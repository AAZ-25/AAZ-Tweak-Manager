#import "ATMRestorePlanner.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;
NSString *const ATMRestorePlannerErrorDomain = @"com.aaz.tweakmanager.restore-plan";

static NSError *ATMRestorePlanError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ATMRestorePlannerErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ATMRestorePackageIDIsValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 128) return NO;
    static NSRegularExpression *expression; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9][a-z0-9+.-]*$" options:0 error:nil]; });
    return [expression numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1;
}

static BOOL ATMRestoreVersionIsValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 256) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound &&
           [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSString *ATMRestoreExecutable(ATMEnvironment *environment, NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        NSString *candidate = [environment pathInsideRoot:path];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSDictionary *ATMRestoreRun(NSString *tool, NSArray<NSString *> *arguments) {
    int outputPipe[2];
    if (pipe(outputPipe) != 0) return @{ @"exitCode": @(-1), @"output": @"" };
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    NSMutableArray<NSData *> *storage = [NSMutableArray array];
    NSMutableArray<NSValue *> *pointers = [NSMutableArray array];
    NSArray<NSString *> *all = [@[tool] arrayByAddingObjectsFromArray:arguments];
    for (NSString *item in all) {
        NSData *data = [[item stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data];
        [pointers addObject:[NSValue valueWithPointer:(void *)data.bytes]];
    }
    char **argv = calloc(pointers.count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < pointers.count; index++) argv[index] = [pointers[index] pointerValue];
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, argv, environ);
    free(argv); posix_spawn_file_actions_destroy(&actions); close(outputPipe[1]);
    if (spawnResult != 0) { close(outputPipe[0]); return @{ @"exitCode": @(spawnResult), @"output": @"" }; }
    NSMutableData *captured = [NSMutableData data]; uint8_t buffer[8192]; ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
        if (captured.length + (NSUInteger)count > 1024 * 1024) { kill(pid, SIGKILL); break; }
        [captured appendBytes:buffer length:(NSUInteger)count];
    }
    close(outputPipe[0]); int status = 0; waitpid(pid, &status, 0);
    NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSString *output = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding] ?: @"";
    return @{ @"exitCode": @(exitCode), @"output": output };
}

static NSDictionary *ATMRestoreHeldPackages(ATMEnvironment *environment) {
    NSString *tool = ATMRestoreExecutable(environment, @[@"/usr/bin/apt-mark", @"/bin/apt-mark"]);
    if (!tool) return @{ @"available": @NO, @"success": @NO, @"packages": [NSSet set] };
    NSDictionary *result = ATMRestoreRun(tool, @[@"showhold"]);
    if ([result[@"exitCode"] integerValue] != 0) return @{ @"available": @YES, @"success": @NO, @"packages": [NSSet set] };
    NSMutableSet *held = [NSMutableSet set];
    [result[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        NSString *value = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ATMRestorePackageIDIsValid(value)) [held addObject:value];
    }];
    return @{ @"available": @YES, @"success": @YES, @"packages": held };
}

@interface ATMRestorePlanner ()
@property(nonatomic, strong) ATMEnvironment *environment;
@end

@implementation ATMRestorePlanner
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment { if ((self = [super init])) _environment = environment; return self; }

