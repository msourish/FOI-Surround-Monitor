#import "FMChannelTrimView.h"
#import <math.h>

static NSString *const FMTrimNames[] = {@"L", @"R", @"C", @"LFE", @"Ls", @"Rs"};
static NSString *const FMTrimLabels[] = {@"Front left", @"Front right", @"Center", @"Low-frequency effects",
                                         @"Left surround", @"Right surround"};
static const double FMHardMute = -61.0;
static const double FMMinTrim = -60.0;
static const double FMMaxTrim = 6.0;

static BOOL FMTrimNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
        && isfinite([value doubleValue]);
}

static double FMTrimTenth(double value) {
    double rounded=fmin(FMMaxTrim, fmax(FMMinTrim, round(value*10)/10));
    return rounded==0 ? 0 : rounded;
}

// The broad working range around unity receives most of the dial's travel.
// A distinct detent at the left stop selects digital mute.
static const double FMTrimBreaks[] = {-61,-60,-24,-12,0,6};
static const double FMTrimPositions[] = {0,.055,.27,.44,.76,1};

static double FMTrimMap(double input, const double *from, const double *to) {
    for (int i=1;i<6;i++) {
        if (input<=from[i]) {
            double t = fmax(0,(input-from[i-1])/(from[i]-from[i-1]));
            return to[i-1]+t*(to[i]-to[i-1]);
        }
    }
    return to[5];
}

static double FMTrimPosition(double db) {
    return FMTrimMap(db,FMTrimBreaks,FMTrimPositions);
}

static double FMTrimAtPosition(double t) {
    if (t < FMTrimPositions[1]/2) return FMHardMute;
    return FMTrimTenth(FMTrimMap(t,FMTrimPositions,FMTrimBreaks));
}

static NSColor *FMTrimColor(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb>>16)&255)/255. green:((rgb>>8)&255)/255.
                                blue:(rgb&255)/255. alpha:1];
}

static void FMTrimText(NSString *text, NSRect rect, NSFont *font, NSColor *ink) {
    static NSParagraphStyle *centered;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];
        style.alignment=NSTextAlignmentCenter;
        style.lineBreakMode=NSLineBreakByClipping;
        centered=[style copy];
    });
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:ink,
                                          NSParagraphStyleAttributeName:centered}];
}

static NSPoint FMTrimPolar(NSPoint center, CGFloat r, CGFloat angle) {
    CGFloat radians=angle*M_PI/180;
    return NSMakePoint(center.x+r*cos(radians),center.y+r*sin(radians));
}

static void FMTrimArc(NSPoint center, CGFloat radius, CGFloat from, CGFloat to, CGFloat width, NSColor *color) {
    if (fabs(from-to)<.01) return;
    NSBezierPath *arc=[NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:from endAngle:to clockwise:from>to];
    arc.lineWidth=width;
    arc.lineCapStyle=NSLineCapStyleRound;
    [color setStroke];
    [arc stroke];
}

static void FMTrimLine(NSPoint start, NSPoint end, CGFloat width, NSColor *color) {
    NSBezierPath *path=[NSBezierPath bezierPath];
    [path moveToPoint:start];
    [path lineToPoint:end];
    path.lineWidth=width;
    path.lineCapStyle=NSLineCapStyleRound;
    [color setStroke];
    [path stroke];
}

@class FMTrimKnob;
@interface FMChannelTrimView ()
- (void)knobChanged:(FMTrimKnob *)knob;
@end

@interface FMTrimKnob : NSView
@property(nonatomic,weak) FMChannelTrimView *owner;
@property(nonatomic) NSUInteger channel;
@property(nonatomic) double db;
@property(nonatomic) double recallDB;
@property(nonatomic) double dragPosition;
@property(nonatomic) CGFloat lastDragY;
@property(nonatomic) double scrollRemainder;
@property(nonatomic) BOOL dragging;
@end

@implementation FMTrimKnob

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstResponder { return self.owner.enabled; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay=YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay=YES; self.dragging=NO; return [super resignFirstResponder]; }

