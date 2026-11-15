#import "OITIReport.h"
#import "OITIReportText.h"
#import "OITIBaseListController.h"
#import "../OITIDeviceProfiles.h"
#import <OITCore/OITCore.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <stdio.h>
#import <objc/runtime.h>

static NSString * const kOITIReportLogPath = @"/tmp/OITIDebug.log";             // the tweak's log (SpringBoard and the other processes)
static NSString * const kOITIReportLogPath1 = @"/tmp/OITIDebug.log.1";          // its rotated copy
static NSString * const kOITIReportPrefsLogPath = @"/tmp/OITIPrefsDebug.log";   // this bundle's log (OITIRootListController.m)
static NSString * const kOITIReportDomain = @"com.wilburt.oiti.prefs";
// Keep in sync with OITIRootListController.m (the MobileGestalt cache) and OITIStatusBarProvider.xm (the native provider record).
static NSString * const kOITIReportGestaltPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString * const kOITIReportNativeProviderPath = @"/var/mobile/Library/Preferences/OITINativeProvider.plist";

#define OITI_REPORT_CLIPBOARD_LIMIT 60000   // characters; a GitHub comment holds 65,536

// The end of a file (at most maxBytes). *partial is YES when the file is longer, so the first line may be cut.
static NSData *OITIReportReadTail(NSString *path, size_t maxBytes, BOOL *partial, NSString **info) {
    *partial = NO;
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) { if (info) *info = [NSString stringWithFormat:@"%@: not readable (does not exist yet, or no permission)", path]; return nil; }
    struct stat st;
    if (fstat(fileno(file), &st) != 0) { fclose(file); if (info) *info = [NSString stringWithFormat:@"%@: cannot be read", path]; return nil; }
    off_t size = st.st_size;
    off_t offset = size > (off_t)maxBytes ? size - (off_t)maxBytes : 0;
    if (offset > 0) { *partial = YES; fseeko(file, offset, SEEK_SET); }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(size - offset)];
    size_t got = data.length ? fread(data.mutableBytes, 1, data.length, file) : 0;
    fclose(file);
    data.length = got;
    if (info) *info = [NSString stringWithFormat:@"%@: %lld bytes, modified %@", path, (long long)size, [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)st.st_mtime]];
    return data;
}

static NSString *OITIReportStringFromBytes(const char *bytes, size_t length) {
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return text ?: [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];   // never fails
}

static NSString *OITIReportLogSection(NSString *path, size_t readBytes, unsigned keyLines, unsigned tailLines, size_t outBytes, NSString **info, NSString **latestSession) {
    BOOL partial = NO;
    NSData *data = OITIReportReadTail(path, readBytes, &partial, info);
    if (!data) return @"(the log could not be read)\n";
    char *buffer = (char *)malloc(outBytes + 1);
    if (!buffer) return @"(out of memory)\n";
    size_t length = OITIReportBuildLogSection((const char *)data.bytes, data.length, partial, keyLines, tailLines, buffer, outBytes);
    NSString *section = OITIReportStringFromBytes(buffer, length);
    free(buffer);
    if (latestSession) {
        // the newest SpringBoard session start line, from the whole tail that was read
        NSString *whole = OITIReportStringFromBytes((const char *)data.bytes, data.length);
        for (NSString *line in [[whole componentsSeparatedByString:@"\n"] reverseObjectEnumerator]) {
            if ([line containsString:@"[SESSION] START build="] && [line containsString:@"proc=SpringBoard"]) {
                char cleaned[OITI_REPORT_MAX_LINE + 96];
                const char *utf8 = line.UTF8String ?: "";
                size_t n = OITIReportCleanLine(utf8, strlen(utf8), cleaned, sizeof cleaned);
                *latestSession = OITIReportStringFromBytes(cleaned, n);
                break;
            }
        }
    }
    return section;
}

static NSString *OITIReportOneLine(id value, NSUInteger limit) {
    NSString *text = [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return text.length > limit ? [[text substringToIndex:limit] stringByAppendingString:@"..."] : text;
}

static NSString *OITIReportSettings(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kOITIReportDomain);
    CFDictionaryRef values = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)kOITIReportDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *stored = CFBridgingRelease(values);
    if (!stored.count) return @"(no stored settings: every setting is at its default)\n";
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in [stored.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [text appendFormat:@"%@ = %@\n", key, OITIReportOneLine(stored[key], 120)];
        if (text.length > 7000) { [text appendString:@"[cut: more settings than fit]\n"]; break; }
    }
    return text;
}

