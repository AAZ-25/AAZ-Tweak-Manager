#import "ATMBackupManager.h"
#import "ATMRestorePlanner.h"
#import "ATMZipWriter.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
NSString *const ATMBackupErrorDomain = @"com.aaz.tweakmanager.backup";
static NSString *const ATMProfilesKey = @"ATMBackupProfilesV1";
static NSString *const ATMPinnedBackupsKey = @"ATMPinnedBackupsV1";
static const NSUInteger ATMEncryptedHeaderLength = 44;
static const NSUInteger ATMEncryptedTagLength = CC_SHA256_DIGEST_LENGTH;

@interface ATMBackupManager ()
@property(nonatomic, strong) ATMEnvironment *environment;
@property(nonatomic, strong) ATMPersonalLedger *ledger;
@property(nonatomic, strong) ATMRestorePlanner *restorePlanner;
@property(nonatomic, strong, nullable) NSURL *restoreStagingDirectory;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *restorePayloads;
@property(nonatomic, copy) NSArray<NSDictionary *> *restoreSourcePayloads;
@property(nonatomic, copy, nullable) NSDictionary *restoreManifest;
@property(nonatomic, copy, nullable) NSString *restoreSessionID;
@property(atomic) BOOL backupCancellationRequested;
@property(nonatomic) BOOL importSelfTestActive;
@property(nonatomic, copy, readwrite, nullable) NSDictionary *lastBackupAttemptReport;
- (void)cleanupStaleImportArtifacts;
@end

static NSError *ATMBackupError(NSInteger code, NSString *message) { return [NSError errorWithDomain:ATMBackupErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}]; }

static BOOL ATMCopyFileContents(NSURL *sourceURL, NSURL *destinationURL, NSInteger *failureCode) {
    [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
    NSError *copyError = nil;
    BOOL copied = [NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:destinationURL error:&copyError];
    if (!copied && failureCode) {
        BOOL destinationUnavailable = ![NSFileManager.defaultManager isWritableFileAtPath:destinationURL.URLByDeletingLastPathComponent.path];
        *failureCode = destinationUnavailable ? 60 : 59;
    }
    return copied;
}

static NSDictionary *ATMRunBackupToolWithPrivilege(NSString *tool, NSArray<NSString *> *arguments, BOOL asRoot, NSString *workingDirectory) {
    if (!tool.length) return @{ @"exitCode": @(-1), @"output": @"" };
    int outputPipe[2]; if (pipe(outputPipe) != 0) return @{ @"exitCode": @(-1), @"output": @"" };
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    int nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nullInput >= 0) posix_spawn_file_actions_adddup2(&actions, nullInput, STDIN_FILENO);
    (void)workingDirectory;
    NSMutableArray<NSData *> *storage = [NSMutableArray array]; NSMutableArray<NSValue *> *pointers = [NSMutableArray array];
    for (NSString *item in [@[tool] arrayByAddingObjectsFromArray:arguments]) { NSData *data = [[item stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding]; [storage addObject:data]; [pointers addObject:[NSValue valueWithPointer:(void *)data.bytes]]; }
    char **argv = calloc(pointers.count + 1, sizeof(char *)); for (NSUInteger index = 0; index < pointers.count; index++) argv[index] = [pointers[index] pointerValue];
    pid_t pid = 0; posix_spawnattr_t attributes; posix_spawnattr_t *attributesPointer = NULL; BOOL attributesInitialized = NO; int personaResult = 0;
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
    if (spawnResult != 0) { close(outputPipe[0]); return @{ @"exitCode": @(-1), @"output": @"", @"personaError": @(personaResult), @"spawnError": @(spawnResult) }; }
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[8192]; ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) { if (data.length + (NSUInteger)count > 2 * 1024 * 1024) { kill(pid, SIGKILL); break; } [data appendBytes:buffer length:(NSUInteger)count]; }
    close(outputPipe[0]); int status = 0; waitpid(pid, &status, 0); NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return @{ @"exitCode": @(exitCode), @"output": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"" };
}

static NSDictionary *ATMRunBackupTool(NSString *tool, NSArray<NSString *> *arguments) {
    return ATMRunBackupToolWithPrivilege(tool, arguments, NO, nil);
}

static NSString *ATMReadDPKGDebField(ATMEnvironment *environment, NSURL *debURL, NSString *field, NSString **failureStage) {
    static NSSet<NSString *> *allowedFields; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ allowedFields = [NSSet setWithArray:@[@"Package", @"Version", @"Architecture", @"Priority", @"Essential"]]; });
    if (![allowedFields containsObject:field] || !debURL.isFileURL) { if (failureStage) *failureStage = @"identity-tool"; return nil; }
    NSArray *candidates = @[[environment pathInsideRoot:@"/usr/bin/dpkg-deb"], [environment pathInsideRoot:@"/bin/dpkg-deb"]]; NSString *tool = nil;
    for (NSString *candidate in candidates) if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { tool = candidate; break; }
    if (!tool.length) { if (failureStage) *failureStage = @"identity-tool"; return nil; }
    NSDictionary *run = ATMRunBackupTool(tool, @[@"--field", debURL.path, field]);
    if ([run[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"identity-tool"; return nil; }
    NSString *output = [run[@"output"] isKindOfClass:NSString.class] ? run[@"output"] : @"";
    NSString *value = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound || value.length > 512) {
        if (failureStage) *failureStage = [@"identity-" stringByAppendingString:field.lowercaseString];
        return nil;
    }
    return value;
}

static BOOL ATMFilesEqualWithOptionalPrivilegedTool(NSString *sourcePath, NSString *destinationPath, NSString *compareTool) {
    NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:sourcePath];
    NSFileHandle *destination = [NSFileHandle fileHandleForReadingAtPath:destinationPath];
    if (source && destination) {
        @try {
            while (YES) {
                NSData *left = [source readDataOfLength:1024 * 1024];
                NSData *right = [destination readDataOfLength:1024 * 1024];
                if (![left isEqualToData:right]) { [source closeFile]; [destination closeFile]; return NO; }
                if (!left.length) { [source closeFile]; [destination closeFile]; return YES; }
            }
        } @catch (NSException *exception) {
            (void)exception;
            [source closeFile];
            [destination closeFile];
        }
    } else {
        [source closeFile];
        [destination closeFile];
    }
    return compareTool.length && [ATMRunBackupToolWithPrivilege(compareTool, @[@"-s", sourcePath, destinationPath], YES, nil)[@"exitCode"] integerValue] == 0;
}

static BOOL ATMCreateDirectoryTreeBelowRoot(NSURL *rootURL, NSString *relativePath, NSString **failureStage) {
    if (!rootURL.isFileURL || !relativePath.length || relativePath.length > 4096 || [relativePath hasPrefix:@"/"]) {
        if (failureStage) *failureStage = @"directory-containment";
        return NO;
    }
    NSArray<NSString *> *components = [relativePath componentsSeparatedByString:@"/"];
    for (NSString *component in components) {
        if (!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."] || [component containsString:@"\0"] || [component containsString:@"\r"] || [component containsString:@"\n"]) {
            if (failureStage) *failureStage = @"directory-containment";
            return NO;
        }
    }
    int directoryFD = open(rootURL.path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryFD < 0) {
        if (failureStage) *failureStage = @"directory-create";
        return NO;
    }
    for (NSString *component in components) {
        const char *name = component.fileSystemRepresentation;
        if (!name || (mkdirat(directoryFD, name, 0755) != 0 && errno != EEXIST)) {
            close(directoryFD);
            if (failureStage) *failureStage = @"directory-create";
            return NO;
        }
        int childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (childFD < 0) {
            NSInteger openError = errno;
            close(directoryFD);
            if (failureStage) *failureStage = (openError == ELOOP || openError == ENOTDIR) ? @"directory-containment" : @"directory-create";
            return NO;
        }
        close(directoryFD);
        directoryFD = childFD;
    }
    close(directoryFD);
    return YES;
}

static NSArray<NSString *> *ATMRequiredDirectoryPaths(NSArray<NSString *> *safePaths, NSArray<NSString *> *directoryPaths) {
    NSMutableOrderedSet<NSString *> *required = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSDictionary *> *inputs = [NSMutableArray array];
    for (NSString *path in directoryPaths ?: @[]) [inputs addObject:@{ @"path": path, @"includeLast": @YES }];
    for (NSString *path in safePaths ?: @[]) [inputs addObject:@{ @"path": path, @"includeLast": @NO }];
    for (NSDictionary *input in inputs) {
        NSString *path = input[@"path"];
        NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
        NSUInteger limit = [input[@"includeLast"] boolValue] ? components.count : (components.count ? components.count - 1 : 0);
        NSMutableArray<NSString *> *parents = [NSMutableArray array];
        for (NSUInteger index = 0; index < components.count; index++) {
            NSString *component = components[index];
            if (!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."] || [component containsString:@"\0"] || [component containsString:@"\r"] || [component containsString:@"\n"]) return nil;
            if (index >= limit) continue;
            [parents addObject:component];
            [required addObject:[parents componentsJoinedByString:@"/"]];
        }
    }
    return required.array;
}

static BOOL ATMResetAndPreparePayloadStage(NSURL *stage, NSString *payloadRoot, NSArray<NSString *> *safePaths, NSArray<NSString *> *directoryPaths, NSString **failureStage) {
    (void)payloadRoot;
    [NSFileManager.defaultManager removeItemAtURL:stage error:nil];
    if (![NSFileManager.defaultManager createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (failureStage) *failureStage = @"directory-create";
        return NO;
    }
    NSArray<NSString *> *requiredDirectories = ATMRequiredDirectoryPaths(safePaths, directoryPaths);
    if (!requiredDirectories) { if (failureStage) *failureStage = @"directory-containment"; return NO; }
    for (NSString *relativePath in requiredDirectories) {
        if (!ATMCreateDirectoryTreeBelowRoot(stage, relativePath, failureStage)) return NO;
    }
    return YES;
}

static NSString *ATMPruneUnexpectedStagedEntries(NSURL *stage, NSArray<NSString *> *safePaths, NSArray<NSString *> *directoryPaths) {
    NSArray<NSString *> *requiredDirectories = ATMRequiredDirectoryPaths(safePaths, directoryPaths);
    if (!requiredDirectories) return @"source";
    NSSet<NSString *> *expectedFiles = [NSSet setWithArray:safePaths ?: @[]];
    NSSet<NSString *> *expectedDirectories = [NSSet setWithArray:requiredDirectories];
    NSMutableArray<NSDictionary *> *unexpectedDirectories = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:stage.path];
    if (!enumerator) return @"enumeration";
    for (NSString *relativePath in enumerator) {
        if (![relativePath isKindOfClass:NSString.class] || !relativePath.length || [relativePath hasPrefix:@"/"] || [relativePath containsString:@".."] || [relativePath containsString:@"\0"] || [relativePath containsString:@"\r"] || [relativePath containsString:@"\n"]) return @"enumeration";
        NSString *fullPath = [stage.path stringByAppendingPathComponent:relativePath];
        struct stat stagedInfo;
        if (lstat(fullPath.fileSystemRepresentation, &stagedInfo) != 0) return @"enumeration";
        if (S_ISDIR(stagedInfo.st_mode)) {
            if (![expectedDirectories containsObject:relativePath]) {
                [unexpectedDirectories addObject:@{ @"fullPath": fullPath, @"path": relativePath }];
            }
            continue;
        }
        if (![expectedFiles containsObject:relativePath] && unlink(fullPath.fileSystemRepresentation) != 0) return @"unexpected-entry";
    }
    [unexpectedDirectories sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSUInteger leftDepth = [left[@"path"] pathComponents].count;
        NSUInteger rightDepth = [right[@"path"] pathComponents].count;
        if (leftDepth > rightDepth) return NSOrderedAscending;
        if (leftDepth < rightDepth) return NSOrderedDescending;
        return [right[@"path"] compare:left[@"path"]];
    }];
    for (NSDictionary *entry in unexpectedDirectories) {
        NSString *fullPath = entry[@"fullPath"];
        if (rmdir(fullPath.fileSystemRepresentation) != 0) return @"unexpected-entry";
    }
    return nil;
}

static NSString *ATMStagedPayloadVerificationFailure(NSURL *stage, NSString *payloadRoot, NSArray<NSString *> *safePaths, NSArray<NSString *> *directoryPaths, NSString *compareTool) {
    NSArray<NSString *> *requiredDirectories = ATMRequiredDirectoryPaths(safePaths, directoryPaths);
    if (!requiredDirectories) return @"source";
    NSSet<NSString *> *expectedFiles = [NSSet setWithArray:safePaths], *expectedDirectories = [NSSet setWithArray:requiredDirectories];
    NSMutableSet<NSString *> *seenFiles = [NSMutableSet set], *seenDirectories = [NSMutableSet set];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:stage.path];
    if (!enumerator) return @"enumeration";
    for (NSString *relativePath in enumerator) {
        if (![relativePath isKindOfClass:NSString.class] || !relativePath.length || [relativePath hasPrefix:@"/"] || [relativePath containsString:@".."] || [relativePath containsString:@"\0"] || [relativePath containsString:@"\r"] || [relativePath containsString:@"\n"]) return @"enumeration";
        NSString *fullPath = [stage.path stringByAppendingPathComponent:relativePath];
        struct stat stagedInfo;
        if (lstat(fullPath.fileSystemRepresentation, &stagedInfo) != 0) return @"enumeration";
        if (S_ISDIR(stagedInfo.st_mode)) {
            if (![expectedDirectories containsObject:relativePath]) return @"unexpected-directory";
            [seenDirectories addObject:relativePath];
            continue;
        }
        if (![expectedFiles containsObject:relativePath]) return @"unexpected-entry";
        if (!S_ISREG(stagedInfo.st_mode) && !S_ISLNK(stagedInfo.st_mode)) return @"type";
        NSString *sourcePath = [payloadRoot isEqualToString:@"/"] ? [@"/" stringByAppendingString:relativePath] : [payloadRoot stringByAppendingPathComponent:relativePath];
        struct stat sourceInfo;
        if (lstat(sourcePath.fileSystemRepresentation, &sourceInfo) != 0) return @"source";
        if ((sourceInfo.st_mode & S_IFMT) != (stagedInfo.st_mode & S_IFMT)) return @"type";
        if (S_ISREG(sourceInfo.st_mode)) {
            if ((sourceInfo.st_mode & 07777) != (stagedInfo.st_mode & 07777)) return @"mode";
            if (sourceInfo.st_size != stagedInfo.st_size) return @"size";
            if (!ATMFilesEqualWithOptionalPrivilegedTool(sourcePath, fullPath, compareTool)) return @"content";
        } else {
            NSString *sourceTarget = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:sourcePath error:nil];
            NSString *stagedTarget = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:fullPath error:nil];
            if (!sourceTarget.length || ![sourceTarget isEqualToString:stagedTarget]) return @"symlink";
        }
        [seenFiles addObject:relativePath];
    }
    if (![seenFiles isEqualToSet:expectedFiles] || ![seenDirectories isEqualToSet:expectedDirectories]) return @"missing-entry";
    return nil;
}

