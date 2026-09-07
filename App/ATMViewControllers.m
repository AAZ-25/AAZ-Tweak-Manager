#import "ATMViewControllers.h"
#import "ATMCore.h"
#import "ATMBackupManager.h"

static NSString *const ATMDataChangedNotification = @"ATMDataChangedNotification";
static NSString *const ATMShowExcludedKey = @"ATMShowExcludedPackages";

@interface ATMAppModel : NSObject
@property(nonatomic, strong) ATMEnvironment *environment;
@property(nonatomic, strong) ATMPackageScanner *scanner;
@property(nonatomic, strong) ATMPersonalLedger *ledger;
@property(nonatomic, strong) ATMBackupManager *backupManager;
@property(nonatomic, copy) NSArray<ATMPackageRecord *> *packages;
@property(nonatomic, copy) NSArray<ATMSourceRecord *> *sources;
@property(nonatomic, strong, nullable) NSError *scanError;
+ (instancetype)shared;
- (void)refresh;
@end

@implementation ATMAppModel
+ (instancetype)shared {
    static ATMAppModel *model; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ model = [ATMAppModel new]; });
    return model;
}
- (instancetype)init {
    if ((self = [super init])) {
        _environment = ATMEnvironment.currentEnvironment;
        _scanner = [[ATMPackageScanner alloc] initWithEnvironment:_environment];
        _ledger = [ATMPersonalLedger new];
        _backupManager = [[ATMBackupManager alloc] initWithEnvironment:_environment ledger:_ledger];
        [self refresh];
    }
    return self;
}
- (void)refresh {
    NSError *error = nil;
    self.packages = [self.scanner scanInstalledPackages:&error];
    self.sources = [self.scanner scanSources:nil];
    self.scanError = error;
    [self.ledger seedIfNeededWithCandidates:self.packages];
    [self.ledger reconcileInstalledPackages:self.packages];
    [NSNotificationCenter.defaultCenter postNotificationName:ATMDataChangedNotification object:self];
}
@end

static NSString *ATMDateDescription(ATMPackageRecord *record) {
    NSDate *date = record.installedAt ?: [ATMAppModel.shared.ledger firstSeenDateForPackageID:record.packageID];
    if (!date) return @"Date unknown";
    static NSDateFormatter *formatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSDateFormatter new]; formatter.dateStyle = NSDateFormatterMediumStyle; formatter.timeStyle = NSDateFormatterShortStyle; });
    NSString *label = record.installedAt ? @"Install record" : @"First seen";
    return [NSString stringWithFormat:@"%@ %@", label, [formatter stringFromDate:date]];
}

static void ATMShowError(UIViewController *controller, NSString *title, NSError *error) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:error.localizedDescription ?: @"Unknown error" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@interface ATMPackageSwitch : UISwitch
@property(nonatomic, copy) NSString *packageID;
@end
@implementation ATMPackageSwitch @end

@interface ATMMyTweaksController : UITableViewController
@property(nonatomic, copy) NSArray<ATMPackageRecord *> *visiblePackages;
@end

@implementation ATMMyTweaksController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"My Tweaks";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Backup" style:UIBarButtonItemStyleDone target:self action:@selector(createBackup)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshData) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:ATMDataChangedNotification object:nil];
    [self reloadData];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refreshData { [[ATMAppModel shared] refresh]; [self.refreshControl endRefreshing]; }
