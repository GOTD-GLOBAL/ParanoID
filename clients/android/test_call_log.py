"""Isolated real JVM test for the local-only call log vocabulary and ordering.

``CallLog`` itself needs ``android.content`` for its preference accessors, exactly as
``ContactNames`` does; everything a reader sees — the outcome of a terminal transition, its wording
and where the row stands in the conversation — is pure Java in ``MessagePresentation`` and is tested
here without an emulator.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-call-log-") as directory:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/CallLogSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory + ":" + cp, "CallLogSmoke"], check=True)
