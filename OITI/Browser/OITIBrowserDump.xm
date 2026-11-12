// OITIBrowserDump.xm -- browser downloads: the Arc Search source (OITI 0.3.5) and the research log it grew out of.
//
// WHAT RUNS WHERE
//  * Arc Search (company.thebrowser.ArcMobile2): the SOURCE. While SpringBoard says "Show Arc Downloads" is on (libnotify state, see
//    OITIBrowserProtocol.h), the public WKDownload class is hooked (-setDelegate: to find downloads, -cancel: to see a cancel), the
//    newest download's public NSProgress is polled once a second, and its percentage and end are sent to SpringBoard
//    (OITIBrowserSource.xm turns that into the Island's download progress). Percentage only; the file name is planned for 0.3.6.
//  * Arc Search and Safari (com.apple.mobilesafari), only when the file OITIBrowserDump.enable exists in that app's Library folder:
//    the RESEARCH log (OITIBrowser.log in the same folder): what the public WKDownload does, a channel test, the public cancel and
//    resume calls. Safari is research only; it never publishes.
//  * Every other process: one string comparison against the allowlist, then return.
//
// WHAT IS KNOWN (measured on the iPhone 8 Plus, iOS 16.7.16, Arc Search 1.49.0, 10 Nov 2026; LEARNINGS.md)
//  * Arc uses the public WKDownload; its delegate is a private Swift class. -[WKDownload progress] is a public NSProgress: its total
//    is -1 for the first seconds (9 to 25 s in the runs), then the byte size; the fraction rises about once a second; at the end it
//    is 1 with isFinished. A cancel is -[WKDownload cancel:] (no completion handler) and the object is released within a second;
//    NSProgress.isCancelled was never seen. Arc also calls cancel: on a download about 17 s after it finished: that must not show
//    "cancelled". Arc has no pause button; pause and resume are not supported.
//  * A sandboxed app can set a libnotify state and post, and SpringBoard receives both (channel test, same day).
//
// Risk rules. OITI.plist loads this dylib into every UIKit app, so the code that runs in every process is the allowlist comparison.
// In Arc, load does one file-exists check and schedules the rest on the main queue after launch. No UIKit call is made, no private
// method is called, and nothing is written outside the app's own Library folder (research log only). The source is off unless the
// owner turned the setting on (the state defaults to 0 when SpringBoard has not set it).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <string.h>
#import <OITCore/OITCore.h>
#import "Shared/OITIShared.h"
#import "Browser/OITIBrowser.h"
#import "Browser/OITIBrowserProtocol.h"

static NSString * const kOITIBrowserBundleArc = @"company.thebrowser.ArcMobile2";
static NSString * const kOITIBrowserBundleSafari = @"com.apple.mobilesafari";
static NSString * const kOITIBrowserEnableFile = @"OITIBrowserDump.enable";
static NSString * const kOITIBrowserLogFile = @"OITIBrowser.log";
static NSString * const kOITIBrowserDumpNotification = @"com.wilburt.oiti/BrowserDump";           // posted by the owner: run the channel test
static NSString * const kOITIBrowserProbeNotification = @"com.wilburt.oiti/BrowserProbe";         // CF Darwin notification (no payload)
static NSString * const kOITIBrowserProbeStateName = @"com.wilburt.oiti/BrowserProbeState";       // libnotify name that carries a 64-bit state

#define OITI_BLOG(fmt, ...) [sBrowserLog logTag:@"BROWSER" format:fmt, ##__VA_ARGS__]

extern NSString * const kOITIBuildTag;

static OITLogger *sBrowserLog;                           // research log (nil unless the enable file exists)
static BOOL sBrowserIsArc;
static BOOL sBrowserSourceOn;                            // SpringBoard says "Show Arc Downloads" is on
static NSMapTable *sBrowserDownloads;                    // weak WKDownload -> state dictionary
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sBrowserKnown;   // pointer text -> state, to notice when a download object goes away
static NSTimer *sBrowserTimer;
static BOOL sBrowserProbeInstalled;
static NSUInteger sBrowserOrderCounter;                  // the newest download is the one that is published
static NSUInteger sBrowserNewestOrder;
static uint32_t sBrowserSerialCounter;
static int sBrowserStateToken = -1;                      // libnotify token for the download state we set
static int sBrowserEnabledToken;

// ---------------------------------------------------------------------------------------------
// MARK: Helpers
// ---------------------------------------------------------------------------------------------

