# OITUI Plans

> **Purpose:** This file describes work that has been accepted and is intended to happen. It is not a brainstorm, a release schedule, or a promise that every detail will ship unchanged.
>
> **Do not assign target version numbers or dates to plan items.** Work may be split, delayed, changed, or removed as implementation and testing reveal more. Keep unapproved possibilities in `IDEAS.md`.

## How to use this file

- Add something here only after the owner has explicitly decided that it is part of the plan.
- Keep the plan focused on outcomes, dependencies and acceptance criteria, not speculative implementation details.
- Do not attach a release number or deadline unless the owner explicitly asks for one.
- If scope changes, update this document. Do not preserve an outdated commitment just because it was written down earlier.
- When work is complete, remove it from here and record it in `OVERVIEW.md` (and the GitHub Release). Do not leave shipped work looking like future work.
- Claude may recommend changes, identify risks and propose alternatives, but must not silently promote an idea from `IDEAS.md` into this plan.

## Release discipline

These are process rules, not release assignments:

- A release is not ready merely because the code builds or a feature appears complete. The owner and Claude must agree that it is ready based on the actual test results.
- Claude gives an honest, unbiased readiness assessment. Do not rubber-stamp a release or hide unresolved failures to keep a planned version.
- Do not promise a feature for a particular version. Features can move, be split, or be removed as testing and implementation progress.
- Complete code and documentation cleanup as part of release-candidate preparation, after the feature work has been polished enough to review.
- Release notes live in the GitHub Release body (`WORKFLOW.md`, `COMMANDS.md` sections 30, 41 and 42).

## Current baseline

The latest published release is [OITUI 0.4.3](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.4.3):

| Package | Published version |
|---|---:|
| OITCore | `0.1.0` |
| Insula (formerly OITI) | `0.4.1` |
| Tellus | `0.1.3` |

Releases from 0.4.2 on are signed: Tellus verifies an Ed25519 signature of `SHA256SUMS` (`SHA256SUMS.sig`) before it installs anything, and never installs a version lower than the installed one. 0.4.3 changed only Tellus (the optional update check at launch and switches that stay on); the Insula and OITCore files in it are byte-identical to those of 0.4.2. The Island position fix of 0.4.1 has not been confirmed by the person who reported the problem, and the owner's iPhone 8 Plus never had the bug.

Update All installs only packages that are newer, in this order: OITCore, Insula, Tellus.

### Current release limitations

- Releases up to 0.4.1 are not signed: Tellus does not install them (they can be installed by hand with Sileo, Zebra or dpkg). Releases from 0.4.2 on are signed.
- Insula is built and tested for rootless jailbreaks on iOS 16. The documented test device is an iPhone 8 Plus running iOS 16.7.16 with Dopamine. Other iOS versions and roothide are not supported.
- Notifications, Download Progress and Status Bar functionality remain experimental.

Treat these as real support boundaries. Do not describe untested combinations as supported.

## Accepted work

Three small Insula items, accepted by the owner on 27 Nov 2026. They have no release number: the Insula version and the OITUI release number are decided when they ship. Each one needs its own device test on the owner's iPhone 8 Plus before it ships, and a change to Insula needs an Insula version bump.

1. **Show private-browsing downloads like any other.** Owner's decision of 27 Nov 2026, replacing the earlier item "private/incognito download check for Arc and Chrome": no special treatment of private browsing, so Safari, Chrome and Arc Search behave alike. Since 0.3.7 Safari's Private Browsing downloads are hidden (the web view's data store is not persistent, or cannot be read), which is Insula's own filter, not Safari's behaviour; the filter is removed (`OITI/Browser/OITIBrowserDump.xm`) and Arc and Chrome stay unchanged (they never had one). The release notes, the README, the Settings footer and `FeatureInventory.md` say so, because the Island shows the file name on screen. Needs a device check: a Safari Private Browsing download shows, and a normal one still does. Still open for the owner: the Tellus Download Progress footer (`DownloadProgressSettingsView.swift`) says private browsing downloads "are not checked in every browser"; correcting it is a Tellus text change and needs a Tellus version bump.
2. **Dynamic Double Tap Opens Tellus hit zone.** The shipped zone is a fixed band near the default Island location, so a moved, resized or scaled Island can fall outside it. The detection depends on which view takes the touch. A log-only probe (build `-a`, 27 Nov 2026, one log at the owner's everyday settings) showed that with a custom position, scale and size the pill area is taken by `SBSystemApertureWindow`, not by a status bar view. The zone now follows the Island: a status bar zone centred on the Island window, plus a touch the Island window itself takes when no Island element is showing (`OITI/IslandSize/OITIIslandHooks.xm`). If the Island cannot be reached beyond some position, say so in the documentation instead of promising more. The behaviour at the default position must not change. Needs a device test at several positions and scales before it ships.
3. **Download completion feedback.** A haptic when a download or installation ends: one haptic when it finishes successfully, two short haptics in a quick burst when it fails or is cancelled. Haptic only (no sound in this item), a setting that is off by default, and it covers every download source Insula already tracks (App Store, Safari, Chrome, Arc).

New work enters this file only after the owner explicitly accepts it from `IDEAS.md`. The optional update check at Tellus launch and the release tool (`status`, `verify`, `candidate`, `release`, all used for real) are done and shipped (see `OVERVIEW.md`).

## Ongoing updater requirements

These are validation requirements for updater work, not separate features:

- Keep the Update All behaviour: install only packages that are newer, in the order OITCore, Insula, Tellus.
- The next time OITCore itself changes, test the OITCore-first order of Update All end to end. It has not been tested, because 0.4.1 changed only Insula and Tellus.
- Do not install a package unless its signature and checksum checks have both passed, and keep signing every release and pre-release that Tellus has to install.
- Keep stable-release and prerelease version comparisons correct. A prerelease that Tellus must download must not contain `~` in its version, because GitHub rewrites it in asset names; carry the final version numbers instead.

## Explicitly not in the current plan

- **Litus integration is postponed.** Do not add Litus to Tellus' updater allowlists, installer or app pages until the owner decides to bring it back.
- **Landscape Island notifications are on hold for a long while.**

Everything else (uncommitted ideas, research topics, parked work) belongs in `IDEAS.md`.
