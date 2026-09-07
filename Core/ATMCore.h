#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ATMInstallDateConfidence) {
    ATMInstallDateConfidenceUnknown = 0,
    ATMInstallDateConfidenceFirstSeen = 1,
    ATMInstallDateConfidenceLogExact = 2,
};

@interface ATMPackageRecord : NSObject
@property(nonatomic, copy) NSString *packageID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *architecture;
@property(nonatomic, copy) NSString *section;
@property(nonatomic, copy) NSString *priority;
@property(nonatomic, copy) NSString *sourceOrigin;
@property(nonatomic, copy) NSString *depends;
@property(nonatomic, assign) BOOL essential;
@property(nonatomic, assign) BOOL automaticallyInstalled;
@property(nonatomic, assign) BOOL personalCandidate;
@property(nonatomic, copy) NSString *classificationReason;
@property(nonatomic, strong, nullable) NSDate *installedAt;
@property(nonatomic, assign) ATMInstallDateConfidence dateConfidence;
- (NSDictionary *)manifestDictionary;
@end

@interface ATMSourceRecord : NSObject
@property(nonatomic, copy) NSString *relativePath;
@property(nonatomic, copy) NSString *sanitizedContents;
@property(nonatomic, assign) BOOL credentialsRedacted;
@property(nonatomic, assign) BOOL enabled;
- (NSDictionary *)manifestDictionary;
@end

@interface ATMEnvironment : NSObject
@property(nonatomic, copy, readonly) NSString *jailbreakRoot;
@property(nonatomic, copy, readonly) NSString *dpkgStatusPath;
@property(nonatomic, copy, readonly) NSString *aptStatePath;
@property(nonatomic, copy, readonly) NSString *aptCachePath;
@property(nonatomic, copy, readonly) NSString *dpkgLogPath;
@property(nonatomic, copy, readonly) NSArray<NSString *> *sourceRoots;
@property(nonatomic, assign, readonly) BOOL supportedRootless;
+ (instancetype)currentEnvironment;
- (NSString *)pathInsideRoot:(NSString *)path;
@end

@interface ATMPackageScanner : NSObject
@property(nonatomic, strong, readonly) ATMEnvironment *environment;
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment;
- (NSArray<ATMPackageRecord *> *)scanInstalledPackages:(NSError **)error;
- (NSArray<ATMSourceRecord *> *)scanSources:(NSError **)error;
@end

FOUNDATION_EXPORT NSURL * _Nullable ATMWriteDiagnosticReport(ATMEnvironment *environment,
                                                              NSArray<ATMPackageRecord *> *packages,
                                                              NSSet<NSString *> *selectedPackageIDs,
                                                              NSError * _Nullable scanError,
                                                              NSError **error);

@interface ATMPersonalLedger : NSObject
- (NSSet<NSString *> *)selectedPackageIDs;
- (void)seedIfNeededWithCandidates:(NSArray<ATMPackageRecord *> *)packages;
- (void)setSelected:(BOOL)selected packageID:(NSString *)packageID;
- (BOOL)isSelectedPackageID:(NSString *)packageID;
- (nullable NSDate *)firstSeenDateForPackageID:(NSString *)packageID;
- (void)reconcileInstalledPackages:(NSArray<ATMPackageRecord *> *)packages;
- (NSURL *)historyURL;
- (void)recordEvent:(NSString *)event packageID:(nullable NSString *)packageID details:(nullable NSDictionary *)details;
- (NSArray<NSDictionary *> *)history;
@end

NSString *ATMISODateString(NSDate *date);
NSString *ATMSHA256ForFile(NSURL *fileURL, NSError **error);
NSDictionary<NSString *, NSString *> *ATMParseDebianParagraph(NSString *paragraph);
NSArray<NSDictionary<NSString *, NSString *> *> *ATMParseDebianParagraphs(NSString *contents);

NS_ASSUME_NONNULL_END
