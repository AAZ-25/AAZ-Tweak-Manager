#import "ATMCore.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/utsname.h>
#import <zlib.h>

static NSString *const ATMErrorDomain = @"com.aaz.tweakmanager";

NSString *ATMISODateString(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

NSString *ATMSHA256ForFile(NSURL *fileURL, NSError **error) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:fileURL];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger read = 0;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)read);
    }
    NSError *streamError = stream.streamError;
    [stream close];
    if (read < 0 || streamError) {
        if (error) *error = streamError ?: [NSError errorWithDomain:ATMErrorDomain code:10 userInfo:@{NSLocalizedDescriptionKey: @"Unable to read package file."}];
        return @"";
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

NSDictionary<NSString *, NSString *> *ATMParseDebianParagraph(NSString *paragraph) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    __block NSString *currentKey = nil;
    [paragraph enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) && currentKey) {
            NSString *old = fields[currentKey] ?: @"";
            fields[currentKey] = [old stringByAppendingFormat:@"\n%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
            return;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) { currentKey = nil; return; }
        currentKey = [line substringToIndex:colon.location];
        fields[currentKey] = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }];
    return fields;
}

NSArray<NSDictionary<NSString *, NSString *> *> *ATMParseDebianParagraphs(NSString *contents) {
    NSString *normalized = [[contents stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableString *paragraph = [NSMutableString string];
    void (^appendParagraph)(void) = ^{
        if (!paragraph.length) return;
        NSDictionary *fields = ATMParseDebianParagraph(paragraph);
        if (fields.count) [result addObject:fields];
        [paragraph setString:@""];
    };
    [normalized enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (![line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) {
            appendParagraph();
            return;
        }
        if (paragraph.length) [paragraph appendString:@"\n"];
        [paragraph appendString:line];
    }];
    appendParagraph();
    return result;
}

@implementation ATMPackageRecord
- (NSDictionary *)manifestDictionary {
    return @{ @"packageID": self.packageID ?: @"", @"name": self.name ?: @"", @"version": self.version ?: @"",
              @"architecture": self.architecture ?: @"", @"section": self.section ?: @"", @"priority": self.priority ?: @"",
              @"origin": self.sourceOrigin ?: @"", @"depends": self.depends ?: @"", @"provides": self.provides ?: @"", @"essential": @(self.essential),
              @"automatic": @(self.automaticallyInstalled), @"personal": @(self.personalCandidate),
              @"classificationReason": self.classificationReason ?: @"", @"installedAt": self.installedAt ? ATMISODateString(self.installedAt) : [NSNull null],
              @"dateConfidence": @(self.dateConfidence) };
}
@end

@implementation ATMSourceRecord
- (NSDictionary *)manifestDictionary {
    return @{ @"path": self.relativePath ?: @"", @"contents": self.sanitizedContents ?: @"",
              @"credentialsRedacted": @(self.credentialsRedacted), @"enabled": @(self.enabled) };
}
@end

@interface ATMEnvironment ()
@property(nonatomic, copy, readwrite) NSString *jailbreakRoot;
@property(nonatomic, copy, readwrite) NSString *dpkgStatusPath;
@property(nonatomic, copy, readwrite) NSString *aptStatePath;
@property(nonatomic, copy, readwrite) NSString *aptCachePath;
@property(nonatomic, copy, readwrite) NSString *dpkgLogPath;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *sourceRoots;
@property(nonatomic, assign, readwrite) BOOL supportedRootless;
@end

@implementation ATMEnvironment
+ (instancetype)currentEnvironment {
    ATMEnvironment *environment = [ATMEnvironment new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [fm fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    environment.jailbreakRoot = root;
    NSArray *statusCandidates = root.length ? @[[root stringByAppendingString:@"/Library/dpkg/status"], [root stringByAppendingString:@"/var/lib/dpkg/status"]] : @[];
    NSString *status = @"";
    NSUInteger bestInstalledCount = 0;
    for (NSString *candidate in statusCandidates) {
        if (![fm isReadableFileAtPath:candidate]) continue;
        NSString *contents = [NSString stringWithContentsOfFile:candidate encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSUInteger installedCount = 0;
        for (NSDictionary *fields in ATMParseDebianParagraphs(contents)) {
            NSArray *words = [fields[@"Status"] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSMutableArray *tokens = [NSMutableArray array];
            for (NSString *word in words) if (word.length) [tokens addObject:word.lowercaseString];
            if (tokens.count >= 2 && [tokens containsObject:@"ok"] && [tokens.lastObject isEqualToString:@"installed"]) installedCount++;
        }
        if (!status.length || installedCount > bestInstalledCount) {
            status = candidate;
            bestInstalledCount = installedCount;
        }
    }
    environment.dpkgStatusPath = status;
    environment.aptStatePath = [root stringByAppendingString:@"/var/lib/apt/extended_states"];
    environment.aptCachePath = [root stringByAppendingString:@"/var/cache/apt/archives"];
    environment.dpkgLogPath = [root stringByAppendingString:@"/var/log"];
    environment.sourceRoots = @[[root stringByAppendingString:@"/etc/apt"], [root stringByAppendingString:@"/etc/apt/sources.list.d"], [root stringByAppendingString:@"/etc/apt/sileo.list.d"]];
    environment.supportedRootless = root.length > 0 && [fm isReadableFileAtPath:status];
    return environment;
}
- (NSString *)pathInsideRoot:(NSString *)path {
    if (![path hasPrefix:@"/"]) return @"";
    return [self.jailbreakRoot stringByAppendingString:path];
}
@end

static NSString *ATMReadTextFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

static NSString *ATMReadGzipFile(NSString *path) {
    gzFile file = gzopen(path.fileSystemRepresentation, "rb");
    if (!file) return @"";
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[32768];
    int count = 0;
    while ((count = gzread(file, buffer, sizeof(buffer))) > 0) [data appendBytes:buffer length:(NSUInteger)count];
    gzclose(file);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

NSSet<NSString *> *ATMProtectedPackageIDs(void) {
    return [NSSet setWithArray:@[@"apt", @"apt7", @"base", @"bash", @"coreutils", @"dash", @"debianutils", @"diffutils",
                                 @"dpkg", @"essential", @"firmware", @"grep", @"gzip", @"launchctl", @"libapt-pkg6.0",
                                 @"org.coolstar.sileo", @"org.coolstar.sileorespring", @"xyz.willy.zebra", @"jailbreak-resources",
                                 @"ellekit", @"mobilesubstrate", @"preferenceloader", @"substitute", @"libhooker"]];
}

static NSDictionary<NSString *, NSNumber *> *ATMAutomaticStates(NSString *path) {
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    for (NSDictionary *fields in ATMParseDebianParagraphs(ATMReadTextFile(path))) {
        NSString *packageID = fields[@"Package"];
        if (packageID.length) states[packageID] = @([fields[@"Auto-Installed"] integerValue] == 1);
    }
    return states;
}

static BOOL ATMStatusIsInstalled(NSString *status) {
    NSArray *words = [status componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *word in words) if (word.length) [tokens addObject:word.lowercaseString];
    return tokens.count >= 2 && [tokens containsObject:@"ok"] && [tokens.lastObject isEqualToString:@"installed"];
}

static NSDictionary<NSString *, NSDate *> *ATMInstallDates(NSString *logDirectory) {
    NSMutableDictionary *dates = [NSMutableDictionary dictionary];
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:logDirectory error:nil] ?: @[];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{4}-\\d{2}-\\d{2}) (\\d{2}:\\d{2}:\\d{2}) install ([^ :]+)(?::[^ ]+)? " options:0 error:nil];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    for (NSString *name in names) {
        if (![name isEqualToString:@"dpkg.log"] && ![name hasPrefix:@"dpkg.log."]) continue;
        NSString *path = [logDirectory stringByAppendingPathComponent:name];
        NSString *text = [name hasSuffix:@".gz"] ? ATMReadGzipFile(path) : ATMReadTextFile(path);
        [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (!match || match.numberOfRanges < 4) return;
            NSString *stamp = [NSString stringWithFormat:@"%@ %@", [line substringWithRange:[match rangeAtIndex:1]], [line substringWithRange:[match rangeAtIndex:2]]];
            NSString *packageID = [line substringWithRange:[match rangeAtIndex:3]];
            NSDate *date = [formatter dateFromString:stamp];
            if (date && (!dates[packageID] || [date compare:dates[packageID]] == NSOrderedAscending)) dates[packageID] = date;
        }];
    }
    return dates;
}

static NSString *ATMSanitizeSourceText(NSString *text, BOOL *didRedact) {
    NSError *error = nil;
    NSRegularExpression *userinfo = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z][A-Za-z0-9+.-]*://)([^\\s/@]+)@" options:0 error:&error];
    if (error || !userinfo) return text;
    NSUInteger userinfoMatches = [userinfo numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSString *sanitized = [userinfo stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"$1<credentials-redacted>@"];
    NSRegularExpression *querySecret = [NSRegularExpression regularExpressionWithPattern:@"([?&](?:token|key|auth|password|passwd|access_token)=)[^&\\s]+" options:NSRegularExpressionCaseInsensitive error:&error];
    if (error || !querySecret) return sanitized;
    NSUInteger queryMatches = [querySecret numberOfMatchesInString:sanitized options:0 range:NSMakeRange(0, sanitized.length)];
    sanitized = [querySecret stringByReplacingMatchesInString:sanitized options:0 range:NSMakeRange(0, sanitized.length) withTemplate:@"$1<credentials-redacted>"];
    if (didRedact) *didRedact = userinfoMatches > 0 || queryMatches > 0;
    return sanitized;
}

@implementation ATMPackageScanner
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment {
    if ((self = [super init])) _environment = environment;
    return self;
}
- (NSArray<ATMPackageRecord *> *)scanInstalledPackages:(NSError **)error {
    NSString *statusText = ATMReadTextFile(self.environment.dpkgStatusPath);
    if (!statusText.length) {
        if (error) *error = [NSError errorWithDomain:ATMErrorDomain code:20 userInfo:@{NSLocalizedDescriptionKey: @"The rootless dpkg database is unavailable."}];
        return @[];
    }
    NSDictionary *automatic = ATMAutomaticStates(self.environment.aptStatePath);
    NSDictionary *dates = ATMInstallDates(self.environment.dpkgLogPath);
    NSSet *protected = ATMProtectedPackageIDs();
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *fields in ATMParseDebianParagraphs(statusText)) {
        if (!ATMStatusIsInstalled(fields[@"Status"] ?: @"")) continue;
        NSString *packageID = fields[@"Package"] ?: @"";
        if (!packageID.length) continue;
        ATMPackageRecord *record = [ATMPackageRecord new];
        record.packageID = packageID;
        NSString *packageName = fields[@"Name"];
        record.name = packageName.length ? packageName : packageID;
        record.version = fields[@"Version"] ?: @"";
        record.architecture = fields[@"Architecture"] ?: @"";
        record.section = fields[@"Section"] ?: @"";
        record.priority = fields[@"Priority"] ?: @"";
        record.sourceOrigin = fields[@"Origin"] ?: @"";
        NSString *depends = fields[@"Depends"] ?: @"", *preDepends = fields[@"Pre-Depends"] ?: @"";
        record.depends = preDepends.length && depends.length ? [NSString stringWithFormat:@"%@, %@", preDepends, depends] : (preDepends.length ? preDepends : depends);
        record.provides = fields[@"Provides"] ?: @"";
        NSString *essentialValue = fields[@"Essential"];
        record.essential = essentialValue.length > 0 && [essentialValue caseInsensitiveCompare:@"yes"] == NSOrderedSame;
        record.automaticallyInstalled = [automatic[packageID] boolValue];
        BOOL requiredPriority = [@[@"required", @"important"] containsObject:record.priority.lowercaseString];
        BOOL protectedID = [protected containsObject:packageID.lowercaseString];
        record.personalCandidate = !record.automaticallyInstalled && !record.essential && !requiredPriority && !protectedID;
        if (record.automaticallyInstalled) record.classificationReason = @"Dependency installed automatically";
        else if (record.essential) record.classificationReason = @"Essential system package";
        else if (requiredPriority) record.classificationReason = @"Required bootstrap package";
        else if (protectedID) record.classificationReason = @"Protected jailbreak component";
        else record.classificationReason = @"Manually installed candidate";
        record.installedAt = dates[packageID];
        record.dateConfidence = record.installedAt ? ATMInstallDateConfidenceLogExact : ATMInstallDateConfidenceUnknown;
        [records addObject:record];
    }
    if (!records.count) {
        if (error) *error = [NSError errorWithDomain:ATMErrorDomain code:21 userInfo:@{NSLocalizedDescriptionKey: @"The package database was found, but no installed package records could be decoded."}];
        return @[];
    }
    [records sortUsingComparator:^NSComparisonResult(ATMPackageRecord *a, ATMPackageRecord *b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
    return records;
}
- (NSArray<ATMSourceRecord *> *)scanSources:(NSError **)error {
    (void)error;
    NSMutableArray *sources = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *aptRoot = self.environment.sourceRoots.firstObject;
    NSArray *single = @[[aptRoot stringByAppendingPathComponent:@"sources.list"]];
    NSMutableArray *files = [single mutableCopy];
    for (NSString *directory in [self.environment.sourceRoots subarrayWithRange:NSMakeRange(1, self.environment.sourceRoots.count - 1)]) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] ?: @[]) {
            if (![name hasSuffix:@".list"] && ![name hasSuffix:@".sources"]) continue;
            [files addObject:[directory stringByAppendingPathComponent:name]];
        }
    }
    for (NSString *path in files) {
        if ([seen containsObject:path] || ![NSFileManager.defaultManager isReadableFileAtPath:path]) continue;
        [seen addObject:path];
        NSString *contents = ATMReadTextFile(path);
        if (!contents.length) continue;
        BOOL redacted = NO;
        ATMSourceRecord *record = [ATMSourceRecord new];
        record.relativePath = [path hasPrefix:self.environment.jailbreakRoot] ? [path substringFromIndex:self.environment.jailbreakRoot.length] : path;
        record.sanitizedContents = ATMSanitizeSourceText(contents, &redacted);
        record.credentialsRedacted = redacted;
        NSString *trimmed = [contents stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        record.enabled = ![trimmed hasPrefix:@"#"] && [trimmed rangeOfString:@"Enabled: no" options:NSCaseInsensitiveSearch].location == NSNotFound;
        [sources addObject:record];
    }
    [sources sortUsingComparator:^NSComparisonResult(ATMSourceRecord *a, ATMSourceRecord *b) { return [a.relativePath compare:b.relativePath]; }];
    return sources;
}
@end

static NSURL *ATMApplicationSupportDirectory(void) {
    NSURL *directory = [NSURL fileURLWithPath:@"/var/mobile/Library/Application Support/AAZTweakManager" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    return directory;
}

static NSString *const ATMImportDiagnosticsEnabledKey = @"ATMImportDiagnosticsEnabled";
static NSString *const ATMImportTraceKey = @"ATMImportTraceV1";
static NSString *const ATMLastImportStageKey = @"ATMLastImportStageV1";
static NSString *const ATMLastImportErrorCodeKey = @"ATMLastImportErrorCodeV1";
static NSString *const ATMLastImportBuildKey = @"ATMLastImportBuildV2";
static NSString *const ATMLastImportAttemptKey = @"ATMLastImportAttemptV2";
static NSString *const ATMLastImportAttemptStateKey = @"ATMLastImportAttemptStateV2";
static NSInteger ATMImportDiagnosticSuppressionDepth = 0;
static NSString *const ATMLastRestoreCodeKey = @"ATMLastRestoreCodeV1";
static NSString *const ATMLastRestoreExitCodeKey = @"ATMLastRestoreExitCodeV1";
static NSString *const ATMLastRestoreBuildKey = @"ATMLastRestoreBuildV2";
static NSString *const ATMLastRestoreSummaryKey = @"ATMLastRestoreSummaryV2";
static NSString *const ATMLastBackupBuildKey = @"ATMLastBackupBuildV2";
static NSString *const ATMLastBackupSummaryKey = @"ATMLastBackupSummaryV2";

static BOOL ATMRestoreDiagnosticCodeAllowed(NSString *code) {
    static NSSet<NSString *> *allowedCodes; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedCodes = [NSSet setWithArray:@[
            @"R40-READINESS", @"R40-READY", @"R40-NOOP", @"R40-BLOCKED", @"R40-STARTED", @"R40-OK", @"R40-PRECHECK", @"R40-APT-PREFLIGHT",
            @"R40-PERSONA", @"R40-SPAWN", @"R40-SIGNAL", @"R40-LOCK", @"R40-PRIVILEGE", @"R40-STORAGE", @"R40-DPKG", @"R40-DPKG-PREFLIGHT", @"R40-PARTIAL",
            @"R40-DEPENDENCY", @"R40-ARCHIVE", @"R40-AUTH", @"R40-SOURCE-AUTH", @"R40-SOURCE-PREFLIGHT", @"R40-SOURCE-READY", @"R40-SOURCE-OK", @"R40-SOURCE-RESTORE", @"R40-NETWORK", @"R40-APT", @"R40-POSTSCAN", @"R40-VERIFY", @"R40-UNKNOWN"
        ]];
    });
    return [code isKindOfClass:NSString.class] && [allowedCodes containsObject:code];
}

void ATMSetRestoreDiagnosticState(NSString *code, NSInteger exitCode) {
    NSString *safeCode = ATMRestoreDiagnosticCodeAllowed(code) ? code : @"R40-UNKNOWN";
    [NSUserDefaults.standardUserDefaults setObject:safeCode forKey:ATMLastRestoreCodeKey];
    [NSUserDefaults.standardUserDefaults setInteger:exitCode forKey:ATMLastRestoreExitCodeKey];
    [NSUserDefaults.standardUserDefaults setObject:NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown" forKey:ATMLastRestoreBuildKey];
}

NSArray<NSString *> *ATMBackupCaptureStageKeys(void) {
    NSMutableArray<NSString *> *keys = [@[@"preflight", @"preflight-warning", @"preflight-workspace", @"preflight-tools", @"preflight-persona", @"preflight-staging", @"preflight-direct-copy-tools", @"preflight-direct-copy", @"preflight-direct-directory-containment", @"preflight-direct-directory-create", @"preflight-fallback-staging", @"preflight-fallback-create", @"preflight-fallback-extract", @"preflight-fallback-verify", @"preflight-control", @"preflight-build", @"preflight-identity", @"preflight-identity-file", @"preflight-identity-tool", @"preflight-identity-package", @"preflight-identity-version", @"preflight-identity-architecture", @"preflight-identity-policy", @"preflight-identity-hash", @"preflight-identity-unknown", @"preflight-reopen-directory", @"preflight-reopen", @"preflight-payload-verify", @"preflight-restore-dry-run", @"preflight-archive", @"preflight-archive-verify", @"preflight-share-inbox", @"preflight-import", @"preflight-unknown", @"inventory", @"payload", @"privacy", @"verification", @"tools", @"workspace", @"staging", @"directory-containment", @"directory-create", @"directory-staging", @"archive", @"archive-create", @"archive-extract", @"direct-copy-tools", @"direct-copy", @"direct-copy-verify", @"archive-fallback-create", @"archive-fallback-extract", @"archive-fallback-verify", @"control", @"build", @"identity", @"identity-file", @"identity-tool", @"identity-package", @"identity-version", @"identity-architecture", @"identity-policy", @"identity-hash", @"identity-unknown", @"package-reopen-directory", @"package-reopen", @"package-payload-verify", @"cancelled", @"unknown"] mutableCopy];
    NSArray<NSString *> *prefixes = @[@"preflight-direct-copy-verify", @"preflight-fallback-verify", @"preflight-payload-verify", @"direct-copy-verify", @"archive-fallback-verify", @"package-payload-verify"];
    NSArray<NSString *> *reasons = @[@"enumeration", @"unexpected-directory", @"unexpected-entry", @"missing-entry", @"source", @"type", @"mode", @"size", @"content", @"symlink", @"unknown"];
    for (NSString *prefix in prefixes) for (NSString *reason in reasons) [keys addObject:[NSString stringWithFormat:@"%@-%@", prefix, reason]];
    return keys;
}

static NSNumber *ATMReportNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : @0; }

void ATMStoreBackupReportSummary(NSDictionary *report) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![report isKindOfClass:NSDictionary.class]) {
        [defaults removeObjectForKey:ATMLastBackupBuildKey];
        [defaults removeObjectForKey:ATMLastBackupSummaryKey];
        return;
    }
    NSDictionary *manifest = [report[@"manifest"] isKindOfClass:NSDictionary.class] ? report[@"manifest"] : @{};
    NSDictionary *failures = [report[@"captureFailureCounts"] isKindOfClass:NSDictionary.class] ? report[@"captureFailureCounts"] : @{};
    NSMutableDictionary *safeFailures = [NSMutableDictionary dictionary];
    for (NSString *key in ATMBackupCaptureStageKeys()) safeFailures[key] = ATMReportNumber(failures[key]);
    static NSSet<NSString *> *healthValues; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ healthValues = [NSSet setWithArray:@[@"Healthy", @"Incomplete", @"Failed", @"Cancelled", @"Preparing"]]; });
    NSString *health = [healthValues containsObject:report[@"health"]] ? report[@"health"] : @"Unknown";
    NSDictionary *summary = @{
        @"health": health, @"portable": @([report[@"portable"] boolValue]),
        @"packages": ATMReportNumber(report[@"packageCount"]), @"sources": ATMReportNumber(report[@"sourceCount"]),
        @"restorableSources": ATMReportNumber(report[@"restorableSourceCount"]), @"embeddedDEBs": ATMReportNumber(report[@"cachedDEBCount"]),
        @"safelyRepacked": ATMReportNumber(report[@"repackedDEBCount"]), @"portableCoverage": ATMReportNumber(manifest[@"payloadCoverage"]),
        @"payloadUnavailable": ATMReportNumber(report[@"missingPayloadCount"]), @"badHashes": ATMReportNumber(report[@"badHashCount"]),
        @"packageHashFailures": ATMReportNumber(report[@"packageHashFailureCount"]), @"sourceHashFailures": ATMReportNumber(report[@"sourceHashFailureCount"]),
        @"unreadableEntries": ATMReportNumber(report[@"unreadableEntryCount"]), @"captureFailureCounts": safeFailures
    };
    [defaults setObject:NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown" forKey:ATMLastBackupBuildKey];
    [defaults setObject:summary forKey:ATMLastBackupSummaryKey];
}

