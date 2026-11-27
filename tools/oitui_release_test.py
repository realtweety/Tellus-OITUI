#!/usr/bin/env python3
"""Tests for tools/oitui-release, with a fake `gh` and a throw-away repository (with a bare "origin"). Nothing touches GitHub,
your keys or your real repository.

    python3 tools/oitui_release_test.py

Needs git and OpenSSL 3. The fake gh answers `run list`, `release list/view/download/create`, `run download/watch` and `workflow run`
from a JSON state file; what the tool asks it to create is recorded so the tests can check it.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REAL_REPO = HERE.parent
TOOL = HERE / "oitui-release"

FAKE_GH = r'''#!/usr/bin/env python3
import datetime, json, os, shutil, subprocess, sys, tempfile
state_path = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
def save(): json.dump(state, open(state_path, "w"))
def option(name):
    return args[args.index(name) + 1] if name in args else None
if args[:2] == ["run", "list"]:
    print(json.dumps(state["runs"].get(option("--workflow"), [])))
elif args[:2] == ["release", "list"]:
    print(json.dumps([{"tagName": state["stable"]}] if state.get("stable") else []))
elif args[:2] == ["release", "view"]:
    if args[2] not in state["releases"]:
        sys.stderr.write("release not found\n"); sys.exit(1)
    print(json.dumps({"tagName": args[2], "isPrerelease": args[2] in state.get("prereleases", []),
                      "assets": [{"name": n} for n in sorted(os.listdir(state["releases"][args[2]]))]}))
elif args[:2] == ["release", "download"]:
    shutil.copytree(state["releases"][args[2]], option("-D"), dirs_exist_ok=True)
elif args[:2] == ["run", "download"]:
    shutil.copytree(state["artifact"], os.path.join(option("-D"), "artifact"), dirs_exist_ok=True)
elif args[:2] == ["run", "watch"]:
    pass
elif args[:2] == ["workflow", "run"]:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    state["triggered"] = state.get("triggered", 0) + 1
    state["runs"].setdefault(args[2], []).insert(0, {"databaseId": 900 + state["triggered"], "headSha": head, "status": "completed",
        "conclusion": "success", "event": "workflow_dispatch",
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    save()
elif args[:2] == ["release", "delete"]:
    tag = args[2]
    state["releases"].pop(tag, None)
    if tag in state.get("prereleases", []): state["prereleases"].remove(tag)
    if "--cleanup-tag" in args:
        subprocess.run(["git", "--git-dir", state["origin"], "tag", "-d", tag], capture_output=True)
    save()
elif args[:2] == ["pr", "list"]:
    print(json.dumps(state.get("open_prs", [])))
elif args[:2] == ["pr", "create"]:
    state["open_prs"] = [{"number": 17}]
    state.setdefault("pr_calls", []).append(args[2:])
    save()
    print("https://github.com/example/repo/pull/17")
elif args[:2] == ["pr", "diff"]:
    out = subprocess.run(["git", "diff", "--name-only", "origin/main...origin/experiments"], capture_output=True, text=True).stdout
    print(out, end="")
elif args[:2] == ["pr", "merge"]:
    work = tempfile.mkdtemp()
    def g(*a): return subprocess.run(["git", "-C", work] + list(a), capture_output=True, text=True, check=True)
    subprocess.run(["git", "clone", "-q", state["origin"], work], check=True)
    g("checkout", "-q", "main")
    g("merge", "--squash", "-q", "origin/experiments")
    if os.environ.get("FAKE_GH_TAMPER"):
        open(os.path.join(work, "tampered.txt"), "w").write("not in the reviewed tree\\n")
        g("add", "-A")
    g("commit", "-q", "-m", option("--subject"))
    g("push", "-q", "origin", "main")
    if state.get("auto_delete", True):
        g("push", "-q", "origin", "--delete", "experiments")
    sha = g("rev-parse", "HEAD").stdout.strip()
    state["open_prs"] = []
    state["merge_commit"] = sha
    state.setdefault("pr_merges", []).append(args[2:])
    save()
elif args[:2] == ["pr", "view"]:
    print(json.dumps({"state": "MERGED" if state.get("merge_commit") else "OPEN", "mergeCommit": {"oid": state.get("merge_commit")}}))
elif args[:2] == ["release", "create"]:
    if os.environ.get("FAKE_GH_FAIL") == "release-create":
        sys.stderr.write("simulated failure\n"); sys.exit(1)
    tag = args[2]
    target = os.path.join(state["root"], "created-" + tag)
    os.makedirs(target)
    files = [a for a in args[3:] if os.path.isfile(a)]
    for f in files:
        shutil.copy(f, target)
    state["releases"][tag] = target
    if "--prerelease" in args:
        state.setdefault("prereleases", []).append(tag)
    else:
        state["stable"] = tag
    state.setdefault("created", []).append({"tag": tag, "args": args[2:], "files": [os.path.basename(f) for f in files]})
    save()
else:
    sys.stderr.write("fake gh: unsupported " + repr(args) + "\n"); sys.exit(2)
'''


def sh(*command, cwd=None, check=True, env=None):
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=check, env=env)


def pin_versions(repo):
    """The tests build their fixtures for fixed versions (OITCore 0.1.0, Insula 0.4.1, Tellus 0.1.2), whatever the real repository has."""
    for relative, version in (("OITCore/control", "0.1.0"), ("OITI/control", "0.4.1"), ("TellusApp/layout/DEBIAN/control", "0.1.2")):
        path = Path(repo) / relative
        path.write_text(re.sub(r"^Version: .*$", "Version: " + version, path.read_text(), flags=re.M))
    project = Path(repo) / "TellusApp/TellusApp.xcodeproj/project.pbxproj"
    project.write_text(re.sub(r"MARKETING_VERSION = [^;]+;", "MARKETING_VERSION = 0.1.2;", project.read_text()))


def make_keys(folder):
    keys = {}
    for label in ("a", "b", "other"):
        pem = folder / (label + ".pem")
        sh("openssl", "genpkey", "-algorithm", "ed25519", "-out", str(pem))
        der = sh("openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER").stdout if False else None
        raw = subprocess.run(["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], capture_output=True).stdout[-32:]
        keys[label] = (pem, raw.hex())
    return keys


class ReleaseToolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys_dir = Path(tempfile.mkdtemp(prefix="oitui-release-keys-"))
        cls.keys = make_keys(cls.keys_dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.keys_dir, ignore_errors=True)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="oitui-release-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.repo = self.root / "repo"
        origin = self.root / "origin.git"
        sh("git", "init", "--bare", "-q", str(origin))
        for relative in ("OITCore/control", "OITI/control", "TellusApp/layout/DEBIAN/control",
                         "TellusApp/TellusApp.xcodeproj/project.pbxproj", "TellusApp/Helper/tellus-helper.c"):
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REAL_REPO / relative, target)
        pin_versions(self.repo)
        helper = self.repo / "TellusApp/Helper/tellus-helper.c"
        text = helper.read_text()
        text = re.sub(r'(#define TELLUS_TRUSTED_KEY_1 ")[0-9a-f]{64}', r"\g<1>" + self.keys["a"][1], text)
        text = re.sub(r'(#define TELLUS_TRUSTED_KEY_2 ")[0-9a-f]{64}', r"\g<1>" + self.keys["b"][1], text)
        helper.write_text(text)
        self.git("init", "-q", "-b", "experiments")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "test tree")
        self.git("remote", "add", "origin", str(origin))
        self.git("push", "-q", "origin", "experiments")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

        # the previous stable release (v0.4.1) and the CI artifact of HEAD
        old = self.root / "v041"
        old.mkdir()
        self.old_files = {"com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb": b"OLD OITCORE",
                          "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb": b"OLD OITI",
                          "com.wilburt.tellus_0.1.1_iphoneos-arm64.deb": b"OLD TELLUS"}
        for name, data in self.old_files.items():
            (old / name).write_bytes(data)
        (old / "SHA256SUMS").write_text("".join(self.sha(old / n) + "  " + n + "\n" for n in sorted(self.old_files)))
        artifact = self.root / "artifact"
        artifact.mkdir()
        self.new_files = {"com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb": b"REBUILT OITCORE",
                          "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb": b"REBUILT OITI",
                          "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb": b"NEW TELLUS"}
        for name, data in self.new_files.items():
            (artifact / name).write_bytes(data)
        (artifact / "SHA256SUMS").write_text("".join(self.sha(artifact / n) + "  " + n + "\n" for n in sorted(self.new_files)))
        self.state_path = self.root / "gh_state.json"
        self.write_state({
            "root": str(self.root), "stable": "v0.4.1", "releases": {"v0.4.1": str(old)}, "artifact": str(artifact),
            "runs": {"build-oiti.yml": [{"databaseId": 1, "headSha": self.head, "status": "completed", "conclusion": "success"}],
                     "release-oiti.yml": [{"databaseId": 2, "headSha": self.head, "status": "completed", "conclusion": "success",
                                           "event": "workflow_dispatch", "createdAt": "2026-11-25T12:00:00Z"}]}})
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], OITUI_REPO_DIR=str(self.repo),
                        FAKE_GH_STATE=str(self.state_path), OITUI_SIGNING_KEY=str(self.keys["a"][0]),
                        XDG_STATE_HOME=str(self.root / "state"), OITUI_POLL_SECONDS="0", HOME=str(self.root),
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

    # ---- helpers
    def git(self, *args, **kwargs):
        return sh("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, cwd=self.repo, **kwargs)

    def sha(self, path):
        import hashlib
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def tool(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, str(TOOL), *args], input=stdin, text=True, capture_output=True, env=env or self.env)

    # ---- candidate
    def test_candidate_signs_and_publishes(self):
        out = self.root / "out"
        result = self.tool("candidate", "0.4.2", "--out", str(out), stdin="y\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(p.name for p in out.iterdir()),
                         sorted(list(self.old_files)[:2] + ["com.wilburt.tellus_0.1.2_iphoneos-arm64.deb", "SHA256SUMS", "SHA256SUMS.sig"]))
        # unchanged packages are the released bytes, the changed one is the CI build
        self.assertEqual((out / "com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb").read_bytes(), b"OLD OITCORE")
        self.assertEqual((out / "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb").read_bytes(), b"OLD OITI")
        self.assertEqual((out / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb").read_bytes(), b"NEW TELLUS")
        created = self.state()["created"]
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["tag"], "v0.4.2-rc.1")
        self.assertIn("--prerelease", created[0]["args"])
        self.assertIn("--verify-tag", created[0]["args"])
        self.assertEqual(len(created[0]["files"]), 5)
        self.assertIn("v0.4.2-rc.1", self.git("tag", "-l").stdout)
        self.assertIn("v0.4.2-rc.1", sh("git", "ls-remote", "--tags", "origin", cwd=self.repo).stdout)
        self.assertIn("valid signature by the primary key", result.stdout)
        self.assertEqual(self.tool("verify", str(out)).returncode, 0)

    def test_second_candidate_gets_the_next_number(self):
        self.tool("candidate", "0.4.2", "--out", str(self.root / "o1"), stdin="y\ny\n")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "o2"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c["tag"] for c in self.state()["created"]], ["v0.4.2-rc.1", "v0.4.2-rc.2"])

    def test_candidate_signed_by_the_backup_key_is_accepted(self):
        env = dict(self.env, OITUI_SIGNING_KEY=str(self.keys["b"][0]))
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n", env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("valid signature by the backup key", result.stdout)

    def test_declining_to_sign_changes_nothing(self):
        out = self.root / "out"
        result = self.tool("candidate", "0.4.2", "--out", str(out), stdin="n\n")
        self.assertEqual(result.returncode, 1)
        self.assertFalse((out / "SHA256SUMS.sig").exists())
        self.assertEqual(self.git("tag", "-l").stdout.strip(), "")
        self.assertNotIn("created", self.state())

    def test_a_key_the_helper_does_not_trust_is_refused(self):
        out = self.root / "out"
        env = dict(self.env, OITUI_SIGNING_KEY=str(self.keys["other"][0]))
        result = self.tool("candidate", "0.4.2", "--out", str(out), stdin="y\ny\n", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the key Tellus trusts", result.stdout)
        self.assertFalse((out / "SHA256SUMS.sig").exists())
        self.assertEqual(self.git("tag", "-l").stdout.strip(), "")
        self.assertNotIn("created", self.state())

    def test_dry_run_changes_nothing(self):
        out = self.root / "out"
        result = self.tool("candidate", "0.4.2", "--out", str(out), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[dry-run]", result.stdout)
        self.assertFalse((out / "SHA256SUMS.sig").exists())
        self.assertEqual(self.git("tag", "-l").stdout.strip(), "")
        self.assertNotIn("created", self.state())

    def test_no_existing_run_starts_one(self):
        state = self.state()
        state["runs"]["release-oiti.yml"] = []
        self.write_state(state)
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state()["triggered"], 1)

    def test_dry_run_without_a_run_does_not_start_one(self):
        state = self.state()
        state["runs"]["release-oiti.yml"] = []
        self.write_state(state)
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("triggered", self.state())

    # ---- refusals
    def test_unpushed_commit_is_refused(self):
        (self.repo / "note.txt").write_text("x")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "local only")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not what origin", result.stdout)

    def test_uncommitted_changes_are_refused(self):
        (self.repo / "OITI/control").write_text((self.repo / "OITI/control").read_text() + "\n")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("uncommitted", result.stdout)

    def test_wrong_branch_is_refused(self):
        self.git("switch", "-q", "-c", "other")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not 'experiments'", result.stdout)

    def test_red_ci_is_refused(self):
        state = self.state()
        state["runs"]["build-oiti.yml"][0]["conclusion"] = "failure"
        self.write_state(state)
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("has not succeeded", result.stdout)

    def test_release_number_must_be_higher(self):
        result = self.tool("candidate", "0.4.1", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not higher", result.stdout)

    def test_nothing_changed_is_refused(self):
        control = self.repo / "TellusApp/layout/DEBIAN/control"
        control.write_text(control.read_text().replace("Version: 0.1.2", "Version: 0.1.1"))
        project = self.repo / "TellusApp/TellusApp.xcodeproj/project.pbxproj"
        project.write_text(project.read_text().replace("MARKETING_VERSION = 0.1.2;", "MARKETING_VERSION = 0.1.1;"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "back to 0.1.1")
        self.git("push", "-q", "origin", "experiments")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        state = self.state()
        for workflow in state["runs"].values():
            workflow[0]["headSha"] = head
        self.write_state(state)
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("nothing to release", result.stdout)

    def test_control_and_project_versions_must_agree(self):
        project = self.repo / "TellusApp/TellusApp.xcodeproj/project.pbxproj"
        project.write_text(project.read_text().replace("MARKETING_VERSION = 0.1.2;", "MARKETING_VERSION = 0.1.9;", 1))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "mismatch")
        self.git("push", "-q", "origin", "experiments")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        state = self.state()
        for workflow in state["runs"].values():
            workflow[0]["headSha"] = head
        self.write_state(state)
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Xcode project says", result.stdout)

    def test_a_corrupt_artifact_is_refused(self):
        artifact = Path(self.state()["artifact"])
        (artifact / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb").write_bytes(b"CORRUPTED")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match the build's own SHA256SUMS", result.stdout)

    def test_a_debug_build_is_refused(self):
        artifact = Path(self.state()["artifact"])
        (artifact / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb").rename(artifact / "com.wilburt.tellus_0.1.2+debug_iphoneos-arm64.deb")
        (artifact / "SHA256SUMS").unlink()
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("has no com.wilburt.tellus_0.1.2_iphoneos-arm64.deb", result.stdout)

    def test_a_tampered_previous_release_is_refused(self):
        old = Path(self.state()["releases"]["v0.4.1"])
        (old / "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb").write_bytes(b"TAMPERED")
        result = self.tool("candidate", "0.4.2", "--out", str(self.root / "out"), stdin="y\ny\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match that release's SHA256SUMS", result.stdout)

    # ---- verify
    def signed_folder(self):
        out = self.root / "out"
        self.tool("candidate", "0.4.2", "--out", str(out), stdin="y\ny\n")
        return out

    def test_verify_good_folder(self):
        out = self.signed_folder()
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("signed, complete and consistent", result.stdout)

    def test_verify_a_release_by_tag(self):
        self.signed_folder()
        self.assertEqual(self.tool("verify", "v0.4.2-rc.1").returncode, 0)

    def test_verify_changed_manifest(self):
        out = self.signed_folder()
        with open(out / "SHA256SUMS", "a") as handle:
            handle.write("# tampered\n")
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a valid signature", result.stdout)

    def test_verify_changed_package(self):
        out = self.signed_folder()
        with open(out / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb", "ab") as handle:
            handle.write(b"x")
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match its SHA256SUMS entry", result.stdout)

    def test_verify_unsigned_release(self):
        out = self.signed_folder()
        (out / "SHA256SUMS.sig").unlink()
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("UNSIGNED", result.stdout)

    def test_verify_the_old_unsigned_release_by_tag(self):
        result = self.tool("verify", "v0.4.1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("UNSIGNED", result.stdout)

    def test_verify_wrong_key_signature(self):
        out = self.signed_folder()
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.keys["other"][0]), "-in", str(out / "SHA256SUMS"),
                        "-out", str(out / "SHA256SUMS.sig")], check=True)
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a valid signature", result.stdout)

    def test_verify_extra_unlisted_file(self):
        out = self.signed_folder()
        (out / "com.wilburt.oits_0.1.0_iphoneos-arm64.deb").write_bytes(b"EXTRA")
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not listed in SHA256SUMS", result.stdout)

    def test_verify_tilde_in_a_name(self):
        out = self.signed_folder()
        (out / "com.wilburt.oiti_0.4.2~rc.1_iphoneos-arm64.deb").write_bytes(b"X")
        result = self.tool("verify", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("`~`", result.stdout)

    # ---- status
    def test_status(self):
        result = self.tool("status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("com.wilburt.tellus 0.1.2  (CHANGED from 0.1.1)", result.stdout)
        self.assertIn("com.wilburt.oiti 0.4.1  (unchanged)", result.stdout)
        self.assertIn("CI build of HEAD: completed, success", result.stdout)


class ReleaseCommandTest(unittest.TestCase):
    """`oitui-release release`: a real squash merge in a throw-away bare origin, with the fake gh doing the merge."""

    @classmethod
    def setUpClass(cls):
        cls.keys_dir = Path(tempfile.mkdtemp(prefix="oitui-release-keys-"))
        cls.keys = make_keys(cls.keys_dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.keys_dir, ignore_errors=True)

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="oitui-release-rtest-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.repo = self.root / "repo"
        self.origin = self.root / "origin.git"
        sh("git", "init", "--bare", "-q", "-b", "main", str(self.origin))
        for relative in ("OITCore/control", "OITI/control", "TellusApp/layout/DEBIAN/control",
                         "TellusApp/TellusApp.xcodeproj/project.pbxproj", "TellusApp/Helper/tellus-helper.c", "TellusApp/Helper/monocypher.c"):
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = REAL_REPO / relative
            shutil.copy(source if source.exists() else REAL_REPO / "TellusApp/Helper/tellus-helper.c", target)
        pin_versions(self.repo)
        text = (self.repo / "TellusApp/Helper/tellus-helper.c").read_text()
        text = re.sub(r'(#define TELLUS_TRUSTED_KEY_1 ")[0-9a-f]{64}', r"\g<1>" + self.keys["a"][1], text)
        text = re.sub(r'(#define TELLUS_TRUSTED_KEY_2 ")[0-9a-f]{64}', r"\g<1>" + self.keys["b"][1], text)
        (self.repo / "TellusApp/Helper/tellus-helper.c").write_text(text)
        # main = the previous release: Tellus 0.1.1
        control = self.repo / "TellusApp/layout/DEBIAN/control"
        control.write_text(control.read_text().replace("Version: 0.1.2", "Version: 0.1.1"))
        project = self.repo / "TellusApp/TellusApp.xcodeproj/project.pbxproj"
        project.write_text(project.read_text().replace("MARKETING_VERSION = 0.1.2;", "MARKETING_VERSION = 0.1.1;"))
        (self.repo / "README.md").write_text("docs\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "release 0.4.1")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("remote", "set-branches", "origin", "*")
        self.git("push", "-q", "origin", "main")
        # experiments: the tested commit (Tellus 0.1.2), then a documentation commit
        self.git("switch", "-q", "-c", "experiments")
        control.write_text(control.read_text().replace("Version: 0.1.1", "Version: 0.1.2"))
        project.write_text(project.read_text().replace("MARKETING_VERSION = 0.1.1;", "MARKETING_VERSION = 0.1.2;"))
        self.git("commit", "-q", "-am", "Tellus 0.1.2")
        self.tested = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("tag", "-a", "v0.4.2-rc.1", "-m", "rc")
        (self.repo / "tools").mkdir()
        (self.repo / "tools/oitui-release").write_text("tool\n")
        (self.repo / "README.md").write_text("docs, changed\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "docs and tooling")
        self.git("push", "-q", "origin", "experiments", "--tags")

        # the candidate release (signed, made like `candidate` makes it) and the previous release
        rc = self.root / "rc"
        rc.mkdir()
        for name, data in {"com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb": b"OITCORE", "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb": b"OITI",
                           "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb": b"TELLUS 012"}.items():
            (rc / name).write_bytes(data)
        import hashlib
        (rc / "SHA256SUMS").write_text("".join(hashlib.sha256((rc / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in sorted(os.listdir(rc))))
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.keys["a"][0]), "-in", str(rc / "SHA256SUMS"),
                        "-out", str(rc / "SHA256SUMS.sig")], check=True)
        old = self.root / "v041"
        old.mkdir()
        (old / "com.wilburt.tellus_0.1.1_iphoneos-arm64.deb").write_bytes(b"TELLUS 011")
        self.state_path = self.root / "gh_state.json"
        tip = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_state({"root": str(self.root), "origin": str(self.origin), "stable": "v0.4.1", "prereleases": ["v0.4.2-rc.1"],
                          "releases": {"v0.4.1": str(old), "v0.4.2-rc.1": str(rc)}, "open_prs": [],
                          "runs": {"build-oiti.yml": [{"databaseId": 1, "headSha": tip, "status": "completed", "conclusion": "success"}]}})
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.notes = self.root / "notes.md"
        self.notes.write_text("Tellus 0.1.2: signed releases.\n")
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], OITUI_REPO_DIR=str(self.repo),
                        FAKE_GH_STATE=str(self.state_path), XDG_STATE_HOME=str(self.root / "state"), OITUI_POLL_SECONDS="0",
                        HOME=str(self.root), GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

    IDENTITY = dict(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")

    def git(self, *args, **kwargs):
        return sh("git", *args, cwd=self.repo, env=dict(os.environ, **self.IDENTITY), **kwargs)

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def tool(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, str(TOOL), *args], input=stdin, text=True, capture_output=True, env=env or self.env)

    def release(self, stdin="y\n0.4.2\n", extra=(), env=None):
        return self.tool("release", "v0.4.2-rc.1", "--notes-file", str(self.notes), *extra, stdin=stdin, env=env)

    def origin_git(self, *args):
        return sh("git", "--git-dir", str(self.origin), *args)

    def assert_untouched(self):
        self.assertEqual(self.state().get("open_prs"), [])
        self.assertNotIn("pr_merges", self.state())
        self.assertNotIn("v0.4.2", self.origin_git("tag", "-l").stdout.split())
        self.assertEqual(self.state()["stable"], "v0.4.1")

    # ---- the whole release
    def test_full_release(self):
        result = self.release(stdin="y\n0.4.2\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = self.state()
        self.assertEqual(state["stable"], "v0.4.2")
        self.assertNotIn("v0.4.2", state["prereleases"])
        self.assertNotIn("v0.4.2-rc.1", state["releases"])                      # the pre-release is gone
        self.assertEqual(sorted(os.listdir(state["releases"]["v0.4.2"])),
                         ["SHA256SUMS", "SHA256SUMS.sig", "com.wilburt.oitcore_0.1.0_iphoneos-arm64.deb",
                          "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb", "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb"])
        tags = self.origin_git("tag", "-l").stdout.split()
        self.assertIn("v0.4.2", tags)
        self.assertNotIn("v0.4.2-rc.1", tags)
        main = self.origin_git("rev-parse", "main").stdout.strip()
        self.assertEqual(self.origin_git("rev-parse", "v0.4.2^{commit}").stdout.strip(), main)      # tagged on the merge commit
        # main has the reviewed tree: the tested product plus the documentation change
        experiments_tree = self.origin_git("rev-parse", "experiments^{tree}").stdout.strip()
        self.assertEqual(self.origin_git("rev-parse", "main^{tree}").stdout.strip(), experiments_tree)
        self.assertEqual(self.git("rev-parse", "main").stdout.strip(), main)
        self.assertEqual(self.git("rev-parse", "experiments").stdout.strip(), main)                  # recreated from main
        self.assertEqual(self.origin_git("rev-parse", "experiments").stdout.strip(), main)
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip(), "experiments")
        merge = state["pr_merges"][0]
        self.assertIn("--squash", merge)
        self.assertIn("OITUI 0.4.2 (#17)", merge)
        self.assertEqual(result.stdout.count("FAIL"), 0)

    def test_the_final_release_uses_the_tested_bytes_and_notes(self):
        self.release(stdin="y\n0.4.2\n")
        created = [c for c in self.state()["created"] if c["tag"] == "v0.4.2"][0]
        self.assertNotIn("--prerelease", created["args"])
        self.assertIn("--verify-tag", created["args"])
        self.assertIn("Tellus 0.1.2: signed releases.", created["args"])
        final = Path(self.state()["releases"]["v0.4.2"])
        self.assertEqual((final / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb").read_bytes(), b"TELLUS 012")

    def test_remote_branch_that_survives_the_merge_is_deleted_and_recreated(self):
        state = self.state()
        state["auto_delete"] = False
        self.write_state(state)
        result = self.release(stdin="y\n0.4.2\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        main = self.origin_git("rev-parse", "main").stdout.strip()
        self.assertEqual(self.origin_git("rev-parse", "experiments").stdout.strip(), main)

    # ---- nothing changes when it should not
    def test_dry_run_changes_nothing(self):
        result = self.release(extra=("--dry-run",), stdin="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[dry-run] nothing was changed", result.stdout)
        self.assert_untouched()
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip(), "experiments")

    def test_wrong_release_number_typed(self):
        result = self.release(stdin="y\n0.4.3\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the release number", result.stdout)
        self.assert_untouched()

    def test_declining_the_key_question(self):
        result = self.release(stdin="n\n")
        self.assertEqual(result.returncode, 1)
        self.assert_untouched()

    def test_notes_are_required(self):
        result = self.tool("release", "v0.4.2-rc.1", stdin="y\n0.4.2\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("--notes-file", result.stdout)
        self.assert_untouched()

    def test_a_product_change_after_the_test_is_refused(self):
        (self.repo / "OITI/control").write_text((self.repo / "OITI/control").read_text() + "# sneaked in\n")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "product change after the test")
        self.git("push", "-q", "origin", "experiments")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("product file changed since the test: OITI/control", result.stdout)
        self.assert_untouched()

    def test_an_unsigned_candidate_is_refused(self):
        os.remove(Path(self.state()["releases"]["v0.4.2-rc.1"]) / "SHA256SUMS.sig")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not signed, complete and consistent", result.stdout)
        self.assert_untouched()

    def test_a_candidate_with_other_versions_than_tested_is_refused(self):
        rc = Path(self.state()["releases"]["v0.4.2-rc.1"])
        (rc / "com.wilburt.tellus_0.1.2_iphoneos-arm64.deb").rename(rc / "com.wilburt.tellus_0.1.3_iphoneos-arm64.deb")
        sums = (rc / "SHA256SUMS").read_text().replace("tellus_0.1.2", "tellus_0.1.3")
        (rc / "SHA256SUMS").write_text(sums)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(self.keys["a"][0]), "-in", str(rc / "SHA256SUMS"),
                        "-out", str(rc / "SHA256SUMS.sig")], check=True)
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("the candidate has 0.1.3 but the tested commit says 0.1.2", result.stdout)
        self.assert_untouched()

    def test_a_tampered_candidate_is_refused(self):
        rc = Path(self.state()["releases"]["v0.4.2-rc.1"])
        (rc / "com.wilburt.oiti_0.4.1_iphoneos-arm64.deb").write_bytes(b"TAMPERED")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match its SHA256SUMS entry", result.stdout)
        self.assert_untouched()

    def test_red_ci_on_the_work_branch_is_refused(self):
        state = self.state()
        state["runs"]["build-oiti.yml"][0]["conclusion"] = "failure"
        self.write_state(state)
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("has not succeeded", result.stdout)
        self.assert_untouched()

    def test_no_ci_build_of_the_work_branch_is_refused(self):
        state = self.state()
        state["runs"]["build-oiti.yml"] = []
        self.write_state(state)
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no CI build", result.stdout)
        self.assert_untouched()

    def test_an_open_pull_request_is_refused(self):
        state = self.state()
        state["open_prs"] = [{"number": 5}]
        self.write_state(state)
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("already open", result.stdout)

    def test_unpushed_work_branch_is_refused(self):
        (self.repo / "README.md").write_text("local only\n")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "local only")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not what origin/experiments has", result.stdout)
        self.assert_untouched()

    def test_a_release_number_that_is_not_higher_is_refused(self):
        state = self.state()
        state["stable"] = "v0.4.2"
        self.write_state(state)
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not higher", result.stdout)

    def test_a_clone_that_does_not_fetch_all_branches_is_refused(self):
        self.git("config", "--unset-all", "remote.origin.fetch")
        self.git("config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("set-branches", result.stdout)

    def test_a_dirty_tree_is_refused(self):
        (self.repo / "README.md").write_text("uncommitted\n")
        result = self.release()
        self.assertEqual(result.returncode, 1)
        self.assertIn("uncommitted", result.stdout)
        self.assert_untouched()

    def test_a_malformed_candidate_tag_is_refused(self):
        result = self.tool("release", "v0.4.2", "--notes-file", str(self.notes))
        self.assertEqual(result.returncode, 1)
        self.assertIn("must look like", result.stdout)

    def test_a_merge_commit_that_differs_from_the_reviewed_tree_stops_before_tagging(self):
        tampering = dict(self.env, FAKE_GH_TAMPER="1")
        result = self.release(stdin="y\n0.4.2\n", env=tampering)
        self.assertEqual(result.returncode, 1)
        self.assertIn("merged tree differs", result.stdout)
        self.assertNotIn("v0.4.2", self.origin_git("tag", "-l").stdout.split())
        self.assertEqual(self.state()["stable"], "v0.4.1")
        self.assertIn("v0.4.2-rc.1", self.state()["releases"])

    # ---- an interrupted run can be repeated
    def test_resume_after_a_failed_release_creation(self):
        failing = dict(self.env, FAKE_GH_FAIL="release-create")
        first = self.release(stdin="y\n0.4.2\n", env=failing)
        self.assertEqual(first.returncode, 1)
        self.assertIn("v0.4.2", self.origin_git("tag", "-l").stdout.split())       # merged and tagged ...
        self.assertEqual(self.state()["stable"], "v0.4.1")                         # ... but not released
        self.assertIn("v0.4.2-rc.1", self.state()["releases"])                     # and the candidate is still there
        second = self.release(stdin="y\n")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("the tag exists, the release does not", second.stdout)
        self.assertEqual(self.state()["stable"], "v0.4.2")
        self.assertNotIn("v0.4.2-rc.1", self.state()["releases"])
        main = self.origin_git("rev-parse", "main").stdout.strip()
        self.assertEqual(self.git("rev-parse", "experiments").stdout.strip(), main)
        self.assertEqual(len(self.state()["pr_merges"]), 1)                        # it did not merge twice

    def test_resume_when_only_the_cleanup_is_left(self):
        failing = dict(self.env, FAKE_GH_FAIL="release-create")
        self.release(stdin="y\n0.4.2\n", env=failing)
        self.release(stdin="y\n")
        third = self.release(stdin="y\n")                                         # everything is done: it changes nothing more
        self.assertEqual(third.returncode, 0, third.stdout + third.stderr)
        self.assertIn("only the cleanup is left", third.stdout)

    def test_cleanup_refuses_to_delete_a_work_branch_with_extra_work(self):
        failing = dict(self.env, FAKE_GH_FAIL="release-create")
        self.release(stdin="y\n0.4.2\n", env=failing)
        self.git("switch", "-q", "experiments")
        (self.repo / "extra.md").write_text("unmerged work\n")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "extra work")
        extra = self.git("rev-parse", "HEAD").stdout.strip()
        second = self.release(stdin="y\n")
        self.assertEqual(second.returncode, 1, second.stdout)
        self.assertIn("NOT deleting it", second.stdout)
        self.assertEqual(self.state()["stable"], "v0.4.2")                         # the release itself was done
        self.assertEqual(self.git("rev-parse", "experiments").stdout.strip(), extra)  # and the extra work is untouched


if __name__ == "__main__":
    unittest.main(verbosity=2)
