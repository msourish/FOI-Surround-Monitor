#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import "FMInputMeterView.h"
#import "FMChannelTrimView.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <poll.h>

static NSString *const FMName = @"FOI Surround Monitor";
// Public settings/sessions are separate; the hardware lock remains shared.
static NSString *const FMSupportName = @"FOI Surround Monitor";
static NSString *const FMSharedLockSupportName = @"Fairlight 5.1 Monitor";
static NSString *const FMSettingsSuite = @"studio.foi.surroundmonitor";
static NSString *const FMFormat = @"Dolby Digital 5.1 · 48 kHz";
static const NSUInteger FMMaximumStatusBytes = 128 * 1024;
static const NSUInteger FMMaximumDiagnosticBytes = 32 * 1024;

static BOOL FMInputMayStart(AVAuthorizationStatus status) {
    return status == AVAuthorizationStatusAuthorized;
}

static BOOL FMInputMayRequest(AVAuthorizationStatus status) {
    return status == AVAuthorizationStatusNotDetermined;
}

static NSString *FMMessage(id value, NSString *fallback) {
    NSString *text = [value isKindOfClass:NSString.class] && [value length] ? value : fallback;
    return text.length > 180 ? [[text substringToIndex:179] stringByAppendingString:@"…"] : text;
}

static void FMAppendDiagnostics(NSMutableData *buffer, NSData *data) {
    if (data.length >= FMMaximumDiagnosticBytes) {
        [buffer setData:[data subdataWithRange:NSMakeRange(data.length - FMMaximumDiagnosticBytes, FMMaximumDiagnosticBytes)]];
        return;
    }
    if (buffer.length + data.length > FMMaximumDiagnosticBytes) {
        [buffer replaceBytesInRange:NSMakeRange(0, buffer.length + data.length - FMMaximumDiagnosticBytes) withBytes:NULL length:0];
    }
    [buffer appendData:data];
}

static NSData *FMReadStatus(NSURL *url) {
    if (!url) return nil;
    int fd = open(url.path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_size < 0 ||
        (uint64_t)info.st_size > FMMaximumStatusBytes) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:FMMaximumStatusBytes + 1];
    NSUInteger total = 0; BOOL ok = YES;
    while (total <= FMMaximumStatusBytes) {
        ssize_t n = read(fd, (unsigned char *)data.mutableBytes + total, FMMaximumStatusBytes + 1 - total);
        if (n == 0) break;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = NO; break; }
        total += (NSUInteger)n;
    }
    close(fd);
    if (!ok || total > FMMaximumStatusBytes) return nil;
    data.length = total;
    return data;
}

static BOOL FMTrue(id value) {
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static NSColor *FMMint(void) { return [NSColor colorWithSRGBRed:0.57 green:0.84 blue:0.73 alpha:1]; }
static NSColor *FMInk(void) { return [NSColor colorWithSRGBRed:0.88 green:0.90 blue:0.91 alpha:1]; }
static NSColor *FMMuted(void) { return [NSColor colorWithSRGBRed:0.58 green:0.63 blue:0.66 alpha:1]; }
static NSColor *FMAmber(void) { return [NSColor colorWithSRGBRed:0.93 green:0.72 blue:0.42 alpha:1]; }

static BOOL FMUnsignedNumber(id value, BOOL nonzero) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= (nonzero ? 1 : 0) && number <= 9007199254740991.0 && floor(number) == number;
}

static BOOL FMInputIdentityValid(id input) {
    if (![input isKindOfClass:NSDictionary.class]) return NO;
    return [input[@"uid"] isEqual:@"BlackHole16ch_UID"] && [input[@"channels"] isEqual:@6] &&
        [input[@"sample_rate"] isEqual:@48000] &&
        [input[@"channel_order"] isEqual:@[@"FL", @"FR", @"FC", @"LFE", @"SL", @"SR"]];
}

static BOOL FMInputWindowValid(id input) {
    if (!FMInputIdentityValid(input)) return NO;
    if (!FMUnsignedNumber(input[@"level_first_frame"], NO) || !FMUnsignedNumber(input[@"level_frames"], YES) ||
        [input[@"level_frames"] unsignedLongLongValue] > 480000) return NO;
    id peaks = input[@"peak_dbfs"];
    if (![peaks isKindOfClass:NSArray.class] || [peaks count] != 6) return NO;
    for (id value in peaks) {
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
        double db = [value doubleValue];
        if (!isfinite(db) || db < -200 || db > 24) return NO;
    }
    return YES;
}

static BOOL FMOutputActive(NSDictionary *status, NSString *selectedUID) {
    id encoder = status[@"encoder"], output = status[@"output"];
    return [status[@"state"] isEqual:@"running"] && FMTrue(status[@"ready"]) &&
        [encoder isKindOfClass:NSDictionary.class] && [output isKindOfClass:NSDictionary.class] &&
        [encoder[@"codec"] isEqual:@"AC-3"] && [encoder[@"sample_rate"] isEqual:@48000] &&
        [encoder[@"channels"] isEqual:@6] && [encoder[@"bitrate"] isEqual:@448000] &&
        [selectedUID isKindOfClass:NSString.class] && selectedUID.length > 0 &&
        [output[@"name"] isKindOfClass:NSString.class] && [output[@"name"] length] > 0 &&
        [output[@"uid"] isEqual:selectedUID] && FMTrue(output[@"started"]);
}

static BOOL FMOutputCandidateValid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    id uid=value[@"uid"], name=value[@"name"];
    id available=value[@"available"], reason=value[@"unavailable_reason"];
    if (available && (![available isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)available)!=CFBooleanGetTypeID())) return NO;
    if (reason && reason!=NSNull.null && (![reason isKindOfClass:NSString.class] || [reason length]>2048)) return NO;
    return [uid isKindOfClass:NSString.class] && [uid length] > 0 && [uid length] <= 1024 &&
        [name isKindOfClass:NSString.class] && [name length] > 0 && [name length] <= 512 &&
        [value[@"sample_rate"] isEqual:@48000] && [value[@"encoded_format"] isEqual:@"cac3"];
}

static BOOL FMOutputDiscoveryValid(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !FMUnsignedNumber(value[@"schema_version"],YES) || ![value[@"schema_version"] isEqual:@1] ||
        ![value[@"outputs"] isKindOfClass:NSArray.class] || [value[@"outputs"] count] > 128) return NO;
    NSMutableSet *seen=[NSMutableSet set];
    for (id candidate in value[@"outputs"]) {
        if (!FMOutputCandidateValid(candidate) || [seen containsObject:candidate[@"uid"]]) return NO;
        [seen addObject:candidate[@"uid"]];
    }
    return YES;
}

// Read-only discovery has a separate bounded lifetime. It never starts input or
// encoded output. This worker drains at most64KiB; it does not touch AppKit.
static NSDictionary *FMDiscoverOutputs(NSURL *script) {
    NSTask *task=[[NSTask alloc] init]; NSPipe *pipe=[NSPipe pipe];
    task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments=@[@"-B",script.path,@"--list-outputs"];
    task.standardInput=[NSFileHandle fileHandleWithNullDevice];
    task.standardOutput=pipe; task.standardError=[NSFileHandle fileHandleWithNullDevice];
    NSError *error=nil;
    if (![task launchAndReturnError:&error]) return @{@"error":FMMessage(error.localizedDescription,@"Output discovery could not start.")};
    int fd=pipe.fileHandleForReading.fileDescriptor, flags=fcntl(fd,F_GETFL);
    BOOL failed=flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0, eof=NO;
    NSMutableData *data=[NSMutableData data]; NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+5;
    while (!failed && (!eof || task.running)) {
        unsigned char buffer[8192]; ssize_t count=read(fd,buffer,sizeof(buffer));
        if (count>0) {
            if (data.length+(NSUInteger)count>65536) { failed=YES; break; }
            [data appendBytes:buffer length:(NSUInteger)count];
        } else if (!count) eof=YES;
        else if (errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) { failed=YES; break; }
        if (NSProcessInfo.processInfo.systemUptime>=deadline) { failed=YES; break; }
        if (!eof || task.running) { struct pollfd waitFD={fd,POLLIN,0}; poll(&waitFD,1,20); }
    }
    if (failed && task.running) {
        [task terminate]; NSTimeInterval grace=NSProcessInfo.processInfo.systemUptime+.5;
        while (task.running && NSProcessInfo.processInfo.systemUptime<grace) usleep(10000);
        // Only the known read-only discovery child can be force-stopped here.
        // The audio backend retains its separate graceful cleanup policy.
        if (task.running) kill(task.processIdentifier,SIGKILL);
    }
    [task waitUntilExit]; [pipe.fileHandleForReading closeFile];
    if (failed) return @{@"error":@"Output discovery timed out or returned too much data. Check the connection and refresh outputs."};
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (task.terminationStatus!=0 || !FMOutputDiscoveryValid(value))
        return @{@"error":FMMessage([value isKindOfClass:NSDictionary.class]?value[@"error"]:nil,@"Compatible outputs could not be read. Refresh outputs after checking the connection.")};
    return value;
}

static BOOL FMStatusValid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = value;
    id schema = d[@"schema_version"] ?: d[@"schema"];
    if (![schema isKindOfClass:NSNumber.class] || [schema integerValue] != 1) return NO;
    NSArray *states = @[@"starting", @"running", @"stopping", @"stopped", @"failed"];
    return [d[@"state"] isKindOfClass:NSString.class] && [states containsObject:d[@"state"]];
}

static BOOL FMCleanupComplete(NSDictionary *status) {
    id c = status[@"cleanup"];
    if (![c isKindOfClass:NSDictionary.class]) return NO;
    // The backend contract defines complete as all children stopped and reaped.
    // If a separate children_reaped field is supplied, it must agree.
    return FMTrue(c[@"complete"]) && FMTrue(c[@"input_stopped"]) &&
           FMTrue(c[@"output_restored"]) && (!c[@"children_reaped"] || FMTrue(c[@"children_reaped"]));
}

static NSString *FMIncompleteCleanupTitle(NSDictionary *status) {
    id cleanup = status[@"cleanup"];
    if (![cleanup isKindOfClass:NSDictionary.class]) return @"Bridge exited · cleanup not confirmed";
    if (FMTrue(cleanup[@"output_restored"]) && !FMTrue(cleanup[@"input_stopped"]))
        return @"Output restored · input cleanup unconfirmed";
    if (!FMTrue(cleanup[@"output_restored"])) return @"Output restoration was not confirmed";
    return @"Bridge exited · cleanup incomplete";
}

static NSString *FMIncompleteCleanupDetail(NSDictionary *status) {
    id cleanup = status[@"cleanup"];
    if (![cleanup isKindOfClass:NSDictionary.class] || !FMTrue(cleanup[@"children_reaped"]))
        return @"Start is disabled because child-process cleanup could not be verified. Check the session logs.";
    if (FMTrue(cleanup[@"output_restored"]) && !FMTrue(cleanup[@"input_stopped"]))
        return @"All monitor processes stopped and audio output was restored. A clean input-device stop was not confirmed. Start is disabled; see the session logs.";
    if (!FMTrue(cleanup[@"output_restored"]))
        return @"All monitor processes stopped, but output restoration was not confirmed. Start is disabled; see the session logs.";
    return @"All monitor processes stopped, but session cleanup was not fully confirmed. Start is disabled; see the session logs.";
}

static NSString *FMStateTitle(NSDictionary *status) {
    NSString *state = status[@"state"];
    if ([state isEqualToString:@"starting"]) return @"Preparing audio…";
    if ([state isEqualToString:@"stopping"]) return @"Stopping and restoring…";
    if ([state isEqualToString:@"running"]) {
        id input = status[@"input"];
        BOOL signal = [input isKindOfClass:NSDictionary.class] && FMTrue(input[@"signal_present"]);
        return signal ? @"Monitoring · signal present" : @"Monitoring · waiting for audio";
    }
    if ([state isEqualToString:@"stopped"] && FMCleanupComplete(status)) return @"Stopped · audio output restored";
    if ([state isEqualToString:@"failed"]) return @"Monitor stopped with an error";
    return @"Stopping · checking cleanup";
}

static BOOL FMTerminal(NSDictionary *status) {
    return [@[@"stopped", @"failed"] containsObject:status[@"state"] ?: @""];
}

static BOOL FMMeterEnvelopeValid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = value;
    return FMUnsignedNumber(d[@"schema_version"], YES) && [d[@"schema_version"] unsignedLongLongValue] == 1 &&
        [d[@"type"] isEqual:@"meter"] && FMUnsignedNumber(d[@"pid"], YES) &&
        [d[@"session_id"] isKindOfClass:NSString.class] && [d[@"session_id"] length] > 0 &&
        [d[@"session_id"] length] <= 160 && FMUnsignedNumber(d[@"host_ns"], YES) &&
        FMUnsignedNumber(d[@"level_sequence"], YES);
}

static NSArray *FMUnityTrims(void) { return @[@0,@0,@0,@0,@0,@0]; }

static BOOL FMTrimsValid(id trims) {
    if (![trims isKindOfClass:NSArray.class] || [trims count] != 6) return NO;
    for (id value in trims) {
        if (value == NSNull.null) continue;
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
        double db = [value doubleValue];
        if (!isfinite(db) || db < -60 || db > 6 || fabs(db * 10 - round(db * 10)) > 0.000001) return NO;
    }
    return YES;
}

