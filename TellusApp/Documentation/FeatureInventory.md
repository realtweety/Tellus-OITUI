# Tellus feature and preference inventory

Source reviewed on 2026-11-19 from `experiments` at `aee5b14` (same commit as `origin/main`), plus the in-progress `TellusApp` probe. The existing UI definitions are the PreferenceLoader plists under `OITI/OITIPrefs/Resources` and `OITS/OITSPrefs/Resources`; defaults and runtime effects were checked against the current controllers and tweak code.

## Standalone app status

- Tellus is intended to replace the existing settings interfaces with one SwiftUI app. The SpringBoard tweaks remain responsible for system behavior.
- The first probe build (`com.wilburt.tellus`) exposed a single control for `DownloadProgressStyle`. On the iPhone 8 Plus, the owner changed the value in the app; a subsequent SSH read returned `1`, the original value. This confirms on-device app read/write and persistence for this key. The owner confirmed the Download Progress page in `0.1.0-4+debug`, Island, Appearance and Notifications in `0.1.0-5+debug`, Startup Animation and Status Bar Layout in `0.1.0-6+debug`, and Diagnostics in `0.1.0-7+debug` all open. The saved style remained `1` across updates. A controlled device check at owner approval set `DiagnosticsLevel` to 1, posted the established preference-change notification, then requested the status-bar report; SpringBoard emitted `STATUSBAR` lines, confirming its notification listener refreshed state and handled the request. `DiagnosticsLevel` was restored to its default Normal value (0) and the temporary key removed. Build `0.1.0-8+debug` with the preference-transaction fix is installed; Diagnostics is Normal (0), and Download Progress style remains `1`.
- Tellus depends on Insula (`com.wilburt.oiti >= 0.4.0`) and installs to `/var/jb/Applications/Tellus.app`. The debug package is separate from Insula.
- The repository contains two preference domains: Insula `com.wilburt.oiti.prefs` and Litus `com.wilburt.oits.prefs`. The owner confirmed that the current Tellus app scope is Insula only; Litus is paused and should be migrated if/when Litus development resumes. Its settings are inventoried below so they are not lost from the project record.

## Insula (OITI) controls

All listed preference controls use `com.wilburt.oiti.prefs` and post `com.wilburt.oiti/PrefsChanged`, unless the action column says otherwise. Ordinary changes are consumed live by SpringBoard. “Respring” below means the existing UI labels that control as requiring one; do not remove that behavior when migrating.

### Main page and Island appearance

| Control | Key | Default | Range / choices | Behavior |
| --- | --- | ---: | --- | --- |
| Enable Dynamic Island | `islandEnabled` | false | on/off | Enables the Island; marked as requiring respring. Turning on first backs up the original MobileGestalt `ArtworkDeviceSubType`, then writes spoof value 2556. Turning off restores the backup. Backup repair and an uninstall restore breadcrumb are part of this workflow. |
| Apple Mode | `appleMode` | false | on/off | Live “stock Island” mode. Suppresses custom appearance, notifications, startup animation and download progress without clearing stored preferences. Custom Island and notification positions, Status Bar Layout, Safe Mode and diagnostics remain active. |
| Use Custom Position | `posEnabled` | false | on/off | Enables custom Island X/Y offsets. Position itself remains available while Apple Mode is on. |
| X Position | `xPos` | `0` | text; numeric position, clamped to one screen | Stores typed values as strings; blank means default; invalid input keeps the prior value; out-of-range values are clamped. |
| Y Position | `yPos` | `20.5` | text; numeric position, clamped to one screen | Same validation as X. |
| Save | — | — | action | Commits both position fields and displays “Saved”. Each field also commits on editing end. |
| Reset Position to X 0, Y 20.5 | — | — | action | Writes `xPos="0"`, `yPos="20.5"`; leaves `posEnabled` unchanged; posts preference notification. |
| Hide When Not in Use | `hideEnabled` | false | on/off | Island visibility behavior; marked as requiring respring. |
| Disable Island Outline | `lineDisabled` | false | on/off | Hides the Island outline live. |
| Status Bar Layout (Experimental) | `StatusBarLayout` | `auto` | Automatic, Off, or one of seven private provider class names | Chooses UIKit status bar visual provider while the Island is enabled; UI says respring required. Private class names are iOS-version-sensitive. |