static NSString *ATMNormalizeStagedPayloadModes(NSURL *stage, NSString *payloadRoot, NSArray<NSString *> *safePaths, NSArray<NSString *> *directoryPaths, NSString *chmodTool) {
    // Implicit parents are staging structure, not package-owned payload entries.
    // Their physical Rootless path can itself be a redirection symlink.
    for (NSString *relativePath in directoryPaths ?: @[]) {
        NSString *sourcePath = [payloadRoot isEqualToString:@"/"] ? [@"/" stringByAppendingString:relativePath] : [payloadRoot stringByAppendingPathComponent:relativePath];
        NSString *destinationPath = [stage.path stringByAppendingPathComponent:relativePath];
        struct stat sourceInfo, destinationInfo;
        if (stat(sourcePath.fileSystemRepresentation, &sourceInfo) != 0) return @"source";
        if (lstat(destinationPath.fileSystemRepresentation, &destinationInfo) != 0) return @"missing-entry";
        if (!S_ISDIR(sourceInfo.st_mode) || !S_ISDIR(destinationInfo.st_mode)) return @"type";
        mode_t mode = sourceInfo.st_mode & 07777;
        if (chmod(destinationPath.fileSystemRepresentation, mode) == 0) continue;
        NSString *modeString = [NSString stringWithFormat:@"%04o", mode];
        if (!chmodTool.length || [ATMRunBackupToolWithPrivilege(chmodTool, @[modeString, destinationPath], YES, nil)[@"exitCode"] integerValue] != 0) return @"mode";
    }
    for (NSString *relativePath in safePaths ?: @[]) {
        NSString *sourcePath = [payloadRoot isEqualToString:@"/"] ? [@"/" stringByAppendingString:relativePath] : [payloadRoot stringByAppendingPathComponent:relativePath];
        NSString *destinationPath = [stage.path stringByAppendingPathComponent:relativePath];
        struct stat sourceInfo, destinationInfo;
        if (lstat(sourcePath.fileSystemRepresentation, &sourceInfo) != 0) return @"source";
        if (lstat(destinationPath.fileSystemRepresentation, &destinationInfo) != 0) return @"missing-entry";
        if ((sourceInfo.st_mode & S_IFMT) != (destinationInfo.st_mode & S_IFMT)) return @"type";
        if (S_ISLNK(sourceInfo.st_mode)) continue;
        mode_t mode = sourceInfo.st_mode & 07777;
        if (chmod(destinationPath.fileSystemRepresentation, mode) == 0) continue;
        NSString *modeString = [NSString stringWithFormat:@"%04o", mode];
        if (!chmodTool.length || [ATMRunBackupToolWithPrivilege(chmodTool, @[modeString, destinationPath], YES, nil)[@"exitCode"] integerValue] != 0) return @"mode";
    }
    return nil;
}

static NSString *ATMVerificationStage(NSString *prefix, NSString *reason) {
    static NSSet<NSString *> *allowedReasons; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ allowedReasons = [NSSet setWithArray:@[@"enumeration", @"unexpected-directory", @"unexpected-entry", @"missing-entry", @"source", @"type", @"mode", @"size", @"content", @"symlink"]]; });
    NSString *safeReason = [allowedReasons containsObject:reason] ? reason : @"unknown";
    return [NSString stringWithFormat:@"%@-%@", prefix, safeReason];
}

static BOOL ATMBackupPackageIDIsValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 128) return NO;
    static NSRegularExpression *expression; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9][a-z0-9+.-]*$" options:0 error:nil]; });
    return [expression numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1;
}

static BOOL ATMBackupVersionIsValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 256) return NO;
    static NSRegularExpression *expression; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Za-z.+:~_-]+$" options:0 error:nil]; });
    return [expression numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1;
}

static NSData *ATMRepackedControlData(NSDictionary<NSString *, NSString *> *fields) {
    NSArray<NSString *> *required = @[@"Package", @"Version", @"Architecture"];
    for (NSString *key in required) if (![fields[key] isKindOfClass:NSString.class] || ![fields[key] length]) return nil;
    NSSet<NSString *> *excluded = [NSSet setWithArray:@[@"Status", @"Config-Version", @"Conffiles", @"Triggers-Awaited", @"Triggers-Pending", @"Auto-Installed", @"Protected"]];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithArray:required];
    for (NSString *key in [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)]) if (![required containsObject:key] && ![excluded containsObject:key]) [keys addObject:key];
    NSMutableString *control = [NSMutableString string];
    for (NSString *key in keys) {
        NSString *value = [fields[key] isKindOfClass:NSString.class] ? fields[key] : @"";
        NSString *normalizedKey = [key stringByReplacingOccurrencesOfString:@"-" withString:@""];
        if (!value.length || !normalizedKey.length || [normalizedKey rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) continue;
        NSArray<NSString *> *lines = [value componentsSeparatedByString:@"\n"]; [control appendFormat:@"%@: %@\n", key, lines.firstObject ?: @""];
        for (NSUInteger index = 1; index < lines.count; index++) [control appendFormat:@" %@\n", lines[index]];
    }
    return [control dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *ATMValidatedBackupPayloadWithFailure(ATMEnvironment *environment, NSURL *url, NSString **failureStage) {
    NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!url.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:url.path] || size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > 256ULL * 1024ULL * 1024ULL) { if (failureStage) *failureStage = @"identity-file"; return nil; }
    NSString *packageID = ATMReadDPKGDebField(environment, url, @"Package", failureStage);
    if (!packageID || !ATMBackupPackageIDIsValid(packageID)) { if (failureStage && !*failureStage) *failureStage = @"identity-package"; return nil; }
    NSString *version = ATMReadDPKGDebField(environment, url, @"Version", failureStage);
    if (!version || !ATMBackupVersionIsValid(version)) { if (failureStage && !*failureStage) *failureStage = @"identity-version"; return nil; }
    NSString *architecture = ATMReadDPKGDebField(environment, url, @"Architecture", failureStage);
    if (!architecture || ![@[@"iphoneos-arm64", @"all"] containsObject:architecture]) { if (failureStage && !*failureStage) *failureStage = @"identity-architecture"; return nil; }
    NSString *priority = [ATMReadDPKGDebField(environment, url, @"Priority", failureStage) lowercaseString];
    if (!priority) return nil;
    NSString *essential = [ATMReadDPKGDebField(environment, url, @"Essential", failureStage) lowercaseString];
    if (!essential) return nil;
    if ([essential isEqualToString:@"yes"] || [@[@"required", @"important"] containsObject:priority] || [ATMProtectedPackageIDs() containsObject:packageID.lowercaseString]) { if (failureStage) *failureStage = @"identity-policy"; return nil; }
    NSString *sha = ATMSHA256ForFile(url, nil).lowercaseString; if (sha.length != 64) { if (failureStage) *failureStage = @"identity-hash"; return nil; }
    return @{ @"url": url, @"packageID": packageID, @"version": version, @"architecture": architecture, @"sha256": sha, @"size": size ?: @0 };
}

static NSDictionary *ATMValidatedBackupPayload(ATMEnvironment *environment, NSURL *url) {
    return ATMValidatedBackupPayloadWithFailure(environment, url, nil);
}

static NSString *ATMSHA256ForData(NSData *data) { unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest); NSMutableString *value = [NSMutableString stringWithCapacity:64]; for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [value appendFormat:@"%02x", digest[i]]; return value; }
static BOOL ATMConstantTimeEqual(NSData *left, NSData *right) { if (left.length != right.length) return NO; const uint8_t *a = left.bytes, *b = right.bytes; uint8_t difference = 0; for (NSUInteger i = 0; i < left.length; i++) difference |= a[i] ^ b[i]; return difference == 0; }
static BOOL ATMDeriveKeys(NSString *password, NSData *salt, uint32_t iterations, uint8_t output[64]) { NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding]; return CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)passwordData.bytes, passwordData.length, salt.bytes, salt.length, kCCPRFHmacAlgSHA256, iterations, output, 64) == kCCSuccess; }
static NSData *ATMCrypt(NSData *input, CCOperation operation, const uint8_t key[32], NSData *iv, NSError **error) { size_t capacity = input.length + kCCBlockSizeAES128; NSMutableData *output = [NSMutableData dataWithLength:capacity]; size_t moved = 0; CCCryptorStatus status = CCCrypt(operation, kCCAlgorithmAES, kCCOptionPKCS7Padding, key, 32, iv.bytes, input.bytes, input.length, output.mutableBytes, capacity, &moved); if (status != kCCSuccess) { if (error) *error = ATMBackupError(42, @"Backup encryption could not be completed."); return nil; } output.length = moved; return output; }

static NSData *ATMEncryptArchive(NSData *plain, NSString *password, NSError **error) {
    if (password.length < 8) { if (error) *error = ATMBackupError(43, @"Use a password with at least 8 characters."); return nil; }
    uint8_t saltBytes[16], ivBytes[16]; if (SecRandomCopyBytes(kSecRandomDefault, 16, saltBytes) != errSecSuccess || SecRandomCopyBytes(kSecRandomDefault, 16, ivBytes) != errSecSuccess) { if (error) *error = ATMBackupError(44, @"Secure random data is unavailable."); return nil; }
    NSData *salt = [NSData dataWithBytes:saltBytes length:16], *iv = [NSData dataWithBytes:ivBytes length:16]; uint32_t iterations = 150000; uint8_t keys[64];
    if (!ATMDeriveKeys(password, salt, iterations, keys)) { if (error) *error = ATMBackupError(45, @"Password key derivation failed."); return nil; }
    NSData *cipher = ATMCrypt(plain, kCCEncrypt, keys, iv, error); if (!cipher) { memset(keys, 0, sizeof(keys)); return nil; }
    NSMutableData *container = [NSMutableData data]; [container appendData:[@"AAZTME01" dataUsingEncoding:NSASCIIStringEncoding]];
    uint8_t iterationBytes[4] = {(uint8_t)(iterations & 0xff), (uint8_t)((iterations >> 8) & 0xff), (uint8_t)((iterations >> 16) & 0xff), (uint8_t)((iterations >> 24) & 0xff)};
    [container appendBytes:iterationBytes length:4]; [container appendData:salt]; [container appendData:iv]; [container appendData:cipher];
    unsigned char tag[CC_SHA256_DIGEST_LENGTH]; CCHmac(kCCHmacAlgSHA256, keys + 32, 32, container.bytes, container.length, tag); [container appendBytes:tag length:sizeof(tag)]; memset(keys, 0, sizeof(keys)); return container;
}

static NSData *ATMDecryptArchive(NSData *container, NSString *password, NSError **error) {
    NSData *magic = [@"AAZTME01" dataUsingEncoding:NSASCIIStringEncoding];
    if (container.length < ATMEncryptedHeaderLength + ATMEncryptedTagLength + kCCBlockSizeAES128 || ![[container subdataWithRange:NSMakeRange(0, 8)] isEqualToData:magic]) { if (error) *error = ATMBackupError(31, @"Unsupported or invalid encrypted backup."); return nil; }
    if (!password.length) { if (error) *error = ATMBackupError(ATMBackupErrorPasswordRequired, @"This backup is encrypted. Enter its password to inspect it."); return nil; }
    const uint8_t *bytes = container.bytes; uint32_t iterations = (uint32_t)bytes[8] | ((uint32_t)bytes[9] << 8) | ((uint32_t)bytes[10] << 16) | ((uint32_t)bytes[11] << 24);
    if (iterations < 100000 || iterations > 1000000) { if (error) *error = ATMBackupError(31, @"The encrypted backup header is invalid."); return nil; }
    NSData *salt = [container subdataWithRange:NSMakeRange(12, 16)], *iv = [container subdataWithRange:NSMakeRange(28, 16)]; uint8_t keys[64];
    if (!ATMDeriveKeys(password, salt, iterations, keys)) return nil;
    NSData *authenticated = [container subdataWithRange:NSMakeRange(0, container.length - ATMEncryptedTagLength)]; unsigned char expectedBytes[CC_SHA256_DIGEST_LENGTH]; CCHmac(kCCHmacAlgSHA256, keys + 32, 32, authenticated.bytes, authenticated.length, expectedBytes);
    NSData *expected = [NSData dataWithBytes:expectedBytes length:sizeof(expectedBytes)], *actual = [container subdataWithRange:NSMakeRange(container.length - ATMEncryptedTagLength, ATMEncryptedTagLength)];
    if (!ATMConstantTimeEqual(expected, actual)) { memset(keys, 0, sizeof(keys)); if (error) *error = ATMBackupError(ATMBackupErrorWrongPassword, @"The password is incorrect or the encrypted backup was changed."); return nil; }
    NSData *cipher = [container subdataWithRange:NSMakeRange(ATMEncryptedHeaderLength, container.length - ATMEncryptedHeaderLength - ATMEncryptedTagLength)]; NSData *plain = ATMCrypt(cipher, kCCDecrypt, keys, iv, error); memset(keys, 0, sizeof(keys)); return plain;
}

