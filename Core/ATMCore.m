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
    NSArray *raw = [normalized componentsSeparatedByString:@"\n\n"];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *paragraph in raw) {
        if (![paragraph stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) continue;
        NSDictionary *fields = ATMParseDebianParagraph(paragraph);
        if (fields.count) [result addObject:fields];
    }
    return result;
}

@implementation ATMPackageRecord
- (NSDictionary *)manifestDictionary {
    return @{ @"packageID": self.packageID ?: @"", @"name": self.name ?: @"", @"version": self.version ?: @"",
              @"architecture": self.architecture ?: @"", @"section": self.section ?: @"", @"priority": self.priority ?: @"",
              @"origin": self.sourceOrigin ?: @"", @"depends": self.depends ?: @"", @"essential": @(self.essential),
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
    NSString *status = statusCandidates.firstObject ?: @"";
    for (NSString *candidate in statusCandidates) if ([fm isReadableFileAtPath:candidate]) { status = candidate; break; }
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

static NSSet<NSString *> *ATMProtectedPackages(void) {
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
    NSSet *protected = ATMProtectedPackages();
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *fields in ATMParseDebianParagraphs(statusText)) {
        if (![fields[@"Status"] isEqualToString:@"install ok installed"]) continue;
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
        record.depends = fields[@"Depends"] ?: @"";
        record.essential = [fields[@"Essential"] caseInsensitiveCompare:@"yes"] == NSOrderedSame;
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
    NSMutableDictionary *ledger = [self loadLedger];
    NSMutableDictionary *entry = [ledger[packageID] mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"selected"] = @(selected);
    entry[@"classification"] = @"user-confirmed";
    if (!entry[@"firstSeen"]) entry[@"firstSeen"] = ATMISODateString([NSDate date]);
    ledger[packageID] = entry;
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
@end
