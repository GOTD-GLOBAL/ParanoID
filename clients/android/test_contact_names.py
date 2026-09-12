"""Isolated real JVM test for the local-only contact display name normalizer (v18)."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-contact-names-") as directory:
    # ContactNames depends on android.content.* only for the preference accessors; the normalizer is pure Java.
    import os
    cp = str(pathlib.Path(os.environ["ANDROID_SDK_ROOT"]) / "platforms/android-35/android.jar") + ":" + str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/ContactNames.java"),
                    str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/ContactNamesSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory, "ContactNamesSmoke"], check=True)
