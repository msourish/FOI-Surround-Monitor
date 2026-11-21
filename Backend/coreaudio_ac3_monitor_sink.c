/* Fairlight Monitor native encoded sink: explicit UID, guarded lease, finite or continuous.
 * No PCM fallback, no default-device setter, no installs, no persistent service.
 * API references: Apple CoreAudio SDK; mpv's CoreAudio exclusive implementation
 * was consulted for the distinction between physical and virtual formats.
 * An encoded device is a two-channel 16-bit carrier for SIX encoded channels.
 */
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <math.h>
#include <inttypes.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include "sink_device_lease.h"

#define BURST 6144u
#define CAP (BURST*128u)
#define RATE 48000.0
#define BYTES_PER_SECOND 192000u
#define TELEMETRY_CAP 256u
_Static_assert(ATOMIC_LLONG_LOCK_FREE==2,"Callback requires lock-free 64-bit atomics");
_Static_assert(ATOMIC_LONG_LOCK_FREE==2&&ATOMIC_INT_LOCK_FREE==2&&ATOMIC_BOOL_LOCK_FREE==2,"Callback atomics must be lock-free");
static volatile sig_atomic_t interrupted;
static void on_signal(int n) { interrupted = n; }
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void nap(unsigned ms) { struct timespec t={ms/1000,(long)(ms%1000)*1000000}; nanosleep(&t,NULL); }
static void stage_event(FILE *file,const char *stage,uint64_t accepted,unsigned prebuffer_bursts) {
    uint64_t host=AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()),mono=now_ns();
    fprintf(stderr,"STAGE %s host_ns=%"PRIu64" accepted_bursts=%"PRIu64" prebuffer_bursts=%u\n",stage,host,accepted,prebuffer_bursts);
    if(file)fprintf(file,"{\"event\":\"stage\",\"stage\":\"%s\",\"host_ns\":%"PRIu64",\"monotonic_ns\":%"PRIu64",\"accepted_bursts\":%"PRIu64",\"prebuffer_bursts\":%u}\n",stage,host,mono,accepted,prebuffer_bursts);
}
/* Publish a complete immutable handshake atomically, never replacing a target.
 * This helper performs only filesystem operations; tests pass ready:false. */
