#import "ATMLocalization.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString *const ATMLanguageDidChangeNotification = @"ATMLanguageDidChangeNotification";
static NSString *const ATMLanguageDefaultsKey = @"ATMLanguage";
static NSString *const ATMAppGroup = @"group.com.aaz.tweakmanager";

static NSUserDefaults *ATMSharedDefaults(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:ATMAppGroup];
    return defaults ?: NSUserDefaults.standardUserDefaults;
}

NSString *ATMLanguageCode(void) {
    NSString *saved = [ATMSharedDefaults() stringForKey:ATMLanguageDefaultsKey];
    if ([saved isEqualToString:@"ar"] || [saved isEqualToString:@"en"]) return saved;
    NSString *preferred = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"en";
    return [preferred hasPrefix:@"ar"] ? @"ar" : @"en";
}

BOOL ATMIsArabicLanguage(void) { return [ATMLanguageCode() isEqualToString:@"ar"]; }

void ATMSetLanguageCode(NSString *languageCode) {
    NSString *normalized = [languageCode isEqualToString:@"ar"] ? @"ar" : @"en";
    [ATMSharedDefaults() setObject:normalized forKey:ATMLanguageDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ATMLanguageDidChangeNotification object:nil];
}

static NSDictionary<NSString *, NSString *> *ATMArabicStrings(void) {
    static NSDictionary<NSString *, NSString *> *strings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        strings = @{
            @"AAZ Tweak Manager": @"مدير تعديلات AAZ",
            @"My Tweaks": @"تعديلاتي",
            @"Backups": @"النسخ الاحتياطية",
            @"Sources": @"المصادر",
            @"Reports": @"التقارير",
            @"Settings": @"الإعدادات",
            @"Done": @"تم",
            @"OK": @"حسنًا",
            @"Cancel": @"إلغاء",
            @"Continue": @"متابعة",
            @"Delete": @"حذف",
            @"Rename": @"إعادة تسمية",
            @"Duplicate": @"نسخ",
            @"Repair": @"إصلاح",
            @"Unknown": @"غير معروف",
            @"Unknown error": @"خطأ غير معروف",
            @"Missing": @"مفقودة",
            @"Result": @"النتيجة",
            @"Free Storage": @"المساحة المتاحة",
            @"Already Installed": @"مثبتة مسبقًا",
            @"Version Updates": @"تحديثات الإصدارات",
            @"Date unknown": @"التاريخ غير معروف",
            @"Date Unknown": @"التاريخ غير معروف",
            @"Time unknown": @"الوقت غير معروف",
            @"Install record": @"سجل التثبيت",
            @"First seen": @"أول ظهور",
            @"Profile": @"ملف اختيار",
            @"Selection Profiles": @"ملفات الاختيار",
            @"No Saved Profiles": @"لا توجد ملفات محفوظة",
            @"Save a selection from My Tweaks to reuse it later.": @"احفظ اختيارك لاستخدامه لاحقًا.",
            @"Tap to manage. Swipe left to delete.": @"اضغط للإدارة، واسحب للحذف.",
            @"Choose an action for this selection profile.": @"اختر إجراءً لهذا الملف.",
            @"Load Profile": @"تحميل الملف",
            @"Profile Loaded": @"تم تحميل الملف",
            @"Rename Profile": @"إعادة تسمية الملف",
            @"The saved package selection will not change.": @"لن يتغير الاختيار المحفوظ.",
            @"Delete Profile?": @"حذف ملف الاختيار؟",
            @"This removes only the saved profile. Current selections and backup files will not change.": @"سيُحذف الملف المحفوظ فقط.",
            @"Profile not renamed": @"تعذرت إعادة التسمية",
            @"Profile not duplicated": @"تعذر نسخ الملف",
            @"%lu packages • Updated %@": @"%lu حزمة • حُدّث %@",
            @"%lu installed packages are now selected.": @"تم تحديد %lu حزمة مثبتة.",
            @"%@ Copy": @"نسخة %@",
            @"Use a profile name between 1 and 40 characters.": @"استخدم اسمًا من 1 إلى 40 حرفًا.",
            @"A profile with that name already exists.": @"يوجد ملف بهذا الاسم.",
            @"Save Current Profile": @"حفظ الاختيار",
            @"Save Selection Profile": @"حفظ ملف اختيار",
            @"Profiles stay private on this device and let you reuse a package selection.": @"يبقى الملف على هذا الجهاز لإعادة استخدام الاختيار.",
            @"Profile name": @"اسم الملف",
            @"Profile not saved": @"تعذر حفظ الملف",
            @"Select at least one package first.": @"اختر حزمة واحدة على الأقل.",
            @"Manage Profiles": @"إدارة الملفات",
            @"Search packages": @"البحث في الحزم",
            @"Select All": @"تحديد الكل",
            @"Unselect All": @"إلغاء تحديد الكل",
            @"Unselect All Shown?": @"إلغاء تحديد المعروض؟",
            @"Nothing selected": @"لا توجد حزم محددة",
            @"No matching packages": @"لا توجد نتائج",
            @"No personal packages inferred": @"لم تُكتشف حزم شخصية",
            @"Try another name or package identifier.": @"جرّب اسمًا أو معرّفًا آخر.",
            @"%lu personal • %lu installed": @"%lu شخصية • %lu مثبتة",
            @"%lu selected • %lu shown": @"%lu محددة • %lu معروضة",
            @"%lu installed packages were read. Turn on Show Excluded Packages in Settings to review the classification.": @"تمت قراءة %lu حزمة. فعّل الحزم المستبعدة لمراجعتها.",
            @"Bulk actions apply only to the packages currently shown. Changes are saved automatically.": @"تُطبق الإجراءات على الحزم المعروضة فقط.",
            @"Create Backup": @"إنشاء نسخة",
            @"Create Backup?": @"إنشاء نسخة احتياطية؟",
            @"Save %lu selected package%@ and %lu safe source%@? Missing package data will create a clearly marked limited backup.": @"حفظ %lu حزمة محددة%@ و%lu مصدر آمن%@؟ ستظهر النسخة المحدودة بوضوح عند نقص بيانات الحزم.",
            @"%lu selected package%@, required non-system dependencies, and %lu sanitized source%@ will be saved. The app automatically captures original DEBs or safely reconstructs unchanged installed packages. No manual DEB sharing is required. If any payload cannot be captured, the inventory backup is still created and clearly marked as limited.": @"سيُحفظ %lu من الحزم المحددة%@ و%lu من المصادر الآمنة%@. إذا تعذر حفظ بيانات حزمة فستُنشأ نسخة محدودة بوضوح.",
            @"Select at least one installed package before creating a backup.": @"اختر حزمة مثبتة واحدة على الأقل.",
            @"Encrypt Backup": @"تشفير النسخة",
            @"Create Encrypted Backup": @"إنشاء نسخة مشفرة",
            @"Password": @"كلمة المرور",
            @"Confirm password": @"تأكيد كلمة المرور",
            @"Passwords must match and contain at least 8 characters.": @"يجب أن تتطابق كلمتا المرور وألا تقل عن 8 أحرف.",
            @"Use at least 8 characters. AAZ Tweak Manager never stores or recovers this password.": @"استخدم 8 أحرف على الأقل. لا تُحفظ كلمة المرور.",
            @"Creating…": @"جارٍ الإنشاء…",
            @"Working…": @"جارٍ العمل…",
            @"%lu of %lu complete. You can cancel safely; temporary data will be removed.": @"اكتمل %lu من %lu. يمكنك الإلغاء بأمان.",
            @"Safe System Check": @"فحص الأمان",
            @"Checking the system before reading package data…": @"جارٍ فحص النظام قبل قراءة بيانات الحزم…",
            @"Running a synthetic end-to-end check before package data is touched…": @"جارٍ فحص الأمان قبل قراءة بيانات الحزم…",
            @"Backup": @"نسخ احتياطي",
            @"Backup Cancelled": @"أُلغي النسخ",
            @"Backup unavailable": @"النسخ غير متاح",
            @"No installed package inventory is available. An empty backup will not be created.": @"قائمة الحزم غير متاحة، ولن تُنشأ نسخة فارغة.",
            @"Password not accepted": @"كلمة المرور غير مقبولة",
            @"Encrypted Backup": @"نسخة مشفرة",
            @"Standard": @"عادية",
            @"Encrypted": @"مشفرة",
            @"Backup Failed": @"فشل النسخ",
            @"The operation did not complete.": @"لم تكتمل العملية.",
            @"Open Reports": @"فتح التقارير",
            @"Portable Backup Created": @"تم إنشاء نسخة محمولة",
            @"Backup Created: Limited Restore": @"تم إنشاء نسخة محدودة",
            @"Full offline Restore is available.": @"الاستعادة الكاملة متاحة دون اتصال.",
            @"%lu packages • %lu sources • %lu embedded DEBs\n%lu%% portable coverage • %@\n\n%@": @"%lu حزمة • %lu مصدر • %lu حزمة DEB مضمّنة\nتغطية محمولة %lu%% • %@\n\n%@",
            @"Inventory and sources were saved. %lu package payload%@ could not be captured, so full offline Restore stays blocked until a complete backup is created.": @"حُفظت القائمة والمصادر، لكن تعذر حفظ بيانات %lu حزمة%@؛ الاستعادة الكاملة غير متاحة.",
            @"Plan Ready": @"الخطة جاهزة",
            @"Check versions, protections, holds, and package-manager safety.": @"افحص الإصدارات وحواجز الأمان.",
            @"Needs Attention": @"تحتاج مراجعة",
            @"Check Restore Plan": @"فحص خطة الاستعادة",
            @"Readiness Check Passed": @"اجتاز فحص الجاهزية",
            @"Restore Check Unavailable": @"تعذر فحص الاستعادة",
            @"Inspection and readiness checks are read-only. No packages or sources are changed.": @"الفحص لا يغيّر الحزم أو المصادر.",
            @"BACKUP": @"النسخة",
            @"SAFETY GATES": @"حواجز الأمان",
            @"RESTORE PREVIEW": @"معاينة الاستعادة",
            @"Packages": @"الحزم",
            @"Exact Version": @"الإصدار مطابق",
            @"Different Version": @"إصدار مختلف",
            @"Newer Versions Kept": @"الإصدارات الأحدث محفوظة",
            @"Protected or Invalid": @"محمي أو غير صالح",
            @"Held": @"معلّق",
            @"Metadata Unavailable": @"البيانات غير متاحة",
            @"Checks Unavailable": @"الفحوص غير متاحة",
            @"Unexpected Actions": @"إجراءات غير متوقعة",
            @"Passed": @"ناجح",
            @"Not passed": @"غير ناجح",
            @"Embedded DEBs": @"حزم DEB المضمّنة",
            @"Repository Packages": @"حزم المستودعات",
            @"Packages to Install": @"حزم للتثبيت",
            @"Packages to Configure": @"حزم للإعداد",
            @"Packages to Remove": @"حزم للحذف",
            @"Sources to Restore": @"مصادر للاستعادة",
            @"Private Sources Skipped": @"مصادر خاصة تم تجاوزها",
            @"No changes yet. Restore requires a separate final confirmation and an immediate safety recheck.": @"لم يحدث أي تغيير. الاستعادة تحتاج تأكيدًا نهائيًا وفحصًا جديدًا.",
            @"Preview only. No packages or sources were changed.": @"معاينة فقط؛ لم تتغير الحزم أو المصادر.",
            @"Backup Details": @"تفاصيل النسخة",
            @"Portable Backup Verified": @"النسخة المحمولة سليمة",
            @"Backup Not Portable": @"النسخة غير محمولة",
            @"Backup File": @"ملف النسخة",
            @"Privacy-Safe Report": @"تقرير آمن للخصوصية",
            @"Share": @"مشاركة",
            @"Choose the backup file or one privacy-safe full report.": @"اختر ملف النسخة أو التقرير الآمن.",
            @"Integrity passed with a verified original or safely repacked DEB for every package.": @"تم التحقق من بيانات جميع الحزم.",
            @"Inventory and sources are safe, but full offline Restore needs every package payload. Review the count-only capture checks below.": @"القائمة والمصادر سليمة، لكن الاستعادة الكاملة تحتاج بيانات كل الحزم.",
            @"Only a verified Portable Backup with 100% DEB coverage can be checked.": @"يتطلب الفحص نسخة محمولة بتغطية كاملة.",
            @"Compare with Next Backup": @"مقارنة بالنسخة التالية",
            @"See aggregate changes between these backups.": @"عرض ملخص التغييرات بين النسختين.",
            @"Archive Size": @"حجم الأرشيف",
            @"Portable Coverage": @"التغطية المحمولة",
            @"Safely Repacked": @"أعيد تغليفها بأمان",
            @"Restorable Sources": @"مصادر قابلة للاستعادة",
            @"Payload Unavailable": @"بيانات الحزم غير متاحة",
            @"Inventory or File Missing": @"القائمة أو الملف مفقود",
            @"Package Build Failure": @"فشل إنشاء الحزمة",
            @"Privacy or Verification Block": @"حظر خصوصية أو تحقق",
            @"Tool or Archive Failure Events": @"أخطاء الأدوات أو الأرشيف",
            @"CAPTURE CHECKS (COUNTS ONLY)": @"فحوص الالتقاط (أعداد فقط)",
            @"Import Backup": @"استيراد نسخة",
            @"Import securely through the Files share sheet.": @"استورد بأمان من تطبيق الملفات.",
            @"In Files, Share → Save to AAZ Tweak Manager": @"من الملفات: مشاركة ← حفظ في AAZ",
            @"No Backups Yet": @"لا توجد نسخ احتياطية",
            @"No Matching Backups": @"لا توجد نتائج",
            @"%lu backup%@ shown": @"%lu نسخة معروضة%@",
            @"%@Backup — %@": @"%@نسخة — %@",
            @"Pinned • ": @"مثبتة • ",
            @"Encrypted • %@ • Tap to unlock": @"مشفرة • %@ • اضغط للفتح",
            @"Corrupted or unsupported • %@": @"تالفة أو غير مدعومة • %@",
            @"%@%lu packages • %lu sources • %@ • Tap to verify": @"%@%lu حزمة • %lu مصدر • %@ • اضغط للفحص",
            @"Create a backup or import an existing .aaztmbackup file.": @"أنشئ نسخة أو استورد ملف .aaztmbackup.",
            @"Try another search.": @"جرّب بحثًا آخر.",
            @"Tap a backup to verify it and check restore readiness.": @"اضغط على نسخة لفحصها وخطة استعادتها.",
            @"Search backups": @"البحث في النسخ",
            @"Sort Backups": @"ترتيب النسخ",
            @"Unlock Backup": @"فتح النسخة",
            @"The password is used only for this operation and is never stored.": @"تُستخدم كلمة المرور لهذه العملية فقط ولا تُحفظ.",
            @"Inspecting Backup": @"فحص النسخة",
            @"Checking archive structure, CRC values, and cached-DEB hashes…": @"جارٍ التحقق من الأرشيف والحزم…",
            @"Backup could not be inspected": @"تعذر فحص النسخة",
            @"Checking Restore Plan": @"فحص خطة الاستعادة",
            @"Checking versions, protections, holds, and package-manager safety…": @"جارٍ فحص الإصدارات وحواجز الأمان…",
            @"Restore plan unavailable": @"خطة الاستعادة غير متاحة",
            @"Final Restore Confirmation": @"تأكيد الاستعادة",
            @"Run %@ approved package action(s) using %@ and restore %@ safe source file(s)? The plan will be checked again before changes begin.": @"تنفيذ %@ إجراء حزمة معتمد باستخدام %@ واستعادة %@ ملف مصدر آمن؟ ستُفحص الخطة مرة أخرى قبل البدء.",
            @"Run %@ approved package action(s) using %@, then restore %@ sanitized public source file(s)?\n\nThe plan will be rechecked immediately. Restore stops on drift, removal, downgrade, holds, protected packages, unexpected dependencies, or unsafe source data. Private repository credentials are never restored.": @"تنفيذ %@ إجراء حزمة معتمد ثم استعادة %@ من المصادر العامة الآمنة؟\n\nستُفحص الخطة مرة أخرى، وستتوقف عند أي تغيير أو إجراء غير آمن.",
            @"Restore Now": @"استعادة الآن",
            @"Restoring Backup": @"استعادة النسخة",
            @"Rechecking the plan, then restoring approved packages and sources…": @"جارٍ إعادة فحص الخطة ثم استعادة الحزم والمصادر المعتمدة…",
            @"Rechecking the approved plan, installing packages without removals or downgrades, then restoring sanitized public sources…": @"جارٍ إعادة الفحص ثم الاستعادة الآمنة…",
            @"Restore did not start": @"لم تبدأ الاستعادة",
            @"Restore Completed": @"اكتملت الاستعادة",
            @"Restore Needs Attention": @"الاستعادة تحتاج مراجعة",
            @"Restore stopped.": @"توقفت الاستعادة.",
            @"Not run": @"لم يعمل",
            @"Backup Changes": @"تغييرات النسخ",
            @"Added: %@\nRemoved: %@\nUpdated: %@\nUnchanged: %@": @"مضافة: %@\nمحذوفة: %@\nمحدثة: %@\nدون تغيير: %@",
            @"Comparison unavailable": @"المقارنة غير متاحة",
            @"Import from Files": @"الاستيراد من الملفات",
            @"In Files, share an AAZ backup or DEB to AAZ Tweak Manager. Every file is checked before it is saved.": @"من تطبيق الملفات، شارك نسخة AAZ أو حزمة DEB إلى التطبيق. يُفحص كل ملف قبل حفظه.",
            @"Verifying Package DEB": @"فحص حزمة DEB",
            @"Checking the package before saving it locally…": @"جارٍ فحص الحزمة قبل حفظها محليًا…",
            @"Package DEB Saved": @"تم حفظ حزمة DEB",
            @"The package passed every safety check and was saved only in the local Package Vault. Verified vault packages: %lu.": @"اجتازت الحزمة الفحوص وحُفظت محليًا. الحزم الموثقة: %lu.",
            @"Package DEB not saved": @"لم تُحفظ حزمة DEB",
            @"Importing Backup": @"استيراد النسخة",
            @"Preparing the selected file…": @"جارٍ تجهيز الملف…",
            @"Import could not start": @"تعذر بدء الاستيراد",
            @"Import Encrypted Backup": @"استيراد نسخة مشفرة",
            @"The password is used only for this import and is never stored.": @"تُستخدم كلمة المرور للاستيراد فقط ولا تُحفظ.",
            @"Inspecting Import": @"فحص الاستيراد",
            @"Checking format, archive integrity, and cached-DEB hashes before adding it.": @"جارٍ التحقق من الملف قبل إضافته.",
            @"Already Imported": @"مستوردة مسبقًا",
            @"Import failed": @"فشل الاستيراد",
            @"Backup Imported": @"تم استيراد النسخة",
            @"The archive passed health and integrity checks. No restore action was executed.": @"اجتاز الملف فحوص السلامة. لم تُنفذ استعادة.",
            @"Pin": @"تثبيت",
            @"Unpin": @"إلغاء التثبيت",
            @"Delete Backup?": @"حذف النسخة؟",
            @"This permanently removes this backup from the device. Other backups and selections are unchanged.": @"سيُحذف هذا الملف نهائيًا من الجهاز.",
            @"Delete failed": @"فشل الحذف",
            @"No Sources Found": @"لا توجد مصادر",
            @"Legacy AAZ-restored Source files are active and may override package-manager deletions. Use Settings > Troubleshooting > Repair Legacy Restored Sources.": @"توجد ملفات مصادر قديمة قد تعيد المصادر المحذوفة. أصلحها من الإعدادات.",
            @"Add a repository in Sileo or Zebra, then refresh this screen.": @"أضف مستودعًا في Sileo أو Zebra ثم حدّث الصفحة.",
            @"Repository Source": @"مصدر مستودع",
            @"%lu SOURCE%@": @"%lu مصدر%@",
            @"%@ • Private credentials removed from backups": @"%@ • حُذفت بيانات الدخول الخاصة",
            @"Enabled": @"مفعّل",
            @"Disabled": @"معطّل",
            @"Private credentials are removed before a source is added to a backup.": @"تُحذف بيانات الدخول الخاصة قبل النسخ.",
            @"Clear History": @"مسح السجل",
            @"Clear History?": @"مسح السجل؟",
            @"This removes the local activity timeline. Your package selections and backup files will not be changed.": @"سيُمسح سجل النشاط فقط.",
            @"History could not be cleared": @"تعذر مسح السجل",
            @"All": @"الكل",
            @"Overall": @"الحالة العامة",
            @"Import": @"الاستيراد",
            @"Restore": @"الاستعادة",
            @"Share Report": @"مشاركة التقرير",
            @"Copy Report": @"نسخ التقرير",
            @"Clear Report State": @"مسح حالة التقرير",
            @"No current result": @"لا توجد نتيجة حالية",
            @"Share the single current-build report": @"مشاركة التقرير الحالي",
            @"Copy the same report text": @"نسخ التقرير نفسه",
            @"Clears report results only": @"يمسح نتائج التقرير فقط",
            @"No Activity Yet": @"لا يوجد نشاط",
            @"Package, backup, import, and restore activity appears here.": @"يظهر نشاط الحزم والنسخ والاستعادة هنا.",
            @"Activity": @"النشاط",
            @"CURRENT BUILD REPORT": @"تقرير البناء الحالي",
            @"ON THIS DEVICE": @"على هذا الجهاز",
            @"Today": @"اليوم",
            @"Yesterday": @"أمس",
            @"Package Selected": @"تم تحديد الحزمة",
            @"Package Unselected": @"أُلغي تحديد الحزمة",
            @"Selection Updated": @"تم تحديث الاختيار",
            @"%@ shown packages included": @"أُضيفت %@ حزمة معروضة",
            @"%@ shown packages removed": @"أُزيلت %@ حزمة معروضة",
            @"Updated from %@ to %@": @"حُدّثت من %@ إلى %@",
            @"%@ packages • %@ sources • %@ cached DEBs": @"%@ حزمة • %@ مصدر • %@ حزمة DEB",
            @"%@ packages • %@ sources • integrity verified": @"%@ حزمة • %@ مصدر • تم التحقق",
            @"%@ packages stored in the profile": @"حُفظت %@ حزمة في الملف",
            @"%@ installed packages selected": @"تم تحديد %@ حزمة مثبتة",
            @"%@ packages copied to a new profile": @"نُسخت %@ حزمة إلى ملف جديد",
            @"%@ package actions completed • final check passed": @"اكتمل %@ إجراء • اجتاز الفحص النهائي",
            @"%@ completed • %@ remaining • %@": @"%@ مكتملة • %@ متبقية • %@",
            @"Package Detected": @"تم اكتشاف حزمة",
            @"Included in the next backup": @"مضمّنة في النسخة القادمة",
            @"Removed from the next backup": @"أُزيلت من النسخة القادمة",
            @"New installed package found": @"تم العثور على حزمة جديدة",
            @"No longer installed": @"لم تعد مثبتة",
            @"Removed from this device": @"أُزيلت من هذا الجهاز",
            @"Current package selections were not changed": @"لم تتغير اختيارات الحزم الحالية",
            @"The saved package selection was preserved": @"تم الحفاظ على الاختيار المحفوظ",
            @"Package Updated": @"تم تحديث الحزمة",
            @"Package Removed": @"تمت إزالة الحزمة",
            @"Backup Created": @"تم إنشاء النسخة",
            @"Backup Deleted": @"تم حذف النسخة",
            @"Selection Profile Saved": @"تم حفظ ملف الاختيار",
            @"Selection Profile Loaded": @"تم تحميل ملف الاختيار",
            @"Selection Profile Deleted": @"تم حذف ملف الاختيار",
            @"Selection Profile Renamed": @"تمت إعادة تسمية الملف",
            @"Selection Profile Duplicated": @"تم نسخ ملف الاختيار",
            @"Restore Stopped": @"توقفت الاستعادة",
            @"Report unavailable": @"التقرير غير متاح",
            @"Report Copied": @"تم نسخ التقرير",
            @"One private report for the current build. It excludes names, paths, passwords, and file contents.": @"تقرير خاص واحد للبناء الحالي، دون أسماء أو مسارات أو كلمات مرور أو محتوى ملفات.",
            @"Clearing reports or activity does not delete backups or selections.": @"مسح التقارير أو النشاط لا يحذف النسخ أو الاختيارات.",
            @"The same privacy-safe report is now on the clipboard.": @"تم نسخ التقرير الآمن.",
            @"Clear Report State?": @"مسح حالة التقرير؟",
            @"This clears current Backup, Import, and Restore report results. Backups, Package Vault items, selections, sources, and activity history are not deleted.": @"سيُمسح التقرير الحالي فقط، دون حذف أي نسخة أو اختيار.",
            @"Language": @"اللغة",
            @"English": @"English",
            @"Arabic": @"العربية",
            @"Choose Language": @"اختر اللغة",
            @"Package List": @"قائمة الحزم",
            @"Shown Packages": @"الحزم المعروضة",
            @"Package database unavailable": @"قاعدة الحزم غير متاحة",
            @"Rootless package database unavailable": @"قاعدة حزم Rootless غير متاحة",
            @"Profile unavailable": @"ملف الاختيار غير متاح",
            @"Not Started": @"لم تبدأ",
            @"This will remove %lu shown packages from the next backup. You can select them again at any time.": @"سيُزال %lu من الحزم المعروضة من النسخة القادمة. يمكنك تحديدها مجددًا.",
            @"no package changes": @"دون تغييرات على الحزم",
            @"verified DEBs embedded in this backup": @"حزم DEB موثقة داخل النسخة",
            @"authenticated repositories": @"مستودعات موثقة",
            @"an earlier version": @"إصدار أقدم",
            @"a newer version": @"إصدار أحدث",
            @"%@\n\nRestore code: %@\nPackage-manager exit: %@\nRequested: %@\nCompleted: %@\nRemaining: %@\nFinal verification: %@\nPackages removed: 0\nSources restored: %@\nPrivate sources skipped: %@": @"%@\n\nرمز الاستعادة: %@\nخروج مدير الحزم: %@\nالمطلوب: %@\nالمكتمل: %@\nالمتبقي: %@\nالفحص النهائي: %@\nالحزم المحذوفة: 0\nالمصادر المستعادة: %@\nالمصادر الخاصة المتجاوزة: %@",
            @"Protection": @"الحماية",
            @"Troubleshooting": @"استكشاف الأخطاء",
            @"About": @"حول",
            @"Show Excluded Packages": @"إظهار الحزم المستبعدة",
            @"Show system and dependency packages.": @"يعرض حزم النظام والاعتماديات.",
            @"Manage Selection Profiles": @"إدارة ملفات الاختيار",
            @"%lu saved profile%@": @"%lu ملف محفوظ%@",
            @"Rootless Compatible": @"متوافق مع Rootless",
            @"Private by Design": @"خصوصية مدمجة",
            @"Guarded Restore": @"استعادة محمية",
            @"Uses the Rootless package database.": @"يستخدم قاعدة حزم Rootless.",
            @"Passwords and repository credentials never enter backups.": @"لا تدخل كلمات المرور وبيانات المستودعات في النسخ.",
            @"Rechecks every approved plan and refuses removals, downgrades, or source changes.": @"يعيد فحص الخطة ويرفض الحذف أو الرجوع لإصدار أقدم.",
            @"Import Troubleshooting": @"تشخيص الاستيراد",
            @"Enable only while troubleshooting an import.": @"فعّله فقط عند تشخيص مشكلة استيراد.",
            @"On — the next report includes safe progress stages.": @"مفعّل — سيشمل التقرير مراحل آمنة.",
            @"Off — recommended for normal use.": @"متوقف — مناسب للاستخدام العادي.",
            @"Repair Legacy Restored Sources": @"إصلاح المصادر القديمة",
            @"Quarantine %lu old AAZ source file%@ so package managers can control their own Sources again.": @"عزل %lu من ملفات المصادر القديمة%@ لاستعادة تحكم مدير الحزم.",
            @"Move %lu legacy AAZ source file%@ into a disabled recovery folder? No backup is deleted. Close and reopen Sileo afterward.": @"نقل %lu من ملفات المصادر القديمة%@ إلى مجلد استرداد معطل؟ لن تُحذف أي نسخة.",
            @"%@ legacy source file(s) were moved to a disabled recovery folder. Close and reopen Sileo before changing Sources.": @"نُقل %@ من ملفات المصادر القديمة. أعد فتح Sileo قبل تعديل المصادر.",
            @"Repair Legacy Sources?": @"إصلاح المصادر القديمة؟",
            @"Repair stopped": @"توقف الإصلاح",
            @"Legacy Sources Repaired": @"تم إصلاح المصادر القديمة",
            @"Developer on X": @"المطور على X",
            @"Version %@ — Build %@": @"الإصدار %@ — البناء %@",
            @"The package database was found, but no installed package records could be decoded.": @"تعذر قراءة سجلات الحزم المثبتة.",
            @"The rootless dpkg database is unavailable.": @"قاعدة حزم Rootless غير متاحة.",
            @"Unable to read package file.": @"تعذرت قراءة ملف الحزمة.",
            @"A legacy restored Source could not be moved safely. Files already quarantined were kept for recovery.": @"تعذر نقل مصدر قديم بأمان. حُفظت الملفات المنقولة للاسترداد.",
            @"A restorable source payload failed its integrity or privacy validation.": @"فشل مصدر قابل للاستعادة في فحص السلامة أو الخصوصية.",
            @"Backup cancelled. Temporary data was removed and no backup was created.": @"أُلغي النسخ وحُذفت البيانات المؤقتة.",
            @"Backup cancelled. Temporary data was removed and no package or source data was changed.": @"أُلغي النسخ دون تغيير الحزم أو المصادر.",
            @"Backup encryption could not be completed.": @"تعذر تشفير النسخة.",
            @"Backup payload verification failed.": @"فشل التحقق من بيانات النسخة.",
            @"Encrypted backup verification failed.": @"فشل التحقق من النسخة المشفرة.",
            @"Enter a profile name and select at least one package.": @"أدخل اسمًا واختر حزمة واحدة على الأقل.",
            @"No backup file was selected.": @"لم يتم اختيار ملف نسخة.",
            @"No personal packages are selected.": @"لا توجد حزم شخصية محددة.",
            @"Password key derivation failed.": @"تعذر تجهيز مفتاح كلمة المرور.",
            @"Safe system check failed at preflight-workspace. No package or source data was changed.": @"فشل فحص النظام دون تغيير الحزم أو المصادر.",
            @"Secure random data is unavailable.": @"البيانات العشوائية الآمنة غير متاحة.",
            @"Select a backup file, not a folder.": @"اختر ملف نسخة، وليس مجلدًا.",
            @"The backup archive could not be validated and was not imported.": @"تعذر التحقق من النسخة ولم تُستورد.",
            @"The backup archive could not be validated.": @"تعذر التحقق من النسخة.",
            @"The backup failed payload integrity validation and was not imported.": @"فشلت بيانات النسخة في فحص السلامة ولم تُستورد.",
            @"The backup storage folder is unavailable.": @"مجلد حفظ النسخ غير متاح.",
            @"The embedded package payload limit was exceeded.": @"تجاوزت بيانات الحزم الحد المسموح.",
            @"The encrypted backup header is invalid.": @"رأس النسخة المشفرة غير صالح.",
            @"The installed dependency closure is too large or could not be verified.": @"الاعتماديات كثيرة جدًا أو تعذر التحقق منها.",
            @"The legacy Source quarantine could not be prepared.": @"تعذر تجهيز عزل المصادر القديمة.",
            @"The legacy Source quarantine did not pass its directory safety check.": @"فشل مجلد عزل المصادر القديمة في فحص الأمان.",
            @"The password is incorrect or the encrypted backup was changed.": @"كلمة المرور غير صحيحة أو تغيّرت النسخة.",
            @"The sanitized source state changed after confirmation. Run the readiness check again.": @"تغيرت حالة المصادر بعد التأكيد. افحص الخطة مجددًا.",
            @"The selected backup file is empty.": @"ملف النسخة المحدد فارغ.",
            @"The verified Restore session expired. Run the readiness check again.": @"انتهت جلسة الاستعادة الموثقة. افحص الخطة مجددًا.",
            @"The verified backup could not be added to local storage.": @"تعذر حفظ النسخة الموثقة محليًا.",
            @"The verified package could not be saved to the local package vault.": @"تعذر حفظ الحزمة الموثقة محليًا.",
            @"This backup is already in your Backups list.": @"هذه النسخة موجودة مسبقًا.",
            @"This backup is encrypted. Enter its password to inspect it.": @"هذه النسخة مشفرة. أدخل كلمة المرور لفحصها.",
            @"This file is not a supported, safe Rootless package DEB.": @"ملف DEB هذا غير مدعوم أو غير آمن لـRootless.",
            @"Unsupported or invalid backup.": @"النسخة غير صالحة أو غير مدعومة.",
            @"Unsupported or invalid encrypted backup.": @"النسخة المشفرة غير صالحة أو غير مدعومة.",
            @"Use a password with at least 8 characters.": @"استخدم كلمة مرور من 8 أحرف على الأقل.",
            @"Unable to create backup archive.": @"تعذر إنشاء أرشيف النسخة.",
            @"Invalid backup entry.": @"عنصر النسخة غير صالح.",
            @"Unable to write backup entry.": @"تعذرت كتابة عنصر النسخة.",
            @"Unable to verify package file.": @"تعذر التحقق من ملف الحزمة.",
            @"Unable to write package header.": @"تعذرت كتابة رأس الحزمة.",
            @"Unable to copy package file.": @"تعذر نسخ ملف الحزمة.",
            @"Unable to finalize backup archive.": @"تعذر إنهاء أرشيف النسخة.",
            @"Compressed backup entries are not supported.": @"عناصر النسخة المضغوطة غير مدعومة.",
            @"Backup manifest is missing.": @"بيان النسخة مفقود.",
            @"The backup archive entry checksum is invalid.": @"بصمة أحد عناصر النسخة غير صالحة.",
            @"The backup archive is incomplete or corrupted.": @"النسخة ناقصة أو تالفة.",
            @"The backup archive footer is invalid.": @"نهاية أرشيف النسخة غير صالحة.",
            @"The backup archive index does not match its contents.": @"فهرس النسخة لا يطابق محتواها.",
            @"The backup archive index is incomplete.": @"فهرس النسخة غير مكتمل.",
            @"This backup does not match the supported Rootless target.": @"هذه النسخة لا تطابق بيئة Rootless المدعومة.",
            @"The backup package list is invalid.": @"قائمة حزم النسخة غير صالحة.",
            @"This plan is not approved for execution.": @"هذه الخطة غير معتمدة للتنفيذ.",
            @"Installed packages could not be rechecked immediately before Restore.": @"تعذرت إعادة فحص الحزم قبل الاستعادة.",
            @"The Restore plan no longer passes every safety check.": @"لم تعد خطة الاستعادة تجتاز فحوص الأمان.",
            @"The Restore plan changed after confirmation. Run the readiness check again.": @"تغيرت خطة الاستعادة بعد التأكيد. افحصها مجددًا.",
            @"The approved package-manager action is unavailable.": @"إجراء مدير الحزم المعتمد غير متاح.",
            @"Preparing file…": @"جارٍ تجهيز الملف…",
            @"Backup saved. Open AAZ Tweak Manager to verify and import it.": @"تم حفظ النسخة. افتح AAZ لفحصها واستيرادها.",
            @"Package saved. Open AAZ Tweak Manager to verify it for Portable Backup.": @"تم حفظ الحزمة. افتح AAZ لفحصها.",
            @"Could not prepare this file.": @"تعذر تجهيز الملف."
        };
    });
    return strings;
}

