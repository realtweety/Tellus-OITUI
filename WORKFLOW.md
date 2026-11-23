# OITUI Git workflow

## Branches

- **`main`**: tested, release-ready code only. Nothing is committed to it directly.
- **`experiments`**: the single working branch. All unfinished OITI/OITS work, experiments, temporary diagnostic code and unstable changes live here until they have run on the device.

There is never more than `main` plus one working branch.

## Landing work

1. Develop and test on `experiments`. Mark untested work as untested in the commit message or the file header.
2. When a set of changes has been tested on-device, open a pull request `experiments` -> `main`.
3. Review the diff, then **squash merge**. One squash commit per PR keeps `main` linear and readable. Do not use merge commits.
4. After the merge, GitHub deletes the finished `experiments` branch automatically. Create a fresh one from the updated `main`:

   ```
   git fetch --prune origin
   git switch main
   git pull --ff-only
   git branch -D experiments
   git switch -c experiments
   git push -u origin experiments
   git rev-parse main experiments origin/experiments
   ```

   The three hashes must match. Run the block only after the tag and the GitHub Release exist, and from `main` (`git switch main` first: git refuses to delete the branch you are on, and a local `experiments` that still holds the old history would be pushed by `git push -u origin experiments`). If the remote `experiments` still exists after the merge, delete it first with `git push origin --delete experiments`. `-D` is needed because a squash merge does not make the old branch an ancestor of `main`, so `-d` refuses. Check the PR shows as merged before deleting. If git says the local branch does not exist, ignore that line.

**Test before merging.** Do not open the PR until the changes have run on the phone. Minimum check: stock settings still look stock (every Island setting at its default), banners, the settings pages touched by the change, and the respring-loop guard (`COMMANDS.md`, section 7).

Never force-push `main` or rewrite its history.

## Releases

A commit on `main` is not automatically a release. A release is a version tag plus a GitHub Release with the packages attached. Only `main`, only tested work.