void ATMStoreRestoreReportSummary(NSDictionary *plan, NSDictionary *result, NSError *failure) {
    NSString *state = result ? ([result[@"success"] boolValue] ? @"completed" : @"failed") : (plan ? ([plan[@"safeToExecute"] boolValue] ? @"ready" : ([plan[@"noChangesNeeded"] boolValue] ? @"no-op" : @"blocked")) : @"failed");
    NSDictionary *summary = @{
        @"state": state, @"errorCode": @(failure ? failure.code : 0),
        @"requested": ATMReportNumber(result[@"requested"]), @"completed": ATMReportNumber(result[@"completed"]),
        @"remaining": ATMReportNumber(result[@"remaining"]), @"sourcesPending": ATMReportNumber(plan[@"sourcesToRestore"]),
        @"sourcesRestored": ATMReportNumber(result[@"sourcesRestored"]),
        @"privateSourcesSkipped": ATMReportNumber(result[@"privateSourcesSkipped"] ?: plan[@"privateSourcesSkipped"]),
        @"blocked": ATMReportNumber(plan[@"blocked"]), @"protectedOrInvalid": ATMReportNumber(plan[@"protectedOrInvalid"]),
        @"held": ATMReportNumber(plan[@"held"]), @"metadataUnavailable": ATMReportNumber(plan[@"metadataUnavailable"]),
        @"unexpectedActions": ATMReportNumber(plan[@"unexpectedActions"])
    };
    [NSUserDefaults.standardUserDefaults setObject:NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown" forKey:ATMLastRestoreBuildKey];
    [NSUserDefaults.standardUserDefaults setObject:summary forKey:ATMLastRestoreSummaryKey];
}

static BOOL ATMImportDiagnosticStageAllowed(NSString *stage) {
    static NSSet<NSString *> *allowedStages; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedStages = [NSSet setWithArray:@[
            @"share-extension-received", @"security-scope-granted", @"security-scope-not-required",
            @"copying", @"copy-direct-started", @"copy-direct-failed",
            @"coordination-fallback-started", @"coordination-accessor-called", @"invalid-selection", @"destination-unavailable",
            @"source-read-failed", @"destination-write-failed",
            @"coordination-failed", @"empty-file", @"staged", @"validating", @"duplicate",
            @"archive-decryption-failed",
            @"archive-layout-failed", @"archive-crc-failed", @"archive-footer-failed", @"archive-index-failed", @"manifest-schema-failed",
            @"package-hash-failed",
            @"source-hash-failed", @"entry-integrity-failed", @"finalize-failed", @"cancelled", @"completed"
        ]];
    });
    return [stage isKindOfClass:NSString.class] && [allowedStages containsObject:stage];
}

