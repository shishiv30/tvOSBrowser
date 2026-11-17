//
//  AppDelegate.h
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

/// Caught NSException. Reloads the front page, or leaves the app if that just failed.
void BrowserRecoverFromException(NSException *exception);

@end

