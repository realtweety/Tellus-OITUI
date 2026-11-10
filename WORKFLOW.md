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

   The three hashes must match. `-D` is needed because a squash merge does not make the old branch an ancestor of `main`, so `-d` refuses. Check the PR shows as merged before deleting. If git says the local branch does not exist, ignore that line.

**Test before merging.** Do not open the PR until the changes have run on the phone. Minimum check: stock settings still look stock (every Island setting at its default), banners, the settings pages touched by the change, and the respring-loop guard (`COMMANDS.md`, section 7).

Never force-push `main` or rewrite its history.

## Releases

A commit on `main` is not automatically a release. A release is a version tag plus a GitHub Release with the packages attached. Only `main`, only tested work.

- **Release packages are built by GitHub Actions** (`.github/workflows/release-oiti.yml`, `FINALPACKAGE=1`, OITCore and OITI only, never OITS). Run it by hand (`gh workflow run release-oiti.yml --ref experiments`, or Actions > "Release build (OITCore + OITI)" > Run workflow, pick the branch) or push a `v*` tag. GitHub only dispatches a workflow file that exists on the default branch: `release-oiti.yml` has been on `main` since 0.3.0, so the manual run works now (for 0.3.0 it did not, the file existed only on `experiments`, and a `v0.3.0-rc.1` tag was used instead); it uploads the two `.deb` files as an artifact (kept 30 days) and publishes nothing. Do not build release packages on the Arch PC (its arm64e objects warn about an incompatible ABI). Ship **OITCore and OITI together** (OITI depends on OITCore). Do not ship OITS until it is verified.
- **Versions** live in each module's `control` file (`Version:`). Keep them ascending: dpkg sorts `0.0.10` below `0.1.0`. Bump the version through a normal PR before tagging. Tag names are `vMAJOR.MINOR.PATCH`. OITCore remains `0.1.0` until it changes.
- **Release candidate.** Once the work has run on the phone, run the release workflow on `experiments`, download the artifact and test **those exact `.deb` files** (`scp`, `dpkg -i`, `sbreload`) before anything is merged or tagged. Then PR `experiments` to `main`, squash merge, recreate `experiments`, tag `main`, and create the GitHub Release by hand with the same `.deb` files attached (or re-run the workflow from the tag if the merge changed the code).
- **Betas** (not used for 0.3.0): a tilde version such as `0.2.0~beta.1` sorts below `0.2.0`; tag `v0.2.0-beta.1` and mark the GitHub Release as a pre-release.
- **Tag before the Release.** Create and push the tag on the merged commit of `main` first (`git tag -a vX.Y.Z -m "..."`, `git push origin vX.Y.Z`), then `gh release create vX.Y.Z --verify-tag ...`. Without `--verify-tag`, a missing tag is created on the default branch's newest commit; v0.3.1 was published that way, its tag pointed at the 0.3.0 commit, and the tag had to be moved to the squash commit of the 0.3.1 pull request. Check `git status` before `git add -A`: two empty files named `-D` and `^{tree}` (from a command with a placeholder in fish) were committed once and had to be removed.
- **Release notes (owner's decision, 8 Nov 2026):** the text of the GitHub Release is the only release note. Do not add `RELEASE_NOTES_*.md` files to the repo (the old ones are deleted). Create the Release with `--notes` or the web form, not `--notes-file`.
- **CI:** `.github/workflows/build-oiti.yml` builds the `.deb` files on every push to `experiments` (a `DEBUG=1` build for testing; the version carries `+debug`). Those are never released. `release-oiti.yml` is the only workflow that builds release packages.
- Exact commands: `COMMANDS.md`, section 10 ("Releases"). Released: `v0.1.0` (`46cf122`), `v0.1.1`, pre-release `v0.2.0-beta.1`; `v0.2.0`; `v0.2.5`; `v0.3.0` and `v0.3.1` (9 Nov 2026). In preparation: `v0.3.5` (browser downloads). The repository is `realtweety/Tellus-OITUI` (it was renamed; the old URL redirects).

## Logging policy

- Release defaults are quiet: `DiagnosticsLevel` defaults to 0 in OITI, OITS and `OITLogger`. Warnings and errors that matter in normal use (safe mode, self-check, MobileGestalt writes, main-thread stalls) are written at level 0.
- Verbose or per-call logging, dumps, polling timers and system-notification taps run only when `DiagnosticsLevel` is raised with `defaults write`. See `DIAGNOSTICS.md`.
- Do not delete useful diagnostics to tidy the code; gate them behind the level instead.