### Scale

| Control | Key | Default | Range | Behavior |
| --- | --- | ---: | ---: | --- |
| Island width | `MetricsSensorWidthScale` | 1.0 | 0.4–1.5 in UI | Changes the Island’s sensor-region width while keeping content size; live. Runtime clamps to 0.3–2.0. |
| Island height | `MetricsSensorHeightScale` | 1.0 | 0.7–1.5 in UI | Changes sensor-region height while keeping content size; live. Runtime clamps to 0.3–2.0. |
| Reset Island Size | — | — | action | Writes both metrics scales to 1.0; posts notification. |
| Use Custom Scale | `scaleEnabled` | false | on/off | Enables a non-uniform scale of Island and contents together. |
| Width (X) | `RelativeScaleX` | 1.0 | 0.5–2.0 | Relative to Apple’s stock size; live. |
| Height (Y) | `RelativeScaleY` | 1.0 | 0.5–2.0 | Relative to Apple’s stock size; live. |
| Reset Width and Height | — | — | action | Writes both relative scales to 1.0; posts notification. |

### Color and opacity

| Control | Key | Default | Range | Behavior |
| --- | --- | ---: | ---: | --- |
| Use Custom Opacity | `transEnabled` | false | on/off | Enables custom Island opacity. |
| Opacity | `alpha` | 1.0 | 0.0–1.0 | 1.0 is stock/fully opaque; live. |
| Reset Opacity | — | — | action | Writes `alpha=1.0`; leaves toggle unchanged; posts notification. |
| Use Custom Color | `colorEnabled` | false | on/off | Enables custom Island background color. |
| Red / Green / Blue | `red`, `green`, `blue` | 0.0 each | 0.0–1.0 | RGB color components; black is the stock color; live. |
| Reset Color to Black | — | — | action | Writes all three channels to 0.0; leaves toggle unchanged; posts notification. |

### Notifications

| Control | Key | Default | Range / choices | Behavior |
| --- | --- | ---: | --- | --- |
| Show Notifications in the Island | `islandNotificationsEnabled` | false | on/off | Presents notification content in the Island; requires Enable Dynamic Island. Turning off clears active Island notification elements and restores hidden stock banners. |
| Hide the Stock Banner | `islandNotificationsHideBanner` | false | on/off | Hides the stock banner while its Island notice is visible; banner is restored when the notice ends or the feature turns off. |
| Stack Multiple Notifications (Experimental) | `islandNotificationStackEnabled` | true | on/off | Keeps newest notification in the Island and older ones as up to four cards below it. Turning it off removes older cards but retains the newest. |
| Style | `IslandNotificationsStyle` | 2 | Compact=0, Wide=1, Expanded=2 | Applies to the next notification. |
| Dismiss When Tapped | `NotificationTapDismisses` | false | on/off | Immediately dismisses the matching Island notice when tapped. |
| Notification Haptic | `NotificationHaptic` | false | on/off | Plays a light haptic on arrival. |
| Island Notification Duration | `IslandNotificationsDuration` | 4.0 | UI has 2–10 s | Runtime clamps to 1–15 s. |
| Island Notification Message Lines | `IslandNotificationsMessageLines` | 2.0 | 1–4 | Maximum visible message lines. |
| Island Notification Roundness | `IslandNotificationsCornerExtra` | 0.0 | -4–8 | Extra corner radius; 0 is stock. |
| Use Custom Notification Position | `notEnabled` | false | on/off | Enables custom banner X/Y position. Position stays active in Apple Mode. |
| X Position / Y Position | `xNot`, `yNot` | `0`, `40` | text; clamped to one screen | Uses the same numeric validation behavior as Island position; stored as strings from Settings. |
| Save | — | — | action | Commits both notification position fields. |