@implementation ATMBackupManager
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger {
    if ((self = [super init])) {
        _environment = environment; _ledger = ledger; _restorePlanner = [[ATMRestorePlanner alloc] initWithEnvironment:environment];
        NSArray<NSURL *> *temporaryRoots = @[
            [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerRestore"] isDirectory:YES],
            [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerAcquire"] isDirectory:YES],
            [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerPreflight"] isDirectory:YES],
            [NSURL fileURLWithPath:@"/var/mobile/Library/Application Support/AAZTweakManager/Working" isDirectory:YES]
        ];
        for (NSURL *root in temporaryRoots) [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        _restorePayloads = @{}; _restoreSourcePayloads = @[];
        [self cleanupStaleImportArtifacts];
    }
    return self;
}
- (void)cancelCurrentBackup { self.backupCancellationRequested = YES; }
- (NSURL *)backupWorkingDirectory {
    NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Library/Application Support/AAZTweakManager/Working" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication, NSFilePosixPermissions: @0700} error:nil]) return nil;
    return directory;
}
- (NSURL *)newBackupWorkingRootNamed:(NSString *)name {
    NSURL *directory = self.backupWorkingDirectory;
    if (!directory) return nil;
    NSString *safeName = name.length ? name : @"operation";
    NSURL *root = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", safeName, NSUUID.UUID.UUIDString] isDirectory:YES];
    return [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:NO attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication, NSFilePosixPermissions: @0700} error:nil] ? root : nil;
}
- (void)clearRestoreSession { if (self.restoreStagingDirectory) [NSFileManager.defaultManager removeItemAtURL:self.restoreStagingDirectory error:nil]; self.restoreStagingDirectory = nil; self.restorePayloads = @{}; self.restoreSourcePayloads = @[]; self.restoreManifest = nil; self.restoreSessionID = nil; }
- (void)discardRestoreSession { [self clearRestoreSession]; }
- (NSURL *)backupDirectory { NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/Backups" isDirectory:YES]; [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]; return directory; }
- (NSURL *)pendingImportDirectory {
    NSURL *container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.aaz.tweakmanager"];
    if (!container) return nil;
    NSURL *directory = [container URLByAppendingPathComponent:@"ImportInbox" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    return directory;
}
- (void)cleanupStaleImportArtifacts {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *staged = [fm contentsOfDirectoryAtURL:self.backupDirectory includingPropertiesForKeys:nil options:0 error:nil] ?: @[];
    for (NSURL *url in staged) if ([url.lastPathComponent hasSuffix:@".import.staged"] || [url.lastPathComponent hasPrefix:@".selftest-"]) [fm removeItemAtURL:url error:nil];
    NSURL *inbox = self.pendingImportDirectory;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-3600.0];
    NSArray<NSURL *> *pending = inbox ? ([fm contentsOfDirectoryAtURL:inbox includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil] ?: @[]) : @[];
    for (NSURL *url in pending) {
        NSDate *modified = nil; [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        BOOL ownedSelfTest = [url.lastPathComponent hasPrefix:@".selftest-"];
        BOOL stalePartial = [url.lastPathComponent hasSuffix:@".partial"] && modified && [modified compare:cutoff] == NSOrderedAscending;
        if (ownedSelfTest || stalePartial) [fm removeItemAtURL:url error:nil];
    }
}
- (NSArray<NSURL *> *)pendingImportURLs { NSURL *directory = self.pendingImportDirectory; if (!directory) return @[]; NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]; NSPredicate *filter = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { (void)bindings; return [@[@"aaztmbackup", @"deb"] containsObject:url.pathExtension.lowercaseString]; }]; return [[files filteredArrayUsingPredicate:filter] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { NSDate *ad = nil, *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil]; return [ad ?: NSDate.distantPast compare:bd ?: NSDate.distantPast]; }]; }
- (BOOL)isPendingImportURL:(NSURL *)url { NSURL *directory = self.pendingImportDirectory; if (!url.isFileURL || !directory) return NO; NSURL *parent = [url.URLByDeletingLastPathComponent URLByStandardizingPath]; return [parent isEqual:[directory URLByStandardizingPath]] && [url.pathExtension.lowercaseString isEqualToString:@"aaztmbackup"]; }
- (BOOL)isPendingPackagePayloadURL:(NSURL *)url { NSURL *directory = self.pendingImportDirectory; if (!url.isFileURL || !directory) return NO; NSURL *parent = [url.URLByDeletingLastPathComponent URLByStandardizingPath]; return [parent isEqual:[directory URLByStandardizingPath]] && [url.pathExtension.lowercaseString isEqualToString:@"deb"]; }
- (void)discardPendingImportAtURL:(NSURL *)url { if ([self isPendingImportURL:url] || [self isPendingPackagePayloadURL:url]) [NSFileManager.defaultManager removeItemAtURL:url error:nil]; }
- (NSURL *)packageVaultDirectory { NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/PackageVault" isDirectory:YES]; [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]; return directory; }
- (NSDictionary<NSString *, NSURL *> *)verifiedVaultPackagesByIdentity {
    NSMutableDictionary *result = [NSMutableDictionary dictionary]; NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.packageVaultDirectory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *url in files) { if (![url.pathExtension.lowercaseString isEqualToString:@"deb"]) continue; NSDictionary *payload = ATMValidatedBackupPayload(self.environment, url); if (!payload) continue; NSString *identity = [NSString stringWithFormat:@"%@\n%@", payload[@"packageID"], payload[@"version"]]; result[identity] = url; }
    return result;
}
- (NSUInteger)verifiedPackageVaultCount { return self.verifiedVaultPackagesByIdentity.count; }
- (NSDictionary *)importPackagePayloadFromURL:(NSURL *)sourceURL error:(NSError **)error {
    NSDictionary *payload = ATMValidatedBackupPayload(self.environment, sourceURL);
    if (!payload) { if (error) *error = ATMBackupError(79, @"This file is not a supported, safe Rootless package DEB."); return nil; }
    NSString *sha = payload[@"sha256"]; NSURL *destination = [self.packageVaultDirectory URLByAppendingPathComponent:[sha stringByAppendingPathExtension:@"deb"]];
    if (![NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        NSURL *partial = [self.packageVaultDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", NSUUID.UUID.UUIDString]];
        NSInteger failureCode = 0; if (!ATMCopyFileContents(sourceURL, partial, &failureCode) || ![ATMSHA256ForFile(partial, nil).lowercaseString isEqualToString:sha] || ![NSFileManager.defaultManager moveItemAtURL:partial toURL:destination error:error]) { [NSFileManager.defaultManager removeItemAtURL:partial error:nil]; if (error && !*error) *error = ATMBackupError(failureCode ?: 80, @"The verified package could not be saved to the local package vault."); return nil; }
        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:destination.path error:nil];
    }
    return @{ @"packageID": payload[@"packageID"], @"version": payload[@"version"], @"architecture": payload[@"architecture"], @"sha256": sha };
}
- (NSArray<NSURL *> *)availableBackups { NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.backupDirectory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]; NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { (void)bindings; return [url.pathExtension.lowercaseString isEqualToString:@"aaztmbackup"]; }]; return [[files filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { BOOL ap = [self isBackupPinned:a], bp = [self isBackupPinned:b]; if (ap != bp) return ap ? NSOrderedAscending : NSOrderedDescending; NSDate *ad = nil, *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil]; return [bd ?: NSDate.distantPast compare:ad ?: NSDate.distantPast]; }]; }
- (NSDictionary<NSString *, NSURL *> *)cachedPackagesByIdentity { NSMutableDictionary *result = [self.verifiedVaultPackagesByIdentity mutableCopy]; NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.environment.aptCachePath isDirectory:YES] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]; for (NSURL *url in files) { if (![url.pathExtension.lowercaseString isEqualToString:@"deb"]) continue; NSDictionary *payload = ATMValidatedBackupPayload(self.environment, url); if (!payload) continue; NSString *identity = [NSString stringWithFormat:@"%@\n%@", payload[@"packageID"], payload[@"version"]]; if (!result[identity]) result[identity] = url; } return result; }
- (NSString *)backupExecutableForPaths:(NSArray<NSString *> *)paths { for (NSString *path in paths) { NSString *candidate = [self.environment pathInsideRoot:path]; if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate; } return nil; }
- (NSDictionary *)authenticatedRepositoryMetadataForRecord:(ATMPackageRecord *)record {
    NSString *aptCache = [self backupExecutableForPaths:@[@"/usr/bin/apt-cache", @"/bin/apt-cache"]]; if (!aptCache.length) return nil;
    NSString *request = [NSString stringWithFormat:@"%@=%@", record.packageID, record.version]; NSDictionary *run = ATMRunBackupTool(aptCache, @[@"show", request]); if ([run[@"exitCode"] integerValue] != 0) return nil;
    for (NSDictionary *fields in ATMParseDebianParagraphs(run[@"output"] ?: @"")) {
        NSString *packageID = fields[@"Package"] ?: @"", *version = fields[@"Version"] ?: @"", *architecture = fields[@"Architecture"] ?: @"", *sha = [fields[@"SHA256"] lowercaseString] ?: @"", *priority = [fields[@"Priority"] lowercaseString] ?: @"", *essential = [fields[@"Essential"] lowercaseString] ?: @"no";
        unsigned long long size = [fields[@"Size"] longLongValue]; BOOL safeHash = sha.length == 64 && [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
        if ([packageID isEqualToString:record.packageID] && [version isEqualToString:record.version] && [@[@"iphoneos-arm64", @"all"] containsObject:architecture] && safeHash && size > 0 && size <= 256ULL * 1024ULL * 1024ULL && ![essential isEqualToString:@"yes"] && ![@[@"required", @"important"] containsObject:priority] && ![ATMProtectedPackageIDs() containsObject:packageID.lowercaseString]) return @{ @"sha256": sha, @"size": @(size) };
    }
    return nil;
}
- (NSURL *)acquireAuthenticatedRepositoryPackageForRecord:(ATMPackageRecord *)record root:(NSURL *)root {
    NSDictionary *metadata = [self authenticatedRepositoryMetadataForRecord:record]; if (!metadata) return nil;
    NSString *aptGet = [self backupExecutableForPaths:@[@"/usr/bin/apt-get", @"/bin/apt-get"]]; if (!aptGet.length) return nil;
    NSURL *archives = [root URLByAppendingPathComponent:@"archives" isDirectory:YES], *partial = [archives URLByAppendingPathComponent:@"partial" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:partial withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) return nil;
    NSString *archiveOption = [NSString stringWithFormat:@"Dir::Cache::archives=%@/", archives.path]; NSString *request = [NSString stringWithFormat:@"%@=%@", record.packageID, record.version];
    NSArray *arguments = @[@"--download-only", @"--reinstall", @"--yes", @"--no-remove", @"--no-install-recommends", @"-o", @"APT::Get::AllowUnauthenticated=false", @"-o", @"APT::Get::Allow-Downgrades=false", @"-o", @"APT::Get::Allow-Change-Held-Packages=false", @"-o", @"Acquire::AllowInsecureRepositories=false", @"-o", @"Acquire::AllowDowngradeToInsecureRepositories=false", @"-o", @"Acquire::Retries=0", @"-o", @"Debug::NoLocking=true", @"-o", archiveOption, @"install", request];
    NSDictionary *run = ATMRunBackupTool(aptGet, arguments); if ([run[@"exitCode"] integerValue] != 0) return nil;
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:archives includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *url in files) { if (![url.pathExtension.lowercaseString isEqualToString:@"deb"]) continue; NSDictionary *payload = ATMValidatedBackupPayload(self.environment, url); if (![payload[@"packageID"] isEqualToString:record.packageID] || ![payload[@"version"] isEqualToString:record.version] || ![payload[@"sha256"] isEqualToString:metadata[@"sha256"]] || [payload[@"size"] unsignedLongLongValue] != [metadata[@"size"] unsignedLongLongValue]) continue; return url; }
    return nil;
}
- (NSArray<ATMPackageRecord *> *)packagesIncludingDependenciesForSelected:(NSArray<ATMPackageRecord *> *)selected allPackages:(NSArray<ATMPackageRecord *> *)allPackages {
    NSMutableDictionary<NSString *, ATMPackageRecord *> *installed = [NSMutableDictionary dictionary];
    for (ATMPackageRecord *record in allPackages) if (record.packageID.length) installed[record.packageID.lowercaseString] = record;
    for (ATMPackageRecord *record in allPackages) for (NSString *provided in [record.provides componentsSeparatedByString:@","]) {
        NSString *token = [provided stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; NSRange delimiter = [token rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" ([:<"]];
        if (delimiter.location != NSNotFound) token = [token substringToIndex:delimiter.location];
        if (token.length && !installed[token.lowercaseString]) installed[token.lowercaseString] = record;
    }
    NSMutableOrderedSet<NSString *> *included = [NSMutableOrderedSet orderedSet]; NSMutableArray<ATMPackageRecord *> *queue = [NSMutableArray array];
    for (ATMPackageRecord *record in selected) if (record.personalCandidate && ![ATMProtectedPackageIDs() containsObject:record.packageID.lowercaseString]) { [included addObject:record.packageID.lowercaseString]; [queue addObject:record]; }
    for (NSUInteger cursor = 0; cursor < queue.count && included.count <= 500; cursor++) {
        ATMPackageRecord *record = queue[cursor];
        for (NSString *group in [record.depends componentsSeparatedByString:@","]) {
            ATMPackageRecord *dependency = nil;
            for (NSString *alternative in [group componentsSeparatedByString:@"|"]) {
                NSString *token = [alternative stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSRange delimiter = [token rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" ([:<"]];
                if (delimiter.location != NSNotFound) token = [token substringToIndex:delimiter.location];
                dependency = installed[token.lowercaseString]; if (dependency) break;
            }
            if (!dependency || dependency.essential || [@[@"required", @"important"] containsObject:dependency.priority.lowercaseString] || [ATMProtectedPackageIDs() containsObject:dependency.packageID.lowercaseString] || [included containsObject:dependency.packageID.lowercaseString]) continue;
            [included addObject:dependency.packageID.lowercaseString]; [queue addObject:dependency];
        }
    }
    return queue.count <= 500 ? queue : @[];
}

