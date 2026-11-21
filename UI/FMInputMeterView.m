#import "FMInputMeterView.h"
#import <QuartzCore/CADisplayLink.h>
#import <math.h>

enum { FMChannelCount = 6 };
static NSString * const FMChannelNames[] = {@"L", @"R", @"C", @"LFE", @"Ls", @"Rs"};
static NSString * const FMChannelLabels[] = {
    @"Front left", @"Front right", @"Center", @"Low-frequency effects",
    @"Left surround", @"Right surround"
};
static const double FMScaleFloor = -60.0;
static const double FMCaptureFloor = -120.0;
static const double FMHoldSeconds = 1.25;
static const double FMHoldFallDBPerSecond = 18.0;
static const double FMStaleSeconds = 2.0;
static const double FMAttackSeconds = .012;
static const double FMReleaseDBPerSecond = 32.0;
static const double FMFrameSeconds = 1.0/60.0;

typedef struct {
    double sample;
    double peak;
    double holdUntil;
    double updatedAt;
    double barOrigin;
    BOOL available;
    BOOL clipped;
} FMChannelReading;

static double FMRange(double value) {
    return fmin(1.0, fmax(0.0, (value - FMScaleFloor) / -FMScaleFloor));
}

static double FMHeld(FMChannelReading reading, double now) {
    double elapsed = fmax(0.0, now - reading.holdUntil);
    return fmax(reading.sample, reading.peak - elapsed * FMHoldFallDBPerSecond);
}

static BOOL FMFresh(FMChannelReading reading, double now) {
    return reading.available && now - reading.updatedAt < FMStaleSeconds;
}

// Exact elapsed-time ballistics. Retargeting uses the position reached at the input
// timestamp, so coalesced drawings and different monitor refresh rates produce the same curve.
static double FMBarTarget(double db) { return fmin(0.0,fmax(FMScaleFloor,db)); }

static double FMBar(FMChannelReading reading, double now) {
    if (!FMFresh(reading,now)) return FMScaleFloor;
    double target = FMBarTarget(reading.sample);
    double t = fmax(0.0,now-reading.updatedAt);
    if (target <= reading.barOrigin) {
        return fmax(target,reading.barOrigin-t*FMReleaseDBPerSecond);
    }
    double gap = (target-reading.barOrigin)*exp(-t/FMAttackSeconds);
    return gap < .025 ? target : target-gap;
}

static NSColor *FMRGB(unsigned int rgb) {
    // This small palette is used for every segment at every refresh on the main thread.
    static NSMutableDictionary<NSNumber *, NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ palette = [[NSMutableDictionary alloc] init]; });
    NSNumber *key = @(rgb);
    NSColor *color = palette[key];
    if (!color) {
        color = [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                                   green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1.0];
        palette[key] = color;
    }
    return color;
}

static void FMRounded(NSRect rect, CGFloat radius, NSColor *fill, NSColor *stroke) {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    if (fill) { [fill setFill]; [path fill]; }
    if (stroke) { [stroke setStroke]; path.lineWidth = 1.0; [path stroke]; }
}

static void FMStrokeLine(NSPoint start, NSPoint end, NSColor *color, CGFloat width) {
    [color setStroke];
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:start]; [path lineToPoint:end];
    path.lineWidth = width; [path stroke];
}

static void FMText(NSString *text, NSRect box, NSFont *font, NSColor *color, NSTextAlignment alignment) {
    static NSParagraphStyle *styles[3];
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSTextAlignment alignments[] = {NSTextAlignmentLeft,NSTextAlignmentCenter,NSTextAlignmentRight};
        for (NSUInteger i=0;i<3;i++) {
            NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
            style.alignment = alignments[i];
            style.lineBreakMode = NSLineBreakByClipping;
            styles[i] = [style copy];
        }
    });
    NSUInteger style = alignment == NSTextAlignmentCenter ? 1 : (alignment == NSTextAlignmentRight ? 2 : 0);
    [text drawInRect:box withAttributes:@{
        NSFontAttributeName:font, NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:styles[style]
    }];
}

static NSString *FMReadout(FMChannelReading reading, double now) {
    if (!FMFresh(reading, now)) return @"—";
    if (reading.sample <= FMCaptureFloor) return @"−∞";
    return [[NSString stringWithFormat:@"%.1f", reading.sample]
            stringByReplacingOccurrencesOfString:@"-" withString:@"−"];
}

