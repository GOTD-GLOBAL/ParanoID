"""RFC-0020: Firebase Messaging closure integrity — pinned table shape, tamper detection, no native payload."""
import hashlib
import importlib.util
import io
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile


def load():
    source = Path(__file__).with_name("firebase_dependency.py")
    spec = importlib.util.spec_from_file_location("firebase_dependency", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FirebaseDependencyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dep = load()
        cls.archives = Path(__file__).parent / "out/deps/fcm-archives"

    def test_pinned_table_is_complete_and_bounded(self):
        names = [row[0] for row in self.dep.ARTIFACTS]
        self.assertEqual(len(names), len(set(names)), "duplicate artifact")
        self.assertIn("firebase-messaging-24.1.2.aar", names)
        self.assertIn("play-services-basement-18.3.0.aar", names)
        for name, source, path, digest, size in self.dep.ARTIFACTS:
            self.assertIn(source, self.dep.SOURCES)
            self.assertTrue(path.endswith("/" + name), name)
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            self.assertTrue(0 < size <= self.dep.MAX_BYTES, name)
            self.assertNotIn("..", path.split("/"))
        # Every artifact is either an AAR (classes + manifest) or a plain JAR; nothing else is accepted.
        self.assertTrue(all(n.endswith((".aar", ".jar")) for n in names))

    def test_error_prone_uses_maven_central(self):
        # Google's Android repository returns 404 for this Maven Central artifact.
        artifact = next(row for row in self.dep.ARTIFACTS
                        if row[0] == "error_prone_annotations-2.26.0.jar")
        self.assertEqual(artifact[1], "central")

    def test_listenablefuture_uses_maven_central(self):
        artifact = next(row for row in self.dep.ARTIFACTS
                        if row[0] == "listenablefuture-1.0.jar")
        self.assertEqual(artifact[1], "central")

    def test_real_archives_extract_repeatably_and_tamper_is_refused(self):
        if not self.archives.is_dir() or not any(self.archives.glob("*.aar")):
            self.skipTest("Firebase archives not downloaded yet")
        with tempfile.TemporaryDirectory(prefix="paranoid-fcm-dependency-") as scratch:
            root = Path(scratch)
            (root / "fcm-archives").mkdir()
            for archive in self.archives.iterdir():
                shutil.copyfile(archive, root / "fcm-archives" / archive.name)
            self.dep.prepare(root)
            jars = sorted(p.name for p in (root / "fcm-jars").glob("*.jar"))
            self.assertEqual(len(jars), len(self.dep.ARTIFACTS))
            packages = (root / "fcm-packages.txt").read_text().split()
            self.assertIn("com.google.firebase.messaging", packages)
            self.assertIn("com.google.android.gms.common", packages)
            for package in packages:
                self.assertTrue(any((root / "fcm-res").glob("*/values/*")), package)
            # A stale extracted jar is replaced, never trusted.
            (root / "fcm-jars/firebase-messaging-24.1.2.jar").write_bytes(b"stale")
            self.dep.prepare(root)
            self.assertNotEqual((root / "fcm-jars/firebase-messaging-24.1.2.jar").read_bytes(), b"stale")
            # Tampered archive with the right size is refused before any extraction.
            target = root / "fcm-archives/firebase-messaging-24.1.2.aar"
            data = bytearray(target.read_bytes()); data[-1] ^= 1; target.write_bytes(bytes(data))
            with self.assertRaises(RuntimeError):
                self.dep.prepare(root)

    def test_native_payload_is_refused(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as aar:
            aar.writestr("classes.jar", b"x"); aar.writestr("AndroidManifest.xml", '<manifest package="a.b"/>')
            aar.writestr("jni/arm64-v8a/libx.so", b"\x7fELF")
        data = buffer.getvalue()
        dep = load()
        dep.ARTIFACTS = (("evil-1.aar", "google", "a/b/evil/1/evil-1.aar", hashlib.sha256(data).hexdigest(), len(data)),)
        with tempfile.TemporaryDirectory(prefix="paranoid-fcm-native-") as scratch:
            root = Path(scratch); (root / "fcm-archives").mkdir(); (root / "fcm-archives/evil-1.aar").write_bytes(data)
            with self.assertRaises(RuntimeError):
                dep.prepare(root)


if __name__ == "__main__":
    unittest.main()
