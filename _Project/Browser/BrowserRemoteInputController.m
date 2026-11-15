#import "BrowserRemoteInputController.h"

#import <GameController/GameController.h>

static CGFloat const kBrowserCursorMinimumPointsPerSecond = 40.0;
static CGFloat const kBrowserCursorMaximumPointsPerSecond = 960.0;
static CFTimeInterval const kBrowserCursorAccelerationWindow = 1.4;

static CGFloat BrowserCursorPointsPerSecondForHoldDuration(CFTimeInterval holdDuration) {
    CGFloat elapsed = MIN(MAX(holdDuration, 0.0), kBrowserCursorAccelerationWindow);
    CGFloat curve = log1p(elapsed * 6.0) / log1p(kBrowserCursorAccelerationWindow * 6.0);
    return kBrowserCursorMinimumPointsPerSecond + (kBrowserCursorMaximumPointsPerSecond - kBrowserCursorMinimumPointsPerSecond) * curve;
}
static CFTimeInterval const kBrowserFocusRepeatInterval = 0.18;
static NSTimeInterval const kBrowserPageVideoSeekStep = 10.0;
static CFTimeInterval const kBrowserPageVideoSeekRepeatDelay = 0.5;
static CFTimeInterval const kBrowserPageVideoSeekRepeatInterval = 0.3;
static CFTimeInterval const kBrowserEdgeScrollFlushInterval = 1.0 / 30.0;
static CGFloat const kBrowserEdgeScrollMultiplier = 1.5;
static CGFloat const kBrowserTopBarActivationInset = 8.0;
// Game controllers are read directly (GameController), not through the arrow presses tvOS derives
// from them: a stick that does not return to centre keeps such a press down for ever.
// An arrow press counts as controller-made when the D-pad is held or the left stick is off centre.
static float const kBrowserGamepadPressAttributionThreshold = 0.05f;
// Left stick moves the cursor. Inside the dead zone nothing moves, which absorbs stick drift.
static float const kBrowserCursorStickDeadZone = 0.25f;
// Cursor speed for stick and D-pad: slow by default, a held trigger scales it up to the boost.
static CGFloat const kBrowserGamepadCursorPointsPerSecond = 320.0;
static CGFloat const kBrowserGamepadCursorTriggerBoost = 4.5;
// A stick pushed this far counts as a "press" for seeking in a full screen video and for the top bar.
static float const kBrowserStickDigitalThreshold = 0.7f;
// Holding the − / Create / View button this long switches game mode; a shorter press is the menu key.
static CFTimeInterval const kBrowserGameModeHoldDuration = 0.7;
// Unchanged controller state is still re-sent this often, so a freshly loaded page or frame gets it.
static CFTimeInterval const kBrowserGamepadKeepAliveInterval = 1.0;

extern BOOL BrowserGameModeSwallowsRemotePresses;

typedef NS_ENUM(NSInteger, BrowserGamepadKind) {
    BrowserGamepadKindGeneric,
    BrowserGamepadKindNintendo,
    BrowserGamepadKindPlayStation,
    BrowserGamepadKindXbox,
};
// Right stick scrolls the page. The dead zone is wide on purpose so a drifting stick stays still.
static float const kBrowserScrollStickDeadZone = 0.3f;
static CGFloat const kBrowserScrollStickMaximumPointsPerSecond = 2600.0;
// Up/Down pressed twice quickly scrolls one step; keeping the second press down keeps scrolling.
static CFTimeInterval const kBrowserDoublePressInterval = 0.4;
static CFTimeInterval const kBrowserTapMaximumDuration = 0.3;
static CGFloat const kBrowserDoublePressScrollFraction = 0.6;
static CFTimeInterval const kBrowserScrollHoldDelay = 0.4;
static CGFloat const kBrowserScrollHoldPointsPerSecond = 1500.0;

typedef NS_OPTIONS(NSUInteger, BrowserDirectionMask) {
    BrowserDirectionMaskUp = 1 << 0,
    BrowserDirectionMaskDown = 1 << 1,
    BrowserDirectionMaskLeft = 1 << 2,
    BrowserDirectionMaskRight = 1 << 3,
};

static UIImage *BrowserDefaultCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Cursor"];
    });
    return image;
}

static UIImage *BrowserPointerCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Pointer"];
    });
    return image;
}

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic, readwrite) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
@property (nonatomic) CGPoint lastTouchLocation;
@property (nonatomic) CADisplayLink *manualScrollDisplayLink;
@property (nonatomic) CGPoint manualScrollVelocity;
@property (nonatomic) CFTimeInterval manualScrollLastTimestamp;
@property (nonatomic) CFTimeInterval manualScrollLastMovementTimestamp;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) CFTimeInterval lastFunctionKeyTimestamp;
@property (nonatomic) CGPoint pendingEdgeScroll;
@property (nonatomic) NSHashTable<UIPress *> *ignoredStickPresses;
@property (nonatomic) CADisplayLink *scrollStickDisplayLink;
@property (nonatomic) BrowserDirectionMask gamepadDpadDirections;
@property (nonatomic) CADisplayLink *gameModeDisplayLink;
@property (nonatomic, copy) NSString *lastGamepadScript;
@property (nonatomic, copy) NSString *lastGamepadButtons;
@property (nonatomic) NSMutableArray<NSNumber *> *gamepadDpadDownCounts;
@property (nonatomic) CFTimeInterval lastGamepadScriptTimestamp;
@property (nonatomic) NSUInteger optionsPressSerial;
@property (nonatomic) BOOL optionsLongPressFired;
@property (nonatomic) BrowserDirectionMask stickDigitalDirections;
@property (nonatomic) BrowserDirectionMask scrollHoldDirection;
@property (nonatomic) CFTimeInterval scrollHoldStartTimestamp;
@property (nonatomic) BrowserDirectionMask lastVerticalTapDirection;
@property (nonatomic) CFTimeInterval lastVerticalTapEndTimestamp;
@property (nonatomic) CFTimeInterval verticalPressBeganTimestamp;
@property (nonatomic) CFTimeInterval lastEdgeScrollFlushTimestamp;
@property (nonatomic) CADisplayLink *directionalDisplayLink;
@property (nonatomic) BrowserDirectionMask heldDirections;
@property (nonatomic) CFTimeInterval lastFocusStepTimestamp;
@property (nonatomic) CFTimeInterval cursorHoldStartTimestamp;
@property (nonatomic) CFTimeInterval lastHoverUpdateTimestamp;

