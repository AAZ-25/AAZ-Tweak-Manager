#import "ATMAppDelegate.h"
#import "ATMViewControllers.h"
#import "ATMLocalization.h"

static NSString *const ATMExperimentalNoticeLastBuildKey = @"ATMExperimentalNoticeLastBuild";

@interface ATMAppDelegate ()
@property(nonatomic, assign) BOOL experimentalNoticeVisible;
@end

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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self presentExperimentalNoticeIfNeeded]) ATMHandlePendingImport(self.window.rootViewController);
    });
}

- (BOOL)presentExperimentalNoticeIfNeeded {
    if (self.experimentalNoticeVisible) return YES;
    NSString *build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown";
    if ([[NSUserDefaults.standardUserDefaults stringForKey:ATMExperimentalNoticeLastBuildKey] isEqualToString:build]) return NO;

    self.experimentalNoticeVisible = YES;
    NSString *message = [NSString stringWithLocalizedFormat:@"AAZ Tweak Manager is experimental. If you find a problem, contact the developer on X: %@", ATMLTRIsolatedString(@"@_kkk2")];
    UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"Experimental Version" message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    void (^acceptNotice)(BOOL) = ^(BOOL openDeveloper) {
        ATMAppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        [NSUserDefaults.standardUserDefaults setObject:build forKey:ATMExperimentalNoticeLastBuildKey];
        strongSelf.experimentalNoticeVisible = NO;
        if (openDeveloper) {
            NSURL *url = [NSURL URLWithString:@"https://x.com/_kkk2"];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        } else {
            ATMHandlePendingImport(strongSelf.window.rootViewController);
        }
    };
    [notice addAction:[UIAlertAction actionWithTitle:@"Contact Developer" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { acceptNotice(YES); }]];
    [notice addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { acceptNotice(NO); }]];
    [self.window.rootViewController presentViewController:notice animated:YES completion:nil];
    return YES;
}

@end
