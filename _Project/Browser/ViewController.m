//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <QuartzCore/QuartzCore.h>

#import "BrowserMenuCoordinator.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
/// A page video currently fills the screen (driven by BrowserPageAgent.js).
@property (nonatomic) BOOL pageVideoActive;
@property (nonatomic, weak) UILabel *toastLabel;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can bring it back from the Quick Menu (Play/Pause button)."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter URL or Search Terms"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"Enter URL or Search Terms";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Search Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf.webview loadRequest:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Go To Website"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf.webview loadRequest:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        BOOL videoActive = self.pageVideoActive;
        [alertController addAction:[UIAlertAction actionWithTitle:videoActive ? @"Exit Full Screen Video" : @"Full Screen Video"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            if (videoActive) {
                [self exitPageVideo];
            } else {
                [self enterPageVideoFromMenu];
            }
        }]];
    }

    if (self.webview.canGoBack) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Back"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goBack];
        }]];
    }

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Input URL or Search with Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    NSString *fullScreenTitle = self.viewModel.topNavigationBarVisible ? @"Hide Top Bar" : @"Show Top Bar";
    [alertController addAction:[UIAlertAction actionWithTitle:fullScreenTitle
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        if (self.viewModel.topNavigationBarVisible) {
            [self browserHideTopNav];
        } else {
            [self browserShowTopNav];
        }
    }]];

    BOOL adBlockEnabled = [BrowserWebView isAdBlockEnabled];
    [alertController addAction:[UIAlertAction actionWithTitle:adBlockEnabled ? @"Ad Block: On" : @"Ad Block: Off"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [BrowserWebView setAdBlockEnabled:!adBlockEnabled];
        [self.webview reload];
    }]];
    if (self.remoteInputController.gameModeAvailable) {
        // Hands the controller to the page as a Gamepad; only the controller can switch it back.
        NSString *title = [NSString stringWithFormat:@"Game Mode (hold %@ to exit)", self.remoteInputController.gameModeToggleButtonName];
        [alertController addAction:[UIAlertAction actionWithTitle:title
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.remoteInputController.gameModeEnabled = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"More Options"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showAdvancedMenu];
    }]];

    [self addQuickMenuFavoriteActionsToAlertController:alertController];

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (NSString *)quickMenuHostForURLString:(NSString *)URLString {
    NSString *host = [NSURL URLWithString:URLString].host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host ?: @"";
}

- (void)addQuickMenuFavoriteActionsToAlertController:(UIAlertController *)alertController {
    NSString *currentHost = [self quickMenuHostForURLString:self.webview.request.URL.absoluteString];
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    NSInteger matchedIndex = NSNotFound;
    if (currentHost.length > 0) {
        for (NSUInteger index = 0; index < favorites.count; index += 1) {
            NSArray *entry = favorites[index];
            NSString *URLString = entry.count > 0 ? entry[0] : @"";
            if ([[self quickMenuHostForURLString:URLString] isEqualToString:currentHost]) {
                matchedIndex = (NSInteger)index;
                break;
            }
        }
    }

    __weak typeof(self) weakSelf = self;
    if (currentHost.length > 0 && matchedIndex == NSNotFound) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Add Favorite"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *URL = weakSelf.webview.request.URL;
            NSString *scheme = URL.scheme.length > 0 ? URL.scheme : @"https";
            NSString *favoriteURL = [NSString stringWithFormat:@"%@://%@", scheme, URL.host];
            NSMutableArray *updatedFavorites = [favorites mutableCopy] ?: [NSMutableArray array];
            [updatedFavorites addObject:@[favoriteURL, currentHost]];
            [[NSUserDefaults standardUserDefaults] setObject:updatedFavorites forKey:@"FAVORITES"];
        }]];
    } else if (matchedIndex != NSNotFound) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Remove Favorite"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            NSMutableArray *updatedFavorites = [favorites mutableCopy];
            if (matchedIndex >= 0 && matchedIndex < (NSInteger)updatedFavorites.count) {
                [updatedFavorites removeObjectAtIndex:(NSUInteger)matchedIndex];
                [[NSUserDefaults standardUserDefaults] setObject:updatedFavorites forKey:@"FAVORITES"];
            }
        }]];
    }

    for (NSArray *entry in favorites) {
        NSString *URLString = entry.count > 0 ? [entry[0] copy] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        if (URLString.length == 0) {
            continue;
        }
        NSString *displayTitle = title.length > 0 ? title : URLString;
        [alertController addAction:[UIAlertAction actionWithTitle:displayTitle
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *URL = [NSURL URLWithString:URLString];
            if (URL != nil) {
                [weakSelf.webview loadRequest:[NSURLRequest requestWithURL:URL]];
            }
        }]];
    }
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Usage Guide"
                                                                             message:@"Arrows / D-pad move the cursor; push against a screen edge to scroll.\nSelect / A clicks. Quick Menu > Full Screen Video plays the video full screen.\nMenu / B goes back, and leaves full screen video.\nPlay/Pause / X opens the Quick Menu.\nIn full screen: Select pauses, Left/Right skip 10 seconds.\nGamepad: Switch Y / PS square / Xbox X plays the video full screen, L1 back, R1 forward, hold L2 / R2 to move faster."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Page video full screen