### Download Progress (Experimental)

| Control | Key | Default | Range / choices | Behavior |
| --- | --- | ---: | --- | --- |
| Show Download Progress | `DownloadProgressEnabled` | false | on/off | Master switch; App Store and browser sources depend on it. |
| Show App Store Downloads | `DownloadAppStoreEnabled` | false | on/off | Tracks App Store installs; dependent on master switch. |
| Show Browser Downloads | `DownloadBrowserEnabled` | false | on/off | Browser support exists for Safari, Chrome and Arc Search. Private browsing is not checked in Arc/Chrome; Safari private downloads are excluded. |
| Style | `DownloadProgressStyle` | 0 | Minimal=0, Detailed=1 | Minimal is a custom floating pill. Detailed is an Island element and participates in element crash recovery and promotion safety. Restyling replaces the active presentation. |
| Width | `DownloadPillWidth` | 296 pt | 200–380 | Minimal pill width. |
| Bottom padding | `DownloadPillBottomPadding` | 10 pt | 0–40 | Minimal pill placement. |
| Move up or down | `DownloadPillNudgeY` | 0 pt | -30–30 | Additional Minimal pill vertical offset. |
| After this much is downloaded | `DownloadIdleAfterMB` | 0 (Never) | 0–5000 MB | Hides the progress UI at the limit; download continues. Size threshold only applies to byte-based sources. |
| After this percentage | `DownloadIdleAfterPercent` | 0 (Never) | 0–99% | Hides UI at the limit; 100% is reserved for completion. |
| After this long on screen | `DownloadIdleAfterSeconds` | 0 (Never) | 0–900 s | Hides UI after the limit; download continues. |
| Test download size | `DownloadTestSizeMB` | 800 MB | 50–5000 MB | Controls simulated download size. |
| Start Test Download / Stop Test Download | — | — | actions | Post `com.wilburt.oiti/TestDownloadStart` or `.../TestDownloadStop`; test display requires master switch. |

### Startup Animation

| Control | Key | Default | Behavior |
| --- | --- | ---: | --- |
| Enable Hello Animation | `IslandStartupHelloEnabled` | false | Plays after respring once unlocked, with a five-minute cooldown. Turning it on requires respring; turning it off cancels a pending animation live. Apple Mode forces it off without clearing the saved value. |

### Diagnostics, recovery and global actions

- **Extras** (Insula > Extras, 0.4.1 batch 3; not device-tested yet, Swift not compiled yet): a page for the playful switches, all off by default. First entry: **Double Tap Opens Tellus** (`ExtrasDoubleTapOpensTellus`): a double tap on the idle Island opens Tellus. It does nothing while Insula shows something, while the phone is locked, in Apple Mode or in safe mode. Takes effect immediately; needs Insula 0.4.1 or later.
- **Insula Status** (Diagnostics > Insula Status, 0.4.1 batch 2; not device-tested yet): a read-only page fed by the `recoveryState` bridge request. A summary of why Insula is off (safe mode, Insula switch off, Apple Mode, Island elements off, a problem found by the startup check), then Now (switches, safe mode, hooks installed, Island elements, running build), the respring-loop guard count, and the last startup check with its short issue lines. With Insula older than 0.4.1 only safe mode and Island elements are shown, with a note. If SpringBoard does not answer, the page says Insula may not be loaded. It changes nothing; the existing banners above it offer Clear Safe Mode and Turn Off Apple Mode.

