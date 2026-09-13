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
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);
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

static NSString *ATMRunDPKGDebField(ATMEnvironment *environment, NSURL *debURL) {
    NSArray *candidates = @[[environment pathInsideRoot:@"/usr/bin/dpkg-deb"], [environment pathInsideRoot:@"/bin/dpkg-deb"]]; NSString *tool = nil;
    for (NSString *candidate in candidates) if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { tool = candidate; break; }
    if (!tool) return @"";
    int outputPipe[2]; if (pipe(outputPipe) != 0) return @"";
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions); posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO); posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO); posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    char *const arguments[] = {(char *)tool.fileSystemRepresentation, "--field", (char *)debURL.path.fileSystemRepresentation, NULL};
    pid_t pid = 0; int spawnResult = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, arguments, environ); posix_spawn_file_actions_destroy(&actions); close(outputPipe[1]);
    if (spawnResult != 0) { close(outputPipe[0]); return @""; }
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[8192]; ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) { if (data.length + (NSUInteger)count > 1024 * 1024) { kill(pid, SIGKILL); break; } [data appendBytes:buffer length:(NSUInteger)count]; }
    close(outputPipe[0]); int status = 0; waitpid(pid, &status, 0); if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
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
    int chdirResult = workingDirectory.length ? posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.fileSystemRepresentation) : 0;
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
    int spawnResult = chdirResult != 0 ? chdirResult : (personaResult != 0 ? personaResult : posix_spawn(&pid, tool.fileSystemRepresentation, &actions, attributesPointer, argv, fixedEnvironment));
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

static BOOL ATMBackupPackageIDIsValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length < 1 || value.length > 128) return NO;
    static NSRegularExpression *expression; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9][a-z0-9+.-]*$" options:0 error:nil]; });
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

