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

The latest published release is [OITUI 0.4.2](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.4.2):

| Package | Published version |
|---|---:|
| OITCore | `0.1.0` |
| Insula (formerly OITI) | `0.4.1` |
| Tellus | `0.1.2` |

It is the first signed release: Tellus verifies an Ed25519 signature of `SHA256SUMS` (`SHA256SUMS.sig`) before it installs anything, and no longer installs a version lower than the installed one. The Insula and OITCore files in it are byte-identical to those of 0.4.1. The Island position fix of 0.4.1 has not been confirmed by the person who reported the problem, and the owner's iPhone 8 Plus never had the bug.

Update All installs only packages that are newer, in this order: OITCore, Insula, Tellus.

### Current release limitations

- Releases up to 0.4.1 are not signed: Tellus does not install them (they can be installed by hand with Sileo, Zebra or dpkg). Releases from 0.4.2 on are signed.
- Refusing a version older than the installed one is tested off the phone only, and a release signed by the backup key has not been accepted by the helper on a phone.
- Insula is built and tested for rootless jailbreaks on iOS 16. The documented test device is an iPhone 8 Plus running iOS 16.7.16 with Dopamine. Other iOS versions and roothide are not supported.
- Notifications, Download Progress and Status Bar functionality remain experimental.

Treat these as real support boundaries. Do not describe untested combinations as supported.

## Accepted work

The accepted forward work is the optional update check at Tellus launch and the finishing of the release tool. Signed release verification, which came first, is done (see `OVERVIEW.md`).

### 1. Optional update check on launch

Add an optional setting that checks for updates when Tellus launches.

- The setting is **off by default**.
- When enabled, Tellus checks for updates at launch, and an available update is shown as a badge on the About page.
- Results are cached, and GitHub's `ETag` support is used so requests are not wasted against the per-address API limit.
- A check never installs anything. The user stays in control of installation.
- Offline launches and failed checks must not make Tellus unusable or cause repeated needless requests.
- The update screen's **Include Pre-releases** and **Allow Reinstall** switches keep their setting once switched on, even after Tellus is updated (they are stored outside the app); the launch check follows the pre-release setting.

### 2. Release tool (`oitui-release`)

One command-line tool on the owner's PC that carries out the documented release steps (`COMMANDS.md` sections 43 to 45), so a release is: choose a tested candidate, release it, done.

- First: `status` (read-only overview), `verify` (check a release's files and its signature against the keys built into the helper) and `candidate` (use or start the release build, assemble the packages, sign `SHA256SUMS`, publish a pre-release).
- Then `release`, which promotes a tested candidate (the same signed files) to a release (pull request and squash merge, tree checks, tag, GitHub Release, cleanup, `experiments` recreated from `main`). All four commands exist and are tested with a fake GitHub that performs real merges in a throw-away repository. `status`, `verify` and `release` have been used for real. **Still to do:** the first real use of `candidate`; anything the real GitHub shows that the fake did not.
- Rules the tool keeps: it never sees the key passphrase; it signs only after showing the files and hashes and getting a yes, and only if the helper's built-in keys accept the new signature; every command that changes something is logged and can be rehearsed with `--dry-run`; it never force-pushes and never merges to `main` without the owner typing the release number, and only when no product file differs from the tested candidate's commit; unchanged packages are attached byte-identical from the previous release.
- Before relying on a command for real, its tests pass and its first use is a dry run.

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