static BOOL FMTrimStateValid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    return FMUnsignedNumber(value[@"requested_revision"], NO) && FMUnsignedNumber(value[@"applied_revision"], NO) &&
        [value[@"requested_revision"] unsignedLongLongValue] >= [value[@"applied_revision"] unsignedLongLongValue] &&
        FMTrimsValid(value[@"requested_trims_db"]) && FMTrimsValid(value[@"applied_trims_db"]) &&
        [value[@"ramp_frames"] isEqual:@960] &&
        ([value[@"requested_revision"] unsignedLongLongValue] != 0 || [value[@"requested_trims_db"] isEqual:FMUnityTrims()]) &&
        ([value[@"applied_revision"] unsignedLongLongValue] != 0 || [value[@"applied_trims_db"] isEqual:FMUnityTrims()]) &&
        (value[@"error"] == NSNull.null || [value[@"error"] isKindOfClass:NSString.class]);
}

static NSString *FMDescribeTrims(NSArray *trims) {
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *names = @[@"L",@"R",@"C",@"LFE",@"Ls",@"Rs"];
    for (NSUInteger i = 0; i < trims.count && i < 6; i++)
        [parts addObject:[NSString stringWithFormat:@"%@: %@", names[i], trims[i] == NSNull.null ? @"mute" :
            [NSString stringWithFormat:@"%+.1f dB", [trims[i] doubleValue]]]];
    return [parts componentsJoinedByString:@" · "];
}

// Only the explicitly requested session command is mutated. Holding a directory
// descriptor prevents a path change from redirecting the atomic publication.
static BOOL FMWriteTrimRequest(NSURL *session, NSData *data, NSError **error) {
    if (!session || !data.length || data.length > 4096) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    int dir = open(session.path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int failure = dir < 0 ? errno : 0;
    struct stat info;
    if (!failure && (fstat(dir, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid())) failure = EPERM;
    if (!failure) {
        if (fstatat(dir, "trim.request.json", &info, AT_SYMLINK_NOFOLLOW) == 0) {
            if (!S_ISREG(info.st_mode) || info.st_uid != getuid()) failure = EPERM;
        } else if (errno != ENOENT) failure = errno;
    }
    NSString *temporary = [NSString stringWithFormat:@".trim-%@.tmp", NSUUID.UUID.UUIDString];
    int fd = failure ? -1 : openat(dir, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (!failure && fd < 0) failure = errno;
    if (fd >= 0) {
        NSUInteger offset = 0;
        while (!failure && offset < data.length) {
            ssize_t count = write(fd, (const unsigned char *)data.bytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) failure = count < 0 ? errno : EIO;
            else offset += (NSUInteger)count;
        }
        if (close(fd) != 0 && !failure) failure = errno;
        if (!failure && renameat(dir, temporary.fileSystemRepresentation, dir, "trim.request.json") != 0) failure = errno;
        if (failure) unlinkat(dir, temporary.fileSystemRepresentation, 0);
    }
    if (dir >= 0) close(dir);
    if (failure && error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
    return failure == 0;
}

@interface FMStatusInbox : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableData *partial;
@property(nonatomic, strong) NSMutableData *diagnostics;
@property(nonatomic, strong) NSDictionary *latest;
@property(nonatomic, strong) NSDictionary *latestMeter;
@property(nonatomic, strong) NSArray<NSNumber *> *pendingMeterMaxima;
@property(nonatomic) BOOL discardingLine;
@property(nonatomic) uint64_t meterPackets;
@property(nonatomic) uint64_t meterCoalesced;
@property(nonatomic) uint64_t meterRejected;
@property(nonatomic) uint64_t meterTaken;
@property(nonatomic) uint64_t meterSequenceHighWater;
@property(nonatomic) uint64_t meterHostHighWater;
@property(nonatomic, strong) NSNumber *meterSourcePID;
@property(nonatomic, strong) NSString *meterSourceSession;
@property(nonatomic) pid_t expectedMeterPID;
@property(nonatomic, strong) NSString *expectedMeterSession;
- (void)append:(NSData *)data;
- (NSDictionary *)snapshot;
- (NSData *)diagnosticSnapshot;
- (NSDictionary *)takeLatestMeter;
- (NSDictionary *)meterStatistics;
- (void)configureMeterPID:(pid_t)pid sessionID:(NSString *)session;
@end

@implementation FMStatusInbox
- (instancetype)init {
    self = [super init];
    if (self) { _lock = [[NSLock alloc] init]; _partial = [NSMutableData data]; _diagnostics = [NSMutableData data]; }
    return self;
}
- (void)append:(NSData *)data {
    [self.lock lock];
    const unsigned char newline = '\n';
    NSData *delimiter = [NSData dataWithBytes:&newline length:1];
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSRange found = [data rangeOfData:delimiter options:0 range:NSMakeRange(offset, data.length - offset)];
        NSUInteger end = found.location == NSNotFound ? data.length : found.location;
        NSUInteger length = end - offset;
        if (!self.discardingLine) {
            if (self.partial.length + length > FMMaximumStatusBytes) {
                FMAppendDiagnostics(self.diagnostics, [data subdataWithRange:NSMakeRange(offset, length)]);
                self.partial.length = 0; self.discardingLine = YES;
            } else {
                [self.partial appendBytes:(const unsigned char *)data.bytes + offset length:length];
            }
        }
        if (found.location == NSNotFound) break;
        if (!self.discardingLine && self.partial.length) {
            id value = [NSJSONSerialization JSONObjectWithData:self.partial options:0 error:NULL];
            BOOL isMeter = [value isKindOfClass:NSDictionary.class] && [value[@"type"] isEqual:@"meter"];
            if (isMeter) {
                self.meterPackets++;
                BOOL envelopeValid = FMMeterEnvelopeValid(value);
                BOOL sourceMatches = envelopeValid && (!self.expectedMeterPID || [value[@"pid"] intValue] == self.expectedMeterPID) &&
                    (!self.expectedMeterSession || [value[@"session_id"] isEqual:self.expectedMeterSession]) &&
                    (!self.meterSourcePID || ([value[@"pid"] isEqual:self.meterSourcePID] &&
                     [value[@"session_id"] isEqual:self.meterSourceSession]));
                if (!envelopeValid || !sourceMatches ||
                    [value[@"level_sequence"] unsignedLongLongValue] <= self.meterSequenceHighWater ||
                    [value[@"host_ns"] unsignedLongLongValue] <= self.meterHostHighWater) {
                    self.meterRejected++;
                } else {
                    if (self.latestMeter) self.meterCoalesced++;
                    self.meterSourcePID = value[@"pid"]; self.meterSourceSession = value[@"session_id"];
                    self.meterSequenceHighWater = [value[@"level_sequence"] unsignedLongLongValue];
                    self.meterHostHighWater = [value[@"host_ns"] unsignedLongLongValue];
                    if (FMInputWindowValid(value[@"input"])) {
                        NSArray *peaks = value[@"input"][@"peak_dbfs"];
                        NSMutableArray *maxima = self.pendingMeterMaxima ? self.pendingMeterMaxima.mutableCopy : peaks.mutableCopy;
                        for (NSUInteger i = 0; i < 6; i++) if ([peaks[i] doubleValue] > [maxima[i] doubleValue]) maxima[i] = peaks[i];
                        self.pendingMeterMaxima = maxima;
                    }
                    self.latestMeter = value;
                }
                // Fast levels are transient metadata. Keep diagnostics for
                // lifecycle/errors instead of logging 30 meter lines a second.
            } else {
                FMAppendDiagnostics(self.diagnostics, self.partial);
                FMAppendDiagnostics(self.diagnostics, delimiter);
                // A terminal record cannot be displaced by an older one.
                if (FMStatusValid(value) && (!FMTerminal(self.latest) || FMTerminal(value))) self.latest = value;
            }
        }
        self.partial.length = 0; self.discardingLine = NO;
        offset = end + 1;
    }
    [self.lock unlock];
}
- (NSDictionary *)snapshot {
    [self.lock lock]; NSDictionary *value = self.latest; [self.lock unlock]; return value;
}
- (NSData *)diagnosticSnapshot {
    [self.lock lock]; NSData *value = [self.diagnostics copy]; [self.lock unlock]; return value;
}
- (NSDictionary *)takeLatestMeter {
    [self.lock lock];
    NSMutableDictionary *value = self.latestMeter.mutableCopy;
    if (value && self.pendingMeterMaxima) value[@"ui_pending_peak_maxima"] = self.pendingMeterMaxima;
    self.latestMeter = nil;
    self.pendingMeterMaxima = nil;
    if (value) self.meterTaken++;
    [self.lock unlock];
    return value;
}
- (NSDictionary *)meterStatistics {
    [self.lock lock];
    NSDictionary *value = @{@"packets_received":@(self.meterPackets), @"packets_coalesced":@(self.meterCoalesced),
        @"packets_rejected_in_inbox":@(self.meterRejected), @"packets_taken":@(self.meterTaken)};
    [self.lock unlock];
    return value;
}
- (void)configureMeterPID:(pid_t)pid sessionID:(NSString *)session {
    [self.lock lock];
    self.expectedMeterPID = pid; self.expectedMeterSession = session;
    if (self.meterSourcePID && ((pid && self.meterSourcePID.intValue != pid) || ![self.meterSourceSession isEqual:session])) {
        self.latestMeter = nil; self.pendingMeterMaxima = nil;
        self.meterSourcePID = nil; self.meterSourceSession = nil;
        self.meterSequenceHighWater = 0; self.meterHostHighWater = 0;
    }
    [self.lock unlock];
}
@end

static void FMPlace(NSView *parent, NSView *view, CGFloat x, CGFloat top, CGFloat width, CGFloat height) {
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.autoresizingMask = NSViewMinYMargin;
    view.frame = NSMakeRect(x, parent.bounds.size.height - top - height, width, height);
    [parent addSubview:view];
}

static NSTextField *FMLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = FMInk();
    label.selectable = NO;
    return label;
}

@interface FMAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *gearButton;
@property(nonatomic, strong) NSButton *inputAccessButton;
@property(nonatomic, strong) NSTextField *statusTitle;
@property(nonatomic, strong) NSTextField *statusDetail;
@property(nonatomic, strong) NSTextField *formatLabel;
@property(nonatomic, strong) NSTextField *formatStateLabel;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) FMInputMeterView *meterView;
@property(nonatomic, strong) NSSegmentedControl *viewToggle;
@property(nonatomic, strong) NSTextField *heroLabel;
@property(nonatomic, strong) NSBox *divider;
@property(nonatomic, strong) NSMenu *gearMenu;
@property(nonatomic, strong) NSMenu *outputMenu;
@property(nonatomic, strong) NSArray<NSDictionary *> *availableOutputs;
@property(nonatomic, strong) NSString *selectedOutputUID;
@property(nonatomic, strong) NSString *sessionOutputUID;
@property(nonatomic, strong) NSUserDefaults *settings;
@property(nonatomic) BOOL discoveringOutputs;
@property(nonatomic) NSUInteger discoveryGeneration;
@property(nonatomic, strong) FMChannelTrimView *trimView;
@property(nonatomic, strong) NSTextField *trimStateLabel;
@property(nonatomic, strong) NSMenuItem *resetTrimsMenuItem;
@property(nonatomic, strong) NSArray *requestedTrimsDB;
@property(nonatomic, strong) NSArray *appliedTrimsDB;
@property(nonatomic) uint64_t trimRevision;
@property(nonatomic) uint64_t appliedTrimRevision;
@property(nonatomic) uint64_t backendTrimRevision;
@property(nonatomic) NSUInteger trimControlEpoch;
@property(nonatomic) BOOL trimAvailable;
@property(nonatomic) BOOL trimWriteInFlight;
@property(nonatomic) BOOL trimWriteScheduled;
@property(nonatomic) NSTimeInterval trimRequestedUptime;
@property(nonatomic) NSTimeInterval lastTrimTelemetryUptime;
@property(nonatomic, strong) NSString *trimProblem;
@property(nonatomic, strong) NSDictionary *lastTrimSnapshot;
@property(nonatomic, strong) dispatch_queue_t trimWriteQueue;
@property(nonatomic, strong) NSTask *backend;
@property(nonatomic, strong) NSPipe *outputPipe;
@property(nonatomic, strong) FMStatusInbox *statusInbox;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *meterTimer;
@property(nonatomic, strong) NSDictionary *lastStatus;
@property(nonatomic, strong) NSURL *supportURL;
@property(nonatomic, strong) NSURL *sessionURL;
@property(nonatomic, strong) NSURL *statusURL;
@property(nonatomic, strong) NSURL *stopURL;
@property(nonatomic, strong) NSDate *stopRequestedAt;
@property(nonatomic) BOOL terminationPending;
@property(nonatomic) BOOL stopRequested;
@property(nonatomic) BOOL sentTerminate;
@property(nonatomic) BOOL cleanupUnconfirmed;
@property(nonatomic) int lockFD;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger finishAttempts;
@property(nonatomic) AVAuthorizationStatus inputAuthorizationStatus;
@property(nonatomic) BOOL permissionRequestPending;
@property(nonatomic) NSTimeInterval backendStartedUptime;
@property(nonatomic) NSTimeInterval lastStatusUptime;
@property(nonatomic) NSTimeInterval lastMeterUptime;
@property(nonatomic, strong) NSNumber *lastStatusHost;
@property(nonatomic, strong) NSNumber *lastInputFirstFrame;
@property(nonatomic, strong) NSNumber *lastInputFrameCount;
@property(nonatomic) BOOL telemetryUnavailable;
@property(nonatomic, strong) NSArray<NSNumber *> *clipEventsSeen;
@property(nonatomic) uint64_t lastFastSequence;
@property(nonatomic) uint64_t lastFastHostNS;
@property(nonatomic) uint64_t fastPacketsAccepted;
@property(nonatomic) uint64_t fastPacketsRejected;
@property(nonatomic) uint64_t fastWindowsPresented;
@property(nonatomic) uint64_t statusWindowsPresented;
@property(nonatomic) uint64_t firstFastHostNS;
@property(nonatomic) uint64_t lastPresentedFastHostNS;
@property(nonatomic) uint64_t maximumFastSourceGapNS;
@property(nonatomic) NSTimeInterval firstFastReceiptUptime;
@property(nonatomic) NSTimeInterval lastFastReceiptUptime;
@property(nonatomic) NSTimeInterval maximumFastReceiptGap;
@property(nonatomic) BOOL meterSummaryWritten;
@end

@implementation FMAppDelegate

- (instancetype)init {
    self = [super init];
    if (self) { _lockFD = -1; _settings=[[NSUserDefaults alloc] initWithSuiteName:FMSettingsSuite]; }
    return self;
}

- (void)makeMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *root = [[NSMenuItem alloc] init];
    [bar addItem:root];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:FMName];
    NSMenuItem *about=[menu addItemWithTitle:[@"About " stringByAppendingString:FMName] action:@selector(showAbout:) keyEquivalent:@""];
    about.target=self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:[@"Hide " stringByAppendingString:FMName] action:@selector(hide:) keyEquivalent:@"h"];
    [menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:[@"Quit " stringByAppendingString:FMName] action:@selector(terminate:) keyEquivalent:@"q"];
    root.submenu = menu;
    NSApp.mainMenu = bar;
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSURL *credits=[NSBundle.mainBundle URLForResource:@"Credits" withExtension:@"rtf"];
    NSAttributedString *text=credits?[[NSAttributedString alloc] initWithURL:credits options:@{NSDocumentTypeDocumentAttribute:NSRTFTextDocumentType} documentAttributes:NULL error:NULL]:nil;
    if (!text) text=[[NSAttributedString alloc] initWithString:@"Created by Sourish Mukherjee (@msourish). AI collaborator: SOURX."];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionApplicationName:FMName,NSAboutPanelOptionCredits:text}];
}