NSString *ATMLocalizedString(NSString *text) {
    if (!text || !text.length || !ATMIsArabicLanguage()) return text;
    return ATMArabicStrings()[text] ?: text;
}

NSString *ATMLocalizedFormat(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *localizedFormat = ATMLocalizedString(format) ?: format;
    NSString *result = [[NSString alloc] initWithFormat:localizedFormat arguments:arguments];
    va_end(arguments);
    return result;
}

@implementation NSString (ATMLocalization)
+ (instancetype)stringWithLocalizedFormat:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *localizedFormat = ATMLocalizedString(format) ?: format;
    NSString *result = [[NSString alloc] initWithFormat:localizedFormat arguments:arguments];
    va_end(arguments);
    return result;
}
@end

static void ATMSwap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

static void ATMSwapClass(Class cls, SEL original, SEL replacement) {
    Method a = class_getClassMethod(cls, original);
    Method b = class_getClassMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

@interface UIAlertController (ATMLocalization)
+ (instancetype)atm_alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style;
@end
@implementation UIAlertController (ATMLocalization)
+ (instancetype)atm_alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style {
    return [self atm_alertControllerWithTitle:ATMLocalizedString(title) message:ATMLocalizedString(message) preferredStyle:style];
}
@end

@interface UIAlertAction (ATMLocalization)
+ (instancetype)atm_actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^ _Nullable)(UIAlertAction *action))handler;
@end
@implementation UIAlertAction (ATMLocalization)
+ (instancetype)atm_actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^ _Nullable)(UIAlertAction *action))handler {
    return [self atm_actionWithTitle:ATMLocalizedString(title) style:style handler:handler];
}
@end