// Calls a plain getter by name when the object answers it (a public property such as -progress). Nothing else is ever called.
static id OITIBrowserGetter(id object, const char *name) {
    if (!object) return nil;
    SEL selector = sel_registerName(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void OITIBrowserPostState(uint64_t value) {
    if (sBrowserStateToken < 0) {
        int token = 0;
        if (notify_register_check(OITI_BROWSER_DOWNLOAD_STATE_NAME, &token) != NOTIFY_STATUS_OK) return;
        sBrowserStateToken = token;
    }
    notify_set_state(sBrowserStateToken, value);
    notify_post(OITI_BROWSER_DOWNLOAD_STATE_NAME);
}

// ---------------------------------------------------------------------------------------------
// MARK: The public WKDownload class
// ---------------------------------------------------------------------------------------------

static void OITIBrowserNoteDownload(id download, id delegate);
static void OITIBrowserNoteCancel(id download, BOOL hasHandler);
static void OITIBrowserNoteResume(id webView, NSData *data, BOOL hasHandler);

%group OITIWKDownloadProbe
%hook WKDownload
- (void)setDelegate:(id)delegate {
    %orig;
    OITIBrowserNoteDownload((id)self, delegate);
}
%end
%end

// Public -[WKDownload cancel:]. Each group is installed only when the class answers the selector, because hooking a missing
// method would leave %orig empty.
%group OITIWKDownloadCancelProbe
%hook WKDownload
- (void)cancel:(id)completionHandler {
    OITIBrowserNoteCancel((id)self, completionHandler != nil);
    %orig;
}
%end
%end

// Public -[WKWebView resumeDownloadFromResumeData:completionHandler:]. Research log only (Arc has no pause button).
%group OITIWKWebViewResumeProbe
%hook WKWebView
- (void)resumeDownloadFromResumeData:(NSData *)resumeData completionHandler:(id)completionHandler {
    OITIBrowserNoteResume((id)self, resumeData, completionHandler != nil);
    %orig;
}
%end
%end

// Sends the state of one download to SpringBoard when it changed. Only the newest download is published, only while the source is on.
static void OITIBrowserPublishDownload(NSMutableDictionary *state, id download) {
    if (!sBrowserSourceOn || !sBrowserIsArc || !state) return;
    if ([state[@"done"] boolValue] || [state[@"order"] unsignedIntegerValue] != sBrowserNewestOrder) return;
    uint32_t serial = (uint32_t)[state[@"serial"] unsignedIntValue];
    uint32_t status = OITIBrowserStatusWaiting, value = 0;
    if ([state[@"cancelled"] boolValue]) {
        if (![state[@"published"] boolValue]) { state[@"done"] = @YES; return; }   // nothing was ever shown: nothing to cancel
        status = OITIBrowserStatusCancelled;
        value = (uint32_t)([state[@"lastFraction"] doubleValue] * 10000.0);
    } else {
        id progress = OITIBrowserGetter(download, "progress");
        if (![progress isKindOfClass:[NSProgress class]]) return;
        NSProgress *p = (NSProgress *)progress;
        if (p.isFinished || (p.totalUnitCount > 0 && p.completedUnitCount >= p.totalUnitCount)) {
            status = OITIBrowserStatusFinished;
            value = 10000;
            state[@"finished"] = @YES;
        } else if (p.totalUnitCount > 0) {
            double fraction = p.fractionCompleted;
            if (!isfinite(fraction)) return;
            fraction = MAX(0.0, MIN(0.9999, fraction));
            state[@"lastFraction"] = @(fraction);
            status = OITIBrowserStatusRunning;
            value = (uint32_t)(fraction * 10000.0 + 0.5);
        } else {
            return;   // no total yet (Arc reports -1 for the first seconds): nothing to show
        }
    }
    uint64_t message = OITIBrowserEncodeState((uint32_t)getpid(), serial, status, value);
    if ([state[@"lastMessage"] unsignedLongLongValue] == message && state[@"lastMessage"]) return;
    state[@"lastMessage"] = @(message);
    OITIBrowserPostState(message);
    if (status == OITIBrowserStatusRunning) state[@"published"] = @YES;
    if (status != OITIBrowserStatusRunning) state[@"done"] = @YES;
    OITI_BLOG(@"source: sent %@ for download %@ (serial %u, %u/10000)", status == OITIBrowserStatusRunning ? @"running" : (status == OITIBrowserStatusFinished ? @"finished" : @"cancelled"),
              state[@"id"], serial, value);
}

static void OITIBrowserPoll(void) {
    NSMutableDictionary<NSString *, NSNumber *> *live = [NSMutableDictionary dictionary];
    for (id download in sBrowserDownloads.keyEnumerator) {
        NSMutableDictionary *state = [sBrowserDownloads objectForKey:download];
        NSString *identifier = state[@"id"];
        if (!identifier) continue;
        live[identifier] = @YES;
        OITIBrowserPublishDownload(state, download);
        if (!sBrowserLog) continue;
        id progress = OITIBrowserGetter(download, "progress");
        if (![progress isKindOfClass:[NSProgress class]]) {
            if (![state[@"noProgress"] boolValue]) {
                state[@"noProgress"] = @YES;
                OITI_BLOG(@"WKDownload %@: no NSProgress (progress getter returned %@)", identifier, progress ? NSStringFromClass([progress class]) : @"nil");
            }
            continue;
        }
        NSProgress *p = (NSProgress *)progress;
        double fraction = p.fractionCompleted;
        long long done = p.completedUnitCount, total = p.totalUnitCount;
        int flags = (p.isFinished ? 1 : 0) | (p.isCancelled ? 2 : 0) | (p.isPaused ? 4 : 0);
        double last = [state[@"fraction"] doubleValue];
        BOOL first = state[@"fraction"] == nil;
        if (first || fabs(fraction - last) >= 0.01 || flags != [state[@"flags"] intValue] || total != [state[@"total"] longLongValue]) {
            state[@"fraction"] = @(fraction); state[@"flags"] = @(flags); state[@"total"] = @(total);
            OITI_BLOG(@"WKDownload %@ progress: fraction=%.4f units=%lld/%lld finished=%d cancelled=%d paused=%d kind=%@ (%@)",
                      identifier, fraction, done, total, (flags & 1) != 0, (flags & 2) != 0, (flags & 4) != 0,
                      p.kind ?: @"nil", NSStringFromClass([p class]));
        }
    }
    for (NSString *identifier in [sBrowserKnown allKeys]) {
        if (live[identifier]) continue;
        NSMutableDictionary *state = sBrowserKnown[identifier];
        // A download object that is gone without a finish and without a cancel call was lost (Arc dropped it, the transfer failed):
        // that ends the bar as cancelled, like a cancel.
        if (sBrowserSourceOn && ![state[@"done"] boolValue] && [state[@"published"] boolValue]) {
            state[@"cancelled"] = @YES;
            OITIBrowserPublishDownload(state, nil);
        }
        OITI_BLOG(@"WKDownload %@ released (the object is gone; last fraction=%@, flags=%@)", identifier,
                  state[@"fraction"] ?: @"?", state[@"flags"] ?: @"?");
        [sBrowserKnown removeObjectForKey:identifier];
    }
    if (sBrowserKnown.count == 0) {
        [sBrowserTimer invalidate];
        sBrowserTimer = nil;
    }
}

static void OITIBrowserNoteDownload(id download, id delegate) {
    if (!download || (!sBrowserLog && !sBrowserSourceOn)) return;
    if (!sBrowserDownloads) sBrowserDownloads = [NSMapTable weakToStrongObjectsMapTable];
    if (!sBrowserKnown) sBrowserKnown = [NSMutableDictionary dictionary];
    NSMutableDictionary *state = [sBrowserDownloads objectForKey:download];
    BOOL isNew = state == nil;
    if (isNew) {
        state = [NSMutableDictionary dictionary];
        state[@"id"] = [NSString stringWithFormat:@"%p", download];
        state[@"order"] = @(++sBrowserOrderCounter);
        state[@"serial"] = @((++sBrowserSerialCounter) & 0xFFu);
        sBrowserNewestOrder = sBrowserOrderCounter;
        [sBrowserDownloads setObject:state forKey:download];
        sBrowserKnown[state[@"id"]] = state;
    }
    if (sBrowserLog) {
        id request = OITIBrowserGetter(download, "originalRequest");
        NSURL *url = [request isKindOfClass:[NSURLRequest class]] ? ((NSURLRequest *)request).URL : nil;
        id progress = OITIBrowserGetter(download, "progress");
        OITI_BLOG(@"WKDownload %@ %@: delegate=%@ responds[downloadDidFinish=%d didFailWithError=%d decideDestination=%d] progress=%@ host=%@ extension=%@",
                  state[@"id"], isNew ? @"seen (setDelegate:)" : @"delegate set again",
                  delegate ? NSStringFromClass([delegate class]) : @"nil",
                  [delegate respondsToSelector:NSSelectorFromString(@"downloadDidFinish:")],
                  [delegate respondsToSelector:NSSelectorFromString(@"download:didFailWithError:resumeData:")],
                  [delegate respondsToSelector:NSSelectorFromString(@"download:decideDestinationUsingResponse:suggestedFilename:completionHandler:")],
                  progress ? NSStringFromClass([progress class]) : @"nil", url.host ?: @"?", url.pathExtension ?: @"");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sBrowserTimer) {
            sBrowserTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { OITIBrowserPoll(); }];
        }
    });
}

