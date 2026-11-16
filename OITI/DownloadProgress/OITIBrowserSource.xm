// OITIBrowserSource.xm -- the SpringBoard side of the browser source (OITI 0.3.5 Arc Search; 0.3.6 Chrome and the file name).
// Setting: DownloadBrowserEnabled (default NO; "Show Browser Downloads" under Download Progress; experimental).
//
// Arc Search and Chrome send the percentage and the end of their newest download as a 64-bit libnotify state, protocol version 2
// (Browser/OITIBrowserProtocol.h; the browser side is Browser/OITIBrowserDump.xm). The state carries the browser ID; the file name
// travels in eight more libnotify states that the browser sets first, and is used only when its header matches the message's pid
// and serial. This file turns each message into the same calls the App Store source makes, so both looks, the return to idle by
// percentage, the finished and cancelled states and the card in the stack work as for the App Store. Percentage only
// (OITIDownloadUpdateFraction); the title is the file name, or "Download" when no name arrived. A name that is not there at the first
// message is looked for again at each later one (the tracker takes a new title with every update). One download at a time: a message
// with a new serial replaces the one being shown. Pause and resume do not exist in these browsers, so nothing is ever shown as paused.
// Version 1 messages (an Arc process started before the 0.3.6 update) are ignored.
//
// It also owns the flag the browser reads: libnotify state OITI_BROWSER_SOURCE_ENABLED_NAME is 1 only while Show Download Progress
// and Show Browser Downloads are on and Apple Mode and safe mode are off, so a browser installs no hook otherwise.
//
// The file name is private: it is logged only at DiagnosticsLevel 1, never at the default level.
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

// The browsers that publish (OITIBrowserID* in the protocol header) and how they are shown. Hardcoded bundle IDs, as in the browser side.
static BOOL OITIBrowserSourceDescribe(uint32_t browserID, NSString **appName, NSString **bundleID) {
    switch (browserID) {
        case OITIBrowserIDArc:    *appName = @"Arc";    *bundleID = @"company.thebrowser.ArcMobile2"; return YES;
        case OITIBrowserIDChrome: *appName = @"Chrome"; *bundleID = @"com.google.chrome.ios"; return YES;
        default: return NO;
    }
}
static const NSTimeInterval kOITIBrowserAliveInterval = 2.0;

static BOOL sBrowserSourceWanted;
static BOOL sBrowserListening;
static int sBrowserFlagToken = -1;
static int sBrowserStateListenToken;
static NSString *sBrowserTracked;          // identifier of the download that is shown (browser.<pid>.<serial>)
static uint32_t sBrowserTrackedPid;
static NSString *sBrowserTrackedTitle;     // the file name of the download that is shown, once it has been read
static int sBrowserNameTokens[OITI_BROWSER_NAME_CHUNK_COUNT];
static BOOL sBrowserNameTokensReady;
static NSTimer *sBrowserAliveTimer;

// The eight name chunk states are registered when the source is switched on (not at launch): the first read through a token that was
// registered at that moment returned zeros in the 0.3.6 research (Safari, 13 Nov 2026), so they are ready before the first message.
static void OITIBrowserSourceRegisterNameTokens(void) {
    if (sBrowserNameTokensReady) return;
    sBrowserNameTokensReady = YES;
    unsigned failures = 0;
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
        int token = 0;
        if (notify_register_check(OITIBrowserNameChunkName(i), &token) == NOTIFY_STATUS_OK) {
            sBrowserNameTokens[i] = token;
        } else {
            sBrowserNameTokens[i] = -1;
            failures++;
        }
    }
    [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: name tokens registered (%u failures)", failures];
}

// The file name of the download with this pid and serial, or nil (no name published, a header that is not for this download, bytes
// that are not UTF-8). Control characters become spaces and the ends are trimmed, so a name never breaks the one-line label.
static NSString *OITIBrowserSourceReadName(uint32_t pid, uint32_t serial) {
    OITIBrowserSourceRegisterNameTokens();
    uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT];
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
        chunks[i] = 0;
        if (sBrowserNameTokens[i] < 0 || notify_get_state(sBrowserNameTokens[i], &chunks[i]) != NOTIFY_STATUS_OK) return nil;
    }
    char buffer[OITI_BROWSER_NAME_MAX_BYTES + 1];
    int length = OITIBrowserUnpackName(chunks, pid, serial, buffer, sizeof buffer);
    if (length <= 0) return nil;
    NSString *name = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    if (!name.length) return nil;
    name = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet controlCharacterSet]] componentsJoinedByString:@" "];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length ? name : nil;
}

static void OITIBrowserSourceStopTracking(void) {
    sBrowserTracked = nil;
    sBrowserTrackedPid = 0;
    sBrowserTrackedTitle = nil;
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
    uint32_t pid = 0, browserID = 0, serial = 0, status = 0, tenThousandths = 0;
    BOOL hasName = NO;
    if (!OITIBrowserDecodeStateV2(message, &pid, &browserID, &hasName, &serial, &status, &tenThousandths)) {
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: ignored state 0x%llx (not a version 2 download message)", message];
        return;
    }
    NSString *appName = nil, *bundleID = nil;
    if (!OITIBrowserSourceDescribe(browserID, &appName, &bundleID)) {
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: ignored state 0x%llx (browser ID %u does not publish)", message, browserID];
        return;
    }
    @try {
        NSString *identifier = [NSString stringWithFormat:@"browser.%u.%u", pid, serial];
        double fraction = tenThousandths / 10000.0;
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: %@ (%@) status=%u %.2f%% name flag %d", identifier, appName, status, fraction * 100.0, hasName];
        if (sBrowserTracked && ![sBrowserTracked isEqualToString:identifier]) {
            // A new download replaces the one being shown (the newest wins); the old one ends without a verdict.
            [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: %@ replaces %@", identifier, sBrowserTracked];
            OITIDownloadDrop(sBrowserTracked);
            OITIBrowserSourceStopTracking();
        }
        BOOL tracked = [sBrowserTracked isEqualToString:identifier];
        // The name is read until it has been read once for the download that is shown (a failed read is tried again at the next message).
        NSString *title = tracked ? sBrowserTrackedTitle : nil;
        if (!title && hasName && (status == OITIBrowserStatusRunning || (status == OITIBrowserStatusFinished && !tracked))) {
            title = OITIBrowserSourceReadName(pid, serial);
            [sLog logLevel:1 tag:@"DOWNLOAD" format:@"browser source: file name for %@: %@", identifier, title ?: @"not available (will try again)"];
        }
        switch (status) {
            case OITIBrowserStatusRunning:
                OITIDownloadUpdateFraction(identifier, appName, title ?: @"Download", bundleID, fraction, NO, NO);
                sBrowserTrackedTitle = title;
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
                if (!tracked) OITIDownloadUpdateFraction(identifier, appName, title ?: @"Download", bundleID, 1.0, NO, NO);
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
    if (wanted) OITIBrowserSourceRegisterNameTokens();
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
