# Tellus app architecture plan

## Current boundary

The existing Insula (OITI) and Litus (OITS) tweaks continue to own SpringBoard behavior. The Tellus app is a settings client: it reads and writes the existing preference domains and asks the owning tweak to act through the existing Darwin-notification interfaces. The old PreferenceLoader bundles remain installed as a fallback throughout migration.

The first app build demonstrated on the jailbroken iPhone 8 Plus that an ordinary rootless app can read, update, synchronize and read back `DownloadProgressStyle` in `com.wilburt.oiti.prefs`. Build `0.1.0-4+debug`, with the reusable `PreferenceStore` and Download Progress page, was installed and the owner confirmed that page opens and works. Build `0.1.0-5+debug` added Island, Appearance and Notifications; the owner confirmed all three pages open on the phone. Build `0.1.0-6+debug` added Startup Animation and Status Bar Layout; the owner confirmed both pages open. Build `0.1.0-7+debug` added Diagnostics log detail and status-bar request controls; the owner confirmed that page opens. The saved Download Progress style remained `1` across updates. At the owner's approval, `DiagnosticsLevel` was temporarily set to 1 and `com.wilburt.oiti/PrefsChanged` was posted; a subsequent `com.wilburt.oiti/Dump` request produced SpringBoard `STATUSBAR` report lines, proving the listener reloaded the preference and handled the established request. The temporary DiagnosticsLevel key was removed and its default Normal value (0) verified. Build `0.1.0-8+debug` adds a preference-transaction fix so the app posts its Darwin notification only after synchronization and read-back succeed; it is installed. After installation, Diagnostics remained at Normal (0) and Download Progress style remained `1`. Build `0.1.0-9+debug` adds Recovery and respring actions; its companion Insula 0.3.8 adds the SpringBoard request handlers and preserves the intentional-respring marker. Both packages are installed on the iPhone (Insula `0.3.8-1+debug`, Tellus `0.1.0-9+debug`). After installation, SpringBoard was restarted; its log confirms Insula 0.3.8 loaded and consumed the intentional-respring marker without counting the restart as a crash. Build `0.1.0-10+debug` moves Respring from Recovery to a confirmed action on the home page. It is installed and `dpkg` reports Tellus `0.1.0-10+debug`; physical UI confirmation is pending. Build `0.1.0-11+debug` changes all Tellus sliders to match the legacy Settings interaction: preference writes are throttled to one every 120 ms while dragging and the final value is written on release. It builds successfully and is installed on the iPhone; the owner confirmed that Island width and height now respond while dragging. Tellus `0.1.0-16+debug` and Insula `0.3.7-6+debug` are installed. Insula's package/runtime version label now follows the owner's 0.3.7 version series. The recent Tellus work adds bridged Diagnostics actions, recovery and Apple Mode banners, and the Enable Dynamic Island bridge through the shared MobileGestalt backup/restore helper. The upstream source and author links have been removed from both interfaces. Physical verification of the recently migrated controls remains in progress.

**Status, 21 Nov 2026 (0.4.0 in preparation).** The app is no longer a plain sandboxed app: it is signed with `platform-application`, `com.apple.private.security.no-sandbox`, `com.apple.private.persona-mgmt` and `com.apple.private.skip-library-validation` (`TellusApp/Entitlements.plist`) so it can write to shared folders and start a root helper. It also gained an updater and an installer (below). Insula `0.4.0` is the release that carries the bridge handlers the app needs, and the app requires it.

## App structure

- One SwiftUI app target, deployed to iOS 16.0, using `NavigationStack`, `List`, `Form`, native switches, sliders, pickers, alerts and SF Symbols. Use system typography, semantic colors and grouped backgrounds so the interface tracks each OS appearance naturally. Build custom presentation only where the current feature requires it.
- Root page presents feature groups, not every control at once: Island, Appearance, Notifications, Downloads and Diagnostics. Recovery remains available through the status banners and Miscellaneous actions instead of a separate Recovery page.
- Each feature screen owns only presentation and validation. Preference access, transactions, notification posting and action requests stay in shared services.
- Preserve the current settings labels and explanations initially; wording/design can be refined after parity and behavior are verified.