// The page script makes the <video> (or the iframe holding it) fill the web view, so it works for
// blob/MSE players that AVPlayer cannot open. Natively we only hide the chrome and route the keys.
- (void)setPageVideoActive:(BOOL)pageVideoActive {
    if (_pageVideoActive == pageVideoActive) {
        return;
    }
    _pageVideoActive = pageVideoActive;
    [self updateTopNavigationForImmersiveState];
    [self.remoteInputController refreshInteractionState];
}

/// A full screen video and game mode both take the whole screen: no top bar while either is on.
- (void)updateTopNavigationForImmersiveState {
    if (self.pageVideoActive || self.remoteInputController.gameModeEnabled) {
        [self deactivateTopBarFocusMode];
        [self.tabCoordinator setTopNavigationVisible:NO];
    } else {
        [self.tabCoordinator setTopNavigationVisible:self.preferencesStore.topNavigationBarVisible];
    }
}

#pragma mark - Game mode

- (void)browserRemoteInputControllerGameModeDidChange:(BOOL)enabled toggleButtonName:(NSString *)toggleButtonName {
    [self updateTopNavigationForImmersiveState];
    NSString *message = enabled
        ? [NSString stringWithFormat:@"Game Mode On  ·  hold %@ to return to the browser", toggleButtonName]
        : @"Game Mode Off";
    [self showToastWithMessage:message];
}

- (void)browserRemoteInputControllerEvaluateGamepadScript:(NSString *)script {
    [self.webview evaluateJavaScriptWithoutWaiting:script];
}

- (void)showToastWithMessage:(NSString *)message {
    [self.toastLabel removeFromSuperview];
    UILabel *label = [UILabel new];
    label.text = [NSString stringWithFormat:@"   %@   ", message];
    label.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 18.0;
    label.layer.masksToBounds = YES;
    [label sizeToFit];
    CGRect frame = CGRectInset(label.frame, 0.0, -14.0);
    frame.origin = CGPointMake(CGRectGetMidX(self.view.bounds) - CGRectGetWidth(frame) / 2.0,
                               CGRectGetMaxY(self.view.bounds) - CGRectGetHeight(frame) - 70.0);
    label.frame = frame;
    [self.view addSubview:label];
    self.toastLabel = label;
    [UIView animateWithDuration:0.4 delay:3.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        label.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [label removeFromSuperview];
    }];
}

- (NSString *)evaluatePageAgentCall:(NSString *)call fallback:(NSString *)fallback {
    if (self.webview == nil) {
        return fallback;
    }
    NSString *script = [NSString stringWithFormat:@"(function(){try{return window.__tvb?String(window.__tvb.%@):'%@';}catch(error){return '%@';}})();",
                        call, fallback, fallback];
    return [self.webview stringByEvaluatingJavaScriptFromString:script] ?: fallback;
}

/// Asks the page directly. The page also pushes changes (see -webView:didReceiveAgentMessage:);
/// this covers the moments where a push could have been missed.
- (BOOL)syncPageVideoState {
    BOOL active = [[self evaluatePageAgentCall:@"state()" fallback:@"0"] isEqualToString:@"1"];
    self.pageVideoActive = active;
    return active;
}

- (void)schedulePageVideoStateChecks {
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@0.4, @1.2, @2.5, @5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.presentedViewController == nil) {
                [weakSelf syncPageVideoState];
            }
        });
    }
}

- (void)exitPageVideo {
    [self evaluatePageAgentCall:@"exit()" fallback:@""];
    self.pageVideoActive = NO;
}

- (BOOL)browserFullscreenVideoActive {
    return self.pageVideoActive;
}

