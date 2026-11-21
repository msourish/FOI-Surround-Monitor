/* Continuous BlackHole-only PCM capture, derived from the verified bounded reader. No default-device/format setter, tap,
 * microphone fallback, resampling, or persistent audio setting is used.
 * --self-test does not access CoreAudio. --list / --dry-run only read properties.
 * Only --capture creates and starts a separately configured input-only AUHAL. */
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CoreFoundation.h>
#include <AudioUnit/AudioUnit.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <math.h>
#include <time.h>
#include <inttypes.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include "pcm_trim.h"

#define RATE 48000u
#define INCH 16u
#define OUTCH 6u
#define FRAMES 1536u
#define BLOCK_BYTES (FRAMES*OUTCH*sizeof(float))
#define RING_BLOCKS 32u
#define REQUESTED_MAX_FRAMES 4096u
#define MAX_DEVICE_BUFFER_FRAMES 4096u
#define MAX_CALLBACK_FRAMES 16384u
#define DRAIN_TIMEOUT_SECONDS 2.0
#define PIPE_TIMEOUT_SECONDS 0.5
_Static_assert(ATOMIC_LLONG_LOCK_FREE==2 && ATOMIC_LONG_LOCK_FREE==2 && ATOMIC_INT_LOCK_FREE==2,"Lock-free callback atomics required");
static volatile sig_atomic_t interrupted;
static void signal_handler(int s){interrupted=s;}
static uint64_t host_ns(void){return AudioConvertHostTimeToNanos(AudioGetCurrentHostTime());}
static double monotonic_now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void nap(unsigned ms){struct timespec t={ms/1000,(long)(ms%1000)*1000000};nanosleep(&t,NULL);}
enum {ERR_NONE,ERR_INPUT_TOPOLOGY,ERR_OUTPUT_ENABLED,ERR_OVERFLOW,ERR_DISCONTINUITY,
      ERR_INVALID_SAMPLE,ERR_FORMAT_CHANGED,ERR_INPUT_STALLED,ERR_PIPE,ERR_TIMEOUT,ERR_SIGNAL,ERR_SETUP,ERR_CLEANUP,ERR_TIMESTAMP,ERR_RENDER,ERR_COUNTER_LIMIT,ERR_TELEMETRY};
typedef struct {
    float samples[FRAMES*OUTCH];
    uint64_t sequence,first_frame,callback_ticks,input_ticks;
    double input_sample_time;
    UInt32 input_frame_offset;
    bool host_valid,sample_valid;
} Block;
typedef OSStatus (*RenderFunction)(AudioUnit,AudioUnitRenderActionFlags *,const AudioTimeStamp *,UInt32,UInt32,AudioBufferList *);
typedef struct {
    uint64_t callback_ticks;UInt32 bus,frames,timestamp_flags,render_channels,render_bytes;
    bool notification_data_present,render_pointer_matches;OSStatus render_status;
} CallbackMetadata;
typedef struct {
    Block ring[RING_BLOCKS];
    CallbackMetadata topology;_Atomic int topology_ready;
    AudioUnit unit;RenderFunction render_function;float *render_samples;AudioBufferList render_list;
    _Atomic int stopping;_Atomic unsigned callbacks_active;
    _Atomic uint64_t render_failures,render_silence_callbacks;_Atomic int last_render_status;
    _Atomic uint64_t published,consumed,captured_frames,first_callback_ticks,last_callback_ticks;
    _Atomic uint64_t overflow_events,dropped_frames,discontinuity_events,invalid_sample_events,invalid_timestamp_events,queue_high_water;
    _Atomic int fatal;
    uint64_t target_blocks,target_frames;
    unsigned partial;
    bool previous_sample_valid;
    double expected_sample_time;
    float peak_limit;
    /* Main-thread-only meter state; no additional callback work. */
    double level_squares[OUTCH];float level_peaks[OUTCH];
    uint64_t level_first_frame,level_frames;
    PCMTrim trim;bool trim_enabled;int trim_control_fd;
    unsigned char trim_control_bytes[72];size_t trim_control_used;bool trim_control_closed;
    uint64_t trim_last_ack,trim_rejected,level_protected[OUTCH],protected_total[OUTCH];
} Capture;
typedef struct {AudioDeviceID device;AudioStreamID stream;UInt32 outputs,buffer_frames;char uid[512],name[256];AudioStreamBasicDescription physical,virtual;} Device;
static void fault(Capture *c,int reason){int zero=0;atomic_compare_exchange_strong(&c->fatal,&zero,reason);}
static void high_water(Capture *c,uint64_t value){uint64_t old=atomic_load(&c->queue_high_water);while(value>old&&!atomic_compare_exchange_weak(&c->queue_high_water,&old,value)){} }
static AudioObjectPropertyAddress address(AudioObjectPropertySelector s,AudioObjectPropertyScope scope){return(AudioObjectPropertyAddress){s,scope,kAudioObjectPropertyElementMain};}
static OSStatus getp(AudioObjectID o,AudioObjectPropertySelector s,AudioObjectPropertyScope scope,void *p,UInt32 n){AudioObjectPropertyAddress a=address(s,scope);UInt32 z=n;OSStatus e=AudioObjectGetPropertyData(o,&a,0,NULL,&z,p);return e?e:(n==z?noErr:kAudioHardwareBadPropertySizeError);}
static void *arrayp(AudioObjectID o,AudioObjectPropertySelector s,AudioObjectPropertyScope scope,UInt32 *n){AudioObjectPropertyAddress a=address(s,scope);*n=0;if(AudioObjectGetPropertyDataSize(o,&a,0,NULL,n)||*n>1024*1024)return NULL;void *p=calloc(1,*n?*n:1);if(!p)return NULL;UInt32 allocated=*n;if(AudioObjectGetPropertyData(o,&a,0,NULL,n,p)||*n>allocated){free(p);return NULL;}return p;}
static bool stringp(AudioObjectID o,AudioObjectPropertySelector s,char *p,size_t n){CFStringRef v=NULL;p[0]=0;if(getp(o,s,kAudioObjectPropertyScopeGlobal,&v,sizeof(v))||!v)return false;bool ok=CFStringGetCString(v,p,n,kCFStringEncodingUTF8);CFRelease(v);return ok;}
static bool pcm16(const AudioStreamBasicDescription *f){return f->mFormatID==kAudioFormatLinearPCM&&f->mSampleRate==RATE&&f->mChannelsPerFrame==INCH&&f->mBitsPerChannel==32&&f->mBytesPerFrame==INCH*4&&f->mBytesPerPacket==INCH*4&&f->mFramesPerPacket==1&&f->mFormatFlags==(kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked);}
static UInt32 channel_count(AudioDeviceID d,AudioObjectPropertyScope scope){UInt32 n=0;AudioBufferList *b=arrayp(d,kAudioDevicePropertyStreamConfiguration,scope,&n);UInt32 c=0;if(b&&n>=offsetof(AudioBufferList,mBuffers)&&b->mNumberBuffers<100&&n>=offsetof(AudioBufferList,mBuffers)+(size_t)b->mNumberBuffers*sizeof(AudioBuffer))for(UInt32 i=0;i<b->mNumberBuffers;i++)c+=b->mBuffers[i].mNumberChannels;free(b);return c;}
static bool validate_device(Device *d,bool log){
    UInt32 alive=0,transport=0,n=0;Float64 rate=0;char uid[512],name[256];
    if(!stringp(d->device,kAudioDevicePropertyDeviceUID,uid,sizeof(uid))||strcmp(uid,d->uid)||!stringp(d->device,kAudioObjectPropertyName,name,sizeof(name))||strcmp(name,"BlackHole 16ch"))return false;
    if(getp(d->device,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&alive,sizeof(alive))||!alive||getp(d->device,kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,&transport,sizeof(transport))||transport!=kAudioDeviceTransportTypeVirtual||getp(d->device,kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,&rate,sizeof(rate))||rate!=RATE)return false;
    AudioStreamID *is=arrayp(d->device,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,&n);
    bool stream_ok=is&&n==sizeof(*is)&&is[0]==d->stream;free(is);if(!stream_ok)return false;
    UInt32 frames=0;if(getp(d->device,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,&frames,sizeof(frames))||frames==0||frames>MAX_DEVICE_BUFFER_FRAMES)return false;
    AudioStreamBasicDescription p={0},v={0};if(getp(d->stream,kAudioStreamPropertyPhysicalFormat,kAudioObjectPropertyScopeGlobal,&p,sizeof(p))||getp(d->stream,kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,&v,sizeof(v))||!pcm16(&p)||!pcm16(&v))return false;
    AudioBufferList *bl=arrayp(d->device,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput,&n);
    bool topology=bl&&n>=sizeof(AudioBufferList)&&bl->mNumberBuffers==1&&bl->mBuffers[0].mNumberChannels==INCH;free(bl);if(!topology)return false;
    d->buffer_frames=frames;d->physical=p;d->virtual=v;
    if(log)fprintf(stderr,"PREFLIGHT uid=%s name=%s input=16ch interleaved float32 48000Hz flags=0x%X buffer=%u; select channels1..6 FL FR FC LFE SL SR\n",uid,name,v.mFormatFlags,frames);
    return true;
}
static bool find_device(const char *uid,Device *d,bool list){
    UInt32 n=0;AudioDeviceID *ds=arrayp(kAudioObjectSystemObject,kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,&n);if(!ds||n%sizeof(*ds)){free(ds);return false;}unsigned matches=0;
    for(UInt32 i=0;i<n/sizeof(*ds);i++){char u[512],name[256];stringp(ds[i],kAudioDevicePropertyDeviceUID,u,sizeof(u));stringp(ds[i],kAudioObjectPropertyName,name,sizeof(name));if(list)printf("device=%u name=%s uid=%s input_channels=%u output_channels=%u\n",ds[i],name,u,channel_count(ds[i],kAudioObjectPropertyScopeInput),channel_count(ds[i],kAudioObjectPropertyScopeOutput));if(uid&&!strcmp(u,uid)){matches++;d->device=ds[i];snprintf(d->uid,sizeof(d->uid),"%s",u);snprintf(d->name,sizeof(d->name),"%s",name);}}
    free(ds);if(list)return true;if(matches!=1)return false;
    AudioStreamID *ss=arrayp(d->device,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,&n);bool ok=ss&&n==sizeof(*ss);if(ok)d->stream=ss[0];free(ss);if(!ok)return false;
    ss=arrayp(d->device,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,&n);if(!ss||n%sizeof(*ss)){free(ss);return false;}d->outputs=n/sizeof(*ss);free(ss);return d->outputs>0&&d->outputs<=8&&validate_device(d,true);
}
/* Entire callback-side operation: bounded copies and arithmetic, lock-free
 * atomics. No property calls, allocation, file IO, logging, or locks. */