@end

@implementation BrowserRemoteInputController

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView {
    self = [super init];
    if (self) {
        _host = host;
        _rootView = rootView;
        _lastTouchLocation = CGPointMake(-1, -1);
        _cursorModeEnabled = YES;
        _ignoredStickPresses = [NSHashTable weakObjectsHashTable];
        _gamepadDpadDownCounts = [@[@0, @0, @0, @0] mutableCopy];

        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        _cursorView.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        _cursorView.image = BrowserDefaultCursor();

        _manualScrollPanRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleManualScrollPan:)];
        _manualScrollPanRecognizer.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
        _manualScrollPanRecognizer.cancelsTouchesInView = NO;
        _manualScrollPanRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_manualScrollPanRecognizer];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidConnect:)
                                                     name:GCControllerDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidDisconnect:)
                                                     name:GCControllerDidDisconnectNotification
                                                   object:nil];
        [self attachGamepadHandlers];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.directionalDisplayLink invalidate];
    [self.manualScrollDisplayLink invalidate];
    [self.scrollStickDisplayLink invalidate];
    [self.gameModeDisplayLink invalidate];
    BrowserGameModeSwallowsRemotePresses = NO;
}

- (BOOL)directionalInputAllowed {
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    return YES;
}

- (CGRect)cursorTravelBounds {
    UIView *limitView = self.rootView;
    CGRect bounds = limitView != nil ? limitView.bounds : CGRectZero;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }
    return bounds;
}

- (void)refreshCursorHoverImage {
    CFTimeInterval now = CACurrentMediaTime();
    if ((now - self.lastHoverUpdateTimestamp) < 0.08) {
        return;
    }
    self.lastHoverUpdateTimestamp = now;
    self.cursorView.image = BrowserDefaultCursor();
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if ([self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
            self.cursorView.image = BrowserPointerCursor();
        }
        return;
    }
    if (!self.cursorModeEnabled) {
        return;
    }
    NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
    if ([containsLink isEqualToString:@"true"]) {
        self.cursorView.image = BrowserPointerCursor();
    }
}

- (void)moveCursorByDelta:(CGPoint)delta {
    if (delta.x == 0.0 && delta.y == 0.0) {
        return;
    }

    CGRect travelBounds = [self cursorTravelBounds];
    CGRect rect = self.cursorView.frame;
    CGFloat maxX = MAX(0.0, CGRectGetWidth(travelBounds) - 1.0);
    CGFloat maxY = MAX(0.0, CGRectGetHeight(travelBounds) - 1.0);
    CGPoint wanted = CGPointMake(rect.origin.x + delta.x, rect.origin.y + delta.y);
    rect.origin.x = MIN(MAX(wanted.x, 0.0), maxX);
    rect.origin.y = MIN(MAX(wanted.y, 0.0), maxY);
    self.cursorView.frame = rect;
    // Whatever the cursor could not travel because it hit a screen edge scrolls the page instead.
    [self queueEdgeScrollByDelta:CGPointMake(wanted.x - rect.origin.x, wanted.y - rect.origin.y)];
    [self refreshCursorHoverImage];
}

- (void)queueEdgeScrollByDelta:(CGPoint)delta {
    if (delta.x == 0.0 && delta.y == 0.0) {
        return;
    }
    if (!self.cursorModeEnabled || [self.host browserRemoteInputControllerTabOverviewVisible]) {
        return;
    }
    [self queuePageScrollByDelta:CGPointMake(delta.x * kBrowserEdgeScrollMultiplier, delta.y * kBrowserEdgeScrollMultiplier)];
}

// Batches scroll requests so the page gets at most one script call per flush interval.
- (void)queuePageScrollByDelta:(CGPoint)delta {
    self.pendingEdgeScroll = CGPointMake(self.pendingEdgeScroll.x + delta.x, self.pendingEdgeScroll.y + delta.y);
    CFTimeInterval now = CACurrentMediaTime();
    if ((now - self.lastEdgeScrollFlushTimestamp) < kBrowserEdgeScrollFlushInterval) {
        return;
    }
    self.lastEdgeScrollFlushTimestamp = now;
    CGPoint scroll = self.pendingEdgeScroll;
    self.pendingEdgeScroll = CGPointZero;
    [self.host browserRemoteInputControllerScrollPageByDelta:scroll];
}

- (BrowserDirectionMask)directionMaskForPressType:(UIPressType)type {
    switch (type) {
        case UIPressTypeUpArrow: return BrowserDirectionMaskUp;
        case UIPressTypeDownArrow: return BrowserDirectionMaskDown;
        case UIPressTypeLeftArrow: return BrowserDirectionMaskLeft;
        case UIPressTypeRightArrow: return BrowserDirectionMaskRight;
        default: return 0;
    }
}

- (NSString *)focusDirectionNameForMask:(BrowserDirectionMask)mask {
    if ((mask & BrowserDirectionMaskUp) != 0) {
        return @"up";
    }
    if ((mask & BrowserDirectionMaskDown) != 0) {
        return @"down";
    }
    if ((mask & BrowserDirectionMaskLeft) != 0) {
        return @"left";
    }
    if ((mask & BrowserDirectionMaskRight) != 0) {
        return @"right";
    }
    return nil;
}

- (CGPoint)cursorDeltaForDirectionMask:(BrowserDirectionMask)mask speed:(CGFloat)speed {
    CGFloat x = 0.0;
    CGFloat y = 0.0;
    if ((mask & BrowserDirectionMaskLeft) != 0) {
        x -= speed;
    }
    if ((mask & BrowserDirectionMaskRight) != 0) {
        x += speed;
    }
    if ((mask & BrowserDirectionMaskUp) != 0) {
        y -= speed;
    }
    if ((mask & BrowserDirectionMaskDown) != 0) {
        y += speed;
    }
    return CGPointMake(x, y);
}