static NSColor *FMActiveColor(double db) {
    if (db >= -1.0) return FMRGB(0xFFB269);
    if (db >= -6.0) return FMRGB(0xDAB878);
    if (db >= -18.0) return FMRGB(0x79DAC3);
    return FMRGB(0x54A99B);
}

@interface FMInputMeterView ()
@property(nonatomic, strong) NSArray<NSAccessibilityElement *> *channelElements;
- (NSNumber *)valueForChannel:(NSUInteger)channel;
- (NSString *)valueDescriptionForChannel:(NSUInteger)channel;
@end

// VoiceOver reads the same unfiltered measurements as the numeric readouts on demand.
// Animating a fill or changing another channel generates no accessibility value traffic.
@interface FMInputPeakElement : NSAccessibilityElement
@property(nonatomic, weak) FMInputMeterView *meter;
@property(nonatomic) NSUInteger channel;
@end
@implementation FMInputPeakElement
- (id)accessibilityValue { return [self.meter valueForChannel:self.channel]; }
- (NSString *)accessibilityValueDescription { return [self.meter valueDescriptionForChannel:self.channel]; }
@end

@implementation FMInputMeterView {
    FMChannelReading _readings[FMChannelCount];
    CADisplayLink *_displayLink API_AVAILABLE(macos(14.0));
    NSTimer *_frameTimer;
    NSTimer *_deadlineTimer;
    double _deadlineAt;
    NSImage *_backplate;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self configureMeters];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self configureMeters];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)configureMeters {
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = @"Captured 5.1 input peaks";
    NSMutableArray *elements = [NSMutableArray arrayWithCapacity:FMChannelCount];
    for (NSInteger i = 0; i < FMChannelCount; i++) {
        FMInputPeakElement *element = [[FMInputPeakElement alloc] init];
        element.accessibilityParent = self;
        element.accessibilityRole = NSAccessibilityLevelIndicatorRole;
        element.accessibilityLabel = FMChannelLabels[i];
        element.meter = self;
        element.channel = (NSUInteger)i;
        element.accessibilityIdentifier = [@"inputPeak." stringByAppendingString:FMChannelNames[i]];
        [elements addObject:element];
    }
    self.channelElements = elements;
    self.accessibilityChildren = elements;
    [self resetLevels];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateAccessibilityFrames];
    [self refreshAt:NSProcessInfo.processInfo.systemUptime];
}

- (void)viewDidHide {
    [super viewDidHide];
    [self stopDrivers];
}

- (void)viewDidUnhide {
    [super viewDidUnhide];
    [self refreshAt:NSProcessInfo.processInfo.systemUptime];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    _backplate = nil;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    [self updateAccessibilityFrames];
}

- (void)setRoomMode:(BOOL)roomMode {
    if (_roomMode == roomMode) return;
    _roomMode = roomMode;
    _backplate = nil;
    [self updateAccessibilityFrames];
    self.needsDisplay = YES;
}

- (void)updatePeaks:(NSArray *)peaks {
    double now = NSProcessInfo.processInfo.systemUptime;
    if (![peaks isKindOfClass:NSArray.class]) peaks = nil;
    BOOL changed = NO;
    for (NSInteger i = 0; i < FMChannelCount; i++) {
        id raw = i < (NSInteger)peaks.count ? peaks[i] : nil;
        BOOL numeric = [raw isKindOfClass:NSNumber.class] &&
                       CFGetTypeID((__bridge CFTypeRef)raw) != CFBooleanGetTypeID();
        double db = numeric ? [raw doubleValue] : NAN;
        FMChannelReading *reading = &_readings[i];
        if (!isfinite(db)) {
            changed |= reading->available;
            reading->available = NO;
            continue;
        }
        BOOL fresh = FMFresh(*reading,now);
        changed |= !fresh || reading->sample != db || (db >= 0 && !reading->clipped);
        double origin = fresh ? FMBar(*reading,now) : FMBarTarget(db);
        // A measured burst can arrive and fall between two screen refreshes. Start
        // its release from the captured peak so the transient still reaches the fill.
        if (fresh && db < reading->sample) origin = fmax(origin,FMBarTarget(reading->sample));
        reading->barOrigin = origin;
        if (!fresh || db >= FMHeld(*reading, now)) {
            reading->peak = db;
            reading->holdUntil = now + FMHoldSeconds;
        }
        reading->updatedAt = now;
        reading->available = YES;
        reading->sample = db;
        if (db >= 0.0) reading->clipped = YES;
    }
    [self scheduleAt:now];
    if (changed) self.needsDisplay = YES;
}

