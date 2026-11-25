# OITUI Ideas

> **Purpose:** This file is the pool of things OITUI *could* do. Nothing here is promised, approved, scheduled, or assigned to a release unless the owner explicitly moves it into `PLANS.md`.
>
> Ideas may be researched, prototyped, changed, postponed, rejected, or removed. Claude may rank options and explain trade-offs, but must not treat this file as a list of commitments, and must not move an idea into `PLANS.md` or start building it without the owner's explicit decision.

## How to read this file

Every entry starts with one of these labels:

- **Candidate**: potentially worthwhile; not approved for implementation.
- **Research**: needs technical investigation or a prototype before its value or feasibility is clear.
- **Dependency**: depends on another capability being designed or completed first.
- **Parked**: deliberately postponed; do not restart without revisiting the owner's decision.
- **Low fit**: possible in theory, but it seems outside Insula's purpose or offers too little value for its cost.
- **Closed**: explicitly rejected or superseded; do not reintroduce without the owner's request.

Rules for this file:

- Do not add release numbers or dates to ideas. If the owner decides an idea is coming, move it into `PLANS.md`.
- When something ships, delete it from this file. Shipped work is documented in `OVERVIEW.md`, `LEARNINGS.md` and the Git history, and must not be left looking like future work.
- Keep one authoritative entry per idea.
- The numbered list that older documents and source comments cite (for example "IDEAS #13") is retired. Those numbers refer to the version of this file from 12 November 2026, which is in the Git history.

---

## 1. Insula ideas

### Island content and Download Progress

- **Candidate: Download Progress round two.** Show bytes downloaded, transfer speed and ETA for browsers once a browser's download source exposes reliable data. The current browser integrations may not provide all of these fields.
- **Candidate: Several simultaneous downloads.** Show multiple downloads together, potentially as a compact stack.
- **Candidate: More download sources.** Add a browser or app only where a stable download source can be measured and tested on the device.
- **Candidate: Browser pause/resume.** Expose pause or resume only for browsers that genuinely support it. Arc was measured as not supporting pause; never show a fake or ineffective control.
- **Candidate: Download completion feedback.** Optional haptic or sound when a download finishes, off by default.
- **Research: Richer App Store Installing/Updating state.** Distinguish installation and update activity more clearly than a percentage alone. An Installing state already exists, so first identify exactly what information is still missing.
- **Research: Private/incognito browser download checks.** Safari Private Browsing downloads are hidden because the web view's data store is not persistent. Arc Search and Chrome behaviour has not been measured. Compare normal and private downloads in each browser, and verify whether the public `WKDownload` information can reliably identify the originating web view or tab, before changing anything.
- **Dependency / Research: A real Island content queue.** Stop music, timers, downloads and other activities from constantly replacing one another. This needs a content-management mechanism and clear priority and interruption rules first.
- **Dependency / Research: Context awareness.** Adapt Island content to the foreground app or activity (for example media controls in a music app). Needs the same content-management foundation and careful privacy and resource decisions.
- **Research: Universal progress representation.** Let an activity provide progress information that Insula renders consistently. Download Progress is the natural first use. A public third-party API is a much later, separate decision.
- **Dependency / Research: Internal content-provider mechanism.** A stable internal way for OITUI components to register content or progress with Insula. This is the prerequisite for a real queue, context-aware content and broader progress support. Start internal; a public SDK is not implied.

### Notifications

- **Candidate: Notification stack validation and polish.** Before adding more notification behaviour, test the existing stack more broadly: Compact and Wide layouts, real delivery paths, timeouts over longer intervals, real Dynamic Island hardware and other iOS 16 builds, and the card size and position matrix.
- **Low fit: Per-app notification exclusion list.** Keep selected apps (for example Phone or Timer) on Apple's stock presentation. The app picker and Settings-bundle behaviour are the hard part. The earlier decision was to defer it until someone asks; keep it low priority without real demand.
- **Candidate: Per-app accent colors.** Consider only after the notification styling model is stable.
- **Research: Notification history/timeline.** Browse earlier notifications. Raises storage, retention, privacy, clearing and capacity questions.
- **Research: Notification snoozing.** Defer a notification and bring it back later. Needs research into what iOS notification delivery and scheduling allow reliably.
- **Research: Focus and Do Not Disturb awareness.** Adapt Island notification behaviour to the current Focus state.
- **Dependency: Progress display in notification cards.** A possible use of the content and progress mechanism; not a current priority.

