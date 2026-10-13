#!/usr/bin/env python3
"""Unit tests of the Mac runner's guards, not a native iOS build result."""
from contextlib import contextmanager
import os
import platform
import shutil
import tempfile
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run-candidate-mac.sh"


@contextmanager
def mac_fixture():
    """A fake build subprocess proves runner guards only, never Xcode behavior."""
    with tempfile.TemporaryDirectory(prefix="ios-candidate-runner-") as temporary:
        root = Path(temporary)
        ios = root / "clients" / "ios"
        ios.mkdir(parents=True)
        runner = ios / RUNNER.name
        shutil.copyfile(RUNNER, runner)
        (ios / "build.sh").write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            'if [[ -n "${PARANOID_IOS_TEAM_ID:-}" || -n "${PARANOID_ASC_KEY_ID:-}" '
            '|| -n "${PARANOID_ASC_ISSUER_ID:-}" || -n "${PARANOID_ASC_KEY_PATH:-}" ]]; '
            'then exit 91; fi\n'
            'printf "BUILD_SUBPROCESS_CALLED\\n"\nexit "${FAKE_BUILD_EXIT:-0}"\n'
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "clients"], check=True)
        subprocess.run(["git", "-C", str(root), "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgsign=false", "-c", "user.name=Runner test",
                        "-c", "user.email=runner-test@invalid", "commit", "-qm", "fixture"], check=True)
        sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        mockbin = root / "mockbin"
        mockbin.mkdir()
        (mockbin / "uname").write_text('#!/bin/sh\nprintf "Darwin\\n"\n')
        (mockbin / "uname").chmod(0o700)
        # Tool doubles are outside the source set and ignored, like build outputs.
        subprocess.run(["git", "-C", str(root), "config", "core.excludesfile", str(root / "ignores")], check=True)
        (root / "ignores").write_text("mockbin/\nignores\n")
        env = dict(os.environ, PATH=str(mockbin) + os.pathsep + os.environ["PATH"])
        env["PARANOID_IOS_SIMULATOR"] = "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001"
        yield root, runner, sha, env


class CandidateMacRunnerTests(unittest.TestCase):
    def test_requires_exact_full_commit_argument_before_build(self):
        result = subprocess.run(["bash", str(RUNNER), "main"], text=True,
                                capture_output=True, env=dict(os.environ))
        self.assertEqual(result.returncode, 64)
        self.assertIn("expected full lowercase commit SHA", result.stderr)

    @unittest.skipIf(platform.system() == "Darwin", "non-Mac guard uses the real host")
    def test_non_mac_host_refuses_without_claiming_build(self):
        result = subprocess.run(["bash", str(RUNNER), "0" * 40], text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 69)
        self.assertIn("macOS with Xcode required; no build performed", result.stderr)

    def test_wrong_source_commit_refuses_on_mac(self):
        with mac_fixture() as (_, runner, _, env):
            result = subprocess.run(["bash", str(runner), "0" * 40], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 65)
            self.assertIn("source commit mismatch", result.stderr)
            self.assertNotIn("BUILD_SUBPROCESS_CALLED", result.stdout)

    def test_dirty_source_refuses_without_cleanup(self):
        with mac_fixture() as (root, runner, sha, env):
            target = root / "clients" / "ios" / "build.sh"
            before = target.read_text() + "# retained local edit\n"
            target.write_text(before)
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 66)
            self.assertIn("source worktree is not clean", result.stderr)
            self.assertEqual(target.read_text(), before)
            self.assertNotIn("BUILD_SUBPROCESS_CALLED", result.stdout)

    def test_explicit_isolated_simulator_destination_required(self):
        with mac_fixture() as (_, runner, sha, env):
            env.pop("PARANOID_IOS_SIMULATOR", None)
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 64)
            self.assertIn("explicit simulator UUID required", result.stderr)

    def test_calls_real_build_entrypoint_without_archive_credentials(self):
        with mac_fixture() as (_, runner, sha, env):
            for key in ("PARANOID_IOS_TEAM_ID", "PARANOID_ASC_KEY_ID",
                        "PARANOID_ASC_ISSUER_ID", "PARANOID_ASC_KEY_PATH"):
                env[key] = "unit-test-only"
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("BUILD_SUBPROCESS_CALLED", result.stdout)
            self.assertNotIn("unit-test-only", result.stdout + result.stderr)

    def test_build_failure_is_not_reported_as_success(self):
        with mac_fixture() as (_, runner, sha, env):
            env["FAKE_BUILD_EXIT"] = "23"
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 23)
            self.assertIn("BUILD_SUBPROCESS_CALLED", result.stdout)

    def test_untracked_source_is_preserved_and_refused(self):
        with mac_fixture() as (root, runner, sha, env):
            retained = root / "local-note.txt"
            retained.write_text("keep this fixture")
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 66)
            self.assertEqual(retained.read_text(), "keep this fixture")
            self.assertNotIn("BUILD_SUBPROCESS_CALLED", result.stdout)

    def test_git_status_error_refuses_dirty_build_and_preserves_index(self):
        with mac_fixture() as (root, runner, sha, env):
            build = root / "clients/ios/build.sh"
            retained = build.read_bytes() + b"# uncommitted fixture edit\n"
            build.write_bytes(retained)
            index = root / ".git/index"
            index.write_bytes(b"broken-index-fixture")
            result = subprocess.run(["bash", str(runner), sha], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 67)
            self.assertIn("cannot verify source worktree", result.stderr)
            self.assertNotIn("BUILD_SUBPROCESS_CALLED", result.stdout)
            self.assertNotIn("Exact source checked", result.stdout)
            self.assertEqual(build.read_bytes(), retained)
            self.assertEqual(index.read_bytes(), b"broken-index-fixture")


if __name__ == "__main__":
    unittest.main()
