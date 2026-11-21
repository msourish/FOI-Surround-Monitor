#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Six capture-input sample peaks in L, R, C, LFE, Ls, Rs order. Use on the main thread.
@interface FMInputMeterView : NSView

@property(nonatomic) BOOL roomMode;

/// Send each fresh measurement once. A missing/nonfinite value clears that channel's
/// readout and hold. A latched clip remains visible until explicitly cleared.
- (void)updatePeaks:(nullable NSArray *)peaks;
/// Apply the accumulated maxima from newly received, coalesced sample windows after
/// updatePeaks:. Changes held peak/clip only. The current readout and input age stay exact.
- (void)holdPeaks:(nullable NSArray *)peaks;
/// Mark a clip reported between visible peak windows. Indexes are zero based.
- (void)latchClipChannels:(NSIndexSet *)channels;
- (void)resetLevels;
- (void)clearClips;

@end

NS_ASSUME_NONNULL_END
