// OITINoticeStackCards.xm -- the stack's older notifications, drawn by OITI as cards below the Island
// (v0.3.0 polish, batch 5; tested on the phone by the owner from build OITI-exp-2026-11-03-c).
//
// The newest notice is an Apple element in whatever Style the owner chose. The older notices of the stack (the stack holds four)
// are drawn here, as compact capsules in a window of OITI's own placed under the Island's card:
//
//     [app icon]        Title: message in the middle        [how long ago]
//
// Each card has its own tap and its own swipe up, so a tap opens that notice only. Every notice is still a registered element with
// its own timeout and promotion; only where the older ones are drawn and what a tap on them does lives here. (Until build
// OITI-exp-2026-11-03-d the older notices could also be drawn as compact cards inside the newest element's card, selected by a
// Stack Look setting; the owner preferred these cards, so that look and its setting were removed.)
//
// The window follows the Minimal download pill's design (own window in the Island's scene, above the Island's window, touches
// outside the cards fall through). The cards are placed from the on-screen rectangle of the Island's container view and wait until it
// has stood still for a moment; when no plausible rectangle is found they stay hidden (nothing is guessed). Level 2 logs the
// candidate rectangles (tag STACKCARDS).
//
// Motion (batch 6, item 2). One card view lives per stack item and is kept while its notice stays an older one (matched by the item
// dictionary's identity, so nothing is rebuilt when the stack changes). While the cards are showing: a new card slides down from
// under the Island's card and fades in; the cards that stay glide to their new place when a card is added or leaves; a card that
// leaves (swipe, tap-dismiss, timeout, eviction, or promotion into the Island) slides up and fades out. The motion is a transform
// offset that animates back to identity, so the 30 Hz tick can keep setting bounds and center without fighting it. Reduce Motion
// turns the slides and glides off: new cards fade in, leaving cards fade out, the others jump. While the Island-rectangle gate
// is closed (the rectangle is moving, or the newest notice is not on screen yet) the cards are invisible, so changes apply
// instantly and the group fades in as before; a card that was added meanwhile then slides in with that fade.
//
// Morph (batch 7). When a new notice pushes the Island's notice down into the cards, a copy of that card starts at the Island's
// rectangle and travels to its place under the Island (0.42 s, spring, the corners shrinking from the Island's to the card's), in the
// window itself so the closed gate does not hide it. When the real card shows, it takes over from the copy (the copy is on top and
// looks the same, so it is removed a moment later). Only when the notice had been on screen for a while and the Island's rectangle
// is known, never with Reduce Motion or in landscape. The gate, the real card and its enter animation are unchanged.
//
// Download card (batch 7, item 5). A running Detailed download that a notice has pushed behind is a card too: app name, a thin bar
// and the percentage, kept current by the tracker through OITIStackCardsDownloadUpdate.
//
// Launch path: nothing here runs at launch. The first call comes from OITIPresentNoticeElement after a notice exists.

#import "Shared/OITIShared.h"
#import "IslandNotifications/OITIIslandNotifications.h"
#import "Diagnostics/OITIDiagnostics.h"
#import "DownloadProgress/OITIDownloadProgress.h"

static const CGFloat kOITICardHeight = 36.0;
static const CGFloat kOITICardGap = 5.0;            // between cards
static const CGFloat kOITICardIslandGap = 8.0;      // between the Island's card and the first card
static const CGFloat kOITICardMinWidth = 240.0;
static const NSUInteger kOITICardMax = 3;           // the stack holds four notices: the newest plus three older ones
static const CFTimeInterval kOITICardStableAfter = 0.15;   // the Island's rectangle must stand still this long
// The newest notice must have been on screen this long before the cards show. A new notice lands in the Island while it is still
// its small pill and expands about 0.2 s later; the rectangle is steady for the 0.15 s before that, so the gate alone opened early
// and the cards flashed under the small pill (device log 2026-11-06: shown at 05.069 under an 88 x 33 pill, hidden at 05.129 when it
// grew, shown again at 05.302). Batch 8.
static const CFTimeInterval kOITICardNewestSettle = 0.30;
static NSDictionary *sDownloadCardState;    // header, percent, fraction, ending of the running Detailed download (OITIStackCardsDownloadUpdate)

static const CGFloat kOITICardEnterOffset = 8.0;    // a new card starts this far above its place (flush with the Island's card)
static const CGFloat kOITICardExitOffset = 8.0;     // a leaving card slides this far up
static const CGFloat kOITICardAwayScale = 0.96;     // and is slightly smaller while it is away

// ---- One card ------------------------------------------------------------------------------------------