- (void)resetLevels {
    memset(_readings, 0, sizeof(_readings));
    [self stopDrivers];
    self.needsDisplay = YES;
}

- (void)holdPeaks:(NSArray *)peaks {
    if (![peaks isKindOfClass:NSArray.class]) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL changed = NO;
    for (NSUInteger i=0;i<MIN(peaks.count,(NSUInteger)FMChannelCount);i++) {
        id value = peaks[i];
        if (![value isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) continue;
        double db = [value doubleValue];
        if (!isfinite(db)) continue;
        FMChannelReading *r = &_readings[i];
        if (FMFresh(*r,now) && db > r->sample && db >= FMHeld(*r,now)) {
            r->peak = db;
            r->holdUntil = now+FMHoldSeconds;
            changed = YES;
        }
        if (db >= 0 && !r->clipped) { r->clipped = YES; changed = YES; }
    }
    if (changed) { self.needsDisplay = YES; [self scheduleAt:now]; }
}

- (void)clearClips {
    for (NSInteger i = 0; i < FMChannelCount; i++) _readings[i].clipped = NO;
    self.needsDisplay = YES;
}

- (void)latchClipChannels:(NSIndexSet *)channels {
    for (NSUInteger i = 0; i < FMChannelCount; i++) {
        if ([channels containsIndex:i]) _readings[i].clipped = YES;
    }
    self.needsDisplay = YES;
}

- (BOOL)animationVisible { return self.window != nil && !self.hiddenOrHasHiddenAncestor; }

- (void)stopFrameDriver {
    if (@available(macOS 14.0,*)) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    [_frameTimer invalidate];
    _frameTimer = nil;
}

- (void)stopDrivers {
    [self stopFrameDriver];
    [_deadlineTimer invalidate];
    _deadlineTimer = nil;
}

- (void)frameTick:(id)sender {
    (void)sender;
    [self refreshAt:NSProcessInfo.processInfo.systemUptime];
}

- (void)startFrameDriver {
    if (@available(macOS 14.0,*)) {
        if (_displayLink) return;
        if (self.window) {
            _displayLink = [self displayLinkWithTarget:self selector:@selector(frameTick:)];
            _displayLink.preferredFrameRateRange = (CAFrameRateRange){60,60,60};
            [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            if (_displayLink) return;
        }
    }
    if (_frameTimer) return;
    __weak FMInputMeterView *weakView = self;
    _frameTimer = [NSTimer timerWithTimeInterval:FMFrameSeconds repeats:YES block:^(NSTimer *timer) {
        FMInputMeterView *view = weakView;
        if (view) [view frameTick:timer]; else [timer invalidate];
    }];
    _frameTimer.tolerance = .0005;
    [NSRunLoop.mainRunLoop addTimer:_frameTimer forMode:NSRunLoopCommonModes];
}

- (void)scheduleAt:(double)now {
    if (![self animationVisible]) { [self stopDrivers]; return; }
    BOOL moving = NO;
    double next = INFINITY;
    for (NSInteger i = 0; i < FMChannelCount; i++) {
        FMChannelReading r = _readings[i];
        if (!FMFresh(r,now)) continue;
        next = fmin(next,r.updatedAt+FMStaleSeconds);
        double target = FMBarTarget(r.sample);
        moving |= FMBar(r,now) != target;
        if (FMBarTarget(FMHeld(r,now)) > target) {
            if (now >= r.holdUntil) moving = YES;
            else next = fmin(next,r.holdUntil);
        }
    }
    if (moving) [self startFrameDriver]; else [self stopFrameDriver];

    // Hold and stale transitions may fall well after motion has settled. One
    // one-shot wakeup covers them without polling at the animation rate.
    if (_deadlineTimer && _deadlineAt <= next && isfinite(next)) return;
    [_deadlineTimer invalidate];
    _deadlineTimer = nil;
    if (!isfinite(next)) return;
    _deadlineAt = next;
    __weak FMInputMeterView *weakView = self;
    _deadlineTimer = [NSTimer timerWithTimeInterval:fmax(.001,next-now) repeats:NO block:^(NSTimer *timer) {
        FMInputMeterView *view = weakView;
        if (!view) return;
        if (view->_deadlineTimer == timer) view->_deadlineTimer = nil;
        [view refreshAt:NSProcessInfo.processInfo.systemUptime];
    }];
    [NSRunLoop.mainRunLoop addTimer:_deadlineTimer forMode:NSRunLoopCommonModes];
}

- (void)refreshAt:(double)now {
    for (NSInteger i=0;i<FMChannelCount;i++) {
        if (_readings[i].available && !FMFresh(_readings[i],now)) _readings[i].available = NO;
    }
    self.needsDisplay = YES;
    [self scheduleAt:now];
}

- (NSNumber *)valueForChannel:(NSUInteger)channel {
    FMChannelReading r = _readings[channel];
    return FMFresh(r,NSProcessInfo.processInfo.systemUptime) ? @(r.sample) : nil;
}

- (NSString *)valueDescriptionForChannel:(NSUInteger)channel {
    FMChannelReading r = _readings[channel];
    NSString *description = @"No current input reading";
    if (FMFresh(r,NSProcessInfo.processInfo.systemUptime)) {
        description = r.sample <= FMCaptureFloor ? @"Silence at the meter floor"
            : [NSString stringWithFormat:@"%.1f dBFS",r.sample];
    }
    return r.clipped ? [description stringByAppendingString:@", clip latched"] : description;
}

- (NSRect)roomCard:(NSInteger)channel {
    // LFE is a separate meter below the listening point. It has no directional ray.
    static const CGFloat position[FMChannelCount][2] = {
        {.185,.27}, {.815,.27}, {.50,.145}, {.50,.856}, {.185,.742}, {.815,.742}
    };
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat cardWidth = fmin(84.0, fmax(76.0, width * .15));
    CGFloat cardHeight = fmin(45.0, height * .178);
    return NSMakeRect(round(width*position[channel][0]-cardWidth/2.0),
                      round(height*position[channel][1]-cardHeight/2.0), cardWidth, cardHeight);
}

- (NSRect)channelColumn:(NSInteger)channel {
    CGFloat left = 44.0, right = 13.0;
    CGFloat width = fmax(1.0, (NSWidth(self.bounds)-left-right)/FMChannelCount);
    return NSMakeRect(left+channel*width, 0.0, width, NSHeight(self.bounds));
}

- (void)updateAccessibilityFrames {
    for (NSInteger i = 0; i < (NSInteger)self.channelElements.count; i++) {
        NSRect rect = self.roomMode ? [self roomCard:i] : [self channelColumn:i];
        // Accessibility element frames in parent space are measured from the lower left.
        rect.origin.y = NSHeight(self.bounds)-NSMaxY(rect);
        self.channelElements[i].accessibilityFrameInParentSpace = rect;
    }
}

- (NSRect)railForChannel:(NSInteger)i {
    NSRect column = [self channelColumn:i];
    CGFloat width = fmin(33.0,fmax(17.0,NSWidth(column)*.43));
    return NSMakeRect(round(NSMidX(column)-width*.5),41,width,NSHeight(self.bounds)-78);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (NSWidth(self.bounds)<80 || NSHeight(self.bounds)<80) return;
    if (!_backplate || !NSEqualSizes(_backplate.size,self.bounds.size)) {
        __weak FMInputMeterView *weakView = self;
        _backplate = [NSImage imageWithSize:self.bounds.size flipped:YES drawingHandler:^BOOL(NSRect dstRect) {
            (void)dstRect;
            FMInputMeterView *view = weakView;
            if (!view) return NO;
            FMRounded(NSInsetRect(view.bounds,.5,.5),11,FMRGB(0x111617),FMRGB(0x323B3B));
            if (view.roomMode) [view drawRoomBackplate]; else [view drawMeterBackplate];
            return YES;
        }];
        _backplate.cacheMode = NSImageCacheAlways;
    }
    [_backplate drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                  fraction:1.0 respectFlipped:YES hints:nil];
    double now = NSProcessInfo.processInfo.systemUptime;
    if (self.roomMode) [self drawRoomAt:now]; else [self drawMeterBankAt:now];
}

- (void)drawMeterBackplate {
    NSFont *scale = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium];
    NSFont *label = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSColor *muted=FMRGB(0x9AA9A9);
    FMText(@"dBFS",NSMakeRect(8,14,28,15),scale,muted,NSTextAlignmentRight);
    const int divisions[] = {0,-6,-12,-18,-24,-36,-48,-60};
    NSRect first = [self railForChannel:0];
    for (size_t j=0;j<sizeof(divisions)/sizeof(divisions[0]);j++) {
        int db=divisions[j];
        CGFloat y=round(NSMaxY(first)-FMRange(db)*NSHeight(first))+.5;
        FMStrokeLine(NSMakePoint(40,y),NSMakePoint(NSWidth(self.bounds)-15,y),FMRGB(0x273031),.7);
        NSString *text=db==0 ? @"0" : [NSString stringWithFormat:@"−%d",-db];
        FMText(text,NSMakeRect(6,y-6,29,13),scale,muted,NSTextAlignmentRight);
    }
    for (NSInteger i=0;i<FMChannelCount;i++) {
        NSRect column=[self channelColumn:i], rail=[self railForChannel:i];
        if (i==3) FMRounded(NSMakeRect(NSMidX(column)-18,10,36,21),5,FMRGB(0x242E2E),nil);
        FMText(FMChannelNames[i],NSMakeRect(NSMinX(column),13,NSWidth(column),17),
               label,FMRGB(0xD4DEDD),NSTextAlignmentCenter);
        FMRounded(NSInsetRect(rail,-2,-2),3,FMRGB(0x0B0E0F),nil);
        CGFloat step=NSHeight(rail)/24;
        [FMRGB(0x253032) setFill];
        for (NSInteger j=0;j<24;j++) {
            NSRectFill(NSMakeRect(NSMinX(rail),NSMinY(rail)+j*step+.65,NSWidth(rail),step-1.3));
        }
    }
}

- (void)drawMeterBankAt:(double)now {
    NSFont *digits=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    for (NSInteger i=0;i<FMChannelCount;i++) {
        FMChannelReading r=_readings[i];
        NSRect column=[self channelColumn:i],rail=[self railForChannel:i];
        CGFloat x=NSMinX(rail),bottom=NSMaxY(rail),w=NSWidth(rail);
        CGFloat fill=FMRange(FMBar(r,now))*NSHeight(rail),step=NSHeight(rail)/24;
        for (NSInteger j=0;j<24 && j*step<fill;j++) {
            CGFloat start=j*step+.65;
            CGFloat amount=fmax(0,fmin(step-1.3,fill-start));
            [FMActiveColor(FMScaleFloor+(j+1)*(-FMScaleFloor)/24) setFill];
            NSRectFill(NSMakeRect(x,bottom-start-amount,w,amount));
        }
        double hold=FMHeld(r,now);
        if (FMFresh(r,now) && hold>FMScaleFloor) {
            CGFloat y=fmin(bottom-1.5,fmax(NSMinY(rail),bottom-NSHeight(rail)*FMRange(hold)));
            [FMRGB(0xC5E4D9) setFill]; NSRectFill(NSMakeRect(x-1,y,w+2,1.5));
        }
        if (r.clipped) FMRounded(NSMakeRect(x-1,NSMinY(rail)-7,w+2,3),1.5,FMRGB(0xFF7268),nil);
        NSColor *color = r.clipped ? FMRGB(0xFF9987) : (FMFresh(r,now) && r.sample>FMScaleFloor
                                                         ? FMRGB(0xD6E1DF) : FMRGB(0x9AA9A9));
        FMText(FMReadout(r,now),NSMakeRect(NSMinX(column),bottom+10,NSWidth(column),17),
               digits,color,NSTextAlignmentCenter);
    }
}

- (void)drawRoomBackplate {
    CGFloat width=NSWidth(self.bounds),height=NSHeight(self.bounds);
    NSPoint listener=NSMakePoint(width*.5,height*.50);
    CGFloat radius=fmin(width*.175,height*.33);
    [FMRGB(0x293233) setStroke];
    NSBezierPath *circle=[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(listener.x-radius,listener.y-radius,radius*2,radius*2)];
    CGFloat dash[]={2.0,4.0};
    [circle setLineDash:dash count:2 phase:0]; circle.lineWidth=1; [circle stroke];
    for (NSInteger i=0;i<FMChannelCount;i++) {
        if (i==3) continue;
        NSRect card=[self roomCard:i];
        FMStrokeLine(listener,NSMakePoint(NSMidX(card),NSMidY(card)),FMRGB(0x344141),1);
    }
    FMRounded(NSMakeRect(listener.x-14,listener.y-14,28,28),14,FMRGB(0x172222),FMRGB(0x4E6562));
    NSBezierPath *marker=[NSBezierPath bezierPath];
    [marker moveToPoint:NSMakePoint(listener.x-5,listener.y+3)];
    [marker lineToPoint:NSMakePoint(listener.x,listener.y-5)];
    [marker lineToPoint:NSMakePoint(listener.x+5,listener.y+3)];
    [FMRGB(0xA9BFBA) setStroke]; marker.lineWidth=1.5; [marker stroke];
    NSFont *label=[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    NSFont *digits=[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    FMText(@"dBFS",NSMakeRect(14,height-22,40,14),digits,FMRGB(0x95A5A4),NSTextAlignmentLeft);
    for (NSInteger i=0;i<FMChannelCount;i++) {
        NSRect card=[self roomCard:i];
        FMRounded(card,6,FMRGB(0x192121),FMRGB(0x415353));
        FMText(FMChannelNames[i],NSMakeRect(NSMinX(card)+7,NSMinY(card)+6,NSWidth(card)-14,17),
               label,FMRGB(0xD8E3DF),NSTextAlignmentLeft);
        FMRounded(NSMakeRect(NSMinX(card)+7,NSMaxY(card)-11,NSWidth(card)-14,4),2,FMRGB(0x0C1011),nil);
    }
}

- (void)drawRoomAt:(double)now {
    NSFont *digits=[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    NSPoint seat=NSMakePoint(NSMidX(self.bounds),NSMidY(self.bounds));
    for (NSInteger i=0;i<FMChannelCount;i++) {
        FMChannelReading r=_readings[i];
        NSRect card=[self roomCard:i];
        double db=FMBar(r,now),level=FMRange(db);
        NSColor *accent=FMActiveColor(db);
        // Along each directional ray the lit length follows that input's envelope.
        // The LFE card stays independent of speaker placement.
        if (i!=3 && level>0) {
            CGFloat dx=NSMidX(card)-seat.x,dy=NSMidY(card)-seat.y,distance=hypot(dx,dy);
            CGFloat ux=dx/distance,uy=dy/distance;
            CGFloat edge=fmin(NSWidth(card)*.5/fmax(.0001,fabs(ux)),
                              NSHeight(card)*.5/fmax(.0001,fabs(uy)));
            CGFloat outer=distance-edge-2,inner=outer-level*(outer-17);
            FMStrokeLine(NSMakePoint(seat.x+ux*outer,seat.y+uy*outer),
                         NSMakePoint(seat.x+ux*inner,seat.y+uy*inner),
                         [accent colorWithAlphaComponent:.45],1.4);
        }
        NSColor *valueColor = FMFresh(r,now) && r.sample>FMScaleFloor ? FMRGB(0xC3D6D1) : FMRGB(0x82938F);
        FMText(FMReadout(r,now),NSMakeRect(NSMinX(card)+7,NSMinY(card)+6,NSWidth(card)-14,17),
               digits,valueColor,NSTextAlignmentRight);
        CGFloat x=NSMinX(card)+7,y=NSMaxY(card)-11,bar=NSWidth(card)-14;
        if (level>0) FMRounded(NSMakeRect(x,y,bar*level,4),fmin(2,bar*level/2),accent,nil);
        double hold=FMHeld(r,now);
        if (FMFresh(r,now) && hold>FMScaleFloor) {
            [FMRGB(0xCAE2D9) setFill];
            NSRectFill(NSMakeRect(fmin(x+bar-1.5,x+bar*FMRange(hold)),y-1,1.5,6));
        }
        if (r.clipped) {
            FMRounded(card,6,nil,FMRGB(0xEA887C));
            FMRounded(NSMakeRect(NSMaxX(card)-6,NSMinY(card)+3,3,3),1.5,FMRGB(0xFF7268),nil);
        }
    }
}

@end
