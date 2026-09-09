"""Isolated real JVM tests for the native messaging presentation model."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-ui-jvm-") as directory:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/MessagePresentationSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory + ":" + cp, "MessagePresentationSmoke"], check=True)