static bool publish_ready_json(const char *path,const char *json) {
    char temp[PATH_MAX];int count=snprintf(temp,sizeof(temp),"%s.tmp.%d",path,getpid());
    if(count<0||(size_t)count>=sizeof(temp)){errno=ENAMETOOLONG;return false;}
    int fd=open(temp,O_CREAT|O_EXCL|O_WRONLY,0600);if(fd<0)return false;
    size_t n=strlen(json),done=0;bool ok=true;
    while(done<n){ssize_t got=write(fd,json+done,n-done);if(got<0&&errno==EINTR&&!interrupted)continue;if(got<=0){ok=false;break;}done+=(size_t)got;}
    int saved=errno;if(close(fd)&&ok){ok=false;saved=errno;}
    if(ok&&interrupted){ok=false;saved=EINTR;}
    if(ok&&renamex_np(temp,path,RENAME_EXCL)){ok=false;saved=errno;}
    if(!ok){unlink(temp);errno=saved;}
    return ok;
}
static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){sel,scope,kAudioObjectPropertyElementMain};
}
static OSStatus getp(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, void *v, UInt32 n) {
    AudioObjectPropertyAddress a=addr(sel,scope); UInt32 got=n;
    OSStatus e=AudioObjectGetPropertyData(obj,&a,0,NULL,&got,v);
    return e ? e : (got==n ? noErr : kAudioHardwareBadPropertySizeError);
}
static OSStatus setp(AudioObjectID obj, AudioObjectPropertySelector sel, void *v, UInt32 n) {
    AudioObjectPropertyAddress a=addr(sel,kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(obj,&a,0,NULL,n,v);
}
static void *arrayp(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 *bytes) {
    AudioObjectPropertyAddress a=addr(sel,scope); *bytes=0;
    if(AudioObjectGetPropertyDataSize(obj,&a,0,NULL,bytes)!=noErr || !*bytes) return NULL;
    UInt32 allocated=*bytes; void *p=malloc(allocated); if(!p) return NULL;
    if(AudioObjectGetPropertyData(obj,&a,0,NULL,bytes,p)!=noErr || *bytes>allocated) {free(p);return NULL;}
    return p;
}
static void stringp(AudioObjectID obj, AudioObjectPropertySelector sel, char *s, size_t n) {
    CFStringRef v=NULL; s[0]=0;
    if(!getp(obj,sel,kAudioObjectPropertyScopeGlobal,&v,sizeof(v)) && v) {
        CFStringGetCString(v,s,n,kCFStringEncodingUTF8); CFRelease(v);
    }
}
static void fourcc(UInt32 n,char out[5]) {
    for(int i=0;i<4;i++){unsigned c=(n>>(24-i*8))&255;out[i]=(c>=32&&c<=126)?c:'?';}out[4]=0;
}
static void showformat(const char *label, const AudioStreamBasicDescription *a) {
    char id[5];fourcc(a->mFormatID,id);
    fprintf(stderr,"%s format=%s rate=%.0f carrier_channels=%u bits=%u bpf=%u fpp=%u bpp=%u flags=0x%X\n",
            label,id,a->mSampleRate,a->mChannelsPerFrame,a->mBitsPerChannel,a->mBytesPerFrame,
            a->mFramesPerPacket,a->mBytesPerPacket,a->mFormatFlags);
}
static bool encoded_carrier(const AudioStreamBasicDescription *a) {
    /* Strictly accept Apple's documented packaged AC-3, not PCM, raw AC-3,
     * undocumented IAC3 variants, or a float bit-perfect transport trick. */
    const AudioFormatFlags required=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonMixable;
    return a->mFormatID==kAudioFormat60958AC3 && a->mSampleRate==RATE &&
        a->mChannelsPerFrame==2 && a->mBitsPerChannel==16 && a->mBytesPerFrame==4 &&
        a->mFramesPerPacket==1536 && a->mBytesPerPacket==BURST &&
        (a->mFormatFlags&required)==required &&
        !(a->mFormatFlags&(kAudioFormatFlagIsFloat|kAudioFormatFlagIsBigEndian|kAudioFormatFlagIsNonInterleaved));
}
static unsigned readbits(const uint8_t *p,unsigned *position,unsigned count) {
    unsigned result=0;while(count--){result=(result<<1)|((p[*position/8]>>(7-*position%8))&1);++*position;}return result;
}
static unsigned crc16(const uint8_t *p,size_t n) {
    unsigned crc=0;while(n--){crc^=(unsigned)*p++<<8;for(int b=0;b<8;b++)crc=((crc<<1)^((crc&0x8000)?0x8005:0))&0xFFFF;}return crc;
}
static bool validate_burst(const uint8_t *b,char *reason,size_t n) {
    #define REJECT(s) do{snprintf(reason,n,"%s",s);return false;}while(0)
    if(b[0]!=0x72||b[1]!=0xf8||b[2]!=0x1f||b[3]!=0x4e) REJECT("not little-endian IEC61937 sync");
    unsigned pc=b[4]|(b[5]<<8),bits=b[6]|(b[7]<<8);
    if((pc&0x1f)!=1 || (pc&0x80)) REJECT("burst is not valid AC-3 data type");
    if(bits!=1792*8) REJECT("expected 448 kb/s AC-3 frame (1792 bytes)");
    uint8_t frame[1792];for(unsigned i=0;i<sizeof(frame);i+=2){frame[i]=b[8+i+1];frame[i+1]=b[8+i];}
    if(frame[0]!=0x0b||frame[1]!=0x77) REJECT("AC-3 sync absent in burst payload");
    if((frame[4]>>6)!=0 || ((frame[4]&63)>>1)!=15) REJECT("AC-3 header is not 48 kHz/448 kb/s");
    if((frame[5]>>3)>10) REJECT("unsupported AC-3 bitstream version");
    unsigned pos=48,acmod=readbits(frame,&pos,3);
    if((acmod&1)&&acmod!=1) (void)readbits(frame,&pos,2);
    if(acmod&4) (void)readbits(frame,&pos,2);
    if(acmod==2) (void)readbits(frame,&pos,2);
    unsigned lfe=readbits(frame,&pos,1);
    if(acmod!=7||lfe!=1) REJECT("AC-3 is not discrete 3/2 + LFE (six channels)");
    if(crc16(frame+2,sizeof(frame)-2)!=0) REJECT("AC-3 frame CRC failed");
    for(unsigned i=8+sizeof(frame);i<BURST;i++)if(b[i]) REJECT("nonzero bytes in IEC61937 padding");
    return true;
    #undef REJECT
}
struct telemetry_record {
    uint64_t callback_index,callback_monotonic_ns,callback_host_ticks,scheduled_host_ticks;
    uint64_t byte_position,emitted_bytes,requested_bytes,queue_before_bytes,queue_after_bytes,underrun_events;
    unsigned reason_flags,faultcode;
    bool scheduled_host_valid,eof;
};
struct state {
    uint8_t ring[CAP];
    _Atomic uint64_t readpos,writepos,outputbytes,callbacks,drain_hosttime;
    _Atomic uint64_t underrun_events,underrun_missing_bytes;
    _Atomic uint64_t queue_min_before,queue_max_before,queue_min_after,queue_max_after;
    _Atomic uint64_t live_queue_min_before,live_queue_min_after;
    struct telemetry_record telemetry[TELEMETRY_CAP];
    _Atomic uint64_t telemetry_write,telemetry_read,telemetry_dropped;
    _Atomic bool eof,fatal,finished,armed,watch_armed;
    _Atomic unsigned callbacks_active;
    _Atomic unsigned faultcode;
    uint64_t maxbytes,next_telemetry_byte; /* next_telemetry_byte: callback-only. */
    bool telemetry_enabled;
};
static void metric_min(_Atomic uint64_t *slot,uint64_t n) { if(n<atomic_load_explicit(slot,memory_order_relaxed))atomic_store_explicit(slot,n,memory_order_relaxed); }
static void metric_max(_Atomic uint64_t *slot,uint64_t n) { if(n>atomic_load_explicit(slot,memory_order_relaxed))atomic_store_explicit(slot,n,memory_order_relaxed); }
/* Only the callback produces telemetry records. Main alone drains them. */
static void sample_callback(struct state *s,const AudioTimeStamp *ot,uint64_t index,uint64_t position,
                            uint64_t emitted,uint64_t requested,uint64_t qbefore,uint64_t qafter,
                            bool eof,unsigned reason,uint64_t callback_monotonic_ns,uint64_t callback_host_ticks) {
    if(!s->telemetry_enabled)return;
    uint64_t w=atomic_load_explicit(&s->telemetry_write,memory_order_relaxed);
    uint64_t r=atomic_load_explicit(&s->telemetry_read,memory_order_acquire);
    if(w-r>=TELEMETRY_CAP){atomic_fetch_add_explicit(&s->telemetry_dropped,1,memory_order_relaxed);return;}
    struct telemetry_record item={
        .callback_index=index,.callback_monotonic_ns=callback_monotonic_ns,.callback_host_ticks=callback_host_ticks,
        .scheduled_host_ticks=ot?ot->mHostTime:0,.scheduled_host_valid=ot&&(ot->mFlags&kAudioTimeStampHostTimeValid),
        .byte_position=position,.emitted_bytes=emitted,.requested_bytes=requested,
        .queue_before_bytes=qbefore,.queue_after_bytes=qafter,.eof=eof,.reason_flags=reason,
        .underrun_events=atomic_load_explicit(&s->underrun_events,memory_order_relaxed),
        .faultcode=atomic_load_explicit(&s->faultcode,memory_order_relaxed)
    };
    s->telemetry[w%TELEMETRY_CAP]=item;
    atomic_store_explicit(&s->telemetry_write,w+1,memory_order_release);
}
/* The conversion/calibration and JSON I/O are deliberately outside the callback. */
static void drain_telemetry(FILE *file,struct state *s,int64_t host_to_monotonic_ns) {
    if(!file)return;
    uint64_t r=atomic_load_explicit(&s->telemetry_read,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&s->telemetry_write,memory_order_acquire);
    while(r<w){
        struct telemetry_record p=s->telemetry[r%TELEMETRY_CAP];
        uint64_t host_ns=AudioConvertHostTimeToNanos(p.callback_host_ticks);
        uint64_t scheduled_ns=p.scheduled_host_valid?AudioConvertHostTimeToNanos(p.scheduled_host_ticks):0;
        int64_t scheduled_monotonic=p.scheduled_host_valid?(int64_t)scheduled_ns+host_to_monotonic_ns:0;
        fprintf(file,"{\"event\":\"callback_output\",\"callback_index\":%"PRIu64",\"callback_monotonic_ns\":%"PRIu64",\"callback_host_ns\":%"PRIu64",\"scheduled_host_valid\":%s,\"scheduled_host_ns\":%"PRIu64",\"scheduled_monotonic_ns\":%"PRId64",\"byte_position\":%"PRIu64",\"carrier_frame_position\":%"PRIu64",\"emitted_bytes\":%"PRIu64",\"requested_bytes\":%"PRIu64",\"queue_before_bytes\":%"PRIu64",\"queue_after_bytes\":%"PRIu64",\"eof\":%s,\"reason_flags\":%u,\"faultcode\":%u,\"underrun_events\":%"PRIu64"}\n",
            p.callback_index,p.callback_monotonic_ns,host_ns,p.scheduled_host_valid?"true":"false",scheduled_ns,scheduled_monotonic,
            p.byte_position,p.byte_position/4,p.emitted_bytes,p.requested_bytes,p.queue_before_bytes,p.queue_after_bytes,p.eof?"true":"false",p.reason_flags,p.faultcode,p.underrun_events);
        r++;
    }
    atomic_store_explicit(&s->telemetry_read,r,memory_order_release);
}
static void fault(struct state *s,unsigned code) {atomic_store(&s->faultcode,code);atomic_store(&s->fatal,true);}
static OSStatus format_changed(AudioObjectID obj,UInt32 count,const AudioObjectPropertyAddress *a,void *ctx) {
    (void)obj;(void)count;(void)a;struct state *s=ctx;if(atomic_load(&s->watch_armed))fault(s,5);return noErr;
}
static OSStatus render_body(AudioDeviceID dev,const AudioTimeStamp *t,const AudioBufferList *in,const AudioTimeStamp *it,
                       AudioBufferList *out,const AudioTimeStamp *ot,void *ctx) {
    (void)dev;(void)t;(void)in;(void)it;(void)ot;struct state *s=ctx;
    uint64_t callback_host_ticks=AudioGetCurrentHostTime(),callback_monotonic_ns=now_ns();
    uint64_t callback_index=atomic_fetch_add_explicit(&s->callbacks,1,memory_order_relaxed);
    if(!out){fault(s,1);return noErr;}
    for(UInt32 i=0;i<out->mNumberBuffers;i++)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
    if(!atomic_load_explicit(&s->armed,memory_order_acquire)||atomic_load(&s->fatal)||atomic_load(&s->finished)||interrupted)return noErr;
    if(out->mNumberBuffers!=1 || !out->mBuffers[0].mData || out->mBuffers[0].mNumberChannels!=2) {fault(s,1);return noErr;}
    size_t requested=out->mBuffers[0].mDataByteSize;
    if(!requested||requested%4||requested>CAP) {fault(s,2);return noErr;}
    uint64_t r=atomic_load_explicit(&s->readpos,memory_order_relaxed),w=atomic_load_explicit(&s->writepos,memory_order_acquire);
    uint64_t emitted=atomic_load_explicit(&s->outputbytes,memory_order_relaxed);
    uint64_t queue_before=w-r;
    bool eof=atomic_load_explicit(&s->eof,memory_order_acquire);
    metric_min(&s->queue_min_before,queue_before);metric_max(&s->queue_max_before,queue_before);
    if(!eof)metric_min(&s->live_queue_min_before,queue_before);
    size_t remaining=s->maxbytes>emitted?(size_t)(s->maxbytes-emitted):0;
    size_t take=requested<remaining?requested:remaining;
    if(w-r<take) {
        if(!eof) {
            atomic_fetch_add_explicit(&s->underrun_events,1,memory_order_relaxed);
            atomic_fetch_add_explicit(&s->underrun_missing_bytes,take-(w-r),memory_order_relaxed);
            fault(s,3);sample_callback(s,ot,callback_index,emitted,0,requested,queue_before,queue_before,eof,4,callback_monotonic_ns,callback_host_ticks);return noErr;
        }
        take=(size_t)(w-r);
    }
    size_t index=(size_t)(r%CAP),first=CAP-index;if(first>take)first=take;
    if(take){memcpy(out->mBuffers[0].mData,s->ring+index,first);memcpy((uint8_t*)out->mBuffers[0].mData+first,s->ring,take-first);}
    atomic_store_explicit(&s->readpos,r+take,memory_order_release);
    atomic_store_explicit(&s->outputbytes,emitted+take,memory_order_relaxed);
    uint64_t queue_after=queue_before-take;
    metric_min(&s->queue_min_after,queue_after);metric_max(&s->queue_max_after,queue_after);
    if(!eof)metric_min(&s->live_queue_min_after,queue_after);
    bool finish=take<requested || emitted+take==s->maxbytes || (atomic_load(&s->eof)&&r+take==w);
    /* Sample a callback containing a burst start, so downstream timing can
     * interpolate within this buffer, rather than extrapolate across a second. */
    uint64_t boundary=((emitted+BURST-1)/BURST)*BURST;
    bool boundary_inside=take&&boundary>=emitted&&boundary<emitted+take;
    unsigned telemetry_reason=(emitted>=s->next_telemetry_byte&&boundary_inside?1:0)|(finish?2:0);
    if(telemetry_reason){sample_callback(s,ot,callback_index,emitted,take,requested,queue_before,queue_after,eof,telemetry_reason,callback_monotonic_ns,callback_host_ticks);s->next_telemetry_byte=emitted+BYTES_PER_SECOND;}
    if(finish) {
        uint64_t host=(ot&&(ot->mFlags&kAudioTimeStampHostTimeValid))?ot->mHostTime:AudioGetCurrentHostTime();
        /* Let the final scheduled output buffer reach hardware before stopping. */
        atomic_store(&s->drain_hosttime,host+AudioConvertNanosToHostTime((uint64_t)(1e9*requested/BYTES_PER_SECOND)+100000000));
        atomic_store_explicit(&s->finished,true,memory_order_release);
    }
    return noErr;
}
static OSStatus render(AudioDeviceID dev,const AudioTimeStamp *t,const AudioBufferList *in,const AudioTimeStamp *it,AudioBufferList *out,const AudioTimeStamp *ot,void *ctx){
    struct state *s=ctx;atomic_fetch_add(&s->callbacks_active,1);OSStatus e=render_body(dev,t,in,it,out,ot,ctx);atomic_fetch_sub(&s->callbacks_active,1);return e;
}
static void enqueue(struct state *s,const uint8_t *b) {
    uint64_t w=atomic_load_explicit(&s->writepos,memory_order_relaxed);size_t i=(size_t)(w%CAP);
    memcpy(s->ring+i,b,BURST); /* Writes remain burst-aligned, and CAP is a burst multiple. */
    atomic_store_explicit(&s->writepos,w+BURST,memory_order_release);
}
static bool get_formats(AudioStreamID stream,AudioStreamBasicDescription *p,AudioStreamBasicDescription *v) {
    return !getp(stream,kAudioStreamPropertyPhysicalFormat,kAudioObjectPropertyScopeGlobal,p,sizeof(*p))&&
           !getp(stream,kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,v,sizeof(*v));
}
struct lease_device_context {AudioDeviceID device;AudioStreamID stream;char uid[1024];};
static bool read_device_lease(void *opaque,LeaseObservation *o){
    struct lease_device_context *c=opaque;char uid[1024];stringp(c->device,kAudioDevicePropertyDeviceUID,uid,sizeof(uid));
    UInt32 bytes=0;AudioStreamID *streams=arrayp(c->device,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,&bytes);
    o->identity_matches=uid[0]&&!strcmp(uid,c->uid)&&streams&&bytes==sizeof(AudioStreamID)&&streams[0]==c->stream;free(streams);
    if(!o->identity_matches)return false;
    UInt32 alive=0,running=0;AudioObjectPropertyAddress running_address=addr(kAudioDevicePropertyDeviceIsRunningSomewhere,kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertySelector running_selector=AudioObjectHasProperty(c->device,&running_address)?kAudioDevicePropertyDeviceIsRunningSomewhere:kAudioDevicePropertyDeviceIsRunning;
    bool ok=!getp(c->device,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&alive,sizeof(alive));
    ok=!getp(c->device,running_selector,kAudioObjectPropertyScopeGlobal,&running,sizeof(running))&&ok;
    ok=!getp(c->device,kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,&o->owner,sizeof(o->owner))&&ok;
    ok=get_formats(c->stream,&o->physical,&o->virtual_format)&&ok;o->alive=alive!=0;o->running=running!=0;return ok;
}
static bool write_device_owner(void *opaque,pid_t owner){struct lease_device_context *c=opaque;return !setp(c->device,kAudioDevicePropertyHogMode,&owner,sizeof(owner));}
static bool write_device_format(void *opaque,bool physical,const AudioStreamBasicDescription *f){struct lease_device_context *c=opaque;return !setp(c->stream,physical?kAudioStreamPropertyPhysicalFormat:kAudioStreamPropertyVirtualFormat,(void *)f,sizeof(*f));}
static void lease_pause(void *opaque){(void)opaque;nap(20);}
static int list_or_select(const char *needle,AudioDeviceID *selected) {
    UInt32 bytes=0;AudioDeviceID *devices=arrayp(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,&bytes);
    if(!devices){fprintf(stderr,"No devices visible; hardware access may be sandboxed.\n");return -1;}
    int matches=0;
    for(unsigned i=0;i<bytes/sizeof(*devices);i++) {
        char name[1024],uid[1024];stringp(devices[i],kAudioObjectPropertyName,name,sizeof(name));stringp(devices[i],kAudioDevicePropertyDeviceUID,uid,sizeof(uid));
        if(!needle||!strcmp(needle,uid)) {
            pid_t hog=-2;getp(devices[i],kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,&hog,sizeof(hog));
            fprintf(stderr,"device=%u name=%s UID=%s hogPID=%d\n",devices[i],name,uid,hog);
            if(needle){*selected=devices[i];matches++;}
        }
    }
    free(devices);return needle?(matches==1?0:-1):0;
}
static void print_json_string(FILE *out,const char *value) {
    fputc('"',out);
    for(const unsigned char *p=(const unsigned char *)value;*p;p++) {
        if(*p=='"'||*p=='\\'){fputc('\\',out);fputc(*p,out);}
        else if(*p<0x20)fprintf(out,"\\u%04x",(unsigned)*p);
        else fputc(*p,out);
    }
    fputc('"',out);
}
/* Capability discovery only: no ownership/format setters, IOProc or audio start. */
static int list_compatible(void) {
    UInt32 bytes=0;AudioDeviceID *devices=arrayp(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,&bytes);
    if(!devices){fprintf(stderr,"Unable to enumerate CoreAudio outputs.\n");return 1;}
    fputs("{\"schema_version\":1,\"outputs\":[",stdout);bool comma=false;unsigned count=0;
    for(unsigned i=0;i<bytes/sizeof(*devices);i++) {
        AudioDeviceID device=devices[i];UInt32 transport=0,stream_bytes=0;
        if(getp(device,kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,&transport,sizeof(transport))||transport!=kAudioDeviceTransportTypeHDMI)continue;
        AudioStreamID *streams=arrayp(device,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,&stream_bytes);
        if(!streams||stream_bytes!=sizeof(AudioStreamID)){free(streams);continue;}
        AudioStreamID stream=streams[0];free(streams);
        UInt32 format_bytes=0;bool compatible=false;
        AudioStreamRangedDescription *formats=arrayp(stream,kAudioStreamPropertyAvailablePhysicalFormats,kAudioObjectPropertyScopeGlobal,&format_bytes);
        if(formats)for(unsigned j=0;j<format_bytes/sizeof(*formats);j++) {
            AudioStreamBasicDescription target=formats[j].mFormat;target.mSampleRate=RATE;
            if(formats[j].mSampleRateRange.mMinimum<=RATE&&formats[j].mSampleRateRange.mMaximum>=RATE&&encoded_carrier(&target)){compatible=true;break;}
        }
        free(formats);if(!compatible)continue;
        char name[1024],uid[1024];stringp(device,kAudioObjectPropertyName,name,sizeof(name));stringp(device,kAudioDevicePropertyDeviceUID,uid,sizeof(uid));
        bool safe_uid=uid[0]!=0&&name[0]!=0;
        for(const unsigned char *p=(const unsigned char *)uid;*p;p++)if(*p<0x20||*p==0x7f||*p=='"'||*p=='\\')safe_uid=false;
        if(!safe_uid)continue;
        if(++count>256){free(devices);fprintf(stderr,"Too many compatible outputs; refusing an incomplete device list.\n");return 1;}
        struct lease_device_context context={.device=device,.stream=stream};snprintf(context.uid,sizeof(context.uid),"%s",uid);
        LeaseObservation observation={0};const char *reason=NULL;
        if(!read_device_lease(&context,&observation)||!observation.identity_matches||!observation.alive)reason="device_unavailable";
        else if(observation.owner!=-1)reason="device_occupied";
        else if(observation.running)reason="device_active_output";
        if(comma)fputc(',',stdout);comma=true;
        fputs("{\"uid\":",stdout);print_json_string(stdout,uid);fputs(",\"name\":",stdout);print_json_string(stdout,name);
        fprintf(stdout,",\"sample_rate\":48000,\"encoded_format\":\"cac3\",\"available\":%s,\"unavailable_reason\":",reason?"false":"true");
        if(reason)print_json_string(stdout,reason);else fputs("null",stdout);fputc('}',stdout);
    }
    free(devices);fputs("]}\n",stdout);return ferror(stdout)?1:0;
}
static int selftest(void) {
    struct state *s=calloc(1,sizeof(*s));if(!s)return 1;s->maxbytes=BURST*4;
    s->telemetry_enabled=true;atomic_init(&s->queue_min_before,UINT64_MAX);atomic_init(&s->queue_min_after,UINT64_MAX);
    atomic_init(&s->live_queue_min_before,UINT64_MAX);atomic_init(&s->live_queue_min_after,UINT64_MAX);
    uint8_t burst[BURST];for(unsigned i=0;i<BURST;i++)burst[i]=(uint8_t)i;
    enqueue(s,burst);atomic_store(&s->armed,true);
    uint8_t dst[1024];AudioBufferList b={.mNumberBuffers=1,.mBuffers={{2,sizeof(dst),dst}}};
    AudioTimeStamp output_time={.mHostTime=AudioGetCurrentHostTime(),.mFlags=kAudioTimeStampHostTimeValid};
    render(0,NULL,NULL,NULL,&b,&output_time,s);bool ok=!memcmp(dst,burst,sizeof(dst))&&atomic_load(&s->readpos)==sizeof(dst);
    ok=ok&&atomic_load(&s->telemetry_write)==1&&s->telemetry[0].byte_position==0&&s->telemetry[0].emitted_bytes==sizeof(dst)&&s->telemetry[0].scheduled_host_valid;
    ok=ok&&atomic_load(&s->queue_min_before)==BURST&&atomic_load(&s->queue_min_after)==BURST-sizeof(dst);
    atomic_store(&s->readpos,0);b.mBuffers[0].mDataByteSize=1023;
    render(0,NULL,NULL,NULL,&b,NULL,s);ok=ok&&atomic_load(&s->faultcode)==2;
    atomic_store(&s->fatal,false);atomic_store(&s->faultcode,0);atomic_store(&s->readpos,BURST);
    b.mBuffers[0].mDataByteSize=sizeof(dst);memset(dst,0xFF,sizeof(dst));
    render(0,NULL,NULL,NULL,&b,&output_time,s);
    ok=ok&&atomic_load(&s->faultcode)==3&&atomic_load(&s->underrun_events)==1&&atomic_load(&s->underrun_missing_bytes)==sizeof(dst)&&atomic_load(&s->telemetry_write)==2&&s->telemetry[1].reason_flags==4;
    for(unsigned i=0;i<sizeof(dst);i++)ok=ok&&dst[i]==0;
    char reason[128];memset(burst,0,sizeof(burst));ok=ok&&!validate_burst(burst,reason,sizeof(reason));
    free(s);s=calloc(1,sizeof(*s));if(!s)return 1;
    s->maxbytes=CAP;s->telemetry_enabled=true;atomic_store(&s->armed,true);
    for(unsigned i=0;i<CAP/BURST;i++)enqueue(s,burst);
    for(unsigned i=0;i<400;i++)render(0,NULL,NULL,NULL,&b,&output_time,s);
    uint64_t samples=atomic_load(&s->telemetry_write);
    ok=ok&&samples==3&&!atomic_load(&s->fatal);
    for(uint64_t i=0;i<samples;i++) {
        struct telemetry_record p=s->telemetry[i];uint64_t boundary=((p.byte_position+BURST-1)/BURST)*BURST;
        ok=ok&&boundary>=p.byte_position&&boundary<p.byte_position+p.emitted_bytes;
        if(i)ok=ok&&p.byte_position-s->telemetry[i-1].byte_position>=BYTES_PER_SECOND;
    }
    for(unsigned i=0;i<TELEMETRY_CAP;i++)sample_callback(s,&output_time,0,0,0,0,0,0,false,1,now_ns(),AudioGetCurrentHostTime());
    ok=ok&&atomic_load(&s->telemetry_write)==TELEMETRY_CAP&&atomic_load(&s->telemetry_dropped)==3;
    free(s);fprintf(stderr,"SELFTEST %s (ring copy; alignment guard; underrun stop/counter/silence; first/periodic burst-boundary telemetry; bounded telemetry ring; no device API)\n",ok?"PASS":"FAIL");return ok?0:1;
}
static bool clean_empty_cancellation(bool continuous,bool validate,bool prepared,bool started,bool eof,uint64_t bursts,size_t partial){return continuous&&!validate&&prepared&&!started&&eof&&bursts==0&&partial==0;}
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--list-compatible"))return list_compatible();
    const char *device=NULL,*auditpath=NULL,*telemetrypath=NULL,*readypath=NULL;bool dry=false,validate=false,list=false,continuous=false,maxseconds_given=false;double maxseconds=120;unsigned prebuffer_bursts=4;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--device")&&i+1<argc)device=argv[++i];
        else if(!strcmp(argv[i],"--audit")&&i+1<argc)auditpath=argv[++i];
        else if(!strcmp(argv[i],"--telemetry")&&i+1<argc)telemetrypath=argv[++i];
        else if(!strcmp(argv[i],"--ready-file")&&i+1<argc)readypath=argv[++i];
        else if(!strcmp(argv[i],"--prebuffer-bursts")&&i+1<argc){const char *n=argv[++i];if(!strcmp(n,"2"))prebuffer_bursts=2;else if(!strcmp(n,"4"))prebuffer_bursts=4;else if(!strcmp(n,"8"))prebuffer_bursts=8;else{fprintf(stderr,"Prebuffer must be exactly 2, 4, or 8 bursts.\n");return 2;}}
        else if(!strcmp(argv[i],"--max-seconds")&&i+1<argc){char *end=NULL;maxseconds=strtod(argv[++i],&end);maxseconds_given=true;if(!end||*end){fprintf(stderr,"Invalid duration.\n");return 2;}}
        else if(!strcmp(argv[i],"--continuous"))continuous=true;
        else if(!strcmp(argv[i],"--dry-run"))dry=true;
        else if(!strcmp(argv[i],"--validate"))validate=true;
        else if(!strcmp(argv[i],"--list"))list=true;
        else if(!strcmp(argv[i],"--self-test"))return selftest();
        else {fprintf(stderr,"Usage: %s --device EXACT_UID [--dry-run] [--max-seconds 1..180 (default120) | --continuous] [--audit NEW_FILE] [--telemetry NEW_JSONL] --ready-file NEW_JSON [--prebuffer-bursts 2|4|8 (default4)]\n       %s --list-compatible | --list | --validate | --self-test\nstdin must be little-endian IEC61937 AC-3, 48 kHz, 448 kb/s, acmod=7/lfeon=1.\nNo hardware use for --validate or --self-test. --dry-run and listing are read-only. Telemetry measures software/device scheduling, NOT acoustic latency.\n",argv[0],argv[0]);return !strcmp(argv[i],"--help")?0:2;}
    }
    if(continuous&&(maxseconds_given||auditpath||(telemetrypath&&strcmp(telemetrypath,"-")))){fprintf(stderr,"Continuous mode uses EOF/Stop, no --max-seconds or audio audit, and metadata telemetry must be stderr (-).\n");return 2;}
    if(!isfinite(maxseconds)||maxseconds<1||maxseconds>180||(!device&&!validate&&!list)){fprintf(stderr,"Require a device and finite max-seconds 1..180.\n");return 2;}
    if(device){for(const unsigned char *u=(const unsigned char *)device;*u;u++)if(*u<32||*u=='"'||*u=='\\'){fprintf(stderr,"Device UID must be a plain printable identifier.\n");return 2;}}
    if((validate||dry||list)&&readypath){fprintf(stderr,"--ready-file is live-only; no simulated hardware readiness.\n");return 2;}
    if(!validate&&!dry&&!list&&!readypath){fprintf(stderr,"Live prototype requires --ready-file; producer must wait for device readiness.\n");return 2;}
    if(readypath){struct stat st;if(!lstat(readypath,&st)||errno!=ENOENT){fprintf(stderr,"Ready-file destination must not already exist and must be accessible.\n");return 2;}}
    signal(SIGINT,on_signal);signal(SIGTERM,on_signal);signal(SIGHUP,on_signal);signal(SIGPIPE,SIG_IGN);
    setvbuf(stderr,NULL,_IOLBF,0);
    AudioDeviceID dev=0;AudioStreamID stream=0;AudioDeviceIOProcID proc=NULL;
    AudioStreamBasicDescription original_p={0},original_v={0},target={0};
    struct lease_device_context lease_context={0};DeviceLease lease={.pid=getpid()};LeaseOperations lease_ops={read_device_lease,write_device_owner,write_device_format,lease_pause,&lease_context};
    const char *failure_reason="setup_failed";unsigned watch_count=0;AudioObjectID watch_objects[5]={0};bool telemetry_owned=false,stop_ok=true,destroy_ok=true,quiescent=true,listener_cleanup_ok=true;
    bool prepared=false,started=false,first_input_seen=false,cancelled_before_playback=false;int rc=1,audit=-1;
    FILE *telemetryfile=NULL;int64_t host_to_monotonic_ns=0;uint64_t bursts=0;
    const char *restore_physical="not_touched",*restore_virtual="not_touched",*release_status="not_acquired";
    struct state *s=calloc(1,sizeof(*s));if(!s)return 1;
    atomic_init(&s->queue_min_before,UINT64_MAX);atomic_init(&s->queue_min_after,UINT64_MAX);
    atomic_init(&s->live_queue_min_before,UINT64_MAX);atomic_init(&s->live_queue_min_after,UINT64_MAX);
    s->maxbytes=continuous?UINT64_MAX-UINT64_MAX%BURST:(uint64_t)(maxseconds*RATE/1536)*BURST;
    if(telemetrypath) {
        if(!strcmp(telemetrypath,"-")){telemetryfile=stderr;int sf=fcntl(STDERR_FILENO,F_GETFL);if(sf<0||fcntl(STDERR_FILENO,F_SETFL,sf|O_NONBLOCK)){perror("nonblocking telemetry stderr");return 1;}}
        else{int fd=open(telemetrypath,O_CREAT|O_EXCL|O_WRONLY,0600);if(fd<0){perror("telemetry exclusive create");return 1;}telemetryfile=fdopen(fd,"w");if(!telemetryfile){close(fd);perror("telemetry fdopen");return 1;}telemetry_owned=true;}
        setvbuf(telemetryfile,NULL,_IOLBF,0);s->telemetry_enabled=true;
        uint64_t bestspan=UINT64_MAX,bestmono=0,besthost=0;
        for(unsigned i=0;i<8;i++) {uint64_t a=now_ns(),h=AudioGetCurrentHostTime(),b=now_ns();if(b-a<bestspan){bestspan=b-a;bestmono=a+(b-a)/2;besthost=AudioConvertHostTimeToNanos(h);}}
        host_to_monotonic_ns=(int64_t)bestmono-(int64_t)besthost;
        fprintf(telemetryfile,"{\"event\":\"clock_calibration\",\"schema_version\":1,\"clock_monotonic_ns\":%"PRIu64",\"host_ns\":%"PRIu64",\"host_to_monotonic_offset_ns\":%"PRId64",\"bracket_span_ns\":%"PRIu64",\"pid\":%d,\"max_seconds\":%.6f,\"carrier_bytes_per_second\":192000,\"ac3_samples_per_frame\":1536,\"spdif_bytes_per_burst\":6144,\"measurement\":\"software_and_scheduled_device_output_not_acoustic_latency\"}\n",bestmono,besthost,host_to_monotonic_ns,bestspan,getpid(),continuous?0.0:s->maxbytes/(double)BYTES_PER_SECOND);
        if(ferror(telemetryfile)){perror("telemetry initial write");goto cleanup;}
    }
    AudioObjectPropertyAddress watch_addresses[]={addr(kAudioStreamPropertyPhysicalFormat,kAudioObjectPropertyScopeGlobal),addr(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal),addr(kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal),addr(kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal),addr(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput)};
    if(!validate) {
        stage_event(telemetryfile,"preflight_begin",0,prebuffer_bursts);
        if(list_or_select(list?NULL:device,&dev)){failure_reason="device_unavailable";goto cleanup;}
        if(list){failure_reason="none";rc=0;goto cleanup;}
        UInt32 transport=0,alive=0,nbytes=0;pid_t owner=-2;
        if(getp(dev,kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,&transport,sizeof(transport))||transport!=kAudioDeviceTransportTypeHDMI){fprintf(stderr,"Refuse: target must explicitly be an HDMI device.\n");goto cleanup;}
        if(getp(dev,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&alive,sizeof(alive))||!alive){failure_reason="device_unavailable";goto cleanup;}
        if(getp(dev,kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,&owner,sizeof(owner))||owner!=-1){fprintf(stderr,"Refuse: device is occupied (hog PID %d); stop its player before retrying.\n",owner);failure_reason="device_occupied";goto cleanup;}
        AudioStreamID *streams=arrayp(dev,kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput,&nbytes);
        if(!streams||nbytes!=sizeof(AudioStreamID)){free(streams);fprintf(stderr,"Refuse: this probe supports exactly one output stream.\n");goto cleanup;}
        stream=streams[0];free(streams);lease_context.device=dev;lease_context.stream=stream;snprintf(lease_context.uid,sizeof(lease_context.uid),"%s",device);
        LeaseObservation current={0};if(!read_device_lease(&lease_context,&current)||!current.identity_matches||!current.alive){failure_reason="device_unavailable";goto cleanup;}if(current.running){fprintf(stderr,"Selected HDMI has active output IO; it may be an audible or silent player. No takeover attempted.\n");failure_reason="device_active_output";goto cleanup;}
        if(!get_formats(stream,&original_p,&original_v))goto cleanup;
        showformat("original physical",&original_p);showformat("original virtual",&original_v);
        AudioStreamRangedDescription *formats=arrayp(stream,kAudioStreamPropertyAvailablePhysicalFormats,kAudioObjectPropertyScopeGlobal,&nbytes);
        if(!formats)goto cleanup;
        for(unsigned i=0;i<nbytes/sizeof(*formats);i++){
            AudioStreamBasicDescription test=formats[i].mFormat;test.mSampleRate=RATE;
            if(formats[i].mSampleRateRange.mMinimum<=RATE && formats[i].mSampleRateRange.mMaximum>=RATE && encoded_carrier(&test)){target=test;break;}
        }
        free(formats);
        if(!target.mFormatID){failure_reason="unsupported_encoded_format";fprintf(stderr,"Refuse: no native exact 48 kHz packaged AC-3 carrier. No PCM fallback.\n");goto cleanup;}
        showformat("supported target physical",&target);
        stage_event(telemetryfile,"preflight_complete",0,prebuffer_bursts);
        if(dry){fprintf(stderr,"DRY RUN PASS: exact UID, native target, idle unowned HDMI; no setters, input read, or playback.\n");failure_reason="none";rc=0;goto cleanup;}
    }
    if(auditpath){audit=open(auditpath,O_CREAT|O_EXCL|O_WRONLY,0600);if(audit<0){perror("audit create");goto cleanup;}}
    int flags=fcntl(STDIN_FILENO,F_GETFL);if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)){perror("stdin nonblocking");goto cleanup;}
    double begun=now(),starttime=0,lastcheck=0,lastprogress=0;size_t have=0;uint8_t block[BURST];
    double ready_time=0;
    if(!validate) {
        stage_event(telemetryfile,"format_prepare_begin",bursts,prebuffer_bursts);
        lease.target_p=target;enum LeaseResult acquired=lease_acquire(&lease,&lease_ops);
        if(acquired!=LEASE_OK){failure_reason=lease_result_name(acquired);fprintf(stderr,"Lease acquisition refused: %s\n",failure_reason);goto loopdone;}
        original_p=lease.original_p;original_v=lease.original_v;showformat("owned lease snapshot physical",&original_p);showformat("owned lease snapshot virtual",&original_v);pid_t owner=-2;
        stage_event(telemetryfile,"hog_acquired",bursts,prebuffer_bursts);
        stage_event(telemetryfile,"format_set_begin",bursts,prebuffer_bursts);
        enum LeaseResult installed=lease_install(&lease,&lease_ops);
        if(installed!=LEASE_OK){failure_reason=lease_result_name(installed);fprintf(stderr,"Encoded format preparation failed: %s\n",failure_reason);goto loopdone;}
        stage_event(telemetryfile,"physical_format_confirmed",bursts,prebuffer_bursts);
        AudioStreamBasicDescription p={0},v={0};
        if(!get_formats(stream,&p,&v)||!encoded_carrier(&p)||!encoded_carrier(&v)){showformat("rejected physical",&p);showformat("rejected virtual",&v);fprintf(stderr,"Refuse: BOTH physical and virtual formats must be native packaged AC-3.\n");goto loopdone;}
        lease.installed_p=p;lease.installed_v=v;lease.installed_verified=true;
        stage_event(telemetryfile,"native_formats_verified",bursts,prebuffer_bursts);
        showformat("VERIFIED physical",&p);showformat("VERIFIED virtual",&v);
        /* Wait for the format setter's notifications before arming listeners. */
        nap(150);
        stage_event(telemetryfile,"notifications_settled",bursts,prebuffer_bursts);
        atomic_store(&s->watch_armed,true);
        watch_objects[0]=stream;watch_objects[1]=stream;watch_objects[2]=dev;watch_objects[3]=dev;watch_objects[4]=dev;
        for(unsigned i=0;i<5;i++){if(AudioObjectAddPropertyListener(watch_objects[i],&watch_addresses[i],format_changed,s)){fprintf(stderr,"Device/format listener setup failed.\n");goto loopdone;}watch_count++;}
        if(AudioDeviceCreateIOProcID(dev,render,s,&proc)){fprintf(stderr,"IOProc creation failed.\n");goto loopdone;}
        /* Setup is asynchronous: close the verification gap after listeners
         * and IOProc creation, before any callback may emit encoded bytes. */
        owner=-2;LeaseObservation ready_identity={0};
        if(lease_owned_read(&lease,&lease_ops,&ready_identity)!=LEASE_OK||!get_formats(stream,&p,&v)||!encoded_carrier(&p)||!encoded_carrier(&v)||
           getp(dev,kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,&owner,sizeof(owner))||
           owner!=getpid()||atomic_load(&s->fatal)||interrupted){fprintf(stderr,"Final pre-start encoded format/ownership check failed.\n");goto loopdone;}
        prepared=true;lastcheck=now();
        stage_event(telemetryfile,"format_ready",bursts,prebuffer_bursts);
        if(telemetryfile&&ferror(telemetryfile)){fault(s,9);goto loopdone;}
        uint64_t ready_host=AudioConvertHostTimeToNanos(AudioGetCurrentHostTime());
        char ready_json[4096];
        snprintf(ready_json,sizeof(ready_json),"{\"event\":\"device_ready\",\"backend\":\"guarded_coreaudio_ac3\",\"schema_version\":1,\"ready\":true,\"continuous\":%s,\"device_uid\":\"%s\",\"pid\":%d,\"device_id\":%u,\"stream_id\":%u,\"ready_host_ns\":%"PRIu64",\"prebuffer_bursts\":%u,\"prebuffer_bytes\":%u,\"format\":\"cac3\",\"carrier_sample_rate\":48000,\"required_encoded_channels\":6,\"input_read\":false,\"audio_device_started\":false,\"input_wait_timeout_seconds\":10}\n",continuous?"true":"false",lease_context.uid,getpid(),dev,stream,ready_host,prebuffer_bursts,prebuffer_bursts*BURST);
        if(!publish_ready_json(readypath,ready_json)){perror("ready handshake publication");goto loopdone;}
        ready_time=now();begun=ready_time;
        stage_event(telemetryfile,"device_ready",bursts,prebuffer_bursts);
        fprintf(stderr,"DEVICE READY: native encoded output prepared; start producer now. Ready file: %s\n",readypath);
    }
    failure_reason="runtime_failure";
    fprintf(stderr,"INPUT: CRC-validated AC-3; mode=%s; finite_limit_seconds=%.3f; prebuffer=%u bursts (%u ms); pid=%d\n",continuous?"continuous_until_EOF":"finite",continuous?0.0:s->maxbytes/(double)BYTES_PER_SECOND,prebuffer_bursts,prebuffer_bursts*32,getpid());
    while(!interrupted && !atomic_load(&s->fatal) && !atomic_load(&s->finished)) {
        double t=now();
        drain_telemetry(telemetryfile,s,host_to_monotonic_ns);
        if(telemetryfile&&ferror(telemetryfile)){fprintf(stderr,"Telemetry write failed; stopping bounded test.\n");fault(s,9);break;}
        if(prepared&&!started&&t-ready_time>10){fprintf(stderr,"Prepared-device input/prebuffer wait exceeded 10 seconds.\n");goto loopdone;}
        if(!continuous&&t-begun>maxseconds+10){fprintf(stderr,"Wall-clock deadline reached.\n");goto loopdone;}
        if(!started&&!validate&&(atomic_load(&s->writepos)>=(uint64_t)prebuffer_bursts*BURST || atomic_load(&s->eof))) {
            if(!bursts){
                if(clean_empty_cancellation(continuous,validate,prepared,started,atomic_load(&s->eof),bursts,have)){cancelled_before_playback=true;rc=0;stage_event(telemetryfile,"cancelled_before_playback",0,prebuffer_bursts);goto loopdone;}
                fprintf(stderr,"Refuse: empty input.\n");goto loopdone;
            }
            stage_event(telemetryfile,"prebuffer_ready",bursts,prebuffer_bursts);
            AudioStreamBasicDescription p={0},v={0};pid_t owner=-2;LeaseObservation start_identity={0};
            if(!prepared||lease_owned_read(&lease,&lease_ops,&start_identity)!=LEASE_OK||!get_formats(stream,&p,&v)||!encoded_carrier(&p)||!encoded_carrier(&v)||
               getp(dev,kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,&owner,sizeof(owner))||
               owner!=getpid()||atomic_load(&s->fatal)||interrupted){fprintf(stderr,"Final pre-start encoded format/ownership check failed.\n");goto loopdone;}
            stage_event(telemetryfile,"audio_start_begin",bursts,prebuffer_bursts);
            atomic_store(&s->armed,true);
            if(AudioDeviceStart(dev,proc)){atomic_store(&s->armed,false);fprintf(stderr,"Device start failed.\n");goto loopdone;}
            started=true;starttime=now();lastcheck=starttime;
            stage_event(telemetryfile,"audio_start_return",bursts,prebuffer_bursts);
            if(telemetryfile)fprintf(telemetryfile,"{\"event\":\"audio_start_return\",\"monotonic_ns\":%"PRIu64",\"host_ns\":%"PRIu64",\"accepted_bursts\":%"PRIu64"}\n",now_ns(),AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()),bursts);
            fprintf(stderr,"LIVE OUTPUT STARTED: validated incoming AC-3 → native cac3 HDMI. No PCM fallback.\n");
        }
        if(prepared && t-lastcheck>=0.1) {
            LeaseObservation current={0};enum LeaseResult observed=lease_owned_read(&lease,&lease_ops,&current);
            if(observed!=LEASE_OK||!encoded_carrier(&current.physical)||!encoded_carrier(&current.virtual_format)||!lease_pair(&current,&lease.installed_p,&lease.installed_v)){
                failure_reason=observed==LEASE_OK?"external_format_change":lease_result_name(observed);fault(s,4);break;
            }lastcheck=t;
        }
        if(started && t-lastprogress>=1){fprintf(stderr,"progress input_frames=%"PRIu64" output_seconds=%.3f buffer_ms=%.1f wall=%.3f\n",bursts,atomic_load(&s->outputbytes)/(double)BYTES_PER_SECOND,(atomic_load(&s->writepos)-atomic_load(&s->readpos))*1000.0/BYTES_PER_SECOND,t-starttime);lastprogress=t;}
        if(atomic_load(&s->eof)){if(validate){rc=bursts?0:1;break;}nap(5);continue;}
        if(!validate&&atomic_load(&s->writepos)-atomic_load(&s->readpos)>CAP-BURST){nap(5);continue;}
        struct pollfd fd={STDIN_FILENO,POLLIN,0};int ready=poll(&fd,1,20);
        if(ready<0){if(errno==EINTR)continue;perror("stdin poll");break;}
        if(!ready)continue;
        ssize_t got=read(STDIN_FILENO,block+have,BURST-have);
        if(got<0){if(errno==EAGAIN||errno==EINTR)continue;perror("stdin read");break;}
        if(!got){if(have){fprintf(stderr,"Refuse: truncated IEC61937 burst at EOF.\n");fault(s,6);break;}atomic_store(&s->eof,true);continue;}
        if(!first_input_seen){first_input_seen=true;stage_event(telemetryfile,"first_input_bytes",bursts,prebuffer_bursts);}
        have+=(size_t)got;
        if(have==BURST){char reason[160];if(!validate_burst(block,reason,sizeof(reason))){fprintf(stderr,"Reject input burst %"PRIu64": %s\n",bursts,reason);fault(s,7);break;}
            if(!bursts)stage_event(telemetryfile,"first_validated_burst",bursts,prebuffer_bursts);
            if(audit>=0){size_t wrote=0;while(wrote<BURST){ssize_t n=write(audit,block+wrote,BURST-wrote);if(n<0&&errno==EINTR)continue;if(n<=0){perror("audit write");fault(s,8);break;}wrote+=(size_t)n;}if(atomic_load(&s->fatal))break;}
            if(!validate)enqueue(s,block);
            if(telemetryfile&&bursts%32==0)fprintf(telemetryfile,"{\"event\":\"input_burst_accepted\",\"monotonic_ns\":%"PRIu64",\"host_ns\":%"PRIu64",\"burst_index\":%"PRIu64",\"byte_position\":%"PRIu64",\"queue_bytes\":%"PRIu64"}\n",now_ns(),AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()),bursts,bursts*BURST,atomic_load(&s->writepos)-atomic_load(&s->readpos));
            ++bursts;have=0;
            if(bursts*BURST>=s->maxbytes){atomic_store(&s->eof,true);if(validate){rc=0;break;}}
        }
    }