BOOL ATMImportDiagnosticsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:ATMImportDiagnosticsEnabledKey];
}

void ATMClearImportDiagnosticTrace(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMImportTraceKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMLastImportStageKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMLastImportErrorCodeKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMLastImportBuildKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMLastImportAttemptKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:ATMLastImportAttemptStateKey];
}

void ATMBeginImportDiagnosticAttempt(void) {
    ATMClearImportDiagnosticTrace();
    NSString *identifier = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8];
    [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithFormat:@"I-%@", identifier] forKey:ATMLastImportAttemptKey];
    [NSUserDefaults.standardUserDefaults setObject:NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown" forKey:ATMLastImportBuildKey];
    [NSUserDefaults.standardUserDefaults setObject:@"in-progress" forKey:ATMLastImportAttemptStateKey];
}

void ATMPushImportDiagnosticSuppression(void) {
    @synchronized (NSUserDefaults.standardUserDefaults) { ATMImportDiagnosticSuppressionDepth++; }
}

void ATMPopImportDiagnosticSuppression(void) {
    @synchronized (NSUserDefaults.standardUserDefaults) { if (ATMImportDiagnosticSuppressionDepth > 0) ATMImportDiagnosticSuppressionDepth--; }
}

void ATMSetImportDiagnosticsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ATMImportDiagnosticsEnabledKey];
    ATMClearImportDiagnosticTrace();
}

