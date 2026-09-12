#import "ATMRestorePlanner.h"
#import <spawn.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
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
    static NSRegularExpression *expression; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Za-z.+:~_-]+$" options:0 error:nil]; });
    return [expression numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1;
}

static NSString *ATMRestoreExecutable(ATMEnvironment *environment, NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        NSString *candidate = [environment pathInsideRoot:path];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSDictionary *ATMRestoreRunWithPrivilege(NSString *tool, NSArray<NSString *> *arguments, BOOL asRoot) {
    int outputPipe[2];
    if (pipe(outputPipe) != 0) {
        int pipeError = errno;
        return @{ @"exitCode": @(-1), @"output": @"", @"personaError": @0, @"spawnError": @(pipeError), @"signal": @0 };
    }
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    int nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nullInput >= 0) posix_spawn_file_actions_adddup2(&actions, nullInput, STDIN_FILENO);
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
    posix_spawnattr_t attributes; posix_spawnattr_t *attributesPointer = NULL; BOOL attributesInitialized = NO;
    int personaResult = 0;
    if (asRoot) {
        personaResult = posix_spawnattr_init(&attributes); attributesInitialized = personaResult == 0;
        if (personaResult == 0) personaResult = posix_spawnattr_set_persona_np(&attributes, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        if (personaResult == 0) personaResult = posix_spawnattr_set_persona_uid_np(&attributes, 0);
        if (personaResult == 0) personaResult = posix_spawnattr_set_persona_gid_np(&attributes, 0);
        if (personaResult == 0) attributesPointer = &attributes;
    }
    char *const fixedEnvironment[] = { "PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin", "DEBIAN_FRONTEND=noninteractive", "LC_ALL=C", NULL };
    int spawnResult = personaResult != 0 ? personaResult : posix_spawn(&pid, tool.fileSystemRepresentation, &actions, attributesPointer, argv, fixedEnvironment);
    if (attributesInitialized) posix_spawnattr_destroy(&attributes);
    free(argv); posix_spawn_file_actions_destroy(&actions); close(outputPipe[1]); if (nullInput >= 0) close(nullInput);
    if (spawnResult != 0) {
        close(outputPipe[0]);
        return @{ @"exitCode": @(-1), @"output": @"", @"personaError": @(personaResult), @"spawnError": @(spawnResult), @"signal": @0 };
    }
    NSMutableData *captured = [NSMutableData data]; uint8_t buffer[8192]; ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
        NSUInteger remaining = captured.length < 1024 * 1024 ? 1024 * 1024 - captured.length : 0;
        if (remaining) [captured appendBytes:buffer length:MIN((NSUInteger)count, remaining)];
    }
    close(outputPipe[0]); int status = 0; pid_t waitResult = waitpid(pid, &status, 0);
    NSInteger signalCode = waitResult >= 0 && WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    NSInteger exitCode = waitResult >= 0 && WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSString *output = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding] ?: @"";
    return @{ @"exitCode": @(exitCode), @"output": output, @"personaError": @0, @"spawnError": @0, @"signal": @(signalCode) };
}

static BOOL ATMRestoreOutputContainsAny(NSString *output, NSArray<NSString *> *needles) {
    NSString *lowercase = [output lowercaseString];
    for (NSString *needle in needles) if ([lowercase containsString:needle]) return YES;
    return NO;
}