- (BOOL)acquireApplicationLock:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    self.supportURL = [base URLByAppendingPathComponent:FMSupportName isDirectory:YES];
    if (![fm createDirectoryAtURL:self.supportURL withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    NSURL *sharedLockURL=[base URLByAppendingPathComponent:FMSharedLockSupportName isDirectory:YES];
    if (![fm createDirectoryAtURL:sharedLockURL withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    NSString *path = [[sharedLockURL URLByAppendingPathComponent:@"application.lock"] path];
    self.lockFD = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (self.lockFD < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    struct stat info;
    if (fstat(self.lockFD, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || flock(self.lockFD, LOCK_EX | LOCK_NB)) {
        int code = errno ?: EACCES;
        close(self.lockFD); self.lockFD = -1;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self makeMenu];
    NSError *error = nil;
    if (![self acquireApplicationLock:&error]) {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID ?: @""]) {
            if (other.processIdentifier != getpid()) [other activateWithOptions:NSApplicationActivateAllWindows];
        }
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"A monitor window is already open, or its lock is unavailable.";
        alert.informativeText = @"Use the existing window. No audio was started by this instance.";
        [alert addButtonWithTitle:@"Close"];
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }
    [self buildWindow];
    [self refreshInputPermissionPreservingStatus:YES];
    [self refreshOutputs:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 565, 554)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = FMName;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithSRGBRed:0.105 green:0.12 blue:0.13 alpha:1];
    [self.window center];
    NSView *content = self.window.contentView;
    // Fixed instrument faceplate: no arranged-view detachment under layout pressure.
    FMPlace(content, FMLabel(FMName, 20, NSFontWeightSemibold), 22, 17, 470, 27);
    self.gearButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings and help"]
        target:self action:@selector(showGearMenu:)];
    self.gearButton.bordered = NO;
    self.gearButton.contentTintColor = FMMuted();
    self.gearButton.toolTip = @"Output selection, routing, Fairlight setup and session logs";
    FMPlace(content, self.gearButton, 513, 15, 30, 30);
    self.gearMenu = [[NSMenu alloc] initWithTitle:@"Settings and help"];
    NSMenuItem *outputItem=[self.gearMenu addItemWithTitle:@"Output" action:nil keyEquivalent:@""];
    self.outputMenu=[[NSMenu alloc] initWithTitle:@"Output"]; self.outputMenu.autoenablesItems=NO;
    outputItem.submenu=self.outputMenu;
    [self rebuildOutputMenu];
    [self.gearMenu addItem:NSMenuItem.separatorItem];
    for (NSArray *item in @[@[@"Routing…", NSStringFromSelector(@selector(showRouting:))],
                            @[@"Fairlight setup…", NSStringFromSelector(@selector(showFairlightSetup:))],
                            @[@"Show session logs…", NSStringFromSelector(@selector(showSession:))]]) {
        NSMenuItem *entry = [self.gearMenu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:@""];
        entry.target = self;
    }
    [self.gearMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *clear = [self.gearMenu addItemWithTitle:@"Clear clip indicators" action:@selector(clearClipIndicators:) keyEquivalent:@""];
    clear.target = self;
    self.resetTrimsMenuItem = [self.gearMenu addItemWithTitle:@"Reset channel trims" action:@selector(resetChannelTrims:) keyEquivalent:@""];
    self.resetTrimsMenuItem.target = self;
    self.resetTrimsMenuItem.enabled = NO;
    self.gearMenu.autoenablesItems = NO;

    self.statusTitle = FMLabel(@"Idle · audio stopped", 13, NSFontWeightMedium);
    self.statusTitle.maximumNumberOfLines = 1;
    self.statusTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    FMPlace(content, self.statusTitle, 22, 85, 521, 21);
    self.startButton = [NSButton buttonWithTitle:@"Start" target:self action:@selector(toggleMonitor:)];
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.controlSize = NSControlSizeRegular;
    self.startButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.startButton.contentTintColor = FMMint();
    self.startButton.keyEquivalent = @"\r";
    self.startButton.enabled = NO;
    self.startButton.toolTip = @"Start the bridge; while active, Stop drains audio and restores the output";
    FMPlace(content, self.startButton, 439, 47, 104, 32);
    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    FMPlace(content, self.spinner, 417, 55, 14, 14);
    self.statusDetail = FMLabel(@"", 11, NSFontWeightRegular);
    self.statusDetail.textColor = FMMuted();
    self.statusDetail.maximumNumberOfLines = 2;
    self.statusDetail.lineBreakMode = NSLineBreakByTruncatingTail;
    FMPlace(content, self.statusDetail, 22, 108, 521, 32);
    self.inputAccessButton = [NSButton buttonWithTitle:@"Request input access…" target:self action:@selector(requestInputAccess:)];
    self.inputAccessButton.bezelStyle = NSBezelStyleRounded;
    self.inputAccessButton.controlSize = NSControlSizeSmall;
    self.inputAccessButton.font = [NSFont systemFontOfSize:11];
    self.inputAccessButton.hidden = YES;
    FMPlace(content, self.inputAccessButton, 354, 108, 189, 28);

    self.formatLabel = FMLabel(FMFormat, 11, NSFontWeightMedium);
    self.formatLabel.maximumNumberOfLines=1; self.formatLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    self.formatLabel.textColor = FMMuted();
    FMPlace(content, self.formatLabel, 22, 56, 334, 17);
    self.formatStateLabel = FMLabel(@"IDLE", 9, NSFontWeightSemibold);
    self.formatStateLabel.alignment = NSTextAlignmentRight;
    self.formatStateLabel.textColor = FMMuted();
    FMPlace(content, self.formatStateLabel, 356, 57, 55, 15);
    self.divider = [[NSBox alloc] init];
    self.divider.boxType = NSBoxSeparator;
    FMPlace(content, self.divider, 22, 88, 521, 1);
    self.heroLabel = FMLabel(@"5.1 input · post-trim", 12, NSFontWeightSemibold);
    self.heroLabel.toolTip = @"Levels after channel trims, before peak protection and Dolby Digital encoding.";
    FMPlace(content, self.heroLabel, 22, 101, 210, 19);
    self.viewToggle = [NSSegmentedControl segmentedControlWithLabels:@[@"Meters", @"Room"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeMeterView:)];
    self.viewToggle.segmentStyle = NSSegmentStyleRounded;
    self.viewToggle.controlSize = NSControlSizeSmall;
    self.viewToggle.selectedSegment = 0;
    self.viewToggle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [self.viewToggle setWidth:65 forSegment:0];
    [self.viewToggle setWidth:65 forSegment:1];
    self.viewToggle.toolTip = @"Display the same input peaks as meters or speaker positions";
    FMPlace(content, self.viewToggle, 405, 96, 138, 26);
    self.meterView = [[FMInputMeterView alloc] initWithFrame:NSZeroRect];
    FMPlace(content, self.meterView, 22, 128, 521, 300);
    self.trimView = [[FMChannelTrimView alloc] initWithFrame:NSMakeRect(22, 22, 521, 96)];
    [content addSubview:self.trimView];
    self.trimStateLabel = FMLabel(@"Session trims · unity", 10, NSFontWeightRegular);
    self.trimStateLabel.textColor = FMMuted();
    self.trimStateLabel.maximumNumberOfLines = 1;
    self.trimStateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    // The trim component is flipped and reserves its first19pt for this label.
    self.trimStateLabel.frame = NSMakeRect(12, 3, 497, 14);
    [self.trimView addSubview:self.trimStateLabel];
    __weak FMAppDelegate *weakSelf = self;
    self.trimView.changeHandler = ^(NSArray *trims) { [weakSelf handleTrimChange:trims]; };
    [self resetSessionTrims];
    [self.meterView resetLevels];
    [self setFormatActive:NO];
    [self layoutFaceplateShowingDetails:NO];
}

- (void)changeMeterView:(NSSegmentedControl *)sender {
    self.meterView.roomMode = sender.selectedSegment == 1;
}

- (void)clearClipIndicators:(id)sender {
    (void)sender;
    [self.meterView clearClips];
    // clipEventsSeen deliberately survives the user acknowledgement.
}

- (void)showGearMenu:(id)sender {
    (void)sender;
    [self.gearMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.gearButton];
}

- (NSDictionary *)selectedOutput {
    for (NSDictionary *candidate in self.availableOutputs)
        if ([candidate[@"uid"] isEqual:self.selectedOutputUID]) return candidate;
    return nil;
}

- (BOOL)selectedOutputAvailable {
    NSDictionary *candidate=[self selectedOutput];
    return candidate && (!candidate[@"available"] || FMTrue(candidate[@"available"]));
}

- (void)rebuildOutputMenu {
    [self.outputMenu removeAllItems];
    for (NSDictionary *candidate in self.availableOutputs) {
        NSString *name=FMMessage(candidate[@"name"],@"Audio output");
        BOOL available=!candidate[@"available"] || FMTrue(candidate[@"available"]);
        if (!available) name=[name stringByAppendingString:@" — unavailable"];
        NSUInteger sameName=0; for (NSDictionary *other in self.availableOutputs) if ([other[@"name"] isEqual:candidate[@"name"]]) sameName++;
        if (sameName>1) name=[name stringByAppendingFormat:@" (%@)",candidate[@"uid"]];
        NSMenuItem *item=[self.outputMenu addItemWithTitle:name action:@selector(selectOutput:) keyEquivalent:@""];
        item.target=self; item.representedObject=candidate[@"uid"]; item.toolTip=candidate[@"uid"];
        item.state=[candidate[@"uid"] isEqual:self.selectedOutputUID]?NSControlStateValueOn:NSControlStateValueOff;
        item.enabled=!self.backend && !self.discoveringOutputs && available;
    }
    if (!self.availableOutputs.count) {
        NSMenuItem *empty=[self.outputMenu addItemWithTitle:self.discoveringOutputs?@"Checking compatible outputs…":@"No compatible output found" action:nil keyEquivalent:@""];
        empty.enabled=NO;
    }
    [self.outputMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *refresh=[self.outputMenu addItemWithTitle:@"Refresh outputs" action:@selector(refreshOutputs:) keyEquivalent:@""];
    refresh.target=self; refresh.enabled=!self.backend && !self.discoveringOutputs;
}

- (void)selectOutput:(NSMenuItem *)sender {
    if (self.backend || self.discoveringOutputs || self.terminationPending) return;
    NSString *uid=sender.representedObject;
    BOOL found=NO; for (NSDictionary *candidate in self.availableOutputs) if ([candidate[@"uid"] isEqual:uid]) found=YES;
    if (!found) return;
    for (NSDictionary *candidate in self.availableOutputs) if ([candidate[@"uid"] isEqual:uid] && candidate[@"available"] && !FMTrue(candidate[@"available"])) return;
    self.selectedOutputUID=uid; [self.settings setObject:uid forKey:@"SelectedOutputUID"];
    [self rebuildOutputMenu]; [self setFormatActive:NO]; [self updatePrimaryControl];
    if (FMInputMayStart(self.inputAuthorizationStatus) && !self.cleanupUnconfirmed) {
        self.statusTitle.stringValue=@"Idle · audio stopped"; self.statusDetail.stringValue=@"";
        [self layoutFaceplateShowingDetails:NO];
    }
}

- (void)refreshOutputs:(id)sender {
    (void)sender;
    if (self.backend || self.discoveringOutputs || self.terminationPending) return;
    self.discoveringOutputs=YES; NSUInteger generation=++self.discoveryGeneration;
    [self rebuildOutputMenu]; [self updatePrimaryControl];
    NSURL *script=[self backendURL]; __weak FMAppDelegate *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDictionary *result=FMDiscoverOutputs(script);
        dispatch_async(dispatch_get_main_queue(), ^{
            FMAppDelegate *strong=weakSelf;
            if (!strong || strong.discoveryGeneration!=generation) return;
            strong.discoveringOutputs=NO;
            strong.availableOutputs=FMOutputDiscoveryValid(result)?result[@"outputs"]:@[];
            NSString *preferred=strong.selectedOutputUID ?: [strong.settings stringForKey:@"SelectedOutputUID"];
            strong.selectedOutputUID=nil;
            for (NSDictionary *candidate in strong.availableOutputs) if ([candidate[@"uid"] isEqual:preferred]) strong.selectedOutputUID=preferred;
            if (!strong.selectedOutputUID && strong.availableOutputs.count==1) strong.selectedOutputUID=strong.availableOutputs[0][@"uid"];
            if (strong.selectedOutputUID) [strong.settings setObject:strong.selectedOutputUID forKey:@"SelectedOutputUID"];
            [strong rebuildOutputMenu]; [strong updatePrimaryControl]; [strong setFormatActive:NO];
            if (FMInputMayStart(strong.inputAuthorizationStatus) && !strong.cleanupUnconfirmed) {
                if (![strong selectedOutputAvailable]) {
                    strong.statusTitle.stringValue=strong.availableOutputs.count?@"Choose an audio output":@"No compatible output found";
                    strong.statusDetail.stringValue=FMMessage(result[@"error"],strong.availableOutputs.count?@"Choose a device from Settings → Output.":@"Connect an output that supports Dolby Digital, then use Settings → Output → Refresh outputs.");
                    if (strong.selectedOutputUID) {
                        strong.statusTitle.stringValue=@"Selected output is unavailable";
                        strong.statusDetail.stringValue=FMMessage([strong selectedOutput][@"unavailable_reason"],@"Stop other playback using this output, then refresh outputs.");
                    }
                    [strong layoutFaceplateShowingDetails:YES];
                } else {
                    strong.statusTitle.stringValue=@"Idle · audio stopped"; strong.statusDetail.stringValue=@"";
                    [strong layoutFaceplateShowingDetails:NO];
                }
            }
        });
    });
}

- (void)showHelp:(NSString *)title text:(NSString *)text {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = text;
    [alert addButtonWithTitle:@"Done"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)showRouting:(id)sender {
    (void)sender;
    NSString *name=FMMessage([self selectedOutput][@"name"],@"Choose a compatible output in Settings → Output");
    [self showHelp:@"Routing" text:[NSString stringWithFormat:@"BlackHole 16ch, channels 1–6 → live Dolby Digital 5.1 → %@.\n\nChoose a connected device from Settings → Output. Use Refresh outputs after connecting or disconnecting equipment. Selection is fixed for each running session. The stream is AC-3 at 48 kHz and 448 kb/s.\n\nConnect the selected output to a Dolby Digital receiver directly or through a compatible extractor. Begin at a comfortable low volume and disable any receiver mode that copies every channel to every speaker.\n\nA disconnect stops the bridge; it does not reconnect automatically. Stop or Quit drains audio and restores the selected device. These controls do not change the Fairlight patch; use Fairlight setup for that route.",name]];
}

- (void)showFairlightSetup:(id)sender {
    (void)sender;
    [self showHelp:@"Fairlight setup" text:@"In Resolve, select BlackHole 16ch as the output. Route a 5.1 Bus Out to channels 1–6 in this order: L, R, C, LFE, Ls, Rs.\n\nRemove competing stereo or track-direct patches on those outputs. Bus Out bypasses Resolve’s monitor volume and mute; use track or bus controls, receiver volume, or Stop in this app.\n\nStart prepares the bridge. Playback still starts separately in Resolve. The meters show BlackHole input levels, not measured speaker sound.\n\nmacOS uses Microphone permission for the BlackHole virtual input. This monitor selects only BlackHole, with no physical microphone input. If access is denied, use System Settings → Privacy & Security → Microphone."];
}

- (void)toggleMonitor:(id)sender {
    if (self.backend) [self stopMonitor:sender];
    else [self startMonitor:sender];
}

- (void)updatePrimaryControl {
    if (self.backend) {
        BOOL restoring = self.stopRequested || [self.lastStatus[@"state"] isEqual:@"stopping"] || FMTerminal(self.lastStatus);
        self.startButton.title = restoring ? @"Restoring…" : @"Stop";
        self.startButton.enabled = !restoring;
        self.startButton.contentTintColor = restoring ? FMMuted() : FMAmber();
    } else {
        self.startButton.title = @"Start";
        self.startButton.enabled = !self.terminationPending && !self.cleanupUnconfirmed &&
            !self.permissionRequestPending && !self.discoveringOutputs && [self selectedOutputAvailable] && FMInputMayStart(self.inputAuthorizationStatus);
        self.startButton.contentTintColor = FMMint();
    }
    for (NSMenuItem *item in self.outputMenu.itemArray) {
        if (item.action==@selector(refreshOutputs:)) item.enabled=!self.backend && !self.discoveringOutputs;
        if (item.action==@selector(selectOutput:)) {
            BOOL available=NO;
            for (NSDictionary *candidate in self.availableOutputs) if ([candidate[@"uid"] isEqual:item.representedObject]) available=!candidate[@"available"] || FMTrue(candidate[@"available"]);
            item.enabled=!self.backend && !self.discoveringOutputs && available;
        }
    }
}

- (void)setFormatActive:(BOOL)active {
    NSString *name=FMMessage(active?self.lastStatus[@"output"][@"name"]:[self selectedOutput][@"name"],@"Choose output");
    self.formatLabel.stringValue = [FMFormat stringByAppendingFormat:@" · %@",name];
    self.formatLabel.toolTip = active ? [NSString stringWithFormat:@"Active Dolby Digital 5.1, 48 kHz, 448 kb/s through %@",name] :
        @"Configured output only. Choose a compatible device in Settings → Output; the bridge confirms the active stream after Start.";
    self.formatStateLabel.stringValue = active ? @"ACTIVE" : @"IDLE";
    self.formatStateLabel.textColor = active ? FMMint() : FMMuted();
}

- (void)layoutFaceplateShowingDetails:(BOOL)show {
    self.statusTitle.hidden = !show;
    self.statusDetail.hidden = !show || !self.statusDetail.stringValue.length;
    CGFloat h = self.window.contentView.bounds.size.height;
    self.divider.frame = NSMakeRect(22, h - (show ? 142 : 89), 521, 1);
    self.heroLabel.frame = NSMakeRect(22, h - (show ? 155 : 101) - 19, 210, 19);
    self.viewToggle.frame = NSMakeRect(405, h - (show ? 150 : 96) - 26, 138, 26);
    self.meterView.frame = NSMakeRect(22, 126, 521, show ? 247 : 300);
}

- (void)refreshInputPermissionPreservingStatus:(BOOL)preserve {
    if (!self.window || self.backend || self.permissionRequestPending || self.terminationPending) return;
    BOOL previouslyAllowed = FMInputMayStart(self.inputAuthorizationStatus);
    self.inputAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (self.cleanupUnconfirmed) {
        self.startButton.enabled = NO; self.inputAccessButton.hidden = YES;
        [self layoutPermissionDetail]; return;
    }
    BOOL allowed = FMInputMayStart(self.inputAuthorizationStatus);
    BOOL undetermined = FMInputMayRequest(self.inputAuthorizationStatus);
    [self updatePrimaryControl];
    self.inputAccessButton.hidden = !undetermined;
    self.inputAccessButton.enabled = undetermined;
    [self layoutPermissionDetail];
    if (allowed) {
        if (!preserve || !previouslyAllowed) {
            self.statusTitle.stringValue = @"Idle · audio stopped";
            self.statusTitle.textColor = FMInk();
            self.statusDetail.stringValue = @"";
            [self setFormatActive:NO];
            [self layoutFaceplateShowingDetails:NO];
        }
        return;
    }
    self.statusTitle.textColor = FMAmber();
    if (undetermined) {
        self.statusTitle.stringValue = @"Input access needed";
        self.statusDetail.stringValue = @"Microphone permission covers BlackHole’s virtual input, not a physical mic.";
    } else if (self.inputAuthorizationStatus == AVAuthorizationStatusRestricted) {
        self.statusTitle.stringValue = @"Input access is restricted";
        self.statusDetail.stringValue = @"System Settings → Privacy & Security → Microphone. BlackHole is the virtual input; no physical mic is selected.";
    } else {
        self.statusTitle.stringValue = @"Input access is not allowed";
        self.statusDetail.stringValue = @"System Settings → Privacy & Security → Microphone → FOI Surround Monitor. Only BlackHole’s virtual input is selected.";
    }
    self.statusDetail.toolTip = self.statusDetail.stringValue;
    self.formatStateLabel.stringValue = @"ACCESS";
    self.formatStateLabel.textColor = FMAmber();
    [self layoutFaceplateShowingDetails:YES];
}

- (void)layoutPermissionDetail {
    NSRect frame = self.statusDetail.frame;
    frame.size.width = self.inputAccessButton.hidden ? 521 : 317;
    self.statusDetail.frame = frame;
}

- (void)requestInputAccess:(id)sender {
    (void)sender;
    if (self.backend || self.permissionRequestPending || self.terminationPending || self.cleanupUnconfirmed) return;
    // This action is reachable only through the separate, explicit user button.
    // Opening the app and pressing Start never invoke requestAccess.
    self.inputAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (!FMInputMayRequest(self.inputAuthorizationStatus)) {
        [self refreshInputPermissionPreservingStatus:YES]; return;
    }
    id explanation = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"];
    if (![explanation isKindOfClass:NSString.class] || ![explanation length]) {
        [self showError:@"The app’s input-access explanation is missing" detail:@"The application bundle needs its Microphone usage description before it can request access. No audio has started."];
        return;
    }
    self.permissionRequestPending = YES;
    self.inputAccessButton.enabled = NO; self.startButton.enabled = NO;
    self.statusTitle.stringValue = @"Waiting for input access…";
    self.statusTitle.textColor = FMAmber();
    self.statusDetail.stringValue = @"BlackHole virtual input only. Audio stays stopped while you choose.";
    self.formatStateLabel.stringValue = @"ACCESS";
    [self layoutFaceplateShowingDetails:YES];
    __weak FMAppDelegate *weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        (void)granted;
        dispatch_async(dispatch_get_main_queue(), ^{
            FMAppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.permissionRequestPending = NO;
            [strongSelf refreshInputPermissionPreservingStatus:NO];
            // No automatic Start or backend/device operation on either answer.
        });
    }];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self refreshInputPermissionPreservingStatus:YES];
}