static NSString *OITIReportGestaltLine(void) {
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:kOITIReportGestaltPath];
    if (!cache) return @"MobileGestalt cache: not readable";
    id extra = cache[@"CacheExtra"];
    id nested = [extra isKindOfClass:[NSDictionary class]] ? extra[@"oPeik/9e8lQWMszEjbPzng"] : nil;
    id subtype = [nested isKindOfClass:[NSDictionary class]] ? nested[@"ArtworkDeviceSubType"] : nil;
    if (!subtype) return @"MobileGestalt cache: ArtworkDeviceSubType is not set (no Island spoof stored)";
    return [NSString stringWithFormat:@"MobileGestalt cache: ArtworkDeviceSubType = %@ (2556 is the Island spoof)", subtype];
}

// What this phone's UIKit offers for the status bar fix, and whether the iOS version is the one Insula is built for. The Settings app
// runs on the same UIKit as SpringBoard, so these answers hold for SpringBoard too. Read-only.
static NSString *OITIReportEnvironmentChecks(NSString *bundlePath) {
    NSMutableString *text = [NSMutableString string];
    NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
    [text appendFormat:@"iOS %ld.%ld.%ld: %@\n", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion,
     version.majorVersion == 16 ? @"the iOS version Insula is built and tested for (16)" : @"outside what Insula is built and tested for (iOS 16): some features may not work"];
    NSString *layout = [bundlePath hasPrefix:@"/var/jb/"] ? @"rootless (/var/jb)" : ([bundlePath containsString:@".jbroot"] ? @"roothide (the path has .jbroot-)" : @"not recognized");
    [text appendFormat:@"Jailbreak layout, guessed from the Settings bundle path: %@ (Insula is built for rootless)\n", layout];
    Class provider = objc_getClass("_UIStatusBarVisualProvider_iOS");
    SEL selector = NSSelectorFromString(@"visualProviderSubclassForScreen:visualProviderInfo:");
    BOOL hasSelector = provider && class_getClassMethod(provider, selector) != NULL;
    [text appendFormat:@"UIKit class _UIStatusBarVisualProvider_iOS: %@\n", provider ? @"present" : @"MISSING (the status bar fix cannot work)"];
    [text appendFormat:@"+visualProviderSubclassForScreen:visualProviderInfo: (the method the status bar fix hooks): %@\n", hasSelector ? @"present" : @"MISSING (the status bar fix cannot work)"];
    unsigned int total = objc_getClassList(NULL, 0);
    Class *classes = total ? (Class *)malloc(sizeof(Class) * total) : NULL;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (classes) {
        total = objc_getClassList(classes, total);
        for (unsigned int i = 0; i < total; i++) {
            const char *name = class_getName(classes[i]);
            if (name && strncmp(name, "_UIStatusBarVisualProvider_", 27) == 0) [names addObject:[NSString stringWithUTF8String:name] ?: @"?"];
        }
        free(classes);
    }
    [names sortUsingSelector:@selector(compare:)];
    if (names.count > 40) [names removeObjectsInRange:NSMakeRange(40, names.count - 40)];
    [text appendFormat:@"Status bar provider classes on this phone (%lu shown): %@\n", (unsigned long)names.count, names.count ? [names componentsJoinedByString:@", "] : @"none"];
    id override = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("UIStatusBarVisualProviderClassName"), CFSTR("com.apple.UIKit")));
    [text appendFormat:@"UIStatusBarVisualProviderClassName override in com.apple.UIKit: %@\n", override ?: @"none"];
    return text;
}

