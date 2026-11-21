#!/usr/bin/python3
"""FOI Surround Monitor: BlackHole -> live AC-3 -> selected encoded output.

All runtime helpers are siblings. Normal runs retain metadata only. This module
does not change default devices or privacy grants. Native capability checks,
device ownership and bounded queues remain authoritative; no PCM fallback.
"""
import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
sys.dont_write_bytecode=True
if not __debug__:raise SystemExit('Do not run this validated backend with Python optimization')

ROOT=Path(__file__).resolve().parent
INPUT_UID='BlackHole16ch_UID'
ORDER=['FL','FR','FC','LFE','SL','SR']
FRAMES=1536;PCM_BYTES=36864;BURST_BYTES=6144
REQUIRED_FILES=('monitor_backend.py','auhal_input_continuous','coreaudio_ac3_monitor_sink','ffmpeg')
SHARED_LOCK_PREFIX='foi-fairlight-monitor-'
_lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
class _Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
_tb=_Timebase();assert _lib.mach_timebase_info(ctypes.byref(_tb))==0
_lib.mach_absolute_time.restype=ctypes.c_uint64
def host_ns():return _lib.mach_absolute_time()*_tb.numer//_tb.denom
def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()

def verify_runtime(root):
    """Trust only the executables copied and hashed by this local app build."""
    manifest_path=root/'backend_manifest.json'
    if manifest_path.is_symlink() or not manifest_path.is_file():raise ValueError('Backend manifest is missing or unsafe')
    manifest=json.loads(manifest_path.read_text())
    if manifest.get('schema_version')!=1 or not isinstance(manifest.get('files'),dict):
        raise ValueError('Backend manifest schema is invalid')
    hashes={}
    for name in REQUIRED_FILES:
        path=root/name;expected=manifest['files'].get(name)
        if not isinstance(expected,str) or len(expected)!=64 or any(c not in '0123456789abcdef' for c in expected):
            raise ValueError('Backend manifest hash is invalid: '+name)
        if not path.is_file() or path.is_symlink() or (name!='monitor_backend.py' and not os.access(path,os.X_OK)):
            raise ValueError('Backend executable is missing or unsafe: '+name)
        hashes[name]=sha(path)
        if hashes[name]!=expected:raise ValueError('Backend integrity check failed: '+name)
    return hashes

def valid_output_uid(value):
    if not isinstance(value,str) or not value or not value.isprintable() or '"' in value or '\\' in value:return False
    try:return len(value.encode('utf-8'))<1024
    except UnicodeError:return False

def validate_output_inventory(value):
    if not isinstance(value,dict) or value.get('schema_version')!=1 or not isinstance(value.get('outputs'),list):
        raise ValueError('Native output discovery returned an invalid schema')
    if len(value['outputs'])>256:raise ValueError('Native output discovery exceeded its device bound')
    outputs=[];seen=set()
    for item in value['outputs']:
        if not isinstance(item,dict):raise ValueError('Invalid output discovery entry')
        uid=item.get('uid');name=item.get('name')
        if not valid_output_uid(uid) or uid in seen or not isinstance(name,str) or not name or len(name)>1024:
            raise ValueError('Invalid or duplicate output identity')
        if item.get('sample_rate')!=48000 or item.get('encoded_format')!='cac3' or type(item.get('available')) is not bool:
            raise ValueError('Output is not a validated 48 kHz AC-3 candidate')
        reason=item.get('unavailable_reason')
        if reason is not None and (not isinstance(reason,str) or len(reason)>200):raise ValueError('Invalid output availability reason')
        outputs.append({'uid':uid,'name':name,'sample_rate':48000,'encoded_format':'cac3',
            'available':item['available'],'unavailable_reason':reason});seen.add(uid)
    return outputs

def discover_outputs(root,*,verify=True):
    if verify:verify_runtime(root)
    result=subprocess.run([str(root/'coreaudio_ac3_monitor_sink'),'--list-compatible'],
        stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False)
    if result.returncode!=0:raise RuntimeError('Could not inspect compatible encoded outputs: '+result.stderr.decode('utf-8','replace')[-500:].strip())
    if len(result.stdout)>1024*1024:raise ValueError('Native output discovery response is too large')
    return validate_output_inventory(json.loads(result.stdout))

def select_output(outputs,requested_uid=None):
    if requested_uid is not None and not valid_output_uid(requested_uid):raise ValueError('Invalid output device UID')
    if requested_uid is None:
        if not outputs:raise RuntimeError('No compatible 48 kHz AC-3 output is connected')
        if len(outputs)!=1:raise RuntimeError('Multiple compatible outputs are connected; select an output device')
        selected=outputs[0]
    else:
        selected=next((item for item in outputs if item['uid']==requested_uid),None)
        if selected is None:raise RuntimeError('The selected output is disconnected or does not support the required 48 kHz AC-3 carrier')
    if not selected['available']:
        reason=selected.get('unavailable_reason')
        if reason in ('device_occupied','device_active_output'):
            raise RuntimeError(selected['name']+' is in use. Stop its other player, then retry.')
        raise RuntimeError(selected['name']+' is currently unavailable'+(': '+reason if reason else ''))
    return dict(selected)

def encoder_command(ffmpeg_path):
    return [str(ffmpeg_path),'-hide_banner','-nostdin','-loglevel','error',
        '-f','wav','-ignore_length','1','-max_size','36864','-probesize','32','-analyzeduration','0','-i','pipe:0',
        '-map','0:a:0','-c:a','ac3','-b:a','448k','-ar','48000','-dialnorm','-31','-map_metadata','-1',
        '-flush_packets','1','-f','spdif','pipe:1']
