"""Strict JVM TURN response contract; real issuer/media gates run separately."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-voice-relay-") as directory:
    subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-d", directory,
                    str(root / "src/org/paranoid/text/VoiceRelayConfig.java"),
                    str(root / "test/VoiceRelaySmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory, "VoiceRelaySmoke"], check=True)