void ATMRecordImportDiagnosticEvent(NSString *stage) {
    if (ATMImportDiagnosticSuppressionDepth > 0) return;
    if (!ATMImportDiagnosticsEnabled() || !ATMImportDiagnosticStageAllowed(stage)) return;
    NSArray *existing = [NSUserDefaults.standardUserDefaults arrayForKey:ATMImportTraceKey] ?: @[];
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    for (id item in existing) if ([item isKindOfClass:NSString.class] && ATMImportDiagnosticStageAllowed(item)) [trace addObject:item];
    [trace addObject:stage];
    while (trace.count > 32) [trace removeObjectAtIndex:0];
    [NSUserDefaults.standardUserDefaults setObject:trace forKey:ATMImportTraceKey];
}

void ATMSetImportDiagnosticState(NSString *stage, NSInteger code) {
    if (ATMImportDiagnosticSuppressionDepth > 0) return;
    if (!ATMImportDiagnosticStageAllowed(stage)) return;
    if (![NSUserDefaults.standardUserDefaults stringForKey:ATMLastImportAttemptKey]) ATMBeginImportDiagnosticAttempt();
    [NSUserDefaults.standardUserDefaults setObject:stage forKey:ATMLastImportStageKey];
    [NSUserDefaults.standardUserDefaults setInteger:code forKey:ATMLastImportErrorCodeKey];
    BOOL terminal = [stage isEqualToString:@"completed"] || code != 0;
    [NSUserDefaults.standardUserDefaults setObject:terminal ? ([stage isEqualToString:@"completed"] ? @"completed" : @"failed") : @"in-progress" forKey:ATMLastImportAttemptStateKey];
    ATMRecordImportDiagnosticEvent(stage);
}

