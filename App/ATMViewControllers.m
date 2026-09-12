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

static UIView *ATMEmptyStateView(NSString *symbol, NSString *titleText, NSString *detailText) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = UIColor.systemBlueColor; icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:46].active = YES; [icon.heightAnchor constraintEqualToConstant:46].active = YES;
    UILabel *title = [UILabel new]; title.text = titleText; title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; title.adjustsFontForContentSizeCategory = YES; title.textAlignment = NSTextAlignmentCenter;
    UILabel *detail = [UILabel new]; detail.text = detailText; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; detail.adjustsFontForContentSizeCategory = YES; detail.textColor = UIColor.secondaryLabelColor; detail.textAlignment = NSTextAlignmentCenter; detail.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, detail]]; stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *container = [UIView new]; [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor], [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-24], [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:32], [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-32], [detail.widthAnchor constraintLessThanOrEqualToConstant:360]]];
    return container;
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
    self.tableView.backgroundView = ATMEmptyStateView(@"person.crop.square", @"No Saved Profiles", @"Save a selection from My Tweaks to reuse it later.");
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
    return @"Bulk actions apply only to the packages currently shown. Changes are saved automatically.";
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


@interface ATMRestoreReadinessController : UITableViewController
@property(nonatomic, copy) NSDictionary *plan;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@property(nonatomic, copy, nullable) dispatch_block_t restoreHandler;
@property(nonatomic, copy, nullable) dispatch_block_t cancelHandler;
- (instancetype)initWithPlan:(NSDictionary *)plan;
@end

