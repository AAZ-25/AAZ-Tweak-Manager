#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ATMZipWriter : NSObject
- (instancetype)initWithDestinationURL:(NSURL *)destinationURL error:(NSError **)error;
- (BOOL)addData:(NSData *)data path:(NSString *)path error:(NSError **)error;
- (BOOL)addFileURL:(NSURL *)fileURL path:(NSString *)path error:(NSError **)error;
- (BOOL)close:(NSError **)error;
@end

NSData * _Nullable ATMReadStoredZipEntry(NSURL *archiveURL, NSString *entryPath, NSError **error);

NS_ASSUME_NONNULL_END
