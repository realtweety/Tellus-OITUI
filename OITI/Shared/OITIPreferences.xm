// OITIPreferences.xm -- the preferences reload (v0.3.0 module split, round 7).
//
// Moved from Tweak.xm unchanged: preferencesChanged reads every OITI setting from com.wilburt.oiti.prefs into the variables
// declared in Shared/OITIShared.h and the modules' headers, logs what changed and asks the modules to refresh. The %ctor in
// Tweak.xm calls it at launch and on the PrefsChanged Darwin notification, so it lost its `static`.

#import "Shared/OITIShared.h"
#import "Safety/OITISafety.h"
#import "Diagnostics/OITIDiagnostics.h"
#import "DownloadProgress/OITIDownloadProgress.h"
#import "IslandSize/OITIIslandSize.h"
#import "IslandNotifications/OITIIslandNotifications.h"
#import "Startup/OITIStartup.h"
#import "StatusBar/OITIStatusBar.h"
#import "OITIPositionValues.h"   // strict parsing for the typed position settings (Foundation only: this file runs from %ctor)

static NSString * const kOITIPrefsDomain = @"com.wilburt.oiti.prefs";
static NSDictionary<NSString *, NSNumber *> *sLastPrefSnapshot;

// One-time migration (v0.3.0, batch 8). Fix Island Position and Fix Notification Positioning are gone: the built-in positions only
// existed for some devices, were mostly estimates, and people changed them anyway. So that nobody's Island or banner moves on the
// update, a device that has a table entry and had a Fix switch on gets the same position as a custom position, once:
//   Fix Island Position on       -> Use Custom Position on, X 0, Y = the table's islandY   (the Island's old Y)
//   Fix Notification Positioning -> Use Custom Notification Position on, X 0, Y = the table's bannerY
// (the old Fix took priority over a custom value, so the custom X and Y are overwritten too). Without a table entry the old switch
// did nothing and nothing is changed. The key PresetPositionsMigrated is written either way, so it never runs again. It runs from
// preferencesChanged, after the respring-loop guard, and uses only sysctl (the machine identifier) and preferences: no UIKit.
// The stored fixEnabled and notificationFix keys are left as they are and are ignored from now on.
static void OITIMigratePresetPositions(void) {
    if ([sOITIPreferences boolForKey:@"PresetPositionsMigrated" default:NO]) return;
    const OITIDeviceProfile *profile = OITICurrentProfile();
    BOOL islandFix = [sOITIPreferences boolForKey:@"fixEnabled" default:NO];
    BOOL bannerFix = [sOITIPreferences boolForKey:@"notificationFix" default:NO];
    if (profile && islandFix) {
        [sOITIPreferences setObject:@YES forKey:@"posEnabled"];
        [sOITIPreferences setObject:@"0" forKey:@"xPos"];
        [sOITIPreferences setObject:[NSString stringWithFormat:@"%g", (double)profile->islandY] forKey:@"yPos"];
    }
    if (profile && bannerFix) {
        [sOITIPreferences setObject:@YES forKey:@"notEnabled"];
        [sOITIPreferences setObject:@"0" forKey:@"xNot"];
        [sOITIPreferences setObject:[NSString stringWithFormat:@"%g", (double)profile->bannerY] forKey:@"yNot"];
    }
    [sOITIPreferences setObject:@YES forKey:@"PresetPositionsMigrated"];
    [sOITIPreferences synchronize];
    [sLog logLevel:0 tag:@"PREF" format:@"preset positions migrated once: device %@ (%@), Fix Island Position was %@, Fix Notification Positioning was %@",
     [OITDeviceInfo machineIdentifier] ?: @"?", profile ? @(profile->name) : @"no table entry", islandFix ? @"on" : @"off", bannerFix ? @"on" : @"off"];
}

// One of the four typed position settings (xPos, yPos, xNot, yNot). The Settings text field stores a string, `defaults write`
// stores a number. A string that is not a plain number (empty, "abc", "nan", "1e30") gives the setting's default instead of 0,
// and the result is always finite and inside kOITIPositionCeiling. The tighter limit of one screen needs UIScreen, which must
// not be touched from here (this runs from %ctor, before UIKit is up), so it is applied where the value is used
// (OITIClampedPositionForUse in IslandSize/OITIIslandHooks.xm).
static CGFloat OITIReadPositionPreference(NSString *key, CGFloat fallback) {
    id raw = [sOITIPreferences objectForKey:key default:nil];
    double value = fallback;
    BOOL valid = YES;
    if ([raw isKindOfClass:[NSNumber class]]) value = [raw doubleValue];
    else if ([raw isKindOfClass:[NSString class]]) valid = OITIParsePositionText(raw, &value);
    CGFloat result = valid ? (CGFloat)OITISanitizedPosition(value, fallback, kOITIPositionCeiling) : fallback;
    if (raw && (!valid || !isfinite(value) || fabs(result - value) > 0.0001)) {
        [sLog logLevel:1 tag:@"PREF" format:@"position %@ = %@ is %@, using %.1f", key, raw,
         (valid && isfinite(value)) ? @"outside the allowed range" : @"not a plain number", (double)result];
    }
    return result;
}

