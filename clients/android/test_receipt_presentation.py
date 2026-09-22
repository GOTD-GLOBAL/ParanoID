"""Real JVM receipt semantics; Canvas and preference lifecycle need Android runtime."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="paranoid-receipt-presentation-") as out:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-Xlint:-options", "-encoding", "UTF-8",
                    "-cp", cp, "-d", out,
                    str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/ReceiptPresentationSmoke.java")], check=True)
    subprocess.run(["java", "-cp", out + ":" + cp, "ReceiptPresentationSmoke"], check=True)