- (void)stepFocusInDirectionMask:(BrowserDirectionMask)mask {
    NSString *direction = [self focusDirectionNameForMask:mask];
    if (direction.length == 0) {
        return;
    }
    [self.host browserRemoteInputControllerMoveFocusInDirection:direction];
}

- (BOOL)cursorIsAtTopEdge {
    return CGRectGetMinY(self.cursorView.frame) <= kBrowserTopBarActivationInset;
}

- (void)ensureDirectionalDisplayLink {
    if (self.directionalDisplayLink != nil) {
        return;
    }
    self.directionalDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDirectionalDisplayLink:)];
    [self.directionalDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDirectionalDisplayLinkIfIdle {
    if (self.heldDirections != 0 || self.scrollHoldDirection != 0) {
        return;
    }
    [self.directionalDisplayLink invalidate];
    self.directionalDisplayLink = nil;
}

// tvOS already turns a game controller into presses: D-pad -> arrows, A -> Select (confirm),
// B -> Menu (cancel), X -> Play/Pause (function key). Those arrive through pressesBegan/Ended like
// the Siri Remote, so only the buttons the system leaves unmapped need handlers here.
- (void)handleFunctionKey {
    CFTimeInterval now = CACurrentMediaTime();
    if ((now - self.lastFunctionKeyTimestamp) < 0.3) {
        return;
    }
    self.lastFunctionKeyTimestamp = now;
    if (self.gameModeEnabled) {
        return;
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        [self.host browserRemoteInputControllerDeactivateTopBarFocus];
    }
    [self.host browserRemoteInputControllerHandlePlayPausePress];
}

- (void)attachGamepadHandlers {
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil) {
            continue;
        }
        __weak typeof(self) weakSelf = self;
        gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *directionPad, float xValue, float yValue) {
            (void)directionPad;
            if (hypotf(xValue, yValue) > kBrowserCursorStickDeadZone) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf ensureScrollStickDisplayLink];
                });
            }
        };
        gamepad.dpad.valueChangedHandler = ^(GCControllerDirectionPad *directionPad, float xValue, float yValue) {
            (void)xValue;
            (void)yValue;
            BrowserDirectionMask mask = 0;
            if (directionPad.up.isPressed) { mask |= BrowserDirectionMaskUp; }
            if (directionPad.down.isPressed) { mask |= BrowserDirectionMaskDown; }
            if (directionPad.left.isPressed) { mask |= BrowserDirectionMaskLeft; }
            if (directionPad.right.isPressed) { mask |= BrowserDirectionMaskRight; }
            [weakSelf gamepadDpadDidReportDirections:mask];
            // Handlers already run on the main queue; calling straight through keeps down/up in order.
            [weakSelf gamepadDpadDidChangeToDirections:mask];
        };
        gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *directionPad, float xValue, float yValue) {
            (void)directionPad;
            if (fabsf(xValue) > kBrowserScrollStickDeadZone || fabsf(yValue) > kBrowserScrollStickDeadZone) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf ensureScrollStickDisplayLink];
                });
            }
        };
        GCControllerButtonValueChangedHandler functionHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
            (void)button;
            (void)value;
            if (!pressed) {
                return;
            }
            [weakSelf handleFunctionKey];
        };
        // Game mode: every button transition goes to the page the moment it happens. Polling alone
        // (once per frame) could miss a tap that starts and ends between two frames.
        gamepad.valueChangedHandler = ^(GCExtendedGamepad *changedGamepad, GCControllerElement *element) {
            (void)changedGamepad;
            (void)element;
            [weakSelf sendGamepadStateOnlyIfButtonsChanged:YES];
        };
        gamepad.buttonA.pressedChangedHandler = nil;
        gamepad.buttonB.pressedChangedHandler = nil;
        gamepad.buttonY.pressedChangedHandler = functionHandler;
        // − / Create / View: a short press is the menu key (on release), a long press toggles game mode.
        gamepad.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
            (void)button;
            (void)value;
            [weakSelf optionsButtonDidChange:pressed];
        };
    }
}

#pragma mark - Game controller: D-pad, sticks, triggers

/// YES when tvOS derived this arrow press from a game controller. Such presses are dropped because
/// the same input is already handled from the controller state below.
- (BOOL)arrowPressIsFromGamepad {
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil) {
            continue;
        }
        GCControllerDirectionPad *dpad = gamepad.dpad;
        if (dpad.up.isPressed || dpad.down.isPressed || dpad.left.isPressed || dpad.right.isPressed) {
            return YES;
        }
        if (hypotf(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value) > kBrowserGamepadPressAttributionThreshold) {
            return YES;
        }
    }
    return NO;
}

/// 1 with no trigger held, up to kBrowserGamepadCursorTriggerBoost with a trigger fully down.
- (CGFloat)gamepadCursorSpeedMultiplier {
    float trigger = 0.0f;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil) {
            continue;
        }
        trigger = MAX(trigger, MAX(gamepad.leftTrigger.value, gamepad.rightTrigger.value));
        if (gamepad.leftTrigger.isPressed || gamepad.rightTrigger.isPressed) {
            trigger = MAX(trigger, 1.0f);
        }
    }
    return 1.0 + (kBrowserGamepadCursorTriggerBoost - 1.0) * MIN(trigger, 1.0f);
}

/// Counts D-pad presses as GameController reports them, for the gamepad test page.
- (void)gamepadDpadDidReportDirections:(BrowserDirectionMask)directions {
    static BrowserDirectionMask previous = 0;
    NSArray<NSNumber *> *order = @[@(BrowserDirectionMaskUp), @(BrowserDirectionMaskDown), @(BrowserDirectionMaskLeft), @(BrowserDirectionMaskRight)];
    for (NSUInteger index = 0; index < order.count; index++) {
        BrowserDirectionMask direction = order[index].unsignedIntegerValue;
        if ((directions & direction) != 0 && (previous & direction) == 0) {
            self.gamepadDpadDownCounts[index] = @(self.gamepadDpadDownCounts[index].unsignedIntegerValue + 1);
        }
    }
    previous = directions;
}

