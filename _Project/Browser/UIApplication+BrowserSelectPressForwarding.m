#import "AppDelegate.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;

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

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIPressType sBrowserSwallowedPressType = (UIPressType)-1;

// Game mode: tvOS still turns the controller into Select / Menu / Play-Pause / arrow presses. They
// are dropped here, before any responder sees them; otherwise B (Menu) would leave the app.
BOOL BrowserGameModeSwallowsRemotePresses = NO;
// When the last Menu press of any phase went through the app, so a controller button read
// directly can tell whether tvOS already delivered the matching press.
CFTimeInterval BrowserLastMenuPressTimestamp = 0;
// Menu is taken away from the system here, including while a menu is presented. Left to the
// responder chain it can still end up as "leave the app" even though the browser handled it.
BOOL (^BrowserMenuPressShouldIntercept)(void) = nil;
void (^BrowserMenuPressPerform)(void) = nil;
void (^BrowserMenuPressBegan)(void) = nil;
static BOOL sBrowserMenuPressIntercepted = NO;
// Play/Pause is a media key once a page has a video: WKWebView consumes it and the
// view controller never sees pressesBegan, so the Quick Menu only opened on pages
// with no media. Take the press here, before that happens.
void (^BrowserPlayPausePressPerform)(UIPressPhase phase) = nil;
static BOOL sBrowserPlayPauseForMenu = NO;
// A synthetic click runs inside sendEvent: and WebKit sends another non-press event
// before that call returns. Forwarding it here nests sendEvent: and the app stops responding.
static BOOL sBrowserSendEventEntered = NO;

FOUNDATION_EXPORT void BrowserInputTraceMessage(NSString *message);

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.rootViewController == nil) {
                continue;
            }

            UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
            if (match != nil) {
                return match;
            }
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
    });
}