- (void)webView:(id)webView didReceiveAgentMessage:(NSDictionary *)message {
    if (webView != self.webview) {
        return;
    }
    // A playing video takes the remote's Play/Pause as a media-session action, so it never
    // arrives as a UIPress. That action is the Quick Menu request on those pages.
    if ([message[@"type"] isEqual:@"media-key"]) {
        NSString *action = [message[@"action"] isKindOfClass:[NSString class]] ? message[@"action"] : @"";
        if (![action isEqualToString:@"play"] && ![action isEqualToString:@"pause"] && ![action isEqualToString:@"stop"]) {
            return;
        }
        static CFTimeInterval lastMediaKey = 0;
        CFTimeInterval now = CACurrentMediaTime();
        BOOL menuVisible = [self.presentedViewController isKindOfClass:[UIAlertController class]];
        if (menuVisible || (now - lastMediaKey) < 0.8) {
            return;
        }
        lastMediaKey = now;
        [self browserRemoteInputControllerFunctionKeyDown];
        [self browserRemoteInputControllerHandlePlayPausePress];
        return;
    }
    if (![message[@"type"] isEqual:@"fs"]) {
        return;
    }
    self.pageVideoActive = [message[@"active"] respondsToSelector:@selector(boolValue)] && [message[@"active"] boolValue];
}

- (void)browserHandlePrimaryAction {
    if (self.webview == nil) {
        BrowserInputTraceMessage(@"click: no web view");
        return;
    }
    if (!self.remoteInputController.cursorModeEnabled) {
        BrowserInputTraceMessage(@"click: cursor mode off, activating focused element");
        [self activateFocusedPageElement];
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        BrowserInputTraceMessage(@"click: cursor above page, opening top bar");
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    // A click only clicks. Full screen video is its own command (Quick Menu > Full Screen Video).
    NSString *call = [NSString stringWithFormat:@"activate(%0.2f,%0.2f,false)", domPoint.x, domPoint.y];
    NSString *result = [self evaluatePageAgentCall:call fallback:@"none"];
    BrowserInputTraceMessage([NSString stringWithFormat:@"click: %@ -> %@ url=%@", call, result, self.webview.request.URL.host ?: @"?"]);
    if (![result isEqualToString:@"frame"]) {
        // "frame" means a cross-origin iframe took the click itself; everything else is a normal click.
        [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
    }
}

/// Quick Menu command: the video under the cursor, else the page's main video, fills the screen.
- (void)enterPageVideoFromMenu {
    if (self.webview == nil) {
        return;
    }
    CGPoint domPoint = self.remoteInputController.cursorModeEnabled ? [self browserDOMPointForCursor] : CGPointMake(-1.0, -1.0);
    NSString *call = [NSString stringWithFormat:@"fullscreenAt(%0.2f,%0.2f)", domPoint.x, domPoint.y];
    NSString *result = [self evaluatePageAgentCall:call fallback:@"none"];
    BrowserInputTraceMessage([NSString stringWithFormat:@"full screen video: %@ -> %@", call, result]);
    if ([result isEqualToString:@"video"]) {
        self.pageVideoActive = YES;
        return;
    }
    if ([result isEqualToString:@"none"]) {
        [self showToastWithMessage:@"No video found on this page"];
        return;
    }
    // A cross-origin frame was asked; it reports back on its own if it has a video.
    [self schedulePageVideoStateChecks];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.presentedViewController == nil && ![weakSelf syncPageVideoState]) {
            [weakSelf showToastWithMessage:@"No video found on this page"];
        }
    });
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (BOOL)browserRemoteInputControllerPageVideoActive {
    return self.pageVideoActive;
}

- (void)browserRemoteInputControllerPageVideoToggle {
    [self evaluatePageAgentCall:@"command('toggle')" fallback:@""];
}

- (void)browserRemoteInputControllerPageVideoSeekBy:(NSTimeInterval)delta {
    [self evaluatePageAgentCall:[NSString stringWithFormat:@"command('seek',%0.1f)", delta] fallback:@""];
}

- (void)browserRemoteInputControllerPageVideoExit {
    [self exitPageVideo];
}

- (void)browserRemoteInputControllerScrollPageByDelta:(CGPoint)delta {
    if (self.webview == nil || self.pageVideoActive) {
        return;
    }
    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    point.y = MAX(point.y, 1.0);
    NSString *script = [NSString stringWithFormat:@"window.__tvb&&window.__tvb.scrollBy(%0.1f,%0.1f,%0.1f,%0.1f);",
                        point.x, point.y, delta.x, delta.y];
    [self.webview evaluateJavaScriptWithoutWaiting:script];
}