- (void)gamepadDpadDidChangeToDirections:(BrowserDirectionMask)directions {
    if (self.gameModeEnabled) {
        directions = 0;
    }
    BrowserDirectionMask previous = self.gamepadDpadDirections;
    self.gamepadDpadDirections = directions;
    for (NSNumber *value in @[@(BrowserDirectionMaskUp), @(BrowserDirectionMaskDown), @(BrowserDirectionMaskLeft), @(BrowserDirectionMaskRight)]) {
        BrowserDirectionMask direction = value.unsignedIntegerValue;
        BOOL wasDown = (previous & direction) != 0;
        BOOL isDown = (directions & direction) != 0;
        if (isDown && !wasDown) {
            if ([self directionalInputAllowed]) {
                [self beginDirection:direction];
            }
        } else if (!isDown && wasDown) {
            [self endDirection:direction];
        }
    }
}

- (void)ensureScrollStickDisplayLink {
    if (self.scrollStickDisplayLink != nil) {
        return;
    }
    self.scrollStickDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleScrollStickDisplayLink:)];
    [self.scrollStickDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static CGFloat BrowserScrollStickSpeed(float value) {
    float magnitude = fabsf(value);
    if (magnitude <= kBrowserScrollStickDeadZone) {
        return 0.0;
    }
    CGFloat amount = (magnitude - kBrowserScrollStickDeadZone) / (1.0f - kBrowserScrollStickDeadZone);
    return (value > 0 ? 1.0 : -1.0) * amount * amount * kBrowserScrollStickMaximumPointsPerSecond;
}

/// Runs while either stick is off centre: left stick moves the cursor, right stick scrolls the page.
- (void)handleScrollStickDisplayLink:(CADisplayLink *)displayLink {
    CFTimeInterval deltaTime = displayLink.duration;
    if (deltaTime <= 0.0 || deltaTime > 0.1) {
        deltaTime = 1.0 / 60.0;
    }
    CGPoint scrollSpeed = CGPointZero;
    CGPoint cursorStick = CGPointZero;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (gamepad == nil) {
            continue;
        }
        if (scrollSpeed.x == 0.0 && scrollSpeed.y == 0.0) {
            scrollSpeed = CGPointMake(BrowserScrollStickSpeed(gamepad.rightThumbstick.xAxis.value),
                                      -BrowserScrollStickSpeed(gamepad.rightThumbstick.yAxis.value));
        }
        float x = gamepad.leftThumbstick.xAxis.value;
        float y = gamepad.leftThumbstick.yAxis.value;
        float magnitude = hypotf(x, y);
        if (cursorStick.x == 0.0 && cursorStick.y == 0.0 && magnitude > kBrowserCursorStickDeadZone) {
            // Rescale so movement starts from zero at the edge of the dead zone.
            float amount = MIN((magnitude - kBrowserCursorStickDeadZone) / (1.0f - kBrowserCursorStickDeadZone), 1.0f);
            cursorStick = CGPointMake(x / magnitude * amount, -y / magnitude * amount);
        }
    }
    BOOL scrolling = scrollSpeed.x != 0.0 || scrollSpeed.y != 0.0;
    BOOL moving = cursorStick.x != 0.0 || cursorStick.y != 0.0;
    if ((!scrolling && !moving) || self.gameModeEnabled) {
        self.stickDigitalDirections = 0;
        [self.scrollStickDisplayLink invalidate];
        self.scrollStickDisplayLink = nil;
        return;
    }
    if (![self directionalInputAllowed]) {
        self.stickDigitalDirections = 0;
        return;
    }
    if (scrolling) {
        [self queuePageScrollByDelta:CGPointMake(scrollSpeed.x * deltaTime, scrollSpeed.y * deltaTime)];
    }

    // A firm push also works as a one-shot "press": seek in a full screen video, open the top bar.
    BrowserDirectionMask digital = 0;
    if (cursorStick.x <= -kBrowserStickDigitalThreshold) { digital |= BrowserDirectionMaskLeft; }
    if (cursorStick.x >= kBrowserStickDigitalThreshold) { digital |= BrowserDirectionMaskRight; }
    if (cursorStick.y <= -kBrowserStickDigitalThreshold) { digital |= BrowserDirectionMaskUp; }
    if (cursorStick.y >= kBrowserStickDigitalThreshold) { digital |= BrowserDirectionMaskDown; }
    BrowserDirectionMask newlyPushed = digital & ~self.stickDigitalDirections;
    self.stickDigitalDirections = digital;

    if ([self.host browserRemoteInputControllerPageVideoActive]) {
        [self seekPageVideoForDirectionMask:newlyPushed];
        return;
    }
    if (!moving || !self.cursorModeEnabled) {
        return;
    }
    if ((newlyPushed & BrowserDirectionMaskUp) != 0 && [self shouldActivateTopBarForUpPress]) {
        [self.host browserRemoteInputControllerActivateTopBarFocus];
        return;
    }
    CGFloat speed = kBrowserGamepadCursorPointsPerSecond * [self gamepadCursorSpeedMultiplier] * deltaTime;
    [self moveCursorByDelta:CGPointMake(cursorStick.x * speed, cursorStick.y * speed)];
}

- (BOOL)shouldActivateTopBarForUpPress {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL pageIsScrolledDown = scrollView != nil && scrollView.contentOffset.y > 1.0;
    return self.cursorModeEnabled && [self cursorIsAtTopEdge] && !pageIsScrolledDown &&
        [self.host browserRemoteInputControllerCanActivateTopBarFocus];
}

#pragma mark - Game mode

- (GCController *)primaryGameController {
    for (GCController *controller in GCController.controllers) {
        if (controller.extendedGamepad != nil) {
            return controller;
        }
    }
    return nil;
}

