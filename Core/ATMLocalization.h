#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ATMLanguageDidChangeNotification;

NSString *ATMLanguageCode(void);
BOOL ATMIsArabicLanguage(void);
void ATMSetLanguageCode(NSString *languageCode);
NSLocale *ATMSelectedLocale(void);
NSString * _Nullable ATMLocalizedString(NSString * _Nullable text);
NSString *ATMLocalizedFormat(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *ATMLocalizedDateString(NSDate *date, NSDateFormatterStyle dateStyle, NSDateFormatterStyle timeStyle);
NSString *ATMBidiIsolatedString(id _Nullable value);
NSString *ATMLTRIsolatedString(id _Nullable value);
void ATMInstallLocalization(void);

@interface NSString (ATMLocalization)
+ (instancetype)stringWithLocalizedFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@end

NS_ASSUME_NONNULL_END
