#import "OITIDiagnosticsListController.h"
#import "OITIReport.h"
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
