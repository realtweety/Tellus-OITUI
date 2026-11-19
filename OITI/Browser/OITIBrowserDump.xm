// OITIBrowserDump.xm -- browser downloads: the Arc Search source (OITI 0.3.5), the Chrome source and the file name (OITI 0.3.6),
// the Safari source (OITI 0.3.7) and the research log they grew out of.
//
// WHAT RUNS WHERE
//  * Arc Search (company.thebrowser.ArcMobile2) and Chrome (com.google.chrome.ios, since 0.3.6): the SOURCES. While SpringBoard says
//    "Show Browser Downloads" is on (libnotify state, see OITIBrowserProtocol.h), the public WKDownload class is hooked
//    (-setDelegate: to find downloads, -cancel: to see a cancel), the newest download's public NSProgress is polled once a second, and
//    its percentage and end are sent to SpringBoard (OITIBrowserSource.xm turns that into the Island's download progress). Since
//    0.3.6 the message is protocol version 2 (browser ID) and the download's file name travels with it: the delegate's
//    -download:decideDestinationUsingResponse:suggestedFilename:completionHandler: is hooked on the delegate's class (it only stores
//    the name and calls the original), with the last path component of the request URL as the fallback. Both browsers were measured
//    on 13 Nov 2026 (LEARNINGS.md); Chrome cancels its first WKDownload of a link at once (before any progress), which is never
//    published (nothing was ever shown, so there is nothing to cancel).
//  * Arc Search, Safari (com.apple.mobilesafari) and Chrome (com.google.chrome.ios), only when the file OITIBrowserDump.enable exists
//    in that app's Library folder: the RESEARCH log (OITIBrowser.log in the same folder): what the public WKDownload does, a channel
//    test, the public cancel and resume calls.
//  * Safari (com.apple.mobilesafari), since 0.3.7: a SOURCE too, but not through WKDownload (Safari does not call it). While SpringBoard
//    says "Show Browser Downloads" is on, the private _SFDownloadDispatcher's download calls are hooked (see "Safari source" below;
//    private API, matched by selector and encoding, otherwise nothing is hooked) and the newest download is published like Arc's.
//    0.3.6 batch 1 adds to the research log (nothing is published, nothing is shown in the Island): (1) a census of the loaded
//    Objective-C classes whose name contains "download" (Safari does not use the public WKDownload, 12 Nov 2026, so this is how its
//    own download classes are found), run 8 s after launch and again on every channel test; (2) the file name a download delegate
//    is given (-download:decideDestinationUsingResponse:suggestedFilename:completionHandler: is hooked on the delegate's class, only
//    to log it and call the original); (3) the file name transport test: the channel test also publishes a sample name in the
//    eight name chunks (OITIBrowserProtocol.h, version 2) and SpringBoard logs what it read back at DiagnosticsLevel 1.
//    0.3.6 batch 2 adds, in Safari only: a log-only probe of Safari's private download classes (OITIBrowserInstallSafariProbe).
//    0.3.7 batch 1 turns that probe into the Safari source and adds to its log: the first argument and the thread of every call,
//    and what the download's web view says about its data store; the Safari source (0.3.7 batch 3) does not show a Private Browsing
//    download (a download whose web view's data store is not persistent) or one it cannot tell from one.
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
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import <OITCore/OITCore.h>
#import "Shared/OITIShared.h"
#import "Browser/OITIBrowser.h"
#import "Browser/OITIBrowserProtocol.h"

static NSString * const kOITIBrowserBundleArc = @"company.thebrowser.ArcMobile2";
static NSString * const kOITIBrowserBundleSafari = @"com.apple.mobilesafari";
static NSString * const kOITIBrowserBundleChrome = @"com.google.chrome.ios";
static NSString * const kOITIBrowserEnableFile = @"OITIBrowserDump.enable";
static NSString * const kOITIBrowserLogFile = @"OITIBrowser.log";
static NSString * const kOITIBrowserDumpNotification = @"com.wilburt.oiti/BrowserDump";           // posted by the owner: run the channel test
static NSString * const kOITIBrowserProbeNotification = @"com.wilburt.oiti/BrowserProbe";         // CF Darwin notification (no payload)
static NSString * const kOITIBrowserProbeStateName = @"com.wilburt.oiti/BrowserProbeState";       // libnotify name that carries a 64-bit state

#define OITI_BLOG(fmt, ...) [sBrowserLog logTag:@"BROWSER" format:fmt, ##__VA_ARGS__]

extern NSString * const kOITIBuildTag;

static OITLogger *sBrowserLog;                           // research log (nil unless the enable file exists)
static uint32_t sBrowserID;                              // OITIBrowserID* of this process (Arc, Safari or Chrome)
static BOOL sBrowserSourceOn;                            // SpringBoard says "Show Browser Downloads" is on
static BOOL sBrowserSafariInstalled;                     // the Safari research probe is installed
static int sBrowserNameTokens[OITI_BROWSER_NAME_CHUNK_COUNT];
static BOOL sBrowserNameTokensReady;
static NSMapTable *sBrowserDownloads;                    // weak WKDownload -> state dictionary
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sBrowserKnown;   // pointer text -> state, to notice when a download object goes away
static NSTimer *sBrowserTimer;
static BOOL sBrowserProbeInstalled;
static NSUInteger sBrowserOrderCounter;                  // the newest download is the one that is published
static NSUInteger sBrowserNewestOrder;
static uint32_t sBrowserSerialCounter;
static int sBrowserStateToken = -1;                      // libnotify token for the download state we set
static int sBrowserEnabledToken;
static NSMutableSet<NSString *> *sBrowserHookedDelegates;   // delegate class names whose destination method is hooked (research)
static BOOL sBrowserCensusRunning;                          // main queue only

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

static BOOL OITIBrowserIsPublisher(void) {
    return sBrowserID == OITIBrowserIDArc || sBrowserID == OITIBrowserIDChrome || sBrowserID == OITIBrowserIDSafari;
}

// Publishes a download's file name in the eight name chunks (OITIBrowserProtocol.h) before the message that says a name exists.
static void OITIBrowserPostName(NSData *utf8, uint32_t serial) {
    if (!sBrowserNameTokensReady) {
        sBrowserNameTokensReady = YES;
        for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
            int token = 0;
            sBrowserNameTokens[i] = notify_register_check(OITIBrowserNameChunkName(i), &token) == NOTIFY_STATUS_OK ? token : -1;
        }
    }
    uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT];
    uint32_t length = (uint32_t)MIN(utf8.length, (NSUInteger)4096);
    uint32_t packed = OITIBrowserPackName((const char *)utf8.bytes, length, (uint32_t)getpid(), serial, chunks);
    unsigned failures = 0;
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
        if (sBrowserNameTokens[i] < 0 || notify_set_state(sBrowserNameTokens[i], chunks[i]) != NOTIFY_STATUS_OK) failures++;
    }
    OITI_BLOG(@"source: name published (serial %u, %u of %u bytes, %u failures)", serial, packed, length, failures);
}

