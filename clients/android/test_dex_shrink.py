"""RFC-0020: the shrunk dex keeps every manifest component and JNI/reflection surface verbatim."""
import re
import struct
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).parent
A = "{http://schemas.android.com/apk/res/android}"


def class_definitions(data):
    """Read actual class_defs, not descriptor references. Not a full DEX verifier."""
    if len(data) < 112 or not re.fullmatch(rb'dex\n0[0-9]{2}\x00', data[:8]):
        raise ValueError('not a DEX header')
    def word(offset):
        if offset < 0 or offset + 4 > len(data):
            raise ValueError('DEX offset out of bounds')
        return struct.unpack_from('<I', data, offset)[0]
    def offsets(count, offset, width):
        if offset + count * width > len(data):
            raise ValueError('DEX table out of bounds')
        return range(offset, offset + count * width, width)
    strings = []
    for item in offsets(word(56), word(60), 4):
        offset = word(item)
        for _ in range(5):
            if offset >= len(data):
                raise ValueError('DEX string length out of bounds')
            byte = data[offset]
            offset += 1
            if not byte & 128:
                break
        else:
            raise ValueError('invalid DEX string length')
        strings.append(bytes(data[offset:data.index(0, offset)]))
    types = [strings[word(item)] for item in offsets(word(64), word(68), 4)]
    return {types[word(item)] for item in offsets(word(96), word(100), 32)}


class DexShrink(unittest.TestCase):
    def test_descriptor_strings_are_not_class_definitions(self):
        with self.assertRaises(ValueError):
            class_definitions(b'Lorg/webrtc/PeerConnectionFactory;')
        original = (ROOT / 'out/dex/classes.dex').read_bytes()
        trimmed = bytearray(original)
        count = struct.unpack_from('<I', trimmed, 96)[0]
        self.assertGreater(count, 0)
        struct.pack_into('<I', trimmed, 96, count - 1)
        self.assertEqual(len(class_definitions(original) - class_definitions(trimmed)), 1)

    def test_split_inputs_cannot_be_silently_dropped(self):
        build = (ROOT / 'build.sh').read_text()
        merge = build.index('"$TOOLS/d8" --release --lib "$PLATFORM" --min-api 26 --output out/dex out/dex-app/classes.dex')
        for path in ('out/dex-app/classes2.dex', 'out/dex-fcm/classes2.dex'):
            self.assertIn('test ! -e ' + path, build[:merge])

    def test_manifest_components_and_kept_packages_survive(self):
        dex = class_definitions((ROOT / "out/dex/classes.dex").read_bytes())
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
        # WebRTC/app/ZXing bypass R8 entirely: every class in the d8-only dex survives in the merged dex.
        app = class_definitions((ROOT / "out/dex-app/classes.dex").read_bytes())
        fcm = class_definitions((ROOT / "out/dex-fcm/classes.dex").read_bytes())
        self.assertEqual(dex, app | fcm, "all input class definitions must survive merge")
        self.assertIn(b"Lorg/webrtc/WebRtcClassLoader;", app)
        rules = (ROOT / "proguard.pro").read_text()
        for rule in ("-dontoptimize", "-dontobfuscate", "-keep class com.google.firebase.messaging.FirebaseMessaging { public *; }"):
            self.assertIn(rule, rules)
        build = (ROOT / "build.sh").read_text()
        self.assertIn("--classpath out/classes --classpath out/deps/webrtc-classes.jar", build, "R8 program input must be the Firebase closure only")
        self.assertNotIn("R8 --release --lib \"$PLATFORM\" --min-api 26 --output out/dex --pg-conf", build)


if __name__ == "__main__":
    unittest.main()