- (void)browser_sendEvent:(UIEvent *)event {
    if (sBrowserSendEventEntered && event.type != UIEventTypePresses) {
        return;
    }
    BOOL outermost = !sBrowserSendEventEntered;
    sBrowserSendEventEntered = YES;
    @try {
    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);

    if (event.type == UIEventTypeTouches) {
        SEL allTouchesSelector = NSSelectorFromString(@"allTouches");
        if ([event respondsToSelector:allTouchesSelector]) {
            NSSet<UITouch *> *touches = ((id (*)(id, SEL))objc_msgSend)(event, allTouchesSelector);
            for (UITouch *touch in touches) {
                if (touch.type != UITouchTypeIndirect) {
                    continue;
                }

                CGPoint location = [touch locationInView:nil];
                if (touch.phase == UITouchPhaseBegan) {
                    sBrowserNativeScrubTracking = (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil);
                    sBrowserNativePendingScrubPixels = 0.0;
                    sBrowserNativeLastTouchLocation = location;
                    continue;
                }

                if (!sBrowserNativeScrubTracking || nativeVideoPlayerViewController == nil) {
                    continue;
                }

                if (touch.phase == UITouchPhaseMoved) {
                    CGFloat deltaX = location.x - sBrowserNativeLastTouchLocation.x;
                    sBrowserNativeLastTouchLocation = location;
                    sBrowserNativePendingScrubPixels += deltaX;

                    SEL scrubSelector = NSSelectorFromString(@"scrubByHorizontalDelta:");
                    if ([nativeVideoPlayerViewController respondsToSelector:scrubSelector]) {
                        while (fabs(sBrowserNativePendingScrubPixels) >= kBrowserNativeScrubPixelStep) {
                            CGFloat step = sBrowserNativePendingScrubPixels > 0.0 ? kBrowserNativeScrubPixelStep : -kBrowserNativeScrubPixelStep;
                            ((void (*)(id, SEL, CGFloat))objc_msgSend)(nativeVideoPlayerViewController, scrubSelector, step);
                            sBrowserNativePendingScrubPixels -= step;
                            NSLog(@"[InputTrace][App] scrub step delta=%.2f", step);
                        }
                    }
                }

                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    sBrowserNativeScrubTracking = NO;
                    sBrowserNativePendingScrubPixels = 0.0;
                }
            }
        }

        [self browser_sendEvent:event];
        return;
    }

    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
        return;
    }

    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    if (BrowserGameModeSwallowsRemotePresses && nativeVideoPlayerViewController == nil) {
        BOOL onlyRemoteButtons = presses.count > 0;
        for (UIPress *press in presses) {
            if (press.type < UIPressTypeUpArrow || press.type > UIPressTypePlayPause) {
                onlyRemoteButtons = NO;
            }
        }
        if (onlyRemoteButtons) {
            return;
        }
    }
    BOOL skipSystemDelivery = NO;
    for (UIPress *press in presses) {
        nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
        if (press.type == UIPressTypeMenu) {
            BrowserLastMenuPressTimestamp = CACurrentMediaTime();
        }
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
            BrowserInputTraceMessage([NSString stringWithFormat:@"app press %@ %@ count=%lu nativePlayer=%d swallowed=%ld",
                                      BrowserPressTypeString(press.type), BrowserPressPhaseString(press.phase),
                                      (unsigned long)presses.count, nativeVideoPlayerViewController != nil, (long)sBrowserSwallowedPressType]);
            NSLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }

        if (press.type == sBrowserSwallowedPressType) {
            if (press.phase == UIPressPhaseEnded) {
                if (press.type == UIPressTypePlayPause && sBrowserPlayPauseForMenu && BrowserPlayPausePressPerform != nil) {
                    BrowserPlayPausePressPerform(UIPressPhaseEnded);
                } else {
                    SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                    if ((press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) &&
                        [nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
                        });
                    }
                }
            }
            if ((press.phase == UIPressPhaseCancelled) && press.type == UIPressTypePlayPause &&
                sBrowserPlayPauseForMenu && BrowserPlayPausePressPerform != nil) {
                BrowserPlayPausePressPerform(UIPressPhaseCancelled);
            }
            if (press.phase == UIPressPhaseEnded && press.type == UIPressTypeMenu && sBrowserMenuPressIntercepted &&
                BrowserMenuPressPerform != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    BrowserMenuPressPerform();
                });
            }
            if (press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled) {
                sBrowserSwallowedPressType = (UIPressType)-1;
                sBrowserMenuPressIntercepted = NO;
                sBrowserPlayPauseForMenu = NO;
            }
            return;
        }

        if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan && nativeVideoPlayerViewController == nil &&
            BrowserMenuPressShouldIntercept != nil && BrowserMenuPressShouldIntercept()) {
            BrowserInputTraceMessage(@"app intercepts Menu");
            sBrowserSwallowedPressType = UIPressTypeMenu;
            sBrowserMenuPressIntercepted = YES;
            if (BrowserMenuPressBegan != nil) {
                BrowserMenuPressBegan();
            }
            return;
        }

        if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                NSLog(@"[InputTrace][App] swallow Menu for native player");
                sBrowserSwallowedPressType = UIPressTypeMenu;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [nativeVideoPlayerViewController dismissViewControllerAnimated:YES completion:nil];
                });
                return;
            }
        }

        if (press.type == UIPressTypePlayPause && press.phase == UIPressPhaseBegan) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                sBrowserSwallowedPressType = UIPressTypePlayPause;
                return;
            }
            if (BrowserPlayPausePressPerform != nil) {
                BrowserInputTraceMessage(@"app intercepts PlayPause for Quick Menu");
                sBrowserSwallowedPressType = UIPressTypePlayPause;
                sBrowserPlayPauseForMenu = YES;
                BrowserPlayPausePressPerform(UIPressPhaseBegan);
                return;
            }
        }

        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseBegan &&
            nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
            sBrowserSwallowedPressType = UIPressTypeSelect;
            return;
        }

        if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) &&
            nativeVideoPlayerViewController != nil) {
            skipSystemDelivery = YES;
            if (press.phase == UIPressPhaseEnded) {
                SEL skipSelector = NSSelectorFromString(@"skipByIntervalAndContinue:");
                if ([nativeVideoPlayerViewController respondsToSelector:skipSelector]) {
                    NSTimeInterval delta = (press.type == UIPressTypeRightArrow) ? 10.0 : -10.0;
                    NSLog(@"[InputTrace][App] native player %@ seek delta=%0.1f",
                          BrowserPressTypeString(press.type), delta);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(nativeVideoPlayerViewController, skipSelector, delta);
                    });
                }
            }
        }
    }

    if (skipSystemDelivery) {
        return;
    }
    @try {
        [self browser_sendEvent:event];
    } @catch (NSException *exception) {
        BrowserRecoverFromException(exception);
    }

    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            BrowserInputTraceMessage(@"app posts global select");
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
    } @finally {
        if (outermost) {
            sBrowserSendEventEntered = NO;
        }
    }
}

@end