NSString *OITIReportBuild(BOOL full) {
    @autoreleasepool {
        NSMutableString *report = [NSMutableString string];
        NSString *machine = [OITDeviceInfo machineIdentifier] ?: @"?";
        const OITIDeviceProfile *profile = OITIProfileForModel(machine);
        // UIScreen is read on the main thread (the report is built on a background queue)
        __block NSString *screenText = @"?";
        void (^readScreen)(void) = ^{
            UIScreen *screen = [UIScreen mainScreen];
            screenText = [NSString stringWithFormat:@"nativeBounds %@, scale %.2f", NSStringFromCGRect(screen.nativeBounds), (double)screen.scale];
        };
        if ([NSThread isMainThread]) readScreen(); else dispatch_sync(dispatch_get_main_queue(), readScreen);
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        NSInteger level = [[OITPreferences preferencesWithDomain:kOITIReportDomain] integerForKey:@"DiagnosticsLevel" default:0];
        NSBundle *bundle = [NSBundle bundleForClass:NSClassFromString(@"OITIBaseListController")];

        // the log sections first (they also give the newest session line), then the report in reading order
        NSString *logInfo = nil, *latestSession = nil, *prefsLogInfo = nil;
        NSString *logSection = full ? OITIReportLogSection(kOITIReportLogPath, 3u * 1024 * 1024, 600, 3000, 1200u * 1024, &logInfo, &latestSession)
                                    : OITIReportLogSection(kOITIReportLogPath, 400u * 1024, 80, 120, 34000, &logInfo, &latestSession);
        NSString *prefsLogSection = full ? OITIReportLogSection(kOITIReportPrefsLogPath, 256u * 1024, 0, 300, 100u * 1024, &prefsLogInfo, NULL)
                                         : OITIReportLogSection(kOITIReportPrefsLogPath, 64u * 1024, 0, 25, 4000, &prefsLogInfo, NULL);

        [report appendFormat:@"Insula diagnostics report (%@)\nCreated: %@\n\n", full ? @"full" : @"short", [formatter stringFromDate:[NSDate date]]];
        [report appendString:@"== Device ==\n"];
        [report appendFormat:@"Machine: %@%@\n", machine, profile ? [NSString stringWithFormat:@" (%s)", profile->name] : @" (not in Insula's device table)"];
        [report appendFormat:@"iOS: %@\n", [NSProcessInfo processInfo].operatingSystemVersionString];
        [report appendFormat:@"Screen: %@\n", screenText];
        [report appendFormat:@"Settings bundle path (shows the jailbreak layout): %@\n\n", bundle.bundlePath ?: @"?"];
        [report appendString:@"== Environment checks ==\n"];
        [report appendString:OITIReportEnvironmentChecks(bundle.bundlePath ?: @"")];
        [report appendString:@"\n== Insula ==\n"];
        [report appendFormat:@"%@\n", OITIInstalledVersionText()];
        [report appendFormat:@"Latest SpringBoard session start in the log: %@\n", latestSession ?: @"none found (the tweak has not written a session line, or the log is empty)"];
        [report appendFormat:@"Log Detail (DiagnosticsLevel): %ld (0 = Normal, 1 = Detailed)\n", (long)level];
        [report appendFormat:@"%@\n", OITIReportGestaltLine()];
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:kOITIReportNativeProviderPath];
        [report appendFormat:@"Native status bar provider record: %@\n\n", record ? OITIReportOneLine(record, 400) : @"none"];
        [report appendString:@"== Settings (stored values; a setting that is not listed is at its default) ==\n"];
        [report appendString:OITIReportSettings()];
        [report appendFormat:@"\n== Log: %@ ==\n", logInfo ?: kOITIReportLogPath];
        [report appendString:logSection];
        [report appendFormat:@"\n== Log: %@ ==\n", prefsLogInfo ?: kOITIReportPrefsLogPath];
        [report appendString:prefsLogSection];
        if (!full && report.length > OITI_REPORT_CLIPBOARD_LIMIT) {
            [report deleteCharactersInRange:NSMakeRange(OITI_REPORT_CLIPBOARD_LIMIT, report.length - OITI_REPORT_CLIPBOARD_LIMIT)];
            [report appendString:@"\n[cut: the report is longer than a GitHub comment; use Share Full Report instead]\n"];
        }
        return report;
    }
}

void OITIReportClearLogs(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in @[kOITIReportLogPath, kOITIReportLogPath1, kOITIReportPrefsLogPath]) [fileManager removeItemAtPath:path error:nil];
}