def atomic_json(path,value):
    temporary=path.with_name(path.name+'.writing-'+str(os.getpid()))
    with temporary.open('w') as f:json.dump(value,f,allow_nan=False,separators=(',',':'));f.write('\n')
    os.replace(temporary,path)
def read_exact(stream,count):
    out=[]
    while count:
        b=stream.read(count)
        if not b:break
        out.append(b);count-=len(b)
    return b''.join(out)
def write_all(stream,data):
    view=memoryview(data)
    while view:
        n=os.write(stream.fileno(),view)
        if n<=0:raise OSError('Pipe write made no progress')
        view=view[n:]
def stream_header():
    fmt=struct.pack('<HHIIHHHHI',0xfffe,6,48000,1152000,24,32,22,32,0x60f)
    fmt+=bytes.fromhex('0300000000001000800000aa00389b71')
    return b'RIFF'+struct.pack('<I',0xffffffff)+b'WAVEfmt '+struct.pack('<I',40)+fmt+b'data'+struct.pack('<I',0xffffffff)
def validate_burst(b):
    if len(b)!=BURST_BYTES:raise ValueError('Incomplete encoded burst')
    pa,pb,pc,pd=struct.unpack_from('<HHHH',b)
    if (pa,pb)!=(0xf872,0x4e1f) or pc&31!=1 or pd!=1792*8:raise ValueError('Invalid encoded carrier preamble')
    payload=bytearray(1792);payload[0::2]=b[9:1800:2];payload[1::2]=b[8:1800:2]
    if not (payload[:2]==b'\x0b\x77' and payload[4]>>6==0 and payload[4]&63==30 and
            payload[5]>>3<=10 and payload[6]>>5==7 and payload[6]&1==1 and not any(b[1800:])):
        raise ValueError('Encoder output is not the verified 48 kHz AC-3 3/2+LFE format')

def normalize_trims(values):
    if not isinstance(values,list) or len(values)!=6:raise ValueError('Six channel trims are required')
    result=[]
    for value in values:
        if value is None:result.append(None)
        elif type(value) in (int,float) and -60<=value<=6 and math.isfinite(value):result.append(float(value))
        else:raise ValueError('Each trim must be mute or a finite value from -60 to +6 dB')
    return result

def validate_trim_request(value,session_id,pid,min_revision=0):
    if not isinstance(value,dict) or type(value.get('schema_version')) is not int or value['schema_version']!=1:
        raise ValueError('Invalid trim request schema')
    if type(value.get('pid')) is not int or value['pid']!=pid or value.get('session_id')!=session_id:
        raise ValueError('Trim request belongs to another monitor session')
    revision=value.get('revision')
    if type(revision) is not int or not min_revision<revision<=9007199254740991:
        raise ValueError('Trim revision must be a newer positive safe integer')
    return revision,normalize_trims(value.get('trims_db'))

def trim_control_packet(revision,trims):
    mask=sum(1<<i for i,value in enumerate(trims) if value is None)
    return struct.pack('<8sQ6dII',b'FOITRM1\n',revision,*[0. if x is None else x for x in trims],mask,960)

class RotatingLog:
    """At most four MiB per child plus one rotated file; metadata only."""
    def __init__(self,path,limit=2*1024*1024):self.path=path;self.limit=limit;self.file=path.open('x');self.size=0
    def write(self,line):
        text=line[:65536]
        if self.size+len(text.encode('utf-8'))>self.limit:
            self.file.close();old=self.path.with_suffix(self.path.suffix+'.1')
            os.replace(self.path,old);self.file=self.path.open('w');self.size=0
        self.file.write(text);self.file.flush();self.size+=len(text.encode('utf-8'))
    def close(self):self.file.close()

class MetadataOutbox:
    """Nonblocking NDJSON: one partial line and one latest packet of each kind.

    Input telemetry and the slow status publisher share this writer. No reader
    backlog can block PCM delivery or create an unbounded metadata queue.
    """
    MAX_LINE_BYTES=32768
    def __init__(self,write=None):
        self.write=write or (lambda data:os.write(sys.stdout.fileno(),data))
        self.lock=threading.Lock();self.latest={};self.active=b'';self.offset=0;self.kind=None;self.closed=False
        self.counts={'meter_packets_sent':0,'status_packets_sent':0,'meter_packets_replaced':0,
                     'write_would_block':0,'stdout_closed':0,'bytes_sent':0}
    def offer(self,kind,value):
        if kind not in ('meter','status'):raise ValueError('Unknown metadata packet kind')
        line=(json.dumps(value,separators=(',',':'),allow_nan=False)+'\n').encode()
        if len(line)>self.MAX_LINE_BYTES:raise ValueError('Metadata packet exceeds bounded line size')
        with self.lock:
            if self.closed:return
            if self.active and self.kind==kind and self.offset==0:
                if kind=='meter':self.counts['meter_packets_replaced']+=1
                self.active=line
            else:
                if kind=='meter' and kind in self.latest:self.counts['meter_packets_replaced']+=1
                self.latest[kind]=line
    def flush(self):
        with self.lock:
            for _ in range(4):
                if self.closed:return
                if not self.active:
                    self.kind=next((kind for kind in ('status','meter') if kind in self.latest),None)
                    if self.kind is None:return
                    self.active=self.latest.pop(self.kind);self.offset=0
                try:n=self.write(self.active[self.offset:])
                except BlockingIOError:self.counts['write_would_block']+=1;return
                except BrokenPipeError:
                    self.closed=True;self.counts['stdout_closed']=1;self.active=b'';self.offset=0;self.kind=None;self.latest.clear();return
                except InterruptedError:return
                if n<=0:raise OSError('Metadata pipe write made no progress')
                self.offset+=n;self.counts['bytes_sent']+=n
                if self.offset==len(self.active):
                    self.counts[self.kind+'_packets_sent']+=1;self.active=b'';self.offset=0
    def snapshot(self):
        with self.lock:
            return {**self.counts,'buffered_bytes':len(self.active)-self.offset+sum(map(len,self.latest.values()))}

