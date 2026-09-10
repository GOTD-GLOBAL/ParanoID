"""Real JVM voice lifecycle/consent tests; audio transport is tested separately."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-call-state-") as directory:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/CallController.java"),
                    str(root / "test/CallControllerSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory + ":" + cp, "CallControllerSmoke"], check=True)
