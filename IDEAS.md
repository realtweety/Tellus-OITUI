# OITUI Ideas



## 12 Nov 2026: roadmap decisions and a big list of ideas

Where this differs from the 0.4.0 wording in the roadmap bullet under "OITI: current state and next candidates", this section is newer. Plans after 0.4.0 are still open; the list below is a pool to pick from, not a commitment.

### Decisions for 0.4.0 (owner, 12 Nov 2026)

- **Landscape Island Notifications without Apple's Dynamic Island.** All views and rendering are done by OITI itself, in a window of its own (as the stack cards in `OITINoticeStackCards.xm` already are). Open questions for batch 1, none researched yet: where our window gets the interface orientation from (SpringBoard's own window does not rotate with the apps), how a landscape card is styled so it matches the portrait Island look, how it avoids or hides Apple's own landscape banner, and its own off-by-default switch (off in Apple Mode). Testable only on the iPhone 8 Plus; real Dynamic Island hardware in landscape cannot be verified.
- **One-command tester report.** A script in `tools/` (for SSH use) and a button in Insula's settings (maybe a dedicated section or menu) that collects the report and copies it to the clipboard: build tag, device model, iOS version, every setting that differs from its default, safe-mode and self-check state, the log tail, Dopamine and package versions. Design points: the collection runs in the Settings bundle process with no change to the launch path; live SpringBoard state, if needed, is requested on demand through a notification (cheap observer at launch, the work only when the button is pressed). Before shipping: grep every log call site for notification titles or text, show a preview and list what the report contains, and say that Universal Clipboard can sync it to the user's other devices.
- **Icons.** Make icons for Tellus, Insula, Litus and the rest of the family (the owner is tired of plain text names). Starting points are in "Icon concepts (not yet made, no urgency)" at the end of this file, which still uses the old module names (OITI is Insula, OITS is Litus, OITUI is Tellus).

### Ideas for Insula (31 items; major, medium, small, infrastructure)

**Major**

1. Landscape Island notifications with our own views (0.4.0).
2. Download Progress round 2: bytes, speed and ETA for browsers, once the browser protocol carries them.
3. Several downloads at once, as a small stack.
4. A real Island queue, so music, timer and download do not fight over the space (needs a content mechanism first).
5. Context awareness: the Island adapts to the foreground app (needs a content mechanism first).
6. Presets (Minimal, Stock-like, Compact) in one tap, plus export and import of all settings as a file.
7. A live preview inside the Settings page that draws the Island at the chosen size.
8. A notification history or timeline you can scrub back through.
9. Notification snoozing.
10. Focus and Do Not Disturb awareness for Island notifications.

**Medium**

11. Per-app exclude list for Island Notifications (the list logic is easy, the app picker in the Settings bundle is the real work).
12. Per-app accent colors for notifications.
13. Tapping the download Island opens the app or its downloads list.
14. Pause and resume where a browser supports it (Arc has no pause, per the 0.3.5 measurements).
15. A finish haptic or sound for downloads, off by default.
16. An Installing/Updating state for the App Store beyond percentage (the Installing state already exists, so this would be small).
17. A "why is Insula off?" page showing safe-mode state, the last self-check and the respring-loop guard counter.
18. A Diagnostics page in Settings with a level toggle, so users do not need SSH.
19. Hello animation variants or a customizable clip.
20. Reduce Motion, VoiceOver labels and Dynamic Type support for the custom cards (accessibility has not been looked at yet).
21. Low Power Mode behavior: fewer animations.

**Small and tiny**

22. Banner position at extreme Island sizes (known polish item).
23. A lower Island Height slider minimum (about 0.6 is where 22 pt artwork stops fitting, untested).
24. A Respring button at the top of the Settings page, if there is not one already.
25. A "Reset this page" action on every settings page.
26. Show the download source in the Detailed look, such as the app or browser name.
27. Review the timeout slider ranges and units for the notifications.
28. A Sileo/Zebra depiction with a short changelog and the supported-devices note.

**Infrastructure and branding**

29. A tester-report parser on the PC that builds a compatibility table from pasted reports.
30. Remove the legacy position migration, but only in 0.5.0 or later, so people upgrading from before 0.3.0 still get migrated.
31. Icons for Tellus, Insula, Litus and OITCore (see the decision above).

