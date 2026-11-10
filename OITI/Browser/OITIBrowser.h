// OITIBrowser.h -- browser downloads, research only (v0.3.5, batch 1).
//
// Nothing here changes what the user sees. It exists to find out, from the phone, how Arc Search and Safari report a download,
// before any browser source for Download Progress is written (OITIBrowserDump.xm explains the plan and the risks).

#pragma once
#import <Foundation/Foundation.h>

// Called from the %ctor in every process that is not SpringBoard (OITI.plist loads the dylib into every UIKit app). The first thing
// it does is compare the bundle ID against a hardcoded allowlist and return, so every other app is untouched. For an allowlisted
// browser it does nothing unless the file OITIBrowserDump.enable exists in that app's own Library folder.
void OITIBrowserDumpStartIfAllowed(NSString *bundleID);

// SpringBoard side of the cross-process test: logs (level 1) what the browser process sent. Notifications and libnotify state only.
void OITIBrowserProbeObserveInSpringBoard(void);