### Appearance, configuration and interaction

- **Candidate: Presets.** One-tap configurations such as Minimal, Stock-like and Compact.
- **Candidate: Export/import all settings.** Back up or transfer a configuration as a file. The format needs a schema version, value validation, defaults for missing keys, and rejection of malformed input.
- **Research: Live Settings preview.** Preview the Island at the selected size and appearance. It must match real behaviour closely enough not to mislead; a decorative approximation is not useful.
- **Candidate: Hello animation variants or a custom clip.** Keep accessibility, animation cost and failure handling in mind.
- **Research: Accessibility for custom cards.** Investigate VoiceOver labels, Dynamic Type and Reduce Motion. The custom cards have not had a complete accessibility review.
- **Candidate: Low Power Mode behaviour.** Simplify or reduce animations when Low Power Mode is on.
- **Research: Banner positioning at extreme Island sizes.** Test the full size and position matrix before changing any geometry.
- **Research: Lower minimum for the Island Height slider.** A value around 0.6 was suggested, but the 22 pt artwork may stop fitting. Measure first.
- **Candidate: Notification timeout slider review.** Confirm ranges, units, labels and actual timing.
- **Candidate: Sileo/Zebra package depiction improvements.** A concise changelog and an accurate supported-device note.

### Diagnostics and developer tools

- **Candidate: PC-side tester-report parser.** Turn pasted tester reports into a compatibility table (device model, iOS version, package versions, settings, reported results). Keep privacy-sensitive content out of the report and the table.
- **Candidate: Developer/debug overlay.** Optionally show measured FPS, render time, active Island state and similar values. Developer-focused; show only what can genuinely be measured.
- **Low fit: More diagnostic controls.** Revisit only if the existing Insula diagnostics in Settings and Tellus's Insula Status page leave a concrete support problem unsolved. Do not build duplicate diagnostics surfaces.

---

## 2. Tellus and updater ideas

These are not part of the accepted updater plan unless they appear in `PLANS.md`.

- **Candidate: Dynamic Double Tap Opens Tellus hit zone.** Make the touch zone follow the Island's actual position, size and scale. The shipped zone is a fixed band near the default Island location (60 pt from the top, 90 pt either side of the middle); more extreme custom layouts may fall outside it.
- **Candidate: Package version from reliable metadata.** Read a package's version from its metadata or the release data rather than from the asset filename. GitHub can rewrite characters such as `~` in asset names, which can break prerelease handling. See `WORKFLOW.md`.
- **Candidate: Clean stale staged packages.** Remove obsolete staged `.deb` files left in `/var/mobile/Library/Caches/TellusUpdates`. A Tellus self-update leaves its own staged package, and the staged `SHA256SUMS` and `SHA256SUMS.sig`, because dpkg ends the app before it can clean up.
- **Candidate: Insula update note with an inline respring action.** After Insula is installed, offer the respring action in the same row instead of only explaining it in text.
- **Research: Verify download source in the Detailed view.** The `App Name - File Name` headline may already show the source. Check on the device before changing anything, and do not duplicate existing UI.
- **Parked: Litus in Tellus and the updater.** When Litus work resumes and the owner brings it back into scope, add its package ID to the allowlists in `tellus-helper.c` and `PackageInstaller.swift`, and add its app pages. No partial integration before that decision.

---

## 3. Infrastructure, maintenance and branding ideas

- **Candidate: Remove the legacy position migration.** Only after verifying that users upgrading from versions before the migration keep their intended settings. Do not tie its removal to a version number.
- **Research: Clean-uninstall audit.** Check that every package removes the files, preferences, caches and system values it creates. The MobileGestalt value cleanup through `prerm` is known; that alone does not prove a complete path for every package.
- **Candidate: Conditional device-table additions.** Add or revise a device entry when a real compatibility need exists and measurements can be obtained (`DEVICES.md`). Measuring every iPhone is not a project of its own.
- **Candidate: Icons for the OITUI family.** A consistent identity for Insula, Tellus, Litus and OITCore. The concepts below are starting points, not requirements.
- **Low fit: A `CONTRIBUTING.md`.** Issue templates exist. Add a concise contributing guide only if outside contributions become relevant.
- **Parked / Research: Shared architecture with Litus.** A shared status and event engine could let status-bar information flow into the Island. Apple has `SBSystemApertureStatusBarPillElementProvider` and `SBSystemApertureStatusBarPillElement`, which may matter if that connection is researched. Premature while Litus is parked and Insula's content architecture is still evolving.