- Tellus has a confirmed Respring action on the Home page. It writes `OITRespringIntent.plist` through the SpringBoard listener so the Safe Mode loop guard does not count the requested restart, then calls OITCore’s respring helper.
- A Safe Mode banner appears on the Home page and each settings page after repeated short SpringBoard launches. **Clear Safe Mode & Respring** removes `OITISafeMode.plist` and `OITIBootLog.plist`, marks the intentional restart, then resprings.
- An “Island elements are switched off” banner appears after the promotion guard records failures. Island notifications, startup animation and Detailed download style remain disabled until respring.
- Apple Mode banners explain which stored settings are temporarily inactive; a button on subpages turns Apple Mode off.
- **Copy Report to Clipboard** builds a device/settings/log report. Notification text and download file names are redacted; app names may still appear, and detailed logs can contain more personal information.
- **Share Full Report** writes a longer temporary text report and opens the share sheet.
- **Log Detail** (`DiagnosticsLevel`, default 0, Normal=0 / Detailed=1) applies live; detailed logs include more events and may expose personal details. The tweak also accepts level 2 through defaults for rate-limited per-call logs.
- **Run Status Bar Check** posts `com.wilburt.oiti/Dump` only when DiagnosticsLevel >= 1. The user should wait, then copy a report.
- **Clear Log Files** asks before deleting `/tmp/OITIDebug.log`, its rotated copy and `/tmp/OITIPrefsDebug.log`.
- Enabling the Island invokes the existing MobileGestalt workflow through Insula's fixed SpringBoard request. The shared helper saves the original value once, avoids trusting a backup that already contains spoof value 2556 on non-Island hardware, writes a root-readable restore breadcrumb, and restores/removes the value on disable/uninstall. Tellus never writes the cache directly.
- Attribution links will be added in a dedicated credits page when it is ready.

## Litus (OITS) controls

Litus has a separate Settings bundle and preference domain `com.wilburt.oits.prefs`, with Darwin notification `com.wilburt.oits/PrefsChanged`. Its page has six independent reposition toggles, six offsets and six hide toggles. All default off; changes apply live. The six **Hide** switches only take effect when the matching reposition switch is also on. Each offset is a leading-edge coordinate from 0–414 pt.

| Element | Reposition key (default) | Leading offset key (default) | Hide key (default) |
| --- | --- | --- | --- |
| Clock | `ClockRepositionEnabled` (false) | `ClockLeadingOffset` (16) | `ClockHidden` (false) |
| Battery | `BatteryRepositionEnabled` (false) | `BatteryLeadingOffset` (384) | `BatteryHidden` (false) |
| Cellular signal | `CellularSignalRepositionEnabled` (false) | `CellularSignalLeadingOffset` (6) | `CellularSignalHidden` (false) |
| Wi-Fi signal | `WifiSignalRepositionEnabled` (false) | `WifiSignalLeadingOffset` (76) | `WifiSignalHidden` (false) |
| Carrier text | `CarrierTextRepositionEnabled` (false) | `CarrierTextLeadingOffset` (28) | `CarrierTextHidden` (false) |
| Network type | `NetworkTypeRepositionEnabled` (false) | `NetworkTypeLeadingOffset` (80) | `NetworkTypeHidden` (false) |

README describes Litus as paused. Its existing code implements the above settings and live preference-change path. Keep its Settings bundle and preference data intact while Tellus ships Insula only; when Litus resumes, these rows can move into the same generic preference-store architecture.

## Non-UI keys, migrations and compatibility

### Insula operational keys

These are not normal settings controls but affect recovery, diagnostics or test behavior. Existing documentation says they are configured with `defaults write`.

| Key | Default | Purpose |
| --- | ---: | --- |
| `DiagnosticsEnabled` | true | Master logger switch. |
| `SafeModeGuardEnabled` | true | Enables SpringBoard crash-loop recovery. |
| `SafeModeMaxLaunches` | 5 (minimum 2) | Short-lived launches before safe mode. |
| `SafeModeWindowSeconds` | 120 (minimum 10) | Crash-loop observation window. |
| `SafeModeStableSeconds` | 45 (minimum 5) | Stable launch needed to clear launch history. |
| `SafeModeRestoreGestalt` | false | On safe-mode trip, also run OITIRestoreGestalt. |
| `InstallDumpSamples` | 6, range 0–30 | Samples for opt-in install diagnostic dump. |
| `InstallDumpIntervalSeconds` | 2, range 1–10 | Interval between samples. |
| `InstallDumpCallGetters` | false | Allows selected declared property getters in the install dump. |
| `DownloadTestFractionOnly` | false | Makes test download report a changing fraction instead of byte counts. |

