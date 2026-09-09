"""Exercise downloaded media-artifact integrity and repeatable extraction."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest


class WebRtcDependencyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).with_name("webrtc_dependency.py")
        spec = importlib.util.spec_from_file_location("webrtc_dependency", source)
        cls.dep = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.dep)
        cls.artifact = Path(os.environ.get("PARANOID_WEBRTC_TEST_AAR",
                                          str(source.parent / "out/deps" / cls.dep.ARTIFACT)))

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="paranoid-webrtc-dependency-")
        self.root = Path(self.scratch.name)
        shutil.copyfile(self.artifact, self.root / self.dep.ARTIFACT)

    def tearDown(self):
        self.scratch.cleanup()

    def test_real_archive_extracts_required_abis_and_exact_java(self):
        self.dep.prepare(self.root)
        self.assertTrue((self.root / "webrtc-classes.jar").is_file())
        for abi in ("arm64-v8a", "x86_64"):
            native = self.root / "webrtc" / abi / "libjingle_peerconnection_so.so"
            self.assertEqual(hashlib.sha256(native.read_bytes()).hexdigest(),
                             self.dep.NATIVE_SHA256[abi])
        self.assertFalse((self.root / "webrtc" / "x86").exists())

    def test_corrupted_cached_archive_fails_before_extract(self):
        archive = self.root / self.dep.ARTIFACT
        with archive.open("r+b") as out:
            out.seek(4096)
            value = out.read(1)
            out.seek(4096)
            out.write(bytes([value[0] ^ 1]))
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            self.dep.prepare(self.root)
        self.assertFalse((self.root / "webrtc-classes.jar").exists())

    def test_tampered_extraction_is_repaired_from_verified_archive(self):
        self.dep.prepare(self.root)
        jar = self.root / "webrtc-classes.jar"
        original = hashlib.sha256(jar.read_bytes()).hexdigest()
        jar.write_bytes(b"tampered cache")
        self.dep.prepare(self.root)
        self.assertEqual(hashlib.sha256(jar.read_bytes()).hexdigest(), original)


if __name__ == "__main__":
    unittest.main()
