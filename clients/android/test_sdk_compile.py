"""Compile every application source against the real Android SDK, not host org.json.

Run dependencies.py, webrtc_dependency.py and firebase_dependency.py first.
This does not sign, install or launch an APK and needs no signing credentials.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
sdk = Path(os.environ["ANDROID_SDK_ROOT"])
platform = sdk / "platforms/android-35/android.jar"
deps = root / "out/deps"
with tempfile.TemporaryDirectory(prefix="paranoid-sdk-compile-") as scratch:
    temp = Path(scratch)
    generated = temp / "gen"
    classes = temp / "classes"
    generated.mkdir()
    classes.mkdir()
    resources = [root / "res", *sorted((deps / "fcm-res").iterdir())]
    command = [str(sdk / "build-tools/35.0.0/aapt"), "package", "-f", "-m",
               "--auto-add-overlay", "-M", str(root / "AndroidManifest.xml")]
    for resource in resources:
        command += ["-S", str(resource)]
    command += ["-I", str(platform), "-J", str(generated), "--extra-packages",
                ":".join((deps / "fcm-packages.txt").read_text().split())]
    subprocess.run(command, check=True)
    jars = [platform, deps / "zxing-core-3.5.3.jar", deps / "webrtc-classes.jar",
            *sorted((deps / "fcm-jars").glob("*.jar"))]
    subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-encoding", "UTF-8",
                    "-classpath", os.pathsep.join(map(str, jars)), "-d", str(classes),
                    *map(str, sorted((root / "src/org/paranoid/text").glob("*.java"))),
                    *map(str, sorted(generated.rglob("R.java")))], check=True)
    for name in ("MainActivity", "TextEngine", "VoiceCallService", "CallLog"):
        assert (classes / "org/paranoid/text" / (name + ".class")).is_file(), name
        print("SDK compilation PASS:", name + ".java")
