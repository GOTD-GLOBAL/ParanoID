#!/usr/bin/env python3
"""Build the native bundle with locked Rust dependencies; no deployment."""
import hashlib
import json
import platform
import shutil
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    subprocess.run(['cargo', 'build', '--release', '--locked', '--manifest-path',
                    ROOT / 'server/Cargo.toml'], check=True)
    dest = ROOT / 'dist/release'
    dest.mkdir(parents=True, exist_ok=True)
    files = {'paranoid-server': ROOT / 'server/target/release/paranoid-server',
             'schema.sql': ROOT / 'server/schema.sql', 'alpha.py': ROOT / 'deploy/alpha.py',
             'create-test-tls.py': ROOT / 'scripts/create-test-tls.py',
             'README.md': ROOT / 'deploy/README.md'}
    for name, source in files.items():
        shutil.copy2(source, dest / name)
    hashes = {name: hashlib.sha256((dest / name).read_bytes()).hexdigest() for name in files}
    release = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:20]
    manifest = {'release': release, 'sha256': hashes, 'schema_contract': 'paranoid-dev-v0',
                'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
                'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
                'architecture': platform.machine(),
                'rustc': subprocess.check_output(['rustc', '--version']).decode().strip(),
                'postgres_major_required': 16}
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # Stable tar headers; a repeatable build workflow, not a cross-toolchain bitwise claim.
    artifact = ROOT / 'dist' / f'paranoid-alpha-{release}-linux-{platform.machine()}.tar'
    def normalize(info):
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ''
        return info
    with tarfile.open(artifact, 'w') as tar:
        for path in sorted(dest.iterdir()):
            tar.add(path, arcname='release/' + path.name, filter=normalize)
    checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
    artifact.with_suffix('.tar.sha256').write_text(checksum + '  ' + artifact.name + '\n')
    print(f'Built {artifact}\nSHA256 {checksum}', flush=True)


if __name__ == '__main__':
    main()
