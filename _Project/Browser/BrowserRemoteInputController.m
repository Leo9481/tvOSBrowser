#import "BrowserRemoteInputController.h"

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

// ---- D-pad cursor control (for remotes without a touch surface) ----
// Set to NO to restore the original behaviour (arrows are not used to move the cursor).
static const BOOL kBrowserDPadCursorEnabled = YES;
static const CGFloat kDPadScreenWidth = 1920.0;      // same bounds the touch code uses
static const CGFloat kDPadScreenHeight = 1080.0;
static const CGFloat kDPadTapStep = 48.0;            // points moved by a single quick press
static const CGFloat kDPadMinSpeed = 350.0;          // points/second when a hold begins
static const CGFloat kDPadMaxSpeed = 1800.0;         // points/second after the ramp-up
static const CFTimeInterval kDPadHoldDelay = 0.25;   // seconds before continuous movement starts
static const CFTimeInterval kDPadRampDuration = 1.2; // seconds to reach max speed
static const CGFloat kDPadEdgeMargin = 4.0;          // "at the screen edge" tolerance
static const CGFloat kDPadScrollSpeed = 900.0;       // page scroll speed when pushing against an edge
// Max gap between two Select presses to count as a double press (toggles cursor/scroll mode).
// Single clicks are delayed by this long, so lower it if clicking feels sluggish.
static const CFTimeInterval kSelectDoublePressWindow = 0.5;
// Scroll mode: arrows scroll the page (tap = one step, hold = continuous with ramp-up).
static const CGFloat kDPadScrollTapStep = 240.0;
static const CGFloat kDPadScrollMinSpeed = 600.0;
static const CGFloat kDPadScrollMaxSpeed = 2400.0;

static BOOL BrowserIsArrowPress(UIPressType type) {
    return type == UIPressTypeUpArrow ||
           type == UIPressTypeDownArrow ||
           type == UIPressTypeLeftArrow ||
           type == UIPressTypeRightArrow;
}

static CGPoint BrowserDPadDirection(UIPressType type) {
    switch (type) {
        case UIPressTypeUpArrow: return CGPointMake(0, -1);
        case UIPressTypeDownArrow: return CGPointMake(0, 1);
        case UIPressTypeLeftArrow: return CGPointMake(-1, 0);
        case UIPressTypeRightArrow: return CGPointMake(1, 0);
        default: return CGPointZero;
    }
}

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic, readwrite) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readwrite) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
@property (nonatomic) CGPoint lastTouchLocation;
@property (nonatomic) CADisplayLink *manualScrollDisplayLink;
@property (nonatomic) CGPoint manualScrollVelocity;
@property (nonatomic) CFTimeInterval manualScrollLastTimestamp;
@property (nonatomic) CFTimeInterval manualScrollLastMovementTimestamp;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) CFTimeInterval lastSelectPressTimestamp;
@property (nonatomic) BOOL awaitingSecondSelectPress;
@property (nonatomic) CADisplayLink *dpadDisplayLink;
@property (nonatomic) UIPressType dpadHeldType;
@property (nonatomic) CFTimeInterval dpadHoldStart;
@property (nonatomic) CFTimeInterval dpadLastTimestamp;
@property (nonatomic) BOOL dpadPressBeganAtTopEdge;
@property (nonatomic) BOOL dpadDidScroll;

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

        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        _cursorView.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        _cursorView.image = BrowserDefaultCursor();

        _playPauseDoubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayPauseDoubleTap:)];
        _playPauseDoubleTapRecognizer.numberOfTapsRequired = 2;
        _playPauseDoubleTapRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        [rootView addGestureRecognizer:_playPauseDoubleTapRecognizer];

        _manualScrollPanRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleManualScrollPan:)];
        _manualScrollPanRecognizer.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
        _manualScrollPanRecognizer.cancelsTouchesInView = NO;
        _manualScrollPanRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_manualScrollPanRecognizer];
    }
    return self;
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self stopManualScrollInertia];
    [self stopDPadMovement];
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
    self.cursorView.hidden = !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        topBarFocusActive;
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

- (void)handleGlobalSelectPressEndedNotification {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.15) {
        return;
    }

    [self handleSelectPressEnded];
}

