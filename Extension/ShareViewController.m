#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

static NSString *const ATMImportGroup = @"group.com.aaz.tweakmanager";

static BOOL ATMWriteAll(int descriptor, const uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        offset += (size_t)written;
    }
    return YES;
}

static BOOL ATMHasBackupHeader(const uint8_t *bytes, size_t length) {
    if (length >= 2 && bytes[0] == 'P' && bytes[1] == 'K') return YES;
    static const uint8_t encryptedHeader[] = {'A', 'A', 'Z', 'T', 'M', 'E', '0', '1'};
    return length >= sizeof(encryptedHeader) && memcmp(bytes, encryptedHeader, sizeof(encryptedHeader)) == 0;
}

static BOOL ATMMaterializeBackup(NSURL *sourceURL) {
    if (!sourceURL.isFileURL) return NO;
    int source = open(sourceURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (source < 0) return NO;

    struct stat metadata;
    BOOL valid = fstat(source, &metadata) == 0 && S_ISREG(metadata.st_mode) && metadata.st_size > 0;
    uint8_t buffer[64 * 1024];
    ssize_t firstRead = valid ? read(source, buffer, sizeof(buffer)) : -1;
    if (firstRead <= 0 || !ATMHasBackupHeader(buffer, (size_t)firstRead)) valid = NO;

    NSURL *groupURL = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ATMImportGroup];
    NSURL *inboxURL = [groupURL URLByAppendingPathComponent:@"ImportInbox" isDirectory:YES];
    if (!groupURL || ![NSFileManager.defaultManager createDirectoryAtURL:inboxURL
                                              withIntermediateDirectories:YES
                                                               attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                                    error:nil]) valid = NO;

    NSString *identifier = NSUUID.UUID.UUIDString;
    NSURL *partialURL = [inboxURL URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", identifier]];
    NSURL *finalURL = [inboxURL URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"aaztmbackup"]];
    int destination = -1;
    if (valid) destination = open(partialURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (destination < 0) valid = NO;

    if (valid && !ATMWriteAll(destination, buffer, (size_t)firstRead)) valid = NO;
    while (valid) {
        ssize_t count = read(source, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (count == 0) break;
        if (!ATMWriteAll(destination, buffer, (size_t)count)) valid = NO;
    }
    if (destination >= 0 && fsync(destination) != 0) valid = NO;
    if (destination >= 0) close(destination);
    close(source);

    if (valid && rename(partialURL.fileSystemRepresentation, finalURL.fileSystemRepresentation) != 0) valid = NO;
    if (!valid) {
        unlink(partialURL.fileSystemRepresentation);
        return NO;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                    ofItemAtPath:finalURL.path
                                           error:nil];
    return YES;
}

@interface AAZShareViewController : UIViewController
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, assign) BOOL started;
@end

@implementation AAZShareViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Preparing backup…";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner startAnimating];
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.closeButton.hidden = YES;
    [self.closeButton setTitle:@"Done" forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.spinner];
    [self.view addSubview:self.closeButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24.0],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:18.0],
        [self.closeButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.closeButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:18.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) return;
    self.started = YES;
    [self loadSharedBackup];
}

- (void)loadSharedBackup {
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (NSExtensionItem *item in self.extensionContext.inputItems) {
        if ([item isKindOfClass:NSExtensionItem.class]) [providers addObjectsFromArray:item.attachments ?: @[]];
    }
    if (providers.count != 1) { [self finishWithSuccess:NO]; return; }

    NSItemProvider *provider = providers.firstObject;
    NSArray<NSString *> *types = @[@"com.aaz.tweakmanager.backup", @"public.archive", @"public.data", @"public.item"];
    NSString *selectedType = nil;
    for (NSString *type in types) if ([provider hasItemConformingToTypeIdentifier:type]) { selectedType = type; break; }
    if (!selectedType) { [self finishWithSuccess:NO]; return; }

    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:selectedType completionHandler:^(NSURL *url, NSError *error) {
        BOOL saved = !error && ATMMaterializeBackup(url);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishWithSuccess:saved]; });
    }];
}

- (void)finishWithSuccess:(BOOL)success {
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.closeButton.hidden = NO;
    self.statusLabel.text = success
        ? @"Backup saved. Open AAZ Tweak Manager to verify and import it."
        : @"Could not prepare this backup.";
}

- (void)finish {
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}

@end
