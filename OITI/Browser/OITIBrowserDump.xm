// OITIBrowserDump.xm -- browser downloads: the Arc Search source (OITI 0.3.5), the Chrome source and the file name (OITI 0.3.6),
// and the research log they grew out of.
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
//    test, the public cancel and resume calls. Safari is research only; it never publishes.
//    0.3.6 batch 1 adds to the research log (nothing is published, nothing is shown in the Island): (1) a census of the loaded
//    Objective-C classes whose name contains "download" (Safari does not use the public WKDownload, 12 Nov 2026, so this is how its
//    own download classes are found), run 8 s after launch and again on every channel test; (2) the file name a download delegate
//    is given (-download:decideDestinationUsingResponse:suggestedFilename:completionHandler: is hooked on the delegate's class, only
//    to log it and call the original); (3) the file name transport test: the channel test also publishes a sample name in the
//    eight name chunks (OITIBrowserProtocol.h, version 2) and SpringBoard logs what it read back at DiagnosticsLevel 1.
//    0.3.6 batch 2 adds, in Safari only: a log-only probe of Safari's private download classes (OITIBrowserInstallSafariProbe).
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
    return sBrowserID == OITIBrowserIDArc || sBrowserID == OITIBrowserIDChrome;   // Safari is research only
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
// (the same selectors) and _SFDownloadManager (-downloads, -runningDownloadsCount). Nothing is known yet about when these selectors
// are called or with what, so this logs each call and calls the original with the same arguments. Private API: it is research only
// (Safari, only with the enable file) and is not part of any release until the log shows it is the right source.

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

// shape 1: (id); 2: (id, id); 3: (id, id, id); 4: (id, int64, int64, int64). A selector of another shape is logged and left alone.
static void OITIBrowserHookSafariSelector(Class cls, const char *name, int shape) {
    NSString *className = NSStringFromClass(cls);
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) {
        OITI_BLOG(@"Safari probe: -[%@ %s] does not exist (no hook)", className, name);
        return;
    }
    unsigned expectedArguments = shape == 1 ? 3 : (shape == 2 ? 4 : (shape == 3 ? 5 : 6));
    char *returnType = method_copyReturnType(method);
    BOOL returnsVoid = returnType && returnType[0] == 'v';
    free(returnType);
    BOOL fits = returnsVoid && method_getNumberOfArguments(method) == expectedArguments && OITIBrowserArgumentIs(method, 2, "@");
    if (shape >= 2 && shape <= 3) fits = fits && OITIBrowserArgumentIs(method, 3, "@");
    if (shape == 3) fits = fits && OITIBrowserArgumentIs(method, 4, "@");
    if (shape == 4) fits = fits && OITIBrowserArgumentIs(method, 3, "qQ") && OITIBrowserArgumentIs(method, 4, "qQ") && OITIBrowserArgumentIs(method, 5, "qQ");
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
                OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p arg=%@%@", className, selectorText, receiver, OITIBrowserDescribeObject(a), OITIBrowserDescribeSafariDownload(receiver));
                ((void (*)(id, SEL, id))original)(receiver, selector, a);
            });
            break;
        }
        case 2: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, id b) {
                OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p args=%@, %@%@", className, selectorText, receiver, OITIBrowserDescribeObject(a), OITIBrowserDescribeObject(b), OITIBrowserDescribeSafariDownload(receiver));
                ((void (*)(id, SEL, id, id))original)(receiver, selector, a, b);
            });
            break;
        }
        case 3: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, id b, id c) {
                OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p args=%@, %@, completion handler %@%@", className, selectorText, receiver, OITIBrowserDescribeObject(a),
                          OITIBrowserDescribeObject(b), c ? @"given" : @"none", OITIBrowserDescribeSafariDownload(receiver));
                ((void (*)(id, SEL, id, id, id))original)(receiver, selector, a, b, c);
            });
            break;
        }
        default: {
            replacement = imp_implementationWithBlock(^(id receiver, id a, long long written, long long total, long long expected) {
                static CFAbsoluteTime sLast;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - sLast >= 1.0) {   // about once a second, like the progress lines of the public hooks
                    sLast = now;
                    OITI_BLOG(@"Safari probe: -[%@ %@] receiver=%p written=%lld totalWritten=%lld totalExpected=%lld%@", className, selectorText, receiver, written, total, expected,
                              OITIBrowserDescribeSafariDownload(receiver));
                }
                ((void (*)(id, SEL, id, long long, long long, long long))original)(receiver, selector, a, written, total, expected);
            });
            break;
        }
    }
    class_replaceMethod(cls, selector, replacement, encoding);
    OITI_BLOG(@"Safari probe: -[%@ %@] hooked (encoding %s)", className, selectorText, encoding);
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
    if (sBrowserSafariInstalled || !sBrowserLog || sBrowserID != OITIBrowserIDSafari) return;
    if (!objc_getClass("_SFDownload") && !objc_getClass("_SFDownloadDispatcher")) {
        OITI_BLOG(@"Safari probe: the private download classes are not loaded (%@)", when);
        return;
    }
    sBrowserSafariInstalled = YES;
    OITI_BLOG(@"Safari probe: installing (%@)", when);
    OITIBrowserLogClassDetail("_SFDownload");
    OITIBrowserLogClassDetail("_SFDownloadManager");
    OITIBrowserLogClassDetail("_SFDownloadDispatcher");
    static const struct { const char *selector; int shape; } kSelectors[] = {
        {"_downloadDidStart:", 1}, {"_downloadDidFinish:", 1}, {"_downloadDidCancel:", 1}, {"_downloadProcessDidCrash:", 1},
        {"_download:didFailWithError:", 2}, {"_download:didReceiveResponse:", 2},
        {"_download:decideDestinationWithSuggestedFilename:completionHandler:", 3},
        {"_download:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:", 4}
    };
    static const char *const kClasses[] = {"_SFDownload", "_SFDownloadDispatcher"};
    for (unsigned c = 0; c < sizeof kClasses / sizeof kClasses[0]; c++) {
        Class cls = objc_getClass(kClasses[c]);
        if (!cls) continue;
        for (unsigned i = 0; i < sizeof kSelectors / sizeof kSelectors[0]; i++) OITIBrowserHookSafariSelector(cls, kSelectors[i].selector, kSelectors[i].shape);
    }
}

// Installs the hooks once, when the public class exists. WebKit may not be loaded yet when the dylib loads, so this is tried when
// the source is switched on or the research starts, and again a few seconds later.
static void OITIBrowserInstallDownloadProbe(NSString *when) {
    OITIBrowserInstallSafariProbe(when);   // Safari only, research log only; a no-op elsewhere
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
    BOOL publisher = isArc || isChrome;
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!library.length) return;
    BOOL research = [[NSFileManager defaultManager] fileExistsAtPath:[library stringByAppendingPathComponent:kOITIBrowserEnableFile]];
    if (!research && !publisher) return;   // Safari is research only
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
