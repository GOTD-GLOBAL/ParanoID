"""Isolated real JVM test for message time, day separators and row dates.

Pure Java in ``MessagePresentation``; no emulator and no Android SDK are needed. The clock itself
belongs to ``SelfServiceClient``, which stamps each operation with ``System.currentTimeMillis()``.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-message-time-") as directory:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/MessageTimeSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory + ":" + cp, "MessageTimeSmoke"], check=True)