static void ingest(Capture *c,const float *in,UInt32 frames,const AudioTimeStamp *stamp,uint64_t callback_ticks){
    if(atomic_load(&c->fatal))return;
    atomic_store(&c->last_callback_ticks,callback_ticks);
    uint64_t total=atomic_load(&c->captured_frames);if(total>=c->target_frames)return;
    if(total>UINT64_MAX-MAX_CALLBACK_FRAMES){fault(c,ERR_COUNTER_LIMIT);return;}
    bool sv=stamp&&(stamp->mFlags&kAudioTimeStampSampleTimeValid),hv=stamp&&(stamp->mFlags&kAudioTimeStampHostTimeValid);
    if(!sv||!hv){atomic_fetch_add(&c->invalid_timestamp_events,1);fault(c,ERR_TIMESTAMP);return;}
    if(sv&&(!isfinite(stamp->mSampleTime)||(c->previous_sample_valid&&fabs(stamp->mSampleTime-c->expected_sample_time)>0.5))){atomic_fetch_add(&c->discontinuity_events,1);fault(c,ERR_DISCONTINUITY);return;}
    c->previous_sample_valid=sv;if(sv)c->expected_sample_time=stamp->mSampleTime+frames;
    UInt32 offset=0;
    while(offset<frames&&total<c->target_frames){
        uint64_t w=atomic_load_explicit(&c->published,memory_order_relaxed),r=atomic_load_explicit(&c->consumed,memory_order_acquire);
        if(w-r>=RING_BLOCKS){atomic_fetch_add(&c->overflow_events,1);atomic_fetch_add(&c->dropped_frames,frames-offset);fault(c,ERR_OVERFLOW);return;}
        Block *b=&c->ring[w%RING_BLOCKS];
        if(!c->partial){b->sequence=w;b->first_frame=total;b->callback_ticks=callback_ticks;b->input_ticks=hv?stamp->mHostTime:0;b->input_sample_time=sv?stamp->mSampleTime+offset:0;b->input_frame_offset=offset;b->host_valid=hv;b->sample_valid=sv;}
        UInt32 count=FRAMES-c->partial;if(count>frames-offset)count=frames-offset;if(count>c->target_frames-total)count=(UInt32)(c->target_frames-total);
        for(UInt32 f=0;f<count;f++)for(UInt32 ch=0;ch<OUTCH;ch++){float x=in[(offset+f)*INCH+ch];if(!isfinite(x)||fabsf(x)>c->peak_limit){atomic_fetch_add(&c->invalid_sample_events,1);fault(c,ERR_INVALID_SAMPLE);return;}b->samples[(c->partial+f)*OUTCH+ch]=x;}
        c->partial+=count;offset+=count;total+=count;atomic_store(&c->captured_frames,total);
        if(c->partial==FRAMES){c->partial=0;atomic_store_explicit(&c->published,w+1,memory_order_release);high_water(c,w+1-r);}
    }
    if(!atomic_load(&c->first_callback_ticks))atomic_store(&c->first_callback_ticks,callback_ticks);
}
/* AUHAL input notification: bus1 with NULL ioData. The owned non-NULL
 * render ABL is solely a capture destination, never a hardware-output buffer. */
