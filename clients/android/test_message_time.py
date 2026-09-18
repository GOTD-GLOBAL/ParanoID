"""Isolated real JVM test for message time, day separators and row dates.

Pure Java in ``MessagePresentation``; no emulator and no Android SDK are needed. The clock itself
belongs to ``SelfServiceClient``, which stamps each operation with ``System.currentTimeMillis()``.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
# Source-level adapter/UI wiring, separate from the executed formatter below.
client = (root / "src/org/paranoid/text/SelfServiceClient.java").read_text()
stamps = [line for line in client.splitlines() if '.put("now_ms",' in line]
assert len(stamps) == 3, "send, sync and realtime receive must all stamp"
assert all('Math.max(0,System.currentTimeMillis())' in line for line in stamps), \
    "a pre-epoch Android clock must map to unknown, not break u64 request parsing"
ui = (root / "src/org/paranoid/text/MainActivity.java").read_text()
assert 'conversationRow(dialogList,dialog,preview,last,callPreview)' in ui
assert 'System.currentTimeMillis(),callPreview)' in ui
model = (root.parent / "ios/App/ParanoID/AppModel.swift").read_text()
assert 'isCallPreview: preview(for: dialog) != nil' in model
with tempfile.TemporaryDirectory(prefix="paranoid-message-time-") as directory:
    cp = str(root / "out/deps/json-20240303.jar")
    subprocess.run(["javac", "--release", "8", "-encoding", "UTF-8", "-cp", cp,
                    "-d", directory, str(root / "src/org/paranoid/text/MessagePresentation.java"),
                    str(root / "test/MessageTimeSmoke.java")], check=True)
    subprocess.run(["java", "-cp", directory + ":" + cp, "MessageTimeSmoke"], check=True)
