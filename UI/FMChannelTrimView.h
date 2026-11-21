#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Main-thread, six-channel monitor trims in L, R, C, LFE, Ls, Rs order.
/// Designed for a 96-point strip; the top 19 points are reserved for a status caption.
@interface FMChannelTrimView : NSView
/// Six dB numbers from -60 to +6 (0 = unity); NSNull is hard mute. Setting is silent.
/// Invalid arrays are ignored, so restoring a malformed state cannot undo a live trim.
@property(nonatomic,copy) NSArray *trimsDB;
/// One complete immutable snapshot per user change.
@property(nonatomic,copy,nullable) void (^changeHandler)(NSArray *trimsDB);
@property(nonatomic,getter=isEnabled) BOOL enabled;
@end

NS_ASSUME_NONNULL_END
