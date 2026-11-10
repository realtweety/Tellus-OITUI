// OITIBrowserDump.xm -- research for browser downloads in Download Progress (OITI 0.3.5, batch 1). Logging only.
//
// Goal: learn from the phone how Arc Search (company.thebrowser.ArcMobile2) and Safari (com.apple.mobilesafari) report a download,
// and whether a browser process can reach SpringBoard (where the Island and the download tracker live). Nothing is assumed:
//  * Outside SpringBoard the browser's own progress UI is the only thing we know about. iOS 16 browsers (outside the EU) use
//    WebKit, and WebKit has a public download API (WKDownload, iOS 14.5, with a public NSProgress). WHETHER Arc or Safari use it
//    is exactly what this dump finds out; Safari in particular may use something internal.
//  * So the dump does three things, all read-only. (1) (Removed in batch 2: a census of class names, it stopped Arc twice.)
//    (2) A passive probe: if the public WKDownload class exists, its -setDelegate: is hooked and the download's public NSProgress
//    is polled once a second and logged when it changes; batch 2 adds logging of the public -[WKDownload cancel:] and
//    -[WKWebView resumeDownloadFromResumeData:completionHandler:]. (3) A channel test: the
//    browser process posts a plain Darwin notification and a libnotify notification with a 64-bit state; SpringBoard logs what
//    arrives (OITIBrowserProbeObserveInSpringBoard). Whether a sandboxed app is allowed to do this is unverified.
//
// Risk rules. OITI.plist already loads this dylib into every UIKit app, so the code that runs in every process is one string
// comparison against the allowlist. For an allowlisted browser nothing happens unless the owner created the enable file in that
// app's tmp folder (COMMANDS.md, section 23), so a normal install runs no hook and no observer in any browser. No UIKit call is
// made at load time, no private method is called, nothing is written outside the app's own tmp folder.
//
// Log: <the app's tmp folder>/OITIBrowser.log (an app cannot write /tmp). Reference: DIAGNOSTICS.md, "Browser research".

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <string.h>
#import <OITCore/OITCore.h>
#import "Shared/OITIShared.h"
#import "Browser/OITIBrowser.h"

static NSString * const kOITIBrowserBundleArc = @"company.thebrowser.ArcMobile2";
static NSString * const kOITIBrowserBundleSafari = @"com.apple.mobilesafari";
static NSString * const kOITIBrowserEnableFile = @"OITIBrowserDump.enable";
static NSString * const kOITIBrowserLogFile = @"OITIBrowser.log";
static NSString * const kOITIBrowserDumpNotification = @"com.wilburt.oiti/BrowserDump";           // posted by the owner: run the channel test
static NSString * const kOITIBrowserProbeNotification = @"com.wilburt.oiti/BrowserProbe";         // CF Darwin notification (no payload)
static NSString * const kOITIBrowserProbeStateName = @"com.wilburt.oiti/BrowserProbeState";       // libnotify name that carries a 64-bit state

#define OITI_BLOG(fmt, ...) [sBrowserLog logTag:@"BROWSER" format:fmt, ##__VA_ARGS__]

static OITLogger *sBrowserLog;
static NSMapTable *sBrowserDownloads;                    // weak WKDownload -> state dictionary (the pointer text and the last logged values)
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sBrowserKnown;   // pointer text -> state, to notice when a download object goes away
static NSTimer *sBrowserTimer;
static BOOL sBrowserProbeInstalled;

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

// ---------------------------------------------------------------------------------------------
// MARK: Passive probe: the public WKDownload class
// ---------------------------------------------------------------------------------------------

static void OITIBrowserNoteDownload(id download, id delegate);

%group OITIWKDownloadProbe
%hook WKDownload
- (void)setDelegate:(id)delegate {
    %orig;
    OITIBrowserNoteDownload((id)self, delegate);
}
%end
%end

static void OITIBrowserNoteCancel(id download, BOOL hasHandler);
static void OITIBrowserNoteResume(id webView, NSData *data, BOOL hasHandler);

// Public -[WKDownload cancel:] (the pause of a download that can resume goes through it with resume data) and public
// -[WKWebView resumeDownloadFromResumeData:completionHandler:). Logging only; each group is installed only when the class
// answers the selector, because hooking a missing method would leave %orig empty.
%group OITIWKDownloadCancelProbe
%hook WKDownload
- (void)cancel:(id)completionHandler {
    OITIBrowserNoteCancel((id)self, completionHandler != nil);
    %orig;
}
%end
%end

%group OITIWKWebViewResumeProbe
%hook WKWebView
- (void)resumeDownloadFromResumeData:(NSData *)resumeData completionHandler:(id)completionHandler {
    OITIBrowserNoteResume((id)self, resumeData, completionHandler != nil);
    %orig;
}
%end
%end

