# Tellus

**Tellus** (OITUI, *Order In The User Interface*) is a small family of tweaks that make an iPhone running iOS 16 look and feel more modern. It is for rootless jailbreaks, made by me with help from AI.

Every tweak has two names. The **Latin name** is what you see in Sileo and Settings. The **OIT name** is the technical name in package IDs, files, logs and the docs.

| You see | Technical name | What it is |
| --- | --- | --- |
| **Insula** | OITI | A Dynamic Island for iPhones that don't have one, with notifications and download progress |
| **Litus** | OITS | Moves status bar elements around the Island (paused) |
| OITCore | OITCore | The shared library. It installs with Insula |
| OITInspector | OITInspector | A read-only developer tool |

Tested on an **iPhone 8 Plus** with **Dopamine 3** on **iOS 16.7.16**. Other devices may behave differently, so please tell me what you find.

<!-- screenshot: the Insula Settings page (main page) -->

---

# Insula (OITI)

Insula gives iPhones without a Dynamic Island one. It is built on Apple's own Island system and does not draw a fake one on top.

- **The Island:** turn it on, move it, resize or scale it, and change its color and opacity. Most changes apply immediately. Turning it on needs a respring.
- **Apple Mode:** one switch that makes the Island look and behave like stock iOS.
- **Notifications:** show notifications in the Island. The newest is in the Island, older ones are small cards below it (up to four). Tap to open, swipe up to dismiss. Off by default and still experimental: **Settings > Insula > Notifications**.
- **Download Progress:** show App Store downloads as a progress bar with the percentage and the time left, including paused, installing and finished, and Arc Search and Chrome downloads with the file name and the percentage (experimental, off by default). Off by default and still experimental: **Settings > Insula > Download Progress**. Safari and Chrome downloads are planned.
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

You need a rootless jailbreak on iOS 16 (Insula is built and tested on an iPhone 8 Plus, iOS 16.7.16, Dopamine 3; other iOS versions and roothide are not supported and may not work). Install both `.deb` files from the [latest release](https://github.com/realtweety/Tellus-OITUI/releases/latest): **OITCore** first (or both in one `dpkg -i`), then **Insula**. To remove everything, remove Insula before OITCore.

Older releases: [v0.3.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.3.0), [v0.2.5](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.2.5), [v0.2.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.2.0), [v0.1.0](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.1.0), [first_release](https://github.com/realtweety/Tellus-OITUI/releases/tag/first_release) (the only release of Litus).

# Documentation

`OVERVIEW.md` (the modules and plans), `COMMANDS.md` (commands and test steps), `DIAGNOSTICS.md` (logging), `LEARNINGS.md` (technical lessons), `WORKFLOW.md` (branches and releases), `IDEAS.md` (the backlog), `OITUI_HISTORY.md` (how the project got here), `Third Party Licenses/`.