- (void)setDb:(double)value {
    if (_db==value) return;
    _db=value;
    if (value!=FMHardMute) _recallDB=value;
    self.needsDisplay=YES;
    NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);
}

- (void)submit:(double)value {
    if (!self.owner.enabled) return;
    double next=value==FMHardMute ? FMHardMute : FMTrimTenth(value);
    if (next==self.db) return;
    self.db=next;
    [self.owner knobChanged:self];
}

- (void)adjustBy:(double)amount {
    if (!amount) return;
    if (self.db==FMHardMute) {
        if (amount>0) [self submit:FMMinTrim];
    } else {
        double next=self.db+amount;
        [self submit:(self.db==FMMinTrim && next<FMMinTrim) ? FMHardMute : FMTrimTenth(next)];
    }
}

- (void)toggleMute { [self submit:self.db==FMHardMute ? self.recallDB : FMHardMute]; }

- (void)resetFromMenu:(id)sender { (void)sender; [self submit:0]; }
- (void)muteFromMenu:(id)sender { (void)sender; [self toggleMute]; }

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    if (!self.owner.enabled) return nil;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:self.accessibilityLabel];
    NSMenuItem *mute=[menu addItemWithTitle:self.db==FMHardMute?@"Unmute":@"Mute"
                                    action:@selector(muteFromMenu:) keyEquivalent:@""];
    mute.target=self;
    NSMenuItem *reset=[menu addItemWithTitle:@"Reset to 0 dB" action:@selector(resetFromMenu:) keyEquivalent:@""];
    reset.target=self;
    return menu;
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.owner.enabled) return;
    [self.window makeFirstResponder:self];
    if (event.clickCount==2) { self.dragging=NO; [self submit:0]; return; }
    self.dragging=YES;
    self.lastDragY=event.locationInWindow.y;
    self.dragPosition=FMTrimPosition(self.db);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.owner.enabled || !self.dragging) return;
    CGFloat y=event.locationInWindow.y;
    double travel=(event.modifierFlags & NSEventModifierFlagShift) ? 800. : 180.;
    self.dragPosition=fmax(0,fmin(1,self.dragPosition+(y-self.lastDragY)/travel));
    self.lastDragY=y;
    [self submit:FMTrimAtPosition(self.dragPosition)];
}

- (void)mouseUp:(NSEvent *)event { (void)event; self.dragging=NO; }

- (void)scrollWheel:(NSEvent *)event {
    if (!self.owner.enabled || fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)) {
        [super scrollWheel:event];
        return;
    }
    if (event.momentumPhase!=NSEventPhaseNone) return;
    double delta=event.scrollingDeltaY;
    if (!delta) return;
    BOOL fine=(event.modifierFlags & NSEventModifierFlagShift)!=0;
    if (event.hasPreciseScrollingDeltas) {
        if (event.phase==NSEventPhaseBegan) self.scrollRemainder=0;
        self.scrollRemainder+=delta*(fine?.018:.075);
        double amount=trunc(self.scrollRemainder*10)/10;
        self.scrollRemainder-=amount;
        [self adjustBy:amount];
    } else {
        [self adjustBy:copysign(fine?.1:.5,delta)];
    }
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars=event.charactersIgnoringModifiers;
    if (!self.owner.enabled || chars.length!=1 ||
        (event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl))) {
        [super keyDown:event]; return;
    }
    double step=(event.modifierFlags & NSEventModifierFlagShift) ? .1 : .5;
    switch ([chars characterAtIndex:0]) {
        case NSUpArrowFunctionKey: case NSRightArrowFunctionKey: [self adjustBy:step]; break;
        case NSDownArrowFunctionKey: case NSLeftArrowFunctionKey: [self adjustBy:-step]; break;
        case NSHomeFunctionKey: case '0': [self submit:0]; break;
        case 'm': case 'M': [self toggleMute]; break;
        case '\t': [self.window selectNextKeyView:self]; break;
        case NSBackTabCharacter: [self.window selectPreviousKeyView:self]; break;
        default: [super keyDown:event]; break;
    }
}