static OSStatus input_callback(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *stamp,UInt32 bus,UInt32 frames,AudioBufferList *notification_data){
    Capture *c=context;atomic_fetch_add(&c->callbacks_active,1);uint64_t ticks=AudioGetCurrentHostTime();
    if(interrupted)atomic_store(&c->stopping,1);
    bool first=!atomic_load_explicit(&c->topology_ready,memory_order_relaxed);
    CallbackMetadata m={.callback_ticks=ticks,.bus=bus,.frames=frames,.timestamp_flags=stamp?stamp->mFlags:0,.notification_data_present=notification_data!=NULL,.render_status=-1};
    if(atomic_load(&c->stopping)||atomic_load(&c->fatal)||atomic_load(&c->captured_frames)>=c->target_frames)goto done;
    if(notification_data){fault(c,ERR_OUTPUT_ENABLED);goto done;}
    if(bus!=1||!frames||frames>MAX_CALLBACK_FRAMES||!c->render_samples||!c->render_function||!flags){fault(c,ERR_INPUT_TOPOLOGY);goto done;}
    if(!stamp||(stamp->mFlags&(kAudioTimeStampHostTimeValid|kAudioTimeStampSampleTimeValid))!=(kAudioTimeStampHostTimeValid|kAudioTimeStampSampleTimeValid)||!isfinite(stamp->mSampleTime)){
        atomic_fetch_add(&c->invalid_timestamp_events,1);fault(c,ERR_TIMESTAMP);goto done;
    }
    c->render_list.mNumberBuffers=1;c->render_list.mBuffers[0]=(AudioBuffer){INCH,frames*INCH*sizeof(float),c->render_samples};
    OSStatus status=c->render_function(c->unit,flags,stamp,bus,frames,&c->render_list);m.render_status=status;
    atomic_store(&c->last_render_status,status);
    if(status){atomic_fetch_add(&c->render_failures,1);fault(c,ERR_RENDER);goto done;}
    m.render_channels=c->render_list.mBuffers[0].mNumberChannels;m.render_bytes=c->render_list.mBuffers[0].mDataByteSize;m.render_pointer_matches=c->render_list.mBuffers[0].mData==c->render_samples;
    if(c->render_list.mNumberBuffers!=1||m.render_channels!=INCH||m.render_bytes!=frames*INCH*sizeof(float)||!m.render_pointer_matches){fault(c,ERR_INPUT_TOPOLOGY);goto done;}
    if(*flags&kAudioUnitRenderAction_OutputIsSilence){memset(c->render_samples,0,m.render_bytes);atomic_fetch_add(&c->render_silence_callbacks,1);}
    ingest(c,c->render_samples,frames,stamp,ticks);
done:
    if(first){c->topology=m;atomic_store_explicit(&c->topology_ready,1,memory_order_release);}
    atomic_fetch_sub(&c->callbacks_active,1);return noErr;
}
static OSStatus changed(AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress *a,void *context){(void)o;(void)n;(void)a;fault(context,ERR_FORMAT_CHANGED);return noErr;}
static bool au_set(AudioUnit u,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement bus,const void *value,UInt32 size,const char *label){
    OSStatus status=AudioUnitSetProperty(u,property,scope,bus,value,size);if(status)fprintf(stderr,"AUHAL %s failed status=%d scope=%u bus=%u\n",label,(int)status,scope,bus);return status==noErr;
}
static bool au_get(AudioUnit u,AudioUnitPropertyID property,AudioUnitScope scope,AudioUnitElement bus,void *value,UInt32 size,const char *label){
    UInt32 actual=size;OSStatus status=AudioUnitGetProperty(u,property,scope,bus,value,&actual);if(status||actual!=size)fprintf(stderr,"AUHAL %s failed status=%d bytes=%u/%u scope=%u bus=%u\n",label,(int)status,actual,size,scope,bus);return status==noErr&&actual==size;
}
static bool hardware_pcm16(const AudioStreamBasicDescription *f){
    if(pcm16(f))return true;
    return f->mFormatID==kAudioFormatLinearPCM&&f->mSampleRate==RATE&&f->mChannelsPerFrame==INCH&&f->mBitsPerChannel==32&&f->mBytesPerFrame==4&&f->mBytesPerPacket==4&&f->mFramesPerPacket==1&&f->mFormatFlags==(kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved);
}
static bool verify_unit(AudioUnit u,const Device *d,bool formats,const char *stage,FILE *telemetry){
    UInt32 input=0,output=1;AudioDeviceID actual=0;
    bool input_read=au_get(u,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&input,sizeof(input),"get input enable");
    bool output_read=au_get(u,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&output,sizeof(output),"get output enable");
    bool device_read=au_get(u,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,sizeof(actual),"get explicit device");
    AudioStreamBasicDescription hw={0},client={0};UInt32 maximum=0,allocate=UINT32_MAX;SInt32 channel_map[INCH];for(unsigned i=0;i<INCH;i++)channel_map[i]=-1;
    bool hw_read=false,client_read=false,max_read=false,allocate_read=false,map_read=false,map_ok=false;
    if(formats){
        hw_read=au_get(u,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,1,&hw,sizeof(hw),"hardware input format");
        client_read=au_get(u,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&client,sizeof(client),"client capture format");
        max_read=au_get(u,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximum,sizeof(maximum),"maximum frames");
        allocate_read=au_get(u,kAudioUnitProperty_ShouldAllocateBuffer,kAudioUnitScope_Output,1,&allocate,sizeof(allocate),"owned buffer setting");
        map_read=au_get(u,kAudioOutputUnitProperty_ChannelMap,kAudioUnitScope_Output,1,channel_map,sizeof(channel_map),"capture identity channel map");
        map_ok=map_read;for(unsigned i=0;i<INCH;i++)if(channel_map[i]!=(SInt32)i)map_ok=false;
    }
    bool ok=input_read&&output_read&&device_read&&input==1&&output==0&&actual==d->device;
    if(formats)ok=ok&&hw_read&&client_read&&max_read&&allocate_read&&map_ok&&hardware_pcm16(&hw)&&pcm16(&client)&&maximum>0&&maximum<=MAX_CALLBACK_FRAMES&&allocate==0;
    fprintf(stderr,"AUHAL_CHECK stage=%s verified=%d input=%u/read%d output=%u/read%d device=%u/read%d hw_flags=0x%X/read%d client_flags=0x%X/read%d max_frames=%u/read%d capacity=%u requested=%u allocate=%u/read%d map_read=%d map_identity=%d\n",stage,ok,input,input_read,output,output_read,actual,device_read,hw.mFormatFlags,hw_read,client.mFormatFlags,client_read,maximum,max_read,MAX_CALLBACK_FRAMES,REQUESTED_MAX_FRAMES,allocate,allocate_read,map_read,map_ok);
    if(telemetry)fprintf(telemetry,"{\"event\":\"auhal_verified\",\"stage\":\"%s\",\"verified\":%s,\"input_enabled\":%u,\"input_read\":%s,\"output_enabled\":%u,\"output_read\":%s,\"device_id\":%u,\"device_read\":%s,\"formats_checked\":%s,\"hardware_flags\":%u,\"hardware_format_read\":%s,\"client_flags\":%u,\"client_format_read\":%s,\"maximum_frames\":%u,\"maximum_frames_read\":%s,\"owned_capacity_frames\":%u,\"requested_maximum_frames\":%u,\"should_allocate_buffer\":%u,\"should_allocate_buffer_read\":%s,\"channel_map_read\":%s,\"channel_map_identity\":%s}\n",stage,ok?"true":"false",input,input_read?"true":"false",output,output_read?"true":"false",actual,device_read?"true":"false",formats?"true":"false",hw.mFormatFlags,hw_read?"true":"false",client.mFormatFlags,client_read?"true":"false",maximum,max_read?"true":"false",MAX_CALLBACK_FRAMES,REQUESTED_MAX_FRAMES,allocate,allocate_read?"true":"false",map_read?"true":"false",map_ok?"true":"false");
    return ok;
}
static void log_topology(FILE *f,const Capture *c){
    if(!atomic_load_explicit(&c->topology_ready,memory_order_acquire))return;const CallbackMetadata *m=&c->topology;
    fprintf(f,"{\"event\":\"first_auhal_callback\",\"callback_host_ns\":%"PRIu64",\"bus\":%u,\"frames\":%u,\"timestamp_flags\":%u,\"notification_data_present\":%s,\"render_status\":%d,\"render_channels\":%u,\"render_bytes\":%u,\"render_pointer_matches\":%s}\n",AudioConvertHostTimeToNanos(m->callback_ticks),m->bus,m->frames,m->timestamp_flags,m->notification_data_present?"true":"false",(int)m->render_status,m->render_channels,m->render_bytes,m->render_pointer_matches?"true":"false");
}
/* Finish the current raw PCM block on a requested stop. Capture callbacks
 * stop accepting samples immediately; cleanup quiesces AUHAL before draining.
 * An unresponsive downstream pipe is a fault, never an unbounded shutdown. */