static void OITIBrowserNoteCancel(id download, BOOL hasHandler) {
    NSMutableDictionary *state = download ? [sBrowserDownloads objectForKey:download] : nil;
    id progress = OITIBrowserGetter(download, "progress");
    BOOL finished = [progress isKindOfClass:[NSProgress class]] && (((NSProgress *)progress).isFinished || [state[@"finished"] boolValue]);
    NSString *detail = [progress isKindOfClass:[NSProgress class]]
        ? [NSString stringWithFormat:@"fraction=%.4f units=%lld/%lld", ((NSProgress *)progress).fractionCompleted,
           ((NSProgress *)progress).completedUnitCount, ((NSProgress *)progress).totalUnitCount] : @"no progress";
    OITI_BLOG(@"WKDownload %@ cancel: called (completion handler %@); %@%@",
              state[@"id"] ?: [NSString stringWithFormat:@"%p", download], hasHandler ? @"given" : @"none", detail,
              finished ? @"; the download had finished, so this is not a cancel" : @"");
    if (!state || finished) return;   // Arc calls cancel: on a finished download too (seen 17 s after the end)
    state[@"cancelled"] = @YES;
    OITIBrowserPublishDownload(state, download);
}

static void OITIBrowserNoteResume(id webView, NSData *data, BOOL hasHandler) {
    OITI_BLOG(@"WKWebView resumeDownloadFromResumeData: called (resume data %lu bytes, completion handler %@)",
              (unsigned long)data.length, hasHandler ? @"given" : @"none");
}

