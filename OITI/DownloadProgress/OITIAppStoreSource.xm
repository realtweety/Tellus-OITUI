// OITIAppStoreSource.xm -- feeds the download tracker from the App Store's placeholders in SpringBoard (OITI download progress, stage 2).
//
// Moved from Tweak.xm unchanged in the v0.3.0 module split (round 2, DownloadProgress). It reads progress through the
// instance-variable helpers and calls OITISafeBool; they live in Shared/OITIRuntimeHelpers.xm (round 8) and are declared in
// Shared/OITIShared.h.

#import "Shared/OITIShared.h"
#import "DownloadProgress/OITIDownloadProgress.h"

#import "Diagnostics/OITIDiagnostics.h"

// =============================================================================================
// MARK: App Store source (Download Progress, stage 2)
// =============================================================================================

// Feeds the download tracker from the App Store's placeholders in SpringBoard. Setting: DownloadAppStoreEnabled (default
// off, Settings > OITI > Download Progress > App Store Downloads); it also needs DownloadProgressEnabled, and Apple Mode and
// safe mode switch it off (safe mode: the timer never starts).
//
// What the install dump showed (build -c, iOS 16.7.16, one App Store download; LEARNINGS.md): a download's placeholder
// carries a percentage and no byte counts. Path, all by instance variables: SBApplicationPlaceholderController
// -placeholdersByDisplayID (bundle ID -> SBApplicationPlaceholder) > _placeholderProxy > _queue_progress
// (FBSApplicationPlaceholderProgress) > _percentComplete (double, 0 to 1, -1 = unknown) and _progress (an NSProgress with a
// total of 100). So the tracker gets a fraction (OITIDownloadUpdateFraction), not bytes.
//
// How it works. A timer on the main run loop polls once a second, only while the feature is on. Each poll reads the
// placeholders. A placeholder with a readable fraction of 0 or more becomes (or stays) a tracked download. When a tracked
// placeholder leaves the list, the app is looked up: installed means complete, and if it is not there after a 3 s grace the
// download counts as complete only when it had reached 97 percent, otherwise as cancelled (an update or a TestFlight
// install has not been dumped yet, so those are unconfirmed).
//
// Risk rules (see LEARNINGS.md, "Never call private methods because their names look like getters"): the progress is read
// from instance variables and the public NSProgress API; the only private method calls are the explicitly named
// accessors placeholdersByDisplayID, displayName and isPaused (a declared property that SpringBoard's own icon code calls),
// plus the shared-instance and applicationWithBundleIdentifier: lookups the install dump already uses. Whether a pause shows
// up in isPaused or in the NSProgress is logged (level 1) the first time it changes, so the first real pause tells us.


static NSTimer *sAppStoreTimer;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sAppStoreTracked;   // bundle ID -> name, fraction, paused, missingSince
static NSMutableSet<NSString *> *sAppStoreWarned;                                  // one-time warnings per session
static const NSTimeInterval kOITIAppStorePollInterval = 1.0;
static const NSTimeInterval kOITIAppStoreFinishGrace = 3.0;

static NSString *OITIAppStoreIdentifier(NSString *bundleID) {
    return [@"appstore:" stringByAppendingString:bundleID];
}

static id OITIAppStoreIvarObject(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static BOOL OITIAppStoreIvarNumber(id object, const char *name, double *value) {
    if (!object) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || !type[0]) return NO;
    double number = NAN;
    if (!OITIInstallIvarScalarText(object, ivar, type, &number) || isnan(number)) return NO;
    if (value) *value = number;
    return YES;
}