// Sends the state of one download to SpringBoard when it changed. Only the newest download is published, only while the source is on.
static void OITIBrowserPublishDownload(NSMutableDictionary *state, id download) {
    if (!sBrowserSourceOn || !OITIBrowserIsPublisher() || !state) return;
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
    NSString *name = [state[@"name"] isKindOfClass:[NSString class]] ? state[@"name"] : nil;
    NSData *nameBytes = name.length ? [name dataUsingEncoding:NSUTF8StringEncoding] : nil;
    BOOL hasName = nameBytes.length > 0;
    uint64_t message = OITIBrowserEncodeStateV2((uint32_t)getpid(), sBrowserID, hasName, serial, status, value);
    if (message == 0) {
        if (![state[@"badMessage"] boolValue]) {
            state[@"badMessage"] = @YES;
            OITI_BLOG(@"source: the pid %d or the browser ID %u cannot be encoded; nothing is sent for download %@", getpid(), sBrowserID, state[@"id"]);
        }
        return;
    }
    if ([state[@"lastMessage"] unsignedLongLongValue] == message && state[@"lastMessage"]) return;
    if (hasName && ![state[@"nameSent"] boolValue]) {
        OITIBrowserPostName(nameBytes, serial);   // before the message that says a name exists
        state[@"nameSent"] = @YES;
    }
    state[@"lastMessage"] = @(message);
    OITIBrowserPostState(message);
    if (status == OITIBrowserStatusRunning) state[@"published"] = @YES;
    if (status != OITIBrowserStatusRunning) state[@"done"] = @YES;
    OITI_BLOG(@"source: sent %@ for download %@ (serial %u, %u/10000, name %@)", status == OITIBrowserStatusRunning ? @"running" : (status == OITIBrowserStatusFinished ? @"finished" : @"cancelled"),
              state[@"id"], serial, value, hasName ? name : @"none");
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

// The file name a download delegate is given. Called from the hook below, then the original runs. The name is kept in the
// download's state for the source (published with the first message); the research log also gets the arguments.
static void OITIBrowserNoteDestination(id download, id response, id suggestedFilename) {
    NSString *name = [suggestedFilename isKindOfClass:[NSString class]] ? (NSString *)suggestedFilename : nil;
    NSMutableDictionary *state = download ? [sBrowserDownloads objectForKey:download] : nil;
    if (state && name.length) state[@"name"] = [name copy];
    if (!sBrowserLog) return;
    NSString *responseName = nil, *mime = nil;
    long long expected = -1;
    if ([response isKindOfClass:[NSURLResponse class]]) {
        NSURLResponse *urlResponse = (NSURLResponse *)response;
        responseName = urlResponse.suggestedFilename;
        mime = urlResponse.MIMEType;
        expected = urlResponse.expectedContentLength;
    }
    id request = OITIBrowserGetter(download, "originalRequest");
    NSURL *url = [request isKindOfClass:[NSURLRequest class]] ? ((NSURLRequest *)request).URL : nil;
    OITI_BLOG(@"WKDownload %@ destination: suggestedFilename=%@ (%lu chars, %lu UTF-8 bytes) response.suggestedFilename=%@ mime=%@ expectedContentLength=%lld urlLastComponent=%@",
              state[@"id"] ?: [NSString stringWithFormat:@"%p", download], name ?: @"(none)", (unsigned long)name.length,
              (unsigned long)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], responseName ?: @"(none)", mime ?: @"?", expected,
              url.lastPathComponent ?: @"?");
}

// Hooks -download:decideDestinationUsingResponse:suggestedFilename:completionHandler: on the class of a download's delegate, once per
// class, while the research log or the source is on. The hook stores the name (and logs the arguments) and calls the original with
// the same arguments. Browsers whose delegate does not implement the method, or answers with another shape, are logged and left alone
// (the file name is then the last path component of the request URL, see OITIBrowserNoteDownload).
static void OITIBrowserHookDestination(id delegate) {
    if ((!sBrowserLog && !sBrowserSourceOn) || !delegate) return;
    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    if (!sBrowserHookedDelegates) sBrowserHookedDelegates = [NSMutableSet set];
    if ([sBrowserHookedDelegates containsObject:className]) return;
    [sBrowserHookedDelegates addObject:className];
    SEL selector = NSSelectorFromString(@"download:decideDestinationUsingResponse:suggestedFilename:completionHandler:");
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (!method) {
        OITI_BLOG(@"destination hook: %@ does not implement the destination method (no hook)", className);
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || method_getNumberOfArguments(method) != 6) {
        OITI_BLOG(@"destination hook: %@ answers the destination method with %u arguments, encoding %s (no hook)", className,
                  method_getNumberOfArguments(method), encoding ?: "(none)");
        return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id download, id response, id suggestedFilename, id completionHandler) {
        @try {
            OITIBrowserNoteDestination(download, response, suggestedFilename);
        } @catch (NSException *exception) {
            OITI_BLOG(@"destination hook: exception %@: %@", exception.name, exception.reason);
        }
        ((void (*)(id, SEL, id, id, id, id))original)(receiver, selector, download, response, suggestedFilename, completionHandler);
    });
    class_replaceMethod(delegateClass, selector, replacement, encoding);
    OITI_BLOG(@"destination hook installed on %@ (encoding %s)", className, encoding);
}

// The class census (research log only): which loaded Objective-C classes have "download" in their name, and which of their methods
// look related. Runs on a utility queue (it walks every loaded image); only reads class and method names, calls nothing in them.
// Safari does not call the public WKDownload (12 Nov 2026), so this is the way to find what it uses.
static BOOL OITIBrowserNameHasWord(const char *name, const char *const *words) {
    for (; *words; words++) if (strcasestr(name, *words)) return YES;
    return NO;
}