static bool write_bounded(Capture *c,int fd,const void *bytes,size_t length,double hard_deadline){
    const unsigned char *p=bytes;size_t done=0;double until=monotonic_now()+PIPE_TIMEOUT_SECONDS;if(until>hard_deadline)until=hard_deadline;
    while(done<length){if(interrupted)atomic_store(&c->stopping,1);if(atomic_load(&c->fatal))return false;if(monotonic_now()>until){fault(c,ERR_PIPE);return false;}ssize_t n=write(fd,p+done,length-done);if(n>0){done+=(size_t)n;continue;}if(n<0&&errno==EINTR)continue;if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){struct pollfd q={fd,POLLOUT,0};if(poll(&q,1,10)<0&&errno!=EINTR){fault(c,ERR_PIPE);return false;}continue;}fault(c,ERR_PIPE);return false;}
    return true;
}
/* Private fixed-size IPC from the validated backend: no JSON parser or IO in
 * the Core Audio callback. Each read pass is bounded to eight packets. */
static uint64_t trim_le64(const unsigned char *p){uint64_t n=0;for(unsigned i=0;i<8;i++)n|=(uint64_t)p[i]<<(8*i);return n;}
static uint32_t trim_le32(const unsigned char *p){uint32_t n=0;for(unsigned i=0;i<4;i++)n|=(uint32_t)p[i]<<(8*i);return n;}
static bool accept_trim_packet(Capture *c,const unsigned char p[72]){
    if(memcmp(p,"FOITRM1\n",8))return false;
    uint64_t revision=trim_le64(p+8);uint32_t mask=trim_le32(p+64),ramp=trim_le32(p+68);
    if(!revision||revision>9007199254740991ULL||mask>63||ramp!=PCM_TRIM_RAMP_FRAMES)return false;
    double gains[OUTCH];bool mute[OUTCH];
    for(unsigned ch=0;ch<OUTCH;ch++){uint64_t bits=trim_le64(p+16+ch*8);memcpy(&gains[ch],&bits,8);mute[ch]=(mask&(1u<<ch))!=0;}
    return pcm_trim_request(&c->trim,gains,mute,revision);
}
static void reject_trim(Capture *c,FILE *telemetry,const char *reason){
    c->trim_rejected++;fprintf(telemetry,"{\"event\":\"trim_rejected\",\"reason\":\"%s\",\"rejected_count\":%"PRIu64"}\n",reason,c->trim_rejected);
}
static void poll_trim_control(Capture *c,FILE *telemetry){
    if(!c->trim_enabled||c->trim_control_fd<0||c->trim_control_closed)return;
    for(unsigned budget=0;budget<8;budget++){
        ssize_t n=read(c->trim_control_fd,c->trim_control_bytes+c->trim_control_used,72-c->trim_control_used);
        if(n<0){if(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)return;c->trim_control_closed=true;reject_trim(c,telemetry,"control_read_failed");return;}
        if(!n){c->trim_control_closed=true;if(c->trim_control_used)reject_trim(c,telemetry,"partial_control_packet");return;}
        c->trim_control_used+=(size_t)n;
        if(c->trim_control_used==72){if(!accept_trim_packet(c,c->trim_control_bytes))reject_trim(c,telemetry,"invalid_or_stale_control_packet");c->trim_control_used=0;}
    }
}
static void emit_trim_ack(Capture *c,FILE *telemetry,const Block *b){
    if(!c->trim_enabled||c->trim.completed_revision<=c->trim_last_ack)return;
    fprintf(telemetry,"{\"event\":\"trim_applied\",\"revision\":%"PRIu64",\"trims_db\":[",c->trim.completed_revision);
    for(unsigned ch=0;ch<OUTCH;ch++){if(ch)fputc(',',telemetry);if(c->trim.muted[ch])fputs("null",telemetry);else fprintf(telemetry,"%.17g",c->trim.gain_db[ch]);}
    fprintf(telemetry,"],\"ramp_frames\":%u,\"first_frame\":%"PRIu64",\"completed_after_frame\":%"PRIu64",\"write_completed_host_ns\":%"PRIu64"}\n",PCM_TRIM_RAMP_FRAMES,b->first_frame,b->first_frame+FRAMES,host_ns());
    c->trim_last_ack=c->trim.completed_revision;
}
static void accumulate_levels(Capture *c,const Block *b){
    if(!c->level_frames)c->level_first_frame=b->first_frame;
    for(unsigned i=0;i<FRAMES;i++)for(unsigned ch=0;ch<OUTCH;ch++){
        float x=b->samples[i*OUTCH+ch],peak=fabsf(x);
        if(peak>c->level_peaks[ch])c->level_peaks[ch]=peak;
        c->level_squares[ch]+=(double)x*x;
    }
    c->level_frames+=FRAMES;
}
static void accumulate_trim_levels(Capture *c,const Block *b,const PCMTrimMetrics *m){
    if(!c->level_frames)c->level_first_frame=b->first_frame;
    for(unsigned ch=0;ch<OUTCH;ch++){
        if(m->peak[ch]>c->level_peaks[ch])c->level_peaks[ch]=(float)m->peak[ch];
        c->level_squares[ch]+=m->sum_squares[ch];c->level_protected[ch]+=m->protected_samples[ch];c->protected_total[ch]+=m->protected_samples[ch];
    }
    c->level_frames+=FRAMES;
}
static void emit_levels(FILE *f,Capture *c){
    fprintf(f,",\"level_first_frame\":%"PRIu64",\"level_frames\":%"PRIu64",\"peak\":[",c->level_first_frame,c->level_frames);
    for(unsigned ch=0;ch<OUTCH;ch++)fprintf(f,"%s%.9g",ch?",":"",c->level_peaks[ch]);
    fprintf(f,"],\"rms\":[");
    for(unsigned ch=0;ch<OUTCH;ch++)fprintf(f,"%s%.9g",ch?",":"",c->level_frames?sqrt(c->level_squares[ch]/c->level_frames):0.0);
    fprintf(f,"]");
    if(c->trim_enabled){
        fprintf(f,",\"meter_stage\":\"post_trim_pre_protection\",\"trim_applied_revision\":%"PRIu64",\"protected_samples\":[",c->trim_last_ack);
        for(unsigned ch=0;ch<OUTCH;ch++)fprintf(f,"%s%"PRIu64,ch?",":"",c->level_protected[ch]);
        fprintf(f,"],\"protected_samples_total\":[");for(unsigned ch=0;ch<OUTCH;ch++)fprintf(f,"%s%"PRIu64,ch?",":"",c->protected_total[ch]);fprintf(f,"]");
    }
    memset(c->level_peaks,0,sizeof(c->level_peaks));memset(c->level_squares,0,sizeof(c->level_squares));memset(c->level_protected,0,sizeof(c->level_protected));c->level_frames=0;
}
static bool write_block(Capture *c,int fd,FILE *telemetry,uint64_t *written,unsigned every,bool draining,double deadline){
    uint64_t available=atomic_load_explicit(&c->published,memory_order_acquire);if(*written>=available)return true;
    Block *b=&c->ring[*written%RING_BLOCKS];if(b->sequence!=*written){fault(c,ERR_DISCONTINUITY);return false;}
    PCMTrimMetrics metrics;
    if(c->trim_enabled){
        if(!draining)poll_trim_control(c,telemetry);
        if(!pcm_trim_apply(&c->trim,b->samples,FRAMES,&metrics)){atomic_fetch_add(&c->invalid_sample_events,1);fault(c,ERR_INVALID_SAMPLE);return false;}
    }
    if(!write_bounded(c,fd,b->samples,BLOCK_BYTES,deadline))return false;
    uint64_t completed=host_ns();uint64_t input_host=b->host_valid?AudioConvertHostTimeToNanos(b->input_ticks)+(uint64_t)llround((double)b->input_frame_offset*1e9/RATE):0;
    if(c->trim_enabled)accumulate_trim_levels(c,b,&metrics);else accumulate_levels(c,b);
    emit_trim_ack(c,telemetry,b);bool log_ok=true;
    if(*written==0||(*written+1)%every==0||draining){
        fprintf(telemetry,"{\"event\":\"block_written\",\"sequence\":%"PRIu64",\"first_frame\":%"PRIu64",\"frames\":1536,\"capture_callback_host_ns\":%"PRIu64",\"input_host_valid\":%s,\"input_host_ns\":%"PRIu64",\"input_timestamp_host_ns\":%"PRIu64",\"input_sample_time_valid\":%s,\"input_sample_time\":%.9f,\"input_frame_offset_in_callback\":%u,\"write_completed_host_ns\":%"PRIu64",\"queue_blocks\":%"PRIu64",\"draining\":%s",b->sequence,b->first_frame,AudioConvertHostTimeToNanos(b->callback_ticks),b->host_valid?"true":"false",input_host,b->host_valid?AudioConvertHostTimeToNanos(b->input_ticks):0,b->sample_valid?"true":"false",b->input_sample_time,b->input_frame_offset,completed,available-*written-1,draining?"true":"false");
        emit_levels(telemetry,c);fprintf(telemetry,"}\n");log_ok=fflush(telemetry)==0&&!ferror(telemetry);
    }
    /* The PCM block was fully delivered even if its subsequent log failed. */
    ++*written;atomic_store_explicit(&c->consumed,*written,memory_order_release);
    if(!log_ok){fault(c,ERR_TELEMETRY);return false;}return true;
}
/* Called only after capture callbacks have stopped and quiesced. */
static bool drain_complete_blocks(Capture *c,int fd,FILE *telemetry,uint64_t *written,unsigned every,double deadline){
    while(*written<atomic_load_explicit(&c->published,memory_order_acquire)&&!atomic_load(&c->fatal)){
        if(monotonic_now()>=deadline){fault(c,ERR_PIPE);return false;}
        if(!write_block(c,fd,telemetry,written,every,true,deadline))return false;
    }
    return !atomic_load(&c->fatal);
}
static void le16(unsigned char *p,uint16_t v){p[0]=v;p[1]=v>>8;}
static void le32(unsigned char *p,uint32_t v){for(int i=0;i<4;i++)p[i]=v>>(8*i);}
static void wav_header(unsigned char h[68],uint64_t target_frames){memset(h,0,68);uint32_t bytes=(uint32_t)(target_frames*OUTCH*4);memcpy(h,"RIFF",4);le32(h+4,60+bytes);memcpy(h+8,"WAVEfmt ",8);le32(h+16,40);le16(h+20,0xfffe);le16(h+22,OUTCH);le32(h+24,RATE);le32(h+28,RATE*OUTCH*4);le16(h+32,OUTCH*4);le16(h+34,32);le16(h+36,22);le16(h+38,32);le32(h+40,0x60f);le32(h+44,3);h[50]=0x10;h[52]=0x80;h[55]=0xaa;h[57]=0x38;h[58]=0x9b;h[59]=0x71;memcpy(h+60,"data",4);le32(h+64,bytes);}
static bool publish_ready(const char *path,const char *json){char temp[PATH_MAX];int n=snprintf(temp,sizeof(temp),"%s.tmp.%d",path,getpid());if(n<0||(size_t)n>=sizeof(temp))return false;int fd=open(temp,O_WRONLY|O_CREAT|O_EXCL,0600);if(fd<0)return false;size_t size=strlen(json),done=0;bool ok=true;while(done<size){ssize_t z=write(fd,json+done,size-done);if(z<0&&errno==EINTR&&!interrupted)continue;if(z<=0){ok=false;break;}done+=(size_t)z;}if(close(fd))ok=false;if(ok&&renamex_np(temp,path,RENAME_EXCL))ok=false;if(!ok)unlink(temp);return ok;}
static bool safe_uid(const char *uid){size_t n=strlen(uid);if(!n||n>=512)return false;for(size_t i=0;i<n;i++)if(!((uid[i]>='a'&&uid[i]<='z')||(uid[i]>='A'&&uid[i]<='Z')||(uid[i]>='0'&&uid[i]<='9')||strchr("_-.:",uid[i])))return false;return true;}
static int self_test(void){
    unsigned tests=0;bool ok=true;Capture *c=calloc(1,sizeof(*c));float *in=calloc(MAX_CALLBACK_FRAMES*INCH,sizeof(float));if(!c||!in)return 2;c->target_blocks=4;c->target_frames=4*FRAMES;c->peak_limit=1;
    for(unsigned f=0;f<MAX_CALLBACK_FRAMES;f++)for(unsigned ch=0;ch<INCH;ch++)in[f*INCH+ch]=(float)(ch+1)/32;
    AudioTimeStamp t={.mSampleTime=0,.mHostTime=100,.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid};
    ingest(c,in,512,&t,110);tests++;ok&=atomic_load(&c->published)==0&&atomic_load(&c->captured_frames)==512;
    t.mSampleTime=512;ingest(c,in,1024,&t,120);tests++;ok&=atomic_load(&c->published)==1&&c->ring[0].input_sample_time==0;
    tests++;for(unsigned f=0;f<FRAMES;f++)for(unsigned ch=0;ch<OUTCH;ch++)ok&=c->ring[0].samples[f*OUTCH+ch]==(float)(ch+1)/32;
    t.mSampleTime=1536;ingest(c,in,4096,&t,130);tests++;ok&=atomic_load(&c->published)==3&&c->partial==1024&&c->ring[2].input_frame_offset==1536;
    t.mSampleTime=5632;ingest(c,in,512,&t,140);tests++;ok&=atomic_load(&c->published)==4&&atomic_load(&c->captured_frames)==6144;
    t.mSampleTime=6144;ingest(c,in,512,&t,150);tests++;ok&=atomic_load(&c->published)==4&&atomic_load(&c->captured_frames)==6144;
    memset(c,0,sizeof(*c));c->target_frames=(RING_BLOCKS+1)*FRAMES;c->peak_limit=1;for(unsigned b=0;b<RING_BLOCKS+1;b++){t.mSampleTime=b*FRAMES;ingest(c,in,FRAMES,&t,100+b);}tests++;ok&=atomic_load(&c->fatal)==ERR_OVERFLOW&&atomic_load(&c->overflow_events)==1&&atomic_load(&c->dropped_frames)==FRAMES;
    memset(c,0,sizeof(*c));c->target_frames=2*FRAMES;c->peak_limit=1;t.mSampleTime=0;ingest(c,in,512,&t,100);t.mSampleTime=513;ingest(c,in,512,&t,101);tests++;ok&=atomic_load(&c->fatal)==ERR_DISCONTINUITY;
    memset(c,0,sizeof(*c));c->target_frames=FRAMES;c->peak_limit=1;in[0]=NAN;t.mSampleTime=0;ingest(c,in,512,&t,100);tests++;ok&=atomic_load(&c->fatal)==ERR_INVALID_SAMPLE;in[0]=1.1f;
    memset(c,0,sizeof(*c));c->target_frames=FRAMES;c->peak_limit=1;ingest(c,in,512,&t,100);tests++;ok&=atomic_load(&c->fatal)==ERR_INVALID_SAMPLE;
    AudioStreamBasicDescription f={.mSampleRate=RATE,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=9,.mBytesPerPacket=64,.mFramesPerPacket=1,.mBytesPerFrame=64,.mChannelsPerFrame=16,.mBitsPerChannel=32};tests++;ok&=pcm16(&f);f.mChannelsPerFrame=2;tests++;ok&=!pcm16(&f);f.mChannelsPerFrame=16;f.mFormatFlags|=kAudioFormatFlagIsNonInterleaved;tests++;ok&=!pcm16(&f);
    unsigned char h[68];wav_header(h,FRAMES);tests++;ok&=!memcmp(h,"RIFF",4)&&h[44]==3&&h[50]==0x10&&h[52]==0x80&&h[55]==0xaa&&h[57]==0x38&&h[58]==0x9b&&h[59]==0x71&&h[40]==0x0f&&h[41]==6;
    printf("{\"event\":\"self_test\",\"success\":%s,\"tests\":%u,\"hardware_calls\":false}\n",ok?"true":"false",tests);free(c);free(in);return ok?0:1;
}