static NSString *ATMRestoreFailureCode(NSDictionary *run) {
    if ([run[@"personaError"] integerValue] != 0) return @"R34-PERSONA";
    if ([run[@"spawnError"] integerValue] != 0) return @"R34-SPAWN";
    if ([run[@"signal"] integerValue] != 0) return @"R34-SIGNAL";
    NSString *output = [run[@"output"] isKindOfClass:NSString.class] ? run[@"output"] : @"";
    if (ATMRestoreOutputContainsAny(output, @[@"could not get lock", @"unable to acquire the dpkg frontend lock", @"is another process using it"])) return @"R34-LOCK";
    if (ATMRestoreOutputContainsAny(output, @[@"permission denied", @"operation not permitted", @"are you root"])) return @"R34-PRIVILEGE";
    if (ATMRestoreOutputContainsAny(output, @[@"no space left on device", @"not enough free space", @"write error"] )) return @"R34-STORAGE";
    if (ATMRestoreOutputContainsAny(output, @[@"sub-process /usr/bin/dpkg returned an error code", @"dpkg: error", @"dependency problems - leaving unconfigured"])) return @"R34-DPKG";
    if (ATMRestoreOutputContainsAny(output, @[@"unmet dependencies", @"held broken packages", @"dependency problems prevent configuration"])) return @"R34-DEPENDENCY";
    if (ATMRestoreOutputContainsAny(output, @[@"unable to fetch some archives", @"failed to fetch", @"file not found", @"cannot open file"])) return @"R34-ARCHIVE";
    if (ATMRestoreOutputContainsAny(output, @[@"repository is not signed", @"does not have a release file"])) return @"R34-SOURCE-AUTH";
    if (ATMRestoreOutputContainsAny(output, @[@"temporary failure resolving", @"could not resolve", @"connection failed", @"network is unreachable"])) return @"R34-NETWORK";
    if (ATMRestoreOutputContainsAny(output, @[@"there were unauthenticated packages", @"the following packages cannot be authenticated", @"unauthenticated packages and -y was used"])) return @"R34-AUTH";
    return @"R34-APT";
}