@interface OITINoticeCardView : UIView
@property (nonatomic, strong) OITINoticeActions *actions;   // the gesture recognizers' target (they hold it weakly)
@property (nonatomic, assign) CFAbsoluteTime postedAt;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) NSDictionary *item;   // the stack item this card shows (the key that keeps the view between refreshes)
@property (nonatomic, assign) NSInteger slot;       // 0 = directly under the Island's card
@property (nonatomic, assign) BOOL entered;         // the enter animation has played (or the card was shown with the group)
@property (nonatomic, assign) BOOL exiting;         // leaving: not in sCardViews any more, animating out
@property (nonatomic, assign) BOOL isDownload;      // a running Detailed download: header, a thin bar and the percentage (batch 7, item 5)
@property (nonatomic, strong) UIView *ghost;        // a copy that travels from the Island to this card's place while the cards are still hidden
@property (nonatomic, assign) CFTimeInterval ghostEndsAt;
- (instancetype)initWithItem:(NSDictionary *)item;
- (void)refreshTimeText;
- (void)applyDownloadState:(NSDictionary *)state;
@end

@implementation OITINoticeCardView {
    UIImageView *_icon;
    UILabel *_initial;
    UILabel *_message;
    OITIProgressBarView *_bar;   // a download card only
}

static NSString *OITICardMessageText(NSDictionary *info) {
    NSString *title = info[@"title"] ?: @"";
    NSString *subtitle = info[@"subtitle"] ?: @"";
    NSString *message = info[@"message"] ?: @"";
    NSString *appName = info[@"appName"] ?: @"";
    if (!appName.length && [info[@"bundleID"] length]) appName = [(NSString *)info[@"bundleID"] componentsSeparatedByString:@"."].lastObject ?: @"";
    NSString *body = message;
    if (subtitle.length) body = message.length ? [NSString stringWithFormat:@"%@: %@", subtitle, message] : subtitle;
    if (title.length) return body.length ? [NSString stringWithFormat:@"%@: %@", title, body] : title;
    if (body.length) return body;
    return appName;
}

- (instancetype)initWithItem:(NSDictionary *)item {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kOITICardMinWidth, kOITICardHeight)])) {
        NSDictionary *info = item[@"info"];
        NSString *bundleID = info[@"bundleID"] ?: @"";
        self.item = item;
        self.backgroundColor = [UIColor blackColor];
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.cornerRadius = kOITICardHeight / 2.0;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        self.postedAt = [item[@"postedAt"] doubleValue];

        UIImage *icon = nil;
        if (bundleID.length && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
            icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
        }
        if (icon) {
            _icon = [[UIImageView alloc] initWithImage:icon];
            _icon.layer.cornerCurve = kCACornerCurveContinuous;
            _icon.layer.cornerRadius = 5.0;
            _icon.layer.masksToBounds = YES;
            [self addSubview:_icon];
        } else {
            _initial = [[UILabel alloc] init];
            _initial.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            _initial.textColor = [UIColor whiteColor];
            _initial.textAlignment = NSTextAlignmentCenter;
            NSString *name = [info[@"appName"] length] ? info[@"appName"] : OITICardMessageText(info);
            _initial.text = name.length ? [name substringToIndex:1] : @"•";
            [self addSubview:_initial];
        }

        _message = [[UILabel alloc] init];
        _message.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        _message.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        _message.textAlignment = NSTextAlignmentCenter;
        _message.numberOfLines = 1;
        _message.lineBreakMode = NSLineBreakByTruncatingTail;
        _message.text = OITICardMessageText(info);
        [self addSubview:_message];

        _timeLabel = [[UILabel alloc] init];
        _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
        _timeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _timeLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_timeLabel];
        if ([item[@"download"] boolValue]) {
            // A running Detailed download that is older than a notice (batch 7, item 5): app name above a thin bar, the percentage
            // where a notice has its age. The tracker keeps it current (OITIStackCardsDownloadUpdate).
            self.isDownload = YES;
            _bar = [[OITIProgressBarView alloc] initWithFrame:CGRectZero];
            _bar.barHeight = 3.0;
            [self addSubview:_bar];
            NSString *appName = info[@"appName"] ?: @"";
            NSString *title = info[@"title"] ?: @"";
            NSString *header = appName.length ? [NSString stringWithFormat:@"%@ - %@", appName, title] : title;
            [self applyDownloadState:sDownloadCardState ?: @{ @"header": header, @"percent": info[@"message"] ?: @"", @"fraction": @0, @"ending": @0 }];
        }
        [self refreshTimeText];
    }
    return self;
}

- (void)applyDownloadState:(NSDictionary *)state {
    NSString *header = state[@"header"];
    NSInteger ending = [state[@"ending"] integerValue];   // 0 running, 1 completed, 2 cancelled
    NSString *trailing = ending == 2 ? @"Cancelled" : (state[@"percent"] ?: @"");
    if (header.length && ![_message.text isEqualToString:header]) _message.text = header;
    if (![_timeLabel.text isEqualToString:trailing]) {
        _timeLabel.text = trailing;
        [self setNeedsLayout];
    }
    [_bar setComplete:ending == 1];
    if (ending == 2) [_bar setCancelled:YES];
    [_bar setFraction:[state[@"fraction"] doubleValue] animated:self.window != nil];
}