// Installs the hooks once, when the public class exists. WebKit may not be loaded yet when the dylib loads, so this is tried when
// the source is switched on or the research starts, and again a few seconds later.
static void OITIBrowserInstallDownloadProbe(NSString *when) {
    if (sBrowserProbeInstalled) return;
    if (!objc_getClass("WKDownload")) {
        OITI_BLOG(@"WKDownload class is not loaded (%@)", when);
        return;
    }
    sBrowserProbeInstalled = YES;
    %init(OITIWKDownloadProbe);
    OITI_BLOG(@"WKDownload -setDelegate: hook installed (%@)", when);
    if (class_getInstanceMethod(objc_getClass("WKDownload"), NSSelectorFromString(@"cancel:"))) {
        %init(OITIWKDownloadCancelProbe);
        OITI_BLOG(@"WKDownload -cancel: hook installed");
    } else {
        OITI_BLOG(@"WKDownload does not answer cancel: (no hook)");
    }
    Class webViewClass = objc_getClass("WKWebView");
    if (sBrowserLog && webViewClass && class_getInstanceMethod(webViewClass, NSSelectorFromString(@"resumeDownloadFromResumeData:completionHandler:"))) {
        %init(OITIWKWebViewResumeProbe);
        OITI_BLOG(@"WKWebView -resumeDownloadFromResumeData:completionHandler: hook installed");
    }
}

static void OITIBrowserInstallWithRetries(NSString *when) {
    OITIBrowserInstallDownloadProbe(when);
    for (NSNumber *delay in @[@3, @15]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.intValue * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (sBrowserSourceOn || sBrowserLog) OITIBrowserInstallDownloadProbe([NSString stringWithFormat:@"%@ s later", delay]);
        });
    }
}

// ---------------------------------------------------------------------------------------------
// MARK: The switch from SpringBoard
// ---------------------------------------------------------------------------------------------

static void OITIBrowserSetSourceOn(BOOL on) {
    if (on == sBrowserSourceOn) return;
    sBrowserSourceOn = on;
    OITI_BLOG(@"source %@ (SpringBoard's \"Show Arc Downloads\" state)", on ? @"on" : @"off");
    if (on) OITIBrowserInstallWithRetries(@"source on");
}

static void OITIBrowserWatchSourceFlag(void) {
    // The flag is a libnotify state that SpringBoard sets; it is 0 (off) until SpringBoard sets it. Read it now and on every post.
    uint32_t status = notify_register_dispatch(OITI_BROWSER_SOURCE_ENABLED_NAME, &sBrowserEnabledToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) OITIBrowserSetSourceOn(state == 1);
    });
    if (status != NOTIFY_STATUS_OK) {
        OITI_BLOG(@"source: could not register for the flag (status %u); the source stays off", status);
        return;
    }
    uint64_t state = 0;
    if (notify_get_state(sBrowserEnabledToken, &state) == NOTIFY_STATUS_OK) OITIBrowserSetSourceOn(state == 1);
}

