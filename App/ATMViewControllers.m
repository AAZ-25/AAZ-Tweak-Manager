#import "ATMViewControllers.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
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

@interface ATMProfilesController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *profiles;
@end

@implementation ATMProfilesController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Selection Profiles"; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadProfiles]; }
- (void)reloadProfiles {
    self.profiles = [ATMAppModel.shared.backupManager.savedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    [self.tableView reloadData];
    if (self.profiles.count) { self.tableView.backgroundView = nil; return; }
    UILabel *empty = [UILabel new]; empty.text = @"No Saved Profiles\n\nSave one from My Tweaks → Select → Save Current Profile."; empty.textAlignment = NSTextAlignmentCenter; empty.numberOfLines = 0; empty.textColor = UIColor.secondaryLabelColor; empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.tableView.backgroundView = empty;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.profiles.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return self.profiles.count ? @"Tap to manage. Swipe left to delete." : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"profile"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"profile"];
    NSDictionary *profile = self.profiles[indexPath.row]; NSArray *packageIDs = [profile[@"packageIDs"] isKindOfClass:NSArray.class] ? profile[@"packageIDs"] : @[]; NSDate *updated = ATMDateFromISO(profile[@"updatedAt"]);
    cell.textLabel.text = profile[@"name"] ?: @"Profile"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu packages • Updated %@", (unsigned long)packageIDs.count, ATMShortDateTime(updated)]; cell.imageView.image = [UIImage systemImageNamed:@"person.crop.square"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; NSDictionary *profile = self.profiles[indexPath.row]; NSString *name = profile[@"name"] ?: @"Profile";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:@"Choose an action for this selection profile." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Load Profile" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self loadProfile:profile]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptToRenameProfile:profile]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Duplicate" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self duplicateProfile:profile]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; sheet.popoverPresentationController.sourceView = self.view; sheet.popoverPresentationController.sourceRect = self.view.bounds; [self presentViewController:sheet animated:YES completion:nil];
}
- (void)loadProfile:(NSDictionary *)profile {
    NSSet *target = [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; NSMutableSet *installed = [NSMutableSet set]; NSSet *current = ATMAppModel.shared.ledger.selectedPackageIDs;
    for (ATMPackageRecord *record in ATMAppModel.shared.packages) if ([target containsObject:record.packageID]) [installed addObject:record.packageID];
    [ATMAppModel.shared.ledger setSelected:NO forPackageIDs:current.allObjects]; [ATMAppModel.shared.ledger setSelected:YES forPackageIDs:installed.allObjects]; [ATMAppModel.shared.ledger recordEvent:@"profile-loaded" packageID:nil details:@{ @"count": @(installed.count) }]; [NSNotificationCenter.defaultCenter postNotificationName:ATMDataChangedNotification object:nil];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Profile Loaded" message:[NSString stringWithFormat:@"%lu installed packages are now selected.", (unsigned long)installed.count] preferredStyle:UIAlertControllerStyleAlert]; [done addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:done animated:YES completion:nil];
}
- (void)promptToRenameProfile:(NSDictionary *)profile {
    NSString *oldName = profile[@"name"] ?: @"Profile"; NSSet *packageIDs = [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Profile" message:@"The saved package selection will not change." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = oldName; field.clearButtonMode = UITextFieldViewModeWhileEditing; }]; [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { NSString *newName = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!newName.length || newName.length > 40) { ATMShowError(self, @"Profile not renamed", [NSError errorWithDomain:@"ATM" code:61 userInfo:@{NSLocalizedDescriptionKey: @"Use a profile name between 1 and 40 characters."}]); return; } for (NSDictionary *item in ATMAppModel.shared.backupManager.savedProfiles) { NSString *existing = item[@"name"] ?: @""; if ([existing caseInsensitiveCompare:newName] == NSOrderedSame && [existing caseInsensitiveCompare:oldName] != NSOrderedSame) { ATMShowError(self, @"Profile not renamed", [NSError errorWithDomain:@"ATM" code:62 userInfo:@{NSLocalizedDescriptionKey: @"A profile with that name already exists."}]); return; } } NSError *error = nil; if ([oldName caseInsensitiveCompare:newName] != NSOrderedSame) [ATMAppModel.shared.backupManager deleteProfileNamed:oldName error:nil]; if (![ATMAppModel.shared.backupManager saveProfileNamed:newName packageIDs:packageIDs error:&error]) { ATMShowError(self, @"Profile not renamed", error); return; } [ATMAppModel.shared.ledger recordEvent:@"profile-renamed" packageID:nil details:nil]; [self reloadProfiles]; }]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)duplicateProfile:(NSDictionary *)profile {
    NSString *base = [NSString stringWithFormat:@"%@ Copy", profile[@"name"] ?: @"Profile"]; NSString *candidate = base; NSUInteger suffix = 2; NSSet *names = [NSSet setWithArray:[ATMAppModel.shared.backupManager.savedProfiles valueForKey:@"name"]]; while ([names containsObject:candidate]) candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)suffix++]; NSSet *packageIDs = [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; NSError *error = nil; if (![ATMAppModel.shared.backupManager saveProfileNamed:candidate packageIDs:packageIDs error:&error]) { ATMShowError(self, @"Profile not duplicated", error); return; } [ATMAppModel.shared.ledger recordEvent:@"profile-duplicated" packageID:nil details:@{ @"count": @(packageIDs.count) }]; [self reloadProfiles];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; NSDictionary *profile = self.profiles[indexPath.row]; UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) { NSString *name = profile[@"name"] ?: @"Profile"; UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Profile?" message:@"This removes only the saved profile. Current selections and backup files will not change." preferredStyle:UIAlertControllerStyleAlert]; [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { completion(NO); }]]; [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { BOOL ok = [ATMAppModel.shared.backupManager deleteProfileNamed:name error:nil]; if (ok) [ATMAppModel.shared.ledger recordEvent:@"profile-deleted" packageID:nil details:nil]; completion(ok); [self reloadProfiles]; }]]; [self presentViewController:confirm animated:YES completion:nil]; }]; UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[delete]]; configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
@end

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
    UIAction *saveProfile = [UIAction actionWithTitle:@"Save Current Profile" image:[UIImage systemImageNamed:@"bookmark"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf promptToSaveProfile]; }];
    UIAction *manageProfiles = [UIAction actionWithTitle:@"Manage Profiles" image:[UIImage systemImageNamed:@"person.crop.square"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf.navigationController pushViewController:[ATMProfilesController new] animated:YES]; }];
    NSMutableArray *profileActions = [NSMutableArray array];
    for (NSDictionary *profile in ATMAppModel.shared.backupManager.savedProfiles) {
        NSString *name = profile[@"name"] ?: @"Profile";
        [profileActions addObject:[UIAction actionWithTitle:name image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf loadProfileNamed:name]; }]];
    }
    UIMenu *profiles = [UIMenu menuWithTitle:@"Selection Profiles" image:[UIImage systemImageNamed:@"person.crop.square"] identifier:nil options:0 children:[@[saveProfile, manageProfiles] arrayByAddingObjectsFromArray:profileActions]];
    self.selectionButton.menu = [UIMenu menuWithTitle:@"Shown Packages" children:@[selectAll, unselectAll, profiles]];
}
- (void)promptToSaveProfile {
    if (!self.selectedPackageIDs.count) { ATMShowError(self, @"Profile unavailable", [NSError errorWithDomain:@"ATM" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Select at least one package first."}]); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save Selection Profile" message:@"Profiles stay private on this device and let you reuse a package selection." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Profile name"; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { NSError *error = nil; if (![ATMAppModel.shared.backupManager saveProfileNamed:alert.textFields.firstObject.text packageIDs:self.selectedPackageIDs error:&error]) ATMShowError(self, @"Profile not saved", error); else [ATMAppModel.shared.ledger recordEvent:@"profile-saved" packageID:nil details:@{ @"count": @(self.selectedPackageIDs.count) }]; [self configureSelectionMenu]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)loadProfileNamed:(NSString *)name {
    NSSet *target = [ATMAppModel.shared.backupManager packageIDsForProfileNamed:name]; NSMutableSet *installed = [NSMutableSet set];
    for (ATMPackageRecord *record in ATMAppModel.shared.packages) if ([target containsObject:record.packageID]) [installed addObject:record.packageID];
    [ATMAppModel.shared.ledger setSelected:NO forPackageIDs:self.selectedPackageIDs.allObjects]; [ATMAppModel.shared.ledger setSelected:YES forPackageIDs:installed.allObjects];
    [ATMAppModel.shared.ledger recordEvent:@"profile-loaded" packageID:nil details:@{ @"count": @(installed.count) }]; [self reloadData];
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
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Standard Backup" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self performBackupWithPassword:nil]; }]];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Encrypted Backup" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self promptForNewBackupPassword]; }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}
- (void)promptForNewBackupPassword {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Encrypt Backup" message:@"Use at least 8 characters. AAZ Tweak Manager never stores or recovers this password." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Password"; field.secureTextEntry = YES; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Confirm password"; field.secureTextEntry = YES; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create Encrypted Backup" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { NSString *password = alert.textFields.firstObject.text ?: @"", *confirmation = alert.textFields.lastObject.text ?: @""; if (password.length < 8 || ![password isEqualToString:confirmation]) { ATMShowError(self, @"Password not accepted", [NSError errorWithDomain:@"ATM" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Passwords must match and contain at least 8 characters."}]); return; } [self performBackupWithPassword:password]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSString *)matchingProfileName {
    for (NSDictionary *profile in ATMAppModel.shared.backupManager.savedProfiles) if ([[NSSet setWithArray:profile[@"packageIDs"] ?: @[]] isEqualToSet:self.selectedPackageIDs]) return profile[@"name"];
    return nil;
}
- (void)performBackupWithPassword:(NSString *)password {
    UIBarButtonItem *backupButton = self.navigationItem.rightBarButtonItem;
    backupButton.title = @"Creating…";
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.selectionButton.enabled = NO;
    self.packageSearchController.searchBar.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *url = [ATMAppModel.shared.backupManager createBackupWithPackages:ATMAppModel.shared.packages sources:ATMAppModel.shared.sources profileName:[self matchingProfileName] password:password error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            backupButton.title = @"Backup";
            backupButton.enabled = YES;
            self.selectionButton.enabled = YES;
            self.packageSearchController.searchBar.userInteractionEnabled = YES;
            if (!url) { ATMShowError(self, @"Backup failed", error); return; }
            NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url password:password error:nil];
            NSArray *packages = [manifest[@"packages"] isKindOfClass:NSArray.class] ? manifest[@"packages"] : @[];
            NSArray *sources = [manifest[@"sources"] isKindOfClass:NSArray.class] ? manifest[@"sources"] : @[];
            NSUInteger cachedCount = [[packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count];
            NSString *successMessage = [NSString stringWithFormat:@"%lu packages • %lu sources • %lu cached DEBs\n%@ • Atomic write verified\n\nCredentials are never included.", (unsigned long)packages.count, (unsigned long)sources.count, (unsigned long)cachedCount, password.length ? @"Encrypted" : @"Standard"];
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

@interface ATMBackupsController : UITableViewController <UISearchResultsUpdating, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSArray<NSURL *> *allBackups;
@property(nonatomic, copy) NSArray<NSURL *> *backups;
@property(nonatomic, strong) UISearchController *backupSearchController;
@property(nonatomic, assign) NSInteger sortMode;
@property(nonatomic, strong, nullable) NSURL *pendingImportURL;
@property(nonatomic, strong, nullable) UIDocumentPickerViewController *importPicker;
- (void)beginImportFromURL:(NSURL *)url;
@end

@implementation ATMBackupsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Backups";
    self.backupSearchController = [[UISearchController alloc] initWithSearchResultsController:nil]; self.backupSearchController.searchResultsUpdater = self; self.backupSearchController.obscuresBackgroundDuringPresentation = NO; self.backupSearchController.searchBar.placeholder = @"Search backups"; self.navigationItem.searchController = self.backupSearchController; self.definesPresentationContext = YES;
    [self configureSortMenu]; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadData) name:ATMDataChangedNotification object:nil]; [self reloadData];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (void)configureSortMenu {
    __weak typeof(self) weakSelf = self; NSArray *titles = @[@"Newest", @"Oldest", @"Largest", @"Smallest"];
    NSMutableArray *actions = [NSMutableArray array]; for (NSUInteger index = 0; index < titles.count; index++) { UIAction *action = [UIAction actionWithTitle:titles[index] image:nil identifier:nil handler:^(__unused UIAction *item) { weakSelf.sortMode = (NSInteger)index; [weakSelf reloadData]; [weakSelf configureSortMenu]; }]; action.state = self.sortMode == (NSInteger)index ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action]; }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] menu:[UIMenu menuWithTitle:@"Sort Backups" children:actions]];
}
- (void)reloadData {
    self.allBackups = ATMAppModel.shared.backupManager.availableBackups; NSString *query = [self.backupSearchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *filtered = query.length ? [self.allBackups filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { (void)bindings; NSDictionary *manifest = [ATMAppModel.shared.backupManager manifestForBackup:url error:nil]; NSString *profile = manifest[@"profileName"] ?: @""; return [profile localizedCaseInsensitiveContainsString:query] || [url.lastPathComponent localizedCaseInsensitiveContainsString:query]; }]] : self.allBackups;
    self.backups = [filtered sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { BOOL ap = [ATMAppModel.shared.backupManager isBackupPinned:a], bp = [ATMAppModel.shared.backupManager isBackupPinned:b]; if (ap != bp) return ap ? NSOrderedAscending : NSOrderedDescending; NSDate *ad = nil, *bd = nil; NSNumber *as = nil, *bs = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil]; [a getResourceValue:&as forKey:NSURLFileSizeKey error:nil]; [b getResourceValue:&bs forKey:NSURLFileSizeKey error:nil]; if (self.sortMode == 1) return [ad ?: NSDate.distantPast compare:bd ?: NSDate.distantPast]; if (self.sortMode == 2) return [bs compare:as]; if (self.sortMode == 3) return [as compare:bs]; return [bd ?: NSDate.distantPast compare:ad ?: NSDate.distantPast]; }];
    [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { (void)searchController; [self reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 1 : (self.backups.count ?: 1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; if (section == 0) return nil; return self.backups.count ? [NSString stringWithFormat:@"%lu backup%@ shown", (unsigned long)self.backups.count, self.backups.count == 1 ? @"" : @"s"] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section == 0 ? nil : @"Inspect, compare, share, pin, or delete backups."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"]; cell.imageView.tintColor = UIColor.systemBlueColor;
    if (indexPath.section == 0) { cell.textLabel.text = @"Import Backup"; cell.detailTextLabel.text = @"Choose an .aaztmbackup file from Files"; cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault; return cell; }
    if (!self.backups.count) { cell.textLabel.text = self.allBackups.count ? @"No Matching Backups" : @"No Backups Yet"; cell.detailTextLabel.text = self.allBackups.count ? @"Try another search." : @"Create a backup or import an existing .aaztmbackup file."; cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.badge.plus"]; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
    NSURL *url = self.backups[indexPath.row]; BOOL encrypted = [ATMAppModel.shared.backupManager isEncryptedBackup:url], pinned = [ATMAppModel.shared.backupManager isBackupPinned:url]; NSDictionary *manifest = encrypted ? nil : [ATMAppModel.shared.backupManager manifestForBackup:url error:nil]; NSDate *created = ATMDateFromISO(manifest[@"createdAt"]); if (!created) [url getResourceValue:&created forKey:NSURLContentModificationDateKey error:nil]; NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil]; NSString *sizeText = [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]; NSString *profile = manifest[@"profileName"];
    cell.textLabel.text = [NSString stringWithFormat:@"%@Backup — %@", pinned ? @"Pinned • " : @"", ATMShortDateTime(created)];
    if (encrypted) { cell.detailTextLabel.text = [NSString stringWithFormat:@"Encrypted • %@ • Tap to unlock", sizeText]; cell.imageView.image = [UIImage systemImageNamed:@"lock.shield.fill"]; }
    else if (!manifest) { cell.detailTextLabel.text = [NSString stringWithFormat:@"Corrupted or unsupported • %@", sizeText]; cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"]; cell.imageView.tintColor = UIColor.systemOrangeColor; }
    else { cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%lu packages • %lu sources • %@ • Tap to verify", profile.length ? [profile stringByAppendingString:@" • "] : @"", (unsigned long)[manifest[@"packages"] count], (unsigned long)[manifest[@"sources"] count], sizeText]; cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.fill"]; cell.imageView.tintColor = UIColor.systemBlueColor; }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section == 0) { [self importBackup]; return; } if (!self.backups.count) return; NSURL *url = self.backups[indexPath.row]; if ([ATMAppModel.shared.backupManager isEncryptedBackup:url]) [self promptForPasswordWithTitle:@"Unlock Backup" completion:^(NSString *password) { [self showBackup:url password:password]; }]; else [self showBackup:url password:nil]; }
- (void)promptForPasswordWithTitle:(NSString *)title completion:(void (^)(NSString *password))completion { UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:@"The password is used only for this operation and is never stored." preferredStyle:UIAlertControllerStyleAlert]; [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Password"; field.secureTextEntry = YES; }]; [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { completion(alert.textFields.firstObject.text ?: @""); }]]; [self presentViewController:alert animated:YES completion:nil]; }
- (void)showBackup:(NSURL *)url password:(NSString *)password {
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Inspecting Backup" message:@"Checking archive structure, CRC values, and cached-DEB hashes…" preferredStyle:UIAlertControllerStyleAlert]; [self presentViewController:progress animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ NSError *error = nil; NSDictionary *report = [ATMAppModel.shared.backupManager backupReportForURL:url password:password error:&error]; dispatch_async(dispatch_get_main_queue(), ^{ [progress dismissViewControllerAnimated:YES completion:^{ if (!report) { ATMShowError(self, @"Backup could not be inspected", error); return; } [self presentBackupReport:report forURL:url]; }]; }); });
}
- (void)presentBackupReport:(NSDictionary *)report forURL:(NSURL *)url {
    NSDictionary *manifest = report[@"manifest"]; NSMutableDictionary *installed = [NSMutableDictionary dictionary]; for (ATMPackageRecord *record in ATMAppModel.shared.packages) installed[record.packageID] = record.version;
    NSUInteger ready = 0, missing = 0, different = 0, unavailable = 0; for (NSDictionary *package in manifest[@"packages"]) { NSString *current = installed[package[@"packageID"] ?: @""]; if (!current) missing++; else if (![current isEqualToString:package[@"version"] ?: @""]) different++; else ready++; if ([package[@"debStatus"] isEqualToString:@"unavailable"]) unavailable++; }
    NSString *cachedSize = [NSByteCountFormatter stringFromByteCount:[report[@"cachedBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], *archiveSize = [NSByteCountFormatter stringFromByteCount:[report[@"fileSize"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile], *freeSize = [NSByteCountFormatter stringFromByteCount:[report[@"availableBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    NSString *message = [NSString stringWithFormat:@"Health: %@\nProtection: %@\nArchive: %@ • Free storage: %@\nPackages: %@ • Sources: %@\nExact cached DEBs: %@ (%@)\n\nMigration readiness\nReady now: %lu\nMissing: %lu\nDifferent version: %lu\nPayload unavailable: %lu\n\nNo changes are made.", report[@"health"], [report[@"encrypted"] boolValue] ? @"Encrypted" : @"Standard", archiveSize, freeSize, report[@"packageCount"], report[@"sourceCount"], report[@"cachedDEBCount"], cachedSize, (unsigned long)ready, (unsigned long)missing, (unsigned long)different, (unsigned long)unavailable];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Health & Readiness" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]]; [alert addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self shareURL:url]; }]];
    NSUInteger index = [self.backups indexOfObject:url]; if (![report[@"encrypted"] boolValue] && index != NSNotFound && index + 1 < self.backups.count && ![ATMAppModel.shared.backupManager isEncryptedBackup:self.backups[index + 1]]) [alert addAction:[UIAlertAction actionWithTitle:@"Compare with Next" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self compareBackup:self.backups[index + 1] with:url]; }]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)compareBackup:(NSURL *)older with:(NSURL *)newer { NSError *error = nil; NSDictionary *result = [ATMAppModel.shared.backupManager compareBackup:older withBackup:newer error:&error]; if (!result) { ATMShowError(self, @"Comparison unavailable", error); return; } NSString *message = [NSString stringWithFormat:@"Added: %@\nRemoved: %@\nUpdated: %@\nUnchanged: %@", result[@"added"], result[@"removed"], result[@"updated"], result[@"unchanged"]]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Changes" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; }
- (void)importBackup {
    [NSUserDefaults.standardUserDefaults setObject:@"picker-requested" forKey:@"ATMLastImportStageV1"];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"ATMLastImportErrorCodeV1"];
    UIViewController *presenter = self.navigationController ?: self;
    if (!self.view.window || presenter.presentedViewController) {
        [NSUserDefaults.standardUserDefaults setObject:@"picker-presentation-blocked" forKey:@"ATMLastImportStageV1"];
        [NSUserDefaults.standardUserDefaults setInteger:62 forKey:@"ATMLastImportErrorCodeV1"];
        ATMShowError(self, @"Import unavailable", [NSError errorWithDomain:@"ATM" code:62 userInfo:@{NSLocalizedDescriptionKey: @"Close the current window, then try Import Backup again."}]);
        return;
    }
    SEL legacyImportSelector = NSSelectorFromString(@"initWithDocumentTypes:inMode:");
    typedef UIDocumentPickerViewController *(*ATMDocumentPickerInitFunction)(id, SEL, NSArray<NSString *> *, NSUInteger);
    UIDocumentPickerViewController *picker = ((ATMDocumentPickerInitFunction)objc_msgSend)([UIDocumentPickerViewController alloc], legacyImportSelector, @[@"public.data"], 0);
    if (!picker) { ATMShowError(self, @"Import unavailable", [NSError errorWithDomain:@"ATM" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Files is unavailable."}]); return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.presentationController.delegate = self; self.importPicker = picker;
    [presenter presentViewController:picker animated:YES completion:^{
        [NSUserDefaults.standardUserDefaults setObject:@"picker-opened" forKey:@"ATMLastImportStageV1"];
    }];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    controller.delegate = nil; self.importPicker = nil;
    NSURL *url = urls.firstObject;
    if (!url) { [NSUserDefaults.standardUserDefaults setObject:@"no-selection" forKey:@"ATMLastImportStageV1"]; [NSUserDefaults.standardUserDefaults setInteger:51 forKey:@"ATMLastImportErrorCodeV1"]; return; }
    [NSUserDefaults.standardUserDefaults setObject:@"file-selected" forKey:@"ATMLastImportStageV1"];
    [self beginImportFromURL:url];
}
- (void)beginImportFromURL:(NSURL *)url {
    BOOL accessStarted = [url startAccessingSecurityScopedResource];
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Importing Backup" message:@"Preparing the selected file…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *staged = [ATMAppModel.shared.backupManager stageImportFromURL:url error:&error];
        if (accessStarted) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!staged) { ATMShowError(self, @"Import could not start", error); return; }
                self.pendingImportURL = staged;
                if ([ATMAppModel.shared.backupManager isEncryptedBackup:staged]) [self promptForImportPasswordForURL:staged];
                else [self performImport:staged password:nil];
            }];
        });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { controller.delegate = nil; self.importPicker = nil; [NSUserDefaults.standardUserDefaults setObject:@"picker-cancelled" forKey:@"ATMLastImportStageV1"]; [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"ATMLastImportErrorCodeV1"]; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController { if (presentationController.presentedViewController == self.importPicker) { self.importPicker.delegate = nil; self.importPicker = nil; [NSUserDefaults.standardUserDefaults setObject:@"picker-cancelled" forKey:@"ATMLastImportStageV1"]; [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"ATMLastImportErrorCodeV1"]; } }
- (void)promptForImportPasswordForURL:(NSURL *)url {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Encrypted Backup" message:@"The password is used only for this import and is never stored." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Password"; field.secureTextEntry = YES; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [ATMAppModel.shared.backupManager discardStagedImportAtURL:url]; self.pendingImportURL = nil; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self performImport:url password:alert.textFields.firstObject.text ?: @""]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)performImport:(NSURL *)url password:(NSString *)password { UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Inspecting Import" message:@"Checking format, archive integrity, and cached-DEB hashes before adding it." preferredStyle:UIAlertControllerStyleAlert]; [self presentViewController:progress animated:YES completion:nil]; dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ NSError *error = nil; NSURL *imported = [ATMAppModel.shared.backupManager importBackupFromURL:url password:password error:&error]; dispatch_async(dispatch_get_main_queue(), ^{ self.pendingImportURL = nil; [progress dismissViewControllerAnimated:YES completion:^{ if (!imported) { ATMShowError(self, error.code == 54 ? @"Already Imported" : @"Import failed", error); return; } [self reloadData]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Imported" message:@"The archive passed health and integrity checks. No restore action was executed." preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; }]; }); }); }
- (void)shareURL:(NSURL *)url { UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; activity.popoverPresentationController.sourceView = self.view; activity.popoverPresentationController.sourceRect = self.view.bounds; [self presentViewController:activity animated:YES completion:nil]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath { (void)tableView; if (indexPath.section == 0 || !self.backups.count) return nil; NSURL *url = self.backups[indexPath.row]; BOOL pinned = [ATMAppModel.shared.backupManager isBackupPinned:url]; UIContextualAction *pin = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:pinned ? @"Unpin" : @"Pin" handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) { [ATMAppModel.shared.backupManager setBackup:url pinned:!pinned]; completion(YES); [self reloadData]; }]; pin.backgroundColor = UIColor.systemBlueColor; return [UISwipeActionsConfiguration configurationWithActions:@[pin]]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath { (void)tableView; if (indexPath.section == 0 || !self.backups.count) return nil; UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) { NSURL *url = self.backups[indexPath.row]; UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Backup?" message:@"This permanently removes this backup from the device. Other backups and selections are unchanged." preferredStyle:UIAlertControllerStyleAlert]; [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) { completion(NO); }]]; [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) { NSError *error = nil; BOOL ok = [NSFileManager.defaultManager removeItemAtURL:url error:&error]; if (ok) { [ATMAppModel.shared.backupManager setBackup:url pinned:NO]; [ATMAppModel.shared.ledger recordEvent:@"backup-deleted" packageID:nil details:nil]; } completion(ok); [self reloadData]; if (!ok) ATMShowError(self, @"Delete failed", error); }]]; [self presentViewController:confirm animated:YES completion:nil]; }]; UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[delete]]; configuration.performsFirstActionWithFullSwipe = NO; return configuration; }
@end

@interface ATMSourcesController : UITableViewController @end
@implementation ATMSourcesController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Sources"; self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:ATMAppModel.shared action:@selector(refresh)]; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:ATMDataChangedNotification object:nil]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reload { [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.sources.count ?: 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return @"Credentials are removed from exported sources."; }
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
    [self updateEmptyState];
    [self.tableView reloadData];
}
- (void)updateEmptyState {
    if (self.sections.count) { self.tableView.backgroundView = nil; return; }
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:self.filterControl.selectedSegmentIndex ? @"line.3.horizontal.decrease.circle" : @"clock.arrow.circlepath"]];
    icon.tintColor = UIColor.systemBlueColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:46].active = YES;
    [icon.heightAnchor constraintEqualToConstant:46].active = YES;
    UILabel *title = [UILabel new]; title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; title.textAlignment = NSTextAlignmentCenter; title.text = self.filterControl.selectedSegmentIndex ? @"No Matching Activity" : @"No Activity Yet";
    UILabel *detail = [UILabel new]; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; detail.textColor = UIColor.secondaryLabelColor; detail.textAlignment = NSTextAlignmentCenter; detail.numberOfLines = 0; detail.text = self.filterControl.selectedSegmentIndex ? @"Choose another filter." : @"Selections, package changes, profiles, and backups appear here.";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, detail]]; stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *container = [UIView new]; [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor], [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-30], [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:32], [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-32], [detail.widthAnchor constraintLessThanOrEqualToConstant:360]]];
    self.tableView.backgroundView = container;
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return [self.sections[section][@"items"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return self.sections.count ? self.sections[section][@"title"] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (!self.sections.count || section != (NSInteger)self.sections.count - 1) return nil;
    return @"Clearing History keeps selections and backups.";
}
- (NSString *)packageNameForID:(NSString *)packageID {
    if (![packageID isKindOfClass:NSString.class] || !packageID.length) return nil;
    for (ATMPackageRecord *record in ATMAppModel.shared.packages) if ([record.packageID isEqualToString:packageID]) return record.name.length ? record.name : packageID;
    return packageID;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"history"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"history"];
    cell.imageView.tintColor = UIColor.systemBlueColor;
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
    else if ([event isEqualToString:@"backup-imported"]) { title = @"Backup Imported"; summary = [NSString stringWithFormat:@"%@ packages • %@ sources • integrity verified", details[@"packageCount"] ?: @0, details[@"sourceCount"] ?: @0]; symbol = @"square.and.arrow.down.fill"; }
    else if ([event isEqualToString:@"backup-deleted"]) { title = @"Backup Deleted"; summary = @"Removed from this device"; symbol = @"trash.fill"; }
    else if ([event isEqualToString:@"profile-saved"]) { title = @"Selection Profile Saved"; summary = [NSString stringWithFormat:@"%@ packages stored in the profile", details[@"count"] ?: @0]; symbol = @"bookmark.fill"; }
    else if ([event isEqualToString:@"profile-loaded"]) { title = @"Selection Profile Loaded"; summary = [NSString stringWithFormat:@"%@ installed packages selected", details[@"count"] ?: @0]; symbol = @"person.crop.square.fill"; }
    else if ([event isEqualToString:@"profile-deleted"]) { title = @"Selection Profile Deleted"; summary = @"Current package selections were not changed"; symbol = @"trash.fill"; }
    else if ([event isEqualToString:@"profile-renamed"]) { title = @"Selection Profile Renamed"; summary = @"The saved package selection was preserved"; symbol = @"pencil.circle.fill"; }
    else if ([event isEqualToString:@"profile-duplicated"]) { title = @"Selection Profile Duplicated"; summary = [NSString stringWithFormat:@"%@ packages copied to a new profile", details[@"count"] ?: @0]; symbol = @"plus.square.on.square"; }
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
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; if (section == 2) return 3; if (section == 4) return 2; return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Inventory", @"Profiles", @"Safety", @"Diagnostics", @"About"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 3) return @"Counts and stage flags only.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Show Excluded Packages"; cell.detailTextLabel.text = @"Show system and dependency packages.";
        UISwitch *toggle = [UISwitch new]; toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:ATMShowExcludedKey]; [toggle addTarget:self action:@selector(showExcludedChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else if (indexPath.section == 1) {
        NSUInteger count = ATMAppModel.shared.backupManager.savedProfiles.count;
        cell.textLabel.text = @"Manage Selection Profiles"; cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu saved profile%@", (unsigned long)count, count == 1 ? @"" : @"s"];
        cell.imageView.image = [UIImage systemImageNamed:@"person.crop.square"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == 2) {
        NSArray *titles = @[@"Rootless", @"Credentials Excluded", @"Restore Preview"];
        NSArray *details = @[@"Uses the Rootless package database.", @"Passwords and repository credentials are excluded.", @"Reviews backups without changing packages or sources."];
        cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row]; cell.detailTextLabel.numberOfLines = 2; cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield"];
    } else if (indexPath.section == 3) {
        cell.textLabel.text = @"Share Diagnostic File";
        cell.detailTextLabel.text = @"Share counts and import status.";
        cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.row == 0) {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary; cell.textLabel.text = @"AAZ Tweak Manager"; cell.detailTextLabel.text = [NSString stringWithFormat:@"Version %@ — Build %@", info[@"CFBundleShortVersionString"] ?: @"Unknown", info[@"CFBundleVersion"] ?: @"Unknown"]; cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
    } else {
        cell.textLabel.text = @"Developer on X"; cell.detailTextLabel.text = @"@_kkk2"; cell.imageView.image = [UIImage systemImageNamed:@"link"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) { [self.navigationController pushViewController:[ATMProfilesController new] animated:YES]; return; }
    if (indexPath.section == 4 && indexPath.row == 1) { NSURL *url = [NSURL URLWithString:@"https://x.com/_kkk2"]; if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; return; }
    if (indexPath.section != 3) return;
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

BOOL ATMHandleBackupURL(UIViewController *rootController, NSURL *url) {
    if (!url.isFileURL || ![rootController isKindOfClass:UITabBarController.class]) return NO;
    UITabBarController *tabs = (UITabBarController *)rootController;
    if (tabs.viewControllers.count < 2 || ![tabs.viewControllers[1] isKindOfClass:UINavigationController.class]) return NO;
    UINavigationController *navigation = (UINavigationController *)tabs.viewControllers[1];
    if (![navigation.viewControllers.firstObject isKindOfClass:ATMBackupsController.class]) return NO;
    ATMBackupsController *backups = (ATMBackupsController *)navigation.viewControllers.firstObject;
    tabs.selectedIndex = 1;
    [navigation popToRootViewControllerAnimated:NO];
    [backups loadViewIfNeeded];
    [NSUserDefaults.standardUserDefaults setObject:@"open-in-received" forKey:@"ATMLastImportStageV1"];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"ATMLastImportErrorCodeV1"];
    [backups beginImportFromURL:url];
    return YES;
}