- **Release packages are built by GitHub Actions** (`.github/workflows/release-oiti.yml`, `FINALPACKAGE=1`, OITCore, OITI and the Tellus app, never OITS). Run it by hand (`gh workflow run release-oiti.yml --ref experiments`, or Actions > "Release build (OITCore + OITI + Tellus)" > Run workflow, pick the branch) or push a `v*` tag. GitHub only dispatches a workflow file that exists on the default branch: `release-oiti.yml` has been on `main` since 0.3.0, so the manual run works now (for 0.3.0 it did not, the file existed only on `experiments`, and a `v0.3.0-rc.1` tag was used instead); it uploads the three `.deb` files and a `SHA256SUMS` file as one artifact (kept 30 days) and publishes nothing. The run fails if Tellus's `control` Depends on a `+debug` package or on a newer Insula than the release contains, or if its `control` version differs from `MARKETING_VERSION`. Do not build release packages on the Arch PC (its arm64e objects warn about an incompatible ABI). Ship **OITCore and OITI together** (OITI depends on OITCore), and attach `SHA256SUMS` from the same run to the GitHub Release (Tellus's updater uses it to verify downloads; hashes from a different run will not match). Do not ship OITS until it is verified.
- **Versions** live in each module's `control` file (`Version:`). Keep them ascending: dpkg sorts `0.0.10` below `0.1.0`. Bump the version through a normal PR before tagging. Tag names are `vMAJOR.MINOR.PATCH`. OITCore remains `0.1.0` until it changes.
- **Release candidate.** Once the work has run on the phone, run the release workflow on `experiments`, download the artifact and test **those exact `.deb` files** (`scp`, `dpkg -i`, `sbreload`) before anything is merged or tagged. Then PR `experiments` to `main`, squash merge, recreate `experiments`, tag `main`, and create the GitHub Release by hand with the same `.deb` files attached (or re-run the workflow from the tag if the merge changed the code).
- **Betas and pre-releases:** a tilde version such as `0.2.0~beta.1` sorts below `0.2.0`; tag `v0.2.0-beta.1` and mark the GitHub Release as a pre-release. Since 0.4.0 a pre-release is also how a release candidate is tried through Tellus: attach the three `.deb` files and `SHA256SUMS` of ONE release-workflow run, mark it as a pre-release, and in Tellus switch on **Include Pre-releases** (the normal check ignores pre-releases, so nobody else sees it). Delete or promote it afterwards.
- **No `~` in a version that Tellus has to download (found 23 Nov 2026, `v0.4.1-rc.1`).** GitHub rewrites `~` to `.` in an uploaded asset name, so the asset was `com.wilburt.oiti_0.4.1.rc.1_...deb` while `SHA256SUMS` listed `0.4.1~rc.1`; Tellus looks the package up in the list by the asset name and refused the download ("The release's checksum list does not include this package"), and it also read the version as `0.4.1.rc.1`, which sorts above the installed `0.4.1~rc.1`. The release candidate was repaired by hand: `SHA256SUMS` was re-uploaded with the dotted name (the `.deb` bytes stayed the tested ones). Until Tellus handles this, give a pre-release a version without `~` (for example `0.4.0.1`: above 0.4.0, below 0.4.1), or repair `SHA256SUMS` the same way before testing the update in Tellus.
- **Tellus ships with the release:** `TellusApp/layout/DEBIAN/control` (`Version:` and `Depends: com.wilburt.oiti (>= <the Insula version of the release>)`) and `MARKETING_VERSION` in the Xcode project must agree, and the release workflow checks it. Attach `SHA256SUMS` from the same run as the `.deb` files (hashes from a different run do not match). Upgrading from an Insula older than 0.4.0 is a manual install.
- **Tag before the Release.** Create and push the tag on the merged commit of `main` first (`git tag -a vX.Y.Z -m "..."`, `git push origin vX.Y.Z`), then `gh release create vX.Y.Z --verify-tag ...`. Without `--verify-tag`, a missing tag is created on the default branch's newest commit; v0.3.1 was published that way, its tag pointed at the 0.3.0 commit, and the tag had to be moved to the squash commit of the 0.3.1 pull request. Check `git status` before `git add -A`: two empty files named `-D` and `^{tree}` (from a command with a placeholder in fish) were committed once and had to be removed.
- **Release notes (owner's decision, 8 Nov 2026):** the text of the GitHub Release is the only release note. Do not add `RELEASE_NOTES_*.md` files to the repo (the old ones are deleted). Create the Release with `--notes` or the web form, not `--notes-file`.
- **CI:** `.github/workflows/build-oiti.yml` builds the `.deb` files (OITCore, OITI and Tellus) on every push to `experiments` (a `DEBUG=1` build for testing; the version carries `+debug`; a failing Tellus build still uploads the other two packages, but turns the run red). Those are never released. `release-oiti.yml` is the only workflow that builds release packages.
- Exact commands: `COMMANDS.md`, section 10 ("Releases"). Released: `v0.1.0` (`46cf122`), `v0.1.1`, pre-release `v0.2.0-beta.1`; `v0.2.0`; `v0.2.5`; `v0.3.0` and `v0.3.1` (9 Nov 2026), `v0.4.0` (22 Nov 2026, squash commit `885795e`; Insula 0.4.0 with the Tellus app 0.1.0 and a `SHA256SUMS` file, first release with three packages), `v0.3.5` (11 Nov 2026, squash commit `81c4587`; the release workflow was started with `gh workflow run release-oiti.yml --ref experiments` and the tested artifact was attached). `v0.3.6` (16 Nov 2026, squash commit `a666c71` "OITUI 0.3.6 (#14)", tag `v0.3.6` on it; the release workflow was run on `experiments` twice, RC 1 `d9f331a` and RC 2 `3a76235`, and the tested RC 2 artifact was attached; OITCore `0.1.0` unchanged; a change to the package after a tested release candidate, even one settings row, means running the release workflow again and testing the new files). In preparation: `v0.3.7` (a Safari source). Note: the `v0.3.1` tag points at `365909f` (the 0.3.5 research batch 1: it contains the 0.3.1 code plus inert research code), because that Release was published before its tag existed; it was left as it is. The repository is `realtweety/Tellus-OITUI` (it was renamed; the old URL redirects).

## Logging policy

- Release defaults are quiet: `DiagnosticsLevel` defaults to 0 in OITI, OITS and `OITLogger`. Warnings and errors that matter in normal use (safe mode, self-check, MobileGestalt writes, main-thread stalls) are written at level 0.
- Verbose or per-call logging, dumps, polling timers and system-notification taps run only when `DiagnosticsLevel` is raised with `defaults write`. See `DIAGNOSTICS.md`.
- Do not delete useful diagnostics to tidy the code; gate them behind the level instead.