- (void)refreshTimeText {
    if (self.isDownload) return;   // the percentage is set by applyDownloadState:
    NSString *text = @"";
    if (self.postedAt > 0) {
        double seconds = MAX(0.0, CFAbsoluteTimeGetCurrent() - self.postedAt);
        if (seconds < 60.0) text = @"now";
        else if (seconds < 3600.0) text = [NSString stringWithFormat:@"%dm", (int)(seconds / 60.0)];
        else text = [NSString stringWithFormat:@"%dh", (int)(seconds / 3600.0)];
    }
    if (![_timeLabel.text isEqualToString:text]) {
        _timeLabel.text = text;
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat iconSide = 22.0, margin = 12.0;
    CGRect iconFrame = CGRectMake(margin, (height - iconSide) / 2.0, iconSide, iconSide);
    _icon.frame = iconFrame;
    _initial.frame = iconFrame;
    CGSize timeSize = [_timeLabel sizeThatFits:CGSizeMake(80, height)];
    CGFloat timeWidth = _timeLabel.text.length ? ceil(timeSize.width) : 0.0;
    _timeLabel.frame = CGRectMake(width - margin - timeWidth, (height - ceil(timeSize.height)) / 2.0, timeWidth, ceil(timeSize.height));
    // The message is centred in the space between the icon and the time, and the two sides use the same inset, so it is
    // centred on the card even when the time is short.
    CGFloat side = MAX(CGRectGetMaxX(iconFrame), timeWidth + margin) + 8.0;
    _message.frame = CGRectMake(side, 0, MAX(20.0, width - 2.0 * side), height);
    if (_bar) {   // download card: the header on top, the bar under it
        _message.frame = CGRectMake(side, 4.0, MAX(20.0, width - 2.0 * side), 17.0);
        _bar.frame = CGRectMake(side, height - 12.0, MAX(20.0, width - 2.0 * side), 3.0);
    }
}
@end

// ---- The window -----------------------------------------------------------------------------------------

@interface OITINoticeCardsController : UIViewController
@end
@implementation OITINoticeCardsController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
@end

@interface OITINoticeCardsWindow : UIWindow
@end
@implementation OITINoticeCardsWindow
// Only the cards take touches; everything else goes to whatever is underneath.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

static OITINoticeCardsWindow *sCardsWindow;
static NSMutableArray<OITINoticeCardView *> *sCardViews;       // the cards that are in the stack, slot 0 first
static NSMutableArray<OITINoticeCardView *> *sCardExiting;     // cards that left and are animating out
static id sCardsNewestKey;                                       // the newest item the settle time is measured for
static CFTimeInterval sCardsNewestOnScreenSince;                // when it was first seen on screen (0 = not on screen)
static NSDictionary *sCardsPreviousNewest;                     // the Island's notice (newest item) at the last refresh: the one a new notice demotes
static NSTimer *sCardsTimer;
static BOOL sCardsShown;                  // the cards are faded in
static CGRect sCardsLastRect;             // the Island rectangle seen on the last tick
static CFTimeInterval sCardsStableSince;
static CFAbsoluteTime sCardsLastSecond;   // when the time labels were last refreshed
static NSString *sCardsLastCandidates;    // for the level 2 probe log (log on change only)
static NSInteger sCardsLastDecisionCode = -1;   // log a decision only when it changes (the tick runs ~30 times a second)

static UIWindowScene *OITICardsWindowScene(void) {
    for (UIView *view in sLiveApertureWindows.allObjects) {
        UIWindowScene *scene = [view isKindOfClass:[UIWindow class]] ? ((UIWindow *)view).windowScene : nil;
        if (scene) return scene;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

static UIWindowLevel OITICardsWindowLevel(void) {
    UIWindowLevel level = UIWindowLevelAlert + 1000.0;
    for (UIView *view in sLiveApertureWindows.allObjects) {
        if ([view isKindOfClass:[UIWindow class]]) level = MAX(level, ((UIWindow *)view).windowLevel + 1.0);
    }
    return level;
}

// ---- Where the Island's card is ---------------------------------------------------------------------------
// The Island's own rounded black view (SBSystemApertureContainerView) in screen coordinates; the conversion includes OITI's
// position and scale transforms. All candidates are collected (and logged at level 2: this is the probe of this round); the
// one that reaches lowest on screen wins, because the cards go under the expanded card.
static void OITICardsCollectContainers(UIView *view, Class containerClass, NSUInteger depth, NSMutableArray<NSValue *> *rects) {
    if (containerClass && [view isKindOfClass:containerClass]) {
        if (!view.hidden && view.alpha > 0.01) {
            CGRect rect = [[UIScreen mainScreen].coordinateSpace convertRect:view.bounds fromCoordinateSpace:view];
            if (rect.size.width > 20.0 && rect.size.height > 10.0) [rects addObject:[NSValue valueWithCGRect:rect]];
        }
        return;
    }
    if (depth >= 8) return;
    for (UIView *subview in view.subviews) OITICardsCollectContainers(subview, containerClass, depth + 1, rects);
}

static BOOL OITICardsIslandRect(CGRect *rectOut) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    Class containerClass = NSClassFromString(@"SBSystemApertureContainerView");
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (UIView *view in sLiveApertureWindows.allObjects) {
        if (![view isKindOfClass:[UIWindow class]] || view.hidden) continue;
        OITICardsCollectContainers(view, containerClass, 0, rects);
    }
    CGRect best = CGRectNull;
    // The Island is near the top (y up to 80 pt with the built-in positions); Use Custom Position can move it down by the typed Y,
    // so the limit moves with it (batch 7, item 3: it used to be a fixed 80, so the cards never showed for a Y above about 55).
    CGFloat maxOriginY = MIN(screen.height - 60.0, 80.0 + (posEnabled ? MAX(0.0, (CGFloat)yPos) : 0.0));
    for (NSValue *value in rects) {
        CGRect rect = value.CGRectValue;
        BOOL plausible = rect.size.width >= 60.0 && rect.size.width <= screen.width - 8.0 &&
                         rect.origin.y >= -5.0 && rect.origin.y <= maxOriginY && rect.size.height >= 20.0 && rect.size.height <= 420.0;
        if (!plausible) continue;
        if (CGRectIsNull(best) || CGRectGetMaxY(rect) > CGRectGetMaxY(best)) best = rect;
    }
    if ([sLog isLoggingAtLevel:2]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSValue *value in rects) [parts addObject:NSStringFromCGRect(value.CGRectValue)];
        NSString *summary = [NSString stringWithFormat:@"containers=[%@] chosen=%@", [parts componentsJoinedByString:@" "],
                             CGRectIsNull(best) ? @"none" : NSStringFromCGRect(best)];
        if (![summary isEqualToString:sCardsLastCandidates]) {
            sCardsLastCandidates = summary;
            [sLog logLevel:2 tag:@"STACKCARDS" format:@"island rectangle probe: %@", summary];
        }
    }
    if (CGRectIsNull(best)) return NO;
    *rectOut = best;
    return YES;
}

// ---- Which notices become cards -----------------------------------------------------------------------------
// The older items of the stack that are notifications or a running Detailed download (the Hello is never a card). Most recent
// first, at most kOITICardMax.
static NSArray<NSDictionary *> *OITICardsOlderItems(void) {
    if (sAppleMode || !sIslandNotificationStackEnabled) return @[];
    if (sIslandNoticeItems.count < 2) return @[];
    NSMutableArray<NSDictionary *> *older = [NSMutableArray array];
    for (NSInteger i = (NSInteger)sIslandNoticeItems.count - 2; i >= 0 && older.count < kOITICardMax; i--) {
        NSDictionary *item = sIslandNoticeItems[(NSUInteger)i];
        if (item[@"startupHello"] || !item[@"info"]) continue;   // a running Detailed download is a card since batch 7
        [older addObject:item];
    }
    return older;
}

static BOOL OITICardsItemIsOnScreen(NSDictionary *item) {
    for (NSString *key in @[@"leadingView", @"trailingView", @"primaryView"]) {
        UIView *view = item[key];
        if ([view isKindOfClass:[UIView class]] && view.window) return YES;
    }
    return NO;
}

static BOOL OITICardsNewestIsOnScreen(void) {
    return OITICardsItemIsOnScreen(sIslandNoticeItems.lastObject);
}

// Where a card goes: centred under the Island's rectangle (kept on screen), `slot` cards further down.
static CGRect OITICardFrame(CGRect island, NSInteger slot) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat width = MIN(screen.width - 24.0, MAX(kOITICardMinWidth, island.size.width - 20.0));
    CGFloat x = floor(MAX(12.0, MIN(screen.width - width - 12.0, CGRectGetMidX(island) - width / 2.0)));
    CGFloat y = floor(CGRectGetMaxY(island) + kOITICardIslandGap + (CGFloat)slot * (kOITICardHeight + kOITICardGap));
    return CGRectMake(x, y, width, kOITICardHeight);
}

