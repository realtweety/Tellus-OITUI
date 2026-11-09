#import "OITIColorListController.h"
#import <OITCore/OITCore.h>

static NSString * const kOITIColorPrefsDomain = @"com.wilburt.oiti.prefs";
static NSString * const kOITIColorPrefsChangedNotification = @"com.wilburt.oiti/PrefsChanged";

@implementation OITIColorListController

- (NSString *)oiti_plistName {
    return @"Color";
}

// Puts the Opacity slider back to 1.0 (fully opaque, the stock value). The Use Custom Opacity switch is left as it is.
- (void)resetOpacity {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIColorPrefsDomain];
    [prefs setObject:@1.0 forKey:@"alpha"];
    [prefs synchronize];
    OITPostDarwinNotification(kOITIColorPrefsChangedNotification);
    [self oitiRefreshSettingsPage];
}

// Puts Red, Green and Blue back to 0 (black, the stock Island color). The Use Custom Color switch is left as it is.
- (void)resetColor {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:kOITIColorPrefsDomain];
    [prefs setObject:@0.0 forKey:@"red"];
    [prefs setObject:@0.0 forKey:@"green"];
    [prefs setObject:@0.0 forKey:@"blue"];
    [prefs synchronize];
    OITPostDarwinNotification(kOITIColorPrefsChangedNotification);
    [self oitiRefreshSettingsPage];
}

@end