@implementation ATMRestoreReadinessController
- (instancetype)initWithPlan:(NSDictionary *)plan {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _plan = [plan copy];
    return self;
}
- (NSDictionary *)readinessItem:(NSString *)title value:(id)value symbol:(NSString *)symbol color:(UIColor *)color {
    return @{ @"title": title, @"value": [value description] ?: @"0", @"symbol": symbol, @"color": color };
}
- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL passed = [self.plan[@"simulationPassed"] boolValue] && [self.plan[@"blocked"] unsignedIntegerValue] == 0;
    self.title = passed ? @"Plan Ready" : @"Needs Attention";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeReadiness)];
    if ([self.plan[@"safeToExecute"] boolValue]) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Restore" style:UIBarButtonItemStyleDone target:self action:@selector(requestRestore)];
    UIColor *good = UIColor.systemGreenColor, *warning = UIColor.systemOrangeColor, *neutral = UIColor.systemBlueColor;
    self.sections = @[
        @{ @"title": @"BACKUP", @"items": @[
            [self readinessItem:@"Packages" value:self.plan[@"packageCount"] symbol:@"shippingbox.fill" color:neutral],
            [self readinessItem:@"Exact Version" value:self.plan[@"alreadyInstalled"] symbol:@"checkmark.circle.fill" color:good],
            [self readinessItem:@"Missing" value:self.plan[@"missing"] symbol:@"arrow.down.circle.fill" color:neutral],
            [self readinessItem:@"Version Updates" value:self.plan[@"updatesNeeded"] symbol:@"arrow.up.circle.fill" color:neutral],
            [self readinessItem:@"Newer Versions Kept" value:self.plan[@"newerVersionsKept"] symbol:@"arrow.up.right.circle.fill" color:good]
        ] },
        @{ @"title": @"SAFETY GATES", @"items": @[
            [self readinessItem:@"Protected or Invalid" value:self.plan[@"protectedOrInvalid"] symbol:@"shield.lefthalf.filled" color:[self.plan[@"protectedOrInvalid"] unsignedIntegerValue] ? warning : good],
            [self readinessItem:@"Held" value:self.plan[@"held"] symbol:@"pause.circle.fill" color:[self.plan[@"held"] unsignedIntegerValue] ? warning : good],
            [self readinessItem:@"Metadata Unavailable" value:self.plan[@"metadataUnavailable"] symbol:@"questionmark.circle.fill" color:[self.plan[@"metadataUnavailable"] unsignedIntegerValue] ? warning : good],
            [self readinessItem:@"Checks Unavailable" value:self.plan[@"prerequisiteFailures"] symbol:@"wrench.and.screwdriver.fill" color:[self.plan[@"prerequisiteFailures"] unsignedIntegerValue] ? warning : good],
            [self readinessItem:@"Unexpected Actions" value:self.plan[@"unexpectedActions"] symbol:@"exclamationmark.arrow.triangle.2.circlepath" color:[self.plan[@"unexpectedActions"] unsignedIntegerValue] ? UIColor.systemRedColor : good]
        ] },
        @{ @"title": @"RESTORE PREVIEW", @"items": @[
            [self readinessItem:@"Result" value:passed ? @"Passed" : ([self.plan[@"simulationAttempted"] boolValue] ? @"Blocked" : @"Not Started") symbol:passed ? @"checkmark.shield.fill" : @"exclamationmark.shield.fill" color:passed ? good : warning],
            [self readinessItem:@"Embedded DEBs" value:self.plan[@"embeddedRequests"] symbol:@"archivebox.fill" color:[self.plan[@"embeddedRequests"] unsignedIntegerValue] ? good : neutral],
            [self readinessItem:@"Repository Packages" value:self.plan[@"repositoryRequests"] symbol:@"network" color:[self.plan[@"repositoryRequests"] unsignedIntegerValue] ? warning : good],
            [self readinessItem:@"Packages to Install" value:self.plan[@"installActions"] symbol:@"plus.circle.fill" color:neutral],
            [self readinessItem:@"Packages to Configure" value:self.plan[@"configureActions"] symbol:@"gearshape.fill" color:neutral],
            [self readinessItem:@"Packages to Remove" value:self.plan[@"removalActions"] symbol:@"minus.circle.fill" color:[self.plan[@"removalActions"] unsignedIntegerValue] ? UIColor.systemRedColor : good]
        ] }
    ];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 170)];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:passed ? @"checkmark.shield.fill" : @"exclamationmark.shield.fill"]];
    icon.tintColor = passed ? good : warning; icon.contentMode = UIViewContentModeScaleAspectFit; icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *headline = [UILabel new]; headline.text = passed ? @"Readiness Check Passed" : @"Restore Needs Attention"; headline.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; headline.textAlignment = NSTextAlignmentCenter; headline.adjustsFontForContentSizeCategory = YES; headline.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *detail = [UILabel new]; detail.text = self.plan[@"reason"]; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; detail.textColor = UIColor.secondaryLabelColor; detail.textAlignment = NSTextAlignmentCenter; detail.numberOfLines = 3; detail.adjustsFontForContentSizeCategory = YES; detail.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:icon]; [header addSubview:headline]; [header addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[icon.topAnchor constraintEqualToAnchor:header.topAnchor constant:14], [icon.centerXAnchor constraintEqualToAnchor:header.centerXAnchor], [icon.widthAnchor constraintEqualToConstant:44], [icon.heightAnchor constraintEqualToConstant:44], [headline.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:10], [headline.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20], [headline.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20], [detail.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:6], [detail.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24], [detail.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24]]];
    self.tableView.tableHeaderView = header;
}
- (void)closeReadiness { dispatch_block_t handler = self.cancelHandler; [self dismissViewControllerAnimated:YES completion:handler]; }
- (void)requestRestore { if ([self.plan[@"safeToExecute"] boolValue] && self.restoreHandler) self.restoreHandler(); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return [self.sections[section][@"items"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return self.sections[section][@"title"]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return (NSUInteger)section + 1 == self.sections.count ? ([self.plan[@"safeToExecute"] boolValue] ? @"No changes yet. Restore requires a separate final confirmation and an immediate safety recheck." : @"Preview only. No packages or sources were changed.") : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"readiness"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"readiness"];
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    cell.textLabel.text = item[@"title"]; cell.detailTextLabel.text = item[@"value"]; cell.imageView.image = [UIImage systemImageNamed:item[@"symbol"]]; cell.imageView.tintColor = item[@"color"]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
@end


@interface ATMBackupDetailsController : UITableViewController
@property(nonatomic, copy) NSDictionary *report;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@property(nonatomic, copy) dispatch_block_t checkPlanHandler;
@property(nonatomic, copy) dispatch_block_t shareHandler;
@property(nonatomic, copy, nullable) dispatch_block_t compareHandler;
- (instancetype)initWithReport:(NSDictionary *)report
                          ready:(NSUInteger)ready
                        missing:(NSUInteger)missing
                      different:(NSUInteger)different
                    unavailable:(NSUInteger)unavailable;
@end

@implementation ATMBackupDetailsController
- (instancetype)initWithReport:(NSDictionary *)report
                          ready:(NSUInteger)ready
                        missing:(NSUInteger)missing
                      different:(NSUInteger)different
                    unavailable:(NSUInteger)unavailable {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _report = [report copy];
        NSString *archiveSize = [NSByteCountFormatter stringFromByteCount:[report[@"fileSize"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        NSString *freeSize = [NSByteCountFormatter stringFromByteCount:[report[@"availableBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        NSString *cachedSize = [NSByteCountFormatter stringFromByteCount:[report[@"cachedBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        _sections = @[
            @{ @"title": @"BACKUP", @"items": @[
                @{ @"title": @"Protection", @"value": [report[@"encrypted"] boolValue] ? @"Encrypted" : @"Standard", @"symbol": @"lock.shield" },
                @{ @"title": @"Archive Size", @"value": archiveSize, @"symbol": @"doc.zipper" },
                @{ @"title": @"Free Storage", @"value": freeSize, @"symbol": @"internaldrive" }
            ] },
            @{ @"title": @"CONTENTS", @"items": @[
                @{ @"title": @"Packages", @"value": [report[@"packageCount"] description] ?: @"0", @"symbol": @"shippingbox" },
                @{ @"title": @"Sources", @"value": [report[@"sourceCount"] description] ?: @"0", @"symbol": @"link" },
                @{ @"title": @"Cached DEBs", @"value": [NSString stringWithFormat:@"%@ • %@", [report[@"cachedDEBCount"] description] ?: @"0", cachedSize], @"symbol": @"archivebox" }
            ] },
            @{ @"title": @"ON THIS DEVICE", @"items": @[
                @{ @"title": @"Already Installed", @"value": [@(ready) description], @"symbol": @"checkmark.circle" },
                @{ @"title": @"Missing", @"value": [@(missing) description], @"symbol": @"arrow.down.circle" },
                @{ @"title": @"Different Version", @"value": [@(different) description], @"symbol": @"arrow.triangle.2.circlepath" },
                @{ @"title": @"Payload Unavailable", @"value": [@(unavailable) description], @"symbol": @"questionmark.circle" }
            ] }
        ];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL healthy = [self.report[@"health"] isEqualToString:@"Healthy"];
    self.title = @"Backup Details";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeDetails)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareBackup)];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 142)];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:healthy ? @"checkmark.shield.fill" : @"exclamationmark.triangle.fill"]];
    icon.tintColor = healthy ? UIColor.systemGreenColor : UIColor.systemOrangeColor; icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [UILabel new]; title.text = healthy ? @"Backup Verified" : @"Backup Needs Attention"; title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; title.adjustsFontForContentSizeCategory = YES; title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *detail = [UILabel new]; detail.text = healthy ? @"Integrity checks passed. You can safely check the restore plan." : @"Review the backup before using it on another device."; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; detail.adjustsFontForContentSizeCategory = YES; detail.textColor = UIColor.secondaryLabelColor; detail.textAlignment = NSTextAlignmentCenter; detail.numberOfLines = 2; detail.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:icon]; [header addSubview:title]; [header addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[icon.topAnchor constraintEqualToAnchor:header.topAnchor constant:12], [icon.centerXAnchor constraintEqualToAnchor:header.centerXAnchor], [icon.widthAnchor constraintEqualToConstant:42], [icon.heightAnchor constraintEqualToConstant:42], [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8], [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20], [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4], [detail.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:28], [detail.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-28]]];
    self.tableView.tableHeaderView = header;
}
- (void)closeDetails { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)shareBackup { dispatch_block_t handler = self.shareHandler; [self dismissViewControllerAnimated:YES completion:handler]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1 + self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return self.compareHandler ? 2 : 1;
    return [self.sections[section - 1][@"items"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"ACTIONS" : self.sections[section - 1][@"title"]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section == (NSInteger)self.sections.count ? @"Inspection and readiness checks are read-only. No packages or sources are changed." : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup-action"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup-action"];
        BOOL healthy = [self.report[@"health"] isEqualToString:@"Healthy"]; BOOL planRow = indexPath.row == 0;
        cell.textLabel.text = planRow ? (healthy ? @"Check Restore Plan" : @"Restore Check Unavailable") : @"Compare with Next Backup";
        cell.detailTextLabel.text = planRow ? (healthy ? @"Check versions, protections, holds, and package-manager safety." : @"Only a healthy, verified backup can be checked.") : @"See aggregate changes between these backups.";
        cell.detailTextLabel.numberOfLines = 2; cell.imageView.image = [UIImage systemImageNamed:planRow ? (healthy ? @"checkmark.shield" : @"exclamationmark.shield") : @"arrow.left.arrow.right"];
        cell.imageView.tintColor = planRow ? (healthy ? UIColor.systemBlueColor : UIColor.systemOrangeColor) : UIColor.secondaryLabelColor; cell.accessoryType = (planRow && !healthy) ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = (planRow && !healthy) ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault; return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup-detail"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"backup-detail"];
    NSDictionary *item = self.sections[indexPath.section - 1][@"items"][indexPath.row]; cell.textLabel.text = item[@"title"]; cell.detailTextLabel.text = item[@"value"]; cell.imageView.image = [UIImage systemImageNamed:item[@"symbol"]]; cell.imageView.tintColor = UIColor.systemBlueColor; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section != 0) return;
    BOOL healthy = [self.report[@"health"] isEqualToString:@"Healthy"];
    if (indexPath.row == 0) { if (healthy && self.checkPlanHandler) self.checkPlanHandler(); return; }
    if (self.compareHandler) self.compareHandler();
}
@end