class Monitor:
    def __init__(self,args,*,test_commands=None,test_cleanup_seconds=None):
        self.args=args;self.testing=test_commands is not None;self.test_commands=test_commands
        self.root=ROOT;self.session=Path(args.session_dir).resolve();self.status_path=Path(args.status_json).resolve()
        self.requested_output_uid=getattr(args,'output_device',None)
        self.output_uid=self.requested_output_uid;self.output_name='Output not selected'
        self.stop_file=Path(args.stop_file).resolve();self.parent_pid=getattr(args,'parent_pid',None)
        self.cleanup_seconds=test_cleanup_seconds or 15.0
        # Keep the established lock name so older/private and public app builds
        # cannot own a live bridge concurrently, even with distinct app IDs.
        self.lock_path=(self.session.parent/'offline-test.lock') if self.testing else Path('/tmp')/(SHARED_LOCK_PREFIX+str(os.getuid())+'.lock')
        self.lock_fd=None;self.locked=False;self.owned_session=False;self.lock=threading.RLock();self.stop=threading.Event();self.publisher_done=threading.Event()
        self.children={};self.logs={};self.log_threads=[];self.pumps=[];self.process_records=[]
        self.errors=[];self.forced=[];self.summaries={};self.events={};self.native_levels={};self.diagnostics={};self.input_stop_sent=False
        self.level_event_sequence=0;self.sample_clip_last_event=[0]*6
        self.outbox=MetadataOutbox();self.last_input_block_log=None
        self.input_block_logs_written=0;self.input_block_logs_suppressed=0;self.meter_invalid_windows=0
        self.trim_requested_revision=0;self.trim_applied_revision=0;self.trim_requested=[0.]*6;self.trim_applied=[0.]*6
        self.trim_error=None;self.trim_pending=None;self.trim_sent={};self.trim_file_identity=None
        self.trim_rejected_requests=0;self.trim_write_would_block=0;self.trim_native_ack_frame=None
        self.input_ready=None;self.sink_ready=None;self.input_spawn_host=None;self.sink_start_host=None
        self.pcm_blocks=0;self.encoded_bursts=0;self.first_pcm_host=None;self.last_pcm_host=None;self.last_encoded_host=None
        self.pcm_eof=False;self.encoded_eof=False;self.stop_reason=None;self.stop_at=None;self.state='starting';self.phase='locking'
        self.message='Starting monitor';self.started=time.monotonic();self.started_host=host_ns()
        self.output_started=False;self.queue_ms=None;self.verifier=None;self.runtime_info={}
        self.cleanup={'complete':False,'children_reaped':False,'input_stopped':False,'output_restored':False}

    def prepare(self):
        if self.status_path.parent!=self.session or self.stop_file.parent!=self.session:
            raise ValueError('Status and stop files must be inside this new session directory')
        if self.status_path.name!='status.json' or self.stop_file.name!='stop.request':
            raise ValueError('Session status and stop filenames must be status.json and stop.request')
        self.session.parent.mkdir(parents=True,exist_ok=True)
        if self.session.exists():
            entries=list(self.session.iterdir()) if self.session.is_dir() else [self.session]
            if entries and not (entries==[self.stop_file] and self.stop_file.is_file() and not self.stop_file.is_symlink()):
                raise ValueError('Session directory must be new and empty')
        else:self.session.mkdir(mode=0o700)
        self.owned_session=True
        flags=os.O_RDWR|os.O_CREAT|getattr(os,'O_NOFOLLOW',0)
        self.lock_fd=os.open(self.lock_path,flags,0o600)
        info=os.fstat(self.lock_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():raise ValueError('Unsafe monitor lock file')
        try:fcntl.flock(self.lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('Another monitor instance is already running')
        self.locked=True;os.ftruncate(self.lock_fd,0);os.write(self.lock_fd,str(os.getpid()).encode())
        if self.parent_pid is not None and self.parent_pid!=os.getppid():raise RuntimeError('The launching app is no longer the parent process')
        if not self.testing:
            hashes=verify_runtime(self.root)
            selected=select_output(discover_outputs(self.root,verify=False),self.requested_output_uid)
            self.output_uid=selected['uid'];self.output_name=selected['name']
            self.runtime_info={'files':{name:{'path':str(self.root/name),'sha256':hashes[name]} for name in REQUIRED_FILES},
              'manifest_sha256':sha(self.root/'backend_manifest.json'),'timebase_numer':_tb.numer,'timebase_denom':_tb.denom,
              'input_uid':INPUT_UID,'output_uid':self.output_uid,'output_name':self.output_name,'channel_order':ORDER,'sample_rate':48000,
              'clock':'raw mach_absolute_time nanoseconds','session_dir':str(self.session)}
            app=next((p for p in self.root.parents if p.suffix=='.app'),None)
            self.runtime_info['app_path']=str(app) if app else None
            if app:
                with (app/'Contents/Info.plist').open('rb') as f:app_info=plistlib.load(f)
                app_binary=app/'Contents/MacOS'/app_info['CFBundleExecutable']
                self.runtime_info['app_executable']={'path':str(app_binary),'sha256':sha(app_binary)}
        else:self.runtime_info={'offline_test':True,'clock':'raw mach_absolute_time nanoseconds'}
        atomic_json(self.session/'session.json',{'schema_version':1,'pid':os.getpid(),'started_host_ns':self.started_host,
          'mode':'offline_test' if self.testing else 'continuous_monitor','runtime':self.runtime_info,
          'audio_recording_enabled':self.verifier is not None,'normal_recording_policy':'metadata only; no PCM or carrier capture'})

    def input_snapshot(self):
        with self.lock:
            peak=self.native_levels.get('peak',[0.]*6);rms=self.native_levels.get('rms',[0.]*6)
            def levels(a):return [max(-120.,20*math.log10(max(float(x),1e-6))) for x in a]
            return {'uid':INPUT_UID,'name':'BlackHole 16ch','sample_rate':48000,'channels':6,'channel_order':ORDER,
                'peak_dbfs':levels(peak),'rms_dbfs':levels(rms),'signal_present':max(peak,default=0)>.000316228,
                'sample_clip_last_event':list(self.sample_clip_last_event),
                'blocks':self.pcm_blocks,'sample_frames':self.pcm_blocks*FRAMES,'level_first_frame':self.native_levels.get('first_frame'),
                'level_frames':self.native_levels.get('frames'),'level_received_host_ns':self.native_levels.get('received_host_ns'),
                'native_write_completed_host_ns':self.native_levels.get('write_completed_host_ns'),
                'meter_stage':self.native_levels.get('meter_stage','input'),
                'protected_samples':list(self.native_levels.get('protected_samples',[0]*6)),
                'protected_samples_total':list(self.native_levels.get('protected_samples_total',[0]*6))}
    def trim_snapshot(self):
        with self.lock:
            return {'requested_revision':self.trim_requested_revision,'applied_revision':self.trim_applied_revision,
                'requested_trims_db':list(self.trim_requested),'applied_trims_db':list(self.trim_applied),
                'ramp_frames':960,'error':self.trim_error,'native_ack_after_frame':self.trim_native_ack_frame,
                'rejected_requests':self.trim_rejected_requests,'write_would_block':self.trim_write_would_block}
    def snapshot(self):
        with self.lock:
            return {'schema_version':1,'session_id':self.session.name,'pid':os.getpid(),'state':self.state,'phase':self.phase,
              'message':self.message,'ready':self.state=='running','elapsed_seconds':round(time.monotonic()-self.started,3),
              'host_ns':host_ns(),'mode':'offline_test' if self.testing else 'continuous_monitor',
              'input':self.input_snapshot(),'trim':self.trim_snapshot(),
              'meter_transport':{**self.outbox.snapshot(),'native_windows_received':self.level_event_sequence,
                'input_block_logs_written':self.input_block_logs_written,'input_block_logs_suppressed':self.input_block_logs_suppressed,
                'invalid_fast_windows':self.meter_invalid_windows,'source_window_frames':FRAMES,'nominal_source_hz':48000/FRAMES},
              'encoder':{'codec':'AC-3','sample_rate':48000,'channels':6,'bitrate':448000,'frames':self.encoded_bursts},
              'output':{'uid':self.output_uid,'name':self.output_name,'queue_ms':self.queue_ms,'started':self.output_started},
              'stop_reason':self.stop_reason,'errors':self.errors[-8:],'cleanup':dict(self.cleanup),
              'verification_enabled':self.verifier is not None}

    def publish(self):
        status=self.snapshot();atomic_json(self.status_path,status)
        self.outbox.offer('status',status);self.outbox.flush()
        return status
    def publish_meter(self):
        with self.lock:
            if not self.level_event_sequence:return
            first=self.native_levels.get('first_frame')
            if type(first) is not int or first<0 or self.native_levels.get('frames')!=FRAMES:
                self.meter_invalid_windows+=1;return
            packet={'schema_version':1,'type':'meter','pid':os.getpid(),'session_id':self.session.name,
                    'host_ns':host_ns(),'level_sequence':self.level_event_sequence,'input':self.input_snapshot(),'trim':self.trim_snapshot()}
        self.outbox.offer('meter',packet);self.outbox.flush()
    def publisher(self):
        while not self.publisher_done.is_set():
            try:self.publish()
            except (OSError,ValueError) as e:self.fail('Could not publish monitor status: '+str(e))
            self.publisher_done.wait(.25)

    def request_stop(self,reason):
        with self.lock:
            if not self.stop.is_set():
                self.stop_reason=reason;self.stop_at=time.monotonic();self.stop.set()
                self.trim_pending=None
                self.state='stopping';self.phase='draining';self.message='Stopping input and draining audio'
        p=self.children.get('input')
        input_can_stop=(self.input_ready is not None or ('input','configuration') in self.events
          or self.events.get(('input','process_started'),{}).get('signal_handlers_ready') is True)
        if p and p.poll() is None and not self.input_stop_sent and input_can_stop:
            try:p.terminate();self.input_stop_sent=True
            except ProcessLookupError:pass
            except OSError as e:self.add_error('Could not request input stop: '+str(e))
    def add_error(self,message):
        with self.lock:
            if message not in self.errors:self.errors.append(message[:1000])
    def fail(self,message):self.add_error(message);self.request_stop('error')

    def handle_event(self,name,event):
        measured_levels=False
        with self.lock:
            kind=event.get('event')
            self.events[(name,kind)]=event
            if kind=='summary':self.summaries[name]=event
            if name=='input' and kind=='trim_applied':
                try:
                    revision=event.get('revision');trims=normalize_trims(event.get('trims_db'))
                    if type(revision) is not int or revision<=0:raise ValueError('Invalid native trim revision')
                    if revision>self.trim_applied_revision:
                        if self.trim_sent.get(revision)!=trims:raise ValueError('Native trim acknowledgement does not match a sent command')
                        self.trim_applied_revision=revision;self.trim_applied=trims
                        self.trim_native_ack_frame=event.get('completed_after_frame')
                        self.trim_sent={r:v for r,v in self.trim_sent.items() if r>revision}
                        if revision==self.trim_requested_revision:self.trim_error=None
                except ValueError as e:self.trim_error=str(e)
            if name=='input' and kind=='trim_rejected':self.trim_error='Native trim control rejected: '+str(event.get('reason','invalid packet'))
            if name=='input' and kind in ('block_written','final_levels'):
                peak=event.get('peak',event.get('peak_linear'));rms=event.get('rms',event.get('rms_linear'))
                if isinstance(peak,list) and isinstance(rms,list) and len(peak)==len(rms)==6:
                    if all(isinstance(x,(int,float)) and math.isfinite(x) and x>=0 for x in peak+rms):
                        self.native_levels={'peak':peak,'rms':rms,'first_frame':event.get('level_first_frame'),'frames':event.get('level_frames'),
                          'received_host_ns':host_ns(),'write_completed_host_ns':event.get('write_completed_host_ns'),
                          'meter_stage':event.get('meter_stage','input')}
                        for key in ('protected_samples','protected_samples_total'):
                            values=event.get(key)
                            if isinstance(values,list) and len(values)==6 and all(type(x) is int and x>=0 for x in values):self.native_levels[key]=values
                        measured_levels=True
                        # Preserve clip evidence when a later window replaces these levels
                        # before publication or UI polling. Markers live for this session;
                        # a UI reset acknowledges them without clearing backend evidence.
                        self.level_event_sequence+=1
                        for channel,value in enumerate(peak):
                            if value>=1.:self.sample_clip_last_event[channel]=self.level_event_sequence
            if name=='sink':
                if kind=='audio_start_return' or (kind=='stage' and event.get('stage')=='audio_start_return'):
                    self.output_started=True;self.sink_start_host=event.get('host_ns')
                queue=event.get('queue_after_bytes',event.get('queue_bytes'))
                if isinstance(queue,(int,float)):self.queue_ms=queue/192.
        if name=='sink' and self.verifier:
            try:self.verifier.note_sink_event(event)
            except Exception as e:self.fail('Scratch verification metadata failed: '+str(e))
        if name=='input' and self.stop.is_set():self.request_stop(self.stop_reason or 'shutdown')
        return measured_levels

    def consume_log_line(self,name,line):
        event=None
        if line.startswith('{'):
            try:event=json.loads(line)
            except (ValueError,TypeError):pass
        measured_levels=self.handle_event(name,event) if isinstance(event,dict) else False
        if measured_levels:self.publish_meter()
        # Every native window reaches memory/stdout. Normal disk diagnostics
        # sample block metadata at <=4 Hz; faults, setup and summaries are kept.
        keep=True
        if name=='input' and isinstance(event,dict) and event.get('event')=='block_written':
            now=time.monotonic()
            keep=self.last_input_block_log is None or now-self.last_input_block_log>=.25
            with self.lock:
                if keep:self.last_input_block_log=now;self.input_block_logs_written+=1
                else:self.input_block_logs_suppressed+=1
        if keep:self.logs[name].write(line)
        if line.strip() and not line.startswith('{'):self.diagnostics[name]=line.strip()[:1000]

    def drain_log(self,name,p):
        try:
            for raw in iter(p.stderr.readline,b''):
                self.consume_log_line(name,raw.decode('utf-8','replace'))
        except Exception as e:self.fail(name+' diagnostic reader failed: '+str(e))

    def spawn(self,name,command,**kwargs):
        self.logs[name]=RotatingLog(self.session/(name+'.log'))
        p=subprocess.Popen(command,stderr=subprocess.PIPE,bufsize=0,start_new_session=True,**kwargs)
        self.children[name]=p;self.process_records.append({'name':name,'pid':p.pid,'command':command,'spawned_host_ns':host_ns()})
        atomic_json(self.session/'processes.json',self.process_records)
        thread=threading.Thread(target=self.drain_log,args=(name,p),daemon=True);thread.start();self.log_threads.append(thread)
        return p

    def wait_ready(self,path,p,event,timeout=8):
        until=time.monotonic()+timeout
        while not path.exists():
            self.check_external_stop()
            if self.stop.is_set():raise InterruptedError('Start cancelled')
            if p.poll() is not None:
                name='sink' if event=='device_ready' else 'input'
                for t in self.log_threads:t.join(timeout=.05)
                raise RuntimeError(self.failure_message(name,'failed before readiness'))
            if time.monotonic()>until:raise RuntimeError(event+' timed out; the device may be unavailable or require permission')
            time.sleep(.02)
        ready=json.loads(path.read_text())
        if p.poll() is not None or ready.get('event')!=event or ready.get('ready') is not True or ready.get('pid')!=p.pid:
            raise RuntimeError('Invalid native readiness handshake')
        return ready
    def failure_message(self,name,fallback):
        summary=self.summaries.get(name,{})
        reason=summary.get('failure_reason')
        known={'device_occupied':'The selected output is occupied. Stop its other player, then retry.',
          'device_active_output':'The selected output has active output. Stop its other player, then retry.',
          'device_unavailable':'The selected output is unavailable. Reconnect it, then retry.',
          'unsupported_encoded_format':'The selected output does not currently expose the required 48 kHz encoded AC-3 format.',
          'input_underrun':'HDMI ran out of encoded audio; monitoring stopped.',
          'external_format_change':'The HDMI format changed during monitoring; monitoring stopped.'}
        if reason in known:return known[reason]
        if name=='input' and summary.get('invalid_sample_events',0)>0:
            return 'BlackHole input exceeded nominal full scale or contained nonfinite samples. Lower the Fairlight bus level, then retry; no automatic gain is applied.'
        preflight=self.events.get((name,'preflight_exit'),{})
        detail=reason if reason and reason!='none' else preflight.get('reason',self.diagnostics.get(name))
        return name+' '+fallback+(': '+detail if detail else '')
    def primary_error(self):
        if self.summaries.get('input',{}).get('invalid_sample_events',0)>0:
            return self.failure_message('input','stopped')
        if self.summaries.get('sink',{}).get('failure_reason') not in (None,'none','runtime_failure'):
            return self.failure_message('sink','stopped')
        return self.errors[0] if self.errors else 'Monitor stopped'
    def check_external_stop(self):
        if self.stop_file.exists():self.request_stop('stop_file')
        if self.parent_pid is not None and os.getppid()!=self.parent_pid:self.request_stop('parent_exited')

    def poll_trim_request(self):
        if self.stop.is_set():return
        path=self.session/'trim.request.json'
        try:
            info=path.lstat();identity=(info.st_ino,info.st_mtime_ns,info.st_size)
            if identity!=self.trim_file_identity:
                self.trim_file_identity=identity
                if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or not 0<info.st_size<=4096:
                    raise ValueError('Trim request must be a bounded regular session file')
                fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|getattr(os,'O_NOFOLLOW',0))
                try:
                    opened=os.fstat(fd)
                    if not stat.S_ISREG(opened.st_mode) or opened.st_uid!=os.getuid() or opened.st_size>4096:
                        raise ValueError('Trim request file changed during validation')
                    raw=os.read(fd,4097)
                    self.trim_file_identity=(opened.st_ino,opened.st_mtime_ns,opened.st_size)
                finally:os.close(fd)
                if len(raw)>4096:raise ValueError('Trim request is too large')
                value=json.loads(raw)
                with self.lock:
                    revision,trims=validate_trim_request(value,self.session.name,os.getpid(),self.trim_requested_revision)
                    self.trim_requested_revision=revision;self.trim_requested=trims;self.trim_error=None
                    self.trim_pending=(revision,trims,trim_control_packet(revision,trims))
        except FileNotFoundError:pass
        except (OSError,ValueError,TypeError,OverflowError,RecursionError) as e:
            with self.lock:self.trim_error=str(e)[:300];self.trim_rejected_requests+=1
        source=self.children.get('input')
        with self.lock:
            if self.stop.is_set() or not self.trim_pending or not source or not source.stdin or len(self.trim_sent)>=16:return
            revision,trims,packet=self.trim_pending
            try:
                # 72 bytes is below PIPE_BUF: this nonblocking pipe write is
                # atomic, so EAGAIN keeps the complete latest command pending.
                n=os.write(source.stdin.fileno(),packet)
                if n!=len(packet):raise OSError('Incomplete native trim control write')
                self.trim_sent[revision]=list(trims);self.trim_pending=None
            except BlockingIOError:self.trim_write_would_block+=1
            except (OSError,ValueError) as e:self.trim_error='Trim control unavailable: '+str(e);self.trim_pending=None

    def commands(self):
        if self.testing:return self.test_commands(self.session)
        return {
          'sink':[str(self.root/'coreaudio_ac3_monitor_sink'),'--continuous','--device',self.output_uid,
                  '--ready-file',str(self.session/'sink_ready.json'),'--telemetry','-','--prebuffer-bursts','2'],
          'input':[str(self.root/'auhal_input_continuous'),'--capture','--continuous','--raw','--device-uid',INPUT_UID,
                   '--ready-file',str(self.session/'input_ready.json'),'--telemetry','-','--telemetry-every-blocks','1','--peak-limit','1.0','--trim-control-stdin'],
          'encoder':encoder_command(self.root/'ffmpeg')}

    def pump_pcm(self):
        source=self.children['input'];encoder=self.children['encoder']
        try:
            while True:
                data=read_exact(source.stdout,PCM_BYTES)
                if not data:break
                if len(data)!=PCM_BYTES:raise ValueError('Native input ended with an incomplete PCM block')
                received=host_ns();write_all(encoder.stdin,data)
                with self.lock:
                    self.pcm_blocks+=1;self.last_pcm_host=received
                    if self.first_pcm_host is None:self.first_pcm_host=received
            if not self.stop.is_set():self.fail('Native input ended unexpectedly')
        except Exception as e:self.fail('PCM relay failed: '+str(e))
        finally:
            self.pcm_eof=True
            try:encoder.stdin.close()
            except (BrokenPipeError,OSError):pass

    def pump_encoded(self):
        encoder=self.children['encoder'];sink=self.children['sink']
        try:
            while True:
                data=read_exact(encoder.stdout,BURST_BYTES)
                if not data:break
                received=host_ns();validate_burst(data);write_all(sink.stdin,data);sent=host_ns()
                with self.lock:
                    index=self.encoded_bursts;self.encoded_bursts+=1;self.last_encoded_host=received
                if self.verifier:self.verifier.note_packet(data,index,received,sent)
            if not self.stop.is_set():self.fail('Encoder output ended unexpectedly')
        except Exception as e:self.fail('Encoded relay failed: '+str(e))
        finally:
            self.encoded_eof=True
            try:sink.stdin.close()
            except (BrokenPipeError,OSError):pass

    def start(self):
        self.check_external_stop()
        if self.stop.is_set():raise InterruptedError('Start cancelled')
        command=self.commands();self.phase='preparing_output';self.message='Preparing encoded HDMI output'
        sink=self.spawn('sink',command['sink'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL)
        self.sink_ready=self.wait_ready(self.session/'sink_ready.json',sink,'device_ready')
        s=self.sink_ready
        if not (s.get('continuous') is True and s.get('device_uid')==self.output_uid and s.get('format')=='cac3' and s.get('carrier_sample_rate')==48000
                and s.get('required_encoded_channels')==6 and s.get('prebuffer_bursts')==2
                and s.get('input_read') is False and s.get('audio_device_started') is False):raise RuntimeError('HDMI readiness format mismatch')
        self.check_external_stop()
        if self.stop.is_set():raise InterruptedError('Start cancelled')
        self.phase='preparing_input';self.message='Starting BlackHole input'
        encoder=self.spawn('encoder',command['encoder'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        write_all(encoder.stdin,stream_header())
        source=self.spawn('input',command['input'],stdin=subprocess.PIPE,stdout=subprocess.PIPE);self.input_spawn_host=host_ns()
        os.set_blocking(source.stdin.fileno(),False)
        self.input_ready=self.wait_ready(self.session/'input_ready.json',source,'capture_ready')
        s=self.input_ready
        if not (s.get('backend')=='auhal_input_continuous' and s.get('continuous') is True
                and s.get('device_uid')==INPUT_UID and s.get('device_name')=='BlackHole 16ch'
                and s.get('input_channels')==16 and s.get('output_channels')==6 and s.get('sample_rate')==48000
                and s.get('block_frames')==FRAMES and s.get('raw_output') is True and s.get('capture_started') is True):
            raise RuntimeError('BlackHole readiness format mismatch')
        if s['first_callback_host_ns']<self.sink_ready['ready_host_ns']:raise RuntimeError('Input started before HDMI preparation')
        self.start_relays()

    def start_relays(self):
        for function in (self.pump_encoded,self.pump_pcm):
            t=threading.Thread(target=function,daemon=True);t.start();self.pumps.append(t)

    def run_loop(self):
        while True:
            self.check_external_stop()
            if self.stop.is_set():break
            self.poll_trim_request()
            for name,p in list(self.children.items()):
                if p.poll() is not None:self.fail(self.failure_message(name,'exited unexpectedly ('+str(p.returncode)+')'))
            if self.output_started and self.encoded_bursts:
                self.state='running';self.phase='monitoring';self.message='Monitoring six-channel audio'
            now=host_ns()
            if self.input_spawn_host and now-(self.last_pcm_host or self.input_spawn_host)>5000000000:
                self.fail('Input or encoder made no progress for five seconds')
            if self.last_pcm_host and self.last_encoded_host and self.last_pcm_host-self.last_encoded_host>2000000000:
                self.fail('Encoder delivery stalled')
            time.sleep(.05)

    def cleanup_children(self):
        self.request_stop(self.stop_reason or ('error' if self.errors else 'shutdown'))
        source=self.children.get('input')
        if source and source.stdin:
            try:source.stdin.close()
            except OSError:pass
        deadline=time.monotonic()+self.cleanup_seconds
        # Before relays exist, this thread owns EOF. Once running their finally
        # blocks close downstream writers after draining complete PCM/AC-3.
        if not self.pumps and not self.errors and all(name in self.children for name in ('input','encoder','sink')):
            self.start_relays()
        if not self.pumps:
            for name in ('encoder','sink'):
                p=self.children.get(name)
                if p and p.stdin:
                    try:p.stdin.close()
                    except OSError:pass
        while time.monotonic()<deadline:
            if all(p.poll() is not None for p in self.children.values()) and not any(t.is_alive() for t in self.pumps):break
            time.sleep(.05)
        self.phase='restoring';self.message='Finishing native device cleanup'
        for name,p in reversed(list(self.children.items())):
            if p.poll() is None:
                self.add_error(name+' did not finish graceful cleanup in time')
                try:p.terminate()
                except (ProcessLookupError,OSError):pass
        grace=time.monotonic()+2
        for name,p in self.children.items():
            if p.poll() is None:
                try:p.wait(timeout=max(.01,grace-time.monotonic()))
                except subprocess.TimeoutExpired:
                    self.forced.append(name);self.add_error(name+' required a forced stop; restoration may be incomplete')
                    try:p.kill();p.wait(timeout=1)
                    except (OSError,subprocess.TimeoutExpired):self.add_error(name+' could not be confirmed stopped')
        for t in self.pumps+self.log_threads:t.join(timeout=.5)
        self.cleanup['children_reaped']=all(p.poll() is not None for p in self.children.values())
        native=self.summaries.get('input');sink=self.summaries.get('sink')
        if 'input' not in self.children:self.cleanup['input_stopped']=True
        elif native:
            self.cleanup['input_stopped']=all(native.get(k) is True for k in ('cleanup_stop_ok','cleanup_destroy_ok','cleanup_listeners_ok'))
        elif self.events.get(('input','preflight_exit'),{}).get('io_created') is False:
            self.cleanup['input_stopped']=self.children['input'].poll() is not None
        if 'sink' not in self.children:self.cleanup['output_restored']=True
        elif sink:
            self.cleanup['output_restored']=(sink.get('cleanup_complete') is True
              and all(sink.get(k) in ('pass','not_needed','not_touched') for k in ('restore_physical','restore_virtual'))
              and sink.get('release_exclusive') in ('pass','not_needed','not_acquired')
              and all(sink.get(k) is True for k in ('io_stop_ok','io_destroy_ok','callbacks_quiescent')))
        self.cleanup['complete']=all(self.cleanup[k] for k in ('children_reaped','input_stopped','output_restored'))
        if self.forced or any(t.is_alive() for t in self.pumps):self.cleanup['complete']=False

    def verify_completion(self):
        native=self.summaries.get('input');sink=self.summaries.get('sink')
        for name,p in self.children.items():
            if p.returncode!=0:self.add_error(self.failure_message(name,'exited with status '+str(p.returncode)))
        if self.input_ready:
            if not native or native.get('success') is not True or native.get('requested_stop') is not True:
                self.add_error('Input did not confirm a clean requested stop')
            else:
                for k in ('overflow_events','dropped_frames','input_stalls','underrun_events','discontinuity_events','invalid_sample_events','invalid_timestamp_events','fatal_code','undelivered_complete_blocks'):
                    if native.get(k)!=0:self.add_error('Input failure counter: '+k)
                if native.get('written_blocks')!=self.pcm_blocks or native.get('written_frames')!=self.pcm_blocks*FRAMES:
                    self.add_error('Captured PCM delivery count mismatch')
                au=self.events.get(('input','auhal_cleanup'),{})
                if not all(au.get(k) is True for k in ('stop_ok','uninitialize_ok','dispose_ok','callbacks_quiescent')) or au.get('render_failures')!=0 or au.get('last_render_status')!=0:
                    self.add_error('AUHAL cleanup or render status failed')
        if self.encoded_bursts!=self.pcm_blocks:self.add_error('PCM-to-AC-3 frame count mismatch')
        if self.sink_ready:
            if not sink:self.add_error('HDMI sink final summary missing')
            else:
                for k in ('underrun_events','underrun_missing_bytes','faultcode','telemetry_dropped'):
                    if sink.get(k)!=0:self.add_error('HDMI failure counter: '+k)
                if sink.get('accepted_bursts')!=self.encoded_bursts or sink.get('output_bytes')!=self.encoded_bursts*BURST_BYTES:
                    self.add_error('HDMI delivery count mismatch')
        if not self.cleanup['complete']:self.add_error('Native cleanup or restoration was not fully confirmed')

    def execute(self):
        previous={s:signal.signal(s,lambda signum,frame:self.request_stop('signal_'+str(signum))) for s in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP)}
        publisher=None
        try:
            self.prepare();os.set_blocking(sys.stdout.fileno(),False)
            publisher=threading.Thread(target=self.publisher,daemon=True);publisher.start()
            self.start();self.run_loop()
        except InterruptedError:
            self.request_stop(self.stop_reason or 'start_cancelled')
        except Exception as e:self.fail(str(e))
        finally:
            if self.owned_session:
                self.cleanup_children();self.verify_completion()
                self.state='failed' if self.errors else 'stopped';self.phase='done'
                self.message=(self.primary_error() if self.cleanup['complete'] else 'Cleanup needs attention: '+self.primary_error()) if self.errors else 'Monitor stopped and devices restored'
                self.publisher_done.set()
                if publisher:publisher.join(timeout=1)
                status=self.snapshot()
                if self.verifier:
                    try:self.verifier.finish(status)
                    except Exception as e:
                        self.add_error('Scratch verification finalization failed: '+str(e));self.state='failed';self.message=self.errors[-1];status=self.snapshot()
                result={**status,'started_host_ns':self.started_host,'finished_host_ns':host_ns(),
                  'input_ready':self.input_ready,'sink_ready':self.sink_ready,'native_summary':self.summaries.get('input'),
                  'auhal_cleanup':self.events.get(('input','auhal_cleanup')),'sink_summary':self.summaries.get('sink'),
                  'children_returncodes':{name:p.returncode for name,p in self.children.items()},'forced_stops':self.forced,
                  'pcm_blocks_forwarded':self.pcm_blocks,'encoded_bursts':self.encoded_bursts,
                  'runtime':self.runtime_info,'measurement_scope':'software and device scheduling; no acoustic latency claim'}
                try:atomic_json(self.session/'result.json',result);self.publish()
                except Exception as e:print('Final status write failed: '+str(e),file=sys.stderr)
            else:
                self.cleanup={k:True for k in self.cleanup};self.state='failed';self.phase='done';self.message=self.errors[-1] if self.errors else 'Session refused'
                try:print(json.dumps(self.snapshot(),separators=(',',':')),flush=True)
                except OSError:pass
            for log in self.logs.values():
                try:log.close()
                except Exception:pass
            if self.lock_fd is not None:
                if self.locked:fcntl.flock(self.lock_fd,fcntl.LOCK_UN)
                os.close(self.lock_fd)
            for s,handler in previous.items():signal.signal(s,handler)
        return 1 if self.errors else 0

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--list-outputs',action='store_true',help='Read-only compatible-output inventory; JSON on stdout')
    ap.add_argument('--output-device',help='Exact output UID; omit only when one compatible output is connected')
    ap.add_argument('--session-dir',type=Path)
    ap.add_argument('--status-json',type=Path)
    ap.add_argument('--stop-file',type=Path)
    ap.add_argument('--parent-pid',type=int)
    args=ap.parse_args()
    if args.list_outputs:
        if any(x is not None for x in (args.output_device,args.session_dir,args.status_json,args.stop_file,args.parent_pid)):
            ap.error('--list-outputs cannot be combined with session or selection arguments')
        try:
            print(json.dumps({'schema_version':1,'outputs':discover_outputs(ROOT)},separators=(',',':'),allow_nan=False))
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:
            print(json.dumps({'schema_version':1,'outputs':[],'error':str(e)[:1000]},separators=(',',':')))
            raise SystemExit(1)
        return
    if any(x is None for x in (args.session_dir,args.status_json,args.stop_file)):
        ap.error('--session-dir, --status-json and --stop-file are required for monitoring')
    if args.output_device is not None and not valid_output_uid(args.output_device):ap.error('Invalid output device UID')
    if args.parent_pid is not None and args.parent_pid<=1:ap.error('Invalid parent PID')
    raise SystemExit(Monitor(args).execute())

if __name__=='__main__':main()