// Diagnostics and safe-mode settings (no prefs UI yet; set with `defaults write`). Read by the %ctor before preferencesChanged()
// (OITIPrepareEarlyPreferences) so the loop guard can run first, and again by every preferencesChanged().
static void OITIApplyDiagnosticsAndGuardSettings(void) {
    sLog.enabled = [sOITIPreferences boolForKey:@"DiagnosticsEnabled" default:YES];
    sLog.level = MAX(0, MIN(2, [sOITIPreferences integerForKey:@"DiagnosticsLevel" default:0]));
    sGuardEnabled = [sOITIPreferences boolForKey:@"SafeModeGuardEnabled" default:YES];
    sGuardMaxLaunches = MAX(2, [sOITIPreferences integerForKey:@"SafeModeMaxLaunches" default:5]);
    sGuardWindowSeconds = MAX(10, [sOITIPreferences integerForKey:@"SafeModeWindowSeconds" default:120]);
    sGuardStableSeconds = MAX(5, [sOITIPreferences integerForKey:@"SafeModeStableSeconds" default:45]);
    sGuardRestoreGestalt = [sOITIPreferences boolForKey:@"SafeModeRestoreGestalt" default:NO];
}

// The only preferences read before the loop guard has run: the preferences object, the log settings and the guard settings.
void OITIPrepareEarlyPreferences(void) {
    if (!sOITIPreferences) sOITIPreferences = [OITPreferences preferencesWithDomain:kOITIPrefsDomain];
    OITIApplyDiagnosticsAndGuardSettings();
}

// What a launch in safe mode (hooks not installed) loads instead of preferencesChanged(): the log and guard settings and
// islandEnabled (the startup self-check and the dumps report it). Safe mode exists to keep a failing code path from running
// again, so the full preference reload is not run there; the other settings keep their defaults and do nothing anyway.
void OITIApplySafeModePreferences(void) {
    if (!sOITIPreferences) sOITIPreferences = [OITPreferences preferencesWithDomain:kOITIPrefsDomain];
    else [sOITIPreferences reload];
    islandEnabled = [sOITIPreferences boolForKey:@"islandEnabled" default:NO];
    OITIApplyDiagnosticsAndGuardSettings();
}