static void OITIBrowserRunCensus(NSString *when) {
    if (!sBrowserLog) return;
    if (sBrowserCensusRunning) {
        OITI_BLOG(@"census (%@) skipped: one is already running", when);
        return;
    }
    sBrowserCensusRunning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static const char *const kClassWords[] = {"download", NULL};
        static const char *const kMethodWords[] = {"download", "progress", "cancel", "pause", "resume", "filename", "bytes", NULL};
        const NSUInteger kMaxClasses = 120, kMaxNamesPerImage = 40, kMaxMethodClasses = 60, kMaxSelectors = 24;
        uint32_t imageCount = _dyld_image_count();
        NSUInteger withoutClasses = 0, totalClasses = 0, imagesWithHits = 0;
        NSMutableArray<NSArray<NSString *> *> *found = [NSMutableArray array];   // @[class name, image path]
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path) continue;
            unsigned int count = 0;
            const char **names = objc_copyClassNamesForImage(path, &count);
            if (!names) { withoutClasses++; continue; }
            totalClasses += count;
            NSMutableArray<NSString *> *hits = [NSMutableArray array];
            for (unsigned int j = 0; j < count; j++) {
                if (!OITIBrowserNameHasWord(names[j], kClassWords)) continue;
                [hits addObject:[NSString stringWithUTF8String:names[j]] ?: @"(not UTF-8)"];
            }
            free(names);
            if (!hits.count) continue;
            imagesWithHits++;
            NSString *imagePath = [NSString stringWithUTF8String:path] ?: @"?";
            NSArray<NSString *> *shown = hits.count > kMaxNamesPerImage ? [hits subarrayWithRange:NSMakeRange(0, kMaxNamesPerImage)] : hits;
            OITI_BLOG(@"census (%@) image %@: %u classes, %lu with \"download\"%@: %@", when, imagePath, count, (unsigned long)hits.count,
                      hits.count > shown.count ? @" (first 40 shown)" : @"", [shown componentsJoinedByString:@", "]);
            for (NSString *name in hits) if (found.count < kMaxClasses) [found addObject:@[name, imagePath]];
        }
        OITI_BLOG(@"census (%@) summary: %u images, %lu without Objective-C classes, %lu classes in all, \"download\" classes in %lu images (%lu kept for the method list)",
                  when, imageCount, (unsigned long)withoutClasses, (unsigned long)totalClasses, (unsigned long)imagesWithHits, (unsigned long)found.count);
        NSUInteger listed = 0;
        for (NSArray<NSString *> *entry in found) {
            if (listed++ >= kMaxMethodClasses) break;
            Class cls = objc_getClass(entry[0].UTF8String);
            if (!cls) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            NSMutableArray<NSString *> *related = [NSMutableArray array];
            for (unsigned int k = 0; k < methodCount && related.count < kMaxSelectors; k++) {
                const char *selectorName = sel_getName(method_getName(methods[k]));
                if (selectorName && OITIBrowserNameHasWord(selectorName, kMethodWords)) [related addObject:[NSString stringWithUTF8String:selectorName] ?: @"?"];
            }
            free(methods);
            Class superclass = class_getSuperclass(cls);
            OITI_BLOG(@"census (%@) class %@ (super %@): %u instance methods; related: %@", when, entry[0],
                      superclass ? NSStringFromClass(superclass) : @"(none)", methodCount, related.count ? [related componentsJoinedByString:@", "] : @"(none)");
        }
        OITI_BLOG(@"census (%@) done", when);
        dispatch_async(dispatch_get_main_queue(), ^{ sBrowserCensusRunning = NO; });
    });
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
    id request = OITIBrowserGetter(download, "originalRequest");
    NSURL *url = [request isKindOfClass:[NSURLRequest class]] ? ((NSURLRequest *)request).URL : nil;
    if (isNew && url.lastPathComponent.length) state[@"name"] = url.lastPathComponent;   // fallback; the delegate's suggested name replaces it
    if (sBrowserLog) {
        id progress = OITIBrowserGetter(download, "progress");
        OITI_BLOG(@"WKDownload %@ %@: delegate=%@ responds[downloadDidFinish=%d didFailWithError=%d decideDestination=%d] progress=%@ host=%@ extension=%@ lastComponent=%@",
                  state[@"id"], isNew ? @"seen (setDelegate:)" : @"delegate set again",
                  delegate ? NSStringFromClass([delegate class]) : @"nil",
                  [delegate respondsToSelector:NSSelectorFromString(@"downloadDidFinish:")],
                  [delegate respondsToSelector:NSSelectorFromString(@"download:didFailWithError:resumeData:")],
                  [delegate respondsToSelector:NSSelectorFromString(@"download:decideDestinationUsingResponse:suggestedFilename:completionHandler:")],
                  progress ? NSStringFromClass([progress class]) : @"nil", url.host ?: @"?", url.pathExtension ?: @"", url.lastPathComponent ?: @"?");
    }
    OITIBrowserHookDestination(delegate);
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

// ---------------------------------------------------------------------------------------------
// MARK: Safari research (log only): the calls of Safari's private download classes
// ---------------------------------------------------------------------------------------------

// Safari does not use the public WKDownload (12 Nov 2026). The class census of 13 Nov 2026 found, in SafariServices, _SFDownload (it
// has -filename, -estimatedProgress, -bytesLoaded, -progress, -cancel, and the six _download... selectors below), _SFDownloadDispatcher
// (the same selectors) and _SFDownloadManager (-downloads, -runningDownloadsCount). The probe of 15 Nov 2026 measured when the
// selectors are called (LEARNINGS.md). The hooks below log each call (only with the enable file) and call the original with the same
// arguments; on the dispatcher they also feed the Safari source (only while the switch is on). Private API: a selector is hooked
// only when its encoding matches exactly, so another iOS version either works the same way or hooks nothing.

static NSString *OITIBrowserDescribeObject(id object) {
    if (!object) return @"nil";
    if ([object isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"\"%@\"", object];
    if ([object isKindOfClass:[NSError class]]) return [NSString stringWithFormat:@"NSError %@ %ld", ((NSError *)object).domain, (long)((NSError *)object).code];
    if ([object isKindOfClass:[NSURLResponse class]]) {
        NSURLResponse *response = (NSURLResponse *)object;
        return [NSString stringWithFormat:@"%@ mime=%@ expected=%lld suggestedFilename=%@", NSStringFromClass([object class]), response.MIMEType ?: @"?",
                response.expectedContentLength, response.suggestedFilename ?: @"?"];
    }
    return [NSString stringWithFormat:@"%@ %p", NSStringFromClass([object class]), object];
}

// What a _SFDownload says about itself at the moment of a call (public-looking getters found by the census), through KVC so that any
// scalar type is boxed; an unknown key is caught.
static NSString *OITIBrowserDescribeSafariDownload(id receiver) {
    if (![NSStringFromClass([receiver class]) isEqualToString:@"_SFDownload"]) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"filename", @"estimatedProgress", @"bytesLoaded"]) {
        id value = nil;
        @try { value = [receiver valueForKey:key]; } @catch (NSException *exception) { value = [NSString stringWithFormat:@"(exception %@)", exception.name]; }
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value ?: @"nil"]];
    }
    id progress = nil;
    @try { progress = [receiver valueForKey:@"progress"]; } @catch (NSException *exception) { progress = nil; }
    if ([progress isKindOfClass:[NSProgress class]]) {
        NSProgress *p = (NSProgress *)progress;
        [parts addObject:[NSString stringWithFormat:@"progress=%@ %lld/%lld finished=%d cancelled=%d", NSStringFromClass([p class]), p.completedUnitCount, p.totalUnitCount, p.isFinished, p.isCancelled]];
    } else {
        [parts addObject:[NSString stringWithFormat:@"progress=%@", progress ? NSStringFromClass([progress class]) : @"nil"]];
    }
    return [NSString stringWithFormat:@" [%@]", [parts componentsJoinedByString:@" "]];
}

