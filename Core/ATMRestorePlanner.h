#import <Foundation/Foundation.h>
#import "ATMCore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ATMRestorePlannerErrorDomain;

@interface ATMRestorePlanner : NSObject
- (instancetype)initWithEnvironment:(ATMEnvironment *)environment;
- (nullable NSDictionary *)planForManifest:(NSDictionary *)manifest
                          installedPackages:(NSArray<ATMPackageRecord *> *)installed
                                      error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