@interface UIViewController (ATMLocalization)
- (void)atm_setTitle:(NSString *)title;
@end
@implementation UIViewController (ATMLocalization)
- (void)atm_setTitle:(NSString *)title { [self atm_setTitle:ATMLocalizedString(title)]; }
@end

@interface UILabel (ATMLocalization)
- (void)atm_setText:(NSString *)text;
@end
@implementation UILabel (ATMLocalization)
- (void)atm_setText:(NSString *)text { [self atm_setText:ATMLocalizedString(text)]; }
@end

@interface UITextField (ATMLocalization)
- (void)atm_setPlaceholder:(NSString *)placeholder;
@end
@implementation UITextField (ATMLocalization)
- (void)atm_setPlaceholder:(NSString *)placeholder { [self atm_setPlaceholder:ATMLocalizedString(placeholder)]; }
@end

@interface UIButton (ATMLocalization)
- (void)atm_setTitle:(NSString *)title forState:(UIControlState)state;
@end
@implementation UIButton (ATMLocalization)
- (void)atm_setTitle:(NSString *)title forState:(UIControlState)state { [self atm_setTitle:ATMLocalizedString(title) forState:state]; }
@end

@interface UINavigationItem (ATMLocalization)
- (void)atm_setPrompt:(NSString *)prompt;
@end
@implementation UINavigationItem (ATMLocalization)
- (void)atm_setPrompt:(NSString *)prompt { [self atm_setPrompt:ATMLocalizedString(prompt)]; }
@end

void ATMInstallLocalization(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ATMSwap(UIViewController.class, @selector(setTitle:), @selector(atm_setTitle:));
        ATMSwap(UILabel.class, @selector(setText:), @selector(atm_setText:));
        ATMSwap(UITextField.class, @selector(setPlaceholder:), @selector(atm_setPlaceholder:));
        ATMSwap(UIButton.class, @selector(setTitle:forState:), @selector(atm_setTitle:forState:));
        ATMSwap(UINavigationItem.class, @selector(setPrompt:), @selector(atm_setPrompt:));
        ATMSwapClass(UIAlertController.class, @selector(alertControllerWithTitle:message:preferredStyle:), @selector(atm_alertControllerWithTitle:message:preferredStyle:));
        ATMSwapClass(UIAlertAction.class, @selector(actionWithTitle:style:handler:), @selector(atm_actionWithTitle:style:handler:));
    });
}