loopdone:
    if(started&&atomic_load(&s->finished)&&!atomic_load(&s->fatal)&&!interrupted) {
        double drain_deadline=now()+2;
        while(AudioGetCurrentHostTime()<atomic_load(&s->drain_hosttime)&&!interrupted&&!atomic_load(&s->fatal)&&now()<drain_deadline)nap(5);
        if(AudioGetCurrentHostTime()>=atomic_load(&s->drain_hosttime)&&!interrupted&&!atomic_load(&s->fatal))rc=0;
        else fprintf(stderr,"Final scheduled buffer drain did not complete.\n");
    }
    fprintf(stderr,"RESULT rc=%d input_AC3_frames=%"PRIu64" accepted_encoded_seconds=%.3f output_bytes=%"PRIu64" callbacks=%"PRIu64" fault=%u signal=%d\n",
        rc,bursts,bursts*1536.0/RATE,atomic_load(&s->outputbytes),atomic_load(&s->callbacks),atomic_load(&s->faultcode),interrupted);
    if(validate&&rc==0)fprintf(stderr,"VALIDATE PASS: every accepted burst is CRC-valid 48 kHz, 448 kb/s, 3/2+LFE AC-3. No device access.\n");
    if(flags>=0)fcntl(STDIN_FILENO,F_SETFL,flags);
