#import "ATMAppDelegate.h"
#import "ATMViewControllers.h"

@implementation ATMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = [UIColor colorWithRed:0.12 green:0.48 blue:0.95 alpha:1.0];
    self.window.rootViewController = ATMCreateRootController();
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    dispatch_async(dispatch_get_main_queue(), ^{ ATMHandlePendingImport(self.window.rootViewController); });
}

@end