- (BrowserGamepadKind)kindOfController:(GCController *)controller {
    NSString *description = [[NSString stringWithFormat:@"%@ %@", controller.productCategory ?: @"", controller.vendorName ?: @""] lowercaseString];
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if ([gamepad isKindOfClass:NSClassFromString(@"GCDualSenseGamepad")] ||
        [gamepad isKindOfClass:NSClassFromString(@"GCDualShockGamepad")] ||
        [description containsString:@"dualsense"] || [description containsString:@"dualshock"] ||
        [description containsString:@"playstation"]) {
        return BrowserGamepadKindPlayStation;
    }
    if ([gamepad isKindOfClass:NSClassFromString(@"GCXboxGamepad")] || [description containsString:@"xbox"]) {
        return BrowserGamepadKindXbox;
    }
    if ([description containsString:@"switch"] || [description containsString:@"nintendo"] ||
        [description containsString:@"joy-con"] || [description containsString:@"pro controller"]) {
        return BrowserGamepadKindNintendo;
    }
    return BrowserGamepadKindGeneric;
}

- (BOOL)gameModeAvailable {
    return [self primaryGameController] != nil;
}

- (NSString *)gameModeToggleButtonName {
    switch ([self kindOfController:[self primaryGameController]]) {
        case BrowserGamepadKindNintendo: return @"−";
        case BrowserGamepadKindPlayStation: return @"Create";
        case BrowserGamepadKindXbox: return @"View";
        default: return @"Options";
    }
}

- (void)optionsButtonDidChange:(BOOL)pressed {
    if (pressed) {
        self.optionsLongPressFired = NO;
        NSUInteger serial = ++self.optionsPressSerial;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserGameModeHoldDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.optionsPressSerial != serial) {
                return;
            }
            strongSelf.optionsLongPressFired = YES;
            strongSelf.gameModeEnabled = !strongSelf.gameModeEnabled;
        });
        return;
    }
    self.optionsPressSerial += 1;
    if (!self.optionsLongPressFired) {
        [self handleFunctionKey];
    }
}

- (void)setGameModeEnabled:(BOOL)gameModeEnabled {
    if (gameModeEnabled && ![self gameModeAvailable]) {
        gameModeEnabled = NO;
    }
    if (_gameModeEnabled == gameModeEnabled) {
        return;
    }
    NSString *toggleButtonName = self.gameModeToggleButtonName;
    _gameModeEnabled = gameModeEnabled;
    BrowserGameModeSwallowsRemotePresses = gameModeEnabled;

    // Whatever the controller was doing to the browser stops here.
    self.heldDirections = 0;
    self.scrollHoldDirection = 0;
    self.gamepadDpadDirections = 0;
    self.stickDigitalDirections = 0;
    self.lastVerticalTapDirection = 0;
    [self.ignoredStickPresses removeAllObjects];
    [self stopDirectionalDisplayLinkIfIdle];

    [self.gameModeDisplayLink invalidate];
    self.gameModeDisplayLink = nil;
    self.lastGamepadScript = nil;
    self.lastGamepadButtons = nil;
    if (gameModeEnabled) {
        self.gameModeDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleGameModeDisplayLink:)];
        [self.gameModeDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else {
        [self.host browserRemoteInputControllerEvaluateGamepadScript:@"window.__tvb&&window.__tvb.pad&&window.__tvb.pad(null);"];
    }
    [self refreshInteractionState];
    [self.host browserRemoteInputControllerGameModeDidChange:gameModeEnabled toggleButtonName:toggleButtonName];
}

static NSString *BrowserGamepadNumber(float value) {
    if (value == 0.0f) { return @"0"; }
    if (value == 1.0f) { return @"1"; }
    return [NSString stringWithFormat:@"%.3f", value];
}

/// The controller as a W3C "standard" gamepad: 17 buttons by position, 4 axes with down/right positive.
- (NSString *)gamepadScriptForController:(GCController *)controller buttons:(NSString **)buttonsOut {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    BrowserGamepadKind kind = [self kindOfController:controller];

    // GameController names face buttons by label, the web by position. Nintendo prints A on the
    // right and B at the bottom (X top, Y left), the reverse of Xbox, so they are crossed over here.
    BOOL nintendoLayout = kind == BrowserGamepadKindNintendo;
    GCControllerButtonInput *bottom = nintendoLayout ? gamepad.buttonB : gamepad.buttonA;
    GCControllerButtonInput *right = nintendoLayout ? gamepad.buttonA : gamepad.buttonB;
    GCControllerButtonInput *left = nintendoLayout ? gamepad.buttonY : gamepad.buttonX;
    GCControllerButtonInput *top = nintendoLayout ? gamepad.buttonX : gamepad.buttonY;

    NSMutableArray<GCControllerButtonInput *> *buttons = [NSMutableArray arrayWithArray:@[
        bottom, right, left, top,
        gamepad.leftShoulder, gamepad.rightShoulder, gamepad.leftTrigger, gamepad.rightTrigger,
    ]];
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (GCControllerButtonInput *button in buttons) {
        [values addObject:BrowserGamepadNumber(button.isPressed ? MAX(button.value, 1.0f) : button.value)];
    }
    // Trigger depth is analog; everything else is 0 or 1.
    values[6] = BrowserGamepadNumber(gamepad.leftTrigger.isPressed && gamepad.leftTrigger.value == 0.0f ? 1.0f : gamepad.leftTrigger.value);
    values[7] = BrowserGamepadNumber(gamepad.rightTrigger.isPressed && gamepad.rightTrigger.value == 0.0f ? 1.0f : gamepad.rightTrigger.value);
    NSArray<GCControllerButtonInput *> *optional = @[
        (id)gamepad.buttonOptions ?: (id)[NSNull null],          // 8  select / back: −, Create, View
        (id)gamepad.buttonMenu ?: (id)[NSNull null],             // 9  start: +, Options, Menu
        (id)gamepad.leftThumbstickButton ?: (id)[NSNull null],   // 10 L3
        (id)gamepad.rightThumbstickButton ?: (id)[NSNull null],  // 11 R3
        gamepad.dpad.up, gamepad.dpad.down, gamepad.dpad.left, gamepad.dpad.right,  // 12-15
        (id)gamepad.buttonHome ?: (id)[NSNull null],             // 16 Home / PS / Xbox
    ];
    for (id button in optional) {
        BOOL pressed = [button isKindOfClass:[GCControllerButtonInput class]] && [(GCControllerButtonInput *)button isPressed];
        [values addObject:pressed ? @"1" : @"0"];
    }
    if (kind == BrowserGamepadKindPlayStation) {
        // 17: touchpad click (DualSense / DualShock 4).
        id touchpadButton = [gamepad respondsToSelector:NSSelectorFromString(@"touchpadButton")] ? [gamepad valueForKey:@"touchpadButton"] : nil;
        BOOL pressed = [touchpadButton isKindOfClass:[GCControllerButtonInput class]] && [(GCControllerButtonInput *)touchpadButton isPressed];
        [values addObject:pressed ? @"1" : @"0"];
    }

    NSString *identifier = nil;
    switch (kind) {
        case BrowserGamepadKindNintendo:
            identifier = @"Pro Controller (STANDARD GAMEPAD Vendor: 057e Product: 2009)";
            break;
        case BrowserGamepadKindPlayStation:
            identifier = @"DualSense Wireless Controller (STANDARD GAMEPAD Vendor: 054c Product: 0ce6)";
            break;
        case BrowserGamepadKindXbox:
            identifier = @"Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)";
            break;
        default:
            identifier = @"Game Controller (STANDARD GAMEPAD)";
            break;
    }
    NSString *axes = [@[
        BrowserGamepadNumber(gamepad.leftThumbstick.xAxis.value), BrowserGamepadNumber(-gamepad.leftThumbstick.yAxis.value),
        BrowserGamepadNumber(gamepad.rightThumbstick.xAxis.value), BrowserGamepadNumber(-gamepad.rightThumbstick.yAxis.value),
    ] componentsJoinedByString:@","];
    NSString *buttonValues = [values componentsJoinedByString:@","];
    if (buttonsOut != NULL) {
        *buttonsOut = buttonValues;
    }
    return [NSString stringWithFormat:@"window.__tvb&&window.__tvb.pad&&window.__tvb.pad({id:'%@',b:[%@],a:[%@],n:[%@]});",
            identifier, buttonValues, axes, [self.gamepadDpadDownCounts componentsJoinedByString:@","]];
}

