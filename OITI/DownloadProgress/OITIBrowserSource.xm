// OITIBrowserSource.xm -- the SpringBoard side of the browser source (OITI 0.3.5, Arc Search). Setting: DownloadBrowserEnabled
// (default NO; "Show Arc Downloads" under Download Progress; experimental).
//
// Arc Search sends the percentage and the end of its newest download as a 64-bit libnotify state (Browser/OITIBrowserProtocol.h;
// the Arc side is Browser/OITIBrowserDump.xm). This file turns each message into the same calls the App Store source makes, so
// both looks, the return to idle by percentage, the finished and cancelled states and the card in the stack work as for the App
// Store. Percentage only (OITIDownloadUpdateFraction); the file name is planned for 0.3.6. One download at a time: a message with
// a new serial replaces the one being shown. Pause and resume do not exist in Arc, so nothing is ever shown as paused.
//
// It also owns the flag the browser reads: libnotify state OITI_BROWSER_SOURCE_ENABLED_NAME is 1 only while Show Download Progress
// and Show Arc Downloads are on and Apple Mode and safe mode are off, so a browser installs no hook otherwise.
//
// Launch path: OITIBrowserSourceRefresh is only called from a block on the main queue after the launch work (see
// preferencesChanged()); nothing here runs in the %ctor and nothing calls UIKit.

#import <Foundation/Foundation.h>
#import <notify.h>
#import <signal.h>
#import <errno.h>
#import <OITCore/OITCore.h>
#import "Shared/OITIShared.h"
#import "DownloadProgress/OITIDownloadProgress.h"
#import "Browser/OITIBrowserProtocol.h"

static NSString * const kOITIBrowserArcBundleID = @"company.thebrowser.ArcMobile2";
static const NSTimeInterval kOITIBrowserAliveInterval = 2.0;

static BOOL sBrowserSourceWanted;
static BOOL sBrowserListening;
static int sBrowserFlagToken = -1;
static int sBrowserStateListenToken;
static NSString *sBrowserTracked;          // identifier of the download that is shown (browser.<pid>.<serial>)
static uint32_t sBrowserTrackedPid;
static NSTimer *sBrowserAliveTimer;

static void OITIBrowserSourceStopTracking(void) {
    sBrowserTracked = nil;
    sBrowserTrackedPid = 0;
    [sBrowserAliveTimer invalidate];
    sBrowserAliveTimer = nil;
}

// A browser that is killed or crashes sends no end message, so the download that is shown is checked against its process.
static void OITIBrowserSourceCheckAlive(void) {
    if (!sBrowserTracked || !sBrowserTrackedPid) return;
    if (kill((pid_t)sBrowserTrackedPid, 0) == 0 || errno != ESRCH) return;
    [sLog logTag:@"DOWNLOAD" format:@"browser source: process %u is gone, ending %@ as cancelled", sBrowserTrackedPid, sBrowserTracked];
    NSString *identifier = sBrowserTracked;
    OITIBrowserSourceStopTracking();
    OITIDownloadFinish(identifier, NO);
}

static void OITIBrowserSourceHandle(uint64_t message) {
    if (!sBrowserSourceWanted) return;
    uint32_t pid = 0, serial = 0, status = 0, tenThousandths = 0;
    if (!OITIBrowserDecodeState(message, &pid, &serial, &status, &tenThousandths)) {
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: ignored state 0x%llx (not a download message)", message];
        return;
    }
    @try {
        NSString *identifier = [NSString stringWithFormat:@"browser.%u.%u", pid, serial];
        double fraction = tenThousandths / 10000.0;
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: %@ status=%u %.2f%%", identifier, status, fraction * 100.0];
        if (sBrowserTracked && ![sBrowserTracked isEqualToString:identifier]) {
            // A new download replaces the one being shown (the newest wins); the old one ends without a verdict.
            [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: %@ replaces %@", identifier, sBrowserTracked];
            OITIDownloadDrop(sBrowserTracked);
            OITIBrowserSourceStopTracking();
        }
        BOOL tracked = [sBrowserTracked isEqualToString:identifier];
        switch (status) {
            case OITIBrowserStatusRunning:
                OITIDownloadUpdateFraction(identifier, @"Arc", @"Download", kOITIBrowserArcBundleID, fraction, NO, NO);
                sBrowserTracked = identifier;
                sBrowserTrackedPid = pid;
                if (!sBrowserAliveTimer) {
                    sBrowserAliveTimer = [NSTimer timerWithTimeInterval:kOITIBrowserAliveInterval repeats:YES block:^(NSTimer *timer) {
                        OITIBrowserSourceCheckAlive();
                    }];
                    [[NSRunLoop mainRunLoop] addTimer:sBrowserAliveTimer forMode:NSRunLoopCommonModes];
                }
                break;
            case OITIBrowserStatusFinished:
                // A download that ends before the first running message was seen (a small file) still gets its complete state.
                if (!tracked) OITIDownloadUpdateFraction(identifier, @"Arc", @"Download", kOITIBrowserArcBundleID, 1.0, NO, NO);
                OITIBrowserSourceStopTracking();
                OITIDownloadFinish(identifier, YES);
                break;
            case OITIBrowserStatusCancelled:
                if (tracked) {
                    OITIBrowserSourceStopTracking();
                    OITIDownloadFinish(identifier, NO);
                }
                break;
            default:
                break;   // waiting: the browser never sends it, nothing to show
        }
    } @catch (NSException *exception) {
        [sLog logTag:@"DOWNLOAD" format:@"browser source: exception %@: %@", exception.name, exception.reason];
    }
}

// Sets the flag the browser reads and starts or stops listening for the current settings. Idempotent; called after every
// preferences reload (from a block on the main queue, never from the %ctor itself).
void OITIBrowserSourceRefresh(void) {
    BOOL wanted = sDownloadProgressEnabled && sDownloadBrowserEnabled && !sAppleMode && !sSafeModeActive;
    BOOL changed = wanted != sBrowserSourceWanted;
    sBrowserSourceWanted = wanted;
    if (!sBrowserListening) {
        sBrowserListening = YES;
        uint32_t status = notify_register_dispatch(OITI_BROWSER_DOWNLOAD_STATE_NAME, &sBrowserStateListenToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t message = 0;
            if (notify_get_state(token, &message) == NOTIFY_STATUS_OK) OITIBrowserSourceHandle(message);
        });
        if (status != NOTIFY_STATUS_OK) [sLog logTag:@"DOWNLOAD" format:@"browser source: could not listen (status %u)", status];
    }
    if (sBrowserFlagToken < 0) {
        int token = 0;
        if (notify_register_check(OITI_BROWSER_SOURCE_ENABLED_NAME, &token) == NOTIFY_STATUS_OK) sBrowserFlagToken = token;
        changed = YES;   // the first call always writes the flag, so a stale value from before this launch is replaced
    }
    if (sBrowserFlagToken >= 0 && changed) {
        notify_set_state(sBrowserFlagToken, wanted ? 1 : 0);
        notify_post(OITI_BROWSER_SOURCE_ENABLED_NAME);
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source %@", wanted ? @"on (the browser may publish)" : @"off"];
    }
    if (!wanted && sBrowserTracked) {
        NSString *identifier = sBrowserTracked;
        OITIBrowserSourceStopTracking();
        OITIDownloadDrop(identifier);
    }
}
