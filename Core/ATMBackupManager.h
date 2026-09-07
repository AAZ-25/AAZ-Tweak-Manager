#import <Foundation/Foundation.h>
#import "ATMCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface ATMBackupManager : NSObject
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment ledger:(ATMPersonalLedger *)ledger;
- (NSArray<NSURL *> *)availableBackups;
- (nullable NSURL *)createBackupWithPackages:(NSArray<ATMPackageRecord *> *)packages
                                      sources:(NSArray<ATMSourceRecord *> *)sources
                                        error:(NSError **)error;
- (nullable NSDictionary *)manifestForBackup:(NSURL *)backupURL error:(NSError **)error;
- (NSDictionary *)restorePreviewForBackup:(NSURL *)backupURL
                        installedPackages:(NSArray<ATMPackageRecord *> *)installed
                                    error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
