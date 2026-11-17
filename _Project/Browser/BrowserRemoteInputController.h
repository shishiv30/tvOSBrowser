#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserRemoteInputControllerHost <NSObject>

- (nullable UIScrollView *)browserRemoteInputControllerActiveScrollView;
- (nullable UIViewController *)browserRemoteInputControllerPresentedViewController;
- (BOOL)browserRemoteInputControllerTopBarFocusActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
- (void)browserRemoteInputControllerActivateTopBarFocus;
- (void)browserRemoteInputControllerDeactivateTopBarFocus;
- (BOOL)browserRemoteInputControllerTabOverviewVisible;
- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point;
- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point;
- (void)browserRemoteInputControllerDismissTabOverview;
- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction;
- (void)browserRemoteInputControllerHandlePrimaryAction;
/// YES while a page video fills the screen; arrows seek, confirm pauses, cancel leaves.
- (BOOL)browserRemoteInputControllerPageVideoActive;
- (void)browserRemoteInputControllerPageVideoToggle;
- (void)browserRemoteInputControllerPageVideoSeekBy:(NSTimeInterval)delta;
- (void)browserRemoteInputControllerPageVideoExit;
- (void)browserRemoteInputControllerScrollPageByDelta:(CGPoint)delta;
/// Animated step of `fraction` viewport heights; negative scrolls up.
- (void)browserRemoteInputControllerScrollPageByViewportFraction:(CGFloat)fraction;
- (void)browserRemoteInputControllerFunctionKeyDown;
/// Game mode was switched; `toggleButtonName` is how the connected controller labels the toggle button.
- (void)browserRemoteInputControllerGameModeDidChange:(BOOL)enabled toggleButtonName:(NSString *)toggleButtonName;
/// Runs a script that hands the controller state to the page (see `__tvb.pad` in BrowserPageAgent.js).
- (void)browserRemoteInputControllerEvaluateGamepadScript:(NSString *)script;
- (void)browserRemoteInputControllerHandleMenuPress;
- (void)browserRemoteInputControllerGoBack;
- (void)browserRemoteInputControllerGoForward;
- (void)browserRemoteInputControllerHandlePlayPausePress;
/// Plays the video under the pointer (else the page's main video) full screen.
- (void)browserRemoteInputControllerEnterPageVideo;
- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point;
- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled;
- (void)browserRemoteInputControllerPersistSession;
- (void)browserRemoteInputControllerMoveFocusInDirection:(NSString *)direction;
- (void)browserRemoteInputControllerActivateFocusedElement;
- (void)browserRemoteInputControllerInsertText:(NSString *)text;
- (void)browserRemoteInputControllerDeleteBackward;

@end

/// Appends one line to the input trace log (Library/Caches/input-trace.log).
FOUNDATION_EXPORT void BrowserInputTraceMessage(NSString *message);

@interface BrowserRemoteInputController : NSObject

@property (nonatomic, readonly) UIImageView *cursorView;
@property (nonatomic, readonly) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readonly, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
/// Game mode: the controller stops driving the browser and is exposed to the page as a Gamepad.
/// Turning it on needs a connected extended controller, because only that controller can turn it off.
@property (nonatomic, getter=isGameModeEnabled) BOOL gameModeEnabled;
@property (nonatomic, readonly) BOOL gameModeAvailable;
/// Label of the game mode toggle button on the connected controller ("−", "Create", "View").
@property (nonatomic, readonly) NSString *gameModeToggleButtonName;

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)handleGlobalSelectPressEndedNotification;
- (BOOL)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded;
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
