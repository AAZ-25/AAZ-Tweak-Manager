#import "ATMAppDelegate.h"
#import "ATMViewControllers.h"

@implementation ATMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = [UIColor colorWithRed:0.12 green:0.48 blue:0.95 alpha:1.0];
    self.window.rootViewController = ATMCreateRootController();
    [self.window makeKeyAndVisible];
    NSURL *incomingURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (incomingURL) ATMHandleBackupURL(self.window.rootViewController, incomingURL);
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    (void)application;
    (void)options;
    return ATMHandleBackupURL(self.window.rootViewController, url);
}

@end