Other state files, not preferences: `OITISafeMode.plist`, `OITIBootLog.plist`, `OITIElementsOff.plist`, `OITIRespringIntent.plist`, `OITILiveElement.plist`, MobileGestalt backup breadcrumbs and the native provider record. Clear Safe Mode and install/uninstall lifecycle must retain current file semantics.

### Migration / old keys

- On first SpringBoard preference reload, `PresetPositionsMigrated` is set once. Old `fixEnabled` and `notificationFix` values are migrated to custom position toggles/coordinates only when the current device has a profile-table entry. The old keys remain stored but are no longer read.
- Legacy absolute `scale`, `scaleX` and `scaleY` are not read or migrated. Current scaling keys are `RelativeScaleX` and `RelativeScaleY`.
- Preserve existing user values when replacing/removing Settings; do not remove domain keys as part of UI retirement.

## Integration findings / remaining validation

1. On-device app read, write, sync, immediate read-back and persisted storage are proven for `DownloadProgressStyle` on the target. Bundle ID and rootless install path are proven; Tellus 0.1.0-16 depends on Insula 0.3.7-5 or later.
2. The standalone app posts the established Darwin notification after preference writes. The SpringBoard-side preference reload and the new bounded action bridge are implemented; confirm their visible effects on the target.
3. Respring, MobileGestalt restore/backup, Safe Mode recovery and test-download notifications continue to run through the existing SpringBoard/OITCore paths. Tellus has no broad file or root access.
4. Keep preference names, types, defaults, migration behavior, hidden diagnostic controls and reset grouping as documented above. Several controls intentionally write multiple keys together.
5. Existing UI docs say settings may require respring; exact details need revalidation against the target while migrating. `MetricsSensorWidthScale` and `MetricsSensorHeightScale` UI slider ranges (0.4–1.5 / 0.7–1.5) differ from the runtime clamp (0.3–2.0); retain the UI constraints unless a deliberate product change is discussed.

## Recovery actions added for Tellus 0.1.0-9 / Insula 0.3.8

- Tellus provides a **Respring** action on the home page and **Clear Safe Mode & Respring** on the Recovery page. Both require a confirmation.
- The app posts narrowly scoped Darwin requests. The Insula SpringBoard tweak writes the same `OITIRespringIntent.plist` marker the old Settings page writes, then asks OITCore to respring. The Safe Mode action removes `OITISafeMode.plist` and `OITIBootLog.plist` before marking and requesting the restart.
- The old `com.wilburt.oiti/ClearSafeMode` request remains unchanged; it still clears recovery files without respringing.
- These actions require Insula 0.3.8. Both packages are installed on the target. SpringBoard restarted and the log confirms that Insula 0.3.8 loaded and consumed the intentional-respring marker. The Tellus Recovery page and button flows still need physical UI confirmation.

Tellus `0.1.0-10+debug` moves the Respring action to a dedicated home-page row; it is installed on the target. Recovery now contains only Clear Safe Mode & Respring. Physical UI confirmation is pending.

Tellus `0.1.0-11+debug` makes slider updates live using the legacy Settings page's 120 ms write throttle and commits the final value on release. The owner confirmed Island width and height now work.

Tellus `0.1.0-14+debug` and Insula `0.3.9-4+debug` were installed. The SpringBoard log confirms Insula 0.3.9 loaded. This update adds the Enable Dynamic Island switch through the shared MobileGestalt backup/restore helper, bridged diagnostics report copy/share and log cleanup, and Apple Mode and recovery banners on all pages. The owner should verify these newly migrated actions on the phone; no report contents or personal log lines were collected during installation.

