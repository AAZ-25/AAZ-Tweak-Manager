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

static NSDate *ATMDateFromISO(NSString *stamp) {
    if (![stamp isKindOfClass:NSString.class] || !stamp.length) return nil;
    static NSISO8601DateFormatter *formatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter dateFromString:stamp];
}

static NSString *ATMShortDateTime(NSDate *date) {
    if (!date) return @"Date unknown";
    static NSDateFormatter *formatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSDateFormatter new]; formatter.dateStyle = NSDateFormatterMediumStyle; formatter.timeStyle = NSDateFormatterShortStyle; });
    return [formatter stringFromDate:date];
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

@interface ATMMyTweaksController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<ATMPackageRecord *> *visiblePackages;
@property(nonatomic, copy) NSSet<NSString *> *selectedPackageIDs;
@property(nonatomic, strong) UISearchController *packageSearchController;
@property(nonatomic, strong) UIBarButtonItem *selectionButton;
@end

@implementation ATMMyTweaksController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"My Tweaks";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Backup" style:UIBarButtonItemStyleDone target:self action:@selector(createBackup)];
    self.selectionButton = [[UIBarButtonItem alloc] initWithTitle:@"Select" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.leftBarButtonItem = self.selectionButton;
    self.packageSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.packageSearchController.searchResultsUpdater = self;
    self.packageSearchController.obscuresBackgroundDuringPresentation = NO;
    self.packageSearchController.searchBar.placeholder = @"Search packages";
    self.navigationItem.searchController = self.packageSearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshData) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:ATMDataChangedNotification object:nil];
    [self reloadData];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refreshData { [[ATMAppModel shared] refresh]; [self.refreshControl endRefreshing]; }
- (void)reloadData {
    ATMAppModel *model = ATMAppModel.shared;
    self.selectedPackageIDs = model.ledger.selectedPackageIDs;
    BOOL showExcluded = [NSUserDefaults.standardUserDefaults boolForKey:ATMShowExcludedKey];
    NSArray<ATMPackageRecord *> *packages = showExcluded ? model.packages : [model.packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate || [self.selectedPackageIDs containsObject:record.packageID]; }]];
    NSString *query = [self.packageSearchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length) packages = [packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) {
        (void)bindings;
        return [record.name localizedCaseInsensitiveContainsString:query] || [record.packageID localizedCaseInsensitiveContainsString:query];
    }]];
    self.visiblePackages = [packages sortedArrayUsingComparator:^NSComparisonResult(ATMPackageRecord *a, ATMPackageRecord *b) {
        NSComparisonResult nameResult = [a.name localizedCaseInsensitiveCompare:b.name];
        return nameResult == NSOrderedSame ? [a.packageID localizedCaseInsensitiveCompare:b.packageID] : nameResult;
    }];
    NSUInteger personalCount = [[model.packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate; }]] count];
    [self.tableView reloadData];
    self.navigationItem.prompt = model.environment.supportedRootless && !model.scanError ? [NSString stringWithFormat:@"%lu personal • %lu installed", (unsigned long)personalCount, (unsigned long)model.packages.count] : @"Rootless package database unavailable";
    [self configureSelectionMenu];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { (void)searchController; [self reloadData]; }