Claude's top picks after 0.4.0 (a proposal): 6 (presets plus export), 17 and 18 (self-service diagnostics, which pair with the report button) and 2. Items 4 and 5 are research projects, not releases. The volume slider and the OITUI companion app stay skipped (Crescendo already covers the slider; the app is a separate project).

## OITI: current state and next candidates

- **Island Notifications (0.2.0; stack tested on-device).** The owner tested bursts of four on an iPhone 8 Plus running iOS 16.7.16. The newest notice is the Island notification in the chosen Style; the older ones are small OITI-drawn cards below the Island (since build `OITI-exp-2026-11-03-d`; before that they were compact cards inside the newest notice's card). Capacity is four; new notices evict the oldest. Timeout restarts on demotion to compact and promotion, and items can be dismissed individually. Lock-screen-only deliveries still bypass the banner path. The stack is usable but explicitly experimental and not polished.
- **Preset device positions (done in batch 8, build `OITI-exp-2026-11-07-a`).** Fix Island Position and Fix Notification Positioning were removed on the owner's decision (measuring every phone would take forever and people change the position anyway); a one-time migration turns an enabled Fix switch into a custom position. `OITIDeviceProfiles.h` stays for the migration, Status Bar Layout Automatic and the custom banner's size; delete the migration (and the offsets) in a later release. The measurement protocol in `DEVICES.md` is now only needed if a new per-device value is ever wanted.
- **Roadmap (owner's decisions, 9 and 12 Nov 2026).** Released: `0.3.1` (blink fix), `0.3.5` (Arc Search downloads in Download Progress, percentage only). `0.3.6`: the file name of a browser download in the Island (a second channel from the browser; where Arc exposes the name is unknown, research first) plus Safari and Chrome (ship what is device-tested, the rest moves to 0.3.7; Chrome is `com.google.chrome.ios`, Safari research is pending on the owner's phone); one switch for all browsers, labelled "Show Browser Downloads" (a per-browser menu only if someone asks). `0.4.0`: Landscape Island Notifications (measure the Island and the cards in landscape first; cards are portrait only today) plus a few smaller items chosen from this file (proposals: the per-app exclude list for Island Notifications, the banner position at extreme Island sizes). **Lock screen cards: scrapped completely, do not suggest them again.** Later, not decided: iPhone 8 / 8 Plus device-table entries, testers for notched phones and real Dynamic Island hardware, what to do with OITS, the OITUI companion app.
- **Release process decisions (8 Nov 2026).** No beta for 0.3.0. Release notes live only in the GitHub Release body. Before the release both the owner and Claude must agree it is ready; Claude gives an honest, unbiased verdict from the test results. Landscape and lock screen cards are deferred to a later release (for example 0.5.0). Cleanup of code and docs is part of the release-candidate batch, not done before the polish was finished (done in the batch of 8 Nov 2026: dead `fixEnabled` and `notificationFix` globals, the device-warning code in the Settings bundle and the unused item keys `secondaryStack` and `secondaryBody` are gone; the migration and every stored key stay; the migration is deleted in a later release).
- **Settings controls (device-tested).** The owner reports the controls feel more responsive after reducing slider preference-write frequency, saving text fields on editing end, updating picker labels in place, making switch labels tappable, and refreshing custom controls after reset actions.
- **Dedicated toggles:** `islandNotificationsEnabled` controls custom Island notifications (default off); `islandNotificationStackEnabled` controls multi-notice stacking (default on to preserve existing behavior). Settings labels and warning text call out that stacking is experimental and usable but unpolished.
- **Remaining notification work:** Verify Compact/Wide and real notification paths broadly, confirm timeout behavior over longer intervals, test on real Dynamic Island hardware and other iOS 16 builds. Keep the current card layout unless owner asks to revisit it. Progress bars are a possible later addition. Tap behavior: a tap opens the notification and leaves the notice until timeout or swipe; the optional Dismiss When Tapped switch (`NotificationTapDismisses`, default off, build `OITI-exp-2026-11-03-a`) removes it after the tap. A tap on the Hello opens Insula's page in Settings (`prefs:root=Insula`, build `OITI-exp-2026-11-03-b`). **Stack rework (batch 5, done):** the older notices are OITI-drawn compact cards below the Island (icon, message, how long ago) with their own tap and swipe; the in-card look and its Stack Look setting were removed in build `OITI-exp-2026-11-03-d` after the owner tested the cards. Later: opening the exact older notification (needs a dump of what the stored request offers), animation polish (done in batch 6, build `OITI-exp-2026-11-05-a`, untested on the phone: persistent card views, slide and fade in, glide, slide and fade out, Reduce Motion), the Island size and position matrix for the cards, a card for a running download (done in batch 7, build `OITI-exp-2026-11-05-b`, untested on the phone), landscape (deferred to a later release, for example 0.5.0).
- **Hello Startup Animation (0.2.0).** The off-by-default toggle waits until the device is unlocked and SpringBoard is active on the Home Screen, checks a persistent five-minute cooldown, and shows an expanded Island element. The owner confirmed the Home Screen gate, video sizing, cooldown, uninstall, toggle and interruption behavior on-device. The AVPlayer-backed view plays the supplied SVG-derived clip once without audio and removes the Island element when playback ends or fails. While it plays, charging activity is kept registered but placed behind the startup animation; calls and other Island activity take priority. The bundled H.264 clip is 1280×720, six seconds, white on black; its last frame is black and is held for 0.5 s before the element is removed (`kOITIStartupHelloEndHold`).
- **Volume slider:** deferred after an initial implementation was removed because it did not work and did not seem broadly useful.
- **Polish list** (owner chose to defer): live color, opacity and banner offset (done on `experiments`, build `OITI-exp-2026-10-21-a`, tested on-device); banner position at extreme Island sizes; make the X/Y scale relative to Apple's own size (done on `experiments`, build `OITI-exp-2026-10-21-b`: new keys `RelativeScaleX` / `RelativeScaleY`, no migration, tested on-device); maybe lower the Island Height slider minimum (around 0.6 is where 22 pt artwork stops fitting, untested).
- **Per-app exclude list for Island Notifications.** Deferred until someone asks for it (keep Phone or Timer on the stock banner, for example).
- **OITS** is parked: revert or adapt to the `_UIStatusBarProvider_DynamicSplit` layout class, rebuild the lost diagnostic fixes, restore the scoping guard.

## Things I Think Would Be Nice

- **Modular architecture**: split `Tweak.xm` into modules (`Modules/Music`, `Modules/Phone`, etc.)
  instead of one growing file. **Status:** done (see "Split `Tweak.xm` into module folders" below): `OITI/Diagnostics/`, `OITI/DownloadProgress/`, `OITI/IslandSize/`, `OITI/IslandNotifications/`, `OITI/Startup/`, `OITI/StatusBar/`, `OITI/Safety/` and `OITI/Shared/`. Step 1 added a shared device table
  (`OITIDeviceProfiles.h`).
- **Device awareness**: done as a table in `OITIDeviceProfiles.h` (17 models, each marked verified or estimated).
  Remaining: entries for iPhone 8 / 8 Plus (needs on-device measurement; protocol and identifier check in `DEVICES.md`, batch 1 of the 0.3.0 polish) and more devices. The identifiers for iPhone 14 Plus, SE 2 and SE 3 are confirmed (`DEVICES.md`) but none has an entry: no offsets have been measured for them.
- **Apple Mode vs Enhanced Mode**: done on `experiments` (build `OITI-exp-2026-10-21-b`, tested on-device) as a single `appleMode` switch that forces every Island customization off and keeps Enable Dynamic Island, the built-in position and notification fixes, the Status Bar Layout setting and safe mode.
- **Developer/debug overlay**: FPS, render time, active Island state, and other useful runtime diagnostics. Keep it focused on information that can actually be measured on-device.
- **Crash recovery for an expanded Island state**: done on `experiments` (build `OITI-exp-2026-10-21-c`, tested on-device) as a live-element breadcrumb file plus a 120 s window at the next launch in which Island notifications and the startup animation stay off. Nothing about the expanded Island is persisted across a SpringBoard restart, so the real risk was a re-delivered notification rebuilding the element that crashed.
- **Island Stacks / queue**: multiple things (music, timer, download) don't fight for the
  same space -- swipeable or queued instead of clobbering each other. Needs a content mechanism first (Step 3 research).
- **Context awareness**: Island content adapts to foreground app (Maps -> nav controls,
  Spotify -> media controls). Needs a content mechanism first.
- **Universal progress bars**: any app/tweak can expose a progress value the Island renders
  generically. Precursor to a real plugin API. First use: **download progress** (stage 1 appearance finished and working on the owner's phone; stage 2, the App Store source with a
  percentage-only tracker input, is implemented on `experiments`, build `OITI-exp-2026-10-25-a`, tested on the owner's phone; browsers are stage 3, a separate project; later ideas: the return-to-idle limit by percentage is done (`DownloadIdleAfterPercent`, build `OITI-exp-2026-11-03-b`, untested on the phone); the Face ID-style completion check is done for the Minimal look in build `OITI-exp-2026-10-26-a`, tested on the owner's phone, and for the Detailed look as a small badge in the trailing slot in build `OITI-exp-2026-11-03-b`, untested on the phone). Owner's decisions: downloads first; App Store and Safari
  as the first real targets, Chrome and Arc later (they need hooks inside each app); return to idle by MB downloaded and/or
  seconds on screen, user-chosen; off by default; a fake download for testing. Timers and other sources can use the same
  tracker later.
- **OITUI App**: Make a whole new app specifically for customizing OITUI tweaks like OITI and OITS. I would probably add in some sort of live preview to show the user what their settings would look like before they apply everything. It would essentially just move OITUI tweak customization from Settings to a dedicated app
- **Volume Slider**: It might be a cool idea to try and move the volume slider into the dynamic island somehow, maybe do the same thing with other sliders and indicators and whatnot.
  **Note:** the tweak Crescendo (github.com/Yves000/Crescendo, GPL-3.0) already does this for the expanded media player by
  building a slider from Apple's own `MRU*` parts inside MediaRemoteUI. Worth studying (and checking for conflicts with OITI) before building our own.

## Decent Ideas

- **Clipboard history/pinning/OCR**
- **Quick calculator / unit / currency conversion**
- **Translation popup**
- **Universal timer stack, stopwatch controls**
- **Volume mixer, brightness slider, flashlight controls in-Island**
- **Detailed battery stats** (current draw, watts, temp, estimate)
- **Bluetooth/WiFi/VPN quick switches**
- **Live CPU/RAM/FPS/network monitors**
- **Package installer, respring menu in-Island**
- **Notification snoozing**
- **Command palette / Island search**
- **Macros** ("Good Night" -> multiple actions at once)
- **Pin/favorite specific Island cards**
- **Smart/predictive suggestions** (AirPods connect -> show ANC controls)
- **Automation rules** ("if X then Y")
- **Themes / material profiles / per-app accent colors**
- **Notification timeline / scrub-back history**

## Entirely Different Things and Projects

- **Plugin marketplace / public SDK for other tweak devs**: assumes external adoption that
  doesn't exist yet. Build after OITI itself is solid, not before.
- **Anything needing live third-party network calls** (translation APIs, currency, "AI
  quick actions"): different risk/complexity class than anything built so far -- API keys,
  rate limits, offline failure modes. Not until the core system is proven.
- **"Island Studio" companion app**: a second, separate piece of software with its own
  toolchain. Not a feature -- a different project.
- **Merging OITS and OITI into one unified status/event engine**: genuinely interesting
  long-term direction (shared module system, status bar flowing into the Island), but
  premature to design before either one individually works.

## Notes on hype language

Ignore any "120fps guaranteed / zero dropped frames / immeasurable battery impact" framing
from brainstorm sessions -- that's marketing language, not an engineering target. Any renderer
that does real rendering or compositing work should have honest performance budgets set only after
on-device measurement, not before.

## Confirmed via OITInspector dump (2026-07-16)

- `SBSystemApertureStatusBarPillElementProvider` / `SBSystemApertureStatusBarPillElement` exist
  as real classes on-device. These appear to be Apple's own connective tissue between the status
  bar layout system and the Dynamic Island -- worth investigating directly if we ever pursue the
  "status bar flows into the Island" idea for real.
- **Correction (Oct 2026):** the status bar content *is* ordinary UIKit subviews: `_UIStatusBar` -> `_UIStatusBarForegroundView` ->
  per-element views (`_UIStatusBarStringView`, `_UIBatteryView`, wifi and cellular signal views, network type view). OITS already
  moves individual elements. `SBMainDisplaySceneLayoutStatusBarView` is only a full-screen container with no UIKit children.
  OITInspector can't enumerate the persistent `UIStatusBarWindow`; use FLEX or the OITS diagnostic dump (`DIAGNOSTICS.md`).

## Confirmed via dumps (Oct 2026)

- The Island can be resized without scaling its content: scale `SBUISystemApertureLayoutMetrics -sensorRegionSize` (the root input). Done and released in v0.1.0 as the Island Size sliders.
- Apple has a content element model (`SBSystemApertureProvidedContentElement`, `SBUISystemApertureCustomContentProvider`, `SAUISystemApertureManager`, `SBSystemApertureElementAuthority`) that may let OITI add its own elements as real Island elements. This replaces the "own overlay window" idea as the default plan.

## Confirmed via code review (Oct 2026)

- OITI is a positioning/appearance shim over Apple's real Dynamic Island. `islandEnabled` spoofs `ArtworkDeviceSubType` (2556) so
  iOS builds SystemAperture; `Tweak.xm` hooks `SBSystemApertureWindow`, `SBBannerWindow` and a few appearance views. Island content
  (music, timers) is Apple's. The Island's expanded media player is rendered by the **MediaRemoteUI** process (per Crescendo's README).
- Next research step (done in October 2026): the element route was chosen and works. Notes: `LEARNINGS.md`, "Island elements".

## Infrastructure ideas (from the OITI review and Crescendo)

- **Split `Tweak.xm` into module folders** (owner's idea; agreed on 2026-10-28 as the next step before 0.3.0, plan and order in `OVERVIEW.md`, "The Great Split"): for example `OITI/Download Progress/`, `OITI/Resizing/`, `OITI/Notifications/`, `OITI/Startup/`, with a small shared core for logging, preferences and the element machinery. Folder names with spaces are fine for Theos but a nuisance in shell commands, so `DownloadProgress/` is probably better. The work is mostly moving code without changing behavior, which makes it risky in one big step: do it one module at a time with a build and a short device check after each, starting with the most self-contained one (the download tracker and its views, which only touch the element presenter through two calls). The file list lives in `OITI/Makefile` (`OITI_FILES`), and Logos `%hook` groups can sit in `.xm` files in any folder (initialised from a small function in the same file). **Status:** done. All eight rounds (Diagnostics, DownloadProgress, IslandSize, IslandNotifications, Startup, StatusBar, Shared and core with Safety, shared runtime helpers) were built and checked on the phone, and the split shipped as 0.2.5 (`v0.2.5`).

- **Respring-loop safe mode**: auto-disable OITI features after repeated respring cycles in a short window.
- **Startup self-check** for the MobileGestalt spoof: log when `islandEnabled` is on but the cache no longer holds the spoofed value.
- **Shared logging in OITCore** (`OITLog`): async, rate-limited, state-change logging, reused from the OITS diagnostic build.
- **Live settings** over a Darwin notify-token state with a preferences fallback, so most changes need no respring.
- **Clean-uninstall guarantee**: removing a package removes everything it wrote (already true for the MobileGestalt value via `prerm`).
- **Contributor hygiene**: issue templates and a short CONTRIBUTING file.

## Icon concepts (not yet made, no urgency)

- **OITI**: Capsule/pill silhouette (the Island's actual shape) with something
  happening subtly *inside* it -- a small glass refraction highlight, or the
  pill mid-morph into a slightly different shape. Dark background, single
  accent color, restrained rather than busy.
- **OITS**: Thin status-bar-shaped bar across the top of the icon, split
  left/right with a small gap in the middle (echoing the iOS 26/27 layout
  target) -- clock glyph on one side, signal/battery glyphs on the other.
- **OITCore**: Not user-facing, so probably skip a "cute" icon -- simple
  geometric mark (hexagon/gear) is enough.
- **OITUI (whole project)**: TBD -- needs to feel like it ties the family
  together once the individual module icons exist. Revisit after the others
  are settled so it doesn't clash.