- (void)browserRemoteInputControllerScrollPageByViewportFraction:(CGFloat)fraction {
    if (self.webview == nil || self.pageVideoActive) {
        return;
    }
    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    point.y = MAX(point.y, 1.0);
    NSString *script = [NSString stringWithFormat:@"window.__tvb&&window.__tvb.page(%0.1f,%0.1f,%0.2f);", point.x, point.y, fraction];
    [self.webview evaluateJavaScriptWithoutWaiting:script];
}

- (void)browserRemoteInputControllerFunctionKeyDown {
    [self.webview evaluateJavaScriptWithoutWaiting:@"window.__tvb&&window.__tvb.guard();"];
}

- (void)browserRemoteInputControllerGoBack {
    if (self.webview.canGoBack) {
        [self.webview goBack];
    }
}

- (void)browserRemoteInputControllerGoForward {
    if (self.webview.canGoForward) {
        [self.webview goForward];
    }
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if ([self syncPageVideoState]) {
        [self exitPageVideo];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)browserRemoteInputControllerEnterPageVideo {
    [self enterPageVideoFromMenu];
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    BrowserInputTraceMessage([NSString stringWithFormat:@"quick menu toggle: presented=%@ window=%d", NSStringFromClass([self.presentedViewController class]) ?: @"-", self.view.window != nil]);
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

- (NSString *)browserFocusScriptForDirection:(NSString *)direction {
    return [NSString stringWithFormat:
            @"(function(){"
            "var selector='a[href],button,input,textarea,select,summary,[contenteditable=\"true\"],[role=\"button\"],[role=\"link\"],[tabindex]:not([tabindex=\"-1\"])';"
            "function visible(el){"
            "if(!el||el.disabled){return false;}"
            "var style=window.getComputedStyle(el);"
            "if(style.display==='none'||style.visibility==='hidden'||style.visibility==='collapse'){return false;}"
            "var r=el.getBoundingClientRect();"
            "if(r.width<2||r.height<2){return false;}"
            "if(r.bottom<0||r.top>window.innerHeight||r.right<0||r.left>window.innerWidth){return false;}"
            "return true;"
            "}"
            "var nodes=Array.prototype.filter.call(document.querySelectorAll(selector),visible);"
            "var active=document.activeElement;"
            "var current=nodes.indexOf(active)>=0?active:null;"
            "var origin=current?current.getBoundingClientRect():{left:window.innerWidth/2,top:window.innerHeight/2,width:0,height:0};"
            "var cx=origin.left+origin.width/2;"
            "var cy=origin.top+origin.height/2;"
            "var dir='%@';"
            "var best=null;var bestScore=Infinity;"
            "nodes.forEach(function(el){"
            "if(el===current){return;}"
            "var r=el.getBoundingClientRect();"
            "var dx=(r.left+r.width/2)-cx;"
            "var dy=(r.top+r.height/2)-cy;"
            "var primary=0,secondary=0;"
            "if(dir==='up'){primary=-dy;secondary=Math.abs(dx);}"
            "if(dir==='down'){primary=dy;secondary=Math.abs(dx);}"
            "if(dir==='left'){primary=-dx;secondary=Math.abs(dy);}"
            "if(dir==='right'){primary=dx;secondary=Math.abs(dy);}"
            "if(primary<8){return;}"
            "var score=secondary*2+primary;"
            "if(score<bestScore){bestScore=score;best=el;}"
            "});"
            "if(!best){"
            "var amountY=dir==='up'?-160:dir==='down'?160:0;"
            "var amountX=dir==='left'?-160:dir==='right'?160:0;"
            "window.scrollBy(amountX,amountY);"
            "return 'scroll';"
            "}"
            "try{best.focus();}catch(error){}"
            "try{best.scrollIntoView({block:'nearest',inline:'nearest'});}catch(error){}"
            "return 'focus';"
            "})();", direction];
}

- (void)browserRemoteInputControllerMoveFocusInDirection:(NSString *)direction {
    if (self.webview == nil || direction.length == 0) {
        return;
    }
    [self.webview stringByEvaluatingJavaScriptFromString:[self browserFocusScriptForDirection:direction]];
}

- (void)activateFocusedPageElement {
    if (self.webview == nil) {
        return;
    }
    NSString *pointString = [self.webview stringByEvaluatingJavaScriptFromString:
                             @"(function(){"
                             "var selector='a[href],button,input,textarea,select,summary,[contenteditable=\"true\"],[role=\"button\"],[role=\"link\"],[tabindex]:not([tabindex=\"-1\"])';"
                             "function visible(el){"
                             "if(!el||el.disabled){return false;}"
                             "var style=window.getComputedStyle(el);"
                             "if(style.display==='none'||style.visibility==='hidden'){return false;}"
                             "var r=el.getBoundingClientRect();"
                             "return r.width>=2&&r.height>=2&&r.bottom>0&&r.top<window.innerHeight&&r.right>0&&r.left<window.innerWidth;"
                             "}"
                             "var el=document.activeElement;"
                             "var usable=el&&el!==document.body&&el!==document.documentElement&&visible(el);"
                             "if(!usable){"
                             "var nodes=Array.prototype.filter.call(document.querySelectorAll(selector),visible);"
                             "var cx=window.innerWidth/2,cy=window.innerHeight/2,best=null,bestDistance=Infinity;"
                             "nodes.forEach(function(node){"
                             "var r=node.getBoundingClientRect();"
                             "var distance=Math.hypot((r.left+r.width/2)-cx,(r.top+r.height/2)-cy);"
                             "if(distance<bestDistance){bestDistance=distance;best=node;}"
                             "});"
                             "el=best;"
                             "if(el){try{el.focus();}catch(error){}}"
                             "}"
                             "if(!el){return '';}"
                             "var rect=el.getBoundingClientRect();"
                             "return Math.round(rect.left+rect.width/2)+','+Math.round(rect.top+rect.height/2);"
                             "})();"];
    NSArray<NSString *> *parts = [pointString componentsSeparatedByString:@","];
    if (parts.count != 2) {
        return;
    }
    CGPoint domPoint = CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerActivateFocusedElement {
    [self activateFocusedPageElement];
}

- (NSString *)browserJavaScriptLiteralForText:(NSString *)text {
    NSString *escaped = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (void)browserRemoteInputControllerInsertText:(NSString *)text {
    if (self.webview == nil || text.length == 0) {
        return;
    }
    NSString *literal = [self browserJavaScriptLiteralForText:text];
    NSString *script = [NSString stringWithFormat:
                        @"(function(){"
                        "var el=document.activeElement;"
                        "if(!el||el===document.body||el===document.documentElement){return;}"
                        "var value=%@;"
                        "try{el.dispatchEvent(new KeyboardEvent('keydown',{key:value,bubbles:true}));}catch(error){}"
                        "if(el.isContentEditable){document.execCommand('insertText',false,value);return;}"
                        "var tag=(el.tagName||'').toLowerCase();"
                        "if(tag!=='input'&&tag!=='textarea'){return;}"
                        "var start=el.selectionStart==null?el.value.length:el.selectionStart;"
                        "var end=el.selectionEnd==null?el.value.length:el.selectionEnd;"
                        "el.value=el.value.slice(0,start)+value+el.value.slice(end);"
                        "var caret=start+value.length;"
                        "try{el.selectionStart=el.selectionEnd=caret;}catch(error){}"
                        "el.dispatchEvent(new Event('input',{bubbles:true}));"
                        "})();", literal];
    [self.webview stringByEvaluatingJavaScriptFromString:script];
}

- (void)browserRemoteInputControllerDeleteBackward {
    if (self.webview == nil) {
        return;
    }
    [self.webview stringByEvaluatingJavaScriptFromString:
     @"(function(){"
     "var el=document.activeElement;"
     "if(!el||el===document.body||el===document.documentElement){return;}"
     "try{el.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true}));}catch(error){}"
     "if(el.isContentEditable){document.execCommand('delete',false);return;}"
     "var tag=(el.tagName||'').toLowerCase();"
     "if(tag!=='input'&&tag!=='textarea'){return;}"
     "var start=el.selectionStart==null?el.value.length:el.selectionStart;"
     "var end=el.selectionEnd==null?el.value.length:el.selectionEnd;"
     "if(start===end&&start>0){start-=1;}"
     "el.value=el.value.slice(0,start)+el.value.slice(end);"
     "try{el.selectionStart=el.selectionEnd=start;}catch(error){}"
     "el.dispatchEvent(new Event('input',{bubbles:true}));"
     "})();"];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (webView == self.webview) {
        [self syncPageVideoState];
    }
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesBegan:presses withEvent:event]) {
        return;
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesCancelled:presses withEvent:event];
    [super pressesCancelled:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