// Reads one placeholder. Returns NO when the progress object is not where it was on iOS 16.7.16. fraction is -1 while
// the progress is unknown.
static BOOL OITIAppStoreRead(id placeholder, double *fractionOut, BOOL *pausedOut, BOOL *installingOut, NSString **detailOut) {
    id proxy = OITIAppStoreIvarObject(placeholder, "_placeholderProxy");
    id progressObject = OITIAppStoreIvarObject(proxy, "_queue_progress");
    if (!progressObject) return NO;
    double fraction = -1.0, phase = -1.0, state = -1.0;
    BOOL haveFraction = OITIAppStoreIvarNumber(progressObject, "_percentComplete", &fraction);
    OITIAppStoreIvarNumber(progressObject, "_installPhase", &phase);
    OITIAppStoreIvarNumber(progressObject, "_installState", &state);
    id nsProgress = OITIAppStoreIvarObject(progressObject, "_progress");
    BOOL progressPaused = NO;
    if ([nsProgress isKindOfClass:[NSProgress class]]) {
        NSProgress *progress = (NSProgress *)nsProgress;
        if (!haveFraction || (fraction < 0 && !progress.indeterminate)) {
            fraction = progress.fractionCompleted;
            haveFraction = YES;
        }
        progressPaused = progress.paused;
    }
    BOOL available = NO;
    BOOL placeholderPaused = OITISafeBool(placeholder, @"isPaused", &available);
    if (fractionOut) *fractionOut = fraction;
    if (pausedOut) *pausedOut = progressPaused || (available && placeholderPaused);
    // Installing = installPhase 1. Seen in all three installs logged on 2026-11-06 (War Thunder Mobile, TikTok and an App Store
    // update of TestFlight): it follows the download (installPhase 0), keeps the fraction moving and ends with the placeholder
    // leaving the list and the app installed. The start is 3, a pause is 0 with state 2.
    if (installingOut) *installingOut = (phase > 0.5 && phase < 1.5) && !(progressPaused || (available && placeholderPaused));
    if (detailOut) {
        *detailOut = [NSString stringWithFormat:@"installPhase=%.0f installState=%.0f nsProgress=%d progressPaused=%d placeholderPaused=%@",
                      phase, state, nsProgress != nil, (int)progressPaused, available ? (placeholderPaused ? @"YES" : @"NO") : @"?"];
    }
    return haveFraction;
}

// ---- Install phase recorder (v0.3.0 polish, batch 6, item 11, round 1: READ-ONLY) -------------------------------------------
// What the App Store reports once the bytes are done (an "Installing" phase) is not known: the notes only have installPhase and
// installState readings from the download itself and the placeholder leaving the list. This records what a tracked placeholder
// says, one line (tag DOWNLOAD, text "PHASE ...") each time any of it changes, so one real install shows every transition and
// when it happened. Level 1 or higher only; at level 0 it is one level check per tracked download per second.
//
// Safety: instance variables and public NSProgress API only (the same reads OITIAppStoreRead already does), no new private
// method call, never pause or cancel. Each line has the time since tracking began, the fraction, installPhase, installState,
// the progress object's own state, the expected final phase, the NSProgress counts and flags, its localized description with
// the digits replaced by # (so a percentage alone is not a change but a new wording is), and the userInfo phase and state.
// Round 2 (the Installing state itself) is designed from these lines.
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sAppStorePhaseLog;   // bundle ID -> signature, startedAt

static NSString *OITIAppStoreDigitsHashed(NSString *text) {
    if (!text.length) return @"";
    return [text stringByReplacingOccurrencesOfString:@"[0-9]+" withString:@"#" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
}

static NSString *OITIAppStoreNumberText(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value stringValue] : @"-";
}

static void OITIAppStoreRecordPhase(id placeholder, NSString *bundleID, double fraction, CFAbsoluteTime now) {
    if (![sLog isLoggingAtLevel:1]) return;
    if (!sAppStorePhaseLog) sAppStorePhaseLog = [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = sAppStorePhaseLog[bundleID];
    if (!entry) {
        entry = [NSMutableDictionary dictionary];
        entry[@"startedAt"] = @(now);
        sAppStorePhaseLog[bundleID] = entry;
    }
    @try {
        id proxy = OITIAppStoreIvarObject(placeholder, "_placeholderProxy");
        id progressObject = OITIAppStoreIvarObject(proxy, "_queue_progress");
        if (!progressObject) return;
        double phase = -1.0, state = -1.0, rawState = -1.0, finalPhase = -1.0;
        OITIAppStoreIvarNumber(progressObject, "_installPhase", &phase);
        OITIAppStoreIvarNumber(progressObject, "_installState", &state);
        OITIAppStoreIvarNumber(progressObject, "_state", &rawState);
        OITIAppStoreIvarNumber(progressObject, "_expectedFinalInstallPhase", &finalPhase);
        BOOL available = NO;
        BOOL placeholderPaused = OITISafeBool(placeholder, @"isPaused", &available);
        NSString *progressText = @"nsProgress=none";
        NSString *shapeText = @"";
        id nsProgress = OITIAppStoreIvarObject(progressObject, "_progress");
        if ([nsProgress isKindOfClass:[NSProgress class]]) {
            NSProgress *progress = (NSProgress *)nsProgress;
            NSString *description = progress.localizedDescription ?: @"";
            NSString *additional = progress.localizedAdditionalDescription ?: @"";
            NSDictionary *info = progress.userInfo;
            NSDictionary *userInfo = [info isKindOfClass:[NSDictionary class]] ? info : @{};
            progressText = [NSString stringWithFormat:@"units=%lld/%lld indeterminate=%d finished=%d cancelled=%d paused=%d userInfo[phase=%@ state=%@ final=%@] description=\"%@\" additional=\"%@\"",
                            progress.completedUnitCount, progress.totalUnitCount, (int)progress.indeterminate, (int)progress.finished,
                            (int)progress.cancelled, (int)progress.paused, OITIAppStoreNumberText(userInfo[@"installPhase"]),
                            OITIAppStoreNumberText(userInfo[@"installState"]), OITIAppStoreNumberText(userInfo[@"expectedFinalInstallPhase"]),
                            description, additional];
            shapeText = [NSString stringWithFormat:@"%d%d%d%d|%@|%@|%@|%@|%@", (int)progress.indeterminate, (int)progress.finished,
                         (int)progress.cancelled, (int)progress.paused, OITIAppStoreNumberText(userInfo[@"installPhase"]),
                         OITIAppStoreNumberText(userInfo[@"installState"]), OITIAppStoreNumberText(userInfo[@"expectedFinalInstallPhase"]),
                         OITIAppStoreDigitsHashed(description), OITIAppStoreDigitsHashed(additional)];
        }
        NSString *signature = [NSString stringWithFormat:@"%.0f|%.0f|%.0f|%.0f|%d%d|%@", phase, state, rawState, finalPhase,
                               (int)available, (int)placeholderPaused, shapeText];
        if ([entry[@"signature"] isEqualToString:signature]) return;
        BOOL first = entry[@"signature"] == nil;
        entry[@"signature"] = signature;
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"PHASE %@ t=+%.1fs %@ fraction=%.4f installPhase=%.0f installState=%.0f progressState=%.0f expectedFinalPhase=%.0f placeholderPaused=%@ %@",
         bundleID, now - [entry[@"startedAt"] doubleValue], first ? @"(first reading)" : @"CHANGED", fraction, phase, state, rawState, finalPhase,
         available ? (placeholderPaused ? @"YES" : @"NO") : @"?", progressText];
    } @catch (NSException *exception) {
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"PHASE %@ recorder exception %@: %@", bundleID, exception.name, exception.reason];
    }
}

