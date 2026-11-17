//
//  AppDelegate.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"
#import "ViewController.h"

@interface AppDelegate ()
- (BOOL)reloadFrontPageAfterException;
@end

static NSTimeInterval sBrowserLastRecoveryTime = 0;

static void BrowserUncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[Browser] uncaught %@: %@\n%@", exception.name, exception.reason, exception.callStackSymbols);
    exit(EXIT_SUCCESS);
}

void BrowserRecoverFromException(NSException *exception) {
    NSLog(@"[Browser] caught %@: %@\n%@", exception.name, exception.reason, exception.callStackSymbols);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ((now - sBrowserLastRecoveryTime) < 2.0) {
        NSLog(@"[Browser] exception repeated, leaving the app");
        exit(EXIT_SUCCESS);
    }
    sBrowserLastRecoveryTime = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
        if (![delegate isKindOfClass:[AppDelegate class]] || ![delegate reloadFrontPageAfterException]) {
            exit(EXIT_SUCCESS);
        }
    });
}

@implementation AppDelegate

- (BOOL)reloadFrontPageAfterException {
    ViewController *controller = (ViewController *)self.window.rootViewController;
    if (![controller isKindOfClass:[ViewController class]]) {
        return NO;
    }
    [controller reloadAfterException];
    return YES;
}

- (void)restoreCookiesFromDefaults {
    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }

    [BrowserWebView restoreCookiesFromData:cookieData];
}

- (void)saveCookiesToDefaults {
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSSetUncaughtExceptionHandler(&BrowserUncaughtExceptionHandler);
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MobileMode"]) {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.mobileUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.desktopUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [self restoreCookiesFromDefaults];
    [self installDefaultFavorites];
	return YES;
}

- (NSString *)favoriteHostForURLString:(NSString *)URLString {
    NSString *host = [NSURL URLWithString:URLString].host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host ?: @"";
}

- (void)installDefaultFavorites {
    NSArray<NSArray<NSString *> *> *defaultFavorites = @[
        @[@"https://www.kubb.tv", @"kubb"],
        @[@"https://www.suno.com", @"suno"],
        @[@"https://magewords.com", @"magewords"],
        @[@"https://www.rednote.com", @"rednote"],
        @[@"https://www.tiktok.com", @"tiktok"],
        @[@"tvbrowser://gamepad-test", @"Gamepad Test"],
    ];
    NSMutableArray *existingFavorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"] mutableCopy];
    if (existingFavorites == nil) {
        existingFavorites = [NSMutableArray array];
    }

    // Former defaults: dropped from an existing install so the replacement does not sit next to them.
    NSSet<NSString *> *retiredDefaultHosts = [NSSet setWithObjects:@"iyf.tv", @"douyin.com", @"bilibili.com", @"youtube.com", @"youtu.be", nil];

    NSMutableArray *favorites = [NSMutableArray array];
    NSMutableSet<NSString *> *defaultHosts = [NSMutableSet set];
    for (NSArray<NSString *> *entry in defaultFavorites) {
        NSString *host = [self favoriteHostForURLString:entry[0]];
        if (host.length == 0) {
            continue;
        }
        [defaultHosts addObject:host];
        NSArray *savedEntry = entry;
        for (NSArray *existingEntry in existingFavorites) {
            NSString *existingURL = existingEntry.count > 0 ? existingEntry[0] : @"";
            if ([[self favoriteHostForURLString:existingURL] isEqualToString:host]) {
                savedEntry = entry;
                break;
            }
        }
        [favorites addObject:savedEntry];
    }

    for (NSArray *existingEntry in existingFavorites) {
        NSString *existingURL = existingEntry.count > 0 ? existingEntry[0] : @"";
        NSString *host = [self favoriteHostForURLString:existingURL];
        if (host.length == 0 || [defaultHosts containsObject:host] || [retiredDefaultHosts containsObject:host]) {
            continue;
        }
        [favorites addObject:existingEntry];
    }

    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:@"FAVORITES"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [self saveCookiesToDefaults];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [self saveCookiesToDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self restoreCookiesFromDefaults];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self restoreCookiesFromDefaults];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