static NSDictionary *ATMCurrentReportState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *currentBuild = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown";
    BOOL backupCurrent = [[defaults stringForKey:ATMLastBackupBuildKey] isEqualToString:currentBuild];
    BOOL importCurrent = [[defaults stringForKey:ATMLastImportBuildKey] isEqualToString:currentBuild];
    BOOL restoreCurrent = [[defaults stringForKey:ATMLastRestoreBuildKey] isEqualToString:currentBuild];
    return @{ @"build": currentBuild,
              @"backup": backupCurrent ? ([defaults dictionaryForKey:ATMLastBackupSummaryKey] ?: @{}) : @{},
              @"importCurrent": @(importCurrent), @"restoreCurrent": @(restoreCurrent),
              @"restore": restoreCurrent ? ([defaults dictionaryForKey:ATMLastRestoreSummaryKey] ?: @{}) : @{} };
}

NSDictionary<NSString *, NSString *> *ATMUnifiedReportSnapshot(void) {
    NSDictionary *state = ATMCurrentReportState(); NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *backup = state[@"backup"];
    BOOL importCurrent = [state[@"importCurrent"] boolValue], restoreCurrent = [state[@"restoreCurrent"] boolValue];
    NSString *backupStatus = backup.count ? [NSString stringWithFormat:@"%@ • %@/%@ DEBs", backup[@"health"] ?: @"Unknown", backup[@"embeddedDEBs"] ?: @0, backup[@"packages"] ?: @0] : @"No current result";
    NSString *importState = importCurrent ? ([defaults stringForKey:ATMLastImportAttemptStateKey] ?: @"not-run") : @"No current result";
    NSString *restoreCode = restoreCurrent ? ([defaults stringForKey:ATMLastRestoreCodeKey] ?: @"not-run") : @"No current result";
    NSSet<NSString *> *nonFailureRestoreCodes = [NSSet setWithArray:@[@"R40-OK", @"R40-SOURCE-OK", @"R40-NOOP", @"R40-READY", @"R40-SOURCE-READY"]];
    BOOL failed = (backup.count && ![backup[@"health"] isEqualToString:@"Healthy"]) || (importCurrent && [importState isEqualToString:@"failed"]) || (restoreCurrent && ![nonFailureRestoreCodes containsObject:restoreCode]);
    BOOL backupOK = [backup[@"health"] isEqualToString:@"Healthy"];
    BOOL importOK = importCurrent && [importState isEqualToString:@"completed"];
    BOOL restoreOK = restoreCurrent && [@[@"R40-OK", @"R40-SOURCE-OK", @"R40-NOOP"] containsObject:restoreCode];
    NSString *overall = failed ? @"Needs Attention" : (backupOK && importOK && restoreOK ? @"Healthy" : (backupOK && importOK ? @"Restore Test Pending" : ((backup.count || importCurrent || restoreCurrent) ? @"Current Results Available" : @"No current result")));
    return @{ @"overall": overall, @"backup": backupStatus, @"import": importState, @"restore": restoreCode, @"build": state[@"build"] ?: @"unknown" };
}

