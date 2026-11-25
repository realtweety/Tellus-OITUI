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

The latest published release is [OITUI 0.4.1](https://github.com/realtweety/Tellus-OITUI/releases/tag/v0.4.1):

| Package | Published version |
|---|---:|
| OITCore | `0.1.0` |
| Insula (formerly OITI) | `0.4.1` |
| Tellus | `0.1.1` |

It includes the Tellus Insula Status diagnostics page, the optional Double Tap Opens Tellus extra, and fixes for the Island's position after unlocking and for restoring the default position as soon as Use Custom Position is switched off. The lock/unlock fix has not been confirmed by the person who reported the problem, and the owner's iPhone 8 Plus never had the bug.

Update All installs only packages that are newer, in this order: OITCore, Insula, Tellus.

### Current release limitations

- Release packages are not signed yet.
- Insula is built and tested for rootless jailbreaks on iOS 16. The documented test device is an iPhone 8 Plus running iOS 16.7.16 with Dopamine. Other iOS versions and roothide are not supported.
- Notifications, Download Progress and Status Bar functionality remain experimental.

Treat these as real support boundaries. Do not describe untested combinations as supported.

## Accepted work

The accepted forward work makes Tellus' updater more trustworthy and then adds an optional update check at launch. This is the order the owner chose; it is not tied to release numbers.

### 1. Signed release verification

Sign the `SHA256SUMS` manifest with an owner-controlled signing key, and build the matching public key into `tellus-helper`, so the helper can verify that a manifest was signed by the owner before it accepts any package.

Trust model:

- The private key stays under the owner's control and is never in the repository, the app, the helper, the release assets or CI.
- The public key is built into `tellus-helper`.
- The helper verifies the manifest signature itself, and takes the expected package checksum from the verified manifest. It must not accept an expected checksum supplied by its caller, because code running inside the Tellus app could otherwise still choose the checksum.
- A missing, invalid or untrusted signature never falls back to trusting an unsigned checksum file.
- Package checksum verification stays: the signature authenticates the manifest, and the checksum ties the downloaded bytes to that manifest.
- Once signing is in place, do not install a package unless its signature and checksum checks have both passed.

Known limits to state plainly in the documentation:

- The Tellus and helper versions that exist today have no public key. The first update to a signing-capable version can only be trusted the way updates are trusted now (the package and its checksum come from the same GitHub release). Signing protects every update after that one, not the step that introduces it.
- A signature authenticates a release; it does not by itself stop an attacker replaying an older, genuinely signed release. The helper's refusal to install a lower version than the installed one (item 5 below) covers this for installs; hiding a new release from a device (a freeze) is not covered.

Agreed design (the owner approved it; implementation details may still change as testing shows problems):

1. **Format.** A raw Ed25519 signature over the exact bytes of `SHA256SUMS`, stored as `SHA256SUMS.sig` (64 bytes) and made with OpenSSL 3 (`openssl pkeyutl -sign -rawin`). OpenSSH signatures were considered and not chosen. The helper verifies with a vendored, license-listed Ed25519 implementation. OpenSSL on macOS is LibreSSL and may not do raw Ed25519, so release signing happens on a machine with OpenSSL 3.
2. **The helper decides.** `tellus-helper --install` no longer takes an expected hash from its caller. It receives the package, the manifest and the signature, copies them into its root-only folder, verifies the signature, takes the package's expected hash from the verified manifest, and keeps every existing check unchanged.
3. **Release step.** CI never holds the key. After the exact release files are tested, the owner creates `SHA256SUMS` from them, signs it locally, and attaches both. A release is never edited after signing; a changed asset means re-signing.
4. **Prereleases** are signed with the same key, so the prerelease update path can be tested as it is now.
5. **Rollback.** The helper refuses to install a version lower than the installed one (dpkg version comparison). An equal version is allowed, which release candidates need because they carry the final version number. Tellus can therefore no longer downgrade to the existing unsigned releases.
6. **Keys.** A primary key and a backup key. The helper trusts up to two public keys and accepts a signature from either. The primary private key has three encrypted copies (main PC, second PC, one in the cloud, in an account separate from GitHub); the cloud copy is a backup and is never used for signing. The backup private key is kept offline and not on a PC used day to day. Passphrases are kept in a password manager. Losing the primary key is recovered by a normal release signed with the backup key that carries a new key list. A stolen key cannot be revoked on devices that already trust it.

Still to settle during implementation: the exact error messages in the app, and how the app passes the manifest and signature to the helper.

Before calling this complete, test at least: the normal valid-update path, a modified manifest, an invalid signature, a missing signature, a package whose bytes do not match the signed checksum, and both the stable and prerelease update paths. Add these as helper tests in `tools/tellus_helper_test.sh`. Do not widen the helper's allowlist, folder rules or package-name checks without discussing it with the owner first.

Background: today the package and its checksum come from the same release, so the checksum check alone does not independently authenticate the checksum source. See `LEARNINGS.md`, "The Tellus app".

### 2. Optional update check on launch

After signed release verification is in place, add an optional setting that checks for updates when Tellus launches.

- The setting is **off by default**.
- When enabled, Tellus checks for updates at launch, and an available update is shown as a badge on the About page.
- Results are cached, and GitHub's `ETag` support is used so requests are not wasted against the per-address API limit.
- A check never installs anything. The user stays in control of installation.
- Offline launches and failed checks must not make Tellus unusable or cause repeated needless requests.

### 3. Release tool (`oitui-release`)

One command-line tool on the owner's PC that carries out the documented release steps (`COMMANDS.md` sections 43 to 45), so a release is: choose a tested candidate, release it, done.

- First: `status` (read-only overview), `verify` (check a release's files and its signature against the keys built into the helper) and `candidate` (use or start the release build, assemble the packages, sign `SHA256SUMS`, publish a pre-release).
- Then, after those have worked for real: `release`, which promotes a tested candidate (the same signed files) to a release and does the cleanup.
- Rules the tool keeps: it never sees the key passphrase; it signs only after showing the files and hashes and getting a yes, and only if the helper's built-in keys accept the new signature; every command that changes something is logged and can be rehearsed with `--dry-run`; it never force-pushes and never merges to `main` without the owner's explicit typed confirmation; unchanged packages are attached byte-identical from the previous release.
- Before relying on it, its tests with a fake `gh` pass, and its first use on the real repository is a dry run.

## Ongoing updater requirements

These are validation requirements for updater work, not separate features:

- Keep the Update All behaviour: install only packages that are newer, in the order OITCore, Insula, Tellus.
- The next time OITCore itself changes, test the OITCore-first order of Update All end to end. It has not been tested, because 0.4.1 changed only Insula and Tellus.
- Keep stable-release and prerelease version comparisons correct. A prerelease that Tellus must download must not contain `~` in its version, because GitHub rewrites it in asset names; carry the final version numbers instead.

## Explicitly not in the current plan

- **Litus integration is postponed.** Do not add Litus to Tellus' updater allowlists, installer or app pages until the owner decides to bring it back.
- **Landscape Island notifications are on hold for a long while.**

Everything else (uncommitted ideas, research topics, parked work) belongs in `IDEAS.md`.
