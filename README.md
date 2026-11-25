# Tellus

**Tellus** (OITUI, *Order In The User Interface*) is a small family of tweaks that make an iPhone running iOS 16 look and feel more modern. It is for rootless jailbreaks, made by me with help from AI.

Every tweak has two names. The **Latin name** is what you see in Sileo and Settings. The **OIT name** is the technical name in package IDs, files, logs and the docs.

| You see | Technical name | What it is |
| --- | --- | --- |
| **Insula** | OITI | A Dynamic Island for iPhones that don't have one, with notifications and download progress |
| **Litus** | OITS | Moves status bar elements around the Island (paused) |
| **Tellus** (the app) | TellusApp | The companion app: Insula's settings as an app, recovery tools and in-app updates (new in 0.4.0) |
| OITCore | OITCore | The shared library. It installs with Insula |
| OITInspector | OITInspector | A read-only developer tool |

Tested on an **iPhone 8 Plus** with **Dopamine 3** on **iOS 16.7.16**. Other devices may behave differently, so please tell me what you find.

<!-- screenshot: the Insula Settings page (main page) -->

---

# Tellus (the app)

Tellus is a SwiftUI app for Insula: its settings in one place, with the recovery tools and an updater. It is new in 0.4.0 and optional. Insula works without it, and Insula's own pane in Settings stays.

- **Insula's settings:** the Island (position, size, scale), Appearance, Notifications, Startup Animations and Download Progress, plus Diagnostics. A **Reset This Page** button on each page puts that page back to its defaults.
- **Recovery:** the banners for safe mode and for Island elements being off, **Exit Safe Mode**, and a confirmed **Respring**.
- **Insula Status (Diagnostics > Insula Status):** one page that says why Insula might be off: safe mode, the Insula switch, Apple Mode, Island elements switched off, the respring-loop guard count and the last startup check. It works when Insula is in safe mode and says so when SpringBoard does not answer.
- **Extras (Insula > Extras):** a place for the playful switches, all off by default. First one: **Double Tap Opens Tellus**: double tap the idle Island (the area at the top centre of the screen) to open Tellus. It does nothing while the Island shows something, while the phone is locked, in Apple Mode or in safe mode. The touch zone is a fixed area at the top centre of the screen (about 60 points from the top and 90 points either side of the middle), not tied to the Island's own position: it works with a moved, resized or scaled Island as long as the Island stays in that area.
- **Updates (About > Check for Updates):** looks at the latest release on GitHub and shows what is installed next to what is available, with the release notes. **Download** fetches a package and checks its SHA-256 against GitHub's checksums before anything is installed; **Install** installs OITCore, Insula or Tellus; **Update All** does them all in that order, Tellus last (Update All is new in 0.4.0; its first real use was the 0.4.1 candidate). Tellus can update itself; it may close while it does, so open it again afterwards. After an Insula update, respring. The menu in the top corner has switches for reinstalling or downgrading and for including pre-releases (both off each time the screen opens).

Tellus needs Insula 0.4.1 or later. Litus is not part of it yet.

**What Tellus can do to your phone.** To install packages, Tellus runs outside the app sandbox and starts a small helper as root (`/var/jb/usr/libexec/tellus-helper`). The helper installs only OITCore, Insula and Tellus, only from Tellus's own download folder, and only after it has checked the file's SHA-256 itself and confirmed the package name inside it. The checksums come from the same GitHub release as the package and the packages are **not signed**, so the updater trusts that repository and your connection to it. If you do not want that, do not install Tellus: install the `.deb` files by hand.

---

# Insula (OITI)

Insula gives iPhones without a Dynamic Island one. It is built on Apple's own Island system and does not draw a fake one on top.