// ---------------------------------------------------------------------------------------------
// MARK: Research channel test: browser process -> SpringBoard (kept for Safari and for checks)
// ---------------------------------------------------------------------------------------------

static void OITIBrowserPostProbe(void) {
    static uint32_t sSequence;
    sSequence++;
    uint64_t value = ((uint64_t)getpid() << 32) | (0xA5000000u | (sSequence & 0xFFFFFFu));
    int token = 0;
    uint32_t registerStatus = notify_register_check(kOITIBrowserProbeStateName.UTF8String, &token);
    uint32_t stateStatus = registerStatus == NOTIFY_STATUS_OK ? notify_set_state(token, value) : 99;
    uint32_t postStatus = notify_post(kOITIBrowserProbeStateName.UTF8String);
    OITPostDarwinNotification(kOITIBrowserProbeNotification);
    if (registerStatus == NOTIFY_STATUS_OK) notify_cancel(token);
    OITI_BLOG(@"channel test #%u sent: libnotify register_check=%u set_state=%u post=%u (0 = ok) value=0x%llx; the plain Darwin notification %@ was posted too. SpringBoard should log both at DiagnosticsLevel 1 (grep BROWSER /tmp/OITIDebug.log)",
              sSequence, registerStatus, stateStatus, postStatus, value, kOITIBrowserProbeNotification);
}

// ---------------------------------------------------------------------------------------------
// MARK: Entry points
// ---------------------------------------------------------------------------------------------

void OITIBrowserStartIfAllowed(NSString *bundleID) {
    // Every process that is not SpringBoard gets here. The allowlist comparison comes first and is all that runs elsewhere.
    BOOL isArc = [bundleID isEqualToString:kOITIBrowserBundleArc];
    if (!isArc && ![bundleID isEqualToString:kOITIBrowserBundleSafari]) return;
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!library.length) return;
    BOOL research = [[NSFileManager defaultManager] fileExistsAtPath:[library stringByAppendingPathComponent:kOITIBrowserEnableFile]];
    if (!research && !isArc) return;   // Safari is research only
    sBrowserIsArc = isArc;

    if (research) {
        sBrowserLog = [OITLogger loggerWithName:@"oiti-browser" path:[library stringByAppendingPathComponent:kOITIBrowserLogFile]];
        sBrowserLog.level = 2;
        sBrowserLog.ignoredImageNames = @[@"OITI.dylib", @"OITCore.dylib"];
        [sBrowserLog logSessionStartWithBuildTag:kOITIBuildTag];
        OITI_BLOG(@"browser research dump is on in %@ (pid %d); log %@. Post %@ for the channel test.",
                  bundleID, getpid(), kOITIBrowserLogFile, kOITIBrowserDumpNotification);
        OITObserveDarwinNotification(kOITIBrowserDumpNotification, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                OITIBrowserInstallDownloadProbe(@"channel test request");
                OITIBrowserPostProbe();
            });
        });
    }
    // The rest runs on the main queue after launch, never in the load path.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (research) OITIBrowserInstallWithRetries(@"research");
        if (isArc) OITIBrowserWatchSourceFlag();
    });
}

void OITIBrowserProbeObserveInSpringBoard(void) {
    static BOOL sDone;
    static int sStateToken;
    if (sDone) return;
    sDone = YES;
    if (notify_register_check(kOITIBrowserProbeStateName.UTF8String, &sStateToken) != NOTIFY_STATUS_OK) sStateToken = 0;
    OITObserveDarwinNotification(kOITIBrowserProbeNotification, ^{
        if (![sLog isLoggingAtLevel:1]) return;
        uint64_t state = 0;
        uint32_t status = sStateToken ? notify_get_state(sStateToken, &state) : 99;
        [sLog logLevel:1 tag:@"BROWSER" format:@"channel test: the plain Darwin notification %@ arrived; libnotify state read status=%u value=0x%llx (pid %u)",
         kOITIBrowserProbeNotification, status, state, (unsigned)(state >> 32)];
    });
    static int sDispatchToken;
    notify_register_dispatch(kOITIBrowserProbeStateName.UTF8String, &sDispatchToken, dispatch_get_main_queue(), ^(int token) {
        if (![sLog isLoggingAtLevel:1]) return;
        uint64_t state = 0;
        uint32_t status = notify_get_state(token, &state);
        [sLog logLevel:1 tag:@"BROWSER" format:@"channel test: the libnotify notification %@ arrived; state status=%u value=0x%llx (pid %u)",
         kOITIBrowserProbeStateName, status, state, (unsigned)(state >> 32)];
    });
}
