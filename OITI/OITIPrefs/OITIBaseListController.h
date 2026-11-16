#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Foundation/Foundation.h>

// The installed Insula version for the line at the bottom of the main page and for the diagnostics report.
NSString *OITIInstalledVersionText(void);

// Shared behavior for every OITI settings page: loads its specifier plist, adds the Respring button and
// confirmation alert, and provides savePos: (the Save buttons). Subclasses only override -oiti_plistName.
@interface OITIBaseListController : PSListController

// Name of the specifier plist to load ("Root", "Color", "Scale", "Notifications").
- (NSString *)oiti_plistName;
- (void)oitiRefreshSettingsPage;

@end