static BOOL OITIBrowserArgumentIs(Method method, unsigned index, const char *types) {
    char *type = method_copyArgumentType(method, index);
    if (!type) return NO;
    BOOL ok = type[0] != 0 && strchr(types, type[0]) != NULL;
    free(type);
    return ok;
}

// ---------------------------------------------------------------------------------------------
// MARK: Safari source (0.3.7): the newest download of MobileSafari, from the dispatcher's calls
// ---------------------------------------------------------------------------------------------
//
// Measured on 15 Nov 2026 (LEARNINGS.md "Safari's download calls, measured"): every download event arrives at the one global
// _SFDownloadDispatcher, whose first argument is the _WKDownload (confirmed for -_downloadDidStart:; for the other selectors the
// research line now logs the argument, 0.3.7 batch 1, because the source keys every event on it). The source keeps ONE record, the
// newest download, in a small struct under an os_unfair_lock (measured on 18 Nov 2026: every call comes on the main thread, main=1;
// the lock stays, it costs nothing). The hot call, -_download:didWriteData:..., only stores two integers; once a second a timer on the main
// run loop turns the record into a protocol v2 message (browser ID Safari), exactly as the Arc and Chrome path does. Except for
// the one check when a download begins (Private Browsing, below), a download object's pointer is only compared, never dereferenced and
// never retained here.
//
// Rules: the newest started download is the one shown; a write for a download that was not announced (the switch was turned on
// mid-download) is adopted only when nothing is running (its name is then unknown, so the Island says "Download"); finish, cancel,
// failure and a crash of the download process all end the record (failure and crash show as cancelled, UNVERIFIED: neither was seen
// in the measurement); a download that ends before anything was shown shows nothing, except a finish, which shows the finished state.
// Nothing is published without a positive expected size. Private Browsing (batch 3): when a download begins (start, or the first
// destination or write that is seen for it), its web view's data store is read once (OITISafariPersistence); a download that is not
// from a persistent store, or whose web view cannot be read, is put in a small ring of hidden downloads and never shown or adopted; a
// visible download that is already running is not disturbed by it. Fail-closed: not knowing hides.

enum { kSFNone = 0, kSFStart, kSFFinish, kSFCancel, kSFCrash, kSFFail, kSFResponse, kSFDestination, kSFWrite };

typedef struct {
    uintptr_t download;        // identity of the _WKDownload (never dereferenced)
    NSUInteger order;          // 0 = nothing yet; counts up with every download that is begun
    uint32_t serial;           // low 8 bits travel in the message
    int phase;                 // 0 idle, 1 running, 2 finished, 3 cancelled (also failed or crashed)
    long long written;         // bytes written so far (totalBytesWritten)
    long long expected;        // totalBytesExpectedToWrite (0 or less: unknown)
} OITISafariRecord;

static os_unfair_lock sSafariLock = OS_UNFAIR_LOCK_INIT;
static OITISafariRecord sSafariRecord;      // under sSafariLock
static NSString *sSafariName;               // under sSafariLock; the file name of the record, nil until -decideDestination
static NSUInteger sSafariOrderCounter;      // under sSafariLock
static uintptr_t sSafariHidden[8];          // under sSafariLock: downloads that are never shown (Private Browsing, or not known to be normal); a small ring
static unsigned sSafariHiddenNext;          // under sSafariLock
// Main thread only: what was already sent for the record with order sSafariPubOrder.
static NSUInteger sSafariPubOrder;
static BOOL sSafariPubPublished, sSafariPubNameSent, sSafariPubDone, sSafariPubBadLogged, sSafariPubHasLast;
static uint64_t sSafariPubLastMessage;
static double sSafariPubLastFraction;
static NSTimer *sSafariTimer;

static void OITISafariStopTimer(void) {
    [sSafariTimer invalidate];
    sSafariTimer = nil;
}

// Turns the record into one message when something changed. Main thread only.
static void OITISafariPublish(void) {
    if (!sBrowserSourceOn) { OITISafariStopTimer(); return; }
    OITISafariRecord snap;
    NSString *name;
    os_unfair_lock_lock(&sSafariLock);
    snap = sSafariRecord;
    name = sSafariName;
    os_unfair_lock_unlock(&sSafariLock);
    if (snap.order == 0) { OITISafariStopTimer(); return; }
    if (snap.order != sSafariPubOrder) {
        sSafariPubOrder = snap.order;
        sSafariPubPublished = sSafariPubNameSent = sSafariPubDone = sSafariPubBadLogged = sSafariPubHasLast = NO;
        sSafariPubLastMessage = 0;
        sSafariPubLastFraction = 0;
    }
    if (sSafariPubDone) { OITISafariStopTimer(); return; }
    uint32_t status = OITIBrowserStatusWaiting, value = 0;
    if (snap.phase == 3) {
        if (!sSafariPubPublished) {   // nothing was ever shown: nothing to cancel
            sSafariPubDone = YES;
            OITISafariStopTimer();
            if (sBrowserLog) OITI_BLOG(@"Safari source: download %lu ended as cancelled before anything was shown; nothing is sent", (unsigned long)snap.order);
            return;
        }
        status = OITIBrowserStatusCancelled;
        value = (uint32_t)(sSafariPubLastFraction * 10000.0);
    } else if (snap.phase == 2) {
        status = OITIBrowserStatusFinished;
        value = 10000;
    } else if (snap.phase == 1) {
        if (snap.expected <= 0 || snap.written < 0) return;   // no total yet: nothing to show
        double fraction = (double)snap.written / (double)snap.expected;
        fraction = MAX(0.0, MIN(0.9999, fraction));
        sSafariPubLastFraction = fraction;
        status = OITIBrowserStatusRunning;
        value = (uint32_t)(fraction * 10000.0 + 0.5);
    } else {
        return;
    }
    NSData *nameBytes = name.length ? [name dataUsingEncoding:NSUTF8StringEncoding] : nil;
    BOOL hasName = nameBytes.length > 0;
    uint64_t message = OITIBrowserEncodeStateV2((uint32_t)getpid(), sBrowserID, hasName, snap.serial, status, value);
    if (message == 0) {
        if (!sSafariPubBadLogged) {
            sSafariPubBadLogged = YES;
            OITI_BLOG(@"Safari source: the pid %d or the browser ID %u cannot be encoded; nothing is sent", getpid(), sBrowserID);
        }
        return;
    }
    if (sSafariPubHasLast && sSafariPubLastMessage == message) return;
    if (hasName && !sSafariPubNameSent) {
        OITIBrowserPostName(nameBytes, snap.serial);   // before the message that says a name exists
        sSafariPubNameSent = YES;
    }
    sSafariPubHasLast = YES;
    sSafariPubLastMessage = message;
    OITIBrowserPostState(message);
    if (status == OITIBrowserStatusRunning) {
        sSafariPubPublished = YES;
    } else {
        sSafariPubDone = YES;
        OITISafariStopTimer();
    }
    if (sBrowserLog) {
        OITI_BLOG(@"Safari source: sent %@ for download %lu (serial %u, %u/10000, name %@)",
                  status == OITIBrowserStatusRunning ? @"running" : (status == OITIBrowserStatusFinished ? @"finished" : @"cancelled"),
                  (unsigned long)snap.order, snap.serial, value, hasName ? name : @"none");
    }
}