static NSDictionary *ATMValidatedBackupPayload(ATMEnvironment *environment, NSURL *url) {
    NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!url.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:url.path] || size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > 256ULL * 1024ULL * 1024ULL) return nil;
    NSDictionary *fields = ATMParseDebianParagraph(ATMRunDPKGDebField(environment, url));
    NSString *packageID = [fields[@"Package"] isKindOfClass:NSString.class] ? fields[@"Package"] : @"";
    NSString *version = [fields[@"Version"] isKindOfClass:NSString.class] ? fields[@"Version"] : @"";
    NSString *architecture = [fields[@"Architecture"] isKindOfClass:NSString.class] ? fields[@"Architecture"] : @"";
    NSString *priority = [fields[@"Priority"] isKindOfClass:NSString.class] ? [fields[@"Priority"] lowercaseString] : @"";
    NSString *essential = [fields[@"Essential"] isKindOfClass:NSString.class] ? [fields[@"Essential"] lowercaseString] : @"no";
    if (!ATMBackupPackageIDIsValid(packageID) || !version.length || ![@[@"iphoneos-arm64", @"all"] containsObject:architecture] || [essential isEqualToString:@"yes"] || [@[@"required", @"important"] containsObject:priority] || [ATMProtectedPackageIDs() containsObject:packageID.lowercaseString]) return nil;
    NSString *sha = ATMSHA256ForFile(url, nil).lowercaseString; if (sha.length != 64) return nil;
    return @{ @"url": url, @"packageID": packageID, @"version": version, @"architecture": architecture, @"sha256": sha, @"size": size ?: @0 };
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
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger { if ((self = [super init])) { _environment = environment; _ledger = ledger; _restorePlanner = [[ATMRestorePlanner alloc] initWithEnvironment:environment]; NSURL *restoreRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerRestore"] isDirectory:YES], *acquireRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"AAZTweakManagerAcquire"] isDirectory:YES]; [NSFileManager.defaultManager removeItemAtURL:restoreRoot error:nil]; [NSFileManager.defaultManager removeItemAtURL:acquireRoot error:nil]; _restorePayloads = @{}; _restoreSourcePayloads = @[]; } return self; }
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

- (BOOL)installedPackageCanBeRepackedWithoutPrivateData:(ATMPackageRecord *)record {
    NSString *dpkgQuery = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-query", @"/bin/dpkg-query"]];
    NSString *dpkg = [self backupExecutableForPaths:@[@"/usr/bin/dpkg", @"/bin/dpkg"]];
    if (!dpkgQuery.length || !dpkg.length) return NO;
    NSDictionary *md5sums = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-show", record.packageID, @"md5sums"], YES, nil);
    NSString *verifiedFileInventory = [md5sums[@"output"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *listing = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--listfiles", record.packageID], YES, nil);
    if ([listing[@"exitCode"] integerValue] != 0) return NO;
    __block BOOL safe = YES; __block NSUInteger ownedPaths = 0;
    NSArray<NSString *> *privateRoots = @[@"/var/mobile", @"/private/var/mobile", @"/User", @"/home", @"/root", @"/tmp", @"/var/tmp", @"/var/log", @"/var/lib/apt", @"/var/lib/dpkg", @"/etc", @"/Library/Preferences", @"/var/jb/Library/Preferences", @"/var/jb/etc"];
    [listing[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *path = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!path.length) return; ownedPaths++;
        if (![path hasPrefix:@"/"] || [path containsString:@".."] || [path containsString:@"\0"] || [path containsString:@"\r"] || [path containsString:@"\n"]) { safe = NO; *stop = YES; return; }
        for (NSString *root in privateRoots) if ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]) { safe = NO; *stop = YES; break; }
    }];
    if (!safe || ownedPaths == 0 || ownedPaths > 20000) return NO;
    if (verifiedFileInventory.length) {
        NSDictionary *verification = ATMRunBackupToolWithPrivilege(dpkg, @[@"--verify", record.packageID], YES, nil);
        NSString *changes = [verification[@"output"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([verification[@"exitCode"] integerValue] != 0 || changes.length) return NO;
    }
    return YES;
}

- (NSURL *)repackInstalledPackageForRecord:(ATMPackageRecord *)record root:(NSURL *)root {
    if (![self installedPackageCanBeRepackedWithoutPrivateData:record]) return nil;
    NSString *dpkgQuery = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-query", @"/bin/dpkg-query"]];
    NSString *dpkgDeb = [self backupExecutableForPaths:@[@"/usr/bin/dpkg-deb", @"/bin/dpkg-deb"]];
    NSString *tar = [self backupExecutableForPaths:@[@"/usr/bin/tar", @"/bin/tar"]];
    if (!dpkgQuery.length || !dpkgDeb.length || !tar.length || ![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) return nil;
    NSDictionary *listing = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--listfiles", record.packageID], YES, nil);
    NSDictionary *status = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--status", record.packageID], YES, nil);
    NSDictionary *fields = [status[@"exitCode"] integerValue] == 0 ? ATMParseDebianParagraph(status[@"output"] ?: @"") : nil;
    NSData *controlData = fields ? ATMRepackedControlData(fields) : nil;
    if ([listing[@"exitCode"] integerValue] != 0 || !controlData.length) return nil;
    NSMutableArray<NSString *> *safePaths = [NSMutableArray array];
    [listing[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop; NSString *path = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([path hasPrefix:@"/"] && ![path isEqualToString:@"/"] && ![path isEqualToString:@"/."]) [safePaths addObject:path];
    }];
    if (!safePaths.count) return nil;
    NSURL *fileListURL = [root URLByAppendingPathComponent:@"payload-files"], *tarURL = [root URLByAppendingPathComponent:@"payload.tar"], *stage = [root URLByAppendingPathComponent:@"stage" isDirectory:YES];
    NSData *fileListData = [[[safePaths componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (![fileListData writeToURL:fileListURL options:NSDataWritingAtomic error:nil] || ![NSFileManager.defaultManager createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSDictionary *archive = ATMRunBackupToolWithPrivilege(tar, @[@"--create", @"--file", tarURL.path, @"--no-recursion", @"--files-from", fileListURL.path], YES, @"/");
    if ([archive[@"exitCode"] integerValue] != 0) return nil;
    NSDictionary *extract = ATMRunBackupToolWithPrivilege(tar, @[@"--extract", @"--file", tarURL.path, @"--directory", stage.path, @"--same-owner", @"--preserve-permissions"], YES, nil);
    if ([extract[@"exitCode"] integerValue] != 0) return nil;
    NSURL *debian = [stage URLByAppendingPathComponent:@"DEBIAN" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:debian withIntermediateDirectories:YES attributes:nil error:nil] || ![controlData writeToURL:[debian URLByAppendingPathComponent:@"control"] options:NSDataWritingAtomic error:nil]) return nil;
    NSDictionary *controlList = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-list", record.packageID], YES, nil);
    if ([controlList[@"exitCode"] integerValue] != 0) return nil;
    __block BOOL controlsValid = YES;
    [controlList[@"output"] enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *normalizedName = [[[[name stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@"_" withString:@""] stringByReplacingOccurrencesOfString:@"." withString:@""] stringByReplacingOccurrencesOfString:@"+" withString:@""];
        BOOL safeName = name.length && name.length <= 64 && normalizedName.length && [normalizedName rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location == NSNotFound;
        if (!safeName || [name isEqualToString:@"control"] || [name containsString:@".."]) return;
        NSDictionary *item = ATMRunBackupToolWithPrivilege(dpkgQuery, @[@"--control-show", record.packageID, name], YES, nil);
        NSData *data = [item[@"output"] dataUsingEncoding:NSUTF8StringEncoding];
        if ([item[@"exitCode"] integerValue] != 0 || !data.length || data.length > 2ULL * 1024ULL * 1024ULL || ![data writeToURL:[debian URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil]) { controlsValid = NO; *stop = YES; return; }
        BOOL executable = [@[@"preinst", @"postinst", @"prerm", @"postrm", @"config"] containsObject:name];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @(executable ? 0755 : 0644)} ofItemAtPath:[debian URLByAppendingPathComponent:name].path error:nil];
    }];
    if (!controlsValid) return nil;
    NSURL *output = [root URLByAppendingPathComponent:@"repacked.deb"];
    NSDictionary *build = ATMRunBackupToolWithPrivilege(dpkgDeb, @[@"--build", stage.path, output.path], YES, nil);
    NSDictionary *payload = [build[@"exitCode"] integerValue] == 0 ? ATMValidatedBackupPayload(self.environment, output) : nil;
    return [payload[@"packageID"] isEqualToString:record.packageID] && [payload[@"version"] isEqualToString:record.version] && [payload[@"architecture"] isEqualToString:record.architecture] ? output : nil;
}

- (NSDictionary<NSString *, NSURL *> *)portablePackagesForRecords:(NSArray<ATMPackageRecord *> *)records acquisitionRoot:(NSURL **)acquisitionRoot origins:(NSDictionary<NSString *, NSString *> **)origins {
    NSMutableDictionary *packages = [[self cachedPackagesByIdentity] mutableCopy]; NSMutableDictionary *payloadOrigins = [NSMutableDictionary dictionary];
    for (NSString *identity in packages) payloadOrigins[identity] = @"original";
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"AAZTweakManagerAcquire/%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
    for (ATMPackageRecord *record in records) {
        NSString *identity = [NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]; if (packages[identity]) continue;
        NSURL *downloaded = [self acquireAuthenticatedRepositoryPackageForRecord:record root:root];
        if (downloaded) { packages[identity] = downloaded; payloadOrigins[identity] = @"original"; continue; }
        NSURL *repackRoot = [root URLByAppendingPathComponent:[NSString stringWithFormat:@"repack-%lu", (unsigned long)payloadOrigins.count] isDirectory:YES];
        NSURL *repacked = [self repackInstalledPackageForRecord:record root:repackRoot];
        if (repacked) { packages[identity] = repacked; payloadOrigins[identity] = @"verified-repack"; }
    }
    if (acquisitionRoot) *acquisitionRoot = root; if (origins) *origins = payloadOrigins; return packages;
}
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources error:(NSError **)error { return [self createBackupWithPackages:packages sources:sources profileName:nil password:nil error:error]; }
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources profileName:(NSString *)profileName password:(NSString *)password error:(NSError **)error {
    NSSet *selected = self.ledger.selectedPackageIDs; NSArray *primary = [packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return record.personalCandidate && [selected containsObject:record.packageID]; }]];
    if (!primary.count) { if (error) *error = ATMBackupError(30, @"No personal packages are selected."); return nil; }
    NSArray *chosen = [self packagesIncludingDependenciesForSelected:primary allPackages:packages];
    if (!chosen.count) { if (error) *error = ATMBackupError(83, @"The installed dependency closure is too large or could not be verified."); return nil; }
    NSURL *acquisitionRoot = nil; NSDictionary *origins = nil; NSDictionary *cache = [self portablePackagesForRecords:chosen acquisitionRoot:&acquisitionRoot origins:&origins]; NSUInteger unresolved = 0;
    for (ATMPackageRecord *record in chosen) if (!cache[[NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]]) unresolved++;
    if (unresolved) { [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; if (error) *error = ATMBackupError(81, [NSString stringWithFormat:@"Automatic package capture could not safely reproduce %lu installed package%@. No backup was created and no manual file sharing is required.", (unsigned long)unresolved, unresolved == 1 ? @"" : @"s"]); return nil; }
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSURL *finalURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"AAZ-Tweak-Backup-%@.aaztmbackup", stamp]], *zipURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", NSUUID.UUID.UUIDString]], *outputURL = password.length ? [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.encrypted.partial", NSUUID.UUID.UUIDString]] : zipURL;
    ATMZipWriter *writer = [[ATMZipWriter alloc] initWithDestinationURL:zipURL error:error]; if (!writer) { [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; return nil; } NSMutableArray *packageManifest = [NSMutableArray array];
    for (ATMPackageRecord *record in chosen) { NSMutableDictionary *entry = [[record manifestDictionary] mutableCopy]; NSString *identity = [NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]; entry[@"supportingDependency"] = @(![selected containsObject:record.packageID]); NSDate *firstSeen = [self.ledger firstSeenDateForPackageID:record.packageID]; if (firstSeen) entry[@"firstSeen"] = ATMISODateString(firstSeen); NSURL *debURL = cache[identity]; if (debURL) { NSString *safeName = [record.packageID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]; NSString *archivePath = [NSString stringWithFormat:@"packages/%@_%@.deb", safeName, record.version]; NSError *hashError = nil; NSString *sha = ATMSHA256ForFile(debURL, &hashError); if (!hashError && sha.length && [writer addFileURL:debURL path:archivePath error:error]) { entry[@"debPath"] = archivePath; entry[@"sha256"] = sha; entry[@"debStatus"] = @"exact-cache"; entry[@"payloadOrigin"] = origins[identity] ?: @"original"; } else entry[@"debStatus"] = @"unavailable"; } else entry[@"debStatus"] = @"unavailable"; [packageManifest addObject:entry]; }
    [NSFileManager.defaultManager removeItemAtURL:acquisitionRoot error:nil]; NSUInteger embeddedCount = [[packageManifest filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count];
    if (embeddedCount != chosen.count) { [writer close:nil]; [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; if (error && !*error) *error = ATMBackupError(82, @"Portable Backup could not embed every verified package DEB."); return nil; }
    NSMutableArray *sourceManifest = [NSMutableArray array]; NSUInteger sourceIndex = 0;
    for (ATMSourceRecord *source in sources) { NSMutableDictionary *entry = [[source manifestDictionary] mutableCopy]; NSString *extension = [source.relativePath.pathExtension.lowercaseString isEqualToString:@"sources"] ? @"sources" : @"list", *archivePath = [NSString stringWithFormat:@"sources/%03lu.%@", (unsigned long)sourceIndex++, extension]; NSData *data = [source.sanitizedContents dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]; if (![writer addData:data path:archivePath error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; } entry[@"backupPath"] = archivePath; entry[@"sha256"] = ATMSHA256ForData(data); entry[@"restorable"] = @(!source.credentialsRedacted); [sourceManifest addObject:entry]; }
    NSMutableDictionary *manifest = [@{ @"format": @"com.aaz.tweakmanager.backup", @"formatVersion": @1, @"createdAt": ATMISODateString([NSDate date]), @"rootless": @YES, @"architecture": @"iphoneos-arm64", @"packages": packageManifest, @"sources": sourceManifest, @"portable": @YES, @"payloadCoverage": @100, @"credentialsIncluded": @NO, @"restoreExecutionIncluded": @NO, @"atomicWrite": @YES } mutableCopy]; NSString *trimmedProfile = [profileName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (trimmedProfile.length) manifest[@"profileName"] = trimmedProfile;
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error]; if (!manifestData || ![writer addData:manifestData path:@"manifest.json" error:error] || ![writer close:error] || !ATMValidateStoredZipArchive(zipURL, error)) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; }
    if (password.length) { NSData *plain = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:error], *encrypted = plain ? ATMEncryptArchive(plain, password, error) : nil; NSData *roundTrip = encrypted ? ATMDecryptArchive(encrypted, password, error) : nil; if (!encrypted || ![roundTrip isEqualToData:plain] || ![encrypted writeToURL:outputURL options:NSDataWritingAtomic error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; if (error && !*error) *error = ATMBackupError(46, @"Encrypted backup verification failed."); return nil; } [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; }
    if (![NSFileManager.defaultManager moveItemAtURL:outputURL toURL:finalURL error:error]) { [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; return nil; } [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:finalURL.path error:nil];
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
- (NSDictionary *)backupReportForURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error]; if (!readable) return nil; NSArray *entries = ATMValidateStoredZipArchive(readable, error); if (!entries) { if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; return nil; } NSMutableSet *paths = [NSMutableSet set]; NSMutableDictionary *sizes = [NSMutableDictionary dictionary]; for (NSDictionary *entry in entries) { [paths addObject:entry[@"path"]]; sizes[entry[@"path"]] = entry[@"size"]; } NSData *manifestData = ATMReadStoredZipEntry(readable, @"manifest.json", error); NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error] : nil; if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1 || ![manifest[@"packages"] isKindOfClass:NSArray.class] || ![manifest[@"sources"] isKindOfClass:NSArray.class]) { if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; if (error && !*error) *error = ATMBackupError(31, @"Unsupported or invalid backup."); return nil; } NSUInteger missingPayloads = 0, badHashes = 0, cached = 0, repacked = 0, restorableSources = 0; unsigned long long cachedBytes = 0; NSArray *manifestPackages = manifest[@"packages"] ?: @[]; for (NSDictionary *package in manifestPackages) if ([package[@"debStatus"] isEqualToString:@"exact-cache"]) { cached++; if ([package[@"payloadOrigin"] isEqualToString:@"verified-repack"]) repacked++; NSString *path = package[@"debPath"]; if (!path.length || ![paths containsObject:path]) { missingPayloads++; continue; } cachedBytes += [sizes[path] unsignedLongLongValue]; NSData *payload = ATMReadStoredZipEntry(readable, path, nil); if (!payload || ![ATMSHA256ForData(payload) isEqualToString:package[@"sha256"] ?: @""]) badHashes++; } for (NSDictionary *source in manifest[@"sources"] ?: @[]) { NSString *path = source[@"backupPath"]; if (!path.length || ![paths containsObject:path]) { missingPayloads++; continue; } NSData *payload = ATMReadStoredZipEntry(readable, path, nil); NSString *sha = [source[@"sha256"] isKindOfClass:NSString.class] ? source[@"sha256"] : @""; if (sha.length && ![ATMSHA256ForData(payload ?: NSData.data) isEqualToString:sha]) badHashes++; if ([source[@"restorable"] boolValue] && sha.length == 64) restorableSources++; } if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; NSNumber *fileSize = nil, *availableBytes = nil; [backupURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil]; [self.backupDirectory getResourceValue:&availableBytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]; BOOL portable = [manifest[@"portable"] boolValue] && [manifest[@"payloadCoverage"] integerValue] == 100 && cached == manifestPackages.count && missingPayloads == 0 && badHashes == 0; NSString *health = portable ? @"Healthy" : @"Incomplete"; return @{ @"health": health, @"portable": @(portable), @"encrypted": @([self isEncryptedBackup:backupURL]), @"packageCount": @(manifestPackages.count), @"sourceCount": @([manifest[@"sources"] count]), @"restorableSourceCount": @(restorableSources), @"cachedDEBCount": @(cached), @"repackedDEBCount": @(repacked), @"cachedBytes": @(cachedBytes), @"fileSize": fileSize ?: @0, @"availableBytes": availableBytes ?: @0, @"missingPayloadCount": @(missingPayloads), @"badHashCount": @(badHashes), @"manifest": manifest }; }
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
    if (!report || ![report[@"health"] isEqualToString:@"Healthy"]) {
        [self discardStagedImportAtURL:staged];
        if (report && error) *error = ATMBackupError(50, @"Only a verified Portable Backup with 100% DEB coverage can be imported.");
        NSInteger code = error && *error ? (*error).code : 50; ATMSetImportDiagnosticState(@"validation-failed", code);
        return nil;
    }
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSURL *final = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"AAZ-Imported-Backup-%@.aaztmbackup", stamp]];
    if (![NSFileManager.defaultManager moveItemAtURL:staged toURL:final error:error]) {
        [self discardStagedImportAtURL:staged];
        if (error) *error = ATMBackupError(55, @"The verified backup could not be added to local storage.");
        ATMSetImportDiagnosticState(@"finalize-failed", 55);
        return nil;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:final.path error:nil];
    [self.ledger recordEvent:@"backup-imported" packageID:nil details:@{ @"packageCount": report[@"packageCount"] ?: @0, @"sourceCount": report[@"sourceCount"] ?: @0, @"encrypted": report[@"encrypted"] ?: @NO }];
    ATMSetImportDiagnosticState(@"completed", 0);
    return final;
}
- (NSDictionary *)compareBackup:(NSURL *)olderURL withBackup:(NSURL *)newerURL error:(NSError **)error { NSDictionary *oldReport = [self backupReportForURL:olderURL password:nil error:error], *newReport = oldReport ? [self backupReportForURL:newerURL password:nil error:error] : nil; NSDictionary *older = oldReport[@"manifest"], *newer = newReport[@"manifest"]; if (!older || !newer) return nil; NSMutableDictionary *oldVersions = [NSMutableDictionary dictionary], *newVersions = [NSMutableDictionary dictionary]; for (NSDictionary *package in older[@"packages"]) if ([package[@"packageID"] isKindOfClass:NSString.class]) oldVersions[package[@"packageID"]] = package[@"version"] ?: @""; for (NSDictionary *package in newer[@"packages"]) if ([package[@"packageID"] isKindOfClass:NSString.class]) newVersions[package[@"packageID"]] = package[@"version"] ?: @""; NSUInteger added = 0, removed = 0, updated = 0, unchanged = 0; for (NSString *packageID in newVersions) { if (!oldVersions[packageID]) added++; else if (![oldVersions[packageID] isEqualToString:newVersions[packageID]]) updated++; else unchanged++; } for (NSString *packageID in oldVersions) if (!newVersions[packageID]) removed++; return @{ @"added": @(added), @"removed": @(removed), @"updated": @(updated), @"unchanged": @(unchanged) }; }
- (NSDictionary *)restoreReadinessForBackupURL:(NSURL *)backupURL password:(NSString *)password installedPackages:(NSArray<ATMPackageRecord *> *)installed error:(NSError **)error {
    ATMSetRestoreDiagnosticState(@"R39-READINESS", -1);
    NSDictionary *manifest = [self prepareRestoreSessionForBackupURL:backupURL password:password error:error];
    if (!manifest) { ATMSetRestoreDiagnosticState(@"R39-BLOCKED", error && *error ? (*error).code : -1); return nil; }
    NSDictionary *plan = [self.restorePlanner planForManifest:manifest installedPackages:installed exactPayloads:self.restorePayloads error:error];
    if (!plan) { ATMSetRestoreDiagnosticState(@"R39-BLOCKED", error && *error ? (*error).code : -1); [self clearRestoreSession]; return nil; }
    NSUInteger privateSourcesSkipped = [[manifest[@"sources"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id source, NSDictionary *bindings) { (void)bindings; return [source isKindOfClass:NSDictionary.class] && [source[@"credentialsRedacted"] boolValue]; }]] count];
    NSMutableDictionary *sessionPlan = [plan mutableCopy]; sessionPlan[@"restoreSessionID"] = self.restoreSessionID; sessionPlan[@"sourcesToRestore"] = @(self.restoreSourcePayloads.count); sessionPlan[@"privateSourcesSkipped"] = @(privateSourcesSkipped);
    ATMSetRestoreDiagnosticState([plan[@"safeToExecute"] boolValue] || ([plan[@"simulationPassed"] boolValue] && [plan[@"blocked"] unsignedIntegerValue] == 0) ? @"R39-READY" : @"R39-BLOCKED", [plan[@"aptExitCode"] integerValue]);
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
    NSMutableArray<NSString *> *created = [NSMutableArray array]; NSUInteger restored = 0;
    for (NSDictionary *descriptor in self.restoreSourcePayloads) {
        NSURL *url = descriptor[@"url"]; NSString *sha = descriptor[@"sha256"], *extension = descriptor[@"extension"];
        NSString *rootPath = self.restoreStagingDirectory.URLByStandardizingPath.path, *filePath = url.URLByStandardizingPath.path;
        BOOL insideStaging = rootPath.length && [filePath hasPrefix:[rootPath stringByAppendingString:@"/"]];
        if (!insideStaging || ![@[@"list", @"sources"] containsObject:extension] || ![ATMSHA256ForFile(url, nil).lowercaseString isEqualToString:sha]) goto rollback;
        NSString *name = [NSString stringWithFormat:@"aaztm-%@.%@", [sha substringToIndex:16], extension];
        NSString *destination = [destinationRoot stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:destination]) {
            if (![ATMSHA256ForFile([NSURL fileURLWithPath:destination], nil).lowercaseString isEqualToString:sha]) goto rollback;
            continue;
        }
        NSString *partial = [destination stringByAppendingFormat:@".%@.partial", NSUUID.UUID.UUIDString];
        NSDictionary *installed = ATMRunBackupToolWithPrivilege(install, @[@"-o", @"0", @"-g", @"0", @"-m", @"0644", filePath, partial], YES, nil);
        NSDictionary *moved = [installed[@"exitCode"] integerValue] == 0 && [ATMSHA256ForFile([NSURL fileURLWithPath:partial], nil).lowercaseString isEqualToString:sha] ? ATMRunBackupToolWithPrivilege(move, @[@"-n", @"--", partial, destination], YES, nil) : nil;
        BOOL moveVerified = [moved[@"exitCode"] integerValue] == 0 && ![NSFileManager.defaultManager fileExistsAtPath:partial] && [ATMSHA256ForFile([NSURL fileURLWithPath:destination], nil).lowercaseString isEqualToString:sha];
        if (!moveVerified) { ATMRunBackupToolWithPrivilege(remove, @[@"-f", @"--", partial], YES, nil); goto rollback; }
        [created addObject:destination]; restored++;
    }
    return @{ @"success": @YES, @"restored": @(restored) };
rollback:
    for (NSString *path in created) ATMRunBackupToolWithPrivilege(remove, @[@"-f", @"--", path], YES, nil);
    return @{ @"success": @NO, @"restored": @0 };
}

