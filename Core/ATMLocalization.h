#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ATMLanguageDidChangeNotification;

NSString *ATMLanguageCode(void);
BOOL ATMIsArabicLanguage(void);
void ATMSetLanguageCode(NSString *languageCode);
NSLocale *ATMSelectedLocale(void);
NSString * _Nullable ATMLocalizedString(NSString * _Nullable text);
NSString *ATMLocalizedFormat(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *ATMLocalizedDateString(NSDate *date, NSDateFormatterStyle dateStyle, NSDateFormatterStyle timeStyle);
NSString *ATMLocalizedByteCountString(long long byteCount);
NSString *ATMBidiIsolatedString(id _Nullable value);
NSString *ATMLTRIsolatedString(id _Nullable value);
UISemanticContentAttribute ATMLanguageSemanticContentAttribute(void);
NSTextAlignment ATMLanguageTextAlignment(void);
void ATMApplyLanguageDirectionToView(UIView *view);
void ATMApplyLanguageDirectionToViewController(UIViewController *controller);
void ATMApplyLanguageDirectionToWindow(UIWindow *window);
void ATMInstallLocalization(void);

@interface NSString (ATMLocalization)
+ (instancetype)stringWithLocalizedFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@end

NS_ASSUME_NONNULL_END
