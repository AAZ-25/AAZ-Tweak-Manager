#import <Foundation/Foundation.h>
#import "ATMCore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ATMBackupErrorDomain;
typedef NS_ENUM(NSInteger, ATMBackupErrorCode) {
    ATMBackupErrorPasswordRequired = 40,
    ATMBackupErrorWrongPassword = 41,
};

@interface ATMBackupManager : NSObject
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger;
- (NSArray<NSURL *> *)availableBackups;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages
                                      sources:(NSArray<ATMSourceRecord *> *)sources
                                        error:(NSError **)error;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages
                                      sources:(NSArray<ATMSourceRecord *> *)sources
                                  profileName:(nullable NSString *)profileName
                                     password:(nullable NSString *)password
                                        error:(NSError **)error;
- (BOOL)isEncryptedBackup:(NSURL *)backupURL;
- (nullable NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error;
- (nullable NSDictionary *)manifestForBackup:(NSURL *)backupURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSDictionary *)backupReportForURL:(NSURL *)backupURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSURL *)importBackupFromURL:(NSURL *)sourceURL password:(nullable NSString *)password error:(NSError **)error;
- (nullable NSDictionary *)compareBackup:(NSURL *)olderURL withBackup:(NSURL *)newerURL error:(NSError **)error;
- (NSArray<NSDictionary *> *)savedProfiles;
- (BOOL)saveProfileNamed:(NSString *)name packageIDs:(NSSet<NSString *> *)packageIDs error:(NSError **)error;
- (BOOL)deleteProfileNamed:(NSString *)name error:(NSError **)error;
- (NSSet<NSString *> *)packageIDsForProfileNamed:(NSString *)name;
- (BOOL)isBackupPinned:(NSURL *)backupURL;
- (void)setBackup:(NSURL *)backupURL pinned:(BOOL)pinned;
- (NSDictionary *)restorePreviewForBackup:(NSURL *)backupURL
                        installedPackages:(NSArray<ATMPackageRecord *> *)installed
                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
