#import "OITIMobileGestalt.h"
#import <OITCore/OITCore.h>

static NSString * const kOITIGestaltPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString * const kOITIGestaltBreadcrumbPath = @"/var/mobile/Library/Preferences/OITIGestaltBackup.plist";
static NSString * const kOITIGestaltDomain = @"com.wilburt.oiti.prefs";
static NSString * const kOITIGestaltCacheExtraKey = @"CacheExtra";
static NSString * const kOITIGestaltNestedKey = @"oPeik/9e8lQWMszEjbPzng";
static NSString * const kOITIGestaltLeafKey = @"ArtworkDeviceSubType";
static const NSInteger kOITISpoofedArtworkDeviceSubType = 2556;

BOOL OITIMachineHasNativeIsland(NSString *machine) {
    return [machine isEqualToString:@"iPhone15,2"];
}

static void OITIMobileGestaltWriteBreadcrumb(OITLogger *logger) {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIGestaltDomain];
    if (![prefs boolForKey:@"MobileGestaltBackupCaptured" default:NO]) return;

    NSMutableDictionary *breadcrumb = [NSMutableDictionary dictionary];
    breadcrumb[@"BackupCaptured"] = @YES;
    BOOL wasPresent = [prefs boolForKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent" default:NO];
    breadcrumb[@"OriginalValuePresent"] = @(wasPresent);
    if (wasPresent) {
        id originalValue = [prefs objectForKey:@"MobileGestaltOriginalArtworkDeviceSubType" default:nil];
        if (originalValue) breadcrumb[@"OriginalValue"] = originalValue;
    }
    if ([prefs boolForKey:@"MobileGestaltBackupSuspect" default:NO]) breadcrumb[@"CaptureSuspect"] = @YES;
    BOOL written = [breadcrumb writeToFile:kOITIGestaltBreadcrumbPath atomically:YES];
    [logger logTag:@"GESTALT" format:@"breadcrumb written ok=%d present=%d original=%@ suspect=%d",
     written, wasPresent, breadcrumb[@"OriginalValue"] ?: @"(none)", [breadcrumb[@"CaptureSuspect"] boolValue]];
}

