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
import datetime, json, os, shutil, subprocess, sys
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
    print(json.dumps({"assets": [{"name": n} for n in sorted(os.listdir(state["releases"][args[2]]))]}))
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
elif args[:2] == ["release", "create"]:
    tag = args[2]
    target = os.path.join(state["root"], "created-" + tag)
    os.makedirs(target)
    files = [a for a in args[3:] if os.path.isfile(a)]
    for f in files:
        shutil.copy(f, target)
    state["releases"][tag] = target
    state.setdefault("created", []).append({"tag": tag, "args": args[2:], "files": [os.path.basename(f) for f in files]})
    save()
else:
    sys.stderr.write("fake gh: unsupported " + repr(args) + "\n"); sys.exit(2)
'''


def sh(*command, cwd=None, check=True, env=None):
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=check, env=env)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