- (void)handleDeferredSelectPressAction {
    if (!self.awaitingSecondSelectPress) {
        return;
    }

    self.awaitingSecondSelectPress = NO;
    self.lastTouchLocation = CGPointMake(-1, -1);

    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handleSelectPressEnded {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.awaitingSecondSelectPress && (now - self.lastSelectPressTimestamp) < kSelectDoublePressWindow) {
        self.awaitingSecondSelectPress = NO;
        self.lastSelectPressTimestamp = now;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
        if (![self.host browserRemoteInputControllerTabOverviewVisible]) {
            [self setCursorModeEnabled:!self.cursorModeEnabled];
        }
        return;
    }

    self.awaitingSecondSelectPress = YES;
    self.lastSelectPressTimestamp = now;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    [self performSelector:@selector(handleDeferredSelectPressAction) withObject:nil afterDelay:kSelectDoublePressWindow];
}

- (void)handlePlayPauseDoubleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
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

- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }
    if (press != nil && BrowserIsArrowPress(press.type) && [self dpadControlActive]) {
        [self beginDPadPress:press];
    }
    (void)event;
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
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

    if ([self endDPadPress:press]) {
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        [self handleSelectPressEnded];
        return YES;
    }

    if (press.type == UIPressTypeUpArrow &&
        [self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
        [self.host browserRemoteInputControllerActivateTopBarFocus];
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
        [self.host browserRemoteInputControllerHandleMenuPress];
        return YES;
    }
    if (press.type == UIPressTypePlayPause) {
        [self.host browserRemoteInputControllerHandlePlayPausePress];
        return YES;
    }
    return NO;
}

#pragma mark - D-pad cursor control