## Preference service

Use the new `PreferenceStore` as the preference boundary. It supports each existing domain and notification and currently reads/writes property-list values:

1. Synchronize and read the existing preference domain with `CFPreferences`.
2. Preserve existing key names, defaults, stored types and unknown keys. In particular, the four position fields have historically been strings in Settings, while command-line writes may have stored numbers.
3. Validate/clamp user input using current bounds and runtime rules. Do not silently widen the current controls' ranges.
4. For a change or grouped reset, write all related keys, call `CFPreferencesAppSynchronize`, verify the values, then post that domain's existing Darwin notification once. Keep grouped operations atomic at the UI level (for example, RGB reset and X/Y reset).
5. Reload when a settings view appears and when the app becomes active, since the existing Settings bundles and shell tools can change the same values.
6. Use one store per preference domain: `com.wilburt.oiti.prefs` / `com.wilburt.oiti/PrefsChanged`. The store also names Litus’s separate domain for reuse if Litus resumes, but Litus is excluded from the current app scope.

Avoid `@AppStorage` as the source of truth for now: it does not express the existing multi-domain, explicit-synchronize, Darwin-notify transaction by itself. A typed model backed by explicit `CFPreferences` is easier to keep compatible with the tweaks.

## Actions and privilege boundaries

- Respring: request through the existing OITCore Darwin notification `com.oitui.respring`. The SpringBoard-side listener invokes `FBSystemService`; the app should not attempt a private SpringBoard call itself.
- Test download: post the existing `com.wilburt.oiti/TestDownloadStart` and `.../TestDownloadStop` notifications. The current OITI listener dispatches the operation on SpringBoard's main queue.
- Diagnostics: report generation and clipboard/share actions must preserve redaction and the existing warning that app names can remain in logs. A status-bar dump is a request to SpringBoard through `com.wilburt.oiti/Dump` and remains gated by Detailed logging.
- MobileGestalt backup/spoof/restore remains a privileged, safety-critical operation. Tellus writes only the existing `islandEnabled` preference and sends a fixed SpringBoard request. A shared OITI helper performs the same backup, suspect-backup repair, spoof write, breadcrumb update, and restore used by the Settings bundle; the app gets a success/error response and does not receive file access.
- Safe Mode clearing and respring keep the existing marker files and intent marker semantics. Tellus sends `com.wilburt.oiti/Respring` or `com.wilburt.oiti/ClearSafeModeAndRespring`; Insula writes the intent marker and performs the file operations in SpringBoard before asking OITCore to respring. The older `com.wilburt.oiti/ClearSafeMode` notification remains intact.
- Diagnostics report generation and log clearing use fixed bridge actions handled by SpringBoard. The existing report builder still redacts notification text and download file names; only its report string returns to Tellus. The app has no general log or filesystem access.
- The Home page and each settings page request a small recovery-state response from SpringBoard. Tellus shows the existing Safe Mode and Island-elements-off banners and routes their confirmed actions through the existing respring notifications.

## Packaging and migration

- Continue compiling the `.app` with Xcode for generic arm64 iOS, then let Theos rootless-stage and package it. The host Swift 6 toolchain cannot compile against Theos's iOS 16.5 SwiftUI module, while Xcode's SDK builds successfully.
- Current bundle ID: `com.wilburt.tellus`; install path: `/var/jb/Applications/Tellus.app`; current package dependency: Insula `0.4.0` or later (`com.wilburt.oiti (>= 0.4.0)`). The app ships in the same release as OITCore and Insula (three packages and a `SHA256SUMS` file); the release workflow checks that the dependency, the package version and `MARKETING_VERSION` agree.
- Keep the old PreferenceLoader bundle and keys intact until every setting, reset, action, recovery path, and data migration has a verified replacement. Removing its entry is the final milestone, not part of initial app releases.
- Retain user preferences across app install/update/removal. Removing the app must not clear tweak settings.