// Starts the one-second timer if needed and publishes at once (so a finish or a cancel does not wait for the next tick).
static void OITISafariKick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sBrowserSourceOn) return;
        if (!sSafariTimer) {
            sSafariTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { OITISafariPublish(); }];
            [[NSRunLoop mainRunLoop] addTimer:sSafariTimer forMode:NSRunLoopCommonModes];
        }
        OITISafariPublish();
    });
}

// Forgets the record (the switch went off). Main thread.
static void OITISafariReset(void) {
    os_unfair_lock_lock(&sSafariLock);
    memset(&sSafariRecord, 0, sizeof sSafariRecord);
    memset(sSafariHidden, 0, sizeof sSafariHidden);
    sSafariName = nil;
    os_unfair_lock_unlock(&sSafariLock);
    OITISafariStopTimer();
    sSafariPubOrder = 0;
}

// The hidden ring: caller holds sSafariLock. key is never 0.
static BOOL OITISafariIsHiddenLocked(uintptr_t key) {
    for (unsigned i = 0; i < 8; i++) if (sSafariHidden[i] == key) return YES;
    return NO;
}

static void OITISafariHideLocked(uintptr_t key) {
    if (!OITISafariIsHiddenLocked(key)) sSafariHidden[sSafariHiddenNext++ & 7u] = key;
}

static void OITISafariUnhideLocked(uintptr_t key) {
    for (unsigned i = 0; i < 8; i++) if (sSafariHidden[i] == key) sSafariHidden[i] = 0;
}

// Whether the download's web view uses a persistent data store: 1 a normal tab, 0 Private Browsing, -1 cannot tell (`why` says why).
// Measured on 18 Nov 2026 (iOS 16.7.16, the research log of 0.3.7 batch 1): -[_WKDownload originatingWebView] answers with a
// _SFWebView, and its configuration.websiteDataStore.isPersistent was 1 for a normal tab and 0 for a private one; every dispatcher call
// came on the main thread. The public getters are called through the runtime; any other answer is "cannot tell", which is hidden.
static int OITISafariPersistence(id download, NSString **why) {
    if (!download) { *why = @"no download object"; return -1; }
    if (![NSThread isMainThread]) { *why = @"not on the main thread"; return -1; }
    @try {
        SEL webViewSelector = sel_registerName("originatingWebView");
        if (![download respondsToSelector:webViewSelector]) { *why = @"the download has no originatingWebView"; return -1; }
        id webView = ((id (*)(id, SEL))objc_msgSend)(download, webViewSelector);
        if (!webView) { *why = @"originatingWebView is nil"; return -1; }
        id configuration = OITIBrowserGetter(webView, "configuration");
        id store = OITIBrowserGetter(configuration, "websiteDataStore");
        SEL persistentSelector = sel_registerName("isPersistent");
        if (!store || ![store respondsToSelector:persistentSelector]) { *why = @"no websiteDataStore.isPersistent"; return -1; }
        return ((BOOL (*)(id, SEL))objc_msgSend)(store, persistentSelector) ? 1 : 0;
    } @catch (NSException *exception) {
        *why = [NSString stringWithFormat:@"%@ thrown", exception.name];
        return -1;
    }
}

// Starts tracking `download` as the newest one, unless it is a Private Browsing download or cannot be told from one: then it is put in the
// hidden ring, the record (a normal download that is already running) stays as it is, and NO is returned. Main thread (the dispatcher's calls).
static BOOL OITISafariBegin(uintptr_t key, id download, const char *why, NSString *name) {
    NSString *reason = nil;
    int persistence = OITISafariPersistence(download, &reason);
    if (persistence != 1) {
        os_unfair_lock_lock(&sSafariLock);
        OITISafariHideLocked(key);
        os_unfair_lock_unlock(&sSafariLock);
        if (sBrowserLog) {
            OITI_BLOG(@"Safari source: download hidden (%@; %s; object %p)",
                      persistence == 0 ? @"Private Browsing: the data store is not persistent" : [NSString stringWithFormat:@"cannot tell whether it is private (%@), hidden to be safe", reason],
                      why, (void *)key);
        }
        return NO;
    }
    uint32_t serial;
    NSUInteger order;
    os_unfair_lock_lock(&sSafariLock);
    OITISafariUnhideLocked(key);
    order = ++sSafariOrderCounter;
    serial = (++sBrowserSerialCounter) & 0xFFu;
    sSafariRecord = (OITISafariRecord){key, order, serial, 1, 0, 0};
    sSafariName = name.length ? name : nil;
    os_unfair_lock_unlock(&sSafariLock);
    if (sBrowserLog) OITI_BLOG(@"Safari source: download %lu begun (%s; serial %u; object %p)", (unsigned long)order, why, serial, (void *)key);
    OITISafariKick();
    return YES;
}