// `text` is only evaluated when the decision changed and level 1 logging is on.
static void OITICardsDecision(NSInteger code, NSString *(^text)(void)) {
    if (code == sCardsLastDecisionCode) return;
    sCardsLastDecisionCode = code;
    if ([sLog isLoggingAtLevel:1]) [sLog logLevel:1 tag:@"STACKCARDS" format:@"%@", text()];
}

static void OITICardsSetShown(BOOL shown) {
    if (sCardsShown == shown) return;
    sCardsShown = shown;
    UIView *root = sCardsWindow.rootViewController.view;
    [UIView animateWithDuration:shown ? 0.22 : 0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{ root.alpha = shown ? 1.0 : 0.0; } completion:nil];
}

static void OITICardsStopTimer(void) {
    [sCardsTimer invalidate];
    sCardsTimer = nil;
}

// ---- Motion -------------------------------------------------------------------------------------------------
static BOOL OITICardsMotionAllowed(void) {
    return !UIAccessibilityIsReduceMotionEnabled();
}

// Translated up by `dy` (negative) and slightly smaller: the pose of a card that is arriving or leaving.
static CGAffineTransform OITICardAway(CGFloat dy) {
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(0.0, dy), kOITICardAwayScale, kOITICardAwayScale);
}

// Where the card is drawn right now relative to where it is placed (its running transform animation's current offset).
static CGFloat OITICardVisualOffset(UIView *card) {
    CALayer *presentation = card.layer.presentationLayer;
    return presentation ? presentation.affineTransform.ty : card.transform.ty;
}

