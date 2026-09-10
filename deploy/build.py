#!/usr/bin/env python3
"""Build the native bundle with locked Rust dependencies; no deployment."""
import argparse
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main(self_service_v2=False):
    target = Path(os.environ.get('CARGO_TARGET_DIR', str(ROOT / 'server/target')))
    if not target.is_absolute():
        raise ValueError('absolute cargo target directory required')
    subprocess.run(['cargo', 'build', '--release', '--locked', '--manifest-path',
                    ROOT / 'server/Cargo.toml'], check=True)
    if self_service_v2:
        capability = subprocess.check_output([target / 'release/paranoid-server',
                                               'voice-turn-capabilities'], timeout=10)
        if json.loads(capability) != {'api': 1, 'issuer': 'signed-session-turn-v1'}:
            raise ValueError('new bundle requires matching TURN issuer binary')
    os.umask(0o077)
    dist = ROOT / 'dist'
    dist.mkdir(mode=0o700, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='build-', dir=dist))
    dest = output / 'release'
    dest.mkdir(mode=0o700)
    files = {'paranoid-server': target / 'release/paranoid-server',
             'schema.sql': ROOT / 'server/schema.sql', 'key-schema.sql': ROOT / 'server/key-schema.sql',
             'alpha.py': ROOT / 'deploy/alpha.py',
             'create-test-tls.py': ROOT / 'scripts/create-test-tls.py',
             'README.md': ROOT / 'deploy/README.md'}
    if self_service_v2:
        files['self-service-schema.sql'] = ROOT / 'server/self-service-schema.sql'
        files['voice-turn-controller.json'] = ROOT / 'deploy/voice-turn-controller.json'
    for name, source in files.items():
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as src:
            mode = os.fstat(src.fileno()).st_mode
            if not stat.S_ISREG(mode):
                raise ValueError('regular nonsymlink component required')
            with (dest / name).open('xb') as out:
                shutil.copyfileobj(src, out)
            (dest / name).chmod(0o700 if mode & 0o111 else 0o600)
    hashes = {name: hashlib.sha256((dest / name).read_bytes()).hexdigest() for name in files}
    release = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:20]
    manifest = {'release': release, 'sha256': hashes, 'schema_contract': 'paranoid-self-service-v2' if self_service_v2 else 'paranoid-key-v1',
                'deployment_api': 1,
                'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
                'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
                'architecture': platform.machine(),
                'rustc': subprocess.check_output(['rustc', '--version']).decode().strip(),
                'postgres_major_required': 16}
    if self_service_v2:
        manifest['voice_turn_controller'] = 'self-service-v2-turn-file-v1'
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # Stable tar headers; a repeatable build workflow, not a cross-toolchain bitwise claim.
    artifact = output / f'paranoid-alpha-{release}-linux-{platform.machine()}.tar'
    def normalize(info):
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ''
        return info
    if {p.name for p in dest.iterdir()} != {*files, 'manifest.json'}:
        raise ValueError('unexpected package member')
    for path in dest.iterdir():
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('regular nonsymlink package member required')
    with tarfile.open(artifact, 'x') as tar:
        for name in sorted((*files, 'manifest.json')):
            tar.add(dest / name, arcname='release/' + name, filter=normalize, recursive=False)
    checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
    artifact.with_suffix('.tar.sha256').write_text(checksum + '  ' + artifact.name + '\n')
    print(f'Built {artifact}\nSHA256 {checksum}', flush=True)
    return artifact


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-service-v2', action='store_true')
    main(parser.parse_args().self_service_v2)