- **The Island:** turn it on, move it, resize or scale it, and change its color and opacity. Most changes apply immediately. Turning it on needs a respring.
- **Apple Mode:** one switch that makes the Island look and behave like stock iOS.
- **Notifications:** show notifications in the Island. The newest is in the Island, older ones are small cards below it (up to four). Tap to open, swipe up to dismiss. Off by default and still experimental: **Settings > Insula > Notifications**.
- **Download Progress:** show App Store downloads as a progress bar with the percentage and the time left, including paused, installing and finished, and Arc Search, Chrome and Safari downloads with the file name and the percentage (experimental, off by default). Off by default and still experimental: **Settings > Insula > Download Progress**. Safari's Private Browsing downloads are not shown (and a Safari download that cannot be told from one is not shown either); private tabs in Arc Search and Chrome are not checked yet.
- **Diagnostics:** Settings > Insula > Diagnostics copies a report for a bug report to the clipboard (device, iOS version, settings and the log, with notification text and download file names removed), shares a longer one as a file, switches the log detail and clears the log files.
- **Startup Animation:** plays a Hello animation after a respring; tap it to open Insula's Settings. Off by default.
- **Safe mode:** if SpringBoard keeps restarting, Insula switches itself off. Settings then shows why, with a button to clear it.

<!-- screenshot: the Island with a notification -->
<!-- screenshot: the download progress bar -->

If something looks wrong, turn on Apple Mode or turn off Island Notifications to get the stock behavior back.

## Bug reports

Insula does not send notification text anywhere. From 0.3.6 on, the report is one tap away: Settings > Insula > Diagnostics > set Log Detail to Detailed, reproduce the problem, tap **Run Status Bar Check** if it is about the status bar, then **Copy Report to Clipboard** and paste it into the issue (or **Share Full Report** for a file). The report holds the device, iOS version, Insula's settings and Insula's log, with notification text and download file names removed. **Read it before you share it**, and set Log Detail back to Normal afterwards.

Older versions: raise the log level yourself, respring, reproduce the problem and read `/tmp/OITIDebug.log`:

```
defaults write com.wilburt.oiti.prefs DiagnosticsLevel -int 1
```

At higher levels the log holds the first characters of notification text. `DIAGNOSTICS.md` explains the log.

---

# Litus (OITS)

Litus moves and hides status bar elements along the X axis, so a notchless iPhone with an Island has a clock in a sensible place. It is a work in progress and paused while I focus on Insula.

# OITCore

The shared library the tweaks use. It installs automatically with Insula.

---

# Installation

You need a rootless jailbreak on iOS 16 (Insula is built and tested on an iPhone 8 Plus, iOS 16.7.16, Dopamine 3; other iOS versions and roothide are not supported and may not work). Install the `.deb` files from the [latest release](https://github.com/realtweety/Tellus-OITUI/releases/latest): **OITCore** first, then **Insula**, then **Tellus** if you want the app (or all of them in one `dpkg -i`). To remove everything, remove Tellus, then Insula, then OITCore.

**Updating.** With Tellus installed, open About > Check for Updates. Moving from an Insula older than 0.4.0 to 0.4.0 is a manual install, because Tellus cannot read the version of an older Insula; from 0.4.0 on, Tellus does the updating.

**Checking a download by hand.** Each release (from 0.4.0) has a `SHA256SUMS` file. Put it next to the `.deb` files and run `shasum -a 256 -c SHA256SUMS` (on the phone `sha256sum -c SHA256SUMS`).

Older releases: [v0.3.7](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.7), [v0.3.6](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.6), [v0.3.5](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.5), [v0.3.1](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.1), [v0.3.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.0), [v0.2.5](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.2.5), [v0.2.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.2.0), [v0.1.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.1.0), [first_release](https://github.com/realtweety/Tellus-OITUI/releases/tag/first_release) (the only release of Litus).

# Documentation

`OVERVIEW.md` (the modules and plans), `COMMANDS.md` (commands and test steps), `DIAGNOSTICS.md` (logging), `LEARNINGS.md` (technical lessons), `WORKFLOW.md` (branches and releases), `PLANS.md` (accepted forward work), `IDEAS.md` (unapproved ideas), `OITUI_HISTORY.md` (how the project got here), `TellusApp/Documentation/` (the app's architecture and feature inventory), `Third Party Licenses/`.
