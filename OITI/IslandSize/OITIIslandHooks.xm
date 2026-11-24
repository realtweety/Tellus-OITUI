// OITIIslandHooks.xm -- the Island's position, size, scale and appearance (OITI).
//
// Moved from Tweak.xm unchanged in the v0.3.0 module split (round 3, IslandSize): the position helpers (Island and banner),
// Apple's canvas scale, the size multipliers and the OITIHooks group (SBSystemApertureWindow, the curtain, gain map and
// content view, the touch pass-through view, SBBannerWindow, SBUISystemApertureLayoutMetrics). The settings these read are
// defined in Shared/OITIState.xm (declared in Shared/OITIShared.h); the preferences reload in Shared/OITIPreferences.xm writes them.
//
// Round 7 added OITIRefreshIslandLayout (and its helper) from the old preferences section: it only marks Island windows and views
// for layout, so it lives with the hooks.
//
// A Logos group can only be initialised in the file that defines it, so OITIInstallIslandSizeHooks at the end of this
// file does the %init and the %ctor in Tweak.xm calls it where it used to say %init(OITIHooks).

#import "Shared/OITIShared.h"
#import "IslandSize/OITIIslandSize.h"
#import "Diagnostics/OITIDiagnostics.h"
#import "OITIPositionLimits.h"   // one-screen limit for the typed positions (UIKit: used from layout code only)

static const void *kOITIAppliedScaleKey = &kOITIAppliedScaleKey;
static const void *kOITIHiddenByUsKey = &kOITIHiddenByUsKey;
static const void *kOITIColorAppliedKey = &kOITIColorAppliedKey;
// Island transparency and outline hiding: the alpha OITI last set on a view / a flag that OITI hid it, so a changed
// or switched-off setting applies live without fighting Apple's own changes to the same view.
static const void *kOITITransparencyAppliedKey = &kOITITransparencyAppliedKey;
static const void *kOITILineHiddenKey = &kOITILineHiddenKey;
static const void *kOITIPassThroughTouchedKey = &kOITIPassThroughTouchedKey;
// Island position: the window center Apple gave the window (NSValue CGPoint) and a flag that OITI moved the window away from it,
// so turning Use Custom Position off puts the Island back at Apple's place live (0.4.1). The center is used because a window
// transform (Use Custom Scale) scales around the center and leaves it alone; main thread only.
static const void *kOITIStockCenterKey = &kOITIStockCenterKey;
static const void *kOITIPositionMovedKey = &kOITIPositionMovedKey;
static BOOL sOITIWritingOwnIslandFrame;   // set while OITI writes the window frame itself, so the setFrame: hook leaves it alone

static CGFloat OITISafeScaleValue(CGFloat value) {
    if (!isfinite(value)) return 1.0;
    if (value < 0.05) return 1.0;
    if (value > 3.0) return 3.0;
    return value;
}

// Apple's own scale for the Island window: its canvas (360 x 640 on the 8 Plus) is stretched to the screen width by a
// uniform transform (1.15 there). Setting a transform replaces Apple's, so a scale relative to stock multiplies this
// back in. The shorter sides are compared so it holds in either orientation. Falls back to 1.0 if the numbers are
// not sane.
static CGFloat OITIAppleCanvasScale(UIView *window) {
    CGSize canvas = window.bounds.size;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat canvasSide = MIN(canvas.width, canvas.height);
    CGFloat screenSide = MIN(screen.width, screen.height);
    if (canvasSide < 1.0 || screenSide < 1.0) return 1.0;
    CGFloat factor = screenSide / canvasSide;
    return (isfinite(factor) && factor >= 0.5 && factor <= 3.0) ? factor : 1.0;
}

// =============================================================================================
// MARK: Island position (unchanged from Step 1)
// =============================================================================================

