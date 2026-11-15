// OITIBrowser.h -- browser downloads, research only (v0.3.5, batch 1).
//
// Browser downloads for Download Progress (OITI 0.3.5, Arc Search; 0.3.6, Chrome and the file name): the browser side (a source that
// sends the percentage, the end and the file name of the newest download to SpringBoard) and the research log it grew out of. OITIBrowserDump.xm explains what runs where and the risks;
// OITIBrowserProtocol.h is the message; DownloadProgress/OITIBrowserSource.xm is the SpringBoard side.

#pragma once
#import <Foundation/Foundation.h>

// Called from the %ctor in every process that is not SpringBoard (OITI.plist loads the dylib into every UIKit app). The first thing
// it does is compare the bundle ID against a hardcoded allowlist and return, so every other app is untouched. In Arc Search or
// Chrome it then waits for SpringBoard's "Show Browser Downloads" flag (off by default); in Arc, Chrome or Safari the research log
// starts only if the file OITIBrowserDump.enable exists in that app's own Library folder.
void OITIBrowserStartIfAllowed(NSString *bundleID);

// SpringBoard side of the cross-process test: logs (level 1) what the browser process sent. Notifications and libnotify state only.
void OITIBrowserProbeObserveInSpringBoard(void);