@interface ATMBackupsController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSURL *> *allBackups;
@property(nonatomic, copy) NSArray<NSURL *> *backups;
@property(nonatomic, strong) UISearchController *backupSearchController;
@property(nonatomic, assign) NSInteger sortMode;
@property(nonatomic, strong, nullable) NSURL *pendingImportURL;
@property(nonatomic, assign) BOOL processingPendingImport;
- (void)beginImportFromURL:(NSURL *)url;
- (void)consumeNextPendingImport;
- (void)confirmRestoreManifest:(NSDictionary *)manifest plan:(NSDictionary *)plan;
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
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self consumeNextPendingImport]; }
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
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Import securely through the Files share sheet." : @"Tap a backup to verify it and check restore readiness."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"backup"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"backup"]; cell.imageView.tintColor = UIColor.systemBlueColor;
    if (indexPath.section == 0) { cell.textLabel.text = @"Import Backup"; cell.detailTextLabel.text = @"In Files, Share → Save to AAZ Tweak Manager"; cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault; return cell; }
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ NSError *error = nil; NSDictionary *report = [ATMAppModel.shared.backupManager backupReportForURL:url password:password error:&error]; dispatch_async(dispatch_get_main_queue(), ^{ [progress dismissViewControllerAnimated:YES completion:^{ if (!report) { ATMShowError(self, @"Backup could not be inspected", error); return; } [self presentBackupReport:report forURL:url password:password]; }]; }); });
}
- (void)presentBackupReport:(NSDictionary *)report forURL:(NSURL *)url password:(NSString *)password {
    NSDictionary *manifest = report[@"manifest"]; NSMutableDictionary *installed = [NSMutableDictionary dictionary]; for (ATMPackageRecord *record in ATMAppModel.shared.packages) installed[record.packageID] = record.version;
    NSUInteger ready = 0, missing = 0, different = 0, unavailable = 0; for (NSDictionary *package in manifest[@"packages"]) { NSString *current = installed[package[@"packageID"] ?: @""]; if (!current) missing++; else if (![current isEqualToString:package[@"version"] ?: @""]) different++; else ready++; if ([package[@"debStatus"] isEqualToString:@"unavailable"]) unavailable++; }
    NSUInteger index = [self.backups indexOfObject:url]; NSURL *comparisonURL = (![report[@"encrypted"] boolValue] && index != NSNotFound && index + 1 < self.backups.count && ![ATMAppModel.shared.backupManager isEncryptedBackup:self.backups[index + 1]]) ? self.backups[index + 1] : nil;
    ATMBackupDetailsController *details = [[ATMBackupDetailsController alloc] initWithReport:report ready:ready missing:missing different:different unavailable:unavailable];
    __weak typeof(self) weakSelf = self; __weak ATMBackupDetailsController *weakDetails = details;
    details.shareHandler = ^{ [weakSelf shareURL:url]; };
    details.checkPlanHandler = ^{ [weakDetails dismissViewControllerAnimated:YES completion:^{ [weakSelf checkRestorePlanForManifest:manifest backupURL:url password:password]; }]; };
    if (comparisonURL) details.compareHandler = ^{ [weakDetails dismissViewControllerAnimated:YES completion:^{ [weakSelf compareBackup:comparisonURL with:url]; }]; };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:details]; navigation.modalPresentationStyle = UIModalPresentationFormSheet; [self presentViewController:navigation animated:YES completion:nil];
}
- (void)checkRestorePlanForManifest:(NSDictionary *)manifest backupURL:(NSURL *)backupURL password:(NSString *)password {
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Checking Restore Plan" message:@"Checking versions, protections, holds, and package-manager safety…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *plan = [ATMAppModel.shared.backupManager restoreReadinessForBackupURL:backupURL password:password installedPackages:ATMAppModel.shared.packages error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!plan) { ATMShowError(self, @"Restore plan unavailable", error); return; }
                ATMRestoreReadinessController *result = [[ATMRestoreReadinessController alloc] initWithPlan:plan];
                __weak typeof(self) weakSelf = self; __weak ATMRestoreReadinessController *weakResult = result;
                result.restoreHandler = ^{ [weakResult dismissViewControllerAnimated:YES completion:^{ [weakSelf confirmRestoreManifest:manifest plan:plan]; }]; };
                result.cancelHandler = ^{ [ATMAppModel.shared.backupManager discardRestoreSession]; };
                UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:result];
                navigation.modalPresentationStyle = UIModalPresentationFormSheet;
                [self presentViewController:navigation animated:YES completion:nil];
            }];
        });
    });
}
- (void)confirmRestoreManifest:(NSDictionary *)manifest plan:(NSDictionary *)plan {
    if (![plan[@"safeToExecute"] boolValue]) return;
    NSString *mode = [plan[@"embeddedRequests"] unsignedIntegerValue] == [plan[@"executionRequests"] count] ? @"verified DEBs embedded in this backup" : @"authenticated repositories";
    NSString *message = [NSString stringWithFormat:@"Install %@ approved package action(s) using %@?\n\nThe plan will be rechecked immediately. Restore will stop on any drift, removal, downgrade, hold, protected package, unavailable exact package, unexpected dependency action, or insecure repository. Sources will not be changed.", [plan[@"executionRequests"] count] ? @([plan[@"executionRequests"] count]) : @0, mode];
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:@"Final Restore Confirmation" message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [ATMAppModel.shared.backupManager discardRestoreSession]; }]];
    __weak typeof(self) weakSelf = self;
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Restore Now" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Restoring Packages" message:@"Rechecking the approved plan, then installing without removals, downgrades, or source changes…" preferredStyle:UIAlertControllerStyleAlert];
        [weakSelf presentViewController:progress animated:YES completion:nil];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary *result = [ATMAppModel.shared.backupManager executeRestoreForManifest:manifest expectedPlan:plan error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:YES completion:^{
                    if (!result) { ATMShowError(weakSelf, @"Restore did not start", error); return; }
                    BOOL success = [result[@"success"] boolValue];
                    NSString *detail = [NSString stringWithFormat:@"%@\n\nRestore code: %@\nPackage-manager exit: %@\nRequested: %@\nCompleted: %@\nRemaining: %@\nFinal verification: %@\nPackages removed: 0\nSources changed: No", result[@"reason"] ?: @"Restore stopped.", result[@"restoreCode"] ?: @"R37-UNKNOWN", result[@"aptExitCode"] ?: @(-1), result[@"requested"] ?: @0, result[@"completed"] ?: @0, result[@"remaining"] ?: @0, [result[@"postCheckPassed"] boolValue] ? @"Passed" : @"Not passed"];
                    UIAlertController *summary = [UIAlertController alertControllerWithTitle:success ? @"Restore Completed" : @"Restore Needs Attention" message:detail preferredStyle:UIAlertControllerStyleAlert];
                    [summary addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:nil]];
                    [weakSelf presentViewController:summary animated:YES completion:nil];
                }];
            });
        });
    }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}
