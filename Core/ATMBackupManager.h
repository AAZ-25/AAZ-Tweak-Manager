#import <Foundation/Foundation.h>
#import "ATMCore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ATMBackupErrorDomain;
typedef void (^ATMBackupProgressHandler)(NSString *stage, NSUInteger completed, NSUInteger total);
typedef NS_ENUM(NSInteger, ATMBackupErrorCode) {
    ATMBackupErrorPasswordRequired = 40,
    ATMBackupErrorWrongPassword = 41,
};

@interface ATMBackupManager : NSObject
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger;
- (NSArray<NSURL *> *)availableBackups;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources error:(NSError **)error;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages sources:(NSArray<ATMSourceRecord *> *)sources profileName:(nullable NSString *)profileName password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages
                                     sources:(NSArray<ATMSourceRecord *> *)sources
                                 profileName:(nullable NSString *)profileName
                                    password:(nullable NSString *)password
                            progressHandler:(nullable ATMBackupProgressHandler)progressHandler
                                       error:(NSError **)error;
- (nullable NSDictionary *)runBackupPreflight:(NSError **)error;
- (void)cancelCurrentBackup;
@property(nonatomic, copy, readonly, nullable) NSDictionary *lastBackupAttemptReport;
- (BOOL)isEncryptedBackup:(NSURL *)backupURL;
- (nullable NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error;
- (nullable NSDictionary *)manifestForBackup:(NSURL *)backupURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSDictionary *)backupReportForURL:(NSURL *)backupURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSURL *)stageImportFromURL:(NSURL *)sourceURL error:(NSError **)error;
- (void)discardStagedImportAtURL:(nullable NSURL *)stagedURL;
- (NSArray<NSURL *> *)pendingImportURLs;
- (BOOL)isPendingImportURL:(nullable NSURL *)url;
- (BOOL)isPendingPackagePayloadURL:(nullable NSURL *)url;
- (void)discardPendingImportAtURL:(nullable NSURL *)url;
- (nullable NSDictionary *)importPackagePayloadFromURL:(NSURL *)sourceURL error:(NSError **)error;
- (NSUInteger)verifiedPackageVaultCount;
- (NSUInteger)legacyRestoredSourceFileCount;
- (nullable NSDictionary *)quarantineLegacyRestoredSources:(NSError **)error;
- (nullable NSURL *)importBackupFromURL:(NSURL *)sourceURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSDictionary *)compareBackup:(NSURL *)olderURL withBackup:(NSURL *)newerURL error:(NSError **)error;
- (NSArray<NSDictionary *> *)savedProfiles;
- (BOOL)saveProfileNamed:(NSString *)name packageIDs:(NSSet<NSString *> *)packageIDs error:(NSError **)error;
- (BOOL)deleteProfileNamed:(NSString *)name error:(NSError **)error;
- (NSSet<NSString *> *)packageIDsForProfileNamed:(NSString *)name;
- (BOOL)isBackupPinned:(NSURL *)backupURL;
- (void)setBackup:(NSURL *)backupURL pinned:(BOOL)pinned;
- (nullable NSDictionary *)restoreReadinessForBackupURL:(NSURL *)backupURL
                                               password:(nullable NSString *)password
                                      installedPackages:(NSArray<ATMPackageRecord *> *)installed
                                                  error:(NSError **)error;
- (void)discardRestoreSession;
- (nullable NSDictionary *)executeRestoreForManifest:(NSDictionary *)manifest
                                         expectedPlan:(NSDictionary *)expectedPlan
                                                error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
