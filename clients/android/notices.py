"""Bundle locked client crate license texts; no legal/security approval implied."""
import json
from pathlib import Path
import subprocess
metadata=json.loads(subprocess.check_output(["cargo","metadata","--offline","--locked","--format-version","1","--filter-platform","aarch64-linux-android","--manifest-path","../core/Cargo.toml"],text=True))
nodes={n["id"]:n for n in metadata["resolve"]["nodes"]}
active=set();pending=[metadata["resolve"]["root"]]
while pending:
    current=pending.pop()
    if current in active:continue
    active.add(current);pending.extend(d["pkg"] for d in nodes[current]["deps"])
parts=["Third-party notices for the ParanoID development text client"]
for package in sorted(metadata["packages"],key=lambda p:(p["name"],p["version"])):
    if package["source"] is None or package["id"] not in active:continue
    root=Path(package["manifest_path"]).parent
    files=sorted(p for p in root.rglob("*") if p.is_file() and p.name.lower().startswith(("license","licence","copying","notice","copyright")))
    if not files and package["name"] in ("matrix-pickle","matrix-pickle-derive"):
        root=Path("../../spikes/002-android-bootstrap/licenses")
        files=[root/"matrix-pickle-LICENSE"]
    if not files and package["name"]=="jni-sys-macros":
        root=Path("licenses");files=sorted(root.glob("jni-sys-macros-LICENSE-*"))
    if not files:raise RuntimeError("Missing license text: "+package["name"])
    parts.append(f"\n{package['name']} {package['version']} — {package['license']}\n{package['repository']}")
    for path in files:parts.append(str(path.relative_to(root))+"\n"+path.read_text(errors="replace"))
parts.append("\nZXing core 3.5.3 — Apache-2.0\nhttps://github.com/zxing/zxing/tree/zxing-3.5.3\n"+Path("licenses/zxing-LICENSE").read_text())
parts.append("\nWebRTC SDK Android150.7871.01 — WebRTC BSD-3-Clause; upstream patch and dependency notices below\nhttps://github.com/webrtc-sdk/android/tree/v150.7871.01\nhttps://github.com/webrtc-sdk/webrtc/tree/73cb8180f7258ee292878d6edd05177f41883962")
for path in sorted(Path("licenses/webrtc-150.7871.01").glob("*")):
    if path.is_file():parts.append(path.name+"\n"+path.read_text())
fcm=__import__("importlib.util").util.spec_from_file_location("firebase_dependency","firebase_dependency.py");fcm_module=__import__("importlib.util").util.module_from_spec(fcm);fcm.loader.exec_module(fcm_module)
parts.append("\nFirebase Cloud Messaging closure (RFC-0020) — Apache-2.0 (Google Firebase/Play services/androidx/datatransport, JetBrains Kotlin, javax.inject, Guava listenablefuture, Error Prone annotations)\nhttps://firebase.google.com/support/release-notes/android\nExact artifacts (SHA256-pinned in firebase_dependency.py):")
for name,source,path,digest,size in fcm_module.ARTIFACTS:parts.append(f"  {name}  {digest}")
parts.append(Path("licenses/apache-2.0-LICENSE").read_text())
Path("out/THIRD_PARTY_NOTICES.txt").write_text("\n".join(parts))