static void OITIBrowserPoll(void) {
    NSMutableDictionary<NSString *, NSNumber *> *live = [NSMutableDictionary dictionary];
    for (id download in sBrowserDownloads.keyEnumerator) {
        NSMutableDictionary *state = [sBrowserDownloads objectForKey:download];
        NSString *identifier = state[@"id"];
        if (!identifier) continue;
        live[identifier] = @YES;
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
        OITI_BLOG(@"WKDownload %@ released (the object is gone; last fraction=%@, flags=%@)", identifier,
                  sBrowserKnown[identifier][@"fraction"] ?: @"?", sBrowserKnown[identifier][@"flags"] ?: @"?");
        [sBrowserKnown removeObjectForKey:identifier];
    }
    if (sBrowserKnown.count == 0) {
        [sBrowserTimer invalidate];
        sBrowserTimer = nil;
    }
}

static void OITIBrowserNoteDownload(id download, id delegate) {
    if (!sBrowserLog || !download) return;
    if (!sBrowserDownloads) sBrowserDownloads = [NSMapTable weakToStrongObjectsMapTable];
    if (!sBrowserKnown) sBrowserKnown = [NSMutableDictionary dictionary];
    NSMutableDictionary *state = [sBrowserDownloads objectForKey:download];
    BOOL isNew = state == nil;
    if (isNew) {
        state = [NSMutableDictionary dictionary];
        state[@"id"] = [NSString stringWithFormat:@"%p", download];
        [sBrowserDownloads setObject:state forKey:download];
        sBrowserKnown[state[@"id"]] = state;
    }
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
    if (!sBrowserTimer) {
        sBrowserTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { OITIBrowserPoll(); }];
    }
}

static void OITIBrowserNoteCancel(id download, BOOL hasHandler) {
    NSMutableDictionary *state = download ? [sBrowserDownloads objectForKey:download] : nil;
    id progress = OITIBrowserGetter(download, "progress");
    NSString *detail = [progress isKindOfClass:[NSProgress class]]
        ? [NSString stringWithFormat:@"fraction=%.4f units=%lld/%lld", ((NSProgress *)progress).fractionCompleted,
           ((NSProgress *)progress).completedUnitCount, ((NSProgress *)progress).totalUnitCount] : @"no progress";
    OITI_BLOG(@"WKDownload %@ cancel: called (completion handler %@; it receives the resume data); %@",
              state[@"id"] ?: [NSString stringWithFormat:@"%p", download], hasHandler ? @"given" : @"none", detail);
}

static void OITIBrowserNoteResume(id webView, NSData *data, BOOL hasHandler) {
    OITI_BLOG(@"WKWebView resumeDownloadFromResumeData: called (resume data %lu bytes, completion handler %@)",
              (unsigned long)data.length, hasHandler ? @"given" : @"none");
}

// Installs the hook once, when the public class exists. WebKit may not be loaded yet when the dylib loads, so this is tried at
// start, 3 s later and at every channel test request.
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
    if (webViewClass && class_getInstanceMethod(webViewClass, NSSelectorFromString(@"resumeDownloadFromResumeData:completionHandler:"))) {
        %init(OITIWKWebViewResumeProbe);
        OITI_BLOG(@"WKWebView -resumeDownloadFromResumeData:completionHandler: hook installed");
    } else {
        OITI_BLOG(@"WKWebView does not answer resumeDownloadFromResumeData:completionHandler: (no hook)");
    }
}

// The census of batch 1 (a walk over every Objective-C class with class_getImageName and class_copyMethodList) is gone: it was posted
// twice in Arc Search 1.49.0 and the app stopped both times right after the first line (cause unknown: the class walk is the
// suspect). What it was for is answered by the live probe: Arc uses the public WKDownload (LEARNINGS.md).

// ---------------------------------------------------------------------------------------------
// MARK: Channel test: browser process -> SpringBoard
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

void OITIBrowserDumpStartIfAllowed(NSString *bundleID) {
    // Every process that is not SpringBoard gets here. The allowlist comparison comes first and is all that runs elsewhere.
    if (![bundleID isEqualToString:kOITIBrowserBundleArc] && ![bundleID isEqualToString:kOITIBrowserBundleSafari]) return;
    NSString *tmp = NSTemporaryDirectory();
    if (!tmp.length) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[tmp stringByAppendingPathComponent:kOITIBrowserEnableFile]]) return;

    sBrowserLog = [OITLogger loggerWithName:@"oiti-browser" path:[tmp stringByAppendingPathComponent:kOITIBrowserLogFile]];
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
    OITIBrowserInstallDownloadProbe(@"load");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OITIBrowserInstallDownloadProbe(@"3 s after load");
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