- (void)sendGamepadStateOnlyIfButtonsChanged:(BOOL)onlyIfButtonsChanged {
    if (!self.gameModeEnabled) {
        return;
    }
    GCController *controller = [self primaryGameController];
    if (controller == nil) {
        self.gameModeEnabled = NO;
        return;
    }
    NSString *buttons = nil;
    NSString *script = [self gamepadScriptForController:controller buttons:&buttons];
    CFTimeInterval now = CACurrentMediaTime();
    if (onlyIfButtonsChanged) {
        // Stick and trigger movement is frequent; the per-frame pass below carries it.
        if ([buttons isEqualToString:self.lastGamepadButtons]) {
            return;
        }
    } else if ([script isEqualToString:self.lastGamepadScript] &&
               (now - self.lastGamepadScriptTimestamp) < kBrowserGamepadKeepAliveInterval) {
        return;
    }
    self.lastGamepadButtons = buttons;
    self.lastGamepadScript = script;
    self.lastGamepadScriptTimestamp = now;
    [self.host browserRemoteInputControllerEvaluateGamepadScript:script];
}

- (void)handleGameModeDisplayLink:(CADisplayLink *)displayLink {
    (void)displayLink;
    [self sendGamepadStateOnlyIfButtonsChanged:NO];
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    (void)notification;
    if (self.gameModeEnabled && ![self gameModeAvailable]) {
        // Nothing left that could switch game mode off again.
        self.gameModeEnabled = NO;
    }
}

- (void)controllerDidConnect:(NSNotification *)notification {
    (void)notification;
    [self attachGamepadHandlers];
}

- (void)handleDirectionalDisplayLink:(CADisplayLink *)displayLink {
    CFTimeInterval deltaTime = displayLink.duration;
    if (deltaTime <= 0.0 || deltaTime > 0.1) {
        deltaTime = 1.0 / 60.0;
    }

    if (![self directionalInputAllowed]) {
        self.heldDirections = 0;
        self.scrollHoldDirection = 0;
        [self stopDirectionalDisplayLinkIfIdle];
        return;
    }

    if ([self.host browserRemoteInputControllerPageVideoActive]) {
        CFTimeInterval now = CACurrentMediaTime();
        BOOL pastInitialDelay = (now - self.cursorHoldStartTimestamp) >= kBrowserPageVideoSeekRepeatDelay;
        if (pastInitialDelay && (now - self.lastFocusStepTimestamp) >= kBrowserPageVideoSeekRepeatInterval) {
            self.lastFocusStepTimestamp = now;
            [self seekPageVideoForDirectionMask:self.heldDirections];
        }
        [self stopDirectionalDisplayLinkIfIdle];
        return;
    }

    if (self.scrollHoldDirection != 0) {
        if ((CACurrentMediaTime() - self.scrollHoldStartTimestamp) >= kBrowserScrollHoldDelay) {
            CGFloat sign = self.scrollHoldDirection == BrowserDirectionMaskUp ? -1.0 : 1.0;
            [self queuePageScrollByDelta:CGPointMake(0.0, sign * kBrowserScrollHoldPointsPerSecond * deltaTime)];
        }
        return;
    }

    if (self.cursorModeEnabled) {
        CFTimeInterval holdDuration = CACurrentMediaTime() - self.cursorHoldStartTimestamp;
        CGFloat pointsPerSecond = BrowserCursorPointsPerSecondForHoldDuration(holdDuration);
        if (self.gamepadDpadDirections != 0) {
            // Controller D-pad: steady and slow, the trigger is the accelerator.
            pointsPerSecond = kBrowserGamepadCursorPointsPerSecond * [self gamepadCursorSpeedMultiplier];
        }
        CGPoint delta = [self cursorDeltaForDirectionMask:self.heldDirections speed:pointsPerSecond * deltaTime];
        [self moveCursorByDelta:delta];
        [self stopDirectionalDisplayLinkIfIdle];
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (self.heldDirections != 0 && (now - self.lastFocusStepTimestamp) >= kBrowserFocusRepeatInterval) {
        self.lastFocusStepTimestamp = now;
        [self stepFocusInDirectionMask:self.heldDirections];
    }
    [self stopDirectionalDisplayLinkIfIdle];
}

- (void)seekPageVideoForDirectionMask:(BrowserDirectionMask)mask {
    if ((mask & BrowserDirectionMaskLeft) != 0) {
        [self.host browserRemoteInputControllerPageVideoSeekBy:-kBrowserPageVideoSeekStep];
    } else if ((mask & BrowserDirectionMaskRight) != 0) {
        [self.host browserRemoteInputControllerPageVideoSeekBy:kBrowserPageVideoSeekStep];
    }
}

- (BOOL)handleHardwareKeyPress:(UIPress *)press {
    if (self.cursorModeEnabled || ![self directionalInputAllowed]) {
        return NO;
    }
    if (@available(tvOS 13.4, *)) {
        UIKey *key = press.key;
        if (key == nil) {
            return NO;
        }
        if (key.keyCode == UIKeyboardHIDUsageKeyboardDeleteOrBackspace) {
            [self.host browserRemoteInputControllerDeleteBackward];
            return YES;
        }
        NSString *characters = key.characters;
        if (characters.length == 0 || [characters isEqualToString:@"\n"] || [characters isEqualToString:@"\r"]) {
            return NO;
        }
        unichar firstCharacter = [characters characterAtIndex:0];
        if (firstCharacter < 0x20) {
            return NO;
        }
        [self.host browserRemoteInputControllerInsertText:characters];
        return YES;
    }
    return NO;
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.heldDirections = 0;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self stopManualScrollInertia];
    [self refreshInteractionState];
    if (!wasCursorModeEnabled && cursorModeEnabled) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)refreshInteractionState {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
    BOOL shouldAllowWebInteraction = !self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        !topBarFocusActive;
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;
    [self.host browserRemoteInputControllerSetWebInteractionEnabled:shouldAllowWebInteraction];
    self.cursorView.hidden = [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerPageVideoActive] || self.gameModeEnabled;
    if (!self.cursorView.hidden) {
        [self.cursorView.superview bringSubviewToFront:self.cursorView];
    }
}

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return NO;
    }

    CGPoint contentOffset = scrollView.contentOffset;
    CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
    CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
    CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, 0.0), maxOffsetY);
    CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
    [scrollView setContentOffset:nextOffset animated:NO];
    return !CGPointEqualToPoint(contentOffset, nextOffset);
}

