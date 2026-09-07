#import "ATMBackupManager.h"
#import "ATMZipWriter.h"
#import <spawn.h>
#import <signal.h>
#import <sys/utsname.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString *const ATMBackupErrorDomain = @"com.aaz.tweakmanager.backup";

@interface ATMBackupManager ()
@property(nonatomic, strong) ATMEnvironment *environment;
@property(nonatomic, strong) ATMPersonalLedger *ledger;
@end

static NSString *ATMRunDPKGDebField(ATMEnvironment *environment, NSURL *debURL) {
    NSArray *candidates = @[[environment pathInsideRoot:@"/usr/bin/dpkg-deb"], [environment pathInsideRoot:@"/bin/dpkg-deb"]];
    NSString *tool = nil;
    for (NSString *candidate in candidates) if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { tool = candidate; break; }
    if (!tool) return @"";
    int outputPipe[2]; if (pipe(outputPipe) != 0) return @"";
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    char *const arguments[] = {(char *)tool.fileSystemRepresentation, "--field", (char *)debURL.path.fileSystemRepresentation, NULL};
    pid_t pid = 0; int spawnResult = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions); close(outputPipe[1]);
    if (spawnResult != 0) { close(outputPipe[0]); return @""; }
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[8192]; ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
        if (data.length + (NSUInteger)count > 1024 * 1024) { kill(pid, SIGKILL); break; }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(outputPipe[0]); int status = 0; waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation ATMBackupManager
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger {
    if ((self = [super init])) { _environment = environment; _ledger = ledger; }
    return self;
}
- (NSURL *)backupDirectory {
    NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/Backups" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    return directory;
}
- (NSArray<NSURL *> *)availableBackups {
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.backupDirectory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { (void)bindings; return [url.pathExtension.lowercaseString isEqualToString:@"aaztmbackup"]; }];
    return [[files filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *ad = nil, *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];
        return [bd ?: NSDate.distantPast compare:ad ?: NSDate.distantPast];
    }];
}
- (NSDictionary<NSString *, NSURL *> *)cachedPackagesByIdentity {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.environment.aptCachePath isDirectory:YES] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *url in files) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"deb"]) continue;
        NSDictionary *fields = ATMParseDebianParagraph(ATMRunDPKGDebField(self.environment, url));
        NSString *packageID = fields[@"Package"] ?: @"";
        NSString *version = fields[@"Version"] ?: @"";
        if (!packageID.length || !version.length) continue;
        result[[NSString stringWithFormat:@"%@\n%@", packageID, version]] = url;
    }
    return result;
}
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources error:(NSError **)error {
    NSSet *selected = self.ledger.selectedPackageIDs;
    NSArray *chosen = [packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return [selected containsObject:record.packageID]; }]];
    if (!chosen.count) {
        if (error) *error = [NSError errorWithDomain:ATMBackupErrorDomain code:30 userInfo:@{NSLocalizedDescriptionKey: @"No personal packages are selected."}];
        return nil;
    }
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSURL *archiveURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"AAZ-Tweak-Backup-%@.aaztmbackup", stamp]];
    ATMZipWriter *writer = [[ATMZipWriter alloc] initWithDestinationURL:archiveURL error:error];
    if (!writer) return nil;
    NSDictionary *cache = [self cachedPackagesByIdentity];
    NSMutableArray *packageManifest = [NSMutableArray array];
    for (ATMPackageRecord *record in chosen) {
        NSMutableDictionary *entry = [[record manifestDictionary] mutableCopy];
        NSDate *firstSeen = [self.ledger firstSeenDateForPackageID:record.packageID];
        if (firstSeen) entry[@"firstSeen"] = ATMISODateString(firstSeen);
        NSURL *debURL = cache[[NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]];
        if (debURL) {
            NSString *safeName = [record.packageID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            NSString *archivePath = [NSString stringWithFormat:@"packages/%@_%@.deb", safeName, record.version];
            NSError *hashError = nil;
            NSString *sha = ATMSHA256ForFile(debURL, &hashError);
            if (!hashError && sha.length && [writer addFileURL:debURL path:archivePath error:error]) {
                entry[@"debPath"] = archivePath; entry[@"sha256"] = sha; entry[@"debStatus"] = @"exact-cache";
            } else { entry[@"debStatus"] = @"unavailable"; }
        } else entry[@"debStatus"] = @"unavailable";
        [packageManifest addObject:entry];
    }
    NSMutableArray *sourceManifest = [NSMutableArray array];
    NSUInteger sourceIndex = 0;
    for (ATMSourceRecord *source in sources) {
        NSMutableDictionary *entry = [[source manifestDictionary] mutableCopy];
        NSString *extension = source.relativePath.pathExtension.length ? source.relativePath.pathExtension : @"list";
        NSString *archivePath = [NSString stringWithFormat:@"sources/%03lu.%@", (unsigned long)sourceIndex++, extension];
        NSData *data = [source.sanitizedContents dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        if (![writer addData:data path:archivePath error:error]) { [NSFileManager.defaultManager removeItemAtURL:archiveURL error:nil]; return nil; }
        entry[@"backupPath"] = archivePath; [sourceManifest addObject:entry];
    }
    struct utsname systemInfo; uname(&systemInfo);
    NSDictionary *manifest = @{ @"format": @"com.aaz.tweakmanager.backup", @"formatVersion": @1,
                                @"createdAt": ATMISODateString([NSDate date]), @"rootless": @YES,
                                @"jailbreakPrefix": self.environment.jailbreakRoot ?: @"",
                                @"iOSVersion": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
                                @"architecture": [NSString stringWithUTF8String:systemInfo.machine] ?: @"unknown",
                                @"packages": packageManifest, @"sources": sourceManifest,
                                @"credentialsIncluded": @NO, @"restoreExecutionIncluded": @NO };
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!manifestData || ![writer addData:manifestData path:@"manifest.json" error:error] || ![writer close:error]) {
        [NSFileManager.defaultManager removeItemAtURL:archiveURL error:nil]; return nil;
    }
    [self.ledger recordEvent:@"backup-created" packageID:nil details:@{ @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"file": archiveURL.lastPathComponent }];
    return archiveURL;
}
- (NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error {
    NSData *data = ATMReadStoredZipEntry(backupURL, @"manifest.json", error);
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1) {
        if (error && !*error) *error = [NSError errorWithDomain:ATMBackupErrorDomain code:31 userInfo:@{NSLocalizedDescriptionKey: @"Unsupported or invalid backup."}];
        return nil;
    }
    return manifest;
}
- (NSDictionary *)restorePreviewForBackup:(NSURL *)backupURL installedPackages:(NSArray<ATMPackageRecord *> *)installed error:(NSError **)error {
    NSDictionary *manifest = [self manifestForBackup:backupURL error:error];
    if (!manifest) return @{};
    NSMutableDictionary *installedByID = [NSMutableDictionary dictionary];
    for (ATMPackageRecord *record in installed) installedByID[record.packageID] = record;
    NSMutableArray *missing = [NSMutableArray array], *different = [NSMutableArray array], *present = [NSMutableArray array], *unavailable = [NSMutableArray array];
    for (NSDictionary *package in manifest[@"packages"] ?: @[]) {
        NSString *packageID = package[@"packageID"] ?: @"";
        ATMPackageRecord *current = installedByID[packageID];
        if (!current) [missing addObject:packageID];
        else if (![current.version isEqualToString:package[@"version"] ?: @""]) [different addObject:packageID];
        else [present addObject:packageID];
        if ([package[@"debStatus"] isEqualToString:@"unavailable"]) [unavailable addObject:packageID];
    }
    return @{ @"missing": missing, @"differentVersion": different, @"alreadyInstalled": present,
              @"packagePayloadUnavailable": unavailable, @"sourceCount": @([manifest[@"sources"] count]),
              @"safeToExecute": @NO, @"reason": @"Beta 1 provides preview only; no package transaction is executed." };
}
@end