// ---- The morph copy -------------------------------------------------------------------------------------------
static void OITICardEndGhost(OITINoticeCardView *card, BOOL animated) {
    UIView *ghost = card.ghost;
    if (!ghost) return;
    card.ghost = nil;
    if (!animated) {
        [ghost.layer removeAllAnimations];
        [ghost removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ ghost.alpha = 0.0; } completion:^(BOOL finished) { [ghost removeFromSuperview]; }];
}

// A copy of the card starts as big as the Island's rectangle and travels to the card's place. It is a subview of the window (not of
// the root view), so it shows while the gate has the real cards hidden; the real card replaces it when it shows.
static void OITICardStartGhost(OITINoticeCardView *card, CGRect from) {
    CGRect to = OITICardFrame(from, 0);
    OITINoticeCardView *ghost = [[OITINoticeCardView alloc] initWithItem:card.item];
    ghost.userInteractionEnabled = NO;
    ghost.frame = from;
    ghost.layer.cornerRadius = MIN(MIN(from.size.width, from.size.height) / 2.0, 44.0);
    [sCardsWindow addSubview:ghost];
    [ghost layoutIfNeeded];
    const NSTimeInterval duration = 0.42;
    card.ghost = ghost;
    card.ghostEndsAt = CACurrentMediaTime() + duration;
    [UIView animateWithDuration:duration delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.0 options:0
                     animations:^{
                         ghost.frame = to;
                         ghost.layer.cornerRadius = kOITICardHeight / 2.0;
                         [ghost layoutIfNeeded];
                     } completion:nil];
    // If the cards never show (the gate stays closed), the copy must not stay on screen.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (card.ghost == ghost) OITICardEndGhost(card, YES);
    });
}

// A card that was added while the cards are showing: slides down from under the Island's card while it fades in.
static void OITICardPlayEnter(OITINoticeCardView *card, NSUInteger index) {
    card.entered = YES;
    if (card.ghost) {
        // The copy has done the travelling and covers the card: the card shows at once and the copy goes after the root's fade-in
        // (0.22 s) and its own travel are over, so the two never dip in brightness together.
        [UIView performWithoutAnimation:^{ card.transform = CGAffineTransformIdentity; card.alpha = 1.0; }];
        UIView *ghost = card.ghost;
        NSTimeInterval wait = MAX(0.26, card.ghostEndsAt - CACurrentMediaTime());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (card.ghost == ghost) OITICardEndGhost(card, YES);
        });
        return;
    }
    NSTimeInterval delay = 0.04 * (double)index;   // a burst of new cards arrives one after the other
    if (!OITICardsMotionAllowed()) {
        [UIView performWithoutAnimation:^{ card.transform = CGAffineTransformIdentity; card.alpha = 0.0; }];
        [UIView animateWithDuration:0.2 delay:delay options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ card.alpha = 1.0; } completion:nil];
        return;
    }
    [UIView performWithoutAnimation:^{ card.transform = OITICardAway(-kOITICardEnterOffset); card.alpha = 0.0; }];
    [UIView animateWithDuration:0.36 delay:delay usingSpringWithDamping:0.86 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ card.transform = CGAffineTransformIdentity; } completion:nil];
    [UIView animateWithDuration:0.24 delay:delay options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                     animations:^{ card.alpha = 1.0; } completion:nil];
}

// A card that stays but changes place: drawn where it was (plus any motion still running), then glides to the new place.
// Its center is set to the new place by the tick that follows, so the offset is the difference between the two places.
static void OITICardGlide(OITINoticeCardView *card, NSInteger fromSlot, NSInteger toSlot) {
    CGFloat step = kOITICardHeight + kOITICardGap;
    CGFloat visual = OITICardVisualOffset(card) + (CGFloat)(fromSlot - toSlot) * step;
    [UIView performWithoutAnimation:^{ card.transform = CGAffineTransformMakeTranslation(0.0, visual); }];
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ card.transform = CGAffineTransformIdentity; } completion:nil];
}