The Tellus and fallback Insula Settings interfaces no longer display the upstream source or author links. Existing package metadata and source comments preserve the project attribution; a dedicated Tellus credits page is planned by the owner.

Insula package versioning follows the owner's requested `0.3.7` series. The link-removal build is `0.3.7-5+debug`; subsequent Insula changes continue at `0.3.7-6+debug` and upward. Tellus depends on Insula `0.3.7-5+debug` or later.

Tellus `0.1.0-23+debug` and Insula `0.3.7-7+debug` are installed. The standalone Recovery navigation row is removed; recovery banners and the Miscellaneous Exit Safe Mode action remain. About now fetches the installed Insula package version through the fixed SpringBoard bridge.

## Updates (Tellus app, 0.4.0)

| Control | Behavior |
| --- | --- |
| About > Check for Updates | Fetches the latest GitHub release (not pre-releases) and lists OITCore, Insula, Tellus and, if installed or published, Litus with installed and available versions and a status (Update, Up to date, Newer than release, Not installed, Not published, Unknown). Shows the release title, date and notes and a link to the release. |
| Download | Only for a component with an update (or, with the reinstall switch on, the version that is already installed). Needs a release with `SHA256SUMS` and `SHA256SUMS.sig`. Downloads in memory and verifies size, `.deb` header and SHA-256 (the `SHA256SUMS` entry and GitHub's digest must agree), then stores the file in `/var/mobile/Library/Caches/TellusUpdates`. |
| Install / Reinstall | After a verified download, for OITCore, Insula and Tellus. Asks first. Puts the release's `SHA256SUMS` and `SHA256SUMS.sig` next to the package, then runs through the root helper, which verifies the signature and refuses a version lower than the installed one (there is no Downgrade); Details shows the helper's output. Insula needs a respring afterwards; Tellus replaces itself and may close. |
| Update All | Shown when at least one installable component has an update. Installs them in the order OITCore, Insula, Tellus; stops at the first failure. |
| Menu: Check Again | Re-runs the check (not while something is installing). |
| Menu: Allow Reinstall | Off until switched on, then it stays on (stored in Tellus's own preferences, `com.wilburt.tellus.prefs`, outside the app, so updating Tellus does not reset it). Offers download and install again for a component whose installed version equals the release's; every install still asks first. |
| Menu: Include Pre-releases | Off until switched on, then it stays on (same storage as Allow Reinstall). Uses the release list so a pre-release (a release candidate) is considered; the summary says `(pre-release)`. The launch check uses the same setting. |
| About > Check When Tellus Opens | Off by default; stored like the two switches above. When on, Tellus checks GitHub once per launch, in the background: it trusts a saved answer for an hour, sends the saved `ETag` when it asks (a `304 Not Modified` does not use up GitHub's request limit), and after a failure waits 15 minutes. It only counts components with a newer release; it never downloads or installs. Failures are silent. Shows Last Checked and Last Result (`Used the saved answer`, `Nothing new (not modified)`, `New answer from GitHub`, `Could not reach GitHub; it will try again later`) while it is on. |
| About badge | A red count on the About row of the main list and on Check for Updates inside About: the number of components with an update, from the launch check (or from the Check for Updates screen after it has looked). Not shown while the launch check is off. |

## Insula settings: Reset This Page (0.4.0, in the Settings bundle `OITIPrefs`)

A red **Reset This Page** button is the last card of the Color, Scale, Notifications, Downloads, Startup Animation and Diagnostics pages (not the main page). After a confirmation it writes every setting on the page back to the default in its plist, including switches, or removes the setting if it has no default (the typed position fields), then posts `com.wilburt.oiti/PrefsChanged` once and refreshes the page. The existing section resets (Color, Scale, Position) stay. Tellus does not have this button yet.