### Icon concepts

- **Insula:** a capsule silhouette based on the Island, with a subtle detail or activity inside. Dark background, one restrained accent colour.
- **Litus:** a thin status-bar-inspired shape divided left and right with a small centre gap, for example a clock on one side and signal and battery on the other.
- **OITCore:** a simple geometric mark such as a hexagon or gear. It is infrastructure rather than a user-facing app and needs no conventional icon.
- **OITUI as a family:** decide after the individual identities are settled.

---

## 4. Low-fit brainstorm

These have been mentioned but are not recommendations for Insula. They are a record, not a feature queue.

- Clipboard history, pinning or OCR.
- Quick calculator, unit conversion or currency conversion.
- Translation popup.
- Universal timer stack or stopwatch controls (overlaps with the content queue above).
- A volume slider, brightness slider, flashlight or volume mixer in the Island. Crescendo already provides the expanded-media-player slider using Apple's `MRU*` components in MediaRemoteUI, and an earlier Insula attempt was removed. Revisit only for a concrete compatibility gap.
- Detailed battery statistics such as draw, watts, temperature and remaining-time estimates.
- Bluetooth, Wi-Fi or VPN quick switches.
- Live CPU, RAM, FPS or network monitors for ordinary users.
- A package installer or respring menu inside the Island. The installer belongs in Tellus.
- Command palette or Island search.
- Macros, multi-action routines and automation rules.
- Pinning or favouriting particular Island cards.
- Smart or predictive suggestions, such as showing ANC controls when AirPods connect.
- Themes, material profiles and per-app styling systems beyond notification accents.

---

## 5. Parked, closed or superseded directions

These decisions are context. Do not silently turn them back into proposals.

### Parked

- **Landscape Island notifications.** On hold for a long while. The original proposal used Insula-rendered landscape views in their own window, with unresolved questions about orientation, styling, Apple's own landscape banner, and testing on real Dynamic Island hardware. Parked, not cancelled.
- **Litus.** Parked. Known remaining work: adapt to the `_UIStatusBarProvider_DynamicSplit` layout class, rebuild lost diagnostic fixes, and restore the scoping guard. Resume only when the owner decides to.
- **Public plugin marketplace or SDK.** Possibly interesting once Insula and its internal content mechanism are mature; premature now, because it creates API stability, compatibility, documentation, security and support commitments.
- **Live third-party network features.** Translation APIs, currency services and AI quick actions. They bring API keys, rate limits, network failures and ongoing service dependencies that are outside the current core.
- **A unified Insula and Litus status-event engine.** A possible long-term direction, but not before both work independently and there is a clear shared interface.

### Closed or superseded

- **Lock-screen notification cards.** Explicitly scrapped. Do not suggest them again unless the owner reopens the decision.
- **A separate OITUI customization companion app.** Superseded by Tellus. Do not propose a second app that merely moves the same settings out of the Settings bundle.

---

## 6. Principles for evaluating ideas

- Avoid marketing claims such as guaranteed 120 FPS, zero dropped frames or immeasurable battery impact. Set performance budgets from on-device measurements.
- Custom renderers and compositing work need measured performance, memory and battery testing.
- Keep default logging off unless the owner explicitly changes that decision.
- Prefer small, testable changes. The module split worked because it was done one round at a time with a build and a short device check each time.

## 7. References

The current documentation is the source of truth when implementation details have changed:

- `PLANS.md`: accepted, owner-approved future work.
- `OVERVIEW.md`: current project state and development history.
- `LEARNINGS.md`: measured behaviour and technical findings.
- `COMMANDS.md`: repeatable device-testing and diagnostic procedures.
- `DEVICES.md`: device identifiers and measurement notes.
- `DIAGNOSTICS.md`: diagnostic procedures and status-bar investigation notes.
- `WORKFLOW.md`: build and release workflow, asset and version handling.