- (NSDictionary *)executeRestoreForManifest:(NSDictionary *)manifest expectedPlan:(NSDictionary *)expectedPlan error:(NSError **)error {
    ATMSetRestoreDiagnosticState(@"R39-STARTED", -1);
    BOOL sessionValid = self.restoreSessionID.length && [expectedPlan[@"restoreSessionID"] isEqualToString:self.restoreSessionID] && [manifest isEqual:self.restoreManifest];
    if (!sessionValid) { if (error) *error = ATMBackupError(78, @"The verified Restore session expired. Run the readiness check again."); ATMSetRestoreDiagnosticState(@"R39-PRECHECK", 78); [self clearRestoreSession]; return nil; }
    NSDictionary *result = [self.restorePlanner executeManifest:manifest expectedPlan:expectedPlan exactPayloads:self.restorePayloads error:error];
    if ([result[@"success"] boolValue]) {
        NSDictionary *sourceResult = [self restoreSanitizedSources]; NSMutableDictionary *combined = [result mutableCopy];
        combined[@"sourcesRestored"] = sourceResult[@"restored"] ?: @0; combined[@"sourcesChanged"] = @([sourceResult[@"restored"] unsignedIntegerValue] > 0); combined[@"privateSourcesSkipped"] = expectedPlan[@"privateSourcesSkipped"] ?: @0;
        if (![sourceResult[@"success"] boolValue]) { combined[@"success"] = @NO; combined[@"restoreCode"] = @"R39-SOURCE-RESTORE"; combined[@"reason"] = @"Packages were restored, but the sanitized repository sources could not be written safely."; }
        result = combined;
    }
    [self clearRestoreSession];
    if (!result) { ATMSetRestoreDiagnosticState(@"R39-PRECHECK", error && *error ? (*error).code : -1); return nil; }
    NSString *restoreCode = result[@"restoreCode"] ?: @"R39-UNKNOWN"; NSNumber *exitCode = result[@"aptExitCode"] ?: @(-1); ATMSetRestoreDiagnosticState(restoreCode, exitCode.integerValue); [self.ledger recordEvent:[result[@"success"] boolValue] ? @"restore-completed" : @"restore-stopped" packageID:nil details:@{ @"requested": result[@"requested"] ?: @0, @"completed": result[@"completed"] ?: @0, @"remaining": result[@"remaining"] ?: @0, @"postCheckPassed": result[@"postCheckPassed"] ?: @NO, @"restoreCode": restoreCode, @"aptExitCode": exitCode }]; return result;
}
- (NSArray<NSDictionary *> *)savedProfiles { NSArray *profiles = [NSUserDefaults.standardUserDefaults arrayForKey:ATMProfilesKey]; return [profiles isKindOfClass:NSArray.class] ? profiles : @[]; }
- (BOOL)saveProfileNamed:(NSString *)name packageIDs:(NSSet<NSString *> *)packageIDs error:(NSError **)error { NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!trimmed.length || trimmed.length > 40 || !packageIDs.count) { if (error) *error = ATMBackupError(60, @"Enter a profile name and select at least one package."); return NO; } NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] caseInsensitiveCompare:trimmed] == NSOrderedSame; }]; if (matches.count) [profiles removeObjectsAtIndexes:matches]; [profiles addObject:@{ @"name": trimmed, @"packageIDs": [[packageIDs allObjects] sortedArrayUsingSelector:@selector(compare:)], @"updatedAt": ATMISODateString([NSDate date]) }]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (BOOL)deleteProfileNamed:(NSString *)name error:(NSError **)error { (void)error; NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] isEqualToString:name]; }]; [profiles removeObjectsAtIndexes:matches]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (NSSet<NSString *> *)packageIDsForProfileNamed:(NSString *)name { for (NSDictionary *profile in self.savedProfiles) if ([profile[@"name"] isEqualToString:name]) return [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; return [NSSet set]; }
- (BOOL)isBackupPinned:(NSURL *)backupURL { return [[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]] containsObject:backupURL.lastPathComponent]; }
- (void)setBackup:(NSURL *)backupURL pinned:(BOOL)pinned { NSMutableSet *values = [NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]]; if (pinned) [values addObject:backupURL.lastPathComponent]; else [values removeObject:backupURL.lastPathComponent]; [NSUserDefaults.standardUserDefaults setObject:values.allObjects forKey:ATMPinnedBackupsKey]; }
@end