// One dispatcher call. `extra` is the second argument for the destination (the suggested file name), `total` and `expected` come with a write.
// Called before the original runs; it never throws and keeps the work small.
static void OITISafariEvent(int kind, id download, id extra, long long total, long long expected) {
    uintptr_t key = (uintptr_t)(__bridge void *)download;
    if (!key) return;
    switch (kind) {
        case kSFStart: {
            os_unfair_lock_lock(&sSafariLock);
            BOOL same = sSafariRecord.download == key && sSafariRecord.phase == 1;
            os_unfair_lock_unlock(&sSafariLock);
            if (!same) OITISafariBegin(key, download, "start", nil);
            break;
        }
        case kSFDestination: {
            NSString *name = [extra isKindOfClass:[NSString class]] ? [(NSString *)extra copy] : nil;
            BOOL begin = NO, named = NO;
            os_unfair_lock_lock(&sSafariLock);
            if (sSafariRecord.download != key) {
                begin = !OITISafariIsHiddenLocked(key);   // a download whose start was not seen (a hidden one stays hidden)
            } else if (sSafariRecord.phase == 1 && name.length) {
                sSafariName = name;
                named = YES;
            }
            os_unfair_lock_unlock(&sSafariLock);
            BOOL began = begin ? OITISafariBegin(key, download, "destination, no start seen", name) : NO;
            if ((began || named) && sBrowserLog) OITI_BLOG(@"Safari source: file name %@", name ?: @"(none)");
            break;
        }
        case kSFWrite: {
            BOOL adopt = NO;
            os_unfair_lock_lock(&sSafariLock);
            if (sSafariRecord.download == key) {
                if (sSafariRecord.phase == 1) { sSafariRecord.written = total; sSafariRecord.expected = expected; }
            } else if (sSafariRecord.phase != 1) {
                adopt = !OITISafariIsHiddenLocked(key);   // nothing is running and this download was not announced (a hidden one stays hidden)
            }
            os_unfair_lock_unlock(&sSafariLock);
            if (adopt && OITISafariBegin(key, download, "write, no start seen", nil)) {
                os_unfair_lock_lock(&sSafariLock);
                if (sSafariRecord.download == key) { sSafariRecord.written = total; sSafariRecord.expected = expected; }
                os_unfair_lock_unlock(&sSafariLock);
            }
            break;
        }
        case kSFFinish:
        case kSFCancel:
        case kSFCrash:
        case kSFFail: {
            BOOL mine = NO;
            os_unfair_lock_lock(&sSafariLock);
            if (sSafariRecord.download == key && sSafariRecord.phase == 1) {
                sSafariRecord.phase = kind == kSFFinish ? 2 : 3;
                mine = YES;
            }
            os_unfair_lock_unlock(&sSafariLock);
            if (mine) {
                if (sBrowserLog) OITI_BLOG(@"Safari source: the download ended (%@)", kind == kSFFinish ? @"finished" : (kind == kSFCancel ? @"cancelled" : (kind == kSFFail ? @"failed, shown as cancelled" : @"process crash, shown as cancelled")));
                OITISafariKick();
            }
            break;
        }
        default:
            break;
    }
}

// Research only (log): whether the download's web view uses a persistent data store (false would mean Private Browsing). Public
// WKWebView/WKWebViewConfiguration/WKWebsiteDataStore getters through the runtime; the web view of a _WKDownload comes from
// -originatingWebView, which is recalled from WebKit's SPI headers and NOT verified here (the log says whether it answered).
static NSString *OITIBrowserDescribeWebViewStore(id webView) {
    if (!webView) return @"webView=nil";
    if (![NSThread isMainThread]) return @"webView=(not read: not on the main thread)";
    id configuration = OITIBrowserGetter(webView, "configuration");
    id store = OITIBrowserGetter(configuration, "websiteDataStore");
    SEL persistentSelector = sel_registerName("isPersistent");
    if (!store || ![store respondsToSelector:persistentSelector]) return [NSString stringWithFormat:@"webView=%@ store=%@ (no isPersistent)", NSStringFromClass([webView class]), store ? NSStringFromClass([store class]) : @"nil"];
    BOOL persistent = ((BOOL (*)(id, SEL))objc_msgSend)(store, persistentSelector);
    return [NSString stringWithFormat:@"webView=%@ store=%@ persistent=%d", NSStringFromClass([webView class]), NSStringFromClass([store class]), persistent];
}

static void OITIBrowserLogSafariOrigin(id download) {
    if (!sBrowserLog || !download) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SEL selector = sel_registerName("originatingWebView");
            if (![download respondsToSelector:selector]) {
                OITI_BLOG(@"Safari probe: the _WKDownload %p does not answer originatingWebView", (__bridge void *)download);
                return;
            }
            id webView = ((id (*)(id, SEL))objc_msgSend)(download, selector);
            OITI_BLOG(@"Safari probe: _WKDownload %p originatingWebView -> %@", (__bridge void *)download, OITIBrowserDescribeWebViewStore(webView));
        } @catch (NSException *exception) {
            OITI_BLOG(@"Safari probe: originating web view lookup threw %@", exception.name);
        }
    });
}