// The frame the Island window should have for the custom (posEnabled) position, given the frame it has or is about to get.
// Pure arithmetic apart from the one-screen limit (UIKit, called from hooks only). Idempotent: running it on its own result
// returns the same frame, which the setFrame: hook below relies on. Since 0.3.0 (batch 8) there are no built-in positions any
// more: "Fix Island Position" was turned into this custom position once, at the first launch (OITIMigratePresetPositions).
static CGRect OITIIslandPositionedFrame(CGRect frame) {
    if (!posEnabled) return frame;
    CGFloat sx = scaleEnabled ? OITISafeScaleValue(scaleX) : 1.0;
    CGFloat sy = scaleEnabled ? OITISafeScaleValue(scaleY) : 1.0;
    // Stored values are finite and within kOITIPositionCeiling; the one-screen limit is applied here, where UIKit is up.
    CGFloat yUse = OITIClampedPositionForUse(yPos, NO);
    CGFloat xUse = OITIClampedPositionForUse(xPos, YES);
    frame.origin.y = yUse / sy;
    // Original behavior: with scaling on, only override x when it is set; without scaling, always set it.
    if (!scaleEnabled || xUse > 0) frame.origin.x = xUse / sx;
    return frame;
}

// Remembers the center the window has right now as Apple's own, unless one is known already. Called before OITI moves the window.
static void OITIRememberStockCenter(UIView *window) {
    if (objc_getAssociatedObject(window, kOITIStockCenterKey)) return;
    CGPoint center = window.center;
    if (!isfinite(center.x) || !isfinite(center.y)) return;
    objc_setAssociatedObject(window, kOITIStockCenterKey, [NSValue valueWithCGPoint:center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Moves the Island window to the custom position (called from layoutSubviews). The setFrame: hook does the same for frames
// that SpringBoard sets itself.
static void OITIApplyIslandPosition(UIView *window) {
    if (!posEnabled) return;
    CGRect frame = window.frame;
    CGRect wanted = OITIIslandPositionedFrame(frame);
    if (CGRectEqualToRect(wanted, frame)) return;
    OITIRememberStockCenter(window);
    sOITIWritingOwnIslandFrame = YES;
    window.frame = wanted;
    sOITIWritingOwnIslandFrame = NO;
    objc_setAssociatedObject(window, kOITIPositionMovedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Use Custom Position was switched off: if OITI had moved the window, put its center back to the one Apple gave it. Done once
// (the flag is cleared), so it never fights a later layout of Apple's own.
static void OITIRestoreStockIslandPosition(UIView *window) {
    if (posEnabled || !objc_getAssociatedObject(window, kOITIPositionMovedKey)) return;
    objc_setAssociatedObject(window, kOITIPositionMovedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSValue *stock = objc_getAssociatedObject(window, kOITIStockCenterKey);
    if (!stock) return;
    CGPoint center = stock.CGPointValue;
    if (isfinite(center.x) && isfinite(center.y) && !CGPointEqualToPoint(window.center, center)) window.center = center;
}

// Notification banner window position. Returns YES and fills `out` when an override applies.
//  - notEnabled: custom origin (xNot, yNot); devices with no table entry keep the system's size. ("Fix Notification Positioning"
//    was turned into this setting once, at the first launch with 0.3.0.)
static BOOL OITIBannerFrame(CGRect incoming, CGRect *out) {
    const OITIDeviceProfile *profile = OITICurrentProfile();
    if (notEnabled) {
        CGSize size = profile ? CGSizeMake(profile->bannerWidth, profile->bannerHeight) : incoming.size;
        *out = CGRectMake(OITIClampedPositionForUse(xNot, YES), OITIClampedPositionForUse(yNot, NO), size.width, size.height);
        return YES;
    }
    return NO;
}

// =============================================================================================
// MARK: Hooks
// =============================================================================================

// Experimental Island size multipliers: keep them in a range that cannot collapse or explode the layout.
CGFloat OITIClampMetricsFactor(CGFloat value) {
    if (!isfinite(value)) return 1.0;
    return MAX(0.3, MIN(2.0, value));
}

static CGSize OITIApplyMetricsFactor(CGSize size, CGFloat factorX, CGFloat factorY) {
    if (factorX == 1.0 && factorY == 1.0) return size;   // exact pass-through when unused
    return CGSizeMake(size.width * factorX, size.height * factorY);
}

%group OITIHooks

// ---- IDEAS #13: double tap on the idle Island opens Tellus (0.4.1 batch 3, build -g) ------------------------------------------
// Tellus > Extras > Double Tap Opens Tellus (key ExtrasDoubleTapOpensTellus, default NO, off in Apple Mode).
// History: build -d's log made it look as if SBSystemApertureWindow takes touches on the idle Island (a plain UIView under
// _SBSystemApertureContainerViewContentView) and build -e put a double-tap recognizer on that window; it never fired. Build -f's
// SpringBoard-level log showed why: a touch on the truly idle Island is NOT given to SBSystemApertureWindow (no hitTest call at
// all); SpringBoard hands it to the status bar (window UIStatusBarWindow on the Home Screen, SBMainSwitcherWindow inside an
// app; view UIStatusBar_Modern or _UIStatusBarForegroundView). The -d taps were most likely made while an element was showing.
// So the feature only OBSERVES touches in UIApplication sendEvent: (below): a touch that begins in a small band at the top centre,
// is taken by a status bar view and has tapCount 2 is a double tap on the idle Island. A touch an Island element takes goes to
// SBSystemApertureWindow, fails the status bar test and is left to Apple. Nothing is cancelled, delayed or added to any window.
static NSString *const kOITITellusBundleID = @"com.wilburt.tellus";
static CFAbsoluteTime sOITILastDoubleTapOpen;

// The Island's place on the 8 Plus (taps seen at x about 205 to 211, y about 16 to 26). It does not follow a custom position or
// scale: a known limit of the first version.
static BOOL OITIIslandTapBand(CGPoint screenPoint) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    return screenPoint.y < 60.0 && fabs(screenPoint.x - CGRectGetMidX(bounds)) < 90.0;
}

// nil when the device is unlocked; fails closed when the lock state cannot be read.
static NSString *OITIDoubleTapLockReason(void) {
    id lockManager = OITISafeObject(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    BOOL available = NO;
    BOOL locked = OITISafeBool(lockManager, @"isUILocked", &available);
    if (!available) return @"lock state not available";
    return locked ? @"device is locked" : nil;
}

static void OITIHandleIslandTouch(UITouch *touch) {
    if (touch.phase != UITouchPhaseBegan) return;
    CGPoint screenPoint = [touch locationInView:nil];
    if (!OITIIslandTapBand(screenPoint)) return;
    NSString *windowClass = touch.window ? NSStringFromClass([touch.window class]) : @"no window";
    NSString *viewClass = touch.view ? NSStringFromClass([touch.view class]) : @"no view";
    OITLOGGER_LOG_RATED(sLog, 1, @"ISLANDTOUCH", @"island.touch.event", 5, @"touch began at %@ window=%@ view=%@ taps=%lu",
                        NSStringFromCGPoint(screenPoint), windowClass, viewClass, (unsigned long)touch.tapCount);
    // Every touch also arrives as a copy in _UISystemGestureWindow (no view); the real one follows it. Only the real one decides.
    if ([windowClass isEqualToString:@"_UISystemGestureWindow"]) return;
    if (touch.tapCount != 2 || !sExtrasDoubleTapOpensTellus) return;

    NSString *reason = nil;
    BOOL statusBarView = [viewClass hasPrefix:@"_UIStatusBar"] || [viewClass hasPrefix:@"UIStatusBar"];
    if (!statusBarView) {
        reason = [NSString stringWithFormat:@"the touch was not taken by the status bar (window %@, view %@)", windowClass, viewClass];
    } else if (sSafeModeActive) {
        reason = @"safe mode";
    } else if (sAppleMode) {
        reason = @"Apple Mode";
    } else if (!islandEnabled) {
        reason = @"Insula is off";
    } else if (CFAbsoluteTimeGetCurrent() - sOITILastDoubleTapOpen < 1.0) {
        reason = @"debounced (opened less than a second ago)";
    } else if (OITIDoubleTapLockReason()) {
        reason = OITIDoubleTapLockReason();
    } else if (sIslandNoticeItems.count > 0 || sDownloadItem) {
        reason = @"Insula is showing an element";
    }
    if (reason) {
        [sLog logLevel:1 tag:@"ISLANDTOUCH" format:@"double tap rejected: %@", reason];
        return;
    }
    sOITILastDoubleTapOpen = CFAbsoluteTimeGetCurrent();
    [sLog logLevel:1 tag:@"ISLANDTOUCH" format:@"double tap accepted: opening %@", kOITITellusBundleID];
    OITIOpenApp(kOITITellusBundleID);
}

%hook SBSystemApertureWindow

// Reported by a user (iPhone 14 Plus, iOS 16.6, 22 Nov 2026; never seen on the owner's 8 Plus): after a lock and unlock the Island
// goes back behind the notch until a respring. The position used to be applied only from layoutSubviews, and UIKit does not lay
// a view out again when only its frame origin changes, so a frame that SpringBoard sets itself (suspected on lock or unlock)
// was never corrected. This applies the same position to every frame the window is given: Apple's frame goes in first (so the
// center Apple wanted is known and kept for switching the position off again), then the custom frame replaces it in the same
// call. It never re-enters setFrame:, the arithmetic is the one layoutSubviews uses, and unusable frames (not finite, null,
// empty) pass through unchanged. Not device-tested; the cause is a suspicion until the log below shows it.
- (void)setFrame:(CGRect)frame {
    %orig(frame);
    if (sOITIWritingOwnIslandFrame) return;
    BOOL usable = isfinite(frame.origin.x) && isfinite(frame.origin.y) && isfinite(frame.size.width) &&
                  isfinite(frame.size.height) && !CGRectIsNull(frame) && !CGRectIsEmpty(frame);
    if (!usable) return;
    // Apple's own frame was just applied: its center is the stock place (replaces an older one, Apple may have moved it).
    CGPoint center = self.center;
    if (isfinite(center.x) && isfinite(center.y)) {
        objc_setAssociatedObject(self, kOITIStockCenterKey, [NSValue valueWithCGPoint:center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!posEnabled) return;
    CGRect use = OITIIslandPositionedFrame(frame);
    if (CGRectEqualToRect(use, frame)) return;
    // Only when the position had to be corrected: a line here after an unlock is the evidence for the cause.
    OITLOGGER_LOG_RATED(sLog, 1, @"ISLANDFRAME", @"island.setframe", 5,
                        @"setFrame incoming=%@ used=%@ current=%@ scale=%d",
                        NSStringFromCGRect(frame), NSStringFromCGRect(use), NSStringFromCGRect(self.frame), scaleEnabled);
    %orig(use);
    objc_setAssociatedObject(self, kOITIPositionMovedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)layoutSubviews {
    CGRect before = self.frame;

    if (scaleEnabled) {
        CGFloat appleScale = OITIAppleCanvasScale(self);
        CGAffineTransform wanted = CGAffineTransformMakeScale(appleScale * OITISafeScaleValue(scaleX),
                                                              appleScale * OITISafeScaleValue(scaleY));
        if (!CGAffineTransformEqualToTransform(self.transform, wanted)) self.transform = wanted;
        objc_setAssociatedObject(self, kOITIAppliedScaleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(self, kOITIAppliedScaleKey)) {
        // Turning scaling off resets the old transform live.
        self.transform = CGAffineTransformIdentity;
        objc_setAssociatedObject(self, kOITIAppliedScaleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    %orig;
    CGRect afterOrig = self.frame;
    OITIRememberStockCenter(self);        // before OITI moves anything: this is Apple's place
    OITIRestoreStockIslandPosition(self); // Use Custom Position was switched off: back to Apple's place
    OITIApplyIslandPosition(self);

    if (![sLiveApertureWindows containsObject:self]) [sLiveApertureWindows addObject:self];

    if ([sLog isLoggingAtLevel:1]) {
        [sApertureWindows addObject:self];
        OITIScheduleAutoDump();
        NSString *signature = [NSString stringWithFormat:@"frame=%@ bounds=%@ xf=%@ pos=%d scale=%d sx=%.3f sy=%.3f",
                               NSStringFromCGRect(self.frame), NSStringFromCGRect(self.bounds),
                               NSStringFromCGAffineTransform(self.transform),
                               posEnabled, scaleEnabled, scaleX, scaleY];
        if ([sLog noteSignature:signature forObject:self]) {
            [sLog logLevel:1 tag:@"ISLAND" format:@"%@@%p changed: %@ (profile=%d)",
             NSStringFromClass([self class]), self, signature, OITICurrentProfile() != NULL];
        }
    }
    OITLOGGER_LOG_RATED(sLog, 2, @"LAYOUT", @"island.layout", 5,
                        @"before=%@ afterOrig=%@ final=%@",
                        NSStringFromCGRect(before), NSStringFromCGRect(afterOrig), NSStringFromCGRect(self.frame));
}

%end

// IDEAS #13: observes touches for the double tap above. %orig runs first, so Apple's handling is never delayed or changed; nothing
// happens unless Double Tap Opens Tellus is on or Log Detail is 1.
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig(event);
    if ((sExtrasDoubleTapOpensTellus || sLog.level >= 1) && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) OITIHandleIslandTouch(touch);
    }
}
%end

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    BOOL shouldHide = posEnabled || scaleEnabled;
    if (shouldHide) {
        if (!self.hidden) self.hidden = YES;
        objc_setAssociatedObject(self, kOITIHiddenByUsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(self, kOITIHiddenByUsKey)) {
        // Only undo our own hiding, instead of force-unhiding a view Apple may have hidden itself.
        self.hidden = NO;
        objc_setAssociatedObject(self, kOITIHiddenByUsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    OITLOGGER_LOG_RATED(sLog, 1, @"CURTAIN", @"curtain", 4,
                        @"%@@%p didMoveToWindow window=%@ shouldHide=%d hidden=%d ours=%d",
                        NSStringFromClass([self class]), self, self.window ? @"yes" : @"no", shouldHide,
                        self.hidden, objc_getAssociatedObject(self, kOITIHiddenByUsKey) != nil);
}

%end

%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    if (hideEnabled && self.superview) {
        OITLOGGER_LOG(sLog, 1, @"GAINMAP", @"%@@%p removed from %@",
                      NSStringFromClass([self class]), self, NSStringFromClass([self.superview class]));
        [self removeFromSuperview];
    }
}

%end

%hook _SBSystemApertureContainerViewContentView

- (void)layoutSubviews {
    UIColor *backgroundColor = [self backgroundColor];
    BOOL ours = objc_getAssociatedObject(self, kOITIColorAppliedKey) != nil;

    if (colorEnabled) {
        // Only touch the color when nothing set one, or when the color is the one we applied earlier
        // (so changing the color in prefs takes effect without a respring).
        // The color is always opaque. Transparency comes only from Use Custom Opacity (the `alpha` setting, applied once to
        // the touch pass-through subview below), so the same value is never applied twice (v0.3.0 polish, A1).
        if (!backgroundColor || ours) {
            UIColor *customColor = [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
            if (!backgroundColor || ![backgroundColor isEqual:customColor]) {
                [self setBackgroundColor:customColor];
                OITLOGGER_LOG_RATED(sLog, 1, @"COLOR", @"color.apply", 4,
                                    @"%@@%p background %@ -> %@", NSStringFromClass([self class]), self,
                                    OITIColorDesc(backgroundColor), OITIColorDesc(customColor));
            }
            objc_setAssociatedObject(self, kOITIColorAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            OITLOGGER_LOG_RATED(sLog, 2, @"COLOR", @"color.skip", 2,
                                @"%@@%p not overriding: something else set %@",
                                NSStringFromClass([self class]), self, OITIColorDesc(backgroundColor));
        }
    } else if (ours) {
        [self setBackgroundColor:nil];
        objc_setAssociatedObject(self, kOITIColorAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        OITLOGGER_LOG(sLog, 1, @"COLOR", @"%@@%p color override removed", NSStringFromClass([self class]), self);
    }
    %orig;
}

%end

%hook SBFTouchPassThroughView

- (void)layoutSubviews {
    %orig;

    // An instance OITI changed earlier must still be visited when the setting is switched off, so it can be restored.
    if (!transEnabled && !lineDisabled && !objc_getAssociatedObject(self, kOITIPassThroughTouchedKey)) return;

    // SBFTouchPassThroughView is used pervasively throughout SpringBoard (Dock, folders, notification banners,
    // home screen icons, etc.), and the subviews.count == 4 heuristic below is NOT specific enough on its own.
    // Scoping to instances actually inside SBSystemApertureWindow avoids matching unrelated views.
    // KNOWN FRAGILE: the index-based subview picks may change between iOS versions.
    static Class apertureWindowClass;
    if (!apertureWindowClass) apertureWindowClass = NSClassFromString(@"SBSystemApertureWindow");
    if (!apertureWindowClass || !OITViewHasAncestorOfClass(self, apertureWindowClass)) return;

    NSUInteger subviewCount = self.subviews.count;
    if (subviewCount != 4) {
        // The heuristic did not match an Island-scoped instance. Log when the count changes, so a miss shows up.
        if ([sLog isLoggingAtLevel:1] &&
            [sLog noteSignature:[NSString stringWithFormat:@"miss:%lu", (unsigned long)subviewCount] forObject:self]) {
            [sLog logLevel:1 tag:@"TOUCHPASS" format:@"%@@%p inside the Island window has %lu subview(s), not 4: transparency/line hiding NOT applied",
             NSStringFromClass([self class]), self, (unsigned long)subviewCount];
        }
        return;
    }

    // Transparency. A view is OITI's to change when it is untouched (alpha 1.0, as before) or still carries the alpha
    // OITI set earlier (so a new opacity applies live). If something else changed the alpha since, it is left alone.
    UIView *targetSubview = self.subviews[2];
    NSNumber *appliedAlpha = objc_getAssociatedObject(targetSubview, kOITITransparencyAppliedKey);
    BOOL carriesOurAlpha = appliedAlpha && fabs(targetSubview.alpha - appliedAlpha.doubleValue) < 0.001;
    if (transEnabled) {
        BOOL untouched = targetSubview.alpha == 1.0 && targetSubview.userInteractionEnabled == 0;
        if (untouched || carriesOurAlpha) {
            if (fabs(targetSubview.alpha - alpha) > 0.001) {
                targetSubview.alpha = alpha;
                OITLOGGER_LOG_RATED(sLog, 2, @"TOUCHPASS", @"touchpass.trans", 4,
                                    @"transparency applied alpha=%.2f to %@", alpha, NSStringFromClass([targetSubview class]));
            }
            objc_setAssociatedObject(targetSubview, kOITITransparencyAppliedKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (appliedAlpha) {
        if (carriesOurAlpha) targetSubview.alpha = 1.0;
        objc_setAssociatedObject(targetSubview, kOITITransparencyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Outline.
    UIView *lineView = self.subviews[1];
    BOOL lineIsOurs = objc_getAssociatedObject(lineView, kOITILineHiddenKey) != nil;
    if (lineDisabled) {
        if (lineIsOurs || (lineView.alpha == 1.0 && lineView.userInteractionEnabled == 0)) {
            if (!lineView.hidden) {
                lineView.hidden = YES;
                OITLOGGER_LOG_RATED(sLog, 2, @"TOUCHPASS", @"touchpass.line", 4,
                                    @"line hidden: %@", NSStringFromClass([lineView class]));
            }
            objc_setAssociatedObject(lineView, kOITILineHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (lineIsOurs) {
        lineView.hidden = NO;
        objc_setAssociatedObject(lineView, kOITILineHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL touched = objc_getAssociatedObject(targetSubview, kOITITransparencyAppliedKey) != nil ||
                   objc_getAssociatedObject(lineView, kOITILineHiddenKey) != nil;
    objc_setAssociatedObject(self, kOITIPassThroughTouchedKey, touched ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%hook SBBannerWindow

- (CGRect)frame {
    CGRect original = %orig;
    CGRect overridden;
    return OITIBannerFrame(original, &overridden) ? overridden : original;
}

- (void)setFrame:(CGRect)frame {
    CGRect overridden;
    BOOL didOverride = OITIBannerFrame(frame, &overridden);
    CGRect used = didOverride ? overridden : frame;

    [sBannerWindows addObject:self];   // always kept (weak): the Island notification path needs the banner window
    if ([sLog isLoggingAtLevel:1]) {
        NSString *signature = [NSString stringWithFormat:@"in=%@ used=%@ ov=%d", NSStringFromCGRect(frame),
                               NSStringFromCGRect(used), didOverride];
        if ([sLog noteSignature:signature forObject:self]) {
            [sLog logLevel:1 tag:@"BANNER" format:@"%@@%p setFrame %@ (custom=%d profile=%d)",
             NSStringFromClass([self class]), self, signature, notEnabled, OITICurrentProfile() != NULL];
        }
    }
    %orig(used);
}

%end

// The root input Apple builds the Island from. Returns Apple's value times the Island Size multipliers (both 1.0 by
// default, which is an exact pass-through). The raw value is kept for the dump.
%hook SBUISystemApertureLayoutMetrics

- (CGSize)sensorRegionSize {
    CGSize size = %orig;
    sRawSensorRegionSize = size;
    return OITIApplyMetricsFactor(size, sMetricsSensorX, sMetricsSensorY);
}

%end

%end

// Asks the Island windows to lay out again so new settings (scale, position) apply immediately. The layoutSubviews
// hook does the actual work. Harmless when no window has been seen yet (or in safe mode, when no hook exists).
//
// The custom color, transparency and outline settings are applied in the layoutSubviews of two inner view classes, and
// setNeedsLayout on a window does not reach them, so those views are marked too. The custom banner position lives in
// the banner window's frame, which is set again here. Turning the banner position OFF only takes effect the next time
// the system sets the banner frame (the next banner), because OITI does not know the original frame.
static void OITIMarkOverrideViewsForLayout(UIView *view, NSUInteger depth) {
    static Class contentClass;
    static Class passThroughClass;
    if (!contentClass) contentClass = NSClassFromString(@"_SBSystemApertureContainerViewContentView");
    if (!passThroughClass) passThroughClass = NSClassFromString(@"SBFTouchPassThroughView");
    if ((contentClass && [view isKindOfClass:contentClass]) || (passThroughClass && [view isKindOfClass:passThroughClass])) {
        [view setNeedsLayout];
    }
    if (depth >= 12) return;
    for (UIView *subview in view.subviews) OITIMarkOverrideViewsForLayout(subview, depth + 1);
}

void OITIRefreshIslandLayout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *window in sLiveApertureWindows.allObjects) {
            [window setNeedsLayout];
            OITIMarkOverrideViewsForLayout(window, 0);
        }
        if (notEnabled) {
            for (UIView *banner in sBannerWindows.allObjects) {
                CGRect current = banner.frame;
                banner.frame = current;   // the setFrame: hook applies the override
            }
        }
    });
}

void OITIInstallIslandSizeHooks(void) {
    %init(OITIHooks);
}
