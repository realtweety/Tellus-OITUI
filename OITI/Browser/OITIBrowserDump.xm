// OITIBrowserDump.xm -- research for browser downloads in Download Progress (OITI 0.3.5, batch 1). Logging only.
//
// Goal: learn from the phone how Arc Search (company.thebrowser.ArcMobile2) and Safari (com.apple.mobilesafari) report a download,
// and whether a browser process can reach SpringBoard (where the Island and the download tracker live). Nothing is assumed:
//  * Outside SpringBoard the browser's own progress UI is the only thing we know about. iOS 16 browsers (outside the EU) use
//    WebKit, and WebKit has a public download API (WKDownload, iOS 14.5, with a public NSProgress). WHETHER Arc or Safari use it
//    is exactly what this dump finds out; Safari in particular may use something internal.
//  * So the dump does three things, all read-only. (1) A census, on request: the names of classes and methods that contain
//    "download" (names only, nothing is called). (2) A passive probe: if the public WKDownload class exists, its -setDelegate: is
//    hooked and the download's public NSProgress is polled once a second and logged when it changes. (3) A channel test: the
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
static NSString * const kOITIBrowserDumpNotification = @"com.wilburt.oiti/BrowserDump";           // posted by the owner: run the census and the channel test
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

// Installs the hook once, when the public class exists. WebKit may not be loaded yet when the dylib loads, so this is tried at
// start, 3 s later and at every census request.
static void OITIBrowserInstallDownloadProbe(NSString *when) {
    if (sBrowserProbeInstalled) return;
    if (!objc_getClass("WKDownload")) {
        OITI_BLOG(@"WKDownload class is not loaded (%@)", when);
        return;
    }
    sBrowserProbeInstalled = YES;
    %init(OITIWKDownloadProbe);
    OITI_BLOG(@"WKDownload -setDelegate: hook installed (%@)", when);
}

// ---------------------------------------------------------------------------------------------
// MARK: Census (names only, nothing is called)
// ---------------------------------------------------------------------------------------------

static void OITIBrowserRunCensus(NSString *bundleID) {
    NSBundle *main = [NSBundle mainBundle];
    OITI_BLOG(@"census: bundle=%@ version=%@ build=%@ executable=%@ WKDownload=%d WKDownloadDelegate protocol=%d WKNavigationDelegate protocol=%d",
              bundleID, [main objectForInfoDictionaryKey:@"CFBundleShortVersionString"], [main objectForInfoDictionaryKey:@"CFBundleVersion"],
              main.executablePath.lastPathComponent, objc_getClass("WKDownload") != NULL, objc_getProtocol("WKDownloadDelegate") != NULL,
              objc_getProtocol("WKNavigationDelegate") != NULL);
    const char *appPath = main.bundlePath.fileSystemRepresentation;
    size_t appPathLength = appPath ? strlen(appPath) : 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (unsigned int i = 0; i < count && lines.count < 600; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        const char *image = class_getImageName(classes[i]);
        BOOL inApp = image && appPathLength && strncmp(image, appPath, appPathLength) == 0;
        BOOL hasDownload = strcasestr(name, "download") != NULL;
        BOOL appProgress = inApp && (strcasestr(name, "progress") != NULL || strcasestr(name, "transfer") != NULL);
        if (!hasDownload && !appProgress) continue;
        NSMutableString *line = [NSMutableString stringWithFormat:@"class %s [%@]%@", name,
                                 image ? [@(image) lastPathComponent] : @"?", inApp ? @" (in the app)" : @""];
        BOOL listMethods = inApp || strncmp(name, "WKDownload", 10) == 0 || strncmp(name, "_WKDownload", 11) == 0 ||
                           (image && strcasestr(image, "Safari") != NULL);
        if (listMethods) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(classes[i], &methodCount);
            int shown = 0;
            for (unsigned int m = 0; m < methodCount && shown < 40; m++) {
                const char *selectorName = sel_getName(method_getName(methods[m]));
                if (strcasestr(selectorName, "ownload") || strcasestr(selectorName, "progress") || strcasestr(selectorName, "fractionCompleted")) {
                    [line appendFormat:@"\n    - %s", selectorName];
                    shown++;
                }
            }
            if (methods) free(methods);
        }
        [lines addObject:line];
    }
    if (classes) free(classes);
    [lines sortUsingSelector:@selector(compare:)];
    OITI_BLOG(@"census: %lu classes match (names containing download, plus progress or transfer inside the app)", (unsigned long)lines.count);
    for (NSUInteger i = 0; i < lines.count; i += 12) {
        NSUInteger length = MIN((NSUInteger)12, lines.count - i);
        OITI_BLOG(@"census classes %lu-%lu:\n%@", (unsigned long)(i + 1), (unsigned long)(i + length),
                  [[lines subarrayWithRange:NSMakeRange(i, length)] componentsJoinedByString:@"\n"]);
    }
}

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
    OITI_BLOG(@"browser research dump is on in %@ (pid %d); log %@. Post %@ for the census and the channel test.",
              bundleID, getpid(), kOITIBrowserLogFile, kOITIBrowserDumpNotification);

    OITObserveDarwinNotification(kOITIBrowserDumpNotification, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            OITIBrowserInstallDownloadProbe(@"census request");
            OITIBrowserRunCensus(bundleID);
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
