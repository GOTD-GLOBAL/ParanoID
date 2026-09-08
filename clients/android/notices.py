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
Path("out/THIRD_PARTY_NOTICES.txt").write_text("\n".join(parts))