void OITIMobileGestaltRepairSuspectBackup(OITLogger *logger) {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIGestaltDomain];
    if (![prefs boolForKey:@"MobileGestaltBackupCaptured" default:NO] ||
        [prefs boolForKey:@"MobileGestaltBackupSuspect" default:NO]) return;

    BOOL present = [prefs boolForKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent" default:NO];
    id original = [prefs objectForKey:@"MobileGestaltOriginalArtworkDeviceSubType" default:nil];
    NSString *machine = [OITDeviceInfo machineIdentifier];
    if (!present || ![original isKindOfClass:[NSNumber class]] ||
        [original integerValue] != kOITISpoofedArtworkDeviceSubType ||
        OITIMachineHasNativeIsland(machine)) return;

    [logger logTag:@"GESTALT" format:@"REPAIR backup recorded original=%@ on %@ (not Island hardware): recording the original as absent instead",
     original, machine];
    [prefs setObject:@NO forKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent"];
    [prefs removeObjectForKey:@"MobileGestaltOriginalArtworkDeviceSubType"];
    [prefs setObject:@YES forKey:@"MobileGestaltBackupSuspect"];
    [prefs synchronize];
    OITIMobileGestaltWriteBreadcrumb(logger);
}

static void OITIMobileGestaltCaptureOriginalIfNeeded(OITLogger *logger) {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIGestaltDomain];
    if ([prefs boolForKey:@"MobileGestaltBackupCaptured" default:NO]) {
        OITIMobileGestaltRepairSuspectBackup(logger);
        return;
    }

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kOITIGestaltPath];
    if (!plist) {
        [logger logTag:@"GESTALT" format:@"backup NOT captured: MobileGestalt cache not readable at %@", kOITIGestaltPath];
        return;
    }
    NSDictionary *extra = plist[kOITIGestaltCacheExtraKey];
    NSDictionary *nested = extra[kOITIGestaltNestedKey];
    id existingValue = nested[kOITIGestaltLeafKey];
    NSString *machine = [OITDeviceInfo machineIdentifier];
    BOOL suspect = [existingValue isKindOfClass:[NSNumber class]] &&
        [existingValue integerValue] == kOITISpoofedArtworkDeviceSubType &&
        !OITIMachineHasNativeIsland(machine);

    if ([existingValue isKindOfClass:[NSNumber class]] && !suspect) {
        [prefs setObject:@YES forKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent"];
        [prefs setObject:existingValue forKey:@"MobileGestaltOriginalArtworkDeviceSubType"];
        [logger logTag:@"GESTALT" format:@"capture: original=%@ on %@", existingValue, machine];
    } else {
        [prefs setObject:@NO forKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent"];
        if (suspect) {
            [logger logTag:@"GESTALT" format:@"capture: cache already holds %@ on %@ (not Island hardware): recording the original as absent",
             existingValue, machine];
        } else {
            [logger logTag:@"GESTALT" format:@"capture: cache has no %@ value on %@ (original recorded as absent)",
             kOITIGestaltLeafKey, machine];
        }
    }
    if (suspect) [prefs setObject:@YES forKey:@"MobileGestaltBackupSuspect"];
    [prefs setObject:@YES forKey:@"MobileGestaltBackupCaptured"];
    [prefs synchronize];
    OITIMobileGestaltWriteBreadcrumb(logger);
}

static BOOL OITIMobileGestaltWriteValue(id value, OITLogger *logger) {
    NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:kOITIGestaltPath] mutableCopy];
    if (!plist) {
        [logger logTag:@"GESTALT" format:@"write %@ skipped: cache not readable", value ?: @"(remove key)"];
        return NO;
    }

    NSMutableDictionary *extra = [plist[kOITIGestaltCacheExtraKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *nested = [extra[kOITIGestaltNestedKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) nested[kOITIGestaltLeafKey] = value;
    else [nested removeObjectForKey:kOITIGestaltLeafKey];
    extra[kOITIGestaltNestedKey] = nested;
    plist[kOITIGestaltCacheExtraKey] = extra;

    BOOL written = [plist writeToFile:kOITIGestaltPath atomically:YES];
    [logger logTag:@"GESTALT" format:@"cache %@ %@ ok=%d",
     value ? @"set to" : @"key removed:", value ?: kOITIGestaltLeafKey, written];
    return written;
}

BOOL OITIMobileGestaltSetIslandEnabled(BOOL enabled, OITLogger *logger) {
    if (enabled) {
        [logger logTag:@"GESTALT" format:@"islandEnabled ON requested"];
        OITIMobileGestaltCaptureOriginalIfNeeded(logger);
        return OITIMobileGestaltWriteValue(@(kOITISpoofedArtworkDeviceSubType), logger);
    }

    [logger logTag:@"GESTALT" format:@"islandEnabled OFF requested"];
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIGestaltDomain];
    if (![prefs boolForKey:@"MobileGestaltBackupCaptured" default:NO]) {
        [logger logTag:@"GESTALT" format:@"restore skipped: nothing was ever captured"];
        return YES;
    }
    OITIMobileGestaltRepairSuspectBackup(logger);
    prefs = [OITPreferences preferencesWithDomain:kOITIGestaltDomain];

    BOOL wasPresent = [prefs boolForKey:@"MobileGestaltOriginalArtworkDeviceSubTypePresent" default:NO];
    id originalValue = wasPresent ? [prefs objectForKey:@"MobileGestaltOriginalArtworkDeviceSubType" default:nil] : nil;
    if (wasPresent) {
        [logger logTag:@"GESTALT" format:@"restoring original value %@", originalValue ?: @"(nil)"];
    } else {
        [logger logTag:@"GESTALT" format:@"original was absent: removing the key"];
    }

    BOOL written = OITIMobileGestaltWriteValue(originalValue, logger);
    OITIMobileGestaltWriteBreadcrumb(logger);
    return written;
}
