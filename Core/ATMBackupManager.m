#import "ATMBackupManager.h"
#import "ATMZipWriter.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;
NSString *const ATMBackupErrorDomain = @"com.aaz.tweakmanager.backup";
static NSString *const ATMProfilesKey = @"ATMBackupProfilesV1";
static NSString *const ATMPinnedBackupsKey = @"ATMPinnedBackupsV1";
static const NSUInteger ATMEncryptedHeaderLength = 44;
static const NSUInteger ATMEncryptedTagLength = CC_SHA256_DIGEST_LENGTH;

@interface ATMBackupManager ()
@property(nonatomic, strong) ATMEnvironment *environment;
@property(nonatomic, strong) ATMPersonalLedger *ledger;
@end

static NSError *ATMBackupError(NSInteger code, NSString *message) { return [NSError errorWithDomain:ATMBackupErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}]; }

@interface ATMImportDocument : UIDocument
@property(nonatomic, strong) NSURL *stagedURL;
@property(nonatomic, assign) NSInteger loadFailureCode;
@end

@implementation ATMImportDocument
- (BOOL)loadFromContents:(id)contents ofType:(__unused NSString *)typeName error:(NSError **)outError {
    ATMSetImportDiagnosticState(@"document-content-received", 0);
    NSData *data = nil;
    if ([contents isKindOfClass:NSData.class]) {
        data = contents;
    } else if ([contents isKindOfClass:NSFileWrapper.class]) {
        NSFileWrapper *wrapper = contents;
        if (wrapper.isRegularFile) data = wrapper.regularFileContents;
        else {
            self.loadFailureCode = 56;
            ATMSetImportDiagnosticState(@"invalid-selection", 56);
            if (outError) *outError = ATMBackupError(56, @"Select a backup file, not a folder.");
            return NO;
        }
    }
    if (!data) {
        self.loadFailureCode = 58;
        ATMSetImportDiagnosticState(@"document-content-invalid", 58);
        if (outError) *outError = ATMBackupError(58, @"Files returned an unsupported document representation.");
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:self.stagedURL error:nil];
    NSError *writeError = nil;
    if ([data writeToURL:self.stagedURL options:NSDataWritingAtomic error:&writeError]) return YES;
    BOOL destinationUnavailable = ![NSFileManager.defaultManager isWritableFileAtPath:self.stagedURL.URLByDeletingLastPathComponent.path];
    self.loadFailureCode = destinationUnavailable ? 57 : 60;
    ATMSetImportDiagnosticState(@"document-write-failed", self.loadFailureCode);
    if (outError) *outError = ATMBackupError(self.loadFailureCode, @"The selected backup could not be saved to local storage.");
    return NO;
}
@end

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
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger { if ((self = [super init])) { _environment = environment; _ledger = ledger; } return self; }
- (NSURL *)backupDirectory { NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/Backups" isDirectory:YES]; [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]; return directory; }
- (NSArray<NSURL *> *)availableBackups { NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.backupDirectory includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]; NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) { (void)bindings; return [url.pathExtension.lowercaseString isEqualToString:@"aaztmbackup"]; }]; return [[files filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { BOOL ap = [self isBackupPinned:a], bp = [self isBackupPinned:b]; if (ap != bp) return ap ? NSOrderedAscending : NSOrderedDescending; NSDate *ad = nil, *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil]; return [bd ?: NSDate.distantPast compare:ad ?: NSDate.distantPast]; }]; }
- (NSDictionary<NSString *, NSURL *> *)cachedPackagesByIdentity { NSMutableDictionary *result = [NSMutableDictionary dictionary]; NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.environment.aptCachePath isDirectory:YES] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]; for (NSURL *url in files) { if (![url.pathExtension.lowercaseString isEqualToString:@"deb"]) continue; NSDictionary *fields = ATMParseDebianParagraph(ATMRunDPKGDebField(self.environment, url)); NSString *packageID = fields[@"Package"] ?: @"", *version = fields[@"Version"] ?: @""; if (packageID.length && version.length) result[[NSString stringWithFormat:@"%@\n%@", packageID, version]] = url; } return result; }
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources error:(NSError **)error { return [self createBackupWithPackages:packages sources:sources profileName:nil password:nil error:error]; }
- (NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources profileName:(NSString *)profileName password:(NSString *)password error:(NSError **)error {
    NSSet *selected = self.ledger.selectedPackageIDs; NSArray *chosen = [packages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ATMPackageRecord *record, NSDictionary *bindings) { (void)bindings; return [selected containsObject:record.packageID]; }]];
    if (!chosen.count) { if (error) *error = ATMBackupError(30, @"No personal packages are selected."); return nil; }
    NSString *stamp = [[ATMISODateString([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSURL *finalURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"AAZ-Tweak-Backup-%@.aaztmbackup", stamp]], *zipURL = [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.partial", NSUUID.UUID.UUIDString]], *outputURL = password.length ? [self.backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.encrypted.partial", NSUUID.UUID.UUIDString]] : zipURL;
    ATMZipWriter *writer = [[ATMZipWriter alloc] initWithDestinationURL:zipURL error:error]; if (!writer) return nil; NSDictionary *cache = [self cachedPackagesByIdentity]; NSMutableArray *packageManifest = [NSMutableArray array];
    for (ATMPackageRecord *record in chosen) { NSMutableDictionary *entry = [[record manifestDictionary] mutableCopy]; NSDate *firstSeen = [self.ledger firstSeenDateForPackageID:record.packageID]; if (firstSeen) entry[@"firstSeen"] = ATMISODateString(firstSeen); NSURL *debURL = cache[[NSString stringWithFormat:@"%@\n%@", record.packageID, record.version]]; if (debURL) { NSString *safeName = [record.packageID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]; NSString *archivePath = [NSString stringWithFormat:@"packages/%@_%@.deb", safeName, record.version]; NSError *hashError = nil; NSString *sha = ATMSHA256ForFile(debURL, &hashError); if (!hashError && sha.length && [writer addFileURL:debURL path:archivePath error:error]) { entry[@"debPath"] = archivePath; entry[@"sha256"] = sha; entry[@"debStatus"] = @"exact-cache"; } else entry[@"debStatus"] = @"unavailable"; } else entry[@"debStatus"] = @"unavailable"; [packageManifest addObject:entry]; }
    NSMutableArray *sourceManifest = [NSMutableArray array]; NSUInteger sourceIndex = 0;
    for (ATMSourceRecord *source in sources) { NSMutableDictionary *entry = [[source manifestDictionary] mutableCopy]; NSString *extension = source.relativePath.pathExtension.length ? source.relativePath.pathExtension : @"list", *archivePath = [NSString stringWithFormat:@"sources/%03lu.%@", (unsigned long)sourceIndex++, extension]; NSData *data = [source.sanitizedContents dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]; if (![writer addData:data path:archivePath error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; } entry[@"backupPath"] = archivePath; [sourceManifest addObject:entry]; }
    NSMutableDictionary *manifest = [@{ @"format": @"com.aaz.tweakmanager.backup", @"formatVersion": @1, @"createdAt": ATMISODateString([NSDate date]), @"rootless": @YES, @"architecture": @"iphoneos-arm64", @"packages": packageManifest, @"sources": sourceManifest, @"credentialsIncluded": @NO, @"restoreExecutionIncluded": @NO, @"atomicWrite": @YES } mutableCopy]; NSString *trimmedProfile = [profileName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (trimmedProfile.length) manifest[@"profileName"] = trimmedProfile;
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error]; if (!manifestData || ![writer addData:manifestData path:@"manifest.json" error:error] || ![writer close:error] || !ATMValidateStoredZipArchive(zipURL, error)) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; return nil; }
    if (password.length) { NSData *plain = [NSData dataWithContentsOfURL:zipURL options:NSDataReadingMappedIfSafe error:error], *encrypted = plain ? ATMEncryptArchive(plain, password, error) : nil; NSData *roundTrip = encrypted ? ATMDecryptArchive(encrypted, password, error) : nil; if (!encrypted || ![roundTrip isEqualToData:plain] || ![encrypted writeToURL:outputURL options:NSDataWritingAtomic error:error]) { [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; if (error && !*error) *error = ATMBackupError(46, @"Encrypted backup verification failed."); return nil; } [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil]; }
    if (![NSFileManager.defaultManager moveItemAtURL:outputURL toURL:finalURL error:error]) { [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil]; return nil; } [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:finalURL.path error:nil];
    NSUInteger cachedCount = [[packageManifest filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *package, NSDictionary *bindings) { (void)bindings; return [package[@"debStatus"] isEqualToString:@"exact-cache"]; }]] count]; [self.ledger recordEvent:@"backup-created" packageID:nil details:@{ @"packageCount": @(chosen.count), @"sourceCount": @(sources.count), @"cachedDEBCount": @(cachedCount), @"encrypted": @(password.length > 0) }]; return finalURL;
}
- (BOOL)isEncryptedBackup:(NSURL *)backupURL { NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:backupURL.path]; NSData *prefix = [handle readDataOfLength:8]; [handle closeFile]; return [prefix isEqualToData:[@"AAZTME01" dataUsingEncoding:NSASCIIStringEncoding]]; }
- (NSURL *)temporaryReadableArchiveForURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { if (![self isEncryptedBackup:backupURL]) return backupURL; NSData *container = [NSData dataWithContentsOfURL:backupURL options:NSDataReadingMappedIfSafe error:error], *plain = container ? ATMDecryptArchive(container, password, error) : nil; if (!plain) return nil; NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", NSUUID.UUID.UUIDString]]]; if (![plain writeToURL:temporary options:NSDataWritingAtomic error:error]) return nil; return temporary; }
- (NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error { return [self manifestForBackup:backupURL password:nil error:error]; }
- (NSDictionary *)manifestForBackup:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error]; if (!readable) return nil; NSData *data = ATMReadStoredZipEntry(readable, @"manifest.json", error); if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil; if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1 || ![manifest[@"packages"] isKindOfClass:NSArray.class] || ![manifest[@"sources"] isKindOfClass:NSArray.class]) { if (error && !*error) *error = ATMBackupError(31, @"Unsupported or invalid backup."); return nil; } return manifest; }
- (NSDictionary *)backupReportForURL:(NSURL *)backupURL password:(NSString *)password error:(NSError **)error { NSURL *readable = [self temporaryReadableArchiveForURL:backupURL password:password error:error]; if (!readable) return nil; NSArray *entries = ATMValidateStoredZipArchive(readable, error); if (!entries) { if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; return nil; } NSMutableSet *paths = [NSMutableSet set]; NSMutableDictionary *sizes = [NSMutableDictionary dictionary]; for (NSDictionary *entry in entries) { [paths addObject:entry[@"path"]]; sizes[entry[@"path"]] = entry[@"size"]; } NSData *manifestData = ATMReadStoredZipEntry(readable, @"manifest.json", error); NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error] : nil; if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"format"] isEqualToString:@"com.aaz.tweakmanager.backup"] || [manifest[@"formatVersion"] integerValue] != 1 || ![manifest[@"packages"] isKindOfClass:NSArray.class] || ![manifest[@"sources"] isKindOfClass:NSArray.class]) { if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; if (error && !*error) *error = ATMBackupError(31, @"Unsupported or invalid backup."); return nil; } NSUInteger missingPayloads = 0, badHashes = 0, cached = 0; unsigned long long cachedBytes = 0; for (NSDictionary *package in manifest[@"packages"] ?: @[]) if ([package[@"debStatus"] isEqualToString:@"exact-cache"]) { cached++; NSString *path = package[@"debPath"]; if (!path.length || ![paths containsObject:path]) { missingPayloads++; continue; } cachedBytes += [sizes[path] unsignedLongLongValue]; NSData *payload = ATMReadStoredZipEntry(readable, path, nil); if (!payload || ![ATMSHA256ForData(payload) isEqualToString:package[@"sha256"] ?: @""]) badHashes++; } for (NSDictionary *source in manifest[@"sources"] ?: @[]) { NSString *path = source[@"backupPath"]; if (!path.length || ![paths containsObject:path]) missingPayloads++; } if (![readable isEqual:backupURL]) [NSFileManager.defaultManager removeItemAtURL:readable error:nil]; NSNumber *fileSize = nil, *availableBytes = nil; [backupURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil]; [self.backupDirectory getResourceValue:&availableBytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]; NSString *health = (missingPayloads || badHashes) ? @"Incomplete" : @"Healthy"; return @{ @"health": health, @"encrypted": @([self isEncryptedBackup:backupURL]), @"packageCount": @([manifest[@"packages"] count]), @"sourceCount": @([manifest[@"sources"] count]), @"cachedDEBCount": @(cached), @"cachedBytes": @(cachedBytes), @"fileSize": fileSize ?: @0, @"availableBytes": availableBytes ?: @0, @"missingPayloadCount": @(missingPayloads), @"badHashCount": @(badHashes), @"manifest": manifest }; }
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
- (void)stageImportDocumentAtURL:(NSURL *)sourceURL
                      completion:(void (^)(NSURL *stagedURL, NSError *error))completion {
    if (!completion) return;
    if (!sourceURL) {
        ATMSetImportDiagnosticState(@"document-open-failed", 51);
        completion(nil, ATMBackupError(51, @"No backup file was selected."));
        return;
    }
    NSError *directoryError = nil;
    NSURL *backupDirectory = [NSURL fileURLWithPath:@"/var/mobile/Documents/AAZTweakManager/Backups" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:backupDirectory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:&directoryError]) {
        ATMSetImportDiagnosticState(@"destination-unavailable", 57);
        completion(nil, ATMBackupError(57, @"The backup storage folder is unavailable."));
        return;
    }
    NSURL *staged = [backupDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.import.staged", NSUUID.UUID.UUIDString]];
    ATMImportDocument *document = [[ATMImportDocument alloc] initWithFileURL:sourceURL];
    document.stagedURL = staged;
    document.loadFailureCode = 0;
    ATMSetImportDiagnosticState(@"document-open-started", 0);
    [document openWithCompletionHandler:^(BOOL success) {
        NSError *resultError = nil;
        if (!success) {
            NSInteger code = document.loadFailureCode ?: 64;
            NSString *message = code == 56 ? @"Select a backup file, not a folder." : ((code == 57 || code == 60) ? @"The selected backup could not be saved to local storage." : @"Files could not prepare the selected backup for import.");
            if (!document.loadFailureCode) ATMSetImportDiagnosticState(@"document-open-failed", code);
            resultError = ATMBackupError(code, message);
            [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
        } else {
            NSNumber *size = nil;
            [staged getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if (size.unsignedLongLongValue == 0) {
                [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
                ATMSetImportDiagnosticState(@"empty-file", 53);
                resultError = ATMBackupError(53, @"The selected backup file is empty.");
            } else {
                [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:staged.path error:nil];
                ATMSetImportDiagnosticState(@"staged", 0);
            }
        }
        if (!success) {
            completion(nil, resultError);
            return;
        }
        [document closeWithCompletionHandler:^(__unused BOOL closed) { completion(resultError ? nil : staged, resultError); }];
    }];
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
        if (report && error) *error = ATMBackupError(50, @"Only a healthy backup can be imported.");
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
- (NSDictionary *)restorePreviewForBackup:(NSURL *)backupURL installedPackages:(NSArray<ATMPackageRecord *> *)installed error:(NSError **)error { NSDictionary *manifest = [self manifestForBackup:backupURL error:error]; if (!manifest) return @{}; NSMutableDictionary *installedByID = [NSMutableDictionary dictionary]; for (ATMPackageRecord *record in installed) installedByID[record.packageID] = record; NSMutableArray *missing = [NSMutableArray array], *different = [NSMutableArray array], *present = [NSMutableArray array], *unavailable = [NSMutableArray array]; for (NSDictionary *package in manifest[@"packages"] ?: @[]) { NSString *packageID = package[@"packageID"] ?: @""; ATMPackageRecord *current = installedByID[packageID]; if (!current) [missing addObject:packageID]; else if (![current.version isEqualToString:package[@"version"] ?: @""]) [different addObject:packageID]; else [present addObject:packageID]; if ([package[@"debStatus"] isEqualToString:@"unavailable"]) [unavailable addObject:packageID]; } return @{ @"missing": missing, @"differentVersion": different, @"alreadyInstalled": present, @"packagePayloadUnavailable": unavailable, @"sourceCount": @([manifest[@"sources"] count]), @"safeToExecute": @NO, @"reason": @"This beta provides preview only; no package transaction is executed." }; }
- (NSArray<NSDictionary *> *)savedProfiles { NSArray *profiles = [NSUserDefaults.standardUserDefaults arrayForKey:ATMProfilesKey]; return [profiles isKindOfClass:NSArray.class] ? profiles : @[]; }
- (BOOL)saveProfileNamed:(NSString *)name packageIDs:(NSSet<NSString *> *)packageIDs error:(NSError **)error { NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!trimmed.length || trimmed.length > 40 || !packageIDs.count) { if (error) *error = ATMBackupError(60, @"Enter a profile name and select at least one package."); return NO; } NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] caseInsensitiveCompare:trimmed] == NSOrderedSame; }]; if (matches.count) [profiles removeObjectsAtIndexes:matches]; [profiles addObject:@{ @"name": trimmed, @"packageIDs": [[packageIDs allObjects] sortedArrayUsingSelector:@selector(compare:)], @"updatedAt": ATMISODateString([NSDate date]) }]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (BOOL)deleteProfileNamed:(NSString *)name error:(NSError **)error { (void)error; NSMutableArray *profiles = [self.savedProfiles mutableCopy]; NSIndexSet *matches = [profiles indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { (void)idx; (void)stop; return [item[@"name"] isEqualToString:name]; }]; [profiles removeObjectsAtIndexes:matches]; [NSUserDefaults.standardUserDefaults setObject:profiles forKey:ATMProfilesKey]; return YES; }
- (NSSet<NSString *> *)packageIDsForProfileNamed:(NSString *)name { for (NSDictionary *profile in self.savedProfiles) if ([profile[@"name"] isEqualToString:name]) return [NSSet setWithArray:profile[@"packageIDs"] ?: @[]]; return [NSSet set]; }
- (BOOL)isBackupPinned:(NSURL *)backupURL { return [[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]] containsObject:backupURL.lastPathComponent]; }
- (void)setBackup:(NSURL *)backupURL pinned:(BOOL)pinned { NSMutableSet *values = [NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:ATMPinnedBackupsKey] ?: @[]]; if (pinned) [values addObject:backupURL.lastPathComponent]; else [values removeObject:backupURL.lastPathComponent]; [NSUserDefaults.standardUserDefaults setObject:values.allObjects forKey:ATMPinnedBackupsKey]; }
@end