## Open technical checks before broad implementation

1. Capture an OITI Detailed log line showing a preference written from Tellus being reloaded by SpringBoard; then restore `DiagnosticsLevel` to the user's prior value.
2. Verify grouped/multiple-key writes and position string handling from the app on the target.
3. On the target, verify both directions of the new `islandEnabled` bridge, including backup/restore logs and the Island's behavior after respring.
4. Recheck operations needing respring and actions with side effects on the target during feature migration.
5. Litus is intentionally out of current scope. The owner wants its controls moved to Tellus when Litus development resumes; the store is already shaped to support its separate domain and notification.

## Updating and installing (0.4.0)

Files (all in `TellusApp/TellusApp/Sources/` unless noted); networking and logic are separate from the screens.

- `UpdateChecker.swift`: no UI. `GitHubReleaseClient` (the latest release, or the release list when pre-releases are included), `GitHubRelease` (lenient decoding; every field but `tag_name` is optional; package versions come from the attached `<package-id>_<version>_<arch>.deb` names), `DebianVersion` (dpkg's ordering), `UpdateReportBuilder`, `InstalledVersionReader` (Tellus from its own Info.plist, Insula through the SpringBoard bridge action `insulaVersion`, OITCore and Litus from dpkg's status file), `UpdateCheckError`.
- `PackageDownloader.swift`: downloads one package in memory and verifies it before writing: the URL must be `https://github.com/realtweety/Tellus-OITUI/releases/download/...`, the redirect must end on GitHub's asset host, the size and the `!<arch>` header must match, and the SHA-256 must equal the package's entry in the release's `SHA256SUMS` and, if GitHub reports one, GitHub's asset digest too (disagreement is an error). A release without both `SHA256SUMS` and a 64-byte `SHA256SUMS.sig` is refused ("not signed"). The app does not verify the signature: it keeps the exact bytes of both files, and the root helper (which alone holds the public keys) verifies them at install time. The package is stored in `/var/mobile/Library/Caches/TellusUpdates`.
- `PackageInstaller.swift`: asks the root helper to install a verified file; installable components are OITCore, Insula and Tellus (Litus later). An install is never killed on a timeout.
- `UpdateCheckView.swift`: `UpdateCheckViewModel` (state, downloads, installs, **Update All**: OITCore, Insula, Tellus last, stopping at the first failure) and the screen. Reinstall (of the version that is already installed; Tellus never downgrades) and pre-releases are menu switches that are off each time the screen opens.
- `TellusRoot.c/.h` and `TellusApp-Bridging-Header.h`: one C function, `tellus_spawn_capture_ex`, that starts a program (optionally as root through the persona API), captures its output and applies a timeout.
- `Helper/tellus-helper.c` (installed as `/var/jb/usr/libexec/tellus-helper`, signed with `Helper/Helper.entitlements`, mode 0755, never setuid): the root side. Its checks (including the Ed25519 signature check of the `SHA256SUMS` manifest and the refusal to downgrade) are described in `LEARNINGS.md`, "The Tellus app", and tested by `tools/tellus_helper_test.sh`. The Ed25519 verifier is the vendored Monocypher in `Helper/`.

Package scripts: `postinst` fixes the helper's owner and mode and runs `uicache`; `prerm` unregisters the app; `postrm` removes `TellusUpdates` and the helper's `tellus-install` folder on removal.

Known limits: packages are not signed, so the updater trusts the GitHub repository (a signed `SHA256SUMS` checked by the helper is the planned hardening, `PLANS.md`); an Insula older than 0.4.0 cannot be read by the app; Litus is not installable from the app.