- (void)reloadData {
    ATMAppModel *model = ATMAppModel.shared;
    BOOL showExcluded = [NSUserDefaults.standardUserDefaults boolForKey:ATMShowExcludedKey];
    if (showExcluded) self.visiblePackages = model.packages;
    else self.visiblePackages = [model.packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate || [model.ledger isSelectedPackageID:record.packageID]; }]];
    NSUInteger personalCount = [[model.packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate; }]] count];
    [self.tableView reloadData];
    self.navigationItem.prompt = model.environment.supportedRootless && !model.scanError ? [NSString stringWithFormat:@"%lu personal • %lu installed", (unsigned long)personalCount, (unsigned long)model.packages.count] : @"Rootless package database unavailable";
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.visiblePackages.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; (void)section; return @"Selected packages are included in the next backup"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"The first scan is inferred from APT state and protected bootstrap rules. Review the selection once; later choices are saved explicitly.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.visiblePackages.count) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = ATMAppModel.shared.scanError ? @"Package database unavailable" : @"No personal packages inferred";
        empty.detailTextLabel.text = ATMAppModel.shared.scanError.localizedDescription ?: [NSString stringWithFormat:@"%lu installed packages were read. Turn on Show Excluded Packages in Settings to review the classification.", (unsigned long)ATMAppModel.shared.packages.count];
        empty.selectionStyle = UITableViewCellSelectionStyleNone; return empty;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"package"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"package"];
    ATMPackageRecord *record = self.visiblePackages[indexPath.row];
    cell.textLabel.text = record.name;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@\n%@", record.packageID, record.version, ATMDateDescription(record)];
    ATMPackageSwitch *toggle = [ATMPackageSwitch new]; toggle.packageID = record.packageID;
    toggle.on = [ATMAppModel.shared.ledger isSelectedPackageID:record.packageID];
    [toggle addTarget:self action:@selector(selectionChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)selectionChanged:(ATMPackageSwitch *)sender {
    [ATMAppModel.shared.ledger setSelected:sender.isOn packageID:sender.packageID];
    [ATMAppModel.shared.ledger recordEvent:sender.isOn ? @"package-selected" : @"package-unselected" packageID:sender.packageID details:nil];
}
- (void)createBackup {
    if (!ATMAppModel.shared.environment.supportedRootless || ATMAppModel.shared.scanError || !ATMAppModel.shared.packages.count) { ATMShowError(self, @"Backup unavailable", ATMAppModel.shared.scanError ?: [NSError errorWithDomain:@"ATM" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No installed package inventory is available. An empty backup will not be created."}]); return; }
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *url = [ATMAppModel.shared.backupManager createBackupWithPackages:ATMAppModel.shared.packages sources:ATMAppModel.shared.sources error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (!url) { ATMShowError(self, @"Backup failed", error); return; }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup created" message:@"The archive contains selected package metadata, sanitized sources, and exact cached DEBs when available. Repository credentials are never included." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self shareURL:url sourceView:self.navigationController.navigationBar]; }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}
- (void)shareURL:(NSURL *)url sourceView:(UIView *)sourceView {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = sourceView;
    activity.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}
@end

@interface ATMBackupsController : UITableViewController
@property(nonatomic, copy) NSArray<NSURL *> *backups;
@end

@implementation ATMBackupsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Backups";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadData)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:ATMDataChangedNotification object:nil]; [self reloadData];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reloadData { self.backups = ATMAppModel.shared.backupManager.availableBackups; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.backups.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return @"This beta validates and previews restoration. It does not execute package installation or removal."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"];
    if (!self.backups.count) { cell.textLabel.text = @"No backups yet"; cell.detailTextLabel.text = @"Create one from My Tweaks."; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
    NSURL *url = self.backups[indexPath.row]; NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url error:nil];
    cell.textLabel.text = url.lastPathComponent;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ packages • %@ sources", @([manifest[@"packages"] count]), @([manifest[@"sources"] count])];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (!self.backups.count) return;
    NSError *error = nil; NSDictionary *preview = [ATMAppModel.shared.backupManager restorePreviewForBackup:self.backups[indexPath.row] installedPackages:ATMAppModel.shared.packages error:&error];
    if (!preview.count) { ATMShowError(self, @"Invalid backup", error); return; }
    NSString *message = [NSString stringWithFormat:@"Missing: %@\nDifferent version: %@\nAlready installed: %@\nUnavailable DEBs: %@\nSources: %@\n\nNo changes will be made by this beta.", preview[@"missing"], preview[@"differentVersion"], preview[@"alreadyInstalled"], preview[@"packagePayloadUnavailable"], preview[@"sourceCount"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Preview" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share Backup" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self shareURL:self.backups[indexPath.row]]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)shareURL:(NSURL *)url {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view; activity.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.backups.count) return nil;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        NSURL *url = self.backups[indexPath.row];
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Backup?" message:url.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { completionHandler(NO); }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { NSError *error = nil; BOOL ok = [NSFileManager.defaultManager removeItemAtURL:url error:&error]; if (ok) [ATMAppModel.shared.ledger recordEvent:@"backup-deleted" packageID:nil details:@{ @"file": url.lastPathComponent }]; completionHandler(ok); [self reloadData]; if (!ok) ATMShowError(self, @"Delete failed", error); }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[delete]]; configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
@end

@interface ATMSourcesController : UITableViewController @end
@implementation ATMSourcesController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Sources"; self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:ATMAppModel.shared action:@selector(refresh)]; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:ATMDataChangedNotification object:nil]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reload { [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.sources.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return @"Source definitions are backed up after credential-bearing URL values are redacted. A paid or private repository may require signing in again."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"source"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];
    if (!ATMAppModel.shared.sources.count) { cell.textLabel.text = @"No readable sources"; cell.detailTextLabel.text = @"Refresh after adding a source in Sileo or Zebra."; return cell; }
    ATMSourceRecord *source = ATMAppModel.shared.sources[indexPath.row]; cell.textLabel.text = source.relativePath;
    __block NSString *summary = @"";
    [source.sanitizedContents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) { NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (trim.length && ![trim hasPrefix:@"#"]) { summary = trim; *stop = YES; } }];
    if (source.credentialsRedacted) summary = @"Credentials detected and redacted from exports";
    else if (!summary.length) summary = source.enabled ? @"Enabled" : @"Disabled";
    cell.detailTextLabel.text = summary; cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = [UIImage systemImageNamed:source.credentialsRedacted ? @"lock.shield" : @"shippingbox"]; return cell;
}
@end

@interface ATMHistoryController : UITableViewController @end
@implementation ATMHistoryController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"History"; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.ledger.history.count ?: 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"history"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"history"];
    NSArray *history = ATMAppModel.shared.ledger.history;
    if (!history.count) { cell.textLabel.text = @"No manager history yet"; cell.detailTextLabel.text = @"Package dates from dpkg logs appear in My Tweaks."; return cell; }
    NSDictionary *item = history[history.count - 1 - indexPath.row]; cell.textLabel.text = item[@"event"] ?: @"Event";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", item[@"timestamp"] ?: @"", item[@"packageID"] ? [NSString stringWithFormat:@" • %@", item[@"packageID"]] : @""]; return cell;
}
@end

@interface ATMSettingsController : UITableViewController @end
@implementation ATMSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Settings"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 1 : 3; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Inventory" : @"Safety"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section == 1 ? @"AAZ Tweak Manager never transmits package, source, device, or account data and this beta does not execute restore transactions." : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Show Excluded Packages"; cell.detailTextLabel.text = @"Review system/dependency classification without selecting them automatically.";
        UISwitch *toggle = [UISwitch new]; toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:ATMShowExcludedKey]; [toggle addTarget:self action:@selector(showExcludedChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else {
        NSArray *titles = @[@"Rootless only", @"Credentials excluded", @"Restore preview only"];
        NSArray *details = @[@"Reads the /var/jb APT and dpkg state.", @"auth.conf and embedded URL credentials are not exported.", @"No package installation, removal, or source write occurs."];
        cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row]; cell.detailTextLabel.numberOfLines = 2; cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield"];
    }
    return cell;
}
- (void)showExcludedChanged:(UISwitch *)sender { [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:ATMShowExcludedKey]; [NSNotificationCenter.defaultCenter postNotificationName:ATMDataChangedNotification object:nil]; }
@end

