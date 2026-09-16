#import "ATMAppDelegate.h"
#import "ATMViewControllers.h"
#import "ATMLocalization.h"

@implementation ATMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    ATMInstallLocalization();
    UIColor *accent = [UIColor colorWithRed:0.08 green:0.43 blue:0.94 alpha:1.0];
    UINavigationBarAppearance *navigationAppearance = [UINavigationBarAppearance new];
    [navigationAppearance configureWithDefaultBackground];
    UINavigationBar.appearance.standardAppearance = navigationAppearance;
    UINavigationBar.appearance.scrollEdgeAppearance = navigationAppearance;
    UITabBarAppearance *tabAppearance = [UITabBarAppearance new];
    [tabAppearance configureWithDefaultBackground];
    UITabBar.appearance.standardAppearance = tabAppearance;
    UITabBar.appearance.scrollEdgeAppearance = tabAppearance;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = accent;
    self.window.rootViewController = ATMCreateRootController();
    self.window.semanticContentAttribute = ATMIsArabicLanguage() ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    dispatch_async(dispatch_get_main_queue(), ^{ ATMHandlePendingImport(self.window.rootViewController); });
}

@end