- (void)showError:(NSString *)message detail:(NSString *)detail {
    self.statusTitle.stringValue = message;
    self.statusTitle.textColor = NSColor.systemRedColor;
    self.statusDetail.stringValue = FMMessage(detail, @"See the session logs for details.");
    self.statusTitle.toolTip = message;
    self.statusDetail.toolTip = detail;
    self.formatStateLabel.stringValue = @"ERROR";
    self.formatStateLabel.textColor = NSColor.systemRedColor;
    [self layoutFaceplateShowingDetails:YES];
    [self.spinner stopAnimation:nil];
    [self refreshTrimPresentation];
}

- (void)resetMeters {
    [self.meterView resetLevels];
    self.lastInputFirstFrame = nil; self.lastInputFrameCount = nil; self.lastMeterUptime = 0;
    self.clipEventsSeen = @[@0,@0,@0,@0,@0,@0];
    self.telemetryUnavailable = NO;
}

- (void)resetSessionTrims {
    self.trimControlEpoch++;
    self.requestedTrimsDB = FMUnityTrims(); self.appliedTrimsDB = FMUnityTrims();
    self.trimRevision = 0; self.appliedTrimRevision = 0; self.backendTrimRevision = 0;
    self.trimAvailable = NO; self.trimWriteInFlight = NO; self.trimWriteScheduled = NO;
    self.trimRequestedUptime = 0; self.trimProblem = nil;
    self.lastTrimTelemetryUptime = 0;
    self.lastTrimSnapshot = nil;
    if (!self.trimWriteQueue) self.trimWriteQueue = dispatch_queue_create("studio.foi.monitor.trim-writes", DISPATCH_QUEUE_SERIAL);
    self.trimView.trimsDB = self.requestedTrimsDB;
    [self refreshTrimPresentation];
}

