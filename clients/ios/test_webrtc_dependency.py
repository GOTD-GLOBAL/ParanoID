#!/usr/bin/env python3
"""Exercise pinned WebRTC xcframework integrity and repeatable extraction.

Default: the real archive cached by webrtc_dependency.py (out/deps, or
PARANOID_WEBRTC_TEST_ARCHIVE). --offline: a synthetic archive with the same
layout, pinned by patching the module constants, for CI without the 69 MB
download. Both modes forbid network use; a missing real archive is a failure,
never a vacuous pass.
"""
import hashlib
import importlib.util
import io
import os
import plistlib
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
LICENSE_TEXT = (HERE / "licenses" / "webrtc-150.7871.01" / "LICENSE").read_bytes()
OFFLINE = "--offline" in sys.argv[1:]
PINNED_SLICES = ("ios-arm64", "ios-arm64_x86_64-simulator")


def load_module():
    source = HERE / "webrtc_dependency.py"
    spec = importlib.util.spec_from_file_location("webrtc_dependency", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def no_network(*args, **kwargs):
    raise AssertionError("the dependency test must never download")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def synthetic_archive(slices=PINNED_SLICES, extra_slices=("tvos-arm64", "macos-arm64_x86_64"),
                      extra_members=()):
    """Zip with the real xcframework layout: pinned iOS slices plus unrelated ones."""
    root = "WebRTC.xcframework"
    libraries = []
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(root + "/LICENSE", LICENSE_TEXT)
        for identifier in list(slices) + list(extra_slices):
            libraries.append({"BinaryPath": "WebRTC.framework/WebRTC",
                              "LibraryIdentifier": identifier,
                              "LibraryPath": "WebRTC.framework",
                              "SupportedArchitectures": ["arm64"],
                              "SupportedPlatform": identifier.split("-")[0]})
            base = root + "/" + identifier + "/WebRTC.framework/"
            archive.writestr(base + "Info.plist", plistlib.dumps(
                {"CFBundleIdentifier": "org.webrtc.WebRTC", "CFBundleExecutable": "WebRTC"}))
            archive.writestr(base + "Headers/WebRTC.h", "#import <Foundation/Foundation.h>\n")
            archive.writestr(base + "Modules/module.modulemap",
                             'framework module WebRTC { umbrella header "WebRTC.h" }\n')
            binary = zipfile.ZipInfo(base + "WebRTC")
            binary.external_attr = (stat.S_IFREG | 0o755) << 16
            binary.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(binary, (identifier.encode() + b"\0") * 4096)
            if identifier.startswith("macos"):
                # The real archive ships symlinks only in the macOS/Catalyst slices.
                link = zipfile.ZipInfo(base + "Versions/Current")
                link.external_attr = (stat.S_IFLNK | 0o755) << 16
                archive.writestr(link, "A")
        for info, payload in extra_members:
            archive.writestr(info, payload)
        archive.writestr(root + "/Info.plist", plistlib.dumps(
            {"AvailableLibraries": libraries, "CFBundlePackageType": "XFWK",
             "XCFrameworkFormatVersion": "1.0"}))
    return buffer.getvalue()


class WebRtcDependencyTest(unittest.TestCase):
    real_archive = None
    mode = "offline synthetic archive"

    @classmethod
    def setUpClass(cls):
        if OFFLINE:
            return
        default = HERE / "out" / "deps" / "WebRTC.xcframework.zip"
        archive = Path(os.environ.get("PARANOID_WEBRTC_TEST_ARCHIVE", str(default)))
        if not archive.is_file():
            raise RuntimeError("missing " + str(archive)
                               + ": run python3 clients/ios/webrtc_dependency.py first, or pass --offline")
        cls.real_archive = archive
        cls.mode = "real archive " + str(archive)

    def setUp(self):
        self.dep = load_module()
        patcher = mock.patch.object(self.dep.urllib.request, "urlopen", no_network)
        patcher.start()
        self.addCleanup(patcher.stop)
        scratch = tempfile.TemporaryDirectory(prefix="paranoid-webrtc-dependency-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.deps = self.root / "deps"
        self.deps.mkdir()
        self.output = self.root / "Binaries" / "WebRTC.xcframework"
        self.archive = self.deps / self.dep.ARTIFACT
        if OFFLINE:
            self.pin(synthetic_archive())
        else:
            shutil.copyfile(self.real_archive, self.archive)

    def pin(self, data):
        """Write a synthetic archive and re-pin the module constants to it."""
        self.archive.write_bytes(data)
        self.dep.SIZE = len(data)
        self.dep.ARCHIVE_SHA256 = hashlib.sha256(data).hexdigest()
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = set(archive.namelist())
            for identifier in list(self.dep.SLICE_SHA256):
                member = "WebRTC.xcframework/" + identifier + "/WebRTC.framework/WebRTC"
                if member in names:
                    self.dep.SLICE_SHA256[identifier] = hashlib.sha256(archive.read(member)).hexdigest()

    def prepare(self, **kwargs):
        return self.dep.prepare(self.deps, self.output, **kwargs)

    def test_pinned_constants_are_the_release_literals(self):
        dep = load_module()
        self.assertEqual(dep.VERSION, "150.7871.01")
        self.assertEqual(dep.ARTIFACT, "WebRTC.xcframework.zip")
        self.assertEqual(dep.URL, "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/"
                                  "WebRTC.xcframework.zip")
        self.assertEqual(dep.SIZE, 69079305)
        self.assertEqual(sorted(dep.SLICE_SHA256), sorted(PINNED_SLICES))
        for digest in [dep.ARCHIVE_SHA256] + list(dep.SLICE_SHA256.values()):
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_archive_extracts_only_pinned_ios_slices(self):
        slices = self.prepare()
        self.assertEqual(sorted(slices), sorted(self.dep.SLICE_SHA256))
        plist = plistlib.loads((self.output / "Info.plist").read_bytes())
        self.assertEqual([lib["LibraryIdentifier"] for lib in plist["AvailableLibraries"]], slices)
        self.assertEqual(plist["CFBundlePackageType"], "XFWK")
        for identifier, expected in self.dep.SLICE_SHA256.items():
            framework = self.output / identifier / "WebRTC.framework"
            self.assertEqual(sha256(framework / "WebRTC"), expected)
            self.assertTrue(os.access(framework / "WebRTC", os.X_OK))
            self.assertTrue((framework / "Modules" / "module.modulemap").is_file())
            self.assertTrue((framework / "Headers").is_dir())
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         sorted(list(self.dep.SLICE_SHA256) + ["Info.plist", "LICENSE"]))
        self.assertEqual((self.output / "LICENSE").read_bytes(), LICENSE_TEXT)
        self.assertFalse(any(path.is_symlink() for path in self.output.rglob("*")))
        self.assertFalse((self.output.parent / "WebRTC.xcframework.staging").exists())

    def test_corrupted_cached_archive_fails_before_extract(self):
        with self.archive.open("r+b") as out:
            out.seek(4096)
            value = out.read(1)
            out.seek(4096)
            out.write(bytes([value[0] ^ 1]))
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_wrong_length_cached_archive_fails_before_extract(self):
        with self.archive.open("ab") as out:
            out.write(b"\0")
        with self.assertRaisesRegex(RuntimeError, "wrong length"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_changed_archive_pin_rejects_archive_before_extract(self):
        self.dep.ARCHIVE_SHA256 = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_changed_slice_pin_rejects_before_writing(self):
        self.output.mkdir(parents=True)
        marker = self.output / "marker"
        marker.write_bytes(b"previous extraction")
        self.dep.SLICE_SHA256["ios-arm64"] = "f" * 64
        with self.assertRaisesRegex(RuntimeError, "slice integrity: ios-arm64"):
            self.prepare()
        self.assertEqual(marker.read_bytes(), b"previous extraction")
        self.assertFalse((self.output / "Info.plist").exists())
        self.assertFalse((self.output.parent / "WebRTC.xcframework.staging").exists())

    def test_tampered_extraction_is_repaired_from_verified_archive(self):
        self.prepare()
        binary = self.output / "ios-arm64" / "WebRTC.framework" / "WebRTC"
        binary.write_bytes(b"tampered cache")
        (self.output / "Info.plist").write_bytes(b"tampered plist")
        stray = self.output / "tvos-arm64" / "WebRTC.framework" / "WebRTC"
        stray.parent.mkdir(parents=True)
        stray.write_bytes(b"stray slice")
        self.prepare()
        self.assertEqual(sha256(binary), self.dep.SLICE_SHA256["ios-arm64"])
        self.assertFalse((self.output / "tvos-arm64").exists())
        plist = plistlib.loads((self.output / "Info.plist").read_bytes())
        self.assertEqual(sorted(lib["LibraryIdentifier"] for lib in plist["AvailableLibraries"]),
                         sorted(self.dep.SLICE_SHA256))

    def test_archive_without_pinned_slice_is_rejected(self):
        self.pin(synthetic_archive(slices=("ios-arm64_x86_64-simulator",)))
        with self.assertRaisesRegex(RuntimeError, "missing from archive: ios-arm64"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_unsafe_member_path_is_rejected(self):
        escape = zipfile.ZipInfo("WebRTC.xcframework/ios-arm64/../../escape")
        self.pin(synthetic_archive(extra_members=[(escape, b"escape")]))
        with self.assertRaisesRegex(RuntimeError, "unsafe member"):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "escape").exists())

    def test_symlink_inside_pinned_slice_is_rejected(self):
        link = zipfile.ZipInfo("WebRTC.xcframework/ios-arm64/WebRTC.framework/Headers/link.h")
        link.external_attr = (stat.S_IFLNK | 0o755) << 16
        self.pin(synthetic_archive(extra_members=[(link, b"/etc/passwd")]))
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_offline_never_downloads_a_missing_archive(self):
        self.archive.unlink()
        with self.assertRaisesRegex(RuntimeError, "offline"):
            self.prepare(offline=True)
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    program = unittest.main(argv=[arg for arg in sys.argv if arg != "--offline"], exit=False)
    if not program.result.wasSuccessful():
        sys.exit(1)
    print("PASS: " + str(program.result.testsRun) + " tests (" + WebRtcDependencyTest.mode + ")")