- (NSDictionary *)repackInventoryForRecord:(ATMPackageRecord *)record failureStage:(NSString **)failureStage {
    NSString *dpkgQuery = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-query", @"/bin/dpkg-query"]];
    NSString *dpkg = [self backupExecutableForPaths:@[@"/usr/bin/dpkg", @"/bin/dpkg"]];
    if (!dpkgQuery.length || !dpkg.length) { if (failureStage) *failureStage = @"tools"; return nil; }
    NSDictionary *md5sums = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-show", record.packageID, @"md5sums"], NO, nil);
    NSString *verifiedFileInventory = [md5sums[@"exitCode"] integerValue] == 0 ? [md5sums[@"output"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSDictionary *conffiles = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-show", record.packageID, @"conffiles"], NO, nil);
    NSString *configurationInventory = [conffiles[@"exitCode"] integerValue] == 0 ? [conffiles[@"output"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (configurationInventory.length) { if (failureStage) *failureStage = @"privacy"; return nil; }
    NSDictionary *listing = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--listfiles", record.packageID], NO, nil);
    if ([listing[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"inventory"; return nil; }
    NSMutableArray<NSString *> *listedPaths = [NSMutableArray array];
    __block BOOL valid = YES;
    [listing[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *path = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!path.length || [path isEqualToString:@"/"] || [path isEqualToString:@"/."]) return;
        if (![path hasPrefix:@"/"] || [path containsString:@".."] || [path containsString:@"\0"] || [path containsString:@"\r"] || [path containsString:@"\n"]) { valid = NO; *stop = YES; return; }
        [listedPaths addObject:path];
    }];
    if (!valid || !listedPaths.count || listedPaths.count > 20000) { if (failureStage) *failureStage = @"inventory"; return nil; }
    NSUInteger directMatches = 0, rootedMatches = 0;
    for (NSString *path in listedPaths) {
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) == 0) directMatches++;
        NSString *rootedPath = [self.environment pathInsideRoot:path];
        if (rootedPath.length && lstat(rootedPath.fileSystemRepresentation, &info) == 0) rootedMatches++;
    }
    // A Rootless payload can be visible through both / and /var/jb because of
    // bootstrap redirection symlinks. Prefer the actual jailbreak root whenever
    // it contains the complete dpkg inventory; a numeric tie must not select /.
    NSString *payloadRoot = (self.environment.jailbreakRoot.length && rootedMatches == listedPaths.count) ? self.environment.jailbreakRoot : @"/";
    if ([payloadRoot isEqualToString:@"/"] && directMatches != listedPaths.count) { if (failureStage) *failureStage = @"payload"; return nil; }
    NSArray<NSString *> *privateRoots = @[@"/var/mobile", @"/private/var/mobile", @"/User", @"/home", @"/root", @"/tmp", @"/var/tmp", @"/var/log", @"/var/lib/apt", @"/var/lib/dpkg", @"/etc", @"/Library/Preferences", @"/var/jb/Library/Preferences", @"/var/jb/etc"];
    NSMutableOrderedSet<NSString *> *archivePaths = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *directoryPaths = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *pathsWithListedDescendants = [NSMutableSet set];
    for (NSString *listedPath in listedPaths) {
        NSString *parent = [listedPath stringByDeletingLastPathComponent];
        while (parent.length > 1) {
            [pathsWithListedDescendants addObject:parent];
            NSString *next = [parent stringByDeletingLastPathComponent];
            if ([next isEqualToString:parent]) break;
            parent = next;
        }
    }
    for (NSString *path in listedPaths) {
        NSString *physicalPath = [payloadRoot isEqualToString:@"/"] ? path : [payloadRoot stringByAppendingString:path];
        struct stat info; if (lstat(physicalPath.fileSystemRepresentation, &info) != 0) { if (failureStage) *failureStage = @"payload"; return nil; }
        if (!S_ISREG(info.st_mode) && !S_ISDIR(info.st_mode) && !S_ISLNK(info.st_mode)) { if (failureStage) *failureStage = @"privacy"; return nil; }
        BOOL privatePath = NO;
        for (NSString *root in privateRoots) if ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]] || [physicalPath isEqualToString:root] || [physicalPath hasPrefix:[root stringByAppendingString:@"/"]]) { privatePath = YES; break; }
        if (privatePath) { if (S_ISDIR(info.st_mode)) continue; if (failureStage) *failureStage = @"privacy"; return nil; }
        if (S_ISLNK(info.st_mode)) {
            NSString *target = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:physicalPath error:nil] ?: @"";
            if (!target.length || [target containsString:@"\0"] || [target containsString:@"\r"] || [target containsString:@"\n"]) { if (failureStage) *failureStage = @"privacy"; return nil; }
            for (NSString *root in privateRoots) if ([target isEqualToString:root] || [target hasPrefix:[root stringByAppendingString:@"/"]]) { if (failureStage) *failureStage = @"privacy"; return nil; }
        }
        NSString *relativePath = [path substringFromIndex:1];
        if (S_ISDIR(info.st_mode)) [directoryPaths addObject:relativePath];
        else if (S_ISLNK(info.st_mode) && [pathsWithListedDescendants containsObject:path]) {
            struct stat resolvedInfo;
            if (stat(physicalPath.fileSystemRepresentation, &resolvedInfo) != 0 || !S_ISDIR(resolvedInfo.st_mode)) { if (failureStage) *failureStage = @"payload"; return nil; }
            // Rootless redirection symlinks cannot coexist with listed children in
            // a contained DEB tree; reconstruct them as logical directories.
            [directoryPaths addObject:relativePath];
        }
        else [archivePaths addObject:relativePath];
    }
    if (!archivePaths.count) { if (failureStage) *failureStage = @"payload"; return nil; }
    if (verifiedFileInventory.length) {
        NSDictionary *verification = ATMRunBackupToolWithPrivilege(dpkg, @[@"--verify", record.packageID], YES, nil);
        NSString *changes = [verification[@"output"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([verification[@"exitCode"] integerValue] != 0 || changes.length) { if (failureStage) *failureStage = @"verification"; return nil; }
    }
    return @{ @"paths": archivePaths.array, @"directories": directoryPaths.array, @"root": payloadRoot };
}

- (BOOL)installedPackageCanBeRepackedWithoutPrivateData:(ATMPackageRecord *)record {
    return [self repackInventoryForRecord:record failureStage:nil] != nil;
}

- (BOOL)stagePayloadDirectlyFromRoot:(NSString *)payloadRoot paths:(NSArray<NSString *> *)safePaths directories:(NSArray<NSString *> *)directoryPaths stage:(NSURL *)stage failureStage:(NSString **)failureStage {
    NSString *copy = [self backupExecutableForPaths:@[@"/bin/cp", @"/usr/bin/cp"]];
    NSString *compare = [self backupExecutableForPaths:@[@"/usr/bin/cmp", @"/bin/cmp"]];
    NSString *chmodTool = [self backupExecutableForPaths:@[@"/bin/chmod", @"/usr/bin/chmod"]];
    if (!copy.length) { if (failureStage) *failureStage = @"direct-copy-tools"; return NO; }
    if (!ATMResetAndPreparePayloadStage(stage, payloadRoot, safePaths, directoryPaths, failureStage)) return NO;
    for (NSString *relativePath in safePaths) {
        if (self.backupCancellationRequested) { if (failureStage) *failureStage = @"cancelled"; return NO; }
        NSString *sourcePath = [payloadRoot isEqualToString:@"/"] ? [@"/" stringByAppendingString:relativePath] : [payloadRoot stringByAppendingPathComponent:relativePath];
        NSString *destinationPath = [stage.path stringByAppendingPathComponent:relativePath];
        NSDictionary *copyResult = ATMRunBackupToolWithPrivilege(copy, @[@"-P", sourcePath, destinationPath], YES, nil);
        if ([copyResult[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"direct-copy"; return NO; }
    }
    NSString *pruneFailure = ATMPruneUnexpectedStagedEntries(stage, safePaths, directoryPaths);
    if (pruneFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"direct-copy-verify", pruneFailure); return NO; }
    NSString *normalizationFailure = ATMNormalizeStagedPayloadModes(stage, payloadRoot, safePaths, directoryPaths, chmodTool);
    if (normalizationFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"direct-copy-verify", normalizationFailure); return NO; }
    NSString *verificationFailure = ATMStagedPayloadVerificationFailure(stage, payloadRoot, safePaths, directoryPaths, compare);
    if (verificationFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"direct-copy-verify", verificationFailure); return NO; }
    return YES;
}