NSString *ATMUnifiedReportText(ATMEnvironment *environment,
                               NSArray<ATMPackageRecord *> *packages,
                               NSSet<NSString *> *selectedPackageIDs,
                               NSError *scanError) {
    NSUInteger personal = 0;
    NSUInteger automatic = 0;
    NSUInteger essential = 0;
    NSUInteger requiredPriority = 0;
    NSUInteger protectedPackage = 0;
    NSUInteger otherExcluded = 0;
    for (ATMPackageRecord *record in packages) {
        if (record.personalCandidate) personal++;
        else if ([record.classificationReason isEqualToString:@"Dependency installed automatically"]) automatic++;
        else if ([record.classificationReason isEqualToString:@"Essential system package"]) essential++;
        else if ([record.classificationReason isEqualToString:@"Required bootstrap package"]) requiredPriority++;
        else if ([record.classificationReason isEqualToString:@"Protected jailbreak component"]) protectedPackage++;
        else otherExcluded++;
    }
    NSString *databaseKind = @"none";
    if ([environment.dpkgStatusPath hasSuffix:@"/Library/dpkg/status"]) databaseKind = @"library-dpkg";
    else if ([environment.dpkgStatusPath hasSuffix:@"/var/lib/dpkg/status"]) databaseKind = @"var-lib-dpkg";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *currentBuild = info[@"CFBundleVersion"] ?: @"unknown";
    NSDictionary *state = ATMCurrentReportState(); NSDictionary *snapshot = ATMUnifiedReportSnapshot();
    NSDictionary *backup = state[@"backup"], *restore = state[@"restore"];
    BOOL currentImportAttempt = [state[@"importCurrent"] boolValue], currentRestoreCode = [state[@"restoreCurrent"] boolValue];
    NSString *storedImportBuild = [NSUserDefaults.standardUserDefaults stringForKey:ATMLastImportBuildKey];
    NSString *storedRestoreCode = [NSUserDefaults.standardUserDefaults stringForKey:ATMLastRestoreCodeKey];
    NSMutableArray<NSString *> *lines = [@[
        @"AAZ Tweak Manager Report",
        @"format=2",
        [NSString stringWithFormat:@"appVersion=%@", info[@"CFBundleShortVersionString"] ?: @"unknown"],
        [NSString stringWithFormat:@"appBuild=%@", currentBuild],
        @"[Summary]",
        [NSString stringWithFormat:@"overall=%@", snapshot[@"overall"]],
        @"[Backup]",
        [NSString stringWithFormat:@"backupState=%@", backup.count ? @"current" : @"not-run"],
        [NSString stringWithFormat:@"health=%@", backup[@"health"] ?: @"not-run"],
        [NSString stringWithFormat:@"portable=%@", backup.count ? ([backup[@"portable"] boolValue] ? @"yes" : @"no") : @"not-run"],
        [NSString stringWithFormat:@"packages=%@", backup[@"packages"] ?: @0],
        [NSString stringWithFormat:@"sources=%@", backup[@"sources"] ?: @0],
        [NSString stringWithFormat:@"restorableSources=%@", backup[@"restorableSources"] ?: @0],
        [NSString stringWithFormat:@"embeddedDEBs=%@", backup[@"embeddedDEBs"] ?: @0],
        [NSString stringWithFormat:@"safelyRepacked=%@", backup[@"safelyRepacked"] ?: @0],
        [NSString stringWithFormat:@"portableCoverage=%@", backup[@"portableCoverage"] ?: @0],
        [NSString stringWithFormat:@"payloadUnavailable=%@", backup[@"payloadUnavailable"] ?: @0],
        [NSString stringWithFormat:@"badHashes=%@", backup[@"badHashes"] ?: @0],
        [NSString stringWithFormat:@"packageHashFailures=%@", backup[@"packageHashFailures"] ?: @0],
        [NSString stringWithFormat:@"sourceHashFailures=%@", backup[@"sourceHashFailures"] ?: @0],
        [NSString stringWithFormat:@"unreadableEntries=%@", backup[@"unreadableEntries"] ?: @0],
        @"[Import]",
        [NSString stringWithFormat:@"importAttemptBuild=%@", currentImportAttempt ? storedImportBuild : @"not-run"],
        [NSString stringWithFormat:@"importAttemptID=%@", currentImportAttempt ? ([NSUserDefaults.standardUserDefaults stringForKey:ATMLastImportAttemptKey] ?: @"not-run") : @"not-run"],
        [NSString stringWithFormat:@"importAttemptState=%@", currentImportAttempt ? ([NSUserDefaults.standardUserDefaults stringForKey:ATMLastImportAttemptStateKey] ?: @"not-run") : @"not-run"],
        [NSString stringWithFormat:@"importStage=%@", currentImportAttempt ? ([NSUserDefaults.standardUserDefaults stringForKey:ATMLastImportStageKey] ?: @"not-run") : @"not-run"],
        [NSString stringWithFormat:@"importErrorCode=%ld", (long)(currentImportAttempt ? [NSUserDefaults.standardUserDefaults integerForKey:ATMLastImportErrorCodeKey] : 0)],
        @"[Restore]",
        [NSString stringWithFormat:@"restoreState=%@", currentRestoreCode ? (restore[@"state"] ?: @"current") : @"not-run"],
        [NSString stringWithFormat:@"restoreCode=%@", currentRestoreCode ? storedRestoreCode : @"not-run"],
        [NSString stringWithFormat:@"restoreExitCode=%ld", (long)(currentRestoreCode ? [NSUserDefaults.standardUserDefaults integerForKey:ATMLastRestoreExitCodeKey] : -1)],
        [NSString stringWithFormat:@"restoreErrorCode=%@", restore[@"errorCode"] ?: @0],
        [NSString stringWithFormat:@"requested=%@", restore[@"requested"] ?: @0],
        [NSString stringWithFormat:@"completed=%@", restore[@"completed"] ?: @0],
        [NSString stringWithFormat:@"remaining=%@", restore[@"remaining"] ?: @0],
        [NSString stringWithFormat:@"sourcesPending=%@", restore[@"sourcesPending"] ?: @0],
        [NSString stringWithFormat:@"sourcesRestored=%@", restore[@"sourcesRestored"] ?: @0],
        [NSString stringWithFormat:@"privateSourcesSkipped=%@", restore[@"privateSourcesSkipped"] ?: @0],
        [NSString stringWithFormat:@"blocked=%@", restore[@"blocked"] ?: @0],
        [NSString stringWithFormat:@"protectedOrInvalid=%@", restore[@"protectedOrInvalid"] ?: @0],
        [NSString stringWithFormat:@"held=%@", restore[@"held"] ?: @0],
        [NSString stringWithFormat:@"metadataUnavailable=%@", restore[@"metadataUnavailable"] ?: @0],
        [NSString stringWithFormat:@"unexpectedActions=%@", restore[@"unexpectedActions"] ?: @0],
        @"[Environment]",
        [NSString stringWithFormat:@"rootlessDetected=%@", environment.supportedRootless ? @"yes" : @"no"],
        [NSString stringWithFormat:@"statusDatabase=%@", databaseKind],
        [NSString stringWithFormat:@"statusReadable=%@", [fm isReadableFileAtPath:environment.dpkgStatusPath] ? @"yes" : @"no"],
        [NSString stringWithFormat:@"aptStateReadable=%@", [fm isReadableFileAtPath:environment.aptStatePath] ? @"yes" : @"no"],
        [NSString stringWithFormat:@"scanErrorCode=%ld", (long)(scanError ? scanError.code : 0)],
        [NSString stringWithFormat:@"installed=%lu", (unsigned long)packages.count],
        [NSString stringWithFormat:@"personal=%lu", (unsigned long)personal],
        [NSString stringWithFormat:@"excludedAutomatic=%lu", (unsigned long)automatic],
        [NSString stringWithFormat:@"excludedEssential=%lu", (unsigned long)essential],
        [NSString stringWithFormat:@"excludedPriority=%lu", (unsigned long)requiredPriority],
        [NSString stringWithFormat:@"excludedProtected=%lu", (unsigned long)protectedPackage],
        [NSString stringWithFormat:@"excludedOther=%lu", (unsigned long)otherExcluded],
        [NSString stringWithFormat:@"selected=%lu", (unsigned long)selectedPackageIDs.count]
    ] mutableCopy];
    NSDictionary *failureCounts = [backup[@"captureFailureCounts"] isKindOfClass:NSDictionary.class] ? backup[@"captureFailureCounts"] : @{};
    [lines addObject:@"[BackupCapture]"];
    for (NSString *key in ATMBackupCaptureStageKeys()) [lines addObject:[NSString stringWithFormat:@"capture.%@=%@", key, failureCounts[key] ?: @0]];
    BOOL importDebugEnabled = ATMImportDiagnosticsEnabled();
    [lines addObject:@"[ImportTrace]"];
    [lines addObject:[NSString stringWithFormat:@"importDebugEnabled=%@", importDebugEnabled ? @"yes" : @"no"]];
    if (importDebugEnabled) {
        NSArray *storedTrace = currentImportAttempt ? ([NSUserDefaults.standardUserDefaults arrayForKey:ATMImportTraceKey] ?: @[]) : @[];
        NSMutableArray<NSString *> *safeTrace = [NSMutableArray array];
        for (id item in storedTrace) if ([item isKindOfClass:NSString.class] && ATMImportDiagnosticStageAllowed(item)) [safeTrace addObject:item];
        [lines addObject:@"importTraceFormat=1"];
        [lines addObject:[NSString stringWithFormat:@"importTraceCount=%lu", (unsigned long)safeTrace.count]];
        [lines addObject:[NSString stringWithFormat:@"importTrace=%@", safeTrace.count ? [safeTrace componentsJoinedByString:@" > "] : @"empty"]];
        [lines addObject:@"importDebugPrivacy=fixed-stage-labels-only"];
    } else {
        [lines addObject:@"importTrace=disabled"];
    }
    [lines addObject:@"privacy=counts-and-fixed-stage-labels-only"];
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

NSURL *ATMWriteUnifiedReport(ATMEnvironment *environment, NSArray<ATMPackageRecord *> *packages, NSSet<NSString *> *selectedPackageIDs, NSError *scanError, NSError **error) {
    for (NSString *legacyName in @[@"AAZ-Restore-Report.txt", @"AAZ-Backup-Report.txt"]) [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:legacyName] error:nil];
    NSURL *url = [ATMApplicationSupportDirectory() URLByAppendingPathComponent:@"AAZ-Tweak-Manager-Report.txt"];
    BOOL written = [ATMUnifiedReportText(environment, packages, selectedPackageIDs, scanError) writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
    return written ? url : nil;
}

NSURL *ATMWriteDiagnosticReport(ATMEnvironment *environment, NSArray<ATMPackageRecord *> *packages, NSSet<NSString *> *selectedPackageIDs, NSError *scanError, NSError **error) {
    return ATMWriteUnifiedReport(environment, packages, selectedPackageIDs, scanError, error);
}

void ATMClearUnifiedReportState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ATMClearImportDiagnosticTrace();
    for (NSString *key in @[ATMLastBackupBuildKey, ATMLastBackupSummaryKey, ATMLastRestoreBuildKey, ATMLastRestoreSummaryKey, ATMLastRestoreCodeKey, ATMLastRestoreExitCodeKey]) [defaults removeObjectForKey:key];
    NSURL *directory = ATMApplicationSupportDirectory();
    for (NSString *name in @[@"AAZ-Tweak-Manager-Report.txt", @"AAZ-Tweak-Manager-Diagnostic.txt"]) [NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:name] error:nil];
    for (NSString *legacyName in @[@"AAZ-Restore-Report.txt", @"AAZ-Backup-Report.txt"]) [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:legacyName] error:nil];
}

