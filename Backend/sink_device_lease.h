/* Private sink lease state machine. All device operations are injected so
 * occupied/race/restoration cases can be tested without CoreAudio access. */
#ifndef SINK_DEVICE_LEASE_H
#define SINK_DEVICE_LEASE_H
typedef struct {
    bool identity_matches,alive,running;
    pid_t owner;
    AudioStreamBasicDescription physical,virtual_format;
} LeaseObservation;
typedef struct {
    bool (*read)(void *,LeaseObservation *);
    bool (*set_owner)(void *,pid_t);
    bool (*set_format)(void *,bool,const AudioStreamBasicDescription *);
    void (*pause)(void *);
    void *context;
} LeaseOperations;
enum LeaseResult {LEASE_OK,LEASE_UNAVAILABLE,LEASE_OCCUPIED,LEASE_ACTIVE_IO,LEASE_OWNER_CHANGED,LEASE_FORMAT_CONFLICT,LEASE_IO_NOT_QUIESCENT,LEASE_WRITE_FAILED};
typedef struct {
    pid_t pid;
    bool acquired,snapshot_valid,mutation_attempted,installed_verified;
    AudioStreamBasicDescription original_p,original_v,target_p,installed_p,installed_v;
} DeviceLease;
typedef struct {const char *physical,*virtual_format,*release;enum LeaseResult result;} LeaseCleanup;
static const char *lease_result_name(enum LeaseResult result){
    static const char *names[]={"none","device_unavailable","device_occupied","device_active_output","ownership_changed","external_format_change","io_not_quiescent","device_write_failed"};
    return (unsigned)result<sizeof(names)/sizeof(*names)?names[result]:"unknown";
}
static bool lease_same_format(const AudioStreamBasicDescription *a,const AudioStreamBasicDescription *b){
    return a->mSampleRate==b->mSampleRate&&a->mFormatID==b->mFormatID&&a->mFormatFlags==b->mFormatFlags&&a->mBytesPerPacket==b->mBytesPerPacket&&a->mFramesPerPacket==b->mFramesPerPacket&&a->mBytesPerFrame==b->mBytesPerFrame&&a->mChannelsPerFrame==b->mChannelsPerFrame&&a->mBitsPerChannel==b->mBitsPerChannel;
}
static bool lease_pair(const LeaseObservation *o,const AudioStreamBasicDescription *p,const AudioStreamBasicDescription *v){return lease_same_format(&o->physical,p)&&lease_same_format(&o->virtual_format,v);}
static enum LeaseResult lease_owned_read(DeviceLease *g,const LeaseOperations *ops,LeaseObservation *o){
    if(!ops->read(ops->context,o)||!o->identity_matches||!o->alive)return LEASE_UNAVAILABLE;
    return o->owner==g->pid?LEASE_OK:LEASE_OWNER_CHANGED;
}
static enum LeaseResult lease_acquire(DeviceLease *g,const LeaseOperations *ops){
    LeaseObservation before={0},after={0};
    if(!ops->read(ops->context,&before)||!before.identity_matches||!before.alive)return LEASE_UNAVAILABLE;
    if(before.owner!=-1)return LEASE_OCCUPIED;
    if(before.running)return LEASE_ACTIVE_IO;
    bool wrote=ops->set_owner(ops->context,g->pid);if(wrote)g->acquired=true;
    if(!ops->read(ops->context,&after)||!after.identity_matches||!after.alive)return LEASE_UNAVAILABLE;
    if(after.owner==g->pid)g->acquired=true;
    if(!wrote||after.owner!=g->pid)return after.owner!=-1&&after.owner!=g->pid?LEASE_OCCUPIED:LEASE_WRITE_FAILED;
    if(after.running)return LEASE_ACTIVE_IO;
    /* The baseline is captured only inside our verified ownership, never from
     * an earlier preflight observation that another application could change. */
    g->original_p=after.physical;g->original_v=after.virtual_format;g->snapshot_valid=true;
    g->installed_p=g->target_p;g->installed_v=g->target_p;
    return LEASE_OK;
}
static enum LeaseResult lease_wait_format(DeviceLease *g,const LeaseOperations *ops,bool physical,const AudioStreamBasicDescription *wanted){
    for(unsigned i=0;i<100;i++){
        LeaseObservation o={0};enum LeaseResult r=lease_owned_read(g,ops,&o);if(r!=LEASE_OK)return r;
        if(lease_same_format(physical?&o.physical:&o.virtual_format,wanted))return LEASE_OK;
        ops->pause(ops->context);
    }return LEASE_WRITE_FAILED;
}
static enum LeaseResult lease_install(DeviceLease *g,const LeaseOperations *ops){
    if(!g->acquired||!g->snapshot_valid)return LEASE_OWNER_CHANGED;
    LeaseObservation o={0};enum LeaseResult r=lease_owned_read(g,ops,&o);if(r!=LEASE_OK)return r;
    if(!lease_pair(&o,&g->original_p,&g->original_v))return LEASE_FORMAT_CONFLICT;
    if(lease_pair(&o,&g->target_p,&g->target_p)){g->installed_verified=true;return LEASE_OK;}
    g->mutation_attempted=true;
    if(!ops->set_format(ops->context,true,&g->target_p))return LEASE_WRITE_FAILED;
    return lease_wait_format(g,ops,true,&g->target_p);
}
static bool lease_release(DeviceLease *g,const LeaseOperations *ops,const char **status){
    LeaseObservation o={0};
    if(!ops->read(ops->context,&o)||!o.identity_matches||!o.alive){*status="skipped_device_unavailable";return false;}
    if(o.owner!=g->pid){*status="not_ours";return false;}
    if(!ops->set_owner(ops->context,-1)){*status="fail";return false;}
    if(!ops->read(ops->context,&o)||!o.identity_matches||o.owner==g->pid){*status="fail";return false;}
    *status="pass";g->acquired=false;return true;
}
static LeaseCleanup lease_cleanup(DeviceLease *g,const LeaseOperations *ops,bool io_quiescent){
    LeaseCleanup c={"not_touched","not_touched","not_acquired",LEASE_OK};
    if(!g->acquired)return c;
    if(!io_quiescent){c.physical=c.virtual_format="skipped_io_not_quiescent";c.release="deferred_to_process_exit";c.result=LEASE_IO_NOT_QUIESCENT;return c;}
    if(g->mutation_attempted){
        LeaseObservation o={0};c.result=lease_owned_read(g,ops,&o);
        if(c.result!=LEASE_OK){c.physical=c.virtual_format=c.result==LEASE_UNAVAILABLE?"skipped_device_unavailable":"skipped_not_owner";goto release;}
        if(lease_pair(&o,&g->original_p,&g->original_v)){c.physical=c.virtual_format="pass";goto release;}
        bool expected=lease_pair(&o,&g->installed_p,&g->installed_v);
        /* A failed physical setter can have left virtual unchanged. This is
         * the only additional known intermediate state accepted for rollback. */
        if(!g->installed_verified)expected=expected||lease_pair(&o,&g->target_p,&g->original_v);
        if(!expected){c.physical=c.virtual_format="skipped_external_change";c.result=LEASE_FORMAT_CONFLICT;goto release;}
        AudioStreamBasicDescription before_p=o.physical,before_v=o.virtual_format;
        LeaseObservation checked={0};c.result=lease_owned_read(g,ops,&checked);
        if(c.result!=LEASE_OK||!lease_pair(&checked,&before_p,&before_v)){if(c.result==LEASE_OK)c.result=LEASE_FORMAT_CONFLICT;c.physical=c.virtual_format="skipped_changed_before_restore";goto release;}
        if(!lease_same_format(&before_p,&g->original_p)){
            if(!ops->set_format(ops->context,true,&g->original_p)){c.physical="fail";c.virtual_format="skipped_physical_failed";c.result=LEASE_WRITE_FAILED;goto release;}
            c.result=lease_wait_format(g,ops,true,&g->original_p);if(c.result!=LEASE_OK){c.physical="fail";c.virtual_format="skipped_physical_failed";goto release;}
        }c.physical="pass";
        c.result=lease_owned_read(g,ops,&o);if(c.result!=LEASE_OK){c.virtual_format="skipped_unavailable_or_owner_changed";goto release;}
        if(!lease_same_format(&o.physical,&g->original_p)){c.virtual_format="skipped_external_change";c.result=LEASE_FORMAT_CONFLICT;goto release;}
        if(lease_same_format(&o.virtual_format,&g->original_v)){c.virtual_format="pass";goto release;}
        if(!lease_same_format(&o.virtual_format,&before_v)){c.virtual_format="skipped_external_change";c.result=LEASE_FORMAT_CONFLICT;goto release;}
        c.result=lease_owned_read(g,ops,&checked);
        if(c.result!=LEASE_OK||!lease_pair(&checked,&g->original_p,&before_v)){if(c.result==LEASE_OK)c.result=LEASE_FORMAT_CONFLICT;c.virtual_format="skipped_changed_before_restore";goto release;}
        if(!ops->set_format(ops->context,false,&g->original_v)){c.virtual_format="fail";c.result=LEASE_WRITE_FAILED;goto release;}
        c.result=lease_wait_format(g,ops,false,&g->original_v);c.virtual_format=c.result==LEASE_OK?"pass":"fail";
    }
release:
    if(!lease_release(g,ops,&c.release)&&c.result==LEASE_OK)c.result=LEASE_OWNER_CHANGED;
    return c;
}
#endif