- (NSDictionary *)runBackupPreflight:(NSError **)error {
    NSURL *root = [self newBackupWorkingRootNamed:@"preflight"];
    if (!root) {
        if (error) *error = ATMBackupError(91, @"Safe system check failed at preflight-workspace. No package or source data was changed.");
        return @{ @"passed": @NO, @"stage": @"preflight-workspace", @"privacy": @"fixed-stage-labels-only" };
    }
    NSURL *payloadRoot = [root URLByAppendingPathComponent:@"payload" isDirectory:YES], *sourceDirectory = [payloadRoot URLByAppendingPathComponent:@"usr/lib/aaz-preflight" isDirectory:YES];
    NSURL *directStage = [root URLByAppendingPathComponent:@"direct-stage" isDirectory:YES], *fallbackStage = [root URLByAppendingPathComponent:@"fallback-stage" isDirectory:YES], *stage = nil;
    NSURL *executable = [sourceDirectory URLByAppendingPathComponent:@"probe"], *link = [sourceDirectory URLByAppendingPathComponent:@"probe-link"];
    NSArray<NSString *> *directories = @[@"usr", @"usr/lib", @"usr/lib/aaz-preflight"], *paths = @[@"usr/lib/aaz-preflight/probe", @"usr/lib/aaz-preflight/probe-link"];
    NSString *failureStage = nil;
    NSMutableArray<NSString *> *observedStages = [NSMutableArray array];
    NSString *dpkgDeb = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-deb", @"/bin/dpkg-deb"]];
    NSString *dpkg = [self backupExecutableForPaths:@[@"/usr/bin/dpkg", @"/bin/dpkg"]];
    BOOL passed = dpkgDeb.length && dpkg.length;
    if (!passed) failureStage = @"preflight-tools";
    if (passed && [ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--version"], YES, nil)[@"exitCode"] integerValue] != 0) { passed = NO; failureStage = @"preflight-persona"; }
    NSData *probeData = [@"AAZ safe preflight\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (passed && (![NSFileManager.defaultManager createDirectoryAtURL:sourceDirectory withIntermediateDirectories:YES attributes:nil error:nil] || ![probeData writeToURL:executable options:NSDataWritingAtomic error:nil] || chmod(executable.path.fileSystemRepresentation, 0755) != 0 || symlink("probe", link.path.fileSystemRepresentation) != 0)) { passed = NO; failureStage = @"preflight-staging"; }
    BOOL directSucceeded = NO, fallbackSucceeded = NO;
    if (passed) {
        NSString *directFailure = nil;
        directSucceeded = [self stagePayloadDirectlyFromRoot:payloadRoot.path paths:paths directories:directories stage:directStage failureStage:&directFailure];
        if (!directSucceeded && [directFailure isEqualToString:@"cancelled"]) { passed = NO; failureStage = @"cancelled"; }
        else if (!directSucceeded && directFailure.length) {
            NSString *reportedDirectStage = [directFailure hasPrefix:@"direct-copy"] ? [@"preflight-" stringByAppendingString:directFailure] : [@"preflight-direct-" stringByAppendingString:directFailure];
            [observedStages addObject:reportedDirectStage];
        }
    }
    if (passed) {
        NSString *tar = [self backupExecutableForPaths:@[@"/usr/bin/tar", @"/bin/tar"]];
        NSURL *fileList = [root URLByAppendingPathComponent:@"preflight-files"], *tarURL = [root URLByAppendingPathComponent:@"preflight.tar"];
        NSData *fileListData = [[[[paths componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding] copy];
        NSString *fallbackFailure = nil;
        if (!tar.length || ![fileListData writeToURL:fileList options:NSDataWritingAtomic error:nil] || !ATMResetAndPreparePayloadStage(fallbackStage, payloadRoot.path, paths, directories, &fallbackFailure)) {
            fallbackFailure = @"preflight-fallback-staging";
        } else if ([ATMRunBackupToolWithPrivilege(tar, @[@"-c", @"-p", @"-f", tarURL.path, @"-C", payloadRoot.path, @"-T", fileList.path], YES, nil)[@"exitCode"] integerValue] != 0) {
            fallbackFailure = @"preflight-fallback-create";
        } else if ([ATMRunBackupToolWithPrivilege(tar, @[@"-x", @"-m", @"-f", tarURL.path, @"-C", fallbackStage.path], YES, nil)[@"exitCode"] integerValue] != 0) {
            fallbackFailure = @"preflight-fallback-extract";
        } else {
            NSString *compare = [self backupExecutableForPaths:@[@"/usr/bin/cmp", @"/bin/cmp"]];
            NSString *chmodTool = [self backupExecutableForPaths:@[@"/bin/chmod", @"/usr/bin/chmod"]];
            NSString *pruneFailure = ATMPruneUnexpectedStagedEntries(fallbackStage, paths, directories);
            if (pruneFailure) fallbackFailure = ATMVerificationStage(@"preflight-fallback-verify", pruneFailure);
            NSString *normalizationFailure = fallbackFailure ? nil : ATMNormalizeStagedPayloadModes(fallbackStage, payloadRoot.path, paths, directories, chmodTool);
            if (normalizationFailure) fallbackFailure = ATMVerificationStage(@"preflight-fallback-verify", normalizationFailure);
            NSString *verificationFailure = fallbackFailure ? nil : ATMStagedPayloadVerificationFailure(fallbackStage, payloadRoot.path, paths, directories, compare);
            if (verificationFailure) fallbackFailure = ATMVerificationStage(@"preflight-fallback-verify", verificationFailure);
        }
        fallbackSucceeded = !fallbackFailure.length;
        if (!fallbackSucceeded) [observedStages addObject:fallbackFailure];
        if (!directSucceeded && !fallbackSucceeded) { passed = NO; failureStage = fallbackFailure ?: @"preflight-unknown"; }
        else stage = directSucceeded ? directStage : fallbackStage;
    }
    NSURL *debian = [stage URLByAppendingPathComponent:@"DEBIAN" isDirectory:YES], *controlURL = [debian URLByAppendingPathComponent:@"control"], *debURL = [root URLByAppendingPathComponent:@"preflight.deb"];
    NSData *controlData = [@"Package: com.aaz.preflight\nVersion: 1\nArchitecture: iphoneos-arm64\nDescription: AAZ safe synthetic preflight\nMaintainer: AAZ\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (passed && (![NSFileManager.defaultManager createDirectoryAtURL:debian withIntermediateDirectories:YES attributes:nil error:nil] || ![controlData writeToURL:controlURL options:NSDataWritingAtomic error:nil])) { passed = NO; failureStage = @"preflight-control"; }
    if (passed && [ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--build", stage.path, debURL.path], YES, nil)[@"exitCode"] integerValue] != 0) { passed = NO; failureStage = @"preflight-build"; }
    NSString *identityFailure = nil;
    NSDictionary *payload = passed ? ATMValidatedBackupPayloadWithFailure(self.environment, debURL, &identityFailure) : nil;
    if (passed && !payload) { passed = NO; failureStage = [@"preflight-" stringByAppendingString:identityFailure ?: @"identity-unknown"]; }
    if (passed && ![payload[@"packageID"] isEqualToString:@"com.aaz.preflight"]) { passed = NO; failureStage = @"preflight-identity-package"; }
    if (passed && ![payload[@"version"] isEqualToString:@"1"]) { passed = NO; failureStage = @"preflight-identity-version"; }
    if (passed && ![payload[@"architecture"] isEqualToString:@"iphoneos-arm64"]) { passed = NO; failureStage = @"preflight-identity-architecture"; }
    NSURL *reopen = [root URLByAppendingPathComponent:@"reopen" isDirectory:YES];
    if (passed && ![NSFileManager.defaultManager createDirectoryAtURL:reopen withIntermediateDirectories:NO attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) { passed = NO; failureStage = @"preflight-reopen-directory"; }
    if (passed && [ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--extract", debURL.path, reopen.path], YES, nil)[@"exitCode"] integerValue] != 0) { passed = NO; failureStage = @"preflight-reopen"; }
    NSString *compare = [self backupExecutableForPaths:@[@"/usr/bin/cmp", @"/bin/cmp"]];
    if (passed) {
        NSString *verificationFailure = ATMStagedPayloadVerificationFailure(reopen, payloadRoot.path, paths, directories, compare);
        if (verificationFailure) { passed = NO; failureStage = ATMVerificationStage(@"preflight-payload-verify", verificationFailure); }
    }
    if (passed && [ATMRunBackupToolWithPrivilege(dpkg, @[@"--no-act", @"--refuse-downgrade", @"--install", debURL.path], YES, nil)[@"exitCode"] integerValue] != 0) { passed = NO; failureStage = @"preflight-restore-dry-run"; }
    NSURL *archiveURL = [root URLByAppendingPathComponent:@"preflight.aaztmbackup"];
    if (passed) {
        NSString *sha = ATMSHA256ForFile(debURL, nil);
        NSDictionary *manifest = @{ @"format": @"com.aaz.tweakmanager.backup", @"formatVersion": @1, @"createdAt": ATMISODateString([NSDate date]), @"selfTestNonce": NSUUID.UUID.UUIDString, @"rootless": @YES, @"architecture": @"iphoneos-arm64", @"packages": @[@{ @"packageID": @"com.aaz.preflight", @"version": @"1", @"architecture": @"iphoneos-arm64", @"debStatus": @"exact-cache", @"payloadOrigin": @"verified-repack", @"debPath": @"packages/preflight.deb", @"sha256": sha ?: @"" }], @"sources": @[], @"portable": @YES, @"payloadCoverage": @100, @"missingPayloadCount": @0, @"captureFailureCounts": @{}, @"credentialsIncluded": @NO, @"restoreExecutionIncluded": @NO, @"atomicWrite": @YES };
        NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:nil]; NSError *writerError = nil;
        ATMZipWriter *writer = [[ATMZipWriter alloc] initWithDestinationURL:archiveURL error:&writerError];
        if (!writer || ![writer addFileURL:debURL path:@"packages/preflight.deb" error:&writerError] || ![writer addData:manifestData path:@"manifest.json" error:&writerError] || ![writer close:&writerError] || !ATMValidateStoredZipArchive(archiveURL, &writerError)) { passed = NO; failureStage = @"preflight-archive"; }
    }
    NSDictionary *report = passed ? [self backupReportForURL:archiveURL password:nil error:nil] : nil;
    if (passed && (![report[@"portable"] boolValue] || [report[@"badHashCount"] unsignedIntegerValue] != 0)) { passed = NO; failureStage = @"preflight-archive-verify"; }
    NSURL *inbox = self.pendingImportDirectory, *inboxProbe = [inbox URLByAppendingPathComponent:[NSString stringWithFormat:@".selftest-%@.aaztmbackup", NSUUID.UUID.UUIDString]];
    NSInteger inboxCopyFailure = 0;
    if (passed && (!inbox || !ATMCopyFileContents(archiveURL, inboxProbe, &inboxCopyFailure))) { passed = NO; failureStage = @"preflight-share-inbox"; }
    NSURL *stagedImport = nil, *importedBackup = nil;
    if (passed) {
        ATMPushImportDiagnosticSuppression(); self.importSelfTestActive = YES;
        NSError *importError = nil;
        stagedImport = [self stageImportFromURL:inboxProbe error:&importError];
        importedBackup = stagedImport ? [self importBackupFromURL:stagedImport password:nil error:&importError] : nil;
        self.importSelfTestActive = NO; ATMPopImportDiagnosticSuppression();
        NSDictionary *importReport = importedBackup ? [self backupReportForURL:importedBackup password:nil error:nil] : nil;
        if (!importedBackup || ![importReport[@"portable"] boolValue] || [importReport[@"badHashCount"] unsignedIntegerValue] != 0) { passed = NO; failureStage = @"preflight-import"; }
    }
    if (importedBackup) [NSFileManager.defaultManager removeItemAtURL:importedBackup error:nil];
    if (stagedImport) [self discardStagedImportAtURL:stagedImport];
    [NSFileManager.defaultManager removeItemAtURL:inboxProbe error:nil];
    NSURL *encryptedProbe = [root URLByAppendingPathComponent:@"selftest-encrypted.aaztmbackup"];
    NSURL *encryptedInbox = [inbox URLByAppendingPathComponent:[NSString stringWithFormat:@".selftest-%@-encrypted.aaztmbackup", NSUUID.UUID.UUIDString]];
    NSString *selfTestPassword = @"AAZ-Self-Test-Beta51";
    if (passed) {
        NSData *plain = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:nil];
        NSData *encrypted = plain ? ATMEncryptArchive(plain, selfTestPassword, nil) : nil;
        if (!encrypted || ![encrypted writeToURL:encryptedProbe options:NSDataWritingAtomic error:nil]) { passed = NO; failureStage = @"preflight-import"; }
    }
    if (passed) {
        NSError *wrongPasswordError = nil;
        NSDictionary *wrongPasswordReport = [self backupReportForURL:encryptedProbe password:@"incorrect-self-test-password" error:&wrongPasswordError];
        if (wrongPasswordReport || wrongPasswordError.code != ATMBackupErrorWrongPassword) { passed = NO; failureStage = @"preflight-import"; }
    }
    if (passed && !ATMCopyFileContents(encryptedProbe, encryptedInbox, &inboxCopyFailure)) { passed = NO; failureStage = @"preflight-share-inbox"; }
    NSURL *encryptedStaged = nil, *encryptedImported = nil;
    if (passed) {
        ATMPushImportDiagnosticSuppression(); self.importSelfTestActive = YES;
        NSError *encryptedImportError = nil;
        encryptedStaged = [self stageImportFromURL:encryptedInbox error:&encryptedImportError];
        encryptedImported = encryptedStaged ? [self importBackupFromURL:encryptedStaged password:selfTestPassword error:&encryptedImportError] : nil;
        self.importSelfTestActive = NO; ATMPopImportDiagnosticSuppression();
        NSDictionary *encryptedReport = encryptedImported ? [self backupReportForURL:encryptedImported password:selfTestPassword error:nil] : nil;
        if (!encryptedImported || ![encryptedReport[@"portable"] boolValue] || [encryptedReport[@"badHashCount"] unsignedIntegerValue] != 0) { passed = NO; failureStage = @"preflight-import"; }
    }
    if (encryptedImported) [NSFileManager.defaultManager removeItemAtURL:encryptedImported error:nil];
    if (encryptedStaged) [self discardStagedImportAtURL:encryptedStaged];
    [NSFileManager.defaultManager removeItemAtURL:encryptedInbox error:nil];
    [NSFileManager.defaultManager removeItemAtURL:encryptedProbe error:nil];
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    if (!passed && failureStage.length && ![observedStages containsObject:failureStage]) [observedStages addObject:failureStage];
    if (!passed && error) *error = ATMBackupError(91, [NSString stringWithFormat:@"Safe system check failed at %@. No package or source data was changed.", failureStage ?: @"preflight-unknown"]);
    return @{ @"passed": @(passed), @"stage": passed ? @"preflight-complete" : (failureStage ?: @"preflight-unknown"), @"stages": observedStages, @"privacy": @"fixed-stage-labels-only" };
}

- (NSURL *)repackInstalledPackageForRecord:(ATMPackageRecord *)record root:(NSURL *)root failureStage:(NSString **)failureStage observedFailureStages:(NSArray<NSString *> **)observedFailureStages {
    NSMutableArray<NSString *> *observed = [NSMutableArray array];
    if (observedFailureStages) *observedFailureStages = @[];
    NSDictionary *inventory = [self repackInventoryForRecord:record failureStage:failureStage]; if (!inventory) return nil;
    NSString *dpkgQuery = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-query", @"/bin/dpkg-query"]];
    NSString *dpkgDeb = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-deb", @"/bin/dpkg-deb"]];
    NSString *tar = [self backupExecutableForPaths:@[@"/usr/bin/tar", @"/bin/tar"]];
    if (!dpkgQuery.length || !dpkgDeb.length || !tar.length || ![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) { if (failureStage) *failureStage = @"tools"; return nil; }
    NSDictionary *status = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--status", record.packageID], NO, nil);
    NSDictionary *fields = [status[@"exitCode"] integerValue] == 0 ? ATMParseDebianParagraph(status[@"output"] ?: @"") : nil;
    NSData *controlData = fields ? ATMRepackedControlData(fields) : nil;
    if (!controlData.length) { if (failureStage) *failureStage = @"control"; return nil; }
    NSArray<NSString *> *safePaths = inventory[@"paths"], *directoryPaths = inventory[@"directories"] ?: @[]; NSString *payloadRoot = inventory[@"root"];
    if (!safePaths.count) { if (failureStage) *failureStage = @"payload"; return nil; }
    NSURL *fileListURL = [root URLByAppendingPathComponent:@"payload-files"], *tarURL = [root URLByAppendingPathComponent:@"payload.tar"], *stage = [root URLByAppendingPathComponent:@"stage" isDirectory:YES];
    NSData *fileListData = [[[safePaths componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (![fileListData writeToURL:fileListURL options:NSDataWritingAtomic error:nil]) { if (failureStage) *failureStage = @"staging"; return nil; }
    NSString *directFailure = nil;
    BOOL staged = [self stagePayloadDirectlyFromRoot:payloadRoot paths:safePaths directories:directoryPaths stage:stage failureStage:&directFailure];
    if (!staged && ![directFailure isEqualToString:@"cancelled"]) {
        if (directFailure.length) [observed addObject:directFailure];
        if (observedFailureStages) *observedFailureStages = [observed copy];
        if (!ATMResetAndPreparePayloadStage(stage, payloadRoot, safePaths, directoryPaths, failureStage)) return nil;
        NSDictionary *archive = ATMRunBackupToolWithPrivilege(tar, @[@"-c", @"-p", @"-f", tarURL.path, @"-C", payloadRoot, @"-T", fileListURL.path], YES, nil);
        if ([archive[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"archive-fallback-create"; return nil; }
        NSDictionary *extract = ATMRunBackupToolWithPrivilege(tar, @[@"-x", @"-m", @"-f", tarURL.path, @"-C", stage.path], YES, nil);
        if ([extract[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"archive-fallback-extract"; return nil; }
        NSString *compare = [self backupExecutableForPaths:@[@"/usr/bin/cmp", @"/bin/cmp"]];
        NSString *chmodTool = [self backupExecutableForPaths:@[@"/bin/chmod", @"/usr/bin/chmod"]];
        NSString *pruneFailure = ATMPruneUnexpectedStagedEntries(stage, safePaths, directoryPaths);
        if (pruneFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"archive-fallback-verify", pruneFailure); return nil; }
        NSString *normalizationFailure = ATMNormalizeStagedPayloadModes(stage, payloadRoot, safePaths, directoryPaths, chmodTool);
        if (normalizationFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"archive-fallback-verify", normalizationFailure); return nil; }
        NSString *verificationFailure = ATMStagedPayloadVerificationFailure(stage, payloadRoot, safePaths, directoryPaths, compare);
        if (verificationFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"archive-fallback-verify", verificationFailure); return nil; }
    } else if (!staged) {
        if (failureStage) *failureStage = @"cancelled";
        return nil;
    }
    NSURL *debian = [stage URLByAppendingPathComponent:@"DEBIAN" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:debian withIntermediateDirectories:YES attributes:nil error:nil] || ![controlData writeToURL:[debian URLByAppendingPathComponent:@"control"] options:NSDataWritingAtomic error:nil]) { if (failureStage) *failureStage = @"control"; return nil; }
    NSDictionary *controlList = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-list", record.packageID], NO, nil);
    if ([controlList[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"control"; return nil; }
    __block BOOL controlsValid = YES;
    [controlList[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *normalizedName = [[[[name stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@"_" withString:@""] stringByReplacingOccurrencesOfString:@"." withString:@""] stringByReplacingOccurrencesOfString:@"+" withString:@""];
        BOOL safeName = name.length && name.length <= 64 && normalizedName.length && [normalizedName rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound;
        if (!safeName || [name isEqualToString:@"control"] || [name containsString:@".."]) return;
        NSDictionary *item = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-show", record.packageID, name], NO, nil);
        NSData *data = [item[@"output"] dataUsingEncoding:NSUTF8StringEncoding];
        if ([item[@"exitCode"] integerValue] != 0 || !data.length || data.length > 2ULL * 1024ULL * 1024ULL || ![data writeToURL:[debian URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil]) { controlsValid = NO; *stop = YES; return; }
        BOOL executable = [@[@"preinst", @"postinst", @"prerm", @"postrm", @"config"] containsObject:name];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @(executable ? 0755 : 0644)} ofItemAtPath:[debian URLByAppendingPathComponent:name].path error:nil];
    }];
    if (!controlsValid) { if (failureStage) *failureStage = @"control"; return nil; }
    NSURL *output = [root URLByAppendingPathComponent:@"repacked.deb"];
    NSDictionary *build = ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--build", stage.path, output.path], YES, nil);
    NSString *identityFailure = nil;
    NSDictionary *payload = [build[@"exitCode"] integerValue] == 0 ? ATMValidatedBackupPayloadWithFailure(self.environment, output, &identityFailure) : nil;
    if ([build[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"build"; return nil; }
    if (!payload) { if (failureStage) *failureStage = identityFailure ?: @"identity-unknown"; return nil; }
    if (![payload[@"packageID"] isEqualToString:record.packageID]) { if (failureStage) *failureStage = @"identity-package"; return nil; }
    if (![payload[@"version"] isEqualToString:record.version]) { if (failureStage) *failureStage = @"identity-version"; return nil; }
    if (![payload[@"architecture"] isEqualToString:record.architecture]) { if (failureStage) *failureStage = @"identity-architecture"; return nil; }
    NSURL *reopen = [root URLByAppendingPathComponent:@"reopen" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:reopen withIntermediateDirectories:NO attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) { if (failureStage) *failureStage = @"package-reopen-directory"; return nil; }
    NSDictionary *reopenResult = ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--extract", output.path, reopen.path], YES, nil);
    if ([reopenResult[@"exitCode"] integerValue] != 0) { if (failureStage) *failureStage = @"package-reopen"; return nil; }
    NSString *compare = [self backupExecutableForPaths:@[@"/usr/bin/cmp", @"/bin/cmp"]];
    NSString *reopenVerificationFailure = ATMStagedPayloadVerificationFailure(reopen, payloadRoot, safePaths, directoryPaths, compare);
    if (reopenVerificationFailure) { if (failureStage) *failureStage = ATMVerificationStage(@"package-payload-verify", reopenVerificationFailure); return nil; }
    if (observedFailureStages) *observedFailureStages = [observed copy];
    return output;
}

- (NSDictionary<NSString *, NSURL *> *)portablePackagesForRecords:(NSArray<ATMPackageRecord *> *)records acquisitionRoot:(NSURL **)acquisitionRoot origins:(NSDictionary<NSString *, NSString *> **)origins failureCounts:(NSDictionary<NSString *, NSNumber *> **)failureCounts progressHandler:(ATMBackupProgressHandler)progressHandler {
    NSMutableDictionary *packages = [[self cachedPackagesByIdentity] mutableCopy]; NSMutableDictionary *payloadOrigins = [NSMutableDictionary dictionary];
    for (NSString *identity in packages) payloadOrigins[identity] = @"original";
    NSMutableDictionary<NSString *, NSNumber *> *failures = [NSMutableDictionary dictionary]; NSURL *root = [self newBackupWorkingRootNamed:@"acquire"];
    if (!root) { failures[@"workspace"] = @(records.count); if (acquisitionRoot) *acquisitionRoot = nil; if (origins) *origins = payloadOrigins; if (failureCounts) *failureCounts = failures; return packages; }
    NSUInteger completed = 0;
    for (ATMPackageRecord *record in records) {
        if (self.backupCancellationRequested) { failures[@"cancelled"] = @1; break; }
        if (progressHandler) progressHandler(@"Capturing package payloads", completed, records.count);
        NSString *identity = [NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]; if (packages[identity]) { completed++; continue; }
        NSURL *downloaded = [self acquireAuthenticatedRepositoryPackageForRecord:record root:root];
        if (downloaded) { packages[identity] = downloaded; payloadOrigins[identity] = @"original"; completed++; continue; }
        NSURL *repackRoot = [root URLByAppendingPathComponent:[NSString stringWithFormat:@"repack-%lu", (unsigned long)payloadOrigins.count] isDirectory:YES];
        NSString *failureStage = nil; NSArray<NSString *> *observedFailureStages = nil; NSURL *repacked = [self repackInstalledPackageForRecord:record root:repackRoot failureStage:&failureStage observedFailureStages:&observedFailureStages];
        for (NSString *observedStage in observedFailureStages) failures[observedStage] = @([failures[observedStage] unsignedIntegerValue] + 1);
        if (repacked) { packages[identity] = repacked; payloadOrigins[identity] = @"verified-repack"; }
        else { NSString *stage = failureStage ?: @"unknown"; failures[stage] = @([failures[stage] unsignedIntegerValue] + 1); }
        completed++;
    }
    if (progressHandler) progressHandler(@"Capturing package payloads", completed, records.count);
    if (acquisitionRoot) *acquisitionRoot = root; if (origins) *origins = payloadOrigins; if (failureCounts) *failureCounts = failures; return packages;
}
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources error:(NSError **)error { return [self createBackupWithPackages:packages sources:sources profileName:nil password:nil error:error]; }
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources profileName:(NSString *)profileName password:(NSString *)password error:(NSError **)error { return [self createBackupWithPackages:packages sources:sources profileName:profileName password:password progressHandler:nil error:error]; }
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources profileName:(NSString *)profileName password:(NSString *)password progressHandler:(ATMBackupProgressHandler)progressHandler error:(NSError **)error {
    self.backupCancellationRequested = NO; self.lastBackupAttemptReport = nil;
    NSSet *selected = self.ledger.selectedPackageIDs; NSArray *primary = [packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate && [selected containsObject:record.packageID]; }]];
    if (!primary.count) { if (error) *error = ATMBackupError(30, @"No personal packages are selected."); return nil; }
    NSArray *chosen = [self packagesIncludingDependenciesForSelected:primary allPackages:packages];
    if (!chosen.count) { if (error) *error = ATMBackupError(83, @"The installed dependency closure is too large or could not be verified."); return nil; }
    if (progressHandler) progressHandler(@"Running safe system check", 0, 1);
    NSDictionary *preflight = [self runBackupPreflight:nil];
    NSMutableDictionary<NSString *, NSNumber *> *preflightFailureCounts = [NSMutableDictionary dictionary];
    NSArray<NSString *> *preflightStages = [preflight[@"stages"] isKindOfClass:NSArray.class] ? preflight[@"stages"] : @[];
    for (NSString *stage in preflightStages) if ([stage isKindOfClass:NSString.class] && stage.length) preflightFailureCounts[stage] = @1;
    if (!preflight || ![preflight[@"passed"] boolValue]) {
        NSString *preflightStage = [preflight[@"stage"] isKindOfClass:NSString.class] ? preflight[@"stage"] : @"preflight-unknown";
        BOOL cancelled = [preflightStage isEqualToString:@"cancelled"];
        if (cancelled) {
            NSUInteger restorableSourceCount = [[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMSourceRecord *source, NSDictionary *bindings) { (void)bindings; return !source.credentialsRedacted; }]] count];
            self.lastBackupAttemptReport = @{ @"health": @"Cancelled", @"portable": @NO, @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"restorableSourceCount": @(restorableSourceCount), @"cachedDEBCount": @0, @"repackedDEBCount": @0, @"missingPayloadCount": @(chosen.count), @"badHashCount": @0, @"packageHashFailureCount": @0, @"sourceHashFailureCount": @0, @"unreadableEntryCount": @0, @"captureFailureCounts": @{ @"cancelled": @1 }, @"manifest": @{ @"payloadCoverage": @0 } };
            if (error) *error = ATMBackupError(90, @"Backup cancelled. Temporary data was removed and no package or source data was changed.");
            return nil;
        }
        preflightFailureCounts[@"preflight-warning"] = @1;
        preflightFailureCounts[preflightStage] = @1;
        if (progressHandler) progressHandler(@"Safe check warning; continuing backup", 1, 1);
    } else if (preflightStages.count) {
        preflightFailureCounts[@"preflight-warning"] = @1;
    }
    if (progressHandler) progressHandler(@"Running safe system check", 1, 1);
    NSURL *acquisitionRoot = nil; NSDictionary *origins = nil, *packageCaptureFailureCounts = nil; NSDictionary *cache = [self portablePackagesForRecords:chosen acquisitionRoot:&acquisitionRoot origins:&origins failureCounts:&packageCaptureFailureCounts progressHandler:progressHandler];
    NSMutableDictionary<NSString *, NSNumber *> *combinedFailureCounts = [preflightFailureCounts mutableCopy];
    [packageCaptureFailureCounts enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) { (void)stop; combinedFailureCounts[key] = @([combinedFailureCounts[key] unsignedIntegerValue] + value.unsignedIntegerValue); }];
    NSDictionary *captureFailureCounts = [combinedFailureCounts copy];
    if (self.backupCancellationRequested) { [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; self.lastBackupAttemptReport = @{ @"health": @"Cancelled", @"portable": @NO, @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"restorableSourceCount": @0, @"cachedDEBCount": @0, @"repackedDEBCount": @0, @"missingPayloadCount": @(chosen.count), @"badHashCount": @0, @"packageHashFailureCount": @0, @"sourceHashFailureCount": @0, @"unreadableEntryCount": @0, @"captureFailureCounts": captureFailureCounts ?: @{ @"cancelled": @1 }, @"manifest": @{ @"payloadCoverage": @0 } }; if (error) *error = ATMBackupError(90, @"Backup cancelled. Temporary data was removed and no backup was created."); return nil; }
    NSUInteger capturedBeforeWrite = 0, repackedBeforeWrite = 0, restorableSourceCount = 0;
    for (ATMPackageRecord *record in chosen) { NSString *identity = [NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]; if (cache[identity]) { capturedBeforeWrite++; if ([origins[identity] isEqualToString:@"verified-repack"]) repackedBeforeWrite++; } }
    for (ATMSourceRecord *source in sources) if (!source.credentialsRedacted) restorableSourceCount++;
    NSUInteger preliminaryCoverage = chosen.count ? capturedBeforeWrite * 100 / chosen.count : 0;
    self.lastBackupAttemptReport = @{ @"health": capturedBeforeWrite == chosen.count ? @"Preparing" : @"Incomplete", @"portable": @NO, @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"restorableSourceCount": @(restorableSourceCount), @"cachedDEBCount": @(capturedBeforeWrite), @"repackedDEBCount": @(repackedBeforeWrite), @"missingPayloadCount": @(chosen.count - capturedBeforeWrite), @"badHashCount": @0, @"packageHashFailureCount": @0, @"sourceHashFailureCount": @0, @"unreadableEntryCount": @0, @"captureFailureCounts": captureFailureCounts ?: @{}, @"manifest": @{ @"payloadCoverage": @(preliminaryCoverage) } };
    if (progressHandler) progressHandler(@"Writing verified backup", 0, 1);
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSURL *finalURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"AAZ-Tweak-Backup-%@.aaztmbackup", stamp]], *zipURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", NSUUID.UUID.UUIDString]], *outputURL = password.length ? [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.encrypted.partial", NSUUID.UUID.UUIDString]] : zipURL;
    ATMZipWriter *writer = [[ATMZipWriter alloc] initWithDestinationURL:zipURL error:error]; if (!writer) { [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; return nil; } NSMutableArray *packageManifest = [NSMutableArray array];
    for (ATMPackageRecord *record in chosen) { if (self.backupCancellationRequested) { [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; if (error) *error = ATMBackupError(90, @"Backup cancelled. Temporary data was removed and no backup was created."); return nil; } NSMutableDictionary *entry = [[record manifestDictionary] mutableCopy]; NSString *identity = [NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]; entry[@"supportingDependency"] = @(![selected containsObject:record.packageID]); NSDate *firstSeen = [self.ledger firstSeenDateForPackageID:record.packageID]; if (firstSeen) entry[@"firstSeen"] = ATMISODateString(firstSeen); NSURL *debURL = cache[identity]; if (debURL) { NSString *safeName = [record.packageID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]; NSString *archivePath = [NSString stringWithFormat:@"packages/%@_%@.deb", safeName, record.version]; NSError *hashError = nil; NSString *sha = ATMSHA256ForFile(debURL, &hashError); if (!hashError && sha.length && [writer addFileURL:debURL path:archivePath error:error]) { entry[@"debPath"] = archivePath; entry[@"sha256"] = sha; entry[@"debStatus"] = @"exact-cache"; entry[@"payloadOrigin"] = origins[identity] ?: @"original"; } else entry[@"debStatus"] = @"unavailable"; } else entry[@"debStatus"] = @"unavailable"; [packageManifest addObject:entry]; }
    [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; NSUInteger embeddedCount = [[packageManifest filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count];
    NSMutableArray *sourceManifest = [NSMutableArray array]; NSUInteger sourceIndex = 0;
    for (ATMSourceRecord *source in sources) { if (self.backupCancellationRequested) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; if (error) *error = ATMBackupError(90, @"Backup cancelled. Temporary data was removed and no backup was created."); return nil; } NSMutableDictionary *entry = [[source manifestDictionary] mutableCopy]; NSString *extension = [source.relativePath.pathExtension.lowercaseString isEqualToString:@"sources"] ? @"sources" : @"list", *archivePath = [NSString stringWithFormat:@"sources/%03lu.%@", (unsigned long)sourceIndex++, extension]; NSData *data = [source.sanitizedContents dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]; if (![writer addData:data path:archivePath error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; } entry[@"backupPath"] = archivePath; entry[@"sha256"] = ATMSHA256ForData(data); entry[@"restorable"] = @(!source.credentialsRedacted); [sourceManifest addObject:entry]; }
    BOOL portable = embeddedCount == chosen.count; NSUInteger payloadCoverage = chosen.count ? (embeddedCount * 100 / chosen.count) : 0;
    NSMutableDictionary *manifest = [@{ @"format": @"com.aaz.tweakmanager.backup", @"formatVersion": @1, @"createdAt": ATMISODateString([NSDate date]), @"rootless": @YES, @"architecture": @"iphoneos-arm64", @"packages": packageManifest, @"sources": sourceManifest, @"portable": @(portable), @"payloadCoverage": @(payloadCoverage), @"missingPayloadCount": @(chosen.count - embeddedCount), @"captureFailureCounts": captureFailureCounts ?: @{}, @"credentialsIncluded": @NO, @"restoreExecutionIncluded": @NO, @"atomicWrite": @YES } mutableCopy]; NSString *trimmedProfile = [profileName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (trimmedProfile.length) manifest[@"profileName"] = trimmedProfile;
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!manifestData || ![writer addData:manifestData path:@"manifest.json" error:error] || ![writer close:error] || !ATMValidateStoredZipArchive(zipURL, error)) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; }
    NSDictionary *writeReport = [self backupReportForURL:zipURL password:nil error:error];
    if (!writeReport || [writeReport[@"badHashCount"] unsignedIntegerValue] > 0) { if (error && !*error) *error = ATMBackupError(65, @"Backup payload verification failed."); [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; }
    if (password.length) { NSData *plain = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:error], *encrypted = plain ? ATMEncryptArchive(plain, password, error) : nil; NSData *roundTrip = encrypted ? ATMDecryptArchive(encrypted, password, error) : nil; if (!encrypted || ![roundTrip isEqualToData:plain] || ![encrypted writeToURL:outputURL options:NSDataWritingAtomic error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; if (error && !*error) *error = ATMBackupError(46, @"Encrypted backup verification failed."); return nil; } [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; }
    if (![NSFileManager.defaultManager moveItemAtURL:outputURL toURL:finalURL error:error]) { [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; return nil; } [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:finalURL.path error:nil];
    self.lastBackupAttemptReport = [self backupReportForURL:finalURL password:password error:nil] ?: writeReport;
    if (progressHandler) progressHandler(@"Verifying final backup", 1, 1);
    NSUInteger cachedCount = [[packageManifest filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count]; NSUInteger repackedCount = [[packageManifest filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"payloadOrigin"] isEqualToString:@"verified-repack"]; }]] count]; [self.ledger recordEvent:@"backup-created" packageID:nil details:@{ @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"cachedDEBCount": @(cachedCount), @"repackedDEBCount": @(repackedCount), @"encrypted": @(password.length > 0) }]; return finalURL;
}
- (BOOL)isEncryptedBackup:(NSURL *)backupURL { NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:backupURL.path]; NSData *prefix = [handle readDataOfLength:8]; [handle closeFile]; return [prefix isEqualToData:[@"AAZTME01" dataUsingEncoding:NSASCIIStringEncoding]]; }
- (NSURL *)temporaryReadableArchiveForURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { if (![self isEncryptedBackup:backupURL]) return backupURL; NSData *container = [NSData dataWithContentsOfURL:backupURL options:NSDataReadingMappedIfSafe error:error], *plain = container ? ATMDecryptArchive(container, password, error) : nil; if (!plain) return nil; NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", NSUUID.UUID.UUIDString]]]; if (![plain writeToURL:temporary options:NSDataWritingAtomic error:error]) return nil; return temporary; }

- (NSDictionary *)prepareRestoreSessionForBackupURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error {
    [self clearRestoreSession];
    NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error];
    if (!readable) return nil;
    NSArray<NSDictionary *> *entries = ATMValidateStoredZipArchive(readable, error);
    NSData *manifestData = entries ? ATMReadStoredZipEntry(readable, @"manifest.json", error) : nil;
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error] : nil;
    BOOL manifestValid = [manifest isKindOfClass:NSDictionary.class] && [manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] &&
        [manifest[@"formatVersion"] integerValue] == 1 && [manifest[@"packages"] isKindOfClass:NSArray.class] && [manifest[@"sources"] isKindOfClass:NSArray.class];
    if (!entries || !manifestValid) {
        if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil];
        if (error && !*error) *error = ATMBackupError(31, @"Unsupported or invalid backup.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSNumber *> *entrySizes = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in entries) if ([entry[@"path"] isKindOfClass:NSString.class]) entrySizes[entry[@"path"]] = entry[@"size"] ?: @0;
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerRestore"] isDirectory:YES];
    NSURL *staging = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:error]) {
        if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil];
        return nil;
    }
    NSMutableDictionary *payloads = [NSMutableDictionary dictionary]; NSMutableArray *sourcePayloads = [NSMutableArray array]; unsigned long long totalBytes = 0; NSUInteger index = 0;
    for (NSDictionary *package in manifest[@"packages"] ?: @[]) {
        if (![package isKindOfClass:NSDictionary.class] || ![package[@"debStatus"] isEqualToString:@"exact-cache"]) continue;
        NSString *path = [package[@"debPath"] isKindOfClass:NSString.class] ? package[@"debPath"] : @"";
        NSString *sha = [package[@"sha256"] isKindOfClass:NSString.class] ? [package[@"sha256"] lowercaseString] : @"";
        NSString *packageID = [package[@"packageID"] isKindOfClass:NSString.class] ? package[@"packageID"] : @"";
        NSString *version = [package[@"version"] isKindOfClass:NSString.class] ? package[@"version"] : @"";
        unsigned long long size = entrySizes[path].unsignedLongLongValue;
        BOOL safePath = [path hasPrefix:@"packages/"] && ![path containsString:@".."] && ![path containsString:@"\\"] && path.length <= 512;
        BOOL safeHash = sha.length == 64 && [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
        if (!safePath || !safeHash || !packageID.length || !version.length || size == 0 || size > 256ULL * 1024ULL * 1024ULL) continue;
        if (totalBytes + size > 1024ULL * 1024ULL * 1024ULL) { if (error) *error = ATMBackupError(77, @"The embedded package payload limit was exceeded."); [self clearRestoreSession]; [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; return nil; }
        NSData *data = ATMReadStoredZipEntry(readable, path, nil);
        if (!data || data.length != size || ![ATMSHA256ForData(data).lowercaseString isEqualToString:sha]) continue;
        NSURL *destination = [staging URLByAppendingPathComponent:[NSString stringWithFormat:@"%03lu.deb", (unsigned long)index++]];
        if (![data writeToURL:destination options:NSDataWritingAtomic error:nil]) continue;
        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:destination.path error:nil];
        NSString *identity = [NSString stringWithFormat:@"%@\n%@", packageID, version];
        payloads[identity] = @{ @"url": destination, @"stagingRoot": staging, @"sha256": sha };
        totalBytes += size;
    }
    NSUInteger sourceIndex = 0, expectedRestorableSources = 0;
    for (NSDictionary *source in manifest[@"sources"] ?: @[]) {
        if (![source isKindOfClass:NSDictionary.class] || ![source[@"restorable"] boolValue]) continue;
        expectedRestorableSources++;
        NSString *path = [source[@"backupPath"] isKindOfClass:NSString.class] ? source[@"backupPath"] : @"";
        NSString *sha = [source[@"sha256"] isKindOfClass:NSString.class] ? [source[@"sha256"] lowercaseString] : @"";
        NSString *extension = path.pathExtension.lowercaseString; unsigned long long size = entrySizes[path].unsignedLongLongValue;
        BOOL safePath = [path hasPrefix:@"sources/"] && ![path containsString:@".."] && ![path containsString:@"\\"] && [@[@"list", @"sources"] containsObject:extension];
        BOOL safeHash = sha.length == 64 && [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
        if (!safePath || !safeHash || size == 0 || size > 128ULL * 1024ULL) continue;
        NSData *data = ATMReadStoredZipEntry(readable, path, nil);
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!text.length || data.length != size || ![ATMSHA256ForData(data).lowercaseString isEqualToString:sha] || [text containsString:@"\0"] || [text rangeOfString:@"://[^/\\s]+@" options:NSRegularExpressionSearch].location != NSNotFound) continue;
        NSURL *destination = [staging URLByAppendingPathComponent:[NSString stringWithFormat:@"source-%03lu.%@", (unsigned long)sourceIndex++, extension]];
        if (![data writeToURL:destination options:NSDataWritingAtomic error:nil]) continue;
        [sourcePayloads addObject:@{ @"url": destination, @"sha256": sha, @"extension": extension }];
    }
    if (sourcePayloads.count != expectedRestorableSources) {
        if (error) *error = ATMBackupError(84, @"A restorable source payload failed its integrity or privacy validation.");
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil]; if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; return nil;
    }
    if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil];
    self.restoreStagingDirectory = staging; self.restorePayloads = payloads; self.restoreSourcePayloads = sourcePayloads; self.restoreManifest = manifest; self.restoreSessionID = NSUUID.UUID.UUIDString;
    return manifest;
}
- (NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error { return [self manifestForBackup:backupURL password:nil error:error]; }
- (NSDictionary *)manifestForBackup:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error]; if (!readable) return nil; NSData *data = ATMReadStoredZipEntry(readable, @"manifest.json", error); if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil; if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1 || ![manifest[@"packages"] isKindOfClass:NSArray.class] || ![manifest[@"sources"] isKindOfClass:NSArray.class]) { if (error && !*error) *error = ATMBackupError(31, @"Unsupported or invalid backup."); return nil; } return manifest; }
- (NSDictionary *)backupReportForURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error {
    NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error]; if (!readable) return nil;
    NSArray *entries = ATMValidateStoredZipArchive(readable, error);
    if (!entries) { if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; if (error && !*error) *error = ATMBackupError(62, @"The backup archive could not be validated."); return nil; }
    NSMutableSet *paths = [NSMutableSet set]; NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in entries) { [paths addObject:entry[@"path"]]; sizes[entry[@"path"]] = entry[@"size"]; }
    NSData *manifestData = ATMReadStoredZipEntry(readable, @"manifest.json", error);
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1 || ![manifest[@"packages"] isKindOfClass:NSArray.class] || ![manifest[@"sources"] isKindOfClass:NSArray.class]) {
        if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil];
        if (error) *error = ATMBackupError(31, @"Unsupported or invalid backup."); return nil;
    }
    NSUInteger missingPayloads = 0, badHashes = 0, packageHashFailures = 0, sourceHashFailures = 0, unreadableEntries = 0, cached = 0, repacked = 0, restorableSources = 0;
    unsigned long long cachedBytes = 0; NSArray *manifestPackages = manifest[@"packages"] ?: @[];
    for (NSDictionary *package in manifestPackages) {
        if (![package[@"debStatus"] isEqualToString:@"exact-cache"]) { missingPayloads++; continue; }
        cached++; if ([package[@"payloadOrigin"] isEqualToString:@"verified-repack"]) repacked++;
        NSString *path = package[@"debPath"]; if (!path.length || ![paths containsObject:path]) { missingPayloads++; continue; }
        cachedBytes += [sizes[path] unsignedLongLongValue]; NSData *payload = ATMReadStoredZipEntry(readable, path, nil);
        if (!payload) { unreadableEntries++; badHashes++; packageHashFailures++; }
        else if (![ATMSHA256ForData(payload) isEqualToString:package[@"sha256"] ?: @""]) { badHashes++; packageHashFailures++; }
    }
    for (NSDictionary *source in manifest[@"sources"] ?: @[]) {
        NSString *path = source[@"backupPath"]; if (!path.length || ![paths containsObject:path]) { missingPayloads++; continue; }
        NSData *payload = ATMReadStoredZipEntry(readable, path, nil); NSString *sha = [source[@"sha256"] isKindOfClass:NSString.class] ? source[@"sha256"] : @"";
        if (!payload) { unreadableEntries++; if (sha.length) { badHashes++; sourceHashFailures++; } }
        else if (sha.length && ![ATMSHA256ForData(payload) isEqualToString:sha]) { badHashes++; sourceHashFailures++; }
        if ([source[@"restorable"] boolValue] && sha.length == 64) restorableSources++;
    }
    if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil];
    NSNumber *fileSize = nil, *availableBytes = nil; [backupURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil]; [self.backupDirectory getResourceValue:&availableBytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    BOOL portable = [manifest[@"portable"] boolValue] && [manifest[@"payloadCoverage"] integerValue] == 100 && cached == manifestPackages.count && missingPayloads == 0 && badHashes == 0;
    NSString *health = portable ? @"Healthy" : @"Incomplete"; NSDictionary *captureFailures = [manifest[@"captureFailureCounts"] isKindOfClass:NSDictionary.class] ? manifest[@"captureFailureCounts"] : @{};
    return @{ @"health": health, @"portable": @(portable), @"encrypted": @([self isEncryptedBackup:backupURL]), @"packageCount": @(manifestPackages.count), @"sourceCount": @([manifest[@"sources"] count]), @"restorableSourceCount": @(restorableSources), @"cachedDEBCount": @(cached), @"repackedDEBCount": @(repacked), @"cachedBytes": @(cachedBytes), @"fileSize": fileSize ?: @0, @"availableBytes": availableBytes ?: @0, @"missingPayloadCount": @(missingPayloads), @"badHashCount": @(badHashes), @"packageHashFailureCount": @(packageHashFailures), @"sourceHashFailureCount": @(sourceHashFailures), @"unreadableEntryCount": @(unreadableEntries), @"captureFailureCounts": captureFailures, @"manifest": manifest };
}
- (NSURL *)stageImportFromURL:(NSURL *)sourceURL error:(NSError **)error {
    ATMSetImportDiagnosticState(@"copying", 0);
    if (!sourceURL) { if (error) *error = ATMBackupError(51, @"No backup file was selected."); return nil; }
    NSNumber *isDirectory = nil;
    [sourceURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    if (isDirectory.boolValue) {
        if (error) *error = ATMBackupError(56, @"Select a backup file, not a folder.");
        ATMSetImportDiagnosticState(@"invalid-selection", 56);
        return nil;
    }
    NSError *directoryError = nil;
    NSURL *backupDirectory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/Backups" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:backupDirectory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:&directoryError]) {
        if (error) *error = ATMBackupError(57, @"The backup storage folder is unavailable.");
        ATMSetImportDiagnosticState(@"destination-unavailable", 57);
        return nil;
    }
    NSURL *staged = [backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.import.staged", NSUUID.UUID.UUIDString]];
    __block NSInteger copyFailureCode = 59;
    ATMSetImportDiagnosticState(@"copy-direct-started", 0);
    __block BOOL copied = ATMCopyFileContents(sourceURL, staged, &copyFailureCode);
    __block BOOL accessorCalled = NO;
    NSError *coordinationError = nil;
    if (!copied) {
        ATMRecordImportDiagnosticEvent(@"copy-direct-failed");
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        ATMSetImportDiagnosticState(@"coordination-fallback-started", 0);
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:sourceURL options:0 error:&coordinationError byAccessor:^(NSURL *coordinatedURL) {
            accessorCalled = YES;
            ATMSetImportDiagnosticState(@"coordination-accessor-called", 0);
            copied = ATMCopyFileContents(coordinatedURL, staged, &copyFailureCode);
        }];
    }
    if (!copied) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        NSInteger code = accessorCalled ? copyFailureCode : 61;
        NSString *stage = code == 60 ? @"destination-write-failed" : (code == 61 ? @"coordination-failed" : @"source-read-failed");
        NSString *message = code == 60 ? @"The selected backup could not be saved to local storage." : @"The selected backup could not be read from Files. Make sure it is fully downloaded, then try again.";
        if (error) *error = ATMBackupError(code, message);
        ATMSetImportDiagnosticState(stage, code);
        return nil;
    }
    NSNumber *size = nil;
    [staged getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue == 0) {
        [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        if (error) *error = ATMBackupError(53, @"The selected backup file is empty.");
        ATMSetImportDiagnosticState(@"empty-file", 53);
        return nil;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:staged.path error:nil];
    ATMSetImportDiagnosticState(@"staged", 0);
    return staged;
}
- (void)discardStagedImportAtURL:(NSURL *)stagedURL {
    if (!stagedURL || ![stagedURL.lastPathComponent hasSuffix:@".import.staged"] || ![[stagedURL.URLByDeletingLastPathComponent URLByStandardizingPath] isEqual:[self.backupDirectory URLByStandardizingPath]]) return;
    [NSFileManager.defaultManager removeItemAtURL:stagedURL error:nil];
}
- (NSURL *)importBackupFromURL:(NSURL *)sourceURL password:(NSString *)password error:(NSError **)error {
    BOOL alreadyStaged = [sourceURL.lastPathComponent hasSuffix:@".import.staged"] && [[sourceURL.URLByDeletingLastPathComponent URLByStandardizingPath] isEqual:[self.backupDirectory URLByStandardizingPath]];
    NSURL *staged = alreadyStaged ? sourceURL : [self stageImportFromURL:sourceURL error:error];
    if (!staged) return nil;
    ATMSetImportDiagnosticState(@"validating", 0);
    NSString *incomingHash = ATMSHA256ForFile(staged, nil);
    for (NSURL *existing in self.availableBackups) {
        if (incomingHash.length && [incomingHash isEqualToString:ATMSHA256ForFile(existing, nil)]) {
            [self discardStagedImportAtURL:staged];
            if (error) *error = ATMBackupError(54, @"This backup is already in your Backups list.");
            ATMSetImportDiagnosticState(@"duplicate", 54);
            return nil;
        }
    }
    NSDictionary *report = [self backupReportForURL:staged password:password error:error];
    if (!report) {
        [self discardStagedImportAtURL:staged];
        if (error && !*error) *error = ATMBackupError(62, @"The backup archive could not be validated and was not imported.");
        NSInteger code = error && *error ? (*error).code : 62;
        NSString *stage = code == ATMBackupErrorPasswordRequired || code == ATMBackupErrorWrongPassword ? @"archive-decryption-failed" :
            (code == 31 ? @"manifest-schema-failed" : (code == 11 ? @"archive-footer-failed" : (code == 12 ? @"archive-index-failed" : (code == 13 ? @"archive-crc-failed" : @"archive-layout-failed"))));
        ATMSetImportDiagnosticState(stage, code);
        return nil;
    }
    if ([report[@"badHashCount"] unsignedIntegerValue] > 0) {
        [self discardStagedImportAtURL:staged];
        NSUInteger packageFailures = [report[@"packageHashFailureCount"] unsignedIntegerValue], sourceFailures = [report[@"sourceHashFailureCount"] unsignedIntegerValue];
        NSInteger code = packageFailures ? 63 : (sourceFailures ? 64 : 65);
        NSString *stage = packageFailures ? @"package-hash-failed" : (sourceFailures ? @"source-hash-failed" : @"entry-integrity-failed");
        if (error) *error = ATMBackupError(code, @"The backup failed payload integrity validation and was not imported.");
        ATMSetImportDiagnosticState(stage, code);
        return nil;
    }
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSString *finalName = self.importSelfTestActive ? [NSString stringWithFormat:@".selftest-imported-%@.aaztmbackup", NSUUID.UUID.UUIDString] : [NSString stringWithFormat:@"AAZ-Imported-Backup-%@.aaztmbackup", stamp];
    NSURL *final = [self.backupDirectory URLByAppendingPathComponent:finalName];
    if (![NSFileManager.defaultManager moveItemAtURL:staged toURL:final error:error]) {
        [self discardStagedImportAtURL:staged];
        if (error) *error = ATMBackupError(55, @"The verified backup could not be added to local storage.");
        ATMSetImportDiagnosticState(@"finalize-failed", 55);
        return nil;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:final.path error:nil];
    if (!self.importSelfTestActive) [self.ledger recordEvent:@"backup-imported" packageID:nil details:@{ @"packageCount": report[@"packageCount"] ?: @0, @"sourceCount": report[@"sourceCount"] ?: @0, @"encrypted": report[@"encrypted"] ?: @NO }];
    ATMSetImportDiagnosticState(@"completed", 0);
    return final;
}
- (NSDictionary *)compareBackup:(NSURL *)olderURL withBackup:(NSURL *)newerURL error:(NSError **)error { NSDictionary *oldReport = [self backupReportForURL:olderURL password:nil error:error], *newReport = oldReport ? [self backupReportForURL:newerURL password:nil error:error] : nil; NSDictionary *older = oldReport[@"manifest"], *newer = newReport[@"manifest"]; if (!older || !newer) return nil; NSMutableDictionary *oldVersions = [NSMutableDictionary dictionary], *newVersions = [NSMutableDictionary dictionary]; for (NSDictionary *package in older[@"packages"]) if ([package[@"packageID"] isKindOfClass:NSString.class]) oldVersions[package[@"packageID"]] = package[@"version"] ?: @""; for (NSDictionary *package in newer[@"packages"]) if ([package[@"packageID"] isKindOfClass:NSString.class]) newVersions[package[@"packageID"]] = package[@"version"] ?: @""; NSUInteger added = 0, removed = 0, updated = 0, unchanged = 0; for (NSString *packageID in newVersions) { if (!oldVersions[packageID]) added++; else if (![oldVersions[packageID] isEqualToString:newVersions[packageID]]) updated++; else unchanged++; } for (NSString *packageID in oldVersions) if (!newVersions[packageID]) removed++; return @{ @"added": @(added), @"removed": @(removed), @"updated": @(updated), @"unchanged": @(unchanged) }; }
- (NSDictionary *)sourceRestoreReadiness {
    if (!self.restoreSourcePayloads.count) return @{ @"success": @YES, @"pending": @0, @"present": @0, @"snapshot": @{ @"rootPresent": @NO, @"items": @[] } };
    NSString *test = [self backupExecutableForPaths:@[@"/usr/bin/test", @"/bin/test"]];
    NSString *mkdir = [self backupExecutableForPaths:@[@"/bin/mkdir", @"/usr/bin/mkdir"]];
    NSString *install = [self backupExecutableForPaths:@[@"/usr/bin/install", @"/bin/install"]];
    NSString *move = [self backupExecutableForPaths:@[@"/bin/mv", @"/usr/bin/mv"]];
    NSString *remove = [self backupExecutableForPaths:@[@"/bin/rm", @"/usr/bin/rm"]];
    NSString *destinationRoot = [self.environment pathInsideRoot:@"/etc/apt/sources.list.d"];
    BOOL toolsReady = test.length && mkdir.length && install.length && move.length && remove.length;
    BOOL rootPresent = destinationRoot.length && [ATMRunBackupToolWithPrivilege(test, @[@"-d", destinationRoot], YES, nil)[@"exitCode"] integerValue] == 0;
    NSString *destinationParent = destinationRoot.stringByDeletingLastPathComponent;
    BOOL rootReady = rootPresent ? [ATMRunBackupToolWithPrivilege(test, @[@"-w", destinationRoot], YES, nil)[@"exitCode"] integerValue] == 0 :
        (destinationParent.length && [ATMRunBackupToolWithPrivilege(test, @[@"-d", destinationParent], YES, nil)[@"exitCode"] integerValue] == 0 && [ATMRunBackupToolWithPrivilege(test, @[@"-w", destinationParent], YES, nil)[@"exitCode"] integerValue] == 0);
    if (!toolsReady || !rootReady) return @{ @"success": @NO, @"pending": @0, @"present": @0, @"snapshot": @{} };
    NSMutableArray *snapshot = [NSMutableArray array]; NSUInteger pending = 0, present = 0;
    for (NSDictionary *descriptor in self.restoreSourcePayloads) {
        NSURL *url = descriptor[@"url"]; NSString *sha = [descriptor[@"sha256"] lowercaseString], *extension = descriptor[@"extension"];
        NSString *rootPath = self.restoreStagingDirectory.URLByStandardizingPath.path, *filePath = url.URLByStandardizingPath.path;
        BOOL insideStaging = rootPath.length && [filePath hasPrefix:[rootPath stringByAppendingString:@"/"]];
        if (!insideStaging || sha.length != 64 || ![@[@"list", @"sources"] containsObject:extension] || ![ATMSHA256ForFile(url, nil).lowercaseString isEqualToString:sha]) return @{ @"success": @NO, @"pending": @0, @"present": @0, @"snapshot": @{} };
        NSString *name = [NSString stringWithFormat:@"aaztm-%@.%@", [sha substringToIndex:16], extension];
        NSString *destination = [destinationRoot stringByAppendingPathComponent:name];
        struct stat status; BOOL exists = lstat(destination.fileSystemRepresentation, &status) == 0;
        NSString *state = @"pending";
        if (exists) {
            if (!S_ISREG(status.st_mode) || ![ATMSHA256ForFile([NSURL fileURLWithPath:destination], nil).lowercaseString isEqualToString:sha]) return @{ @"success": @NO, @"pending": @0, @"present": @0, @"snapshot": @{} };
            state = @"present"; present++;
        } else pending++;
        [snapshot addObject:@{ @"sha256": sha, @"extension": extension, @"state": state }];
    }
    return @{ @"success": @YES, @"pending": @(pending), @"present": @(present), @"snapshot": @{ @"rootPresent": @(rootPresent), @"items": snapshot } };
}
- (NSDictionary *)restoreReadinessForBackupURL:(NSURL *)backupURL password:(NSString *)password installedPackages:(NSArray<ATMPackageRecord *> *)installed error:(NSError **)error {
    ATMSetRestoreDiagnosticState(@"R40-READINESS", -1);
    NSDictionary *manifest = [self prepareRestoreSessionForBackupURL:backupURL password:password error:error];
    if (!manifest) { ATMSetRestoreDiagnosticState(@"R40-BLOCKED", error && *error ? (*error).code : -1); return nil; }
    NSDictionary *plan = [self.restorePlanner planForManifest:manifest installedPackages:installed exactPayloads:self.restorePayloads error:error];
    if (!plan) { ATMSetRestoreDiagnosticState(@"R40-BLOCKED", error && *error ? (*error).code : -1); [self clearRestoreSession]; return nil; }
    NSDictionary *sourcePlan = [self sourceRestoreReadiness];
    NSUInteger privateSourcesSkipped = [[manifest[@"sources"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id source, NSDictionary *bindings) { (void)bindings; return [source isKindOfClass:NSDictionary.class] && [source[@"credentialsRedacted"] boolValue]; }]] count];
    NSMutableDictionary *sessionPlan = [plan mutableCopy];
    BOOL sourceReady = [sourcePlan[@"success"] boolValue]; NSUInteger sourcesPending = [sourcePlan[@"pending"] unsignedIntegerValue];
    NSUInteger blocked = [plan[@"blocked"] unsignedIntegerValue] + (sourceReady ? 0 : 1);
    BOOL safe = [plan[@"simulationPassed"] boolValue] && blocked == 0 && ([plan[@"executionRequests"] count] > 0 || sourcesPending > 0);
    sessionPlan[@"restoreSessionID"] = self.restoreSessionID; sessionPlan[@"sourcesToRestore"] = @(sourcesPending); sessionPlan[@"sourcesAlreadyPresent"] = sourcePlan[@"present"] ?: @0; sessionPlan[@"privateSourcesSkipped"] = @(privateSourcesSkipped);
    sessionPlan[@"blocked"] = @(blocked); sessionPlan[@"prerequisiteFailures"] = @([plan[@"prerequisiteFailures"] unsignedIntegerValue] + (sourceReady ? 0 : 1)); sessionPlan[@"safeToExecute"] = @(safe);
    sessionPlan[@"packageExecutionSnapshot"] = plan[@"executionSnapshot"] ?: @{};
    sessionPlan[@"executionSnapshot"] = @{ @"packages": plan[@"executionSnapshot"] ?: @{}, @"sources": sourcePlan[@"snapshot"] ?: @[] };
    if (!sourceReady) sessionPlan[@"reason"] = @"The sanitized source destinations could not be verified safely.";
    else if (sourcesPending > 0 && ![plan[@"executionRequests"] count]) sessionPlan[@"reason"] = @"The package state is already satisfied and sanitized public sources are ready to restore.";
    else if (!safe && ![plan[@"executionRequests"] count] && sourcesPending == 0) sessionPlan[@"reason"] = @"All package and sanitized source state already matches this backup.";
    ATMSetRestoreDiagnosticState(safe ? @"R40-READY" : @"R40-BLOCKED", [plan[@"aptExitCode"] integerValue]);
    return sessionPlan;
}

- (NSDictionary *)restoreSanitizedSources {
    if (!self.restoreSourcePayloads.count) return @{ @"success": @YES, @"restored": @0 };
    NSString *mkdir = [self backupExecutableForPaths:@[@"/bin/mkdir", @"/usr/bin/mkdir"]];
    NSString *install = [self backupExecutableForPaths:@[@"/usr/bin/install", @"/bin/install"]];
    NSString *move = [self backupExecutableForPaths:@[@"/bin/mv", @"/usr/bin/mv"]];
    NSString *remove = [self backupExecutableForPaths:@[@"/bin/rm", @"/usr/bin/rm"]];
    NSString *destinationRoot = [self.environment pathInsideRoot:@"/etc/apt/sources.list.d"];
    if (!mkdir.length || !install.length || !move.length || !remove.length || !destinationRoot.length || [ATMRunBackupToolWithPrivilege(mkdir, @[@"-p", destinationRoot], YES, nil)[@"exitCode"] integerValue] != 0) return @{ @"success": @NO, @"restored": @0 };
    struct stat rootStatus; if (lstat(destinationRoot.fileSystemRepresentation, &rootStatus) != 0 || !S_ISDIR(rootStatus.st_mode)) return @{ @"success": @NO, @"restored": @0 };
    NSMutableArray<NSString *> *created = [NSMutableArray array]; NSUInteger restored = 0; BOOL failed = NO;
    for (NSDictionary *descriptor in self.restoreSourcePayloads) {
        NSURL *url = descriptor[@"url"]; NSString *sha = descriptor[@"sha256"], *extension = descriptor[@"extension"];
        NSString *rootPath = self.restoreStagingDirectory.URLByStandardizingPath.path, *filePath = url.URLByStandardizingPath.path;
        BOOL insideStaging = rootPath.length && [filePath hasPrefix:[rootPath stringByAppendingString:@"/"]];
        if (!insideStaging || ![@[@"list", @"sources"] containsObject:extension] || ![ATMSHA256ForFile(url, nil).lowercaseString isEqualToString:sha]) { failed = YES; break; }
        NSString *name = [NSString stringWithFormat:@"aaztm-%@.%@", [sha substringToIndex:16], extension];
        NSString *destination = [destinationRoot stringByAppendingPathComponent:name];
        struct stat destinationStatus; BOOL destinationExists = lstat(destination.fileSystemRepresentation, &destinationStatus) == 0;
        if (destinationExists) {
            if (!S_ISREG(destinationStatus.st_mode) || ![ATMSHA256ForFile([NSURL fileURLWithPath:destination], nil).lowercaseString isEqualToString:sha]) { failed = YES; break; }
            continue;
        }
        NSString *partial = [destination stringByAppendingFormat:@".%@.partial", NSUUID.UUID.UUIDString];
        NSDictionary *installed = ATMRunBackupToolWithPrivilege(install, @[@"-o", @"0", @"-g", @"0", @"-m", @"0644", filePath, partial], YES, nil);
        NSDictionary *moved = [installed[@"exitCode"] integerValue] == 0 && [ATMSHA256ForFile([NSURL fileURLWithPath:partial], nil).lowercaseString isEqualToString:sha] ? ATMRunBackupToolWithPrivilege(move, @[@"-n", @"--", partial, destination], YES, nil) : nil;
        BOOL moveVerified = [moved[@"exitCode"] integerValue] == 0 && ![NSFileManager.defaultManager fileExistsAtPath:partial] && [ATMSHA256ForFile([NSURL fileURLWithPath:destination], nil).lowercaseString isEqualToString:sha];
        if (!moveVerified) { ATMRunBackupToolWithPrivilege(remove, @[@"-f", @"--", partial], YES, nil); failed = YES; break; }
        [created addObject:destination]; restored++;
    }
    if (!failed) return @{ @"success": @YES, @"restored": @(restored) };
    for (NSString *path in created) ATMRunBackupToolWithPrivilege(remove, @[@"-f", @"--", path], YES, nil);
    return @{ @"success": @NO, @"restored": @0 };
}

- (NSDictionary *)executeRestoreForManifest:(NSDictionary *)manifest expectedPlan:(NSDictionary *)expectedPlan error:(NSError **)error {
    ATMSetRestoreDiagnosticState(@"R40-STARTED", -1);
    BOOL sessionValid = self.restoreSessionID.length && [expectedPlan[@"restoreSessionID"] isEqualToString:self.restoreSessionID] && [manifest isEqual:self.restoreManifest];
    if (!sessionValid) { if (error) *error = ATMBackupError(78, @"The verified Restore session expired. Run the readiness check again."); ATMSetRestoreDiagnosticState(@"R40-PRECHECK", 78); [self clearRestoreSession]; return nil; }
    NSDictionary *sourcePlan = [self sourceRestoreReadiness];
    BOOL sourcesStable = [sourcePlan[@"success"] boolValue] && [sourcePlan[@"pending"] isEqual:expectedPlan[@"sourcesToRestore"]] && [sourcePlan[@"snapshot"] isEqual:expectedPlan[@"executionSnapshot"][@"sources"]];
    if (!sourcesStable) { if (error) *error = ATMBackupError(85, @"The sanitized source state changed after confirmation. Run the readiness check again."); ATMSetRestoreDiagnosticState(@"R40-SOURCE-PREFLIGHT", 85); [self clearRestoreSession]; return nil; }
    NSDictionary *result = [self.restorePlanner executeManifest:manifest expectedPlan:expectedPlan exactPayloads:self.restorePayloads error:error];
    if ([result[@"success"] boolValue]) {
        NSDictionary *sourceResult = [self restoreSanitizedSources]; NSMutableDictionary *combined = [result mutableCopy];
        combined[@"sourcesRestored"] = sourceResult[@"restored"] ?: @0; combined[@"sourcesChanged"] = @([sourceResult[@"restored"] unsignedIntegerValue] > 0); combined[@"privateSourcesSkipped"] = expectedPlan[@"privateSourcesSkipped"] ?: @0;
        if (![sourceResult[@"success"] boolValue]) { combined[@"success"] = @NO; combined[@"restoreCode"] = @"R40-SOURCE-RESTORE"; combined[@"reason"] = @"Packages were restored, but the sanitized repository sources could not be written safely."; }
        else if (![expectedPlan[@"executionRequests"] count] && [sourceResult[@"restored"] unsignedIntegerValue] > 0) { combined[@"restoreCode"] = @"R40-SOURCE-OK"; combined[@"reason"] = @"Sanitized public sources were restored and verified; no package change was required."; }
        result = combined;
    }
    [self clearRestoreSession];
    if (!result) { ATMSetRestoreDiagnosticState(@"R40-PRECHECK", error && *error ? (*error).code : -1); return nil; }
    NSString *restoreCode = result[@"restoreCode"] ?: @"R40-UNKNOWN"; NSNumber *exitCode = result[@"aptExitCode"] ?: @(-1); ATMSetRestoreDiagnosticState(restoreCode, exitCode.integerValue); [self.ledger recordEvent:[result[@"success"] boolValue] ? @"restore-completed" : @"restore-stopped" packageID:nil details:@{ @"requested": result[@"requested"] ?: @0, @"completed": result[@"completed"] ?: @0, @"remaining": result[@"remaining"] ?: @0, @"postCheckPassed": result[@"postCheckPassed"] ?: @NO, @"restoreCode": restoreCode, @"aptExitCode": exitCode }]; return result;
}
- (NSArray<NSDictionary *> *)savedProfiles { NSArray *profiles = [NSUserDefaults.standardUserDefaults arrayForKey:ATMProfilesKey]; return [profiles isKindOfClass:NSArray.class] ? profiles : @[]; }
- (BOOL)saveProfileNamed:(NSString *)name packageIDs:(NSSet<NSString *> *)packageIDs error:(NSError **)error { NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!trimmed.length || trimmed.length > 40 || !packageIDs.count) { if (error) *error = ATMBackupError(60, @"Enter a profile name and select at least one package."); return NO; } NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] caseInsensitiveCompare:trimmed] == NSOrderedSame; }]; if (matches.count) [profiles removeObjectsAtIndexes:matches]; [profiles addObject:@{ @"name": trimmed, @"packageIDs": [[packageIDs allObjects] sortedArrayUsingSelector:@selector(compare:)], @"updatedAt": ATMISODateString([NSDate date]) }]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (BOOL)deleteProfileNamed:(NSString *)name error:(NSError **)error { (void)error; NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] isEqualToString:name]; }]; [profiles removeObjectsAtIndexes:matches]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (NSSet<NSString *> *)packageIDsForProfileNamed:(NSString *)name { for (NSDictionary *profile in self.savedProfiles) if ([profile[@"name"] isEqualToString:name]) return [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; return [NSSet set]; }
- (BOOL)isBackupPinned:(NSURL *)backupURL { return [[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]] containsObject:backupURL.lastPathComponent]; }
- (void)setBackup:(NSURL *)backupURL pinned:(BOOL)pinned { NSMutableSet *values = [NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]]; if (pinned) [values addObject:backupURL.lastPathComponent]; else [values removeObject:backupURL.lastPathComponent]; [NSUserDefaults.standardUserDefaults setObject:values.allObjects forKey:ATMPinnedBackupsKey]; }
@end