- (NSDictionary *)planForManifest:(NSDictionary *)manifest installedPackages:(NSArray<ATMPackageRecord *> *)installed error:(NSError **)error {
    if (!self.environment.supportedRootless || ![manifest[@"rootless"] boolValue] || ![manifest[@"architecture"] isEqualToString:@"iphoneos-arm64"]) {
        if (error) *error = ATMRestorePlanError(70, @"This backup does not match the supported Rootless target.");
        return nil;
    }
    NSArray *packages = [manifest[@"packages"] isKindOfClass:NSArray.class] ? manifest[@"packages"] : nil;
    if (!packages.count || packages.count > 500) { if (error) *error = ATMRestorePlanError(71, @"The backup package list is invalid."); return nil; }
    NSMutableDictionary *installedByID = [NSMutableDictionary dictionary];
    for (ATMPackageRecord *record in installed) if (record.packageID.length) installedByID[record.packageID] = record;
    NSDictionary *holdCheck = ATMRestoreHeldPackages(self.environment);
    NSSet *protected = ATMProtectedPackageIDs(), *held = holdCheck[@"packages"];
    NSString *dpkg = ATMRestoreExecutable(self.environment, @[@"/usr/bin/dpkg", @"/bin/dpkg"]);
    NSString *aptCache = ATMRestoreExecutable(self.environment, @[@"/usr/bin/apt-cache", @"/bin/apt-cache"]);
    NSMutableArray<NSString *> *requests = [NSMutableArray array];
    NSUInteger alreadyInstalled = 0, missing = 0, versionChanges = 0, updatesNeeded = 0, newerVersionsKept = 0, payloads = 0, unavailablePayloads = 0, heldCount = 0, metadataUnavailable = 0, protectedOrInvalid = 0, prerequisiteFailures = 0, blockedCount = 0;
    for (id object in packages) {
        if (![object isKindOfClass:NSDictionary.class]) { protectedOrInvalid++; blockedCount++; continue; }
        NSDictionary *package = object;
        NSString *packageID = package[@"packageID"], *version = package[@"version"];
        NSString *architecture = [package[@"architecture"] isKindOfClass:NSString.class] ? package[@"architecture"] : @"";
        NSString *priority = [package[@"priority"] isKindOfClass:NSString.class] ? [package[@"priority"] lowercaseString] : @"";
        BOOL invalid = !ATMRestorePackageIDIsValid(packageID) || !ATMRestoreVersionIsValid(version) ||
            (![architecture isEqualToString:@"iphoneos-arm64"] && ![architecture isEqualToString:@"all"]) ||
            [package[@"essential"] boolValue] || [@[@"required", @"important"] containsObject:priority] ||
            [protected containsObject:packageID.lowercaseString];
        if (invalid) { protectedOrInvalid++; blockedCount++; continue; }
        ATMPackageRecord *current = installedByID[packageID];
        if (current && [current.version isEqualToString:version]) { alreadyInstalled++; continue; }
        if (current) {
            versionChanges++;
            if (!dpkg.length) { prerequisiteFailures++; blockedCount++; continue; }
            NSDictionary *comparison = ATMRestoreRun(dpkg, @[@"--compare-versions", current.version ?: @"", @"gt", version]);
            NSInteger comparisonCode = [comparison[@"exitCode"] integerValue];
            if (comparisonCode == 0) { newerVersionsKept++; continue; }
            if (comparisonCode != 1) { prerequisiteFailures++; blockedCount++; continue; }
            updatesNeeded++;
        } else missing++;
        if ([held containsObject:packageID]) { heldCount++; blockedCount++; continue; }
        if ([package[@"debStatus"] isEqualToString:@"exact-cache"] && [package[@"sha256"] isKindOfClass:NSString.class] && [package[@"sha256"] length] == 64) payloads++; else unavailablePayloads++;
        NSString *request = [NSString stringWithFormat:@"%@=%@", packageID, version];
        if (!aptCache.length) { metadataUnavailable++; blockedCount++; continue; }
        NSDictionary *metadataResult = ATMRestoreRun(aptCache, @[@"show", request]);
        NSArray *metadataParagraphs = ATMParseDebianParagraphs(metadataResult[@"output"]);
        NSDictionary *metadata = metadataParagraphs.firstObject;
        NSString *metadataPackage = [metadata[@"Package"] isKindOfClass:NSString.class] ? metadata[@"Package"] : @"";
        NSString *metadataVersion = [metadata[@"Version"] isKindOfClass:NSString.class] ? metadata[@"Version"] : @"";
        NSString *metadataArchitecture = [metadata[@"Architecture"] isKindOfClass:NSString.class] ? metadata[@"Architecture"] : @"";
        NSString *metadataPriority = [metadata[@"Priority"] isKindOfClass:NSString.class] ? [metadata[@"Priority"] lowercaseString] : @"";
        NSString *metadataEssential = [metadata[@"Essential"] isKindOfClass:NSString.class] ? [metadata[@"Essential"] lowercaseString] : @"no";
        BOOL metadataValid = [metadataResult[@"exitCode"] integerValue] == 0 &&
            [metadataPackage isEqualToString:packageID] && [metadataVersion isEqualToString:version] &&
            ([metadataArchitecture isEqualToString:@"iphoneos-arm64"] || [metadataArchitecture isEqualToString:@"all"]);
        BOOL metadataProtected = [metadataEssential isEqualToString:@"yes"] ||
            [@[@"required", @"important"] containsObject:metadataPriority] || [protected containsObject:metadataPackage.lowercaseString];
        if (!metadataValid) { metadataUnavailable++; blockedCount++; continue; }
        if (metadataProtected) { protectedOrInvalid++; blockedCount++; continue; }
        [requests addObject:request];
    }
    if (![holdCheck[@"success"] boolValue]) { prerequisiteFailures++; blockedCount++; }
    NSString *aptGet = ATMRestoreExecutable(self.environment, @[@"/usr/bin/apt-get", @"/bin/apt-get"]);
    BOOL attempted = aptGet.length && blockedCount == 0;
    __block NSUInteger installActions = 0, configureActions = 0, removalActions = 0, errorLines = 0;
    NSInteger exitCode = -1;
    if (attempted) {
        NSMutableArray *arguments = [@[@"--simulate", @"--no-remove", @"--assume-no", @"--no-install-recommends", @"-o", @"APT::Get::AllowUnauthenticated=false", @"-o", @"Acquire::AllowInsecureRepositories=false", @"-o", @"Debug::NoLocking=true"] mutableCopy];
        if (requests.count) { [arguments addObject:@"install"]; [arguments addObjectsFromArray:requests]; }
        else [arguments addObject:@"check"];
        NSDictionary *result = ATMRestoreRun(aptGet, arguments); exitCode = [result[@"exitCode"] integerValue];
        [result[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if ([line hasPrefix:@"Inst "]) installActions++;
            else if ([line hasPrefix:@"Conf "]) configureActions++;
            else if ([line hasPrefix:@"Remv "]) removalActions++;
            else if ([line hasPrefix:@"E:"]) errorLines++;
        }];
    }
    BOOL simulationPassed = attempted && exitCode == 0 && removalActions == 0 && errorLines == 0;
    BOOL alreadySatisfied = requests.count == 0 && blockedCount == 0;
    NSString *reason = ![holdCheck[@"success"] boolValue] ? @"The held-package safety check could not be completed." :
        (blockedCount ? @"Resolve the listed safety checks before Restore." :
        (!aptGet.length ? @"The package-manager safety check is unavailable." :
        (!simulationPassed ? @"The package manager could not produce a safe, removal-free plan." :
        (alreadySatisfied && newerVersionsKept ? @"All required packages are installed. Newer installed versions will be kept." :
        (alreadySatisfied ? @"All backup package versions are installed and the safety check passed." :
        @"The restore preview completed safely without removals.")))));
    return @{ @"packageCount": @(packages.count), @"alreadyInstalled": @(alreadyInstalled), @"missing": @(missing), @"versionChanges": @(versionChanges), @"updatesNeeded": @(updatesNeeded), @"newerVersionsKept": @(newerVersionsKept),
              @"exactPayloads": @(payloads), @"payloadUnavailable": @(unavailablePayloads), @"held": @(heldCount), @"blocked": @(blockedCount),
              @"protectedOrInvalid": @(protectedOrInvalid), @"metadataUnavailable": @(metadataUnavailable), @"prerequisiteFailures": @(prerequisiteFailures),
              @"holdCheckPassed": holdCheck[@"success"],
              @"simulationAttempted": @(attempted), @"simulationPassed": @(simulationPassed), @"aptExitCode": @(exitCode),
              @"installActions": @(installActions), @"configureActions": @(configureActions), @"removalActions": @(removalActions),
              @"safeToExecute": @NO, @"reason": reason };
}
@end
