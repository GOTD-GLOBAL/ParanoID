"""RFC-0020: the shrunk dex keeps every manifest component and JNI/reflection surface verbatim."""
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).parent
A = "{http://schemas.android.com/apk/res/android}"


class DexShrink(unittest.TestCase):
    def test_manifest_components_and_kept_packages_survive(self):
        dex = (ROOT / "out/dex/classes.dex").read_bytes()
        manifest = ET.parse(ROOT / "AndroidManifest.xml").getroot()
        for element in manifest.iter():
            name = element.get(A + "name")
            if element.tag in ("service", "receiver", "provider", "activity") and name:
                self.assertIn(("L" + name.replace(".", "/") + ";").encode(), dex, name)
            if element.tag == "meta-data" and name and name.startswith("com.google.firebase.components:"):
                registrar = name.split(":", 1)[1]
                self.assertIn(("L" + registrar.replace(".", "/") + ";").encode(), dex, registrar)
        for source in sorted((ROOT / "src/org/paranoid/text").glob("*.java")):
            self.assertIn(("Lorg/paranoid/text/" + source.stem + ";").encode(), dex, source.stem)
        for cls in (b"Lorg/webrtc/PeerConnectionFactory;", b"Lorg/webrtc/Camera2Enumerator;", b"Lcom/google/zxing/qrcode/QRCodeWriter;",
                    b"Lcom/google/firebase/messaging/FirebaseMessaging;", b"Lcom/google/android/datatransport/cct/CctBackendFactory;"):
            self.assertIn(cls, dex)
        self.assertFalse((ROOT / "out/dex/classes2.dex").exists(), "single dex")
        rules = (ROOT / "proguard.pro").read_text()
        for rule in ("-dontoptimize", "-dontobfuscate", "-keep class org.paranoid.text.** { *; }", "-keep class org.webrtc.** { *; }"):
            self.assertIn(rule, rules)


if __name__ == "__main__":
    unittest.main()
