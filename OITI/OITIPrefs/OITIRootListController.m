#import <Foundation/Foundation.h>
#import "OITIRootListController.h"
#import "../Shared/OITIMobileGestalt.h"
#import <OITCore/OITCore.h>
#import <UIKit/UIKit.h>

static NSString * const kOITIPrefsBuildTag = @"OITIPrefs-0.4.0";
static NSString * const kOITIPrefsLogPath = @"/tmp/OITIPrefsDebug.log";

// Prefs-side log, separate from the tweak's /tmp/OITIDebug.log because this code runs in the Settings process.
static OITLogger *OITIPrefsLog(void) {
    static OITLogger *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = [OITLogger loggerWithName:@"oitiprefs" path:kOITIPrefsLogPath];
        log.ignoredImageNames = @[@"OITCore.dylib"];
        [log logSessionStartWithBuildTag:kOITIPrefsBuildTag];
    });
    return log;
}

@implementation OITIRootListController

- (NSString *)oiti_plistName {
    return @"Root";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Opening the settings page repairs a backup that was captured while the spoof was already active.
    OITIMobileGestaltRepairSuspectBackup(OITIPrefsLog());
}

// Puts the custom Island position back to its defaults (X 0, Y 20.5). The text fields store text, so these are stored as text too
// (the same form the fields write). The Use Custom Position switch is left as it is.
- (void)resetPosition {
    OITPreferences *prefs = [OITPreferences preferencesWithDomain:@"com.wilburt.oiti.prefs"];
    [prefs setObject:@"0" forKey:@"xPos"];
    [prefs setObject:@"20.5" forKey:@"yPos"];
    [prefs synchronize];
    OITPostDarwinNotification(@"com.wilburt.oiti/PrefsChanged");
    [self oitiRefreshSettingsPage];
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == [tableView numberOfSections] - 1) {
        UILabel *footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 50)];
        footerLabel.textAlignment = NSTextAlignmentCenter;
        footerLabel.textColor = [UIColor grayColor];
        footerLabel.font = [UIFont systemFontOfSize:14.0];
        footerLabel.text = @"Insula";
        return footerLabel;
    } else {
        return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (section == [tableView numberOfSections] - 1) {
        return 50;
    } else if (section == [tableView numberOfSections] - 5) {
        return 45;
    }
    return 0;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    if ([[specifier propertyForKey:@"key"] isEqualToString:@"islandEnabled"]) {
        BOOL switchValue = [value boolValue];
        OITIMobileGestaltSetIslandEnabled(switchValue, OITIPrefsLog());
    }
}
@end