- (void)stopManualScrollInertia {
    [self.manualScrollDisplayLink invalidate];
    self.manualScrollDisplayLink = nil;
    self.manualScrollVelocity = CGPointZero;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollLastMovementTimestamp = 0;
}

- (void)startManualScrollInertiaWithVelocity:(CGPoint)velocity {
    [self stopManualScrollInertia];
    if (fabs(velocity.x) < 25.0 && fabs(velocity.y) < 25.0) {
        return;
    }

    self.manualScrollVelocity = velocity;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleManualScrollDisplayLink:)];
    [self.manualScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleManualScrollDisplayLink:(CADisplayLink *)displayLink {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        [self stopManualScrollInertia];
        return;
    }

    if (self.manualScrollLastTimestamp <= 0) {
        self.manualScrollLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval deltaTime = displayLink.timestamp - self.manualScrollLastTimestamp;
    self.manualScrollLastTimestamp = displayLink.timestamp;

    CGPoint step = CGPointMake(self.manualScrollVelocity.x * deltaTime, self.manualScrollVelocity.y * deltaTime);
    BOOL didMove = [self applyManualScrollDelta:step];

    CGFloat decay = pow(0.92, deltaTime * 60.0);
    self.manualScrollVelocity = CGPointMake(self.manualScrollVelocity.x * decay, self.manualScrollVelocity.y * decay);

    if (!didMove ||
        (fabs(self.manualScrollVelocity.x) < 10.0 && fabs(self.manualScrollVelocity.y) < 10.0)) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

// Select normally reaches -handlePressesEnded:. This notification is the fallback for a press that
// some other responder consumed; the timestamp keeps one physical press from acting twice.
- (void)handleGlobalSelectPressEndedNotification {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.4) {
        return;
    }

    [self handleSelectPressEnded];
}

- (void)handleSelectPressEnded {
    self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
    self.lastTouchLocation = CGPointMake(-1, -1);

    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }

    if ([self.host browserRemoteInputControllerPageVideoActive]) {
        [self.host browserRemoteInputControllerPageVideoToggle];
        return;
    }

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self stopManualScrollInertia];
    }

    CGPoint translation = [gestureRecognizer translationInView:self.rootView];
    if (!CGPointEqualToPoint(translation, CGPointZero)) {
        [self applyManualScrollDelta:CGPointMake(-translation.x, -translation.y)];
        [gestureRecognizer setTranslation:CGPointZero inView:self.rootView];
        self.manualScrollLastMovementTimestamp = CACurrentMediaTime();
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        CFTimeInterval timeSinceLastMovement = CACurrentMediaTime() - self.manualScrollLastMovementTimestamp;
        CGPoint velocity = [gestureRecognizer velocityInView:self.rootView];
        if (timeSinceLastMovement < 0.08) {
            [self startManualScrollInertiaWithVelocity:CGPointMake(-velocity.x, -velocity.y)];
        } else {
            [self stopManualScrollInertia];
        }
        [self.host browserRemoteInputControllerPersistSession];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
               gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (BOOL)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }
    (void)event;
    if (press == nil) {
        return NO;
    }

    if (press.type == UIPressTypePlayPause) {
        // The system also sends this button to the page as a media toggle; let the page undo it.
        [self.host browserRemoteInputControllerFunctionKeyDown];
    }

    BrowserDirectionMask direction = [self directionMaskForPressType:press.type];
    if (direction != 0 && [self directionalInputAllowed]) {
        if ([self arrowPressIsFromGamepad]) {
            [self.ignoredStickPresses addObject:press];
            return YES;
        }
        [self beginDirection:direction];
        return YES;
    }

    if (press.type != UIPressTypeSelect && press.type != UIPressTypeMenu && press.type != UIPressTypePlayPause) {
        return [self handleHardwareKeyPress:press];
    }
    return NO;
}