/* Startup failures never own an AudioUnit or device IO. This event lets the
 * controller distinguish safe preflight refusal from unconfirmed teardown. */
static int preflight_exit(int code,const char *reason){
    bool requested=interrupted==SIGTERM||interrupted==SIGINT||interrupted==SIGHUP;
    fprintf(stderr,"{\"event\":\"preflight_exit\",\"backend\":\"auhal_input_continuous\",\"pid\":%d,\"io_created\":false,\"capture_started\":false,\"exit_code\":%d,\"reason\":\"%s\",\"requested_stop\":%s,\"signal\":%d}\n",getpid(),code,reason,requested?"true":"false",(int)interrupted);
    return code;
}
static void usage(const char *program){
    fprintf(stderr,"Usage: %s --self-test | --list | --dry-run --device-uid BlackHole16ch_UID | --capture --continuous --raw --device-uid BlackHole16ch_UID --ready-file NEW --telemetry NEW_OR_DASH [--peak-limit 0.25] [--telemetry-every-blocks 8] [--trim-control-stdin]\n",program);
}
int main(int argc,char **argv){
    signal(SIGINT,signal_handler);signal(SIGTERM,signal_handler);signal(SIGHUP,signal_handler);signal(SIGPIPE,SIG_IGN);
    fprintf(stderr,"{\"event\":\"process_started\",\"backend\":\"auhal_input_continuous\",\"pid\":%d,\"signal_handlers_ready\":true,\"io_created\":false}\n",getpid());
    const char *uid=NULL,*ready_path=NULL,*telemetry_path=NULL;
    bool list=false,dry=false,capture=false,raw=false,test=false,continuous=false,trim_control=false;
    double peak=0.25;unsigned every=8;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--list"))list=true;
        else if(!strcmp(argv[i],"--dry-run"))dry=true;
        else if(!strcmp(argv[i],"--capture"))capture=true;
        else if(!strcmp(argv[i],"--continuous"))continuous=true;
        else if(!strcmp(argv[i],"--raw"))raw=true;
        else if(!strcmp(argv[i],"--self-test"))test=true;
        else if(!strcmp(argv[i],"--trim-control-stdin"))trim_control=true;
        else if((!strcmp(argv[i],"--device-uid")||!strcmp(argv[i],"--ready-file")||!strcmp(argv[i],"--telemetry")||!strcmp(argv[i],"--peak-limit")||!strcmp(argv[i],"--telemetry-every-blocks"))&&i+1<argc){
            const char *option=argv[i++];
            if(!strcmp(option,"--device-uid"))uid=argv[i];
            else if(!strcmp(option,"--ready-file"))ready_path=argv[i];
            else if(!strcmp(option,"--telemetry"))telemetry_path=argv[i];
            else{char *end=NULL;double v=strtod(argv[i],&end);if(end==argv[i]||*end||!isfinite(v)){usage(argv[0]);return preflight_exit(2,"invalid_arguments_or_preflight");}
                if(!strcmp(option,"--peak-limit"))peak=v;
                else{if(v<1||v>4096||floor(v)!=v){usage(argv[0]);return preflight_exit(2,"invalid_arguments_or_preflight");}every=(unsigned)v;}}}
        else{usage(argv[0]);return preflight_exit(2,"invalid_arguments_or_preflight");}
    }
    if((unsigned)list+(unsigned)dry+(unsigned)capture+(unsigned)test!=1||peak<=0||peak>1||
       (capture&&(!continuous||!raw||!ready_path||!telemetry_path||!strcmp(ready_path,telemetry_path)))||
       (!capture&&(continuous||raw||ready_path||telemetry_path||trim_control))){usage(argv[0]);return preflight_exit(2,"invalid_arguments_or_preflight");}
    if(test)return preflight_exit(self_test(),"self_test_completed");
    Device device={0};if(interrupted)return preflight_exit(0,"cancelled_before_device_query");
    if(list){bool found=find_device(NULL,&device,true);return preflight_exit(interrupted?0:(found?0:1),interrupted?"cancelled_during_device_query":"read_only_completed");}
    /* This continuous backend is deliberately pinned to the observed endpoint. */
    if(!uid||!safe_uid(uid)||strcmp(uid,"BlackHole16ch_UID")){fprintf(stderr,"REFUSED: exact BlackHole16ch_UID required.\n");return preflight_exit(2,"invalid_arguments_or_preflight");}
    bool found=find_device(uid,&device,false);
    if(interrupted)return preflight_exit(0,"cancelled_during_device_query");
    if(!found){fprintf(stderr,"REFUSED: exact BlackHole 16ch virtual 16ch48k float32 input required.\n");return preflight_exit(2,"input_device_preflight_failed");}
    if(dry){fprintf(stderr,"DRY_RUN_PASS input IO not created or started.\n");return preflight_exit(0,"read_only_completed");}
    struct stat sb;if(lstat(ready_path,&sb)==0||errno!=ENOENT){fprintf(stderr,"Ready path must not exist.\n");return preflight_exit(2,"invalid_arguments_or_preflight");}
    if(fstat(STDOUT_FILENO,&sb)||!S_ISFIFO(sb.st_mode)){fprintf(stderr,"Capture stdout must be a pipe.\n");return preflight_exit(2,"invalid_arguments_or_preflight");}
    bool own_telemetry=strcmp(telemetry_path,"-")!=0;FILE *telemetry=stderr;
    int original_stderr_flags=-1;
    if(own_telemetry){int tf=open(telemetry_path,O_WRONLY|O_CREAT|O_EXCL,0600);if(tf<0){perror("telemetry O_EXCL");return preflight_exit(2,"invalid_arguments_or_preflight");}telemetry=fdopen(tf,"w");if(!telemetry){close(tf);return preflight_exit(2,"invalid_arguments_or_preflight");}}
    else{
        if(fstat(STDERR_FILENO,&sb)||!S_ISFIFO(sb.st_mode)){fprintf(stderr,"Dash telemetry requires a drained stderr pipe.\n");return preflight_exit(2,"invalid_arguments_or_preflight");}
        original_stderr_flags=fcntl(STDERR_FILENO,F_GETFL);
        if(original_stderr_flags<0||fcntl(STDERR_FILENO,F_SETFL,original_stderr_flags|O_NONBLOCK)<0)return preflight_exit(2,"invalid_arguments_or_preflight");
        setvbuf(stderr,NULL,_IONBF,0);
    }
    Capture *c=calloc(1,sizeof(*c));if(!c){if(own_telemetry)fclose(telemetry);return preflight_exit(2,"allocation_failed");}
    c->target_frames=UINT64_MAX;c->target_blocks=UINT64_MAX/FRAMES;c->peak_limit=(float)peak;
    pcm_trim_init(&c->trim);c->trim_enabled=trim_control;c->trim_control_fd=trim_control?STDIN_FILENO:-1;
    if(posix_memalign((void **)&c->render_samples,64,MAX_CALLBACK_FRAMES*INCH*sizeof(float))){if(own_telemetry)fclose(telemetry);return preflight_exit(2,"allocation_failed");}
    memset(c->render_samples,0,MAX_CALLBACK_FRAMES*INCH*sizeof(float));c->render_function=AudioUnitRender;
    int original_flags=fcntl(STDOUT_FILENO,F_GETFL);bool stdout_ok=original_flags>=0&&fcntl(STDOUT_FILENO,F_SETFL,original_flags|O_NONBLOCK)==0;
    int original_input_flags=trim_control?fcntl(STDIN_FILENO,F_GETFL):-1;
    bool control_ok=!trim_control||(original_input_flags>=0&&fcntl(STDIN_FILENO,F_SETFL,original_input_flags|O_NONBLOCK)==0);
    bool initialized=false,started=false,ready=false,stop_ok=true,uninitialize_ok=true,destroy_ok=true,listeners_ok=true,quiescent=true;
    unsigned installed=0;uint64_t written=0,empty_waits=0,input_stalls=0;
    double begin=monotonic_now(),next_check=begin;uint64_t start_host=host_ns();
    AudioObjectID listener_objects[]={device.device,device.device,device.device,device.device,device.stream,device.stream};
    AudioObjectPropertyAddress listener_addresses[]={address(kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal),address(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal),address(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput),address(kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal),address(kAudioStreamPropertyPhysicalFormat,kAudioObjectPropertyScopeGlobal),address(kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal)};
    fprintf(telemetry,"{\"event\":\"configuration\",\"backend\":\"auhal_input_continuous\",\"schema\":1,\"pid\":%d,\"device_uid\":\"%s\",\"input_channels\":16,\"output_channels\":6,\"sample_rate\":48000,\"block_frames\":1536,\"continuous\":true,\"raw_output\":true,\"telemetry_every_blocks\":%u,\"peak_limit\":%.9g,\"start_host_ns\":%"PRIu64",\"timestamp_domain\":\"AudioConvertHostTimeToNanos(mach_absolute_time)\"}\n",getpid(),device.uid,every,peak,start_host);
    if(fflush(telemetry)||ferror(telemetry)){fault(c,ERR_TELEMETRY);goto cleanup;}
    if(!stdout_ok||!control_ok){fault(c,ERR_SETUP);goto cleanup;}
    if(trim_control){fprintf(telemetry,"{\"event\":\"trim_configuration\",\"enabled\":true,\"minimum_db\":-60,\"maximum_db\":6,\"ramp_frames\":960,\"initial_revision\":0,\"initial_trims_db\":[0,0,0,0,0,0],\"protection\":\"explicit_sample_clamp\",\"meter_stage\":\"post_trim_pre_protection\"}\n");}
    if(interrupted)goto cleanup;
    for(unsigned i=0;i<sizeof(listener_objects)/sizeof(*listener_objects);i++){if(AudioObjectAddPropertyListener(listener_objects[i],&listener_addresses[i],changed,c)){fault(c,ERR_SETUP);goto cleanup;}installed++;}
    AudioComponentDescription description={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(NULL,&description);
    OSStatus setup_status=component?AudioComponentInstanceNew(component,&c->unit):kAudio_ParamError;
    if(setup_status||!c->unit){fprintf(stderr,"AUHAL create failed status=%d\n",(int)setup_status);fault(c,ERR_SETUP);goto cleanup;}
    UInt32 one=1,zero=0,maximum=REQUESTED_MAX_FRAMES;
    if(!au_set(c->unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&one,sizeof(one),"enable input")||!au_set(c->unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&zero,sizeof(zero),"disable output")||!au_set(c->unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device.device,sizeof(device.device),"set explicit BlackHole device")||!verify_unit(c->unit,&device,false,"after_device",telemetry)){fault(c,ERR_SETUP);goto cleanup;}
    AudioStreamBasicDescription hw={0};
    if(!au_get(c->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,1,&hw,sizeof(hw),"initial hardware format")||!hardware_pcm16(&hw)){fault(c,ERR_SETUP);goto cleanup;}
    AURenderCallbackStruct callback={input_callback,c};SInt32 identity_map[INCH];for(unsigned i=0;i<INCH;i++)identity_map[i]=(SInt32)i;
    if(!au_set(c->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&device.virtual,sizeof(device.virtual),"set client capture format")||!au_set(c->unit,kAudioOutputUnitProperty_ChannelMap,kAudioUnitScope_Output,1,identity_map,sizeof(identity_map),"set identity capture channel map")||!au_set(c->unit,kAudioUnitProperty_ShouldAllocateBuffer,kAudioUnitScope_Output,1,&zero,sizeof(zero),"use owned render buffer")||!au_set(c->unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximum,sizeof(maximum),"bound render frames")||!au_set(c->unit,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&callback,sizeof(callback),"register input callback")||!verify_unit(c->unit,&device,true,"before_initialize",telemetry)){fault(c,ERR_SETUP);goto cleanup;}
    setup_status=AudioUnitInitialize(c->unit);if(setup_status){fprintf(stderr,"AUHAL initialize failed status=%d\n",(int)setup_status);fault(c,ERR_SETUP);goto cleanup;}initialized=true;
    UInt32 timestamps_at_zero=0;UInt32 timestamp_bytes=sizeof(timestamps_at_zero);OSStatus timestamp_status=AudioUnitGetProperty(c->unit,kAudioOutputUnitProperty_StartTimestampsAtZero,kAudioUnitScope_Global,0,&timestamps_at_zero,&timestamp_bytes);
    fprintf(telemetry,"{\"event\":\"auhal_timestamp_mode\",\"query_status\":%d,\"start_timestamps_at_zero\":%u,\"sample_zero_is_fairlight_timeline_zero\":false}\n",(int)timestamp_status,timestamps_at_zero);
    if(!verify_unit(c->unit,&device,true,"after_initialize",telemetry)||!validate_device(&device,false)||atomic_load(&c->fatal)){fault(c,ERR_SETUP);goto cleanup;}
    if(interrupted)goto cleanup;
    setup_status=AudioOutputUnitStart(c->unit);if(setup_status){fprintf(stderr,"AUHAL start failed status=%d\n",(int)setup_status);fault(c,ERR_SETUP);goto cleanup;}started=true;
    if(!verify_unit(c->unit,&device,true,"after_start",telemetry)){fault(c,ERR_SETUP);goto cleanup;}

    begin=monotonic_now();
    while(!atomic_load(&c->fatal)&&!interrupted){
        double current=monotonic_now();
        if(current>=next_check){if(!validate_device(&device,false)){fault(c,ERR_FORMAT_CHANGED);break;}next_check=current+0.1;}
        uint64_t first_ticks=atomic_load(&c->first_callback_ticks),last_ticks=atomic_load(&c->last_callback_ticks);
        if(!ready&&first_ticks&&!atomic_load(&c->fatal)&&!interrupted){
            char json[2048];
            snprintf(json,sizeof(json),"{\"event\":\"capture_ready\",\"backend\":\"auhal_input_continuous\",\"schema\":1,\"ready\":true,\"pid\":%d,\"device_id\":%u,\"device_uid\":\"%s\",\"device_name\":\"BlackHole 16ch\",\"input_channels\":16,\"output_channels\":6,\"sample_rate\":48000,\"block_frames\":1536,\"continuous\":true,\"raw_output\":true,\"first_callback_host_ns\":%"PRIu64",\"captured_frames_at_ready\":%"PRIu64",\"capture_started\":true}\n",getpid(),device.device,device.uid,AudioConvertHostTimeToNanos(first_ticks),atomic_load(&c->captured_frames));
            if(!publish_ready(ready_path,json)){if(!interrupted)fault(c,ERR_SETUP);break;}
            ready=true;fprintf(telemetry,"%s",json);
            if(fflush(telemetry)||ferror(telemetry)){fault(c,ERR_TELEMETRY);break;}
        }
        if(interrupted)break;
        uint64_t w=atomic_load_explicit(&c->published,memory_order_acquire);
        if(w>written){if(!write_block(c,STDOUT_FILENO,telemetry,&written,every,false,INFINITY))break;}
        else{
            empty_waits++;
            if((!first_ticks&&current-begin>3)||(last_ticks&&host_ns()-AudioConvertHostTimeToNanos(last_ticks)>500000000u)){input_stalls++;fault(c,ERR_INPUT_STALLED);break;}
            nap(1);
        }
    }
cleanup:
    atomic_store(&c->stopping,1);
    if(started){OSStatus e=AudioOutputUnitStop(c->unit);stop_ok=e==noErr;if(e)fprintf(stderr,"AudioOutputUnitStop failed %d\n",(int)e);}
    double quiet_deadline=monotonic_now()+1;
    while(atomic_load(&c->callbacks_active)&&monotonic_now()<quiet_deadline)nap(1);
    quiescent=atomic_load(&c->callbacks_active)==0;
    if(!stop_ok||!quiescent)fault(c,ERR_CLEANUP);
    if(interrupted&&stop_ok&&quiescent&&!atomic_load(&c->fatal))
        drain_complete_blocks(c,STDOUT_FILENO,telemetry,&written,every,monotonic_now()+DRAIN_TIMEOUT_SECONDS);
    if(stop_ok&&quiescent){
        if(initialized){OSStatus e=AudioUnitUninitialize(c->unit);uninitialize_ok=e==noErr;if(e)fprintf(stderr,"AudioUnitUninitialize failed %d\n",(int)e);}
        if(c->unit){OSStatus e=AudioComponentInstanceDispose(c->unit);destroy_ok=e==noErr;if(e)fprintf(stderr,"AudioComponentInstanceDispose failed %d\n",(int)e);}
    }else{uninitialize_ok=false;destroy_ok=false;}
    for(unsigned i=0;i<installed;i++)if(AudioObjectRemovePropertyListener(listener_objects[i],&listener_addresses[i],changed,c))listeners_ok=false;
    if(original_flags>=0&&fcntl(STDOUT_FILENO,F_SETFL,original_flags)<0)stdout_ok=false;
    if(original_input_flags>=0&&fcntl(STDIN_FILENO,F_SETFL,original_input_flags)<0)control_ok=false;
    if(close(STDOUT_FILENO))stdout_ok=false;
    if(!stop_ok||!uninitialize_ok||!destroy_ok||!quiescent||!listeners_ok||!stdout_ok||!control_ok)fault(c,ERR_CLEANUP);
    log_topology(telemetry,c);
    if(c->level_frames){fprintf(telemetry,"{\"event\":\"final_levels\"");emit_levels(telemetry,c);fprintf(telemetry,"}\n");}
    fprintf(telemetry,"{\"event\":\"auhal_cleanup\",\"stop_ok\":%s,\"uninitialize_ok\":%s,\"dispose_ok\":%s,\"callbacks_quiescent\":%s,\"render_failures\":%"PRIu64",\"last_render_status\":%d,\"render_silence_callbacks\":%"PRIu64"}\n",stop_ok?"true":"false",uninitialize_ok?"true":"false",destroy_ok?"true":"false",quiescent?"true":"false",atomic_load(&c->render_failures),atomic_load(&c->last_render_status),atomic_load(&c->render_silence_callbacks));
    if(fflush(telemetry)||ferror(telemetry))fault(c,ERR_TELEMETRY);
    uint64_t published=atomic_load(&c->published),captured=atomic_load(&c->captured_frames);
    uint64_t undelivered=published-written;
    unsigned partial=quiescent?c->partial:0;
    bool requested_stop=interrupted==SIGTERM||interrupted==SIGINT||interrupted==SIGHUP;
    bool success=requested_stop&&!atomic_load(&c->fatal)&&undelivered==0&&captured==written*FRAMES+partial;
    fprintf(telemetry,"{\"event\":\"summary\",\"backend\":\"auhal_input_continuous\",\"continuous\":true,\"success\":%s,\"requested_stop\":%s,\"ready_published\":%s,\"capture_started\":%s,\"captured_frames\":%"PRIu64",\"captured_blocks\":%"PRIu64",\"written_blocks\":%"PRIu64",\"written_frames\":%"PRIu64",\"discarded_partial_frames\":%u,\"undelivered_complete_blocks\":%"PRIu64",\"overflow_events\":%"PRIu64",\"dropped_frames\":%"PRIu64",\"input_stalls\":%"PRIu64",\"underrun_events\":%"PRIu64",\"discontinuity_events\":%"PRIu64",\"invalid_sample_events\":%"PRIu64",\"invalid_timestamp_events\":%"PRIu64",\"queue_high_water_blocks\":%"PRIu64",\"empty_wait_events\":%"PRIu64",\"cleanup_stop_ok\":%s,\"cleanup_destroy_ok\":%s,\"cleanup_listeners_ok\":%s,\"fatal_code\":%d,\"signal\":%d,\"end_host_ns\":%"PRIu64"}\n",success?"true":"false",requested_stop?"true":"false",ready?"true":"false",started?"true":"false",captured,published,written,written*FRAMES,partial,undelivered,atomic_load(&c->overflow_events),atomic_load(&c->dropped_frames),input_stalls,input_stalls,atomic_load(&c->discontinuity_events),atomic_load(&c->invalid_sample_events),atomic_load(&c->invalid_timestamp_events),atomic_load(&c->queue_high_water),empty_waits,stop_ok?"true":"false",destroy_ok?"true":"false",listeners_ok?"true":"false",atomic_load(&c->fatal),(int)interrupted,host_ns());
    bool log_ok=fflush(telemetry)==0&&!ferror(telemetry);
    if(own_telemetry&&fclose(telemetry))log_ok=false;
    if(original_stderr_flags>=0&&fcntl(STDERR_FILENO,F_SETFL,original_stderr_flags)<0)log_ok=false;
    /* Keep callback/listener storage alive until exit if OS teardown failed. */
    return success&&log_ok?0:1;
}
