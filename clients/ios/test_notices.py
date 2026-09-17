#!/usr/bin/env python3
"""Exercise the iOS notices packager: graph walk, license texts, pinned copies.

Two halves. The synthetic half drives notices.py with hand-built cargo
metadata and temporary crate directories, so the failure modes that must stay
failures — a linked crate with no license text, a pinned copy that went
missing, an empty WebRTC notice directory — are proven, not assumed. The real
half resolves the actual locked graph for aarch64-apple-ios (offline) and
checks the rendered file: every linked crate present, the three crates with no
packaged license served from pinned copies, the WebRTC block byte-for-byte,
and none of the Android-only components.

Neither half touches the network; a missing cargo is a failure, never a skip.
"""
import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANDROID_LICENSES = HERE.parent / "android" / "licenses"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def load_module():
    source = HERE / "notices.py"
    spec = importlib.util.spec_from_file_location("notices", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package(name="fake-crate", version="1.2.3", manifest_path="/nowhere/Cargo.toml",
            license="MIT", repository="https://example.invalid/fake", source=REGISTRY):
    return {"id": name + "@" + version, "name": name, "version": version, "source": source,
            "manifest_path": str(manifest_path), "license": license, "repository": repository}


def synthetic_metadata(linked=(), unlinked=()):
    """Metadata with a path root that depends on `linked`; `unlinked` resolves elsewhere."""
    root = package(name="paranoid-ios-bridge", version="0.0.1", source=None,
                   license=None, repository=None)
    root["id"] = "root"
    nodes = [{"id": "root", "deps": [{"pkg": entry["id"]} for entry in linked]}]
    nodes += [{"id": entry["id"], "deps": []} for entry in list(linked) + list(unlinked)]
    return {"packages": [root] + list(linked) + list(unlinked),
            "resolve": {"root": "root", "nodes": nodes}, "workspace_root": "/nowhere"}


class GraphTest(unittest.TestCase):
    """Only crates that actually link into the app carry a notice."""

    def setUp(self):
        self.notices = load_module()

    def test_unreachable_and_path_packages_are_left_out(self):
        linked = package(name="linked")
        unlinked = package(name="unlinked")
        packages = self.notices.linked_packages(synthetic_metadata([linked], [unlinked]))
        self.assertEqual([entry["name"] for entry in packages], ["linked"])

    def test_packages_are_sorted_by_name_then_version(self):
        entries = [package(name="b", version="1.0.0"), package(name="a", version="2.0.0"),
                   package(name="a", version="10.0.0")]
        packages = self.notices.linked_packages(synthetic_metadata(entries))
        self.assertEqual([(entry["name"], entry["version"]) for entry in packages],
                         [("a", "10.0.0"), ("a", "2.0.0"), ("b", "1.0.0")])

    def test_diamond_dependency_is_visited_once(self):
        shared = package(name="shared")
        left, right = package(name="left"), package(name="right")
        metadata = synthetic_metadata([left, right], [shared])
        for node in metadata["resolve"]["nodes"]:
            if node["id"] in (left["id"], right["id"]):
                node["deps"] = [{"pkg": shared["id"]}]
        packages = self.notices.linked_packages(metadata)
        self.assertEqual([entry["name"] for entry in packages], ["left", "right", "shared"])

    def test_metadata_without_a_resolve_root_is_a_build_error(self):
        metadata = synthetic_metadata([package()])
        metadata["resolve"]["root"] = None
        with self.assertRaisesRegex(RuntimeError, "no resolve root"):
            self.notices.linked_packages(metadata)


class LicenseTextTest(unittest.TestCase):
    """A crate without a license text is a build error, never a silent skip."""

    def setUp(self):
        self.notices = load_module()
        scratch = tempfile.TemporaryDirectory(prefix="paranoid-notices-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.crate = self.root / "crate"
        self.crate.mkdir()

    def crate_package(self, name="fake-crate", version="1.2.3"):
        return package(name=name, version=version, manifest_path=self.crate / "Cargo.toml")

    def test_packaged_texts_are_copied_verbatim_and_sorted(self):
        (self.crate / "LICENSE-MIT").write_text("mit text\n")
        (self.crate / "COPYRIGHT").write_text("copyright text\n")
        (self.crate / "README.md").write_text("not a license\n")
        nested = self.crate / "third_party"
        nested.mkdir()
        (nested / "NOTICE").write_text("nested notice\n")
        texts = self.notices.license_texts(self.crate_package())
        self.assertEqual([label for label, _ in texts],
                         ["COPYRIGHT", "LICENSE-MIT", "third_party/NOTICE"])
        self.assertEqual([text for _, text in texts],
                         ["copyright text\n", "mit text\n", "nested notice\n"])

    def test_licence_and_copying_spellings_count(self):
        (self.crate / "LICENCE.txt").write_text("british text\n")
        (self.crate / "COPYING").write_text("copying text\n")
        self.assertEqual([label for label, _ in self.notices.license_texts(self.crate_package())],
                         ["COPYING", "LICENCE.txt"])

    def test_missing_license_text_is_a_build_error(self):
        (self.crate / "Cargo.toml").write_text("[package]\n")
        with self.assertRaisesRegex(RuntimeError, r"Missing license text: fake-crate 1\.2\.3"):
            self.notices.license_texts(self.crate_package())

    def test_replacing_a_crate_directory_with_one_without_a_license_fails_the_build(self):
        (self.crate / "LICENSE-APACHE").write_text("apache text\n")
        entry = self.crate_package(name="vodozemac", version="0.10.0")
        self.assertEqual([label for label, _ in self.notices.license_texts(entry)],
                         ["LICENSE-APACHE"])
        (self.crate / "LICENSE-APACHE").unlink()
        with self.assertRaisesRegex(RuntimeError, r"Missing license text: vodozemac 0\.10\.0"):
            self.notices.license_texts(entry)

    def test_matrix_pickle_uses_the_pinned_spike_copy(self):
        pinned = self.notices.MATRIX_PICKLE_LICENSE
        self.assertTrue(pinned.is_file(), pinned)
        for name in ("matrix-pickle", "matrix-pickle-derive"):
            texts = self.notices.license_texts(self.crate_package(name=name, version="0.2.3"))
            self.assertEqual(texts, [("matrix-pickle-LICENSE", pinned.read_text())])

    def test_jni_sys_macros_uses_both_pinned_copies(self):
        texts = self.notices.license_texts(self.crate_package(name="jni-sys-macros", version="0.4.1"))
        self.assertEqual([label for label, _ in texts],
                         ["jni-sys-macros-LICENSE-APACHE", "jni-sys-macros-LICENSE-MIT"])
        for label, text in texts:
            self.assertEqual(text, (self.notices.LICENSES_DIR / label).read_text())

    def test_pinned_copies_are_the_android_files_byte_for_byte(self):
        for label in ("jni-sys-macros-LICENSE-APACHE", "jni-sys-macros-LICENSE-MIT"):
            self.assertEqual((self.notices.LICENSES_DIR / label).read_bytes(),
                             (ANDROID_LICENSES / label).read_bytes(), label)

    def test_a_missing_pinned_copy_is_a_build_error(self):
        self.notices.LICENSES_DIR = self.root / "empty-licenses"
        self.notices.LICENSES_DIR.mkdir()
        with self.assertRaisesRegex(RuntimeError, r"Missing license text: jni-sys-macros 0\.4\.1"):
            self.notices.license_texts(self.crate_package(name="jni-sys-macros", version="0.4.1"))

    def test_a_crate_the_project_does_not_pin_gets_no_fallback(self):
        self.assertEqual(self.notices.pinned_license_files("serde"), [])


class WebRtcNoticeTest(unittest.TestCase):
    """The pinned xcframework's notices travel with the crate notices."""

    def setUp(self):
        self.notices = load_module()
        self.dependency = self.notices.load_webrtc_dependency()

    def test_block_names_the_exact_pinned_artefact_and_slices(self):
        head = self.notices.webrtc_notice()[0]
        self.assertIn("WebRTC SDK for Apple " + self.dependency.VERSION, head)
        self.assertIn(self.dependency.ARTIFACT + "  " + self.dependency.ARCHIVE_SHA256, head)
        self.assertIn(self.notices.WEBRTC_SOURCE_COMMIT, head)
        for identifier, digest in self.dependency.SLICE_SHA256.items():
            self.assertIn("  " + identifier + "  " + digest, self.notices.webrtc_notice())

    def test_every_notice_file_is_included_verbatim(self):
        parts = self.notices.webrtc_notice()
        files = sorted(path for path in self.notices.WEBRTC_NOTICES.iterdir() if path.is_file())
        self.assertEqual(sorted(path.name for path in files),
                         ["AUTHORS", "LICENSE", "NOTICE", "PATENTS", "PROVENANCE.md",
                          "UPSTREAM-IOS-DEPENDENCY-NOTICES.txt"])
        for path in files:
            self.assertIn(path.name + "\n" + path.read_text(), parts)

    def test_an_empty_notice_directory_is_a_build_error(self):
        with tempfile.TemporaryDirectory(prefix="paranoid-notices-webrtc-") as scratch:
            self.notices.WEBRTC_NOTICES = Path(scratch)
            with self.assertRaisesRegex(RuntimeError, "Missing license text: WebRTC"):
                self.notices.webrtc_notice()

    def test_a_removed_notice_directory_is_a_build_error(self):
        self.notices.WEBRTC_NOTICES = self.notices.IOS_DIR / "licenses" / "webrtc-does-not-exist"
        with self.assertRaisesRegex(RuntimeError, "Missing license text: WebRTC"):
            self.notices.webrtc_notice()


class CargoInvocationTest(unittest.TestCase):
    """The graph is the locked one for the iOS device triple, and only that."""

    def setUp(self):
        self.notices = load_module()
        self.command = None

    def capture(self, command, text=None):
        self.command = command
        return "{}"

    def test_metadata_command_is_locked_and_filtered_for_the_device_triple(self):
        with mock.patch.object(self.notices.subprocess, "check_output", self.capture):
            self.notices.load_metadata()
        self.assertEqual(self.command[1:], [
            "metadata", "--locked", "--format-version", "1",
            "--filter-platform", "aarch64-apple-ios",
            "--manifest-path", str(self.notices.DEFAULT_MANIFEST)])
        self.assertNotIn("--offline", self.command)

    def test_offline_mode_forbids_the_network(self):
        with mock.patch.object(self.notices.subprocess, "check_output", self.capture):
            self.notices.load_metadata(offline=True)
        self.assertEqual(self.command[1:3], ["metadata", "--offline"])

    def test_cargo_failure_is_a_build_error(self):
        def fail(command, text=None):
            raise subprocess.CalledProcessError(101, command)
        with mock.patch.object(self.notices.subprocess, "check_output", fail):
            with self.assertRaisesRegex(RuntimeError, "cargo metadata failed"):
                self.notices.load_metadata(offline=True)

    def test_cargo_is_resolved_even_without_the_rustup_directory_on_path(self):
        with mock.patch.object(self.notices.shutil, "which", lambda _: None):
            resolved = self.notices.cargo()
        self.assertTrue(resolved == "cargo" or resolved.endswith("/.cargo/bin/cargo"), resolved)


class RealGraphTest(unittest.TestCase):
    """The actual locked iOS graph, rendered offline."""

    text = None
    packages = None

    @classmethod
    def setUpClass(cls):
        cls.notices = load_module()
        if shutil.which(cls.notices.cargo()) is None and not Path(cls.notices.cargo()).is_file():
            raise RuntimeError("cargo not found: run through clients/ios/toolchain.sh")
        metadata = cls.notices.load_metadata(offline=True)
        cls.packages = cls.notices.linked_packages(metadata)
        cls.text = cls.notices.render(metadata)

    def test_header_and_crate_count(self):
        self.assertEqual(self.text.splitlines()[0], self.notices.HEADER)
        self.assertGreaterEqual(len(self.packages), 80)

    def test_every_linked_crate_has_a_header_line_and_a_license_text(self):
        for entry in self.packages:
            header = "\n{0} {1} — {2}\n{3}\n".format(entry["name"], entry["version"],
                                                     entry["license"], entry["repository"])
            self.assertIn(header, self.text, entry["name"])
            self.assertTrue(self.notices.license_texts(entry), entry["name"])

    def test_the_core_crates_are_in_the_graph(self):
        names = {entry["name"] + " " + entry["version"] for entry in self.packages}
        for expected in ("vodozemac 0.10.0", "jni 0.21.1", "curve25519-dalek 4.1.3",
                         "prost 0.14.4", "serde_json 1.0.151"):
            self.assertIn(expected, names)

    def test_the_grep_check_of_the_plan_finds_at_least_three_lines(self):
        matched = [line for line in self.text.splitlines()
                   if "vodozemac" in line or "WebRTC" in line or "jni 0.21.1" in line]
        self.assertGreaterEqual(len(matched), 3)

    def test_crates_without_packaged_texts_are_served_from_pinned_copies(self):
        packaged = set()
        for entry in self.packages:
            root = Path(entry["manifest_path"]).parent
            if not any(path.is_file() and path.name.lower().startswith(self.notices.LICENSE_PREFIXES)
                       for path in root.rglob("*")):
                packaged.add(entry["name"])
        self.assertEqual(packaged, {"matrix-pickle", "matrix-pickle-derive", "jni-sys-macros"})
        self.assertIn("matrix-pickle-LICENSE\n" + self.notices.MATRIX_PICKLE_LICENSE.read_text(),
                      self.text)
        for label in ("jni-sys-macros-LICENSE-APACHE", "jni-sys-macros-LICENSE-MIT"):
            self.assertIn(label + "\n" + (self.notices.LICENSES_DIR / label).read_text(), self.text)

    def test_substituting_a_real_crate_directory_without_a_license_fails_the_render(self):
        metadata = self.notices.load_metadata(offline=True)
        with tempfile.TemporaryDirectory(prefix="paranoid-notices-substituted-") as scratch:
            empty = Path(scratch) / "crate"
            empty.mkdir()
            for entry in metadata["packages"]:
                if entry["name"] == "vodozemac":
                    entry["manifest_path"] = str(empty / "Cargo.toml")
            with self.assertRaisesRegex(RuntimeError, r"Missing license text: vodozemac 0\.10\.0"):
                self.notices.render(metadata)

    def test_webrtc_notices_are_appended_after_the_crates(self):
        block = self.text.index("\nWebRTC SDK for Apple ")
        self.assertGreater(block, self.text.index("\nvodozemac 0.10.0 "))
        for path in sorted(self.notices.WEBRTC_NOTICES.iterdir()):
            if path.is_file():
                self.assertIn(path.name + "\n" + path.read_text(), self.text[block:])

    def test_android_only_components_are_absent(self):
        for absent in ("ZXing", "org.json", "XcodeGen", "Firebase Cloud Messaging",
                       "WebRTC SDK Android"):
            self.assertNotIn(absent, self.text, absent)

    def test_writing_twice_produces_the_same_bytes(self):
        with tempfile.TemporaryDirectory(prefix="paranoid-notices-cli-") as scratch:
            output = Path(scratch) / "nested" / "THIRD_PARTY_NOTICES.txt"
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                self.notices.main(["--offline", "--output", str(output)])
            first = output.read_bytes()
            self.assertEqual(first, self.text.encode())
            self.assertIn(str(len(self.packages)) + " crates", printed.getvalue())
            with contextlib.redirect_stdout(printed):
                self.notices.main(["--offline", "--output", str(output)])
            self.assertEqual(output.read_bytes(), first)


if __name__ == "__main__":
    program = unittest.main(argv=sys.argv, exit=False)
    if not program.result.wasSuccessful():
        sys.exit(1)
    print("PASS: " + str(program.result.testsRun) + " tests")