/// A direction went down: remote arrow, keyboard arrow or controller D-pad.
- (void)beginDirection:(BrowserDirectionMask)direction {
    if ([self.host browserRemoteInputControllerPageVideoActive]) {
        if (self.heldDirections == 0) {
            self.cursorHoldStartTimestamp = CACurrentMediaTime();
        }
        self.heldDirections |= direction;
        self.lastFocusStepTimestamp = CACurrentMediaTime();
        [self seekPageVideoForDirectionMask:direction];
        [self ensureDirectionalDisplayLink];
        return;
    }

    BOOL vertical = direction == BrowserDirectionMaskUp || direction == BrowserDirectionMaskDown;
    if (vertical && self.cursorModeEnabled) {
        CFTimeInterval now = CACurrentMediaTime();
        self.verticalPressBeganTimestamp = now;
        if (self.lastVerticalTapDirection == direction &&
            (now - self.lastVerticalTapEndTimestamp) < kBrowserDoublePressInterval) {
            // Second quick press in the same direction: scroll instead of moving the cursor.
            self.scrollHoldDirection = direction;
            self.scrollHoldStartTimestamp = now;
            CGFloat sign = direction == BrowserDirectionMaskUp ? -1.0 : 1.0;
            [self.host browserRemoteInputControllerScrollPageByViewportFraction:sign * kBrowserDoublePressScrollFraction];
            [self ensureDirectionalDisplayLink];
            return;
        }
    }

    if (direction == BrowserDirectionMaskUp && [self shouldActivateTopBarForUpPress]) {
        [self.host browserRemoteInputControllerActivateTopBarFocus];
        return;
    }
    if (self.heldDirections == 0) {
        self.cursorHoldStartTimestamp = CACurrentMediaTime();
    }
    if (!self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil) {
        [self setCursorModeEnabled:YES];
    }
    self.heldDirections |= direction;
    self.lastFocusStepTimestamp = CACurrentMediaTime();
    if (self.cursorModeEnabled) {
        [self moveCursorByDelta:[self cursorDeltaForDirectionMask:direction speed:6.0]];
    } else {
        [self stepFocusInDirectionMask:direction];
    }
    [self ensureDirectionalDisplayLink];
}

- (void)endDirection:(BrowserDirectionMask)direction {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL vertical = direction == BrowserDirectionMaskUp || direction == BrowserDirectionMaskDown;
    BOOL wasScrolling = direction == self.scrollHoldDirection;
    if (wasScrolling) {
        self.scrollHoldDirection = 0;
    }
    // A short press arms the double press; after a scroll step every further quick press scrolls again.
    if (vertical && (wasScrolling || (now - self.verticalPressBeganTimestamp) < kBrowserTapMaximumDuration)) {
        self.lastVerticalTapDirection = direction;
        self.lastVerticalTapEndTimestamp = now;
    } else {
        self.lastVerticalTapDirection = 0;
    }
    self.heldDirections &= ~direction;
    [self stopDirectionalDisplayLinkIfIdle];
}

- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    for (UIPress *press in presses) {
        if ([self.ignoredStickPresses containsObject:press]) {
            [self.ignoredStickPresses removeObject:press];
            continue;
        }
        BrowserDirectionMask direction = [self directionMaskForPressType:press.type];
        self.heldDirections &= ~direction;
        if (direction != 0 && direction == self.scrollHoldDirection) {
            self.scrollHoldDirection = 0;
        }
    }
    self.lastVerticalTapDirection = 0;
    [self stopDirectionalDisplayLinkIfIdle];
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }
    if ([self.ignoredStickPresses containsObject:press]) {
        [self.ignoredStickPresses removeObject:press];
        return YES;
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        NSLog(@"[InputTrace][Root] pressesEnded type=%@ phase=%@ presented=%@ tabOverview=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]),
              [self.host browserRemoteInputControllerTabOverviewVisible] ? @"YES" : @"NO");
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypeDownArrow) {
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            return YES;
        }
        if (press.type == UIPressTypePlayPause) {
            [self handleFunctionKey];
            return YES;
        }
        if (press.type == UIPressTypeSelect ||
            press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow ||
            press.type == UIPressTypeUpArrow) {
            return NO;
        }
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if (press.type == UIPressTypeMenu) {
                [self.host browserRemoteInputControllerDismissTabOverview];
                return YES;
            }
            if (press.type == UIPressTypePlayPause) {
                [self.host browserRemoteInputControllerHandleTabOverviewAlternateAction];
                return YES;
            }
            return NO;
        }
        if (press.type == UIPressTypeMenu) {
            [presentedViewController dismissViewControllerAnimated:YES completion:nil];
            return YES;
        }
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        [self handleSelectPressEnded];
        return YES;
    }

    BrowserDirectionMask direction = [self directionMaskForPressType:press.type];
    if (direction != 0) {
        [self endDirection:direction];
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        if (press.type == UIPressTypeSelect) {
            [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            return YES;
        }
    }

    if (press.type == UIPressTypeMenu) {
        if ([self.host browserRemoteInputControllerPageVideoActive]) {
            [self.host browserRemoteInputControllerPageVideoExit];
            return YES;
        }
        [self.host browserRemoteInputControllerHandleMenuPress];
        return YES;
    }
    if (press.type == UIPressTypePlayPause) {
        [self handleFunctionKey];
        return YES;
    }
    return NO;
}

- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerPageVideoActive]) {
        return YES;
    }

    for (UITouch *touch in touches) {
        UIScrollView *activeScrollView = [self.host browserRemoteInputControllerActiveScrollView];
        UIView *targetView = activeScrollView ?: self.rootView;
        CGPoint location = [touch locationInView:targetView];

        if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
            self.lastTouchLocation = location;
        } else {
            CGFloat xDiff = location.x - self.lastTouchLocation.x;
            CGFloat yDiff = location.y - self.lastTouchLocation.y;
            self.lastTouchLocation = location;
            [self moveCursorByDelta:CGPointMake(xDiff, yDiff)];
        }
        break;
    }

    return YES;
}

- (void)handleTouchesEnded {
    self.lastTouchLocation = CGPointMake(-1, -1);
}

@end