@implementation ATMPersonalLedger
- (NSURL *)ledgerURL { return [ATMApplicationSupportDirectory() URLByAppendingPathComponent:@"personal-packages.json"]; }
- (NSURL *)historyURL { return [ATMApplicationSupportDirectory() URLByAppendingPathComponent:@"history.json"]; }
- (NSMutableDictionary *)loadLedger {
    NSData *data = [NSData dataWithContentsOfURL:self.ledgerURL];
    NSDictionary *dictionary = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [dictionary isKindOfClass:NSDictionary.class] ? [dictionary mutableCopy] : [NSMutableDictionary dictionary];
}
- (void)saveLedger:(NSDictionary *)ledger {
    NSData *data = [NSJSONSerialization dataWithJSONObject:ledger options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:self.ledgerURL options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}
- (NSSet<NSString *> *)selectedPackageIDs {
    NSDictionary *ledger = [self loadLedger];
    NSMutableSet *result = [NSMutableSet set];
    [ledger enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) { (void)stop; if ([entry[@"selected"] boolValue]) [result addObject:key]; }];
    return result;
}
- (void)seedIfNeededWithCandidates:(NSArray<ATMPackageRecord *> *)packages {
    NSMutableDictionary *ledger = [self loadLedger];
    BOOL changed = NO;
    for (ATMPackageRecord *record in packages) {
        if (!record.personalCandidate || ledger[record.packageID]) continue;
        ledger[record.packageID] = @{ @"selected": @YES, @"classification": @"inferred", @"firstSeen": ATMISODateString([NSDate date]) };
        changed = YES;
    }
    if (changed) [self saveLedger:ledger];
}
- (void)setSelected:(BOOL)selected packageID:(NSString *)packageID {
    if (!packageID.length) return;
    [self setSelected:selected forPackageIDs:@[packageID]];
}
- (void)setSelected:(BOOL)selected forPackageIDs:(NSArray<NSString *> *)packageIDs {
    if (!packageIDs.count) return;
    NSMutableDictionary *ledger = [self loadLedger];
    NSString *now = ATMISODateString([NSDate date]);
    for (NSString *packageID in packageIDs) {
        if (![packageID isKindOfClass:NSString.class] || !packageID.length) continue;
        NSMutableDictionary *entry = [ledger[packageID] mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"selected"] = @(selected);
        entry[@"classification"] = @"user-confirmed";
        if (!entry[@"firstSeen"]) entry[@"firstSeen"] = now;
        ledger[packageID] = entry;
    }
    [self saveLedger:ledger];
}
- (BOOL)isSelectedPackageID:(NSString *)packageID { return [[[self loadLedger] objectForKey:packageID][@"selected"] boolValue]; }
- (NSDate *)firstSeenDateForPackageID:(NSString *)packageID {
    NSString *stamp = [self loadLedger][packageID][@"firstSeen"];
    if (![stamp isKindOfClass:NSString.class]) return nil;
    static NSISO8601DateFormatter *formatter; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter dateFromString:stamp];
}
- (NSURL *)snapshotURL { return [ATMApplicationSupportDirectory() URLByAppendingPathComponent:@"installed-snapshot.json"]; }
- (void)reconcileInstalledPackages:(NSArray<ATMPackageRecord *> *)packages {
    NSData *oldData = [NSData dataWithContentsOfURL:self.snapshotURL];
    NSDictionary *old = oldData ? [NSJSONSerialization JSONObjectWithData:oldData options:0 error:nil] : nil;
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    for (ATMPackageRecord *record in packages) current[record.packageID] = record.version ?: @"";
    if ([old isKindOfClass:NSDictionary.class]) {
        [current enumerateKeysAndObjectsUsingBlock:^(NSString *packageID, NSString *version, BOOL *stop) {
            (void)stop; NSString *previous = old[packageID];
            if (!previous) [self recordEvent:@"package-detected-install" packageID:packageID details:@{ @"version": version, @"timeConfidence": @"first-seen" }];
            else if (![previous isEqualToString:version]) [self recordEvent:@"package-detected-update" packageID:packageID details:@{ @"from": previous, @"to": version, @"timeConfidence": @"first-seen" }];
        }];
        [old enumerateKeysAndObjectsUsingBlock:^(NSString *packageID, NSString *version, BOOL *stop) {
            (void)version; (void)stop;
            if (!current[packageID]) [self recordEvent:@"package-detected-remove" packageID:packageID details:@{ @"timeConfidence": @"first-seen" }];
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:current options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:self.snapshotURL options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}
- (void)recordEvent:(NSString *)event packageID:(NSString *)packageID details:(NSDictionary *)details {
    NSMutableArray *items = [[self history] mutableCopy];
    NSMutableDictionary *item = [@{ @"timestamp": ATMISODateString([NSDate date]), @"event": event ?: @"unknown" } mutableCopy];
    if (packageID.length) item[@"packageID"] = packageID;
    if (details.count) item[@"details"] = details;
    [items addObject:item];
    NSData *data = [NSJSONSerialization dataWithJSONObject:items options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:self.historyURL options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}
- (NSArray<NSDictionary *> *)history {
    NSData *data = [NSData dataWithContentsOfURL:self.historyURL];
    NSArray *items = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [items isKindOfClass:NSArray.class] ? items : @[];
}
- (BOOL)clearHistory:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:self.historyURL.path]) return YES;
    return [NSFileManager.defaultManager removeItemAtURL:self.historyURL error:error];
}
@end