- (BOOL)trimControlsMayChange {
    id errors = self.lastStatus[@"errors"];
    return self.backend && self.sessionURL.lastPathComponent.length && self.trimAvailable && !self.stopRequested && !self.cleanupUnconfirmed &&
        !self.telemetryUnavailable && FMOutputActive(self.lastStatus, self.sessionOutputUID) &&
        self.lastStatusUptime > 0 && NSProcessInfo.processInfo.systemUptime - self.lastStatusUptime <= 2.0 &&
        self.lastTrimTelemetryUptime > 0 && NSProcessInfo.processInfo.systemUptime - self.lastTrimTelemetryUptime <= 1.5 &&
        (![errors isKindOfClass:NSArray.class] || ![errors count]);
}

- (void)refreshTrimPresentation {
    BOOL enabled = [self trimControlsMayChange];
    self.trimView.enabled = enabled;
    self.resetTrimsMenuItem.enabled = enabled;
    self.trimStateLabel.textColor = FMMuted();
    if (!self.backend) self.trimStateLabel.stringValue = @"Session trims · unity";
    else if (self.stopRequested || FMTerminal(self.lastStatus) || [self.lastStatus[@"state"] isEqual:@"stopping"])
        self.trimStateLabel.stringValue = @"Session trims · locked while stopping";
    else if (!self.trimAvailable) self.trimStateLabel.stringValue = [self.lastStatus[@"state"] isEqual:@"starting"] ? @"Session trims · unity" : @"Channel trims are unavailable";
    else if (self.trimProblem.length) {
        self.trimStateLabel.stringValue = @"Trim change not confirmed · see status";
        self.trimStateLabel.textColor = NSColor.systemRedColor;
    } else if (self.trimRevision != self.appliedTrimRevision || ![self.requestedTrimsDB isEqual:self.appliedTrimsDB]) {
        self.trimStateLabel.stringValue = @"Applying channel trims…";
        self.trimStateLabel.textColor = FMAmber();
    } else {
        self.trimStateLabel.stringValue = [self.appliedTrimsDB isEqual:FMUnityTrims()] ? @"Trims applied · unity" : @"Session trims · applied";
        self.trimStateLabel.textColor = enabled ? FMMint() : FMMuted();
    }
    self.trimStateLabel.toolTip = [NSString stringWithFormat:@"Requested: %@\nLast acknowledged: %@%@",
        FMDescribeTrims(self.requestedTrimsDB ?: FMUnityTrims()), FMDescribeTrims(self.appliedTrimsDB ?: FMUnityTrims()),
        self.trimProblem.length ? [@"\n" stringByAppendingString:self.trimProblem] : @""];
}

- (void)presentTrimProblemIfNeeded {
    if (self.trimProblem.length && self.backend && !self.stopRequested && FMOutputActive(self.lastStatus, self.sessionOutputUID) && !self.telemetryUnavailable) {
        id errors = self.lastStatus[@"errors"];
        if (![errors isKindOfClass:NSArray.class] || ![errors count])
            [self showError:@"Channel trim change is not confirmed" detail:self.trimProblem];
    }
}

- (void)consumeTrimState:(id)value {
    if (!value || value == NSNull.null) {
        if (!self.lastTrimTelemetryUptime || NSProcessInfo.processInfo.systemUptime - self.lastTrimTelemetryUptime > 1.5) {
            self.trimAvailable = NO;
            if (self.lastTrimTelemetryUptime) self.trimProblem = @"Trim telemetry is no longer updating. Adjustments are disabled until the backend confirms its current settings.";
            [self refreshTrimPresentation];
        }
        return;
    }
    if (!FMTrimStateValid(value)) {
        self.trimAvailable = NO; self.trimProblem = @"The backend reported an invalid trim state. No applied setting can be confirmed; stop and check the session logs.";
        [self refreshTrimPresentation]; return;
    }
    if ([value isEqualToDictionary:self.lastTrimSnapshot] && self.trimAvailable) {
        self.lastTrimTelemetryUptime = NSProcessInfo.processInfo.systemUptime; return;
    }
    uint64_t requested = [value[@"requested_revision"] unsignedLongLongValue];
    uint64_t applied = [value[@"applied_revision"] unsignedLongLongValue];
    if (applied < self.appliedTrimRevision || (requested < self.backendTrimRevision && applied <= self.appliedTrimRevision)) return;
    if (applied == self.appliedTrimRevision && ![value[@"applied_trims_db"] isEqual:self.appliedTrimsDB]) {
        self.trimAvailable = NO;
        self.trimProblem = @"The backend reported conflicting values for one trim revision. Stop and inspect the session logs; the displayed request has not been confirmed.";
        [self refreshTrimPresentation]; return;
    }
    self.lastTrimSnapshot = [value copy];
    self.lastTrimTelemetryUptime = NSProcessInfo.processInfo.systemUptime;
    self.trimAvailable = YES;
    self.backendTrimRevision = MAX(self.backendTrimRevision, requested);
    if (applied >= self.appliedTrimRevision) {
        self.appliedTrimRevision = applied;
        self.appliedTrimsDB = [value[@"applied_trims_db"] copy];
    }
    id error = value[@"error"];
    if (requested >= self.trimRevision && [error isKindOfClass:NSString.class] && [error length]) {
        self.trimProblem = FMMessage(error, @"The backend rejected the trim request.");
    } else if (applied == self.trimRevision && [self.appliedTrimsDB isEqual:self.requestedTrimsDB]) {
        self.trimProblem = nil; self.trimRequestedUptime = 0;
    } else if (applied > self.trimRevision) {
        self.trimProblem = @"The backend applied a trim revision this window did not request. The tooltip shows the acknowledged settings; adjust a knob or reset trims to send a new request.";
    } else if (applied == self.trimRevision && ![self.appliedTrimsDB isEqual:self.requestedTrimsDB]) {
        self.trimProblem = @"The acknowledged trims do not match this window’s request. The knobs show your requested values; the tooltip shows the last acknowledged values.";
    }
    [self refreshTrimPresentation];
}

- (void)handleTrimChange:(NSArray *)trims {
    if (![self trimControlsMayChange]) {
        self.trimView.trimsDB = self.requestedTrimsDB ?: FMUnityTrims(); return;
    }
    if (!FMTrimsValid(trims)) {
        self.trimView.trimsDB = self.requestedTrimsDB;
        self.trimProblem = @"Use six values from −60 to +6 dB in 0.1 dB steps, or mute. No command was sent.";
        [self refreshTrimPresentation]; [self presentTrimProblemIfNeeded]; return;
    }
    uint64_t revision = MAX(self.trimRevision, self.backendTrimRevision);
    if (revision >= 9007199254740990ULL) {
        self.trimProblem = @"This session reached its trim revision limit. Stop and start a new session.";
        [self refreshTrimPresentation]; [self presentTrimProblemIfNeeded]; return;
    }
    self.trimRevision = revision + 1;
    self.requestedTrimsDB = [trims copy];
    self.trimView.trimsDB = self.requestedTrimsDB;
    self.trimRequestedUptime = NSProcessInfo.processInfo.systemUptime;
    self.trimProblem = nil;
    [self refreshTrimPresentation];
    [self scheduleTrimWrite];
}

- (void)resetChannelTrims:(id)sender {
    (void)sender;
    [self handleTrimChange:FMUnityTrims()];
}

- (void)scheduleTrimWrite {
    if (self.trimWriteInFlight || self.trimWriteScheduled || ![self trimControlsMayChange]) return;
    self.trimWriteScheduled = YES;
    NSUInteger epoch = self.trimControlEpoch;
    __weak FMAppDelegate *weakSelf = self;
    // One pending main-thread wakeup and one background write at most. Rapid
    // knob events replace the desired vector rather than creating a work queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FMAppDelegate *owner = weakSelf;
        if (!owner || owner.trimControlEpoch != epoch) return;
        owner.trimWriteScheduled = NO;
        if (![owner trimControlsMayChange]) return;
        uint64_t revision = owner.trimRevision;
        NSURL *session = owner.sessionURL;
        pid_t pid = owner.backend.processIdentifier;
        NSDictionary *command = @{@"schema_version":@1, @"pid":@(pid), @"session_id":session.lastPathComponent,
            @"revision":@(revision), @"trims_db":owner.requestedTrimsDB};
        NSData *data = [NSJSONSerialization dataWithJSONObject:command options:0 error:NULL];
        owner.trimWriteInFlight = YES;
        dispatch_async(owner.trimWriteQueue, ^{
            NSError *error = nil;
            BOOL written = FMWriteTrimRequest(session, data, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                FMAppDelegate *current = weakSelf;
                if (!current || current.trimControlEpoch != epoch || current.backend.processIdentifier != pid ||
                    ![current.sessionURL isEqual:session] || current.stopRequested) return;
                current.trimWriteInFlight = NO;
                if (!written && current.trimRevision == revision) {
                    current.trimProblem = [NSString stringWithFormat:@"The trim request could not be sent: %@. No applied change is confirmed.", error.localizedDescription ?: @"file write failed"];
                    [current refreshTrimPresentation]; [current presentTrimProblemIfNeeded];
                }
                if (current.trimRevision > revision) [current scheduleTrimWrite];
            });
        });
    });
}

- (void)invalidateTrimRequests {
    self.trimControlEpoch++;
    self.trimWriteScheduled = NO; self.trimWriteInFlight = NO;
    [self refreshTrimPresentation];
}

- (void)resetMeterTransport {
    self.lastFastSequence = 0; self.lastFastHostNS = 0;
    self.fastPacketsAccepted = 0; self.fastPacketsRejected = 0;
    self.fastWindowsPresented = 0; self.statusWindowsPresented = 0;
    self.firstFastHostNS = 0; self.lastPresentedFastHostNS = 0; self.maximumFastSourceGapNS = 0;
    self.firstFastReceiptUptime = 0; self.lastFastReceiptUptime = 0; self.maximumFastReceiptGap = 0;
    self.meterSummaryWritten = NO;
}

- (BOOL)fastMetersMayUpdate {
    return self.backend && !self.stopRequested && FMOutputActive(self.lastStatus, self.sessionOutputUID) &&
        self.lastStatusUptime > 0 && NSProcessInfo.processInfo.systemUptime - self.lastStatusUptime <= 2.0;
}

- (void)consumeFastMeter:(NSTimer *)timer {
    (void)timer;
    // Lifecycle state remains authoritative, including a terminal pipe record
    // which may arrive just before the next ordinary disk/status poll.
    NSDictionary *pendingStatus = [self.statusInbox snapshot];
    if (FMTerminal(pendingStatus) && [pendingStatus[@"pid"] isKindOfClass:NSNumber.class] &&
        [pendingStatus[@"pid"] intValue] == self.backend.processIdentifier) [self applyStatus:pendingStatus];
    if (![self fastMetersMayUpdate]) return;
    NSDictionary *packet = [self.statusInbox takeLatestMeter];
    if (packet) [self applyMeterPacket:packet];
}