cleanup:
    atomic_store(&s->armed,false);
    atomic_store(&s->watch_armed,false);
    if(started&&AudioDeviceStop(dev,proc)){fprintf(stderr,"AudioDeviceStop failed.\n");stop_ok=false;rc=1;}
    if(proc&&AudioDeviceDestroyIOProcID(dev,proc)){fprintf(stderr,"IOProc destroy failed.\n");destroy_ok=false;rc=1;}
    double quiet_deadline=now()+1;while(atomic_load(&s->callbacks_active)&&now()<quiet_deadline)nap(1);quiescent=atomic_load(&s->callbacks_active)==0;
    for(unsigned i=0;i<watch_count;i++)if(AudioObjectRemovePropertyListener(watch_objects[i],&watch_addresses[i],format_changed,s))listener_cleanup_ok=false;
    if(!listener_cleanup_ok||!quiescent)rc=1;
    LeaseCleanup restored=lease_cleanup(&lease,&lease_ops,stop_ok&&destroy_ok&&quiescent);
    restore_physical=restored.physical;restore_virtual=restored.virtual_format;release_status=restored.release;
    if(restored.result!=LEASE_OK){failure_reason=lease_result_name(restored.result);rc=1;}
    if(!stop_ok||!destroy_ok||!quiescent)failure_reason="io_cleanup_failed";
    else if(!listener_cleanup_ok)failure_reason="listener_cleanup_failed";
    if(rc!=0&&!strcmp(failure_reason,"runtime_failure")){
        static const char *fault_reasons[]={"runtime_failure","output_topology_changed","output_buffer_invalid","input_underrun","device_state_changed","device_property_changed","truncated_encoded_input","invalid_encoded_input","audit_write_failed","telemetry_write_failed"};unsigned code=atomic_load(&s->faultcode);if(code<sizeof(fault_reasons)/sizeof(*fault_reasons))failure_reason=fault_reasons[code];
    }
    if(rc==0&&!interrupted)failure_reason="none";else if(interrupted)failure_reason="interrupted";
    fprintf(stderr,"LEASE_CLEANUP physical=%s virtual=%s release=%s stop=%d destroy=%d quiescent=%d reason=%s\n",restore_physical,restore_virtual,release_status,stop_ok,destroy_ok,quiescent,failure_reason);
    bool cleanup_complete=!lease.acquired&&stop_ok&&destroy_ok&&quiescent&&listener_cleanup_ok&&restored.result==LEASE_OK;
    if(audit>=0)close(audit);
    drain_telemetry(telemetryfile,s,host_to_monotonic_ns);
    if(telemetryfile) {
        uint64_t qminbefore=atomic_load(&s->queue_min_before),qminafter=atomic_load(&s->queue_min_after);
        uint64_t livebefore=atomic_load(&s->live_queue_min_before),liveafter=atomic_load(&s->live_queue_min_after);
        if(atomic_load(&s->telemetry_dropped)){fprintf(stderr,"Telemetry records dropped.\n");rc=1;failure_reason="telemetry_records_dropped";}
        fprintf(telemetryfile,"{\"event\":\"summary\",\"backend\":\"guarded_coreaudio_ac3\",\"continuous\":%s,\"failure_reason\":\"%s\",\"io_stop_ok\":%s,\"io_destroy_ok\":%s,\"callbacks_quiescent\":%s,\"cleanup_complete\":%s,\"cancelled_before_playback\":%s,\"exit_code\":%d,\"signal\":%d,\"accepted_bursts\":%"PRIu64",\"output_bytes\":%"PRIu64",\"callbacks\":%"PRIu64",\"underrun_events\":%"PRIu64",\"underrun_missing_bytes\":%"PRIu64",\"faultcode\":%u,\"telemetry_dropped\":%"PRIu64",\"queue_metrics_available\":%s,\"queue_min_before_bytes\":%"PRIu64",\"queue_max_before_bytes\":%"PRIu64",\"queue_min_after_bytes\":%"PRIu64",\"queue_max_after_bytes\":%"PRIu64",\"live_queue_metrics_available\":%s,\"live_queue_min_before_bytes\":%"PRIu64",\"live_queue_min_after_bytes\":%"PRIu64",\"restore_physical\":\"%s\",\"restore_virtual\":\"%s\",\"release_exclusive\":\"%s\",\"host_ns\":%"PRIu64"}\n",
            continuous?"true":"false",failure_reason,stop_ok?"true":"false",destroy_ok?"true":"false",quiescent?"true":"false",cleanup_complete?"true":"false",cancelled_before_playback?"true":"false",interrupted?128+interrupted:rc,interrupted,bursts,atomic_load(&s->outputbytes),atomic_load(&s->callbacks),atomic_load(&s->underrun_events),atomic_load(&s->underrun_missing_bytes),atomic_load(&s->faultcode),atomic_load(&s->telemetry_dropped),qminbefore!=UINT64_MAX?"true":"false",
            qminbefore==UINT64_MAX?0:qminbefore,atomic_load(&s->queue_max_before),qminafter==UINT64_MAX?0:qminafter,atomic_load(&s->queue_max_after),livebefore!=UINT64_MAX?"true":"false",livebefore==UINT64_MAX?0:livebefore,liveafter==UINT64_MAX?0:liveafter,restore_physical,restore_virtual,release_status,AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()));
        if(ferror(telemetryfile)){fprintf(stderr,"Telemetry output failed.\n");rc=1;}
        if(telemetry_owned&&fclose(telemetryfile)){perror("telemetry close");rc=1;}else if(!telemetry_owned&&fflush(telemetryfile)){rc=1;}
    }
    /* Keep callback/listener storage alive until process exit, including unusual
     * stop/destroy failures or an already-dispatched property notification. */
    return interrupted?128+interrupted:rc;
}