static void OITICardsHideWindow(NSString *why);

static void OITICardsFinishExit(OITINoticeCardView *card) {
    OITICardEndGhost(card, NO);
    [card removeFromSuperview];   // idempotent: also called for an animation that was cut short
    [sCardExiting removeObject:card];
    if (sCardsWindow && !sCardViews.count && !sCardExiting.count) OITICardsHideWindow(@"the last card left");
}

// A leaving card (swipe, tap, timeout, eviction, promotion into the Island): slides up and fades out, no longer takes touches.
static void OITICardStartExit(OITINoticeCardView *card, UIView *root) {
    OITICardEndGhost(card, NO);
    card.exiting = YES;
    card.userInteractionEnabled = NO;
    if (!sCardExiting) sCardExiting = [NSMutableArray array];
    [sCardExiting addObject:card];
    [root sendSubviewToBack:card];
    BOOL motion = OITICardsMotionAllowed();
    [UIView animateWithDuration:motion ? 0.2 : 0.15 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
                         card.alpha = 0.0;
                         if (motion) card.transform = OITICardAway(-kOITICardExitOffset);
                     }
                     completion:^(BOOL finished) { OITICardsFinishExit(card); }];
}

static void OITICardRemoveNow(OITINoticeCardView *card) {
    OITICardEndGhost(card, NO);
    card.userInteractionEnabled = NO;
    [card.layer removeAllAnimations];
    [card removeFromSuperview];
    [sCardExiting removeObject:card];
}

static void OITICardsHideWindow(NSString *why) {
    sCardsShown = NO;
    sCardsWindow.rootViewController.view.alpha = 0.0;
    sCardsWindow.hidden = YES;
    sCardsLastRect = CGRectZero;
    OITICardsDecision(0, ^NSString *{ return [NSString stringWithFormat:@"cards removed (%@)", why]; });
}

// No older notice is left. While the cards are showing they animate out and the window goes when the last one has left;
// otherwise (invisible anyway) everything goes at once.
static void OITICardsTearDown(NSString *why) {
    OITICardsStopTimer();
    if (!sCardsWindow) return;
    UIView *root = sCardsWindow.rootViewController.view;
    NSArray<OITINoticeCardView *> *live = [sCardViews copy];
    [sCardViews removeAllObjects];
    BOOL animate = sCardsShown;
    for (OITINoticeCardView *card in live) {
        if (animate && card.entered) OITICardStartExit(card, root);
        else OITICardRemoveNow(card);
    }
    if (!animate) for (OITINoticeCardView *card in [sCardExiting copy]) OITICardRemoveNow(card);
    if (!sCardExiting.count) OITICardsHideWindow(why);
    else OITICardsDecision(1, ^NSString *{ return [NSString stringWithFormat:@"cards leaving (%@)", why]; });
}

// Level 1: where the cards are against the Island and the screen, written when the geometry or the settings behind it change
// (batch 7, item 3: the size and position matrix; tools/cards_matrix.sh collects these lines). It only reports; nothing is moved.
static NSString *sCardsLastPlacement;
static void OITICardsLogPlacement(CGRect island) {
    if (![sLog isLoggingAtLevel:1] || !sCardViews.count) return;
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGRect first = OITICardFrame(island, 0);
    CGRect last = OITICardFrame(island, (NSInteger)sCardViews.count - 1);
    BOOL offScreen = CGRectGetMaxY(last) > screen.height - 4.0 || first.origin.x < 0.0 || CGRectGetMaxX(first) > screen.width;
    BOOL overlaps = CGRectIntersectsRect(CGRectInset(island, 1.0, 1.0), first);
    NSString *text = [NSString stringWithFormat:@"cards placement: island=%@ first card=%@ last card=%@ screen=%@ settings: scale=%d x=%.2f y=%.2f, custom position=%d y=%.1f%@%@",
                      NSStringFromCGRect(island), NSStringFromCGRect(first), NSStringFromCGRect(last), NSStringFromCGSize(screen),
                      (int)scaleEnabled, (double)sMetricsSensorX, (double)sMetricsSensorY, (int)posEnabled, (double)yPos,
                      offScreen ? @" WARNING: the cards leave the screen" : @"", overlaps ? @" WARNING: the first card overlaps the Island" : @""];
    if (![text isEqualToString:sCardsLastPlacement]) {
        sCardsLastPlacement = text;
        [sLog logLevel:1 tag:@"STACKCARDS" format:@"%@", text];
    }
}