- (void)applyMeterPacket:(NSDictionary *)packet {
    if (![self fastMetersMayUpdate]) return;
    if (!FMMeterEnvelopeValid(packet) || [packet[@"pid"] intValue] != self.backend.processIdentifier ||
        ![packet[@"session_id"] isEqual:self.sessionURL.lastPathComponent]) {
        self.fastPacketsRejected++; return;
    }
    uint64_t sequence = [packet[@"level_sequence"] unsignedLongLongValue];
    uint64_t host = [packet[@"host_ns"] unsignedLongLongValue];
    if (sequence <= self.lastFastSequence || host <= self.lastFastHostNS) {
        self.fastPacketsRejected++; return;
    }
    id input = packet[@"input"];
    if (!FMInputWindowValid(input) || [input[@"level_frames"] unsignedLongLongValue] != 1536) {
        self.fastPacketsRejected++;
        [self showTelemetryProblem:@"Fast input meters are unavailable" detail:@"The latest input window is invalid. Stop remains available; check the session logs."];
        return;
    }
    self.lastFastSequence = sequence; self.lastFastHostNS = host;
    self.fastPacketsAccepted++;
    [self consumeTrimState:packet[@"trim"]];
    // Cumulative clip events survive skipped/coalesced windows and do not
    // refresh the view's peak hold when the audio window itself is unchanged.
    [self ingestClipEvents:input];
    NSNumber *first = input[@"level_first_frame"], *count = input[@"level_frames"];
    if (self.lastInputFirstFrame && first.unsignedLongLongValue <= self.lastInputFirstFrame.unsignedLongLongValue) {
        // This audio window was already displayed (possibly by a slow status).
        // Do not refresh raw bars, hold time, or freshness a second time.
        return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL recovering = self.telemetryUnavailable;
    [self.meterView updatePeaks:input[@"peak_dbfs"]];
    [self.meterView holdPeaks:packet[@"ui_pending_peak_maxima"]];
    self.lastInputFirstFrame = first; self.lastInputFrameCount = count;
    self.lastMeterUptime = now; self.telemetryUnavailable = NO;
    if (recovering) [self refreshTrimPresentation];
    self.fastWindowsPresented++;
    if (!self.firstFastHostNS) { self.firstFastHostNS = host; self.firstFastReceiptUptime = now; }
    if (self.lastPresentedFastHostNS) self.maximumFastSourceGapNS = MAX(self.maximumFastSourceGapNS, host - self.lastPresentedFastHostNS);
    if (self.lastFastReceiptUptime) self.maximumFastReceiptGap = MAX(self.maximumFastReceiptGap, now - self.lastFastReceiptUptime);
    self.lastPresentedFastHostNS = host; self.lastFastReceiptUptime = now;
    if (recovering) {
        id errors = self.lastStatus[@"errors"];
        if (![errors isKindOfClass:NSArray.class] || ![errors count]) {
            [self setFormatActive:YES];
            self.formatStateLabel.stringValue = FMTrue(input[@"signal_present"]) ? @"ACTIVE" : @"WAITING";
            [self layoutFaceplateShowingDetails:NO];
            [self presentTrimProblemIfNeeded];
        }
    }
}

- (NSDictionary *)meterTransportSummary {
    NSTimeInterval duration = self.lastFastReceiptUptime - self.firstFastReceiptUptime;
    double cadence = self.fastWindowsPresented > 1 && duration > 0 ? (self.fastWindowsPresented - 1) / duration : 0;
    return @{@"schema_version":@1, @"session_id":self.sessionURL.lastPathComponent ?: @"",
        @"transport":@"latest-only stdout meter NDJSON", @"audio_recorded":@NO,
        @"fast_packets_accepted":@(self.fastPacketsAccepted), @"fast_packets_rejected":@(self.fastPacketsRejected),
        @"fast_windows_presented":@(self.fastWindowsPresented), @"status_windows_presented":@(self.statusWindowsPresented),
        @"first_presented_packet_host_ns":@(self.firstFastHostNS), @"last_presented_packet_host_ns":@(self.lastPresentedFastHostNS),
        @"maximum_presented_packet_host_gap_ns":@(self.maximumFastSourceGapNS),
        @"first_presented_ui_uptime_seconds":@(self.firstFastReceiptUptime), @"last_presented_ui_uptime_seconds":@(self.lastFastReceiptUptime),
        @"maximum_ui_update_gap_seconds":@(self.maximumFastReceiptGap), @"mean_fresh_ui_updates_per_second":@(cadence),
        @"inbox":[self.statusInbox meterStatistics] ?: @{},
        @"measurement_scope":@"Fresh UI meter updates, not audio delivery or acoustic latency. Coalescing is intentional; cumulative clip markers are retained."};
}

- (void)writeMeterTransportSummary {
    if (self.meterSummaryWritten || !self.sessionURL || ![NSFileManager.defaultManager fileExistsAtPath:self.sessionURL.path]) return;
    self.meterSummaryWritten = YES;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self meterTransportSummary] options:NSJSONWritingPrettyPrinted error:NULL];
    if (data) [data writeToURL:[self.sessionURL URLByAppendingPathComponent:@"ui_meter_summary.json"] options:NSDataWritingWithoutOverwriting error:NULL];
}

- (NSURL *)backendURL {
    return [[NSBundle.mainBundle resourceURL] URLByAppendingPathComponent:@"Backend/monitor_backend.py"];
}

- (void)startMonitor:(id)sender {
    (void)sender;
    if (self.backend || self.terminationPending || self.cleanupUnconfirmed || self.permissionRequestPending || self.discoveringOutputs) return;
    if (![self selectedOutputAvailable]) { [self refreshOutputs:nil]; return; }
    // Read authorization again even if a previously enabled button was clicked.
    // This read does not request access and precedes any backend launch/output use.
    [self refreshInputPermissionPreservingStatus:YES];
    if (!FMInputMayStart(self.inputAuthorizationStatus)) return;
    NSURL *script = [self backendURL];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm isReadableFileAtPath:script.path] || ![fm isExecutableFileAtPath:@"/usr/bin/python3"]) {
        [self showError:@"Monitor backend is unavailable" detail:@"The application bundle is incomplete, or the system Python runtime is unavailable."];
        return;
    }
    NSString *sessionName = [NSString stringWithFormat:@"session-%.0f-%@", NSDate.date.timeIntervalSince1970, NSUUID.UUID.UUIDString];
    self.sessionURL = [[self.supportURL URLByAppendingPathComponent:@"Sessions" isDirectory:YES] URLByAppendingPathComponent:sessionName isDirectory:YES];
    self.statusURL = [self.sessionURL URLByAppendingPathComponent:@"status.json"];
    self.stopURL = [self.sessionURL URLByAppendingPathComponent:@"stop.request"];
    NSError *error = nil;
    // Create the parent only; the backend exclusively creates this new session.
    if (![fm createDirectoryAtURL:self.sessionURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        [self showError:@"Cannot create a session" detail:error.localizedDescription]; return;
    }
    self.generation++;
    self.sessionOutputUID=self.selectedOutputUID;
    NSUInteger generation = self.generation;
    self.lastStatus = nil;
    self.statusInbox = [[FMStatusInbox alloc] init]; self.finishAttempts = 0;
    [self.statusInbox configureMeterPID:0 sessionID:sessionName];
    [self resetMeterTransport];
    [self resetSessionTrims];
    self.stopRequested = NO; self.sentTerminate = NO; self.stopRequestedAt = nil;
    self.startButton.title = @"Stop"; self.startButton.enabled = YES;
    self.inputAccessButton.hidden = YES; [self layoutPermissionDetail];
    self.statusTitle.stringValue = @"Preparing audio…";
    self.statusTitle.textColor = FMInk();
    self.statusDetail.stringValue = @"Preparing BlackHole input and the selected output.";
    self.lastStatusHost = nil; self.lastStatusUptime = 0;
    self.backendStartedUptime = NSProcessInfo.processInfo.systemUptime;
    [self setFormatActive:NO];
    self.formatStateLabel.stringValue = @"STARTING";
    [self layoutFaceplateShowingDetails:NO];
    [self resetMeters]; [self.spinner startAnimation:nil];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments = @[@"-B", script.path, @"--session-dir", self.sessionURL.path,
                       @"--status-json", self.statusURL.path, @"--stop-file", self.stopURL.path,
                       @"--output-device", self.sessionOutputUID,
                       @"--parent-pid", [NSString stringWithFormat:@"%d", getpid()]];
    task.currentDirectoryURL = script.URLByDeletingLastPathComponent;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    self.outputPipe = [NSPipe pipe];
    task.standardOutput = self.outputPipe;
    // Drain NDJSON/diagnostics off the main thread into a fixed-size tail buffer.
    // The atomic file is authoritative; bounded NDJSON is a fallback for errors
    // before a session can be created. No UI dispatch backlog retains pipe data.
    task.standardError = self.outputPipe;
    __weak FMAppDelegate *weakSelf = self;
    FMStatusInbox *inbox = self.statusInbox;
    self.outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        [inbox append:data];
    };
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FMAppDelegate *strongSelf = weakSelf;
            if (strongSelf && strongSelf.generation == generation) [strongSelf backendFinished:finished];
        });
    };
    self.backend = task;
    if (![task launchAndReturnError:&error]) {
        self.outputPipe.fileHandleForReading.readabilityHandler = nil;
        self.backend = nil; self.outputPipe = nil;
        [self updatePrimaryControl];
        [self showError:@"Monitor could not start" detail:error.localizedDescription];
        return;
    }
    [self.statusInbox configureMeterPID:task.processIdentifier sessionID:sessionName];
    [self updatePrimaryControl];
    [self refreshTrimPresentation];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(pollBackend:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    // Cheap latest-slot pickup only: no disk reads, no queued UI dispatches.
    // Actual peak updates occur once per new native 1536-frame audio window.
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(consumeFastMeter:) userInfo:nil repeats:YES];
    self.meterTimer.tolerance = 0.002;
    [NSRunLoop.mainRunLoop addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
}

- (void)readStatusFile {
    NSData *data = FMReadStatus(self.statusURL);
    id status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (!FMStatusValid(status) || ![status[@"pid"] isKindOfClass:NSNumber.class] ||
        [status[@"pid"] intValue] != self.backend.processIdentifier) status = nil;
    NSDictionary *fallback = [self.statusInbox snapshot];
    BOOL fallbackMatches = [fallback[@"pid"] isKindOfClass:NSNumber.class] &&
        [fallback[@"pid"] intValue] == self.backend.processIdentifier;
    if (fallbackMatches && (!status || (FMTerminal(fallback) &&
        (!FMTerminal(status) || (!FMCleanupComplete(status) && FMCleanupComplete(fallback)))) ||
        (!FMTerminal(status) && !FMTerminal(fallback) && FMUnsignedNumber(fallback[@"host_ns"], YES) &&
        (!FMUnsignedNumber(status[@"host_ns"], YES) ||
        [fallback[@"host_ns"] unsignedLongLongValue] > [status[@"host_ns"] unsignedLongLongValue])))) status = fallback;
    if (status) [self applyStatus:status];
}

- (void)ingestClipEvents:(id)input {
    if (!FMInputIdentityValid(input)) return;
    id events = input[@"sample_clip_last_event"];
    if (![events isKindOfClass:NSArray.class] || [events count] != 6) return;
    for (id value in events) if (!FMUnsignedNumber(value, NO)) return;
    NSMutableArray *seen = self.clipEventsSeen ? self.clipEventsSeen.mutableCopy : [@[@0,@0,@0,@0,@0,@0] mutableCopy];
    NSMutableIndexSet *newClips = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < 6; index++) {
        if ([events[index] unsignedLongLongValue] > [seen[index] unsignedLongLongValue]) {
            [newClips addIndex:index]; seen[index] = events[index];
        }
    }
    self.clipEventsSeen = seen;
    // Acknowledge once even if the same status is polled again. Clearing the
    // view's latch cannot re-latch an old marker or refresh a held peak.
    if (newClips.count) [self.meterView latchClipChannels:newClips];
}

- (void)showTelemetryProblem:(NSString *)message detail:(NSString *)detail {
    [self.meterView updatePeaks:nil];
    self.telemetryUnavailable = YES;
    [self setFormatActive:NO];
    self.formatStateLabel.stringValue = @"STALE";
    self.formatStateLabel.textColor = FMAmber();
    self.statusTitle.stringValue = message;
    self.statusTitle.textColor = FMAmber();
    self.statusDetail.stringValue = detail;
    self.statusDetail.toolTip = detail;
    [self layoutFaceplateShowingDetails:YES];
    [self refreshTrimPresentation];
}