// shape 1: (id); 2: (id, id); 3: (id, id, id); 4: (id, int64, int64, int64); 5: (id, BOOL). A selector of another shape is logged and
// left alone. `kind` says which source event it is (kSFNone: log only); the source reacts only on the dispatcher, never on _SFDownload.
static void OITIBrowserHookSafariSelector(Class cls, const char *name, int shape, int kind) {
    NSString *className = NSStringFromClass(cls);
    BOOL source = kind != kSFNone && [className isEqualToString:@"_SFDownloadDispatcher"];
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) {
        OITI_BLOG(@"Safari probe: -[%@ %s] does not exist (no hook)", className, name);
        return;
    }
    unsigned expectedArguments = shape == 1 ? 3 : (shape == 2 ? 4 : (shape == 3 ? 5 : (shape == 4 ? 6 : 4)));
    char *returnType = method_copyReturnType(method);
    BOOL returnsVoid = returnType && returnType[0] == 'v';
    free(returnType);
    BOOL fits = returnsVoid && method_getNumberOfArguments(method) == expectedArguments && OITIBrowserArgumentIs(method, 2, "@");
    if (shape >= 2 && shape <= 3) fits = fits && OITIBrowserArgumentIs(method, 3, "@");
    if (shape == 3) fits = fits && OITIBrowserArgumentIs(method, 4, "@");
    if (shape == 4) fits = fits && OITIBrowserArgumentIs(method, 3, "qQ") && OITIBrowserArgumentIs(method, 4, "qQ") && OITIBrowserArgumentIs(method, 5, "qQ");
    if (shape == 5) fits = fits && OITIBrowserArgumentIs(method, 3, "Bc");
    const char *encoding = method_getTypeEncoding(method);
    if (!fits || !encoding) {
        OITI_BLOG(@"Safari probe: -[%@ %s] has another shape (encoding %s); no hook", className, name, encoding ?: "(none)");
        return;
    }
    SEL selector = method_getName(method);
    IMP original = method_getImplementation(method);
    IMP replacement = NULL;
    NSString *selectorText = [NSString stringWithUTF8String:name];
    switch (shape) {
        case 1: {
            replacement = imp_implementationWithBlock(^(id receiver, id a) {
                if (source && sBrowserSourceOn) OITISafariEvent(kind, a, nil, 0, 0);
                if (sBrowserLog) {
                    OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p arg=%@%@ main=%d", className, selectorText, receiver, OITIBrowserDescribeObject(a), OITIBrowserDescribeSafariDownload(receiver), [NSThread isMainThread]);
                    if (source && kind == kSFStart) OITIBrowserLogSafariOrigin(a);
                }
                ((void (*)(id, SEL, id))original)(receiver, selector, a);
            });
            break;
        }
        case 2: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, id b) {
                if (source && sBrowserSourceOn) OITISafariEvent(kind, a, b, 0, 0);
                if (sBrowserLog) {
                    NSString *store = kind == kSFNone ? [@" " stringByAppendingString:OITIBrowserDescribeWebViewStore(a)] : @"";
                    OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p args=%@, %@%@%@ main=%d", className, selectorText, receiver, OITIBrowserDescribeObject(a), OITIBrowserDescribeObject(b), store, OITIBrowserDescribeSafariDownload(receiver), [NSThread isMainThread]);
                }
                ((void (*)(id, SEL, id, id))original)(receiver, selector, a, b);
            });
            break;
        }
        case 3: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, id b, id c) {
                if (source && sBrowserSourceOn) OITISafariEvent(kind, a, b, 0, 0);
                if (sBrowserLog) {
                    OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p args=%@, %@, completion handler %@%@ main=%d", className, selectorText, receiver, OITIBrowserDescribeObject(a),
                              OITIBrowserDescribeObject(b), c ? @"given" : @"none", OITIBrowserDescribeSafariDownload(receiver), [NSThread isMainThread]);
                }
                ((void (*)(id, SEL, id, id, id))original)(receiver, selector, a, b, c);
            });
            break;
        }
        case 4: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, long long written, long long total, long long expected) {
                // The hot call (about every 64 KB): with the log off and the source on this is a pointer compare and two stores under a lock.
                if (source && sBrowserSourceOn) OITISafariEvent(kind, a, nil, total, expected);
                if (sBrowserLog) {
                    static CFAbsoluteTime sLast;
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - sLast >= 1.0) {   // about once a second, like the progress lines of the public hooks
                        sLast = now;
                        OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p arg=%@ written=%lld totalWritten=%lld totalExpected=%lld%@ main=%d", className, selectorText, receiver, OITIBrowserDescribeObject(a),
                                  written, total, expected, OITIBrowserDescribeSafariDownload(receiver), [NSThread isMainThread]);
                    }
                }
                ((void (*)(id, SEL, id, long long, long long, long long))original)(receiver, selector, a, written, total, expected);
            });
            break;
        }
        default: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, BOOL flag) {
                if (sBrowserLog) {
                    OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p arg=%@ flag=%d main=%d", className, selectorText, receiver, OITIBrowserDescribeObject(a), flag, [NSThread isMainThread]);
                }
                ((void (*)(id, SEL, id, BOOL))original)(receiver, selector, a, flag);
            });
            break;
        }
    }
    class_replaceMethod(cls, selector, replacement, encoding);
    OITI_BLOG(@"Safari probe: -[%@ %@] hooked (encoding %s%s)", className, selectorText, encoding, source ? ", source" : "");
}

// Instance methods and instance variables of one class, once, so that the next step can be designed from the log.
static void OITIBrowserLogClassDetail(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) { OITI_BLOG(@"Safari probe: class %s is not loaded", className); return; }
    unsigned int methodCount = 0, ivarCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < methodCount && names.count < 100; i++) [names addObject:[NSString stringWithUTF8String:sel_getName(method_getName(methods[i]))] ?: @"?"];
    free(methods);
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    NSMutableArray<NSString *> *ivarNames = [NSMutableArray array];
    for (unsigned int i = 0; i < ivarCount && ivarNames.count < 50; i++) {
        const char *ivarName = ivar_getName(ivars[i]);
        const char *ivarType = ivar_getTypeEncoding(ivars[i]);
        [ivarNames addObject:[NSString stringWithFormat:@"%s:%s", ivarName ?: "?", ivarType ?: "?"]];
    }
    free(ivars);
    OITI_BLOG(@"Safari probe: class %s: %u instance methods (first %lu): %@", className, methodCount, (unsigned long)names.count, [names componentsJoinedByString:@", "]);
    OITI_BLOG(@"Safari probe: class %s: %u instance variables (first %lu): %@", className, ivarCount, (unsigned long)ivarNames.count, [ivarNames componentsJoinedByString:@", "]);
}

static void OITIBrowserInstallSafariProbe(NSString *when) {
    // Since 0.3.7 this installs for the source (flag on) as well as for the research log. Installed once; the hooks stay, and each
    // call checks sBrowserSourceOn / sBrowserLog first, so they do nothing while both are off.
    if (sBrowserSafariInstalled || sBrowserID != OITIBrowserIDSafari) return;
    if (!sBrowserLog && !sBrowserSourceOn) return;
    BOOL haveDispatcher = objc_getClass("_SFDownloadDispatcher") != NULL;
    if (!haveDispatcher && (!sBrowserLog || !objc_getClass("_SFDownload"))) {
        OITI_BLOG(@"Safari probe: the private download classes are not loaded (%@)", when);
        return;
    }
    sBrowserSafariInstalled = YES;
    OITI_BLOG(@"Safari probe: installing (%@; log %d, source %d)", when, sBrowserLog != nil, sBrowserSourceOn);
    if (sBrowserLog) {
        OITIBrowserLogClassDetail("_SFDownload");
        OITIBrowserLogClassDetail("_SFDownloadManager");
        OITIBrowserLogClassDetail("_SFDownloadDispatcher");
    }
    // `dispatcherOnly`: the two entry-point selectors exist only on the dispatcher (census, 13 Nov 2026); they are log only.
    static const struct { const char *selector; int shape; int kind; BOOL dispatcherOnly; } kSelectors[] = {
        {"_downloadDidStart:", 1, kSFStart, NO}, {"_downloadDidFinish:", 1, kSFFinish, NO}, {"_downloadDidCancel:", 1, kSFCancel, NO},
        {"_downloadProcessDidCrash:", 1, kSFCrash, NO},
        {"_download:didFailWithError:", 2, kSFFail, NO}, {"_download:didReceiveResponse:", 2, kSFResponse, NO},
        {"_download:decideDestinationWithSuggestedFilename:completionHandler:", 3, kSFDestination, NO},
        {"_download:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:", 4, kSFWrite, NO},
        {"startDownloadFromWebView:URL:", 2, kSFNone, YES}, {"downloadFromWKDownload:userInitiatedAction:", 5, kSFNone, YES}
    };
    static const char *const kClasses[] = {"_SFDownload", "_SFDownloadDispatcher"};
    for (unsigned c = 0; c < sizeof kClasses / sizeof kClasses[0]; c++) {
        BOOL isDispatcher = c == 1;
        if (!isDispatcher && !sBrowserLog) continue;   // the source needs the dispatcher only
        Class cls = objc_getClass(kClasses[c]);
        if (!cls) continue;
        for (unsigned i = 0; i < sizeof kSelectors / sizeof kSelectors[0]; i++) {
            if (kSelectors[i].dispatcherOnly && (!isDispatcher || !sBrowserLog)) continue;
            OITIBrowserHookSafariSelector(cls, kSelectors[i].selector, kSelectors[i].shape, kSelectors[i].kind);
        }
    }
}