- (NSUInteger)selectedVisibleCount {
    NSUInteger count = 0;
    for (ATMPackageRecord *record in self.visiblePackages) if ([self.selectedPackageIDs containsObject:record.packageID]) count++;
    return count;
}
- (void)configureSelectionMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *selectAll = [UIAction actionWithTitle:@"Select All" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf applySelection:YES]; }];
    UIAction *unselectAll = [UIAction actionWithTitle:@"Unselect All" image:[UIImage systemImageNamed:@"circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf confirmUnselectAll]; }];
    NSUInteger selectedCount = self.selectedVisibleCount;
    if (!self.visiblePackages.count || selectedCount == self.visiblePackages.count) selectAll.attributes = UIMenuElementAttributesDisabled;
    if (!selectedCount) unselectAll.attributes = UIMenuElementAttributesDisabled;
    unselectAll.attributes |= UIMenuElementAttributesDestructive;
    self.selectionButton.menu = [UIMenu menuWithTitle:@"Shown Packages" children:@[selectAll, unselectAll]];
}
- (void)applySelection:(BOOL)selected {
    NSMutableArray<NSString *> *packageIDs = [NSMutableArray array];
    for (ATMPackageRecord *record in self.visiblePackages) {
        if ([self.selectedPackageIDs containsObject:record.packageID] != selected) [packageIDs addObject:record.packageID];
    }
    if (!packageIDs.count) return;
    [ATMAppModel.shared.ledger setSelected:selected forPackageIDs:packageIDs];
    [ATMAppModel.shared.ledger recordEvent:selected ? @"packages-selected" : @"packages-unselected" packageID:nil details:@{ @"count": @(packageIDs.count) }];
    [self reloadData];
}
- (void)confirmUnselectAll {
    NSUInteger count = self.selectedVisibleCount;
    if (!count) return;
    NSString *message = [NSString stringWithFormat:@"This will remove %lu shown packages from the next backup. You can select them again at any time.", (unsigned long)count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unselect All Shown?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unselect All" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { [self applySelection:NO]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.visiblePackages.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; (void)section; return [NSString stringWithFormat:@"%lu selected • %lu shown", (unsigned long)self.selectedVisibleCount, (unsigned long)self.visiblePackages.count]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"Search and Show Excluded Packages control which rows are shown. Select All and Unselect All apply only to the shown rows; choices are saved immediately.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.visiblePackages.count) {
        UITableViewCell *empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        BOOL searching = self.packageSearchController.searchBar.text.length > 0;
        empty.textLabel.text = ATMAppModel.shared.scanError ? @"Package database unavailable" : (searching ? @"No matching packages" : @"No personal packages inferred");
        empty.detailTextLabel.text = ATMAppModel.shared.scanError.localizedDescription ?: (searching ? @"Try another name or package identifier." : [NSString stringWithFormat:@"%lu installed packages were read. Turn on Show Excluded Packages in Settings to review the classification.", (unsigned long)ATMAppModel.shared.packages.count]);
        empty.selectionStyle = UITableViewCellSelectionStyleNone; return empty;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"package"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"package"];
    ATMPackageRecord *record = self.visiblePackages[indexPath.row];
    cell.textLabel.text = record.name;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@\n%@", record.packageID, record.version, ATMDateDescription(record)];
    ATMPackageSwitch *toggle = [ATMPackageSwitch new]; toggle.packageID = record.packageID;
    toggle.on = [self.selectedPackageIDs containsObject:record.packageID];
    [toggle addTarget:self action:@selector(selectionChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)selectionChanged:(ATMPackageSwitch *)sender {
    [ATMAppModel.shared.ledger setSelected:sender.isOn packageID:sender.packageID];
    [ATMAppModel.shared.ledger recordEvent:sender.isOn ? @"package-selected" : @"package-unselected" packageID:sender.packageID details:nil];
    [self reloadData];
}
- (void)createBackup {
    if (!ATMAppModel.shared.environment.supportedRootless || ATMAppModel.shared.scanError || !ATMAppModel.shared.packages.count) { ATMShowError(self, @"Backup unavailable", ATMAppModel.shared.scanError ?: [NSError errorWithDomain:@"ATM" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No installed package inventory is available. An empty backup will not be created."}]); return; }
    NSSet<NSString *> *selected = ATMAppModel.shared.ledger.selectedPackageIDs;
    NSUInteger selectedInstalledCount = [[ATMAppModel.shared.packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return [selected containsObject:record.packageID]; }]] count];
    if (!selectedInstalledCount) { ATMShowError(self, @"Nothing selected", [NSError errorWithDomain:@"ATM" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Select at least one installed package before creating a backup."}]); return; }
    NSUInteger sourceCount = ATMAppModel.shared.sources.count;
    NSString *message = [NSString stringWithFormat:@"%lu selected package%@ and %lu sanitized source%@ will be included. Exact cached DEBs are added when available.", (unsigned long)selectedInstalledCount, selectedInstalledCount == 1 ? @"" : @"s", (unsigned long)sourceCount, sourceCount == 1 ? @"" : @"s"];
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"Create Backup?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Create Backup" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self performBackup]; }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}
- (void)performBackup {
    UIBarButtonItem *backupButton = self.navigationItem.rightBarButtonItem;
    backupButton.title = @"Creating…";
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.selectionButton.enabled = NO;
    self.packageSearchController.searchBar.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *url = [ATMAppModel.shared.backupManager createBackupWithPackages:ATMAppModel.shared.packages sources:ATMAppModel.shared.sources error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            backupButton.title = @"Backup";
            backupButton.enabled = YES;
            self.selectionButton.enabled = YES;
            self.packageSearchController.searchBar.userInteractionEnabled = YES;
            if (!url) { ATMShowError(self, @"Backup failed", error); return; }
            NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url error:nil];
            NSArray *packages = [manifest[@"packages"] isKindOfClass:NSArray.class] ? manifest[@"packages"] : @[];
            NSArray *sources = [manifest[@"sources"] isKindOfClass:NSArray.class] ? manifest[@"sources"] : @[];
            NSUInteger cachedCount = [[packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count];
            NSString *successMessage = [NSString stringWithFormat:@"%lu packages • %lu sources • %lu cached DEBs\n\nCredentials are never included.", (unsigned long)packages.count, (unsigned long)sources.count, (unsigned long)cachedCount];
            [NSNotificationCenter.defaultCenter postNotificationName:ATMDataChangedNotification object:nil];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Created" message:successMessage preferredStyle:UIAlertControllerStyleAlert];
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
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (void)reloadData { self.backups = ATMAppModel.shared.backupManager.availableBackups; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.backups.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; (void)section; return self.backups.count ? [NSString stringWithFormat:@"%lu saved backup%@", (unsigned long)self.backups.count, self.backups.count == 1 ? @"" : @"s"] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return @"Open a backup for a compatibility summary or to share it. Restore execution is not included in this beta."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"];
    if (!self.backups.count) { cell.textLabel.text = @"No Backups Yet"; cell.detailTextLabel.text = @"Select packages in My Tweaks, then tap Backup."; cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.badge.plus"]; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
    NSURL *url = self.backups[indexPath.row]; NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url error:nil];
    if (!manifest) {
        cell.textLabel.text = @"Backup Needs Attention";
        cell.detailTextLabel.text = @"The manifest could not be validated.";
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        cell.imageView.tintColor = UIColor.systemOrangeColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSArray *packages = [manifest[@"packages"] isKindOfClass:NSArray.class] ? manifest[@"packages"] : @[];
    NSArray *sources = [manifest[@"sources"] isKindOfClass:NSArray.class] ? manifest[@"sources"] : @[];
    NSUInteger cachedCount = [[packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count];
    NSDate *created = ATMDateFromISO(manifest[@"createdAt"]);
    if (!created) [url getResourceValue:&created forKey:NSURLContentModificationDateKey error:nil];
    cell.textLabel.text = [NSString stringWithFormat:@"Backup — %@", ATMShortDateTime(created)];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu packages • %lu sources • %lu cached DEBs", (unsigned long)packages.count, (unsigned long)sources.count, (unsigned long)cachedCount];
    cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield.fill"];
    cell.imageView.tintColor = UIColor.systemGreenColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (!self.backups.count) return;
    NSError *error = nil; NSDictionary *preview = [ATMAppModel.shared.backupManager restorePreviewForBackup:self.backups[indexPath.row] installedPackages:ATMAppModel.shared.packages error:&error];
    if (!preview.count) { ATMShowError(self, @"Invalid backup", error); return; }
    NSUInteger missing = [preview[@"missing"] count];
    NSUInteger different = [preview[@"differentVersion"] count];
    NSUInteger installed = [preview[@"alreadyInstalled"] count];
    NSUInteger unavailable = [preview[@"packagePayloadUnavailable"] count];
    NSString *message = [NSString stringWithFormat:@"Already installed: %lu\nMissing: %lu\nDifferent version: %lu\nCached DEB unavailable: %lu\nSanitized sources: %@\n\nThis is a read-only compatibility preview. No packages or sources will be changed.", (unsigned long)installed, (unsigned long)missing, (unsigned long)different, (unsigned long)unavailable, preview[@"sourceCount"] ?: @0];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Summary" message:message preferredStyle:UIAlertControllerStyleAlert];
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
        NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url error:nil];
        NSString *message = [NSString stringWithFormat:@"This permanently removes the backup containing %@ package%@ from this device.", @([manifest[@"packages"] count]), [manifest[@"packages"] count] == 1 ? @"" : @"s"];
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Backup?" message:message preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { completionHandler(NO); }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { NSError *error = nil; BOOL ok = [NSFileManager.defaultManager removeItemAtURL:url error:&error]; if (ok) [ATMAppModel.shared.ledger recordEvent:@"backup-deleted" packageID:nil details:nil]; completionHandler(ok); [self reloadData]; if (!ok) ATMShowError(self, @"Delete failed", error); }]];
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

@interface ATMHistoryController : UITableViewController
@property(nonatomic, strong) UISegmentedControl *filterControl;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@end
@implementation ATMHistoryController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"History";
    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Packages", @"Backups"]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(reloadHistory) forControlEvents:UIControlEventValueChanged];
    UIView *filterHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    self.filterControl.frame = CGRectMake(16, 10, MAX(0, filterHeader.bounds.size.width - 32), 36);
    self.filterControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [filterHeader addSubview:self.filterControl];
    self.tableView.tableHeaderView = filterHeader;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearHistory)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadHistory]; }
- (BOOL)isBackupEvent:(NSString *)event { return [event hasPrefix:@"backup-"]; }
- (void)reloadHistory {
    NSArray<NSDictionary *> *history = ATMAppModel.shared.ledger.history;
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *item in history.reverseObjectEnumerator) {
        NSString *event = [item[@"event"] isKindOfClass:NSString.class] ? item[@"event"] : @"";
        BOOL backupEvent = [self isBackupEvent:event];
        if (self.filterControl.selectedSegmentIndex == 1 && backupEvent) continue;
        if (self.filterControl.selectedSegmentIndex == 2 && !backupEvent) continue;
        [filtered addObject:item];
    }
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    NSMutableArray *currentItems = nil; NSString *currentKey = nil;
    static NSDateFormatter *dayFormatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dayFormatter = [NSDateFormatter new]; dayFormatter.dateStyle = NSDateFormatterMediumStyle; dayFormatter.timeStyle = NSDateFormatterNoStyle; });
    for (NSDictionary *item in filtered) {
        NSDate *date = ATMDateFromISO(item[@"timestamp"]);
        NSString *key = date ? [dayFormatter stringFromDate:date] : @"Date Unknown";
        NSString *title = key;
        if (date && [calendar isDateInToday:date]) title = @"Today";
        else if (date && [calendar isDateInYesterday:date]) title = @"Yesterday";
        if (![key isEqualToString:currentKey]) {
            currentKey = key; currentItems = [NSMutableArray array];
            [sections addObject:@{ @"title": title, @"items": currentItems }];
        }
        [currentItems addObject:item];
    }
    self.sections = sections;
    self.navigationItem.rightBarButtonItem.enabled = history.count > 0;
    [self.tableView reloadData];
}
- (void)confirmClearHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear History?" message:@"This removes the local activity timeline. Your package selections and backup files will not be changed." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear History" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (![ATMAppModel.shared.ledger clearHistory:&error]) { ATMShowError(self, @"History could not be cleared", error); return; }
        [self reloadHistory];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count ?: 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return self.sections.count ? [self.sections[section][@"items"] count] : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return self.sections.count ? self.sections[section][@"title"] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section != MAX(0, (NSInteger)self.sections.count - 1)) return nil;
    return @"History is stored only on this device. Clearing it does not change selections or delete backup files.";
}
- (NSString *)packageNameForID:(NSString *)packageID {
    if (![packageID isKindOfClass:NSString.class] || !packageID.length) return nil;
    for (ATMPackageRecord *record in ATMAppModel.shared.packages) if ([record.packageID isEqualToString:packageID]) return record.name.length ? record.name : packageID;
    return packageID;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"history"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"history"];
    cell.imageView.tintColor = UIColor.systemBlueColor;
    if (!self.sections.count) {
        cell.textLabel.text = self.filterControl.selectedSegmentIndex ? @"No Matching Activity" : @"No Activity Yet";
        cell.detailTextLabel.text = self.filterControl.selectedSegmentIndex ? @"Choose another filter to view activity." : @"Selections, package changes, and backups will appear here.";
        cell.imageView.image = [UIImage systemImageNamed:@"clock"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    NSString *event = [item[@"event"] isKindOfClass:NSString.class] ? item[@"event"] : @"";
    NSDictionary *details = [item[@"details"] isKindOfClass:NSDictionary.class] ? item[@"details"] : @{};
    NSString *packageName = [self packageNameForID:item[@"packageID"]];
    NSString *title = @"Activity"; NSString *summary = @""; NSString *symbol = @"clock.arrow.circlepath";
    if ([event isEqualToString:@"package-selected"]) { title = packageName ?: @"Package Selected"; summary = @"Included in the next backup"; symbol = @"checkmark.circle.fill"; }
    else if ([event isEqualToString:@"package-unselected"]) { title = packageName ?: @"Package Unselected"; summary = @"Removed from the next backup"; symbol = @"minus.circle.fill"; }
    else if ([event isEqualToString:@"packages-selected"]) { title = @"Selection Updated"; summary = [NSString stringWithFormat:@"%@ shown packages included", details[@"count"] ?: @0]; symbol = @"checkmark.circle.fill"; }
    else if ([event isEqualToString:@"packages-unselected"]) { title = @"Selection Updated"; summary = [NSString stringWithFormat:@"%@ shown packages removed", details[@"count"] ?: @0]; symbol = @"minus.circle.fill"; }
    else if ([event isEqualToString:@"package-detected-install"]) { title = packageName ?: @"Package Detected"; summary = @"New installed package found"; symbol = @"shippingbox.fill"; }
    else if ([event isEqualToString:@"package-detected-update"]) { title = packageName ?: @"Package Updated"; summary = [NSString stringWithFormat:@"Updated from %@ to %@", details[@"from"] ?: @"an earlier version", details[@"to"] ?: @"a newer version"]; symbol = @"arrow.triangle.2.circlepath"; }
    else if ([event isEqualToString:@"package-detected-remove"]) { title = packageName ?: @"Package Removed"; summary = @"No longer installed"; symbol = @"trash.fill"; }
    else if ([event isEqualToString:@"backup-created"]) { title = @"Backup Created"; summary = [NSString stringWithFormat:@"%@ packages • %@ sources • %@ cached DEBs", details[@"packageCount"] ?: @0, details[@"sourceCount"] ?: @0, details[@"cachedDEBCount"] ?: @0]; symbol = @"checkmark.shield.fill"; }
    else if ([event isEqualToString:@"backup-deleted"]) { title = @"Backup Deleted"; summary = @"Removed from this device"; symbol = @"trash.fill"; }
    NSDate *date = ATMDateFromISO(item[@"timestamp"]);
    static NSDateFormatter *timeFormatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ timeFormatter = [NSDateFormatter new]; timeFormatter.dateStyle = NSDateFormatterNoStyle; timeFormatter.timeStyle = NSDateFormatterShortStyle; });
    NSString *time = date ? [timeFormatter stringFromDate:date] : @"Time unknown";
    cell.textLabel.text = title;
    cell.detailTextLabel.text = summary.length ? [NSString stringWithFormat:@"%@ • %@", summary, time] : time;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = [UIImage systemImageNamed:symbol];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
@end

@interface ATMSettingsController : UITableViewController @end
@implementation ATMSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Settings"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 1 : (section == 1 ? 3 : 1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Inventory" : (section == 1 ? @"Safety" : @"Diagnostics"); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 1) return @"AAZ Tweak Manager never transmits package, source, device, or account data and this beta does not execute restore transactions.";
    if (section == 2) return @"The diagnostic contains counts and stage flags only. It excludes package names, sources, paths, device identifiers, accounts, and credentials.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Show Excluded Packages"; cell.detailTextLabel.text = @"Review system/dependency classification without selecting them automatically.";
        UISwitch *toggle = [UISwitch new]; toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:ATMShowExcludedKey]; [toggle addTarget:self action:@selector(showExcludedChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else if (indexPath.section == 1) {
        NSArray *titles = @[@"Rootless only", @"Credentials excluded", @"Restore preview only"];
        NSArray *details = @[@"Reads the /var/jb APT and dpkg state.", @"auth.conf and embedded URL credentials are not exported.", @"No package installation, removal, or source write occurs."];
        cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row]; cell.detailTextLabel.numberOfLines = 2; cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield"];
    } else {
        cell.textLabel.text = @"Share Diagnostic File";
        cell.detailTextLabel.text = @"Create a privacy-safe classification summary.";
        cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 2) return;
    NSError *error = nil;
    ATMAppModel *model = ATMAppModel.shared;
    NSURL *url = ATMWriteDiagnosticReport(model.environment, model.packages, model.ledger.selectedPackageIDs, model.scanError, &error);
    if (!url) { ATMShowError(self, @"Diagnostic unavailable", error); return; }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:activity animated:YES completion:nil];
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