static NSString *OITIAppStoreDisplayName(id placeholder, NSString *bundleID) {
    id proxy = OITIAppStoreIvarObject(placeholder, "_placeholderProxy");
    for (id candidate in @[placeholder ?: @"", proxy ?: @""]) {
        if ([candidate isKindOfClass:[NSString class]]) continue;
        id value = OITIInstallObjectGetter(candidate, @"displayName");
        if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length) return value;
    }
    return bundleID;
}

static void OITIAppStorePoll(void) {
    if (!sDownloadProgressEnabled || !sDownloadAppStoreEnabled || sSafeModeActive) return;
    if (!sAppStoreTracked) sAppStoreTracked = [NSMutableDictionary dictionary];
    if (!sAppStoreWarned) sAppStoreWarned = [NSMutableSet set];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @try {
        id controller = OITIInstallSharedInstance(NSClassFromString(@"SBApplicationPlaceholderController"), NULL);
        id dictionary = OITIInstallObjectGetter(controller, @"placeholdersByDisplayID");
        BOOL haveList = [dictionary isKindOfClass:[NSDictionary class]];
        if (!haveList && ![sAppStoreWarned containsObject:@"list"]) {
            [sAppStoreWarned addObject:@"list"];
            [sLog logTag:@"DOWNLOAD" format:@"App Store source: the placeholder list is not available (controller %@). The classes may differ on this iOS version; run the install dump (COMMANDS.md section 17).",
             controller ? @"found" : @"missing"];
        }
        NSMutableSet<NSString *> *present = [NSMutableSet set];
        if (haveList) {
            NSDictionary *placeholders = (NSDictionary *)dictionary;
            for (id key in placeholders.allKeys) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *bundleID = key;
                id placeholder = placeholders[bundleID];
                double fraction = -1.0;
                BOOL paused = NO, installing = NO;
                NSString *detail = nil;
                BOOL readable = OITIAppStoreRead(placeholder, &fraction, &paused, &installing, &detail);
                NSMutableDictionary *tracked = sAppStoreTracked[bundleID];
                if (!readable) {
                    if (![sAppStoreWarned containsObject:bundleID]) {
                        [sAppStoreWarned addObject:bundleID];
                        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source: the placeholder for %@ has no readable progress object, skipped", bundleID];
                    }
                    if (tracked) [present addObject:bundleID];   // keep what is shown until it leaves the list
                    continue;
                }
                if (fraction < 0 && !tracked) continue;   // progress unknown and not tracked yet: not downloading (or not started)
                if (fraction < 0) fraction = [tracked[@"fraction"] doubleValue];   // keep the last value while it is unknown
                [present addObject:bundleID];
                if (!tracked) {
                    tracked = [NSMutableDictionary dictionary];
                    sAppStoreTracked[bundleID] = tracked;
                    tracked[@"paused"] = @NO;
                    tracked[@"name"] = OITIAppStoreDisplayName(placeholder, bundleID);
                    [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source: tracking %@ (%@) at %d%% (%@)", bundleID, tracked[@"name"],
                     (int)lround(fraction * 100.0), detail];
                }
                if ([tracked[@"installing"] boolValue] != installing) {
                    tracked[@"installing"] = @(installing);
                    [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source: %@ %@ at %d%% (%@)", bundleID, installing ? @"installing" : @"no longer installing",
                     (int)lround(fraction * 100.0), detail];
                }
                if ([tracked[@"paused"] boolValue] != paused) {
                    tracked[@"paused"] = @(paused);
                    [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source: %@ %@ at %d%% (%@)", bundleID, paused ? @"paused" : @"resumed",
                     (int)lround(fraction * 100.0), detail];
                }
                tracked[@"fraction"] = @(fraction);
                [tracked removeObjectForKey:@"missingSince"];
                OITIAppStoreRecordPhase(placeholder, bundleID, fraction, now);   // level 1: one line per change (batch 6, item 11)
                OITIDownloadUpdateFraction(OITIAppStoreIdentifier(bundleID), @"App Store", tracked[@"name"], bundleID, fraction, paused, installing);
                OITLOGGER_LOG_RATED(sLog, 2, @"DOWNLOAD", @"appstore-poll", 1, @"App Store source: %@ %.4f paused=%d %@",
                                    bundleID, fraction, (int)paused, detail);
            }
        }
        for (NSString *bundleID in sAppStoreTracked.allKeys) {
            if ([present containsObject:bundleID]) continue;
            NSMutableDictionary *tracked = sAppStoreTracked[bundleID];
            BOOL firstMissing = !tracked[@"missingSince"];
            if (firstMissing) tracked[@"missingSince"] = @(now);
            id applicationController = OITIInstallSharedInstance(NSClassFromString(@"SBApplicationController"), NULL);
            BOOL installed = OITIInstallApplicationForBundleID(applicationController, bundleID) != nil;
            if (firstMissing && [sLog isLoggingAtLevel:1]) {
                NSNumber *startedAt = sAppStorePhaseLog[bundleID][@"startedAt"];
                [sLog logLevel:1 tag:@"DOWNLOAD" format:@"PHASE %@ t=+%.1fs the placeholder is no longer in the list (last fraction %.4f, app installed: %@)", bundleID,
                 startedAt ? now - startedAt.doubleValue : 0.0, [tracked[@"fraction"] doubleValue], installed ? @"yes" : @"no"];
            }
            BOOL waited = now - [tracked[@"missingSince"] doubleValue] >= kOITIAppStoreFinishGrace;
            if (!installed && !waited) continue;   // the app may still be about to appear
            double lastFraction = [tracked[@"fraction"] doubleValue];
            BOOL completed = installed || lastFraction >= 0.97;
            [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source: %@ left the placeholder list at %d%%: %@ (app installed: %@)", bundleID,
             (int)lround(lastFraction * 100.0), completed ? @"complete" : @"cancelled", installed ? @"yes" : @"no"];
            OITIDownloadFinish(OITIAppStoreIdentifier(bundleID), completed);
            [sAppStoreTracked removeObjectForKey:bundleID];
            [sAppStorePhaseLog removeObjectForKey:bundleID];
        }
    } @catch (NSException *exception) {
        [sLog logTag:@"DOWNLOAD" format:@"App Store source: exception %@: %@", exception.name, exception.reason];
    }
}

// Starts or stops the poll for the current settings. Idempotent; called after every preferences reload.
void OITIAppStoreSourceRefresh(void) {
    BOOL wanted = sDownloadProgressEnabled && sDownloadAppStoreEnabled && !sAppleMode && !sSafeModeActive;
    if (wanted && !sAppStoreTimer) {
        sAppStoreTimer = [NSTimer timerWithTimeInterval:kOITIAppStorePollInterval repeats:YES block:^(NSTimer *timer) {
            OITIAppStorePoll();
        }];
        [[NSRunLoop mainRunLoop] addTimer:sAppStoreTimer forMode:NSRunLoopCommonModes];
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source on: polling the placeholders every %.0f s", kOITIAppStorePollInterval];
        OITIAppStorePoll();
    } else if (!wanted && sAppStoreTimer) {
        [sAppStoreTimer invalidate];
        sAppStoreTimer = nil;
        for (NSString *bundleID in sAppStoreTracked.allKeys) OITIDownloadDrop(OITIAppStoreIdentifier(bundleID));
        [sAppStoreTracked removeAllObjects];
        [sAppStorePhaseLog removeAllObjects];
        [sLog logLevel:1 tag:@"DOWNLOAD" format:@"App Store source off"];
    }
}