- (void)applyStatus:(NSDictionary *)status {
    if (!self.backend || !FMStatusValid(status)) return;
    id pid = status[@"pid"];
    if (![pid isKindOfClass:NSNumber.class] || [pid intValue] != self.backend.processIdentifier) return;
    id session = status[@"session_id"];
    BOOL sessionMatches = [session isKindOfClass:NSString.class] && [session isEqual:self.sessionURL.lastPathComponent];
    if ((session && !sessionMatches) || (status[@"trim"] && !sessionMatches)) return;
    BOOL terminal = FMTerminal(status);
    id host = status[@"host_ns"];
    if (!terminal && !FMUnsignedNumber(host, YES)) {
        [self showTelemetryProblem:@"Status timing is invalid" detail:@"Levels are unavailable. Stop the bridge and inspect the session logs."];
        return;
    }
    if (!terminal && self.lastStatusHost && [host unsignedLongLongValue] <= self.lastStatusHost.unsignedLongLongValue) return;
    if ([status isEqualToDictionary:self.lastStatus]) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    self.lastStatus = status; self.lastStatusUptime = now;
    [self consumeTrimState:status[@"trim"]];
    [self refreshTrimPresentation];
    if (FMUnsignedNumber(host, YES)) self.lastStatusHost = host;
    NSString *state = status[@"state"];
    BOOL running = [state isEqualToString:@"running"];
    BOOL stopping = self.stopRequested || [state isEqualToString:@"stopping"];
    BOOL starting = [state isEqualToString:@"starting"];
    [self setFormatActive:FMOutputActive(status, self.sessionOutputUID)];
    self.statusTitle.stringValue = FMStateTitle(status);
    self.statusTitle.textColor = FMInk();
    self.statusDetail.stringValue = @"";
    self.statusTitle.toolTip = FMStateTitle(status);
    [self.formatStateLabel setAccessibilityLabel:FMStateTitle(status)];
    [self updatePrimaryControl];
    if (starting || stopping) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    if (stopping && !terminal) {
        self.formatStateLabel.stringValue = @"RESTORING";
        self.formatStateLabel.textColor = FMAmber();
        self.statusTitle.stringValue = @"Stopping and restoring…";
        self.statusDetail.stringValue = @"Draining queued audio and restoring the output. Keep this window open.";
        [self.meterView updatePeaks:nil];
        [self layoutFaceplateShowingDetails:YES];
        return;
    }
    if ([state isEqualToString:@"failed"]) {
        [self resetMeters];
        [self showError:@"Monitor stopped with an error" detail:FMMessage(status[@"message"], @"See the session logs.")];
        return;
    }
    if (!running) {
        [self resetMeters];
        self.formatStateLabel.stringValue = starting ? @"STARTING" : @"STOPPED";
        [self layoutFaceplateShowingDetails:NO];
        return;
    }
    id input = status[@"input"];
    if (!FMOutputActive(status, self.sessionOutputUID)) {
        [self.meterView updatePeaks:nil];
        [self showError:@"Output format is not confirmed" detail:@"The reported route does not match Dolby Digital 5.1 through the selected output. Stop and check the session logs."];
        return;
    }
    // Prefer any already-arrived fast packet over the slow status window.
    // This slot read is memory-only and does not alter lifecycle state.
    NSDictionary *pendingMeter = [self.statusInbox takeLatestMeter];
    if (pendingMeter) [self applyMeterPacket:pendingMeter];
    [self ingestClipEvents:input];
    if (!FMInputWindowValid(input)) {
        [self showTelemetryProblem:@"Input meters are unavailable" detail:@"Invalid or missing six-channel input levels. Check the session logs; Stop remains available."];
        return;
    }
    NSNumber *first = input[@"level_first_frame"], *count = input[@"level_frames"];
    BOOL slowWindowIsBehindFast = self.lastFastSequence && self.lastInputFirstFrame &&
        first.unsignedLongLongValue <= self.lastInputFirstFrame.unsignedLongLongValue;
    if (slowWindowIsBehindFast) {
        // Ignore equal windows too, even if a slower protocol reports a
        // different window length. They must never refresh fast peak holds.
    } else if (self.lastInputFirstFrame && first.unsignedLongLongValue < self.lastInputFirstFrame.unsignedLongLongValue) {
        if (!self.lastFastSequence) {
            [self showTelemetryProblem:@"Input timing moved backwards" detail:@"Levels are unavailable. Stop the bridge and inspect the session logs."];
            return;
        }
        // Ordinary status snapshots may lag the fast stream. Keep the latest
        // bars, hold and freshness; this record still controls lifecycle.
    } else if (![first isEqual:self.lastInputFirstFrame] || ![count isEqual:self.lastInputFrameCount]) {
        BOOL metersRecovered = self.telemetryUnavailable;
        [self.meterView updatePeaks:input[@"peak_dbfs"]];
        self.lastInputFirstFrame = first; self.lastInputFrameCount = count;
        self.lastMeterUptime = now; self.telemetryUnavailable = NO;
        if (metersRecovered) [self refreshTrimPresentation];
        self.statusWindowsPresented++;
    }
    if (self.telemetryUnavailable) {
        [self showTelemetryProblem:@"Waiting for fresh input levels" detail:@"The previous meter window is unavailable. A new input window is required before levels can resume."];
        return;
    }
    self.formatStateLabel.stringValue = FMTrue(input[@"signal_present"]) ? @"ACTIVE" : @"WAITING";
    self.formatStateLabel.textColor = FMTrue(input[@"signal_present"]) ? FMMint() : FMMuted();
    id errors = status[@"errors"];
    if ([errors isKindOfClass:NSArray.class] && [errors count]) {
        [self showError:@"The bridge reported an error" detail:FMMessage([errors lastObject], FMMessage(status[@"message"], @"See the session logs."))];
    } else {
        [self layoutFaceplateShowingDetails:NO];
        [self presentTrimProblemIfNeeded];
    }
}

- (BOOL)writeStopRequest {
    if (!self.stopURL || ![NSFileManager.defaultManager fileExistsAtPath:self.sessionURL.path]) return NO;
    int fd = open(self.stopURL.path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return errno == EEXIST;
    const char bytes[] = "UI requested graceful stop\n";
    ssize_t count = write(fd, bytes, sizeof(bytes) - 1);
    BOOL closed = close(fd) == 0;
    return count == (ssize_t)sizeof(bytes) - 1 && closed;
}

- (void)pollBackend:(NSTimer *)timer {
    (void)timer;
    [self readStatusFile];
    if (self.backend && !self.stopRequested && self.lastTrimTelemetryUptime &&
        NSProcessInfo.processInfo.systemUptime - self.lastTrimTelemetryUptime > 1.5) {
        [self consumeTrimState:nil]; [self presentTrimProblemIfNeeded];
    }
    if (self.backend && !self.stopRequested && self.trimRequestedUptime > 0 &&
        NSProcessInfo.processInfo.systemUptime - self.trimRequestedUptime > 2.0 &&
        (self.appliedTrimRevision != self.trimRevision || ![self.appliedTrimsDB isEqual:self.requestedTrimsDB])) {
        if (!self.trimProblem.length) self.trimProblem = @"The backend has not acknowledged these trims. The knobs show the request; applied settings remain unconfirmed. Retry a trim or use Reset channel trims.";
        [self refreshTrimPresentation]; [self presentTrimProblemIfNeeded];
    }
    if (self.backend && !self.stopRequested && !FMTerminal(self.lastStatus)) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSTimeInterval statusAge = now - (self.lastStatusUptime ?: self.backendStartedUptime);
        if (statusAge > 2.0) {
            [self showTelemetryProblem:@"Bridge status is not updating" detail:@"Live levels and output state cannot be confirmed. Stop remains available; check the session logs."];
        } else if ([self.lastStatus[@"state"] isEqual:@"running"] && self.lastMeterUptime && now - self.lastMeterUptime > 1.5) {
            [self showTelemetryProblem:@"Input meters stopped updating" detail:@"No fresh input window has arrived. The display is cleared; check the route or stop the bridge."];
        }
    }
    if (!self.stopRequested || !self.backend) return;
    [self writeStopRequest];
    NSTimeInterval waiting = -[self.stopRequestedAt timeIntervalSinceNow];
    if (waiting >= 15 && !self.sentTerminate && self.backend.running) {
        // Signal only the exact NSTask child. Never terminate unrelated audio apps.
        [self.backend terminate]; self.sentTerminate = YES;
        self.statusDetail.stringValue = @"Waiting for the bridge to drain and restore the output. Keep this window open.";
    }
    if (waiting >= 30 && self.backend.running) {
        self.statusDetail.stringValue = @"Restoration is taking longer than expected. The monitor is still waiting for its bridge to finish; session logs have details.";
    }
}

- (void)stopMonitor:(id)sender {
    (void)sender;
    if (!self.backend || self.stopRequested) return;
    self.stopRequested = YES; self.stopRequestedAt = NSDate.date;
    [self invalidateTrimRequests];
    [self updatePrimaryControl];
    self.statusTitle.stringValue = @"Stopping and restoring…";
    self.statusTitle.textColor = FMInk();
    self.statusDetail.stringValue = @"Finishing queued audio and returning the output device to its prior state.";
    [self.spinner startAnimation:nil];
    self.formatStateLabel.stringValue = @"RESTORING";
    self.formatStateLabel.textColor = FMAmber();
    [self.meterView updatePeaks:nil];
    [self layoutFaceplateShowingDetails:YES];
    [self writeStopRequest];
}

- (void)backendFinished:(NSTask *)task {
    if (self.backend != task) return;
    [self readStatusFile];
    if (!FMCleanupComplete(self.lastStatus) && self.finishAttempts++ < 10) {
        // Give the pipe reader at most half a second to consume terminal NDJSON
        // when a refused/unwritable session could not receive a final status file.
        __weak FMAppDelegate *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [weakSelf backendFinished:task];
        });
        return;
    }
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.meterTimer invalidate]; self.meterTimer = nil;
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    [self writeMeterTransportSummary];
    NSData *diagnostics = [self.statusInbox diagnosticSnapshot];
    if ([NSFileManager.defaultManager fileExistsAtPath:self.sessionURL.path]) {
        [diagnostics writeToURL:[self.sessionURL URLByAppendingPathComponent:@"ui_process_output_tail.log"] options:NSDataWritingWithoutOverwriting error:NULL];
    }
    self.backend = nil;
    self.outputPipe = nil;
    [self resetSessionTrims];
    [self.spinner stopAnimation:nil]; [self resetMeters];
    BOOL cleaned = FMCleanupComplete(self.lastStatus);
    self.cleanupUnconfirmed = !cleaned;
    [self updatePrimaryControl];
    [self setFormatActive:NO];
    if (cleaned && task.terminationStatus == 0) {
        self.statusTitle.stringValue = @"Stopped · audio output restored";
        self.statusTitle.textColor = FMInk();
        self.statusDetail.stringValue = @"";
        self.formatStateLabel.stringValue = @"STOPPED";
        [self.formatStateLabel setAccessibilityLabel:@"Stopped · audio output restored"];
        [self layoutFaceplateShowingDetails:NO];
    } else if (cleaned) {
        [self showError:@"Monitor stopped · output restored" detail:FMMessage(self.lastStatus[@"message"], @"The session ended with an error. See the session logs.")];
    } else {
        [self showError:FMIncompleteCleanupTitle(self.lastStatus) detail:FMIncompleteCleanupDetail(self.lastStatus)];
    }
    if (!self.terminationPending) [self refreshInputPermissionPreservingStatus:YES];
    if (self.terminationPending) {
        self.terminationPending = NO;
        // Do not silently close over an unconfirmed restore. No force-kill path.
        [NSApp replyToApplicationShouldTerminate:cleaned];
        if (!cleaned) [self.window makeKeyAndOrderFront:nil];
    }
}

- (void)showSession:(id)sender {
    (void)sender;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *target = self.sessionURL;
    if (!target || ![fm fileExistsAtPath:target.path]) target = [self.supportURL URLByAppendingPathComponent:@"Sessions" isDirectory:YES];
    if (!target || ![fm fileExistsAtPath:target.path]) target = self.supportURL;
    if (target && [fm fileExistsAtPath:target.path]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[target]];
    else [self showHelp:@"Session logs" text:@"No session logs exist yet. Starting the monitor creates a session in ~/Library/Application Support/FOI Surround Monitor/Sessions. No audio starts when you open this menu."];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    [NSApp terminate:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (!self.backend) {
        if (!self.cleanupUnconfirmed) return NSTerminateNow;
        id cleanup = self.lastStatus[@"cleanup"];
        if (![cleanup isKindOfClass:NSDictionary.class] || !FMTrue(cleanup[@"children_reaped"])) {
            [self showError:@"Child-process cleanup was not confirmed" detail:@"Start and ordinary Quit remain disabled. The bridge did not confirm that all of its child processes stopped; check the session logs."];
            [self.window makeKeyAndOrderFront:nil];
            return NSTerminateCancel;
        }
        NSAlert *alert = [[NSAlert alloc] init];
        if (FMTrue(cleanup[@"output_restored"]) && !FMTrue(cleanup[@"input_stopped"]))
            alert.messageText = @"Audio output was restored; input cleanup was not confirmed.";
        else if (!FMTrue(cleanup[@"output_restored"]))
            alert.messageText = @"Audio output restoration was not confirmed.";
        else
            alert.messageText = @"Session cleanup was not fully confirmed.";
        alert.informativeText = @"All monitor processes have stopped. Keep the window open to inspect the session logs, or quit after reviewing this failure.";
        [alert addButtonWithTitle:@"Keep Open"];
        [alert addButtonWithTitle:@"Quit"];
        return [alert runModal] == NSAlertSecondButtonReturn ? NSTerminateNow : NSTerminateCancel;
    }
    if (!self.terminationPending) {
        self.terminationPending = YES;
        [self stopMonitor:nil];
    }
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.pollTimer invalidate];
    [self.meterTimer invalidate];
    [self invalidateTrimRequests];
    if (self.lockFD >= 0) { flock(self.lockFD, LOCK_UN); close(self.lockFD); self.lockFD = -1; }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender; (void)flag;
    [self.window makeKeyAndOrderFront:nil];
    return YES;
}
@end