// One tick: where the cards go and whether they show. Cheap; runs ~30 times a second only while cards exist.
static void OITICardsTick(void) {
    if (!sCardsWindow || !sCardViews.count) { OITICardsStopTimer(); return; }
    CGRect island = CGRectZero;
    BOOL haveIsland = OITICardsIslandRect(&island);
    BOOL onScreen = OITICardsNewestIsOnScreen();
    BOOL landscape = UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation);
    CFTimeInterval now = CACurrentMediaTime();
    id newestNow = sIslandNoticeItems.lastObject;
    if (newestNow != sCardsNewestKey || !onScreen) {
        sCardsNewestKey = newestNow;
        sCardsNewestOnScreenSince = onScreen ? now : 0.0;
    } else if (sCardsNewestOnScreenSince == 0.0) {
        sCardsNewestOnScreenSince = now;
    }
    BOOL settled = onScreen && sCardsNewestOnScreenSince > 0.0 && now - sCardsNewestOnScreenSince >= kOITICardNewestSettle;
    if (haveIsland) {
        CGRect last = sCardsLastRect;
        BOOL moved = fabs(island.origin.x - last.origin.x) > 0.75 || fabs(island.origin.y - last.origin.y) > 0.75 ||
                     fabs(island.size.width - last.size.width) > 0.75 || fabs(island.size.height - last.size.height) > 0.75;
        if (moved) {
            sCardsStableSince = now;
            sCardsLastRect = island;
            [sLog logLevel:2 tag:@"STACKCARDS" format:@"island rectangle changed to %@ (was %@)", NSStringFromCGRect(island), NSStringFromCGRect(last)];
        }
    }
    // The places are kept current whenever the Island's rectangle is known, shown or not: a card's glide is an offset from its
    // new place, so the place must already be the new one when the glide starts. Only the visibility waits for the gate.
    if (haveIsland) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (OITINoticeCardView *card in sCardViews) {
            CGRect frame = OITICardFrame(island, card.slot);
            card.bounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
            card.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        }
        [CATransaction commit];
    }
    BOOL stable = haveIsland && now - sCardsStableSince >= kOITICardStableAfter;
    BOOL wanted = haveIsland && onScreen && settled && stable && !landscape;
    if (!wanted) {
        OITICardsDecision(100 + haveIsland + 2 * onScreen + 4 * stable + 8 * landscape + 16 * settled, ^NSString *{
            return [NSString stringWithFormat:@"cards hidden: island rectangle %@, newest on screen=%d (settled=%d), stable=%d, landscape=%d",
                    haveIsland ? @"found" : @"NOT found", onScreen, settled, stable, landscape];
        });
        OITICardsSetShown(NO);
        return;
    }

    OITICardsDecision(1000 + (NSInteger)sCardViews.count, ^NSString *{
        return [NSString stringWithFormat:@"cards shown: %lu under island %@", (unsigned long)sCardViews.count, NSStringFromCGRect(island)];
    });
    OITICardsLogPlacement(island);
    OITICardsSetShown(YES);
    NSUInteger enterIndex = 0;
    for (OITINoticeCardView *card in sCardViews) if (!card.entered) OITICardPlayEnter(card, enterIndex++);

    CFAbsoluteTime seconds = floor(CFAbsoluteTimeGetCurrent());
    if (seconds != sCardsLastSecond) {
        sCardsLastSecond = seconds;
        for (OITINoticeCardView *card in sCardViews) [card refreshTimeText];
    }
}