- (BOOL)isAccessibilityEnabled { return self.owner.enabled; }
- (id)accessibilityValue { return @(self.db); }
- (id)accessibilityMinValue { return @(FMHardMute); }
- (id)accessibilityMaxValue { return @(FMMaxTrim); }
- (NSString *)accessibilityValueDescription {
    if (self.db==FMHardMute) return @"Mute";
    if (self.db==0) return @"0 dB, unity";
    return [NSString stringWithFormat:@"%+.1f dB",self.db];
}
- (void)setAccessibilityValue:(id)value {
    if (!FMTrimNumber(value)) return;
    double db=[value doubleValue];
    [self submit:db<=FMHardMute ? FMHardMute : db];
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector==@selector(setAccessibilityValue:)) return self.owner.enabled;
    return [super isAccessibilitySelectorAllowed:selector];
}
- (BOOL)accessibilityPerformIncrement { if (!self.owner.enabled) return NO; [self adjustBy:.5]; return YES; }
- (BOOL)accessibilityPerformDecrement { if (!self.owner.enabled) return NO; [self adjustBy:-.5]; return YES; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b=self.bounds;
    CGFloat radius=fmin(20,fmax(12,(NSHeight(b)-29)*.43));
    NSPoint c=NSMakePoint(NSMidX(b),NSMidY(b));
    BOOL enabled=self.owner.enabled, mute=self.db==FMHardMute;
    NSColor *text=FMTrimColor(enabled?0xD6E1DF:0x96A4A3);
    NSColor *accent=FMTrimColor(!enabled?0x647977:(mute?0xD2AD7C:0x7AD9C4));
    CGFloat angle=225-270*FMTrimPosition(self.db);
    CGFloat unity=225-270*FMTrimPosition(0);
    FMTrimText(FMTrimNames[self.channel],NSMakeRect(0,NSHeight(b)-16,NSWidth(b),15),
               [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],text);
    FMTrimArc(c,radius,225,-45,2.7,FMTrimColor(0x384443));
    if (!mute) FMTrimArc(c,radius,225,angle,2.3,accent);
    FMTrimLine(FMTrimPolar(c,radius+2.1,unity),FMTrimPolar(c,radius+4,unity),1.2,FMTrimColor(0xA2B8B3));
    CGFloat face=radius-3.4;
    NSBezierPath *rim=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-face,c.y-face,2*face,2*face)];
    static NSGradient *metal;
    static dispatch_once_t once;
    dispatch_once(&once,^{ metal=[[NSGradient alloc] initWithStartingColor:FMTrimColor(0x414D4E)
                                                               endingColor:FMTrimColor(0x1B2223)]; });
    [metal drawInBezierPath:rim angle:105];
    [FMTrimColor(0x63716F) setStroke]; rim.lineWidth=.8; [rim stroke];
    CGFloat start=face*.38, end=face*.83;
    FMTrimLine(FMTrimPolar(c,start,angle),FMTrimPolar(c,end,angle),2,accent);
    if (enabled && self.window && self.window.firstResponder==self && self.window.keyWindow) {
        NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-radius-4,c.y-radius-4,
                                                                            2*radius+8,2*radius+8)];
        [NSColor.keyboardFocusIndicatorColor setStroke]; ring.lineWidth=1.4; [ring stroke];
    }
    NSString *readout=mute?@"MUTE":[NSString stringWithFormat:self.db>0?@"+%.1f":@"%.1f",self.db];
    readout=[readout stringByReplacingOccurrencesOfString:@"-" withString:@"−"];
    FMTrimText(readout,NSMakeRect(0,1,NSWidth(b),15),
               [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],mute?accent:text);
}
@end

