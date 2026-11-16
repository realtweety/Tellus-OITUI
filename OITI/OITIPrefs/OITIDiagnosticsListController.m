#import "OITIDiagnosticsListController.h"
#import "OITIReport.h"
#import <OITCore/OITCore.h>
#import <UIKit/UIKit.h>

@implementation OITIDiagnosticsListController

- (NSString *)oiti_plistName {
    return @"Diagnostics";
}

// MARK: - Actions (the buttons in Diagnostics.plist)

// Builds the short report off the main thread and puts it on the clipboard.
- (void)copyReport {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = OITIReportBuild(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = report;
            NSUInteger lines = [report componentsSeparatedByString:@"\n"].count;
            NSString *message = [NSString stringWithFormat:@"%lu lines (%lu KB) are on the clipboard.\n\nRead it before you post it: the log can contain app names, and more with Log Detail set to Detailed. Notification text and download file names are removed. Universal Clipboard can also send it to your other devices.",
                                 (unsigned long)lines, (unsigned long)((report.length + 1023) / 1024)];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Report copied" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

// The longer report as a text file in the share sheet, to attach to a GitHub issue or send in a message.
- (void)shareReport {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = OITIReportBuild(YES);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Insula-report.txt"];
        NSError *error = nil;
        BOOL written = [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!written) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Report not saved" message:error.localizedDescription ?: @"The file could not be written." preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            sheet.popoverPresentationController.sourceView = self.view;
            [self presentViewController:sheet animated:YES completion:nil];
        });
    });
}

// Asks SpringBoard to write its status bar report and dump to the log now (the same request the boot report and the developer tools
// use). SpringBoard only does it while Log Detail is Detailed, so this checks first. Keep the name in sync with OITIDumpTriggers.xm.
- (void)runStatusBarCheck {
    NSInteger level = [[OITPreferences preferencesWithDomain:@"com.wilburt.oiti.prefs"] integerForKey:@"DiagnosticsLevel" default:0];
    UIAlertController *alert;
    if (level < 1) {
        alert = [UIAlertController alertControllerWithTitle:@"Log Detail is Normal"
                                                    message:@"SpringBoard ignores the request while Log Detail is Normal. Set Log Detail to Detailed first, then tap this again."
                                             preferredStyle:UIAlertControllerStyleAlert];
    } else {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.wilburt.oiti/Dump"), NULL, NULL, true);
        alert = [UIAlertController alertControllerWithTitle:@"Check requested"
                                                    message:@"SpringBoard writes the status bar report to the log. Wait a few seconds, then tap Copy Report to Clipboard. If the report has no STATUSBAR lines, tap this once more."
                                             preferredStyle:UIAlertControllerStyleAlert];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLogsAsk {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear log files"
                                                                   message:@"Deletes Insula's log files. New lines start a fresh file. Use it before reproducing a problem, so the report holds only that."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        OITIReportClearLogs();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