static void OITICardsEnsureWindow(void) {
    if (sCardsWindow) {
        sCardsWindow.windowLevel = OITICardsWindowLevel();   // the Island's windows can change level
        return;
    }
    UIWindowScene *scene = OITICardsWindowScene();
    sCardsWindow = scene ? [[OITINoticeCardsWindow alloc] initWithWindowScene:scene]
                         : [[OITINoticeCardsWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    sCardsWindow.backgroundColor = [UIColor clearColor];
    OITINoticeCardsController *controller = [[OITINoticeCardsController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    controller.view.alpha = 0.0;
    sCardsWindow.rootViewController = controller;
    sCardsWindow.windowLevel = OITICardsWindowLevel();
    sCardsShown = NO;
    [sLog logLevel:1 tag:@"STACKCARDS" format:@"window created: scene=%@ level=%.0f", scene ? NSStringFromClass([scene class]) : @"none", (double)sCardsWindow.windowLevel];
}

// Builds the card for one older notice, with its own tap and swipe (aimed at that notice only).
static OITINoticeCardView *OITICardsBuildCard(NSDictionary *item) {
    OITINoticeCardView *card = [[OITINoticeCardView alloc] initWithItem:item];
    NSDictionary *info = item[@"info"];
    OITINoticeActions *actions = [OITINoticeActions new];
    actions.bundleID = info[@"bundleID"];
    actions.request = item[@"request"];
    actions.host = card;
    // The removal changes the stack and so the cards (this card leaves and its actions object goes with it), so it runs after
    // the recognizer's callback returns.
    actions.dismiss = ^{ dispatch_async(dispatch_get_main_queue(), ^{ OITIRemoveNoticeItem(item, @"swipe"); }); };
    actions.tapDismiss = ^{ OITIRemoveNoticeItem(item, @"tap"); };
    card.actions = actions;
    if (!card.isDownload) {   // a tap on a notice opens it; a download card has nothing to open (its swipe still hides it)
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:actions action:@selector(handleTap:)];
        [card addGestureRecognizer:tap];
    }
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:actions action:@selector(handleSwipe:)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    [card addGestureRecognizer:swipe];
    return card;
}

// Called whenever the stack changes: brings the cards in line with the stack. Cards of notices that are still older notices are
// kept (and glide if their place changed), new ones are added, notices that left or were promoted into the Island animate out.
void OITIStackCardsRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ OITIStackCardsRefresh(); });
        return;
    }
    NSArray<NSDictionary *> *older = OITICardsOlderItems();
    NSDictionary *previousNewest = sCardsPreviousNewest;
    sCardsPreviousNewest = sIslandNoticeItems.lastObject;
    BOOL downloadInStack = NO;
    for (NSDictionary *candidate in sIslandNoticeItems) if (candidate[@"download"]) downloadInStack = YES;
    if (!downloadInStack) sDownloadCardState = nil;   // the next download's card starts from its own values
    if (!older.count) {
        OITICardsTearDown(@"no older notice");
        return;
    }
    OITICardsEnsureWindow();
    if (!sCardViews) sCardViews = [NSMutableArray array];
    if (!sCardExiting) sCardExiting = [NSMutableArray array];
    UIView *root = sCardsWindow.rootViewController.view;
    BOOL showing = sCardsShown;   // the cards are visible now, so what changes is animated; otherwise it changes unseen

    NSMutableArray<OITINoticeCardView *> *leaving = [sCardViews mutableCopy];
    NSMutableArray<OITINoticeCardView *> *kept = [NSMutableArray arrayWithCapacity:older.count];
    NSUInteger added = 0, moved = 0, ghosts = 0;
    for (NSUInteger index = 0; index < older.count; index++) {
        NSDictionary *item = older[index];
        OITINoticeCardView *card = nil;
        for (OITINoticeCardView *candidate in leaving) if (candidate.item == item) { card = candidate; break; }
        if (card) {
            [leaving removeObjectIdenticalTo:card];
            if (card.slot != (NSInteger)index) {
                if (showing && card.entered && OITICardsMotionAllowed()) OITICardGlide(card, card.slot, (NSInteger)index);
                card.slot = (NSInteger)index;
                moved++;
            }
        } else {
            card = OITICardsBuildCard(item);
            card.slot = (NSInteger)index;
            card.alpha = 0.0;   // the tick plays its enter animation as soon as the cards show
            [root addSubview:card];
            added++;
            // The notice the Island was showing a moment ago and a new notice has just pushed down: it travels from the Island.
            CGRect islandNow;
            if (item == previousNewest && OITICardsMotionAllowed() && !UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation) &&
                CFAbsoluteTimeGetCurrent() - [item[@"postedAt"] doubleValue] > 0.8 && OITICardsItemIsOnScreen(item) &&
                OITICardsIslandRect(&islandNow)) {
                OITICardStartGhost(card, islandNow);
                ghosts++;
            }
        }
        [kept addObject:card];
    }
    NSUInteger left = leaving.count;
    for (OITINoticeCardView *card in leaving) {
        if (showing && card.entered) OITICardStartExit(card, root);
        else OITICardRemoveNow(card);
    }
    [sCardViews setArray:kept];

    sCardsWindow.hidden = NO;
    sCardsLastSecond = 0;
    sCardsLastDecisionCode = -1;
    [sLog logLevel:1 tag:@"STACKCARDS" format:@"refresh: %lu older notice%@ as cards (stack of %lu): %lu new, %lu leaving, %lu moved, %lu morphing from the Island, animated=%d, reduce motion=%d",
     (unsigned long)older.count, older.count == 1 ? @"" : @"s", (unsigned long)sIslandNoticeItems.count, (unsigned long)added,
     (unsigned long)left, (unsigned long)moved, (unsigned long)ghosts, (int)showing, (int)!OITICardsMotionAllowed()];
    if (!sCardsTimer) {
        sCardsTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *timer) { OITICardsTick(); }];
        [[NSRunLoop mainRunLoop] addTimer:sCardsTimer forMode:NSRunLoopCommonModes];
    }
    OITICardsTick();
}

// Called by the download tracker whenever it writes the Detailed look (batch 7, item 5), so a download card shows the same state.
void OITIStackCardsDownloadUpdate(NSString *header, NSString *percent, double fraction, NSInteger ending) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ OITIStackCardsDownloadUpdate(header, percent, fraction, ending); });
        return;
    }
    sDownloadCardState = @{ @"header": header ?: @"", @"percent": percent ?: @"", @"fraction": @(fraction), @"ending": @(ending) };
    for (OITINoticeCardView *card in sCardViews) if (card.isDownload) [card applyDownloadState:sDownloadCardState];
}
