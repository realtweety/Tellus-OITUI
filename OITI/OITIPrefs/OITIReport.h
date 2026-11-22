// OITIReport.h -- the diagnostics report (Settings > Insula > Diagnostics), built in the Settings process.
//
// OITIReportBuild(NO) is the text that goes to the clipboard (kept under about 50 KB so it fits a GitHub comment, which holds 65,536
// characters); OITIReportBuild(YES) is the longer text for the share sheet (a file the person attaches). Both are made of: the device,
// iOS, the jailbreak layout, the Insula version and the latest tweak build tag seen in the log, the Detailed Logging level, what the
// MobileGestalt cache says about the Island spoof, the native provider record, every stored Insula setting, and the log (key lines
// and the last lines, cleaned by OITIReportText.h: notification text and download file names are removed). Reads only; nothing is
// written or changed. It runs when the person taps a button, never at launch.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSString *OITIReportBuild(BOOL full);
NSString *OITIReportInstalledVersionText(void);

// Removes the log files the tweak and this bundle write (the next log lines start a fresh file).
void OITIReportClearLogs(void);

#ifdef __cplusplus
}
#endif