// Installs the hooks once, when the public class exists. WebKit may not be loaded yet when the dylib loads, so this is tried when
// the source is switched on or the research starts, and again a few seconds later.
static void OITIBrowserInstallDownloadProbe(NSString *when) {
    OITIBrowserInstallSafariProbe(when);   // Safari only (source and research log); a no-op elsewhere
    // Safari does not call the public WKDownload (12 Nov 2026) and has its own source above: no WKDownload hooks there, so that a
    // download can never be published twice.
    if (sBrowserID == OITIBrowserIDSafari) return;
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
    OITI_BLOG(@"source %@ (SpringBoard's \"Show Browser Downloads\" state)", on ? @"on" : @"off");
    if (!on && sBrowserID == OITIBrowserIDSafari) OITISafariReset();
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

// The file name transport test (0.3.6): publishes a sample name in the eight chunks, before the main probe state is set and posted.
// The sample is long enough to be cut and holds multi-byte characters; SpringBoard logs what it read back (DiagnosticsLevel 1).
static void OITIBrowserPostProbeName(uint32_t serial) {
    static const char kSample[] = "OITI-test caf\xC3\xA9 \xE3\x83\x95\xE3\x82\xA1\xE3\x82\xA4\xE3\x83\xAB \xE2\x9C\x93 long-file-name-for-the-transport-test.tar.gz";
    uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT];
    uint32_t packed = OITIBrowserPackName(kSample, (uint32_t)(sizeof kSample - 1), (uint32_t)getpid(), serial, chunks);
    unsigned failures = 0;
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
        int token = 0;
        if (notify_register_check(OITIBrowserNameChunkName(i), &token) != NOTIFY_STATUS_OK) { failures++; continue; }
        if (notify_set_state(token, chunks[i]) != NOTIFY_STATUS_OK) failures++;
        notify_cancel(token);
    }
    OITI_BLOG(@"name test: %u of %lu bytes packed in %u chunk states (%u failures); SpringBoard should log what it read at DiagnosticsLevel 1",
              packed, (unsigned long)(sizeof kSample - 1), OITI_BROWSER_NAME_CHUNK_COUNT, failures);
}

static void OITIBrowserPostProbe(void) {
    static uint32_t sSequence;
    sSequence++;
    OITIBrowserPostProbeName(sSequence & 0xFFu);
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
    BOOL isChrome = !isArc && [bundleID isEqualToString:kOITIBrowserBundleChrome];
    BOOL isSafari = !isArc && !isChrome && [bundleID isEqualToString:kOITIBrowserBundleSafari];
    if (!isArc && !isChrome && !isSafari) return;
    BOOL publisher = YES;   // Arc, Chrome and (since 0.3.7) Safari all publish; the allowlist above already returned for every other app
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!library.length) return;
    BOOL research = [[NSFileManager defaultManager] fileExistsAtPath:[library stringByAppendingPathComponent:kOITIBrowserEnableFile]];
    sBrowserID = isArc ? OITIBrowserIDArc : (isChrome ? OITIBrowserIDChrome : OITIBrowserIDSafari);

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
                OITIBrowserRunCensus(@"channel test");
            });
        });
    }
    // The rest runs on the main queue after launch, never in the load path.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (research) OITIBrowserInstallWithRetries(@"research");
        if (publisher) OITIBrowserWatchSourceFlag();
    });
    if (research) {
        // 8 s after launch: the frameworks a browser loads lazily are mostly in by then. Again on every channel test (below).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ OITIBrowserRunCensus(@"8 s after launch"); });
    }
}

// SpringBoard side of the name transport test: reads the eight chunk states the browser set before it posted the probe, and logs
// what came out (level 1). The tokens are registered the first time a probe arrives, never at launch.
static void OITIBrowserLogProbeName(uint64_t probeState) {
    static int sNameTokens[OITI_BROWSER_NAME_CHUNK_COUNT];
    static BOOL sNameTokensReady;
    if (!sNameTokensReady) {
        sNameTokensReady = YES;
        for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
            if (notify_register_check(OITIBrowserNameChunkName(i), &sNameTokens[i]) != NOTIFY_STATUS_OK) sNameTokens[i] = -1;
        }
    }
    uint64_t chunks[OITI_BROWSER_NAME_CHUNK_COUNT];
    unsigned readFailures = 0;
    for (unsigned i = 0; i < OITI_BROWSER_NAME_CHUNK_COUNT; i++) {
        chunks[i] = 0;
        if (sNameTokens[i] < 0 || notify_get_state(sNameTokens[i], &chunks[i]) != NOTIFY_STATUS_OK) readFailures++;
    }
    uint32_t pid = (uint32_t)(probeState >> 32), serial = (uint32_t)(probeState & 0xFFu);
    char name[OITI_BROWSER_NAME_MAX_BYTES + 1];
    int length = OITIBrowserUnpackName(chunks, pid, serial, name, sizeof name);
    NSString *text = length > 0 ? [[NSString alloc] initWithBytes:name length:(NSUInteger)length encoding:NSUTF8StringEncoding] : nil;
    [sLog logLevel:1 tag:@"BROWSER" format:@"name test: pid %u serial %u: read failures=%u header=0x%llx length=%d valid UTF-8=%d name=%@",
     pid, serial, readFailures, chunks[0], length, text != nil, text ?: @"(none)"];
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
        if (status == NOTIFY_STATUS_OK) OITIBrowserLogProbeName(state);
    });
}