@implementation FMChannelTrimView {
    NSArray<FMTrimKnob *> *_knobs;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if (self) [self makeKnobs];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self=[super initWithCoder:coder];
    if (self) [self makeKnobs];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)makeKnobs {
    _enabled=YES;
    self.accessibilityElement=YES;
    self.accessibilityRole=NSAccessibilityGroupRole;
    self.accessibilityLabel=@"Channel trims";
    NSMutableArray *knobs=[NSMutableArray arrayWithCapacity:6];
    for (NSUInteger i=0;i<6;i++) {
        FMTrimKnob *knob=[[FMTrimKnob alloc] initWithFrame:NSZeroRect];
        knob.owner=self;
        knob.channel=i;
        knob.accessibilityElement=YES;
        knob.accessibilityRole=NSAccessibilitySliderRole;
        knob.accessibilityLabel=[FMTrimLabels[i] stringByAppendingString:@" trim"];
        knob.accessibilityIdentifier=[@"trim." stringByAppendingString:FMTrimNames[i]];
        knob.toolTip=@"Drag vertically or scroll to adjust. Hold Shift for fine changes. Double-click to reset to 0 dB. M toggles mute.";
        knob.accessibilityHelp=@"Adjust in decibels. Use the arrow keys, Shift for fine changes, 0 for unity, or M for mute.";
        __weak FMTrimKnob *weakKnob=knob;
        knob.accessibilityCustomActions=@[
            [[NSAccessibilityCustomAction alloc] initWithName:@"Reset to unity" handler:^BOOL{
                FMTrimKnob *k=weakKnob; if (!k.owner.enabled) return NO; [k submit:0]; return YES;
            }],
            [[NSAccessibilityCustomAction alloc] initWithName:@"Toggle mute" handler:^BOOL{
                FMTrimKnob *k=weakKnob; if (!k.owner.enabled) return NO; [k toggleMute]; return YES;
            }]
        ];
        [self addSubview:knob];
        [knobs addObject:knob];
    }
    _knobs=[knobs copy];
    [self positionKnobs];
}

- (void)positionKnobs {
    CGFloat left=44, right=13, w=fmax(1,(NSWidth(self.bounds)-left-right)/6);
    for (NSUInteger i=0;i<_knobs.count;i++) {
        _knobs[i].frame=NSMakeRect(left+i*w,19,w,fmax(1,NSHeight(self.bounds)-21));
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self positionKnobs];
}

- (void)layout {
    [super layout];
    [self positionKnobs];
}

- (NSArray *)trimsDB {
    NSMutableArray *snapshot=[NSMutableArray arrayWithCapacity:6];
    for (FMTrimKnob *k in _knobs) [snapshot addObject:k.db==FMHardMute?NSNull.null:@(k.db)];
    return [snapshot copy];
}

- (void)setTrimsDB:(NSArray *)values {
    if (![values isKindOfClass:NSArray.class] || values.count!=6) return;
    for (id v in values) {
        if (v!=NSNull.null && (!FMTrimNumber(v) || [v doubleValue]<FMMinTrim || [v doubleValue]>FMMaxTrim)) return;
    }
    for (NSUInteger i=0;i<_knobs.count;i++) _knobs[i].db=values[i]==NSNull.null?FMHardMute:FMTrimTenth([values[i] doubleValue]);
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled==enabled) return;
    _enabled=enabled;
    for (FMTrimKnob *knob in _knobs) {
        knob.needsDisplay=YES;
        knob.dragging=NO;
        knob.scrollRemainder=0;
    }
}

- (void)knobChanged:(FMTrimKnob *)knob {
    (void)knob;
    if (self.changeHandler) self.changeHandler(self.trimsDB);
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *panel=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:10 yRadius:10];
    [FMTrimColor(0x151A1B) setFill]; [panel fill];
    [FMTrimColor(0x303B3B) setStroke]; panel.lineWidth=1; [panel stroke];
    FMTrimText(@"dB",NSMakeRect(8,NSHeight(self.bounds)-18,28,15),
               [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],FMTrimColor(0x9FAEAB));
}
@end