void preferencesChanged(void) {
    BOOL islandNotificationsWereEnabled = islandNotificationsEnabled;
    BOOL islandNotificationStackWasEnabled = sIslandNotificationStackEnabled;
    BOOL startupHelloWasEnabled = islandStartupHelloEnabled;
    if (!sOITIPreferences) {
        sOITIPreferences = [OITPreferences preferencesWithDomain:kOITIPrefsDomain];
    } else {
        [sOITIPreferences reload];
    }

    OITIMigratePresetPositions();   // before the values below are read, so a migrated position applies in this same pass

    islandEnabled = [sOITIPreferences boolForKey:@"islandEnabled" default:NO];
    posEnabled = [sOITIPreferences boolForKey:@"posEnabled" default:NO];
    hideEnabled = [sOITIPreferences boolForKey:@"hideEnabled" default:NO];
    notEnabled = [sOITIPreferences boolForKey:@"notEnabled" default:NO];
    colorEnabled = [sOITIPreferences boolForKey:@"colorEnabled" default:NO];
    transEnabled = [sOITIPreferences boolForKey:@"transEnabled" default:NO];
    scaleEnabled = [sOITIPreferences boolForKey:@"scaleEnabled" default:NO];
    lineDisabled = [sOITIPreferences boolForKey:@"lineDisabled" default:NO];
    islandNotificationsEnabled = [sOITIPreferences boolForKey:@"islandNotificationsEnabled" default:NO];
    islandNotificationsHideBanner = [sOITIPreferences boolForKey:@"islandNotificationsHideBanner" default:NO];
    sIslandNotificationStackEnabled = [sOITIPreferences boolForKey:@"islandNotificationStackEnabled" default:YES];
    sNotificationHapticEnabled = [sOITIPreferences boolForKey:@"NotificationHaptic" default:NO];
    sIslandNotificationTapDismisses = [sOITIPreferences boolForKey:@"NotificationTapDismisses" default:NO];
    islandStartupHelloEnabled = [sOITIPreferences boolForKey:@"IslandStartupHelloEnabled" default:NO];
    BOOL downloadProgressWasEnabled = sDownloadProgressEnabled;
    sDownloadProgressEnabled = [sOITIPreferences boolForKey:@"DownloadProgressEnabled" default:NO];
    sDownloadAppStoreEnabled = [sOITIPreferences boolForKey:@"DownloadAppStoreEnabled" default:NO];
    sDownloadBrowserEnabled = [sOITIPreferences boolForKey:@"DownloadBrowserEnabled" default:NO];
    sDownloadTestFractionOnly = [sOITIPreferences boolForKey:@"DownloadTestFractionOnly" default:NO];
    CGFloat downloadIdleMB = [sOITIPreferences floatForKey:@"DownloadIdleAfterMB" default:0.0];
    sDownloadIdleAfterMB = isfinite(downloadIdleMB) ? MAX(0.0, MIN(5000.0, downloadIdleMB)) : 0.0;
    CGFloat downloadIdleSeconds = [sOITIPreferences floatForKey:@"DownloadIdleAfterSeconds" default:0.0];
    sDownloadIdleAfterSeconds = isfinite(downloadIdleSeconds) ? MAX(0.0, MIN(900.0, downloadIdleSeconds)) : 0.0;
    CGFloat downloadIdlePercent = [sOITIPreferences floatForKey:@"DownloadIdleAfterPercent" default:0.0];
    sDownloadIdleAfterPercent = isfinite(downloadIdlePercent) ? MAX(0.0, MIN(99.0, downloadIdlePercent)) : 0.0;   // 99 at most: 100% is the completion state
    NSInteger downloadPreviousStyle = sDownloadStyle;
    sDownloadStyle = (NSInteger)lround([sOITIPreferences floatForKey:@"DownloadProgressStyle" default:0.0]) == 1 ? 1 : 0;
    CGFloat pillWidth = [sOITIPreferences floatForKey:@"DownloadPillWidth" default:296.0];
    sDownloadPillWidth = isfinite(pillWidth) ? MAX(200.0, MIN(380.0, pillWidth)) : 296.0;
    CGFloat pillBottom = [sOITIPreferences floatForKey:@"DownloadPillBottomPadding" default:10.0];
    sDownloadPillBottomPadding = isfinite(pillBottom) ? MAX(0.0, MIN(40.0, pillBottom)) : 10.0;
    CGFloat pillNudge = [sOITIPreferences floatForKey:@"DownloadPillNudgeY" default:0.0];
    sDownloadPillNudgeY = isfinite(pillNudge) ? MAX(-30.0, MIN(30.0, pillNudge)) : 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{ [sDownloadPill relayout]; });   // live size changes
    CGFloat downloadTestMB = [sOITIPreferences floatForKey:@"DownloadTestSizeMB" default:800.0];
    sDownloadTestSizeMB = isfinite(downloadTestMB) ? MAX(50.0, MIN(5000.0, downloadTestMB)) : 800.0;

    // Apple Mode: force every customization off here, after the stored values are read and before anything below
    // compares old and new state, so turning it on behaves exactly like switching each feature off (stack cleared,
    // startup animation cancelled, transforms reset). The stored preferences are not touched.
    BOOL appleModeWasOn = sAppleMode;
    sAppleMode = [sOITIPreferences boolForKey:@"appleMode" default:NO];
    if (sAppleMode) {
        // Where the Island and the banner sit (Use Custom Position, Use Custom Notification Position) stays on in Apple Mode: since
        // 0.3.0 it is all that is left of the built-in position fixes that Apple Mode always kept, and a notched phone needs it.
        hideEnabled = NO;
        colorEnabled = NO;
        transEnabled = NO;
        scaleEnabled = NO;
        lineDisabled = NO;
        islandNotificationsEnabled = NO;
        islandNotificationsHideBanner = NO;
        sNotificationHapticEnabled = NO;   // a customization of the stock notification experience, so it is off too
        sIslandNotificationTapDismisses = NO;   // it only acts on Island notices, which Apple Mode removes; off for consistency
        islandStartupHelloEnabled = NO;
        sDownloadProgressEnabled = NO;
        sDownloadAppStoreEnabled = NO;
        sDownloadBrowserEnabled = NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ OITIAppStoreSourceRefresh(); OITIBrowserSourceRefresh(); });   // starts or stops the App Store source and sets the browser flag
    if (sDownloadProgressEnabled != downloadProgressWasEnabled || sDownloadStyle != downloadPreviousStyle) {
        BOOL restyle = sDownloadStyle != downloadPreviousStyle;
        dispatch_async(dispatch_get_main_queue(), ^{
            // A new look needs a new view, so the old one is removed and the refresh presents the next.
            if (restyle && sDownloadItem) OITIRemoveNoticeItem(sDownloadItem, @"restyle");
            if (restyle) OITIDownloadPillDismiss(@"restyle");
            OITIDownloadsRefresh();   // present or remove the view for the new setting
        });
    }
    if (sAppleMode != appleModeWasOn && sLog) {
        [sLog logTag:@"PREF" format:@"Apple Mode %@: Island customizations are %@", sAppleMode ? @"ON" : @"OFF",
         sAppleMode ? @"forced off (stock Island)" : @"back to the user's settings"];
    }
    CGFloat noticeDuration = [sOITIPreferences floatForKey:@"IslandNotificationsDuration" default:4.0];
    sIslandNoticeDuration = isfinite(noticeDuration) ? MAX(1.0, MIN(15.0, noticeDuration)) : 4.0;

    if (startupHelloWasEnabled && !islandStartupHelloEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OITICancelStartupHello(@"disabled-in-settings");
        });
    }

    if (islandNotificationStackWasEnabled && !sIslandNotificationStackEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSDictionary *> *items = [sIslandNoticeItems copy];
            if (items.count > 1) {
                for (NSUInteger i = 0; i + 1 < items.count; i++) {
                    OITIRemoveNoticeItem(items[i], @"stack-disabled");
                }
            }
            [sLog logLevel:1 tag:@"ELEMENT" format:@"STACK disabled from Settings; retained newest item and cleared older items"];
        });
    }

    if (islandNotificationsWereEnabled && !islandNotificationsEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSDictionary *> *items = [sIslandNoticeItems copy];
            for (NSDictionary *item in items) OITIRemoveNoticeItem(item, @"feature-disabled");
            if (sBannerHideActive) {
                OITIRestoreBannerWindows();
                sBannerHideActive = NO;
            }
            [sLog logLevel:1 tag:@"ELEMENT" format:@"STACK cleared because Island Notifications was turned off"];
        });
    }

    // Defaults match the globals above (and the prefs UI).
    xPos = OITIReadPositionPreference(@"xPos", 0.0);
    yPos = OITIReadPositionPreference(@"yPos", 20.5);
    xNot = OITIReadPositionPreference(@"xNot", 0.0);
    yNot = OITIReadPositionPreference(@"yNot", 40.0);
    red = [sOITIPreferences floatForKey:@"red" default:0.0];
    green = [sOITIPreferences floatForKey:@"green" default:0.0];
    blue = [sOITIPreferences floatForKey:@"blue" default:0.0];
    alpha = [sOITIPreferences floatForKey:@"alpha" default:1.0];
    scaleX = [sOITIPreferences floatForKey:@"RelativeScaleX" default:1.0];
    scaleY = [sOITIPreferences floatForKey:@"RelativeScaleY" default:1.0];

    // Island size multipliers (Apple's layout reads them again on its next layout, so changes apply live).
    sMetricsSensorX = OITIClampMetricsFactor([sOITIPreferences floatForKey:@"MetricsSensorWidthScale" default:1.0]);
    sMetricsSensorY = OITIClampMetricsFactor([sOITIPreferences floatForKey:@"MetricsSensorHeightScale" default:1.0]);
    if (sAppleMode) {
        sMetricsSensorX = 1.0;
        sMetricsSensorY = 1.0;
    }

    OITIApplyDiagnosticsAndGuardSettings();

    NSDictionary<NSString *, NSNumber *> *snapshot = OITIPrefSnapshot();
    if (!sLastPrefSnapshot) {
        [sLog logLevel:1 tag:@"PREF" format:@"initial: %@", OITIPrefSnapshotString(snapshot)];
    } else if ([snapshot isEqualToDictionary:sLastPrefSnapshot]) {
        [sLog logLevel:2 tag:@"PREF" format:@"reload: no change"];
    } else {
        NSMutableArray<NSString *> *changes = [NSMutableArray array];
        for (NSString *key in [snapshot.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (![snapshot[key] isEqualToNumber:sLastPrefSnapshot[key]]) {
                [changes addObject:[NSString stringWithFormat:@"%@: %@ -> %@", key, sLastPrefSnapshot[key], snapshot[key]]];
            }
        }
        [sLog logLevel:1 tag:@"PREF" format:@"CHANGED %@", [changes componentsJoinedByString:@", "]];
    }
    sLastPrefSnapshot = snapshot;

    OITIUpdateDumpTrigger();
    OITIRefreshIslandLayout();
}