- (BOOL)dpadCursorControlActive {
    if (!kBrowserDPadCursorEnabled || !self.cursorModeEnabled) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil ||
        [self.host browserRemoteInputControllerTopBarFocusActive] ||
        [self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    return YES;
}

- (BOOL)dpadScrollControlActive {
    if (!kBrowserDPadCursorEnabled || self.cursorModeEnabled) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil ||
        [self.host browserRemoteInputControllerTopBarFocusActive] ||
        [self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    return YES;
}

- (BOOL)dpadControlActive {
    return [self dpadCursorControlActive] || [self dpadScrollControlActive];
}

- (void)updateCursorImage {
    self.cursorView.image = BrowserDefaultCursor();
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if ([self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
            self.cursorView.image = BrowserPointerCursor();
        }
        return;
    }
    if (self.cursorModeEnabled) {
        NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
        if ([containsLink isEqualToString:@"true"]) {
            self.cursorView.image = BrowserPointerCursor();
        }
    }
}

- (void)moveCursorByDelta:(CGPoint)delta {
    CGRect rect = self.cursorView.frame;
    rect.origin.x = MIN(MAX(rect.origin.x + delta.x, 0.0), kDPadScreenWidth);
    rect.origin.y = MIN(MAX(rect.origin.y + delta.y, 0.0), kDPadScreenHeight);
    self.cursorView.frame = rect;
    [self updateCursorImage];
}

- (void)stopDPadMovement {
    [self.dpadDisplayLink invalidate];
    self.dpadDisplayLink = nil;
    self.dpadDidScroll = NO;
    self.dpadPressBeganAtTopEdge = NO;
}

- (void)beginDPadPress:(UIPress *)press {
    [self stopDPadMovement];

    CGPoint direction = BrowserDPadDirection(press.type);
    self.dpadHeldType = press.type;
    self.dpadHoldStart = CACurrentMediaTime();
    self.dpadLastTimestamp = 0;
    if (self.cursorModeEnabled) {
        self.dpadPressBeganAtTopEdge = (press.type == UIPressTypeUpArrow &&
                                        CGRectGetMinY(self.cursorView.frame) <= kDPadEdgeMargin);
        // A quick tap still moves the cursor a little.
        [self moveCursorByDelta:CGPointMake(direction.x * kDPadTapStep, direction.y * kDPadTapStep)];
    } else {
        UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
        self.dpadPressBeganAtTopEdge = (press.type == UIPressTypeUpArrow &&
                                        (scrollView == nil || scrollView.contentOffset.y <= kDPadEdgeMargin));
        // A quick tap scrolls the page one step.
        if ([self applyManualScrollDelta:CGPointMake(direction.x * kDPadScrollTapStep, direction.y * kDPadScrollTapStep)]) {
            self.dpadDidScroll = YES;
        }
    }

    self.dpadDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDPadDisplayLink:)];
    [self.dpadDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleDPadDisplayLink:(CADisplayLink *)link {
    if (![self dpadControlActive]) {
        [self stopDPadMovement];
        return;
    }

    if (self.dpadLastTimestamp <= 0) {
        self.dpadLastTimestamp = link.timestamp;
        return;
    }
    CFTimeInterval deltaTime = MIN(link.timestamp - self.dpadLastTimestamp, 0.1);
    self.dpadLastTimestamp = link.timestamp;

    CFTimeInterval held = CACurrentMediaTime() - self.dpadHoldStart;
    if (held < kDPadHoldDelay) {
        return;
    }

    CGFloat ramp = MIN((held - kDPadHoldDelay) / kDPadRampDuration, 1.0);
    CGFloat speed = kDPadMinSpeed + (kDPadMaxSpeed - kDPadMinSpeed) * ramp;
    CGPoint direction = BrowserDPadDirection(self.dpadHeldType);

    if (!self.cursorModeEnabled) {
        CGFloat scrollSpeed = kDPadScrollMinSpeed + (kDPadScrollMaxSpeed - kDPadScrollMinSpeed) * ramp;
        CGPoint scrollStep = CGPointMake(direction.x * scrollSpeed * deltaTime, direction.y * scrollSpeed * deltaTime);
        if ([self applyManualScrollDelta:scrollStep]) {
            self.dpadDidScroll = YES;
        }
        return;
    }

    CGPoint before = self.cursorView.frame.origin;
    [self moveCursorByDelta:CGPointMake(direction.x * speed * deltaTime, direction.y * speed * deltaTime)];
    CGPoint after = self.cursorView.frame.origin;

    // Cursor is pinned against a screen edge: keep holding to scroll the page instead.
    if (fabs(after.x - before.x) + fabs(after.y - before.y) < 0.5) {
        CGPoint scrollDelta = CGPointMake(direction.x * kDPadScrollSpeed * deltaTime,
                                          direction.y * kDPadScrollSpeed * deltaTime);
        if ([self applyManualScrollDelta:scrollDelta]) {
            self.dpadDidScroll = YES;
        }
    }
}

- (BOOL)endDPadPress:(UIPress *)press {
    if (self.dpadDisplayLink == nil || self.dpadHeldType != press.type) {
        return NO;
    }

    BOOL didScroll = self.dpadDidScroll;
    // Tapping Up while already at the top (cursor at the top edge, or page scrolled to the top
    // in scroll mode) opens the top bar, as Up did before.
    BOOL activateTopBar = press.type == UIPressTypeUpArrow &&
                          self.dpadPressBeganAtTopEdge &&
                          !didScroll &&
                          [self.host browserRemoteInputControllerCanActivateTopBarFocus];
    [self stopDPadMovement];

    if (activateTopBar) {
        [self.host browserRemoteInputControllerActivateTopBarFocus];
    } else if (didScroll) {
        [self.host browserRemoteInputControllerPersistSession];
    }
    return YES;
}

- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)presses;
    (void)event;
    [self stopDPadMovement];
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

    for (UITouch *touch in touches) {
        UIScrollView *activeScrollView = [self.host browserRemoteInputControllerActiveScrollView];
        UIView *targetView = activeScrollView ?: self.rootView;
        CGPoint location = [touch locationInView:targetView];

        if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
            self.lastTouchLocation = location;
        } else {
            CGFloat xDiff = location.x - self.lastTouchLocation.x;
            CGFloat yDiff = location.y - self.lastTouchLocation.y;
            CGRect rect = self.cursorView.frame;

            if (rect.origin.x + xDiff >= 0 && rect.origin.x + xDiff <= 1920) {
                rect.origin.x += xDiff;
            }
            if (rect.origin.y + yDiff >= 0 && rect.origin.y + yDiff <= 1080) {
                rect.origin.y += yDiff;
            }
            self.cursorView.frame = rect;
            self.lastTouchLocation = location;
        }

        self.cursorView.image = BrowserDefaultCursor();
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if ([self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
                self.cursorView.image = BrowserPointerCursor();
            }
            break;
        }
        if (self.cursorModeEnabled) {
            NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
            if ([containsLink isEqualToString:@"true"]) {
                self.cursorView.image = BrowserPointerCursor();
            }
        }
        break;
    }

    return YES;
}

- (void)handleTouchesEnded {
    self.lastTouchLocation = CGPointMake(-1, -1);
}

@end