- (void)compareBackup:(NSURL *)older with:(NSURL *)newer { NSError *error = nil; NSDictionary *result = [ATMAppModel.shared.backupManager compareBackup:older withBackup:newer error:&error]; if (!result) { ATMShowError(self, @"Comparison unavailable", error); return; } NSString *message = [NSString stringWithFormat:@"Added: %@\nRemoved: %@\nUpdated: %@\nUnchanged: %@", result[@"added"], result[@"removed"], result[@"updated"], result[@"unchanged"]]; UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Backup Changes" message:message preferredStyle:UIAlertControllerStyleAlert]; [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:alert animated:YES completion:nil]; }
- (void)importBackup {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import from Files" message:@"Open the backup in Files, tap Share, then choose Save to AAZ Tweak Manager. The Share Extension creates a private local copy before this app validates and imports it." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)consumeNextPendingImport {
    if (self.processingPendingImport || self.pendingImportURL || self.presentedViewController) return;
    NSURL *url = ATMAppModel.shared.backupManager.pendingImportURLs.firstObject;
    if (!url) return;
    self.processingPendingImport = YES;
    ATMClearImportDiagnosticTrace();
    ATMSetImportDiagnosticState(@"share-extension-received", 0);
    [self beginImportFromURL:url];
}
- (void)beginImportFromURL:(NSURL *)url {
    BOOL pendingSource = [ATMAppModel.shared.backupManager isPendingImportURL:url];
    BOOL accessStarted = [url startAccessingSecurityScopedResource];
    ATMRecordImportDiagnosticEvent(accessStarted ? @"security-scope-granted" : @"security-scope-not-required");
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Importing Backup" message:@"Preparing the selected file…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *staged = [ATMAppModel.shared.backupManager stageImportFromURL:url error:&error];
        if (staged && pendingSource) [ATMAppModel.shared.backupManager discardPendingImportAtURL:url];
        if (accessStarted) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                self.processingPendingImport = NO;
                if (!staged) { ATMShowError(self, @"Import could not start", error); return; }
                self.pendingImportURL = staged;
                if ([ATMAppModel.shared.backupManager isEncryptedBackup:staged]) [self promptForImportPasswordForURL:staged];
                else [self performImport:staged password:nil];
            }];
        });
    });
}
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
- (void)reload { self.tableView.backgroundView = ATMAppModel.shared.sources.count ? nil : ATMEmptyStateView(@"link.badge.plus", @"No Sources Found", @"Add a repository in Sileo or Zebra, then refresh this screen."); [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.sources.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.sources.count ? [NSString stringWithFormat:@"%lu SOURCE%@", (unsigned long)ATMAppModel.shared.sources.count, ATMAppModel.shared.sources.count == 1 ? @"" : @"S"] : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return ATMAppModel.shared.sources.count ? @"Private credentials are removed before a source is added to a backup." : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"source"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];
    ATMSourceRecord *source = ATMAppModel.shared.sources[indexPath.row];
    NSError *detectorError = nil; NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:&detectorError]; NSTextCheckingResult *match = detectorError ? nil : [detector firstMatchInString:source.sanitizedContents options:0 range:NSMakeRange(0, source.sanitizedContents.length)]; NSString *host = match.URL.host;
    cell.textLabel.text = host.length ? host : (source.relativePath.lastPathComponent.length ? source.relativePath.lastPathComponent : @"Repository Source");
    NSString *state = source.enabled ? @"Enabled" : @"Disabled"; cell.detailTextLabel.text = source.credentialsRedacted ? [NSString stringWithFormat:@"%@ • Private credentials removed from backups", state] : state; cell.detailTextLabel.numberOfLines = 2;
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
    self.tableView.backgroundView = ATMEmptyStateView(self.filterControl.selectedSegmentIndex ? @"line.3.horizontal.decrease.circle" : @"clock.arrow.circlepath", self.filterControl.selectedSegmentIndex ? @"No Matching Activity" : @"No Activity Yet", self.filterControl.selectedSegmentIndex ? @"Choose another filter." : @"Selections, package changes, profiles, and backups appear here.");
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
    else if ([event isEqualToString:@"restore-completed"]) { title = @"Restore Completed"; summary = [NSString stringWithFormat:@"%@ package actions completed • final check passed", details[@"completed"] ?: @0]; symbol = @"checkmark.shield.fill"; }
    else if ([event isEqualToString:@"restore-stopped"]) { title = @"Restore Stopped"; summary = [NSString stringWithFormat:@"%@ completed • %@ remaining • %@", details[@"completed"] ?: @0, details[@"remaining"] ?: @0, details[@"restoreCode"] ?: @"R37-UNKNOWN"]; symbol = @"exclamationmark.shield.fill"; }
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; if (section == 2) return 3; if (section == 3 || section == 4) return 2; return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return @[@"Package List", @"Selection Profiles", @"Protection", @"Troubleshooting", @"About"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 3) return @"Turn this on only when an import problem needs troubleshooting. Reports never include filenames, paths, providers, passwords, or archive contents.";
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
        NSArray *titles = @[@"Rootless Compatible", @"Private by Design", @"Guarded Restore"];
        NSArray *details = @[@"Uses the Rootless package database.", @"Passwords and repository credentials never enter backups.", @"Rechecks every approved plan and refuses removals, downgrades, or source changes."];
        cell.textLabel.text = titles[indexPath.row]; cell.detailTextLabel.text = details[indexPath.row]; cell.detailTextLabel.numberOfLines = 2; cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield"];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        cell.textLabel.text = @"Import Troubleshooting";
        cell.detailTextLabel.text = ATMImportDiagnosticsEnabled() ? @"On — the next report includes safe progress stages." : @"Off — recommended for normal use.";
        UISwitch *toggle = [UISwitch new]; toggle.on = ATMImportDiagnosticsEnabled(); [toggle addTarget:self action:@selector(importDiagnosticsChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else if (indexPath.section == 3) {
        cell.textLabel.text = @"Share Troubleshooting Report";
        cell.detailTextLabel.text = @"Create a privacy-safe report for support.";
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
    if (indexPath.section != 3 || indexPath.row != 1) return;
    NSError *error = nil;
    ATMAppModel *model = ATMAppModel.shared;
    NSURL *url = ATMWriteDiagnosticReport(model.environment, model.packages, model.ledger.selectedPackageIDs, model.scanError, &error);
    if (!url) { ATMShowError(self, @"Diagnostic unavailable", error); return; }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}
- (void)importDiagnosticsChanged:(UISwitch *)sender { ATMSetImportDiagnosticsEnabled(sender.isOn); [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3] withRowAnimation:UITableViewRowAnimationNone]; }
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

BOOL ATMHandlePendingImport(UIViewController *rootController) {
    if (![rootController isKindOfClass:UITabBarController.class] || !ATMAppModel.shared.backupManager.pendingImportURLs.count) return NO;
    UITabBarController *tabs = (UITabBarController *)rootController;
    if (tabs.viewControllers.count < 2 || ![tabs.viewControllers[1] isKindOfClass:UINavigationController.class]) return NO;
    UINavigationController *navigation = (UINavigationController *)tabs.viewControllers[1];
    if (![navigation.viewControllers.firstObject isKindOfClass:ATMBackupsController.class]) return NO;
    ATMBackupsController *backups = (ATMBackupsController *)navigation.viewControllers.firstObject;
    tabs.selectedIndex = 1;
    [navigation popToRootViewControllerAnimated:NO];
    [backups loadViewIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{ [backups consumeNextPendingImport]; });
    return YES;
}