static int FMProtocolSelfTest(void) {
    NSDictionary *clean = @{@"complete":@YES, @"input_stopped":@YES, @"output_restored":@YES, @"children_reaped":@YES};
    NSDictionary *stopped = @{@"schema_version":@1, @"state":@"stopped", @"cleanup":clean};
    NSUInteger tests = 0; BOOL ok = YES;
    tests++; ok &= FMStatusValid(stopped);
    tests++; ok &= !FMStatusValid(@[@"invalid"]);
    tests++; ok &= !FMStatusValid(@{@"schema_version":@2, @"state":@"running"});
    tests++; ok &= !FMStatusValid(@{@"schema_version":@1, @"state":@"unknown"});
    tests++; ok &= FMCleanupComplete(stopped);
    tests++; ok &= !FMCleanupComplete(@{@"cleanup":@{@"complete":@YES, @"input_stopped":@YES, @"output_restored":@NO}});
    tests++; ok &= !FMCleanupComplete(@{@"cleanup":@{@"complete":@YES, @"input_stopped":@YES, @"output_restored":@YES, @"children_reaped":@NO}});
    tests++; ok &= [FMStateTitle(@{@"state":@"running", @"input":@{@"signal_present":@NO}}) containsString:@"waiting"];
    tests++; ok &= [FMStateTitle(@{@"state":@"running", @"input":@{@"signal_present":@YES}}) containsString:@"signal present"];
    tests++; ok &= [FMStateTitle(stopped) containsString:@"restored"];
    tests++; ok &= [FMMessage(NSNull.null, @"fallback") isEqualToString:@"fallback"];
    tests++; ok &= FMMessage([@"x" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0], @"").length == 180;
    NSMutableData *diagnostics = [NSMutableData data];
    FMAppendDiagnostics(diagnostics, [NSMutableData dataWithLength:FMMaximumDiagnosticBytes * 4]);
    tests++; ok &= diagnostics.length == FMMaximumDiagnosticBytes;
    FMAppendDiagnostics(diagnostics, [NSMutableData dataWithLength:100]);
    tests++; ok &= diagnostics.length == FMMaximumDiagnosticBytes;
    FMStatusInbox *inbox = [[FMStatusInbox alloc] init];
    [inbox append:[@"{\"schema_version\":1,\"state\":\"stopp" dataUsingEncoding:NSUTF8StringEncoding]];
    [inbox append:[@"ed\",\"pid\":123,\"cleanup\":{\"complete\":true,\"input_stopped\":true,\"output_restored\":true,\"children_reaped\":true}}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    tests++; ok &= FMCleanupComplete([inbox snapshot]);
    [inbox append:[NSMutableData dataWithLength:FMMaximumStatusBytes * 2]];
    tests++; ok &= inbox.partial.length == 0 && inbox.discardingLine && inbox.diagnosticSnapshot.length == FMMaximumDiagnosticBytes;
    [inbox append:[@"\n{\"schema_version\":1,\"state\":\"running\",\"pid\":123}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    tests++; ok &= FMTerminal([inbox snapshot]) && !inbox.discardingLine;
    tests++; ok &= FMInputMayStart(AVAuthorizationStatusAuthorized);
    tests++; ok &= !FMInputMayStart(AVAuthorizationStatusNotDetermined);
    tests++; ok &= !FMInputMayStart(AVAuthorizationStatusDenied);
    tests++; ok &= !FMInputMayStart(AVAuthorizationStatusRestricted);
    tests++; ok &= FMInputMayRequest(AVAuthorizationStatusNotDetermined);
    tests++; ok &= !FMInputMayRequest(AVAuthorizationStatusAuthorized) && !FMInputMayRequest(AVAuthorizationStatusDenied) && !FMInputMayRequest(AVAuthorizationStatusRestricted);
    NSDictionary *inputUnconfirmed = @{@"cleanup":@{@"complete":@NO, @"input_stopped":@NO, @"output_restored":@YES, @"children_reaped":@YES}};
    tests++; ok &= [FMIncompleteCleanupTitle(inputUnconfirmed) isEqualToString:@"Output restored · input cleanup unconfirmed"];
    tests++; ok &= [FMIncompleteCleanupDetail(inputUnconfirmed) containsString:@"audio output was restored"];
    tests++; ok &= [FMIncompleteCleanupTitle(@{@"cleanup":@{@"output_restored":@NO}}) containsString:@"Output restoration"];
    tests++; ok &= [FMSupportName isEqualToString:@"FOI Surround Monitor"] && [FMName isEqualToString:FMSupportName];
    tests++; ok &= [FMSharedLockSupportName isEqualToString:@"Fairlight 5.1 Monitor"] && [FMSettingsSuite isEqualToString:@"studio.foi.surroundmonitor"];
    tests++; ok &= [FMFormat isEqualToString:@"Dolby Digital 5.1 · 48 kHz"];
    tests++; ok &= FMUnsignedNumber(@0, NO) && !FMUnsignedNumber(@0, YES) && !FMUnsignedNumber(@YES, NO);
    tests++; ok &= !FMUnsignedNumber(@(-1), NO) && !FMUnsignedNumber(@0.5, NO) && !FMUnsignedNumber(@(NAN), NO);
    NSMutableDictionary *input = [@{@"uid":@"BlackHole16ch_UID", @"channels":@6, @"sample_rate":@48000,
        @"channel_order":@[@"FL",@"FR",@"FC",@"LFE",@"SL",@"SR"], @"level_first_frame":@0,
        @"level_frames":@12288, @"peak_dbfs":@[@(-18),@(-17),@(-20),@(-35),@(-30),@(-31)]} mutableCopy];
    tests++; ok &= FMInputWindowValid(input);
    input[@"peak_dbfs"] = @[@(-18),@(-17),NSNull.null,@(-35),@(-30),@(-31)];
    tests++; ok &= !FMInputWindowValid(input);
    input[@"peak_dbfs"] = @[@(-18),@(-17),@(INFINITY),@(-35),@(-30),@(-31)];
    tests++; ok &= !FMInputWindowValid(input);
    input[@"peak_dbfs"] = @[@(-18),@(-17),@(-20),@(-35),@(-30),@(-31)]; input[@"channels"] = @2;
    tests++; ok &= !FMInputWindowValid(input);
    NSDictionary *encoder = @{@"codec":@"AC-3",@"sample_rate":@48000,@"channels":@6,@"bitrate":@448000};
    NSDictionary *output = @{@"name":@"Test digital output",@"uid":@"test-output-uid",@"started":@YES};
    NSMutableDictionary *active = [@{@"state":@"running",@"ready":@YES,@"encoder":encoder,@"output":output} mutableCopy];
    tests++; ok &= FMOutputActive(active,@"test-output-uid");
    tests++; ok &= !FMOutputActive(active,@"different-output") && !FMOutputActive(active,nil);
    active[@"ready"] = @NO; tests++; ok &= !FMOutputActive(active,@"test-output-uid");
    active[@"ready"] = @YES; active[@"encoder"] = @{@"codec":@"PCM",@"sample_rate":@48000,@"channels":@2,@"bitrate":@448000};
    tests++; ok &= !FMOutputActive(active,@"test-output-uid");
    NSDictionary *candidate=@{@"uid":@"test-output-uid",@"name":@"Test digital output",@"sample_rate":@48000,@"encoded_format":@"cac3"};
    tests++; ok &= FMOutputCandidateValid(candidate);
    tests++; ok &= !FMOutputCandidateValid(@{@"uid":@"",@"name":@"Bad",@"sample_rate":@48000,@"encoded_format":@"cac3"});
    tests++; ok &= !FMOutputCandidateValid(@{@"uid":@"x",@"name":@"PCM",@"sample_rate":@48000,@"encoded_format":@"lpcm"});
    tests++; ok &= FMOutputDiscoveryValid(@{@"schema_version":@1,@"outputs":@[candidate]});
    tests++; ok &= FMOutputDiscoveryValid(@{@"schema_version":@1,@"outputs":@[]});
    tests++; ok &= !FMOutputDiscoveryValid(@{@"schema_version":@1,@"outputs":@[candidate,candidate]});
    tests++; ok &= !FMOutputDiscoveryValid(@{@"schema_version":@YES,@"outputs":@[]});
    tests++; ok &= !FMOutputDiscoveryValid(@{@"schema_version":@1,@"outputs":NSNull.null});
    input[@"channels"] = @6; input[@"level_frames"] = @1536;
    FMStatusInbox *fastInbox = [[FMStatusInbox alloc] init];
    for (NSUInteger i = 1; i <= 100; i++) {
        input[@"level_first_frame"] = @((i - 1) * 1536);
        input[@"peak_dbfs"] = @[@(i == 1 ? 0 : -40),@(-40),@(-40),@(-40),@(-40),@(-40)];
        NSDictionary *packet = @{@"schema_version":@1,@"type":@"meter",@"pid":@123,@"session_id":@"self-test",
            @"host_ns":@(i * 32000000ULL),@"level_sequence":@(i),@"input":input};
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:packet options:0 error:NULL] mutableCopy];
        [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [fastInbox append:[line subdataWithRange:NSMakeRange(0, 9)]];
        [fastInbox append:[line subdataWithRange:NSMakeRange(9, line.length - 9)]];
    }
    tests++; ok &= fastInbox.diagnosticSnapshot.length == 0 && fastInbox.snapshot == nil;
    NSDictionary *latestMeter = [fastInbox takeLatestMeter];
    tests++; ok &= FMMeterEnvelopeValid(latestMeter) && [latestMeter[@"level_sequence"] isEqual:@100];
    tests++; ok &= [latestMeter[@"input"][@"peak_dbfs"][0] isEqual:@(-40)] && [latestMeter[@"ui_pending_peak_maxima"][0] isEqual:@0];
    tests++; ok &= [fastInbox takeLatestMeter] == nil && fastInbox.latestMeter == nil && fastInbox.pendingMeterMaxima == nil;
    NSDictionary *fastStats = [fastInbox meterStatistics];
    tests++; ok &= [fastStats[@"packets_received"] isEqual:@100] && [fastStats[@"packets_coalesced"] isEqual:@99] && [fastStats[@"packets_taken"] isEqual:@1];
    for (NSNumber *sequence in @[@99,@101]) {
        input[@"level_first_frame"] = @(([sequence unsignedLongLongValue] - 1) * 1536);
        input[@"peak_dbfs"] = @[@([sequence isEqual:@99] ? 0 : -40),@(-40),@(-40),@(-40),@(-40),@(-40)];
        NSDictionary *packet = @{@"schema_version":@1,@"type":@"meter",@"pid":@123,@"session_id":@"self-test",
            @"host_ns":@([sequence unsignedLongLongValue] * 32000000ULL),@"level_sequence":sequence,@"input":input};
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:packet options:0 error:NULL] mutableCopy];
        [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [fastInbox append:line];
    }
    NSDictionary *afterReplay = [fastInbox takeLatestMeter];
    tests++; ok &= [afterReplay[@"level_sequence"] isEqual:@101] && [afterReplay[@"ui_pending_peak_maxima"][0] isEqual:@(-40)];
    tests++; ok &= [[fastInbox meterStatistics][@"packets_rejected_in_inbox"] isEqual:@1];
    [fastInbox append:[@"{\"schema_version\":1,\"state\":\"failed\",\"pid\":123}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    tests++; ok &= FMTerminal(fastInbox.snapshot) && fastInbox.diagnosticSnapshot.length > 0;
    NSMutableDictionary *badMeter = latestMeter.mutableCopy; badMeter[@"level_sequence"] = @0;
    tests++; ok &= !FMMeterEnvelopeValid(badMeter);
    badMeter[@"level_sequence"] = @101; badMeter[@"session_id"] = NSNull.null;
    tests++; ok &= !FMMeterEnvelopeValid(badMeter);
    badMeter[@"session_id"] = @"self-test"; badMeter[@"host_ns"] = @(NAN);
    tests++; ok &= !FMMeterEnvelopeValid(badMeter);
    tests++; ok &= FMTrimsValid(FMUnityTrims());
    tests++; ok &= FMTrimsValid(@[NSNull.null,@(-60),@6,@0.1,@(-3.2),@0]);
    tests++; ok &= !FMTrimsValid(@[@0,@0,@0,@0,@0]);
    tests++; ok &= !FMTrimsValid(@[@YES,@0,@0,@0,@0,@0]);
    tests++; ok &= !FMTrimsValid(@[@6.1,@0,@0,@0,@0,@0]) && !FMTrimsValid(@[@(-60.1),@0,@0,@0,@0,@0]);
    tests++; ok &= !FMTrimsValid(@[@0.15,@0,@0,@0,@0,@0]) && !FMTrimsValid(@[@(NAN),@0,@0,@0,@0,@0]);
    NSMutableDictionary *trimState = [@{@"requested_revision":@0,@"applied_revision":@0,
        @"requested_trims_db":FMUnityTrims(),@"applied_trims_db":FMUnityTrims(),@"ramp_frames":@960,@"error":NSNull.null} mutableCopy];
    tests++; ok &= FMTrimStateValid(trimState);
    trimState[@"requested_revision"] = @1; trimState[@"requested_trims_db"] = @[NSNull.null,@(-3),@0,@0,@0,@0];
    tests++; ok &= FMTrimStateValid(trimState);
    trimState[@"applied_revision"] = @2; tests++; ok &= !FMTrimStateValid(trimState);
    trimState[@"applied_revision"] = @0; trimState[@"applied_trims_db"] = @[@1,@0,@0,@0,@0,@0];
    tests++; ok &= !FMTrimStateValid(trimState);
    trimState[@"applied_revision"] = @1; trimState[@"applied_trims_db"] = @[NSNull.null,@(-3),@0,@0,@0,@0];
    tests++; ok &= FMTrimStateValid(trimState);
    trimState[@"error"] = @YES; tests++; ok &= !FMTrimStateValid(trimState);
    printf("{\"result\":\"%s\",\"tests\":%lu,\"GUI_launched\":false,\"hardware_access\":false}\n", ok ? "PASS" : "FAIL", (unsigned long)tests);
    return ok ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return FMProtocolSelfTest();
        if (argc != 1) { fprintf(stderr, "Usage: FOISurroundMonitor [--self-test]\n"); return 2; }
        NSApplication *app = [NSApplication sharedApplication];
        FMAppDelegate *delegate = [[FMAppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