static NSDictionary *ATMRestoreRun(NSString *tool, NSArray<NSString *> *arguments) {
    return ATMRestoreRunWithPrivilege(tool, arguments, NO);
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

static NSDictionary *ATMRestoreVerifiedPayload(ATMEnvironment *environment, NSDictionary *descriptor, NSString *packageID, NSString *version) {
    NSURL *url = [descriptor[@"url"] isKindOfClass:NSURL.class] ? descriptor[@"url"] : nil;
    NSURL *root = [descriptor[@"stagingRoot"] isKindOfClass:NSURL.class] ? descriptor[@"stagingRoot"] : nil;
    NSString *expectedHash = [descriptor[@"sha256"] isKindOfClass:NSString.class] ? [descriptor[@"sha256"] lowercaseString] : @"";
    NSString *rootPath = root.URLByStandardizingPath.path, *filePath = url.URLByStandardizingPath.path;
    BOOL insideStaging = root.isFileURL && url.isFileURL && rootPath.length && filePath.length &&
        [filePath hasPrefix:[rootPath stringByAppendingString:@"/"]];
    NSNumber *fileSize = nil; [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
    if (!insideStaging || ![NSFileManager.defaultManager isReadableFileAtPath:filePath] || fileSize.unsignedLongLongValue == 0 ||
        fileSize.unsignedLongLongValue > 256ULL * 1024ULL * 1024ULL || expectedHash.length != 64 ||
        ![ATMSHA256ForFile(url, nil).lowercaseString isEqualToString:expectedHash]) return nil;
    NSString *dpkgDeb = ATMRestoreExecutable(environment, @[@"/usr/bin/dpkg-deb", @"/bin/dpkg-deb"]);
    if (!dpkgDeb.length) return nil;
    NSDictionary *run = ATMRestoreRun(dpkgDeb, @[@"--field", filePath]);
    NSDictionary *fields = [run[@"exitCode"] integerValue] == 0 ? ATMParseDebianParagraph(run[@"output"] ?: @"") : nil;
    NSString *actualPackage = [fields[@"Package"] isKindOfClass:NSString.class] ? fields[@"Package"] : @"";
    NSString *actualVersion = [fields[@"Version"] isKindOfClass:NSString.class] ? fields[@"Version"] : @"";
    NSString *architecture = [fields[@"Architecture"] isKindOfClass:NSString.class] ? fields[@"Architecture"] : @"";
    NSString *priority = [fields[@"Priority"] isKindOfClass:NSString.class] ? [fields[@"Priority"] lowercaseString] : @"";
    NSString *essential = [fields[@"Essential"] isKindOfClass:NSString.class] ? [fields[@"Essential"] lowercaseString] : @"no";
    if (![actualPackage isEqualToString:packageID] || ![actualVersion isEqualToString:version] ||
        (![@[@"iphoneos-arm64", @"all"] containsObject:architecture]) || [essential isEqualToString:@"yes"] ||
        [@[@"required", @"important"] containsObject:priority] || [ATMProtectedPackageIDs() containsObject:actualPackage.lowercaseString]) return nil;
    return @{ @"url": url, @"packageID": actualPackage, @"version": actualVersion, @"architecture": architecture };
}

@interface ATMRestorePlanner ()
@property(nonatomic, strong) ATMEnvironment *environment;
@end

@implementation ATMRestorePlanner
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment { if ((self = [super init])) _environment = environment; return self; }

- (NSDictionary *)planForManifest:(NSDictionary *)manifest installedPackages:(NSArray<ATMPackageRecord *> *)installed exactPayloads:(NSDictionary<NSString *,NSDictionary *> *)exactPayloads error:(NSError **)error {
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
    NSMutableArray<NSDictionary *> *requestedItems = [NSMutableArray array];
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
        NSDictionary *metadataResult = aptCache.length ? ATMRestoreRun(aptCache, @[@"show", request]) : @{};
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
        if (!metadataValid) {
            NSString *identity = [NSString stringWithFormat:@"%@\n%@", packageID, version];
            NSDictionary *verifiedPayload = ATMRestoreVerifiedPayload(self.environment, exactPayloads[identity], packageID, version);
            if (!verifiedPayload) { metadataUnavailable++; blockedCount++; continue; }
            NSURL *payloadURL = verifiedPayload[@"url"];
            [requests addObject:payloadURL.path];
            [requestedItems addObject:@{ @"packageID": packageID, @"version": version, @"source": @"embedded" }];
            continue;
        }
        if (metadataProtected) { protectedOrInvalid++; blockedCount++; continue; }
        [requests addObject:request];
        [requestedItems addObject:@{ @"packageID": packageID, @"version": version, @"source": @"repository" }];
    }
    if (![holdCheck[@"success"] boolValue]) { prerequisiteFailures++; blockedCount++; }
    NSUInteger embeddedRequestCount = 0, repositoryRequestCount = 0;
    for (NSDictionary *item in requestedItems) {
        if ([item[@"source"] isEqualToString:@"embedded"]) embeddedRequestCount++;
        else if ([item[@"source"] isEqualToString:@"repository"]) repositoryRequestCount++;
    }
    BOOL mixedRequestSources = embeddedRequestCount > 0 && repositoryRequestCount > 0;
    if (mixedRequestSources) { prerequisiteFailures++; blockedCount++; }
    BOOL embeddedOnly = requests.count > 0 && embeddedRequestCount == requests.count;
    NSString *aptGet = ATMRestoreExecutable(self.environment, @[@"/usr/bin/apt-get", @"/bin/apt-get"]);
    BOOL attempted = aptGet.length && blockedCount == 0;
    __block NSUInteger installActions = 0, configureActions = 0, removalActions = 0, unexpectedActions = 0, errorLines = 0;
    NSInteger exitCode = -1;
    if (attempted) {
        NSString *authenticationPolicy = embeddedOnly ? @"APT::Get::AllowUnauthenticated=true" : @"APT::Get::AllowUnauthenticated=false";
        NSMutableArray *arguments = [@[@"--simulate", @"--no-remove", @"--assume-no", @"--no-install-recommends", @"-o", authenticationPolicy, @"-o", @"Acquire::AllowInsecureRepositories=false", @"-o", @"Debug::NoLocking=true"] mutableCopy];
        if (requests.count) { [arguments addObject:@"install"]; [arguments addObjectsFromArray:requests]; }
        else [arguments addObject:@"check"];
        NSMutableDictionary<NSString *, NSString *> *requestedVersions = [NSMutableDictionary dictionary];
        for (NSDictionary *item in requestedItems) requestedVersions[item[@"packageID"]] = item[@"version"];
        NSRegularExpression *actionExpression = [NSRegularExpression regularExpressionWithPattern:@"^(?:Inst|Conf) ([a-z0-9][a-z0-9+.-]*)(?: \\[[^\\]]*\\])? \\(([^ )]+)" options:0 error:nil];
        NSDictionary *result = ATMRestoreRun(aptGet, arguments); exitCode = [result[@"exitCode"] integerValue];
        [result[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if ([line hasPrefix:@"Inst "] || [line hasPrefix:@"Conf "]) {
                BOOL install = [line hasPrefix:@"Inst "]; if (install) installActions++; else configureActions++;
                NSTextCheckingResult *match = [actionExpression firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                if (!match || match.numberOfRanges < 3) { unexpectedActions++; return; }
                NSString *packageID = [line substringWithRange:[match rangeAtIndex:1]], *version = [line substringWithRange:[match rangeAtIndex:2]];
                if (![requestedVersions[packageID] isEqualToString:version]) unexpectedActions++;
            }
            else if ([line hasPrefix:@"Remv "]) removalActions++;
            else if ([line hasPrefix:@"E:"]) errorLines++;
        }];
    }
    BOOL simulationPassed = attempted && exitCode == 0 && removalActions == 0 && unexpectedActions == 0 && errorLines == 0;
    BOOL alreadySatisfied = requests.count == 0 && blockedCount == 0;
    NSString *reason = ![holdCheck[@"success"] boolValue] ? @"The held-package safety check could not be completed." :
        (blockedCount ? @"Resolve the listed safety checks before Restore." :
        (!aptGet.length ? @"The package-manager safety check is unavailable." :
        (!simulationPassed ? @"The package manager could not produce an exact, removal-free plan." :
        (alreadySatisfied && newerVersionsKept ? @"All required packages are installed. Newer installed versions will be kept." :
        (alreadySatisfied ? @"All backup package versions are installed and the safety check passed." :
        @"The restore preview completed safely without removals.")))));
    NSDictionary *executionSnapshot = @{ @"items": [requestedItems copy], @"embeddedOnly": @(embeddedOnly), @"mixedRequestSources": @(mixedRequestSources), @"blocked": @(blockedCount), @"installActions": @(installActions), @"configureActions": @(configureActions), @"removalActions": @(removalActions), @"unexpectedActions": @(unexpectedActions), @"simulationPassed": @(simulationPassed) };
    return @{ @"packageCount": @(packages.count), @"alreadyInstalled": @(alreadyInstalled), @"missing": @(missing), @"versionChanges": @(versionChanges), @"updatesNeeded": @(updatesNeeded), @"newerVersionsKept": @(newerVersionsKept),
              @"exactPayloads": @(payloads), @"payloadUnavailable": @(unavailablePayloads), @"held": @(heldCount), @"blocked": @(blockedCount),
              @"protectedOrInvalid": @(protectedOrInvalid), @"metadataUnavailable": @(metadataUnavailable), @"prerequisiteFailures": @(prerequisiteFailures),
              @"embeddedRequests": @(embeddedRequestCount), @"repositoryRequests": @(repositoryRequestCount), @"mixedRequestSources": @(mixedRequestSources),
              @"holdCheckPassed": holdCheck[@"success"],
              @"simulationAttempted": @(attempted), @"simulationPassed": @(simulationPassed), @"aptExitCode": @(exitCode),
              @"installActions": @(installActions), @"configureActions": @(configureActions), @"removalActions": @(removalActions), @"unexpectedActions": @(unexpectedActions),
              @"executionRequests": [requests copy], @"requestedItems": [requestedItems copy], @"executionSnapshot": executionSnapshot,
              @"safeToExecute": @(simulationPassed && blockedCount == 0 && requests.count > 0), @"reason": reason };
}

- (NSDictionary *)executeManifest:(NSDictionary *)manifest expectedPlan:(NSDictionary *)expectedPlan exactPayloads:(NSDictionary<NSString *,NSDictionary *> *)exactPayloads error:(NSError **)error {
    if (![expectedPlan[@"safeToExecute"] boolValue] || ![expectedPlan[@"executionSnapshot"] isKindOfClass:NSDictionary.class]) {
        if (error) *error = ATMRestorePlanError(72, @"This plan is not approved for execution.");
        return nil;
    }
    NSError *scanError = nil;
    NSArray<ATMPackageRecord *> *installed = [[[ATMPackageScanner alloc] initWithEnvironment:self.environment] scanInstalledPackages:&scanError];
    if (scanError || !installed) {
        if (error) *error = ATMRestorePlanError(73, @"Installed packages could not be rechecked immediately before Restore.");
        return nil;
    }
    NSError *planError = nil;
    NSDictionary *currentPlan = [self planForManifest:manifest installedPackages:installed exactPayloads:exactPayloads error:&planError];
    if (!currentPlan || ![currentPlan[@"safeToExecute"] boolValue]) {
        if (error) *error = planError ?: ATMRestorePlanError(74, @"The Restore plan no longer passes every safety check.");
        return nil;
    }
    if (![currentPlan[@"executionSnapshot"] isEqual:expectedPlan[@"executionSnapshot"]]) {
        if (error) *error = ATMRestorePlanError(75, @"The Restore plan changed after confirmation. Run the readiness check again.");
        return nil;
    }
    NSArray<NSString *> *requests = currentPlan[@"executionRequests"];
    BOOL embeddedOnly = [currentPlan[@"executionSnapshot"][@"embeddedOnly"] boolValue];
    NSString *aptGet = ATMRestoreExecutable(self.environment, @[@"/usr/bin/apt-get", @"/bin/apt-get"]);
    if (!aptGet.length || !requests.count) {
        if (error) *error = ATMRestorePlanError(76, @"The approved package-manager action is unavailable.");
        return nil;
    }
    NSMutableArray<NSString *> *fixedPolicy = [NSMutableArray array];
    if (embeddedOnly) {
        [fixedPolicy addObjectsFromArray:@[@"--allow-unauthenticated", @"-o", @"APT::Get::AllowUnauthenticated=true", @"-o", @"APT::Get::Download=true", @"-o", @"Acquire::Retries=0"]];
    } else {
        [fixedPolicy addObjectsFromArray:@[@"-o", @"APT::Get::AllowUnauthenticated=false"]];
    }
    [fixedPolicy addObjectsFromArray:@[
        @"-o", @"Acquire::AllowInsecureRepositories=false",
        @"-o", @"Acquire::AllowDowngradeToInsecureRepositories=false",
        @"-o", @"APT::Get::Allow-Downgrades=false",
        @"-o", @"DPkg::Lock::Timeout=30"]];

    NSMutableArray<NSString *> *preflightArguments = [@[@"--simulate", @"--no-remove", @"--assume-no", @"--no-install-recommends"] mutableCopy];
    [preflightArguments addObjectsFromArray:fixedPolicy];
    [preflightArguments addObject:@"install"];
    [preflightArguments addObjectsFromArray:requests];
    NSDictionary *preflightRun = ATMRestoreRunWithPrivilege(aptGet, preflightArguments, YES);
    __block NSUInteger preflightInstallActions = 0, preflightConfigureActions = 0, preflightRemovalActions = 0, preflightUnexpectedActions = 0, preflightErrorLines = 0;
    NSMutableDictionary<NSString *, NSString *> *requestedVersions = [NSMutableDictionary dictionary];
    for (NSDictionary *item in currentPlan[@"requestedItems"] ?: @[]) requestedVersions[item[@"packageID"]] = item[@"version"];
    NSRegularExpression *actionExpression = [NSRegularExpression regularExpressionWithPattern:@"^(?:Inst|Conf) ([a-z0-9][a-z0-9+.-]*)(?: \\[[^\\]]*\\])? \\(([^ )]+)" options:0 error:nil];
    [preflightRun[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if ([line hasPrefix:@"Inst "] || [line hasPrefix:@"Conf "]) {
            if ([line hasPrefix:@"Inst "]) preflightInstallActions++; else preflightConfigureActions++;
            NSTextCheckingResult *match = [actionExpression firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (!match || match.numberOfRanges < 3) { preflightUnexpectedActions++; return; }
            NSString *packageID = [line substringWithRange:[match rangeAtIndex:1]], *version = [line substringWithRange:[match rangeAtIndex:2]];
            if (![requestedVersions[packageID] isEqualToString:version]) preflightUnexpectedActions++;
        } else if ([line hasPrefix:@"Remv "]) preflightRemovalActions++;
        else if ([line hasPrefix:@"E:"]) preflightErrorLines++;
    }];
    NSInteger preflightExitCode = [preflightRun[@"exitCode"] integerValue];
    BOOL preflightPassed = preflightExitCode == 0 && preflightInstallActions == requests.count &&
        preflightConfigureActions <= requests.count && preflightRemovalActions == 0 &&
        preflightUnexpectedActions == 0 && preflightErrorLines == 0;
    if (!preflightPassed) {
        NSString *preflightCode = preflightExitCode != 0 ? ATMRestoreFailureCode(preflightRun) : @"R34-PREFLIGHT";
        return @{ @"success": @NO, @"requested": @(requests.count), @"completed": @0, @"remaining": @(requests.count),
                  @"aptExitCode": @(preflightExitCode), @"restoreCode": preflightCode, @"postCheckPassed": @NO,
                  @"removalsAllowed": @NO, @"downgradesAllowed": @NO, @"sourcesChanged": @NO,
                  @"rollbackEvidence": @{ @"preRestoreRequestCount": @(requests.count), @"postRestoreRequestCount": @(requests.count), @"identitiesIncluded": @NO },
                  @"reason": @"Restore stopped because the privileged package-manager preflight did not match the approved plan." };
    }

    NSMutableArray<NSString *> *arguments = [@[@"--no-remove", @"--yes", @"--no-install-recommends"] mutableCopy];
    [arguments addObjectsFromArray:fixedPolicy];
    [arguments addObject:@"install"];
    [arguments addObjectsFromArray:requests];
    NSDictionary *run = ATMRestoreRunWithPrivilege(aptGet, arguments, YES);
    NSInteger aptExitCode = [run[@"exitCode"] integerValue];

    NSError *postScanError = nil;
    NSArray<ATMPackageRecord *> *afterInstalled = [[[ATMPackageScanner alloc] initWithEnvironment:self.environment] scanInstalledPackages:&postScanError];
    NSDictionary *postPlan = afterInstalled ? [self planForManifest:manifest installedPackages:afterInstalled exactPayloads:exactPayloads error:nil] : nil;
    NSMutableDictionary<NSString *, ATMPackageRecord *> *afterByID = [NSMutableDictionary dictionary];
    for (ATMPackageRecord *record in afterInstalled ?: @[]) if (record.packageID.length) afterByID[record.packageID] = record;
    NSString *dpkg = ATMRestoreExecutable(self.environment, @[@"/usr/bin/dpkg", @"/bin/dpkg"]); NSUInteger completed = 0;
    for (NSDictionary *item in currentPlan[@"requestedItems"] ?: @[]) {
        NSString *packageID = item[@"packageID"], *version = item[@"version"];
        NSString *installedVersion = afterByID[packageID].version;
        if ([installedVersion isEqualToString:version]) { completed++; continue; }
        if (dpkg.length && installedVersion.length && [ATMRestoreRun(dpkg, @[@"--compare-versions", installedVersion, @"gt", version])[@"exitCode"] integerValue] == 0) completed++;
    }
    NSUInteger remaining = requests.count - completed;
    BOOL postCheckPassed = !postScanError && postPlan && [postPlan[@"simulationPassed"] boolValue] && [postPlan[@"blocked"] unsignedIntegerValue] == 0 && remaining == 0;
    BOOL success = aptExitCode == 0 && postCheckPassed;
    NSString *restoreCode = success ? @"R34-OK" :
        (postScanError ? @"R34-POSTSCAN" : (aptExitCode != 0 ? ATMRestoreFailureCode(run) : @"R34-VERIFY"));
    NSString *reason = success ? @"Restore completed and the package state passed verification." :
        (postScanError ? @"Restore finished, but the final package-state verification was unavailable." :
        (aptExitCode != 0 ? @"The package manager stopped before Restore completed." : @"Restore stopped because the final package state did not match the approved plan."));
    return @{ @"success": @(success), @"requested": @(requests.count), @"completed": @(completed), @"remaining": @(remaining),
              @"aptExitCode": @(aptExitCode), @"restoreCode": restoreCode, @"postCheckPassed": @(postCheckPassed),
              @"removalsAllowed": @NO, @"downgradesAllowed": @NO, @"sourcesChanged": @NO,
              @"rollbackEvidence": @{ @"preRestoreRequestCount": @(requests.count), @"postRestoreRequestCount": @(remaining), @"identitiesIncluded": @NO },
              @"reason": reason };
}
@end