static UINavigationController *ATMNavigation(UIViewController *controller, NSString *imageName) {
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.navigationBar.prefersLargeTitles = YES; controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    navigation.tabBarItem.title = controller.tabBarItem.title;
    navigation.tabBarItem.image = [UIImage systemImageNamed:imageName]; return navigation;
}

UIViewController *ATMCreateRootController(void) {
    (void)ATMAppModel.shared;
    UITabBarController *tabs = [UITabBarController new];
    UIViewController *tweaks = [ATMMyTweaksController new]; tweaks.tabBarItem.title = @"My Tweaks";
    UIViewController *backups = [ATMBackupsController new]; backups.tabBarItem.title = @"Backups";
    UIViewController *sources = [ATMSourcesController new]; sources.tabBarItem.title = @"Sources";
    UIViewController *history = [ATMHistoryController new]; history.tabBarItem.title = @"History";
    UIViewController *settings = [ATMSettingsController new]; settings.tabBarItem.title = @"Settings";
    tabs.viewControllers = @[ATMNavigation(tweaks, @"shippingbox.fill"), ATMNavigation(backups, @"externaldrive.fill"), ATMNavigation(sources, @"link"), ATMNavigation(history, @"clock.arrow.circlepath"), ATMNavigation(settings, @"gearshape.fill")];
    return tabs;
}
