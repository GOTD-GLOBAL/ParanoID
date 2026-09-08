"""Bundle crate notices from the locked local Cargo sources; fail if absent."""
import json
import subprocess
from pathlib import Path

metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
    '--manifest-path', 'native/Cargo.toml'
], text=True))
parts = ['Third-party notices for experimental ParanoID Android probe\n']
for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    if package['source'] is None:
        continue
    root = Path(package['manifest_path']).parent
    files = sorted(p for p in root.rglob('*') if p.is_file()
                   and p.name.lower().startswith(('license', 'licence', 'copying', 'notice')))
    if not files and package['name'] in ('matrix-pickle', 'matrix-pickle-derive'):
        root = Path('licenses')
        files = [root / 'matrix-pickle-LICENSE']
    if not files:
        raise RuntimeError('Missing license text: ' + package['name'])
    parts.append(f"\n{package['name']} {package['version']} — {package['license']}\n{package['repository']}\n")
    for path in files:
        parts.append(str(path.relative_to(root)) + '\n' + path.read_text(errors='replace'))
Path('out/THIRD_PARTY_NOTICES.txt').write_text('\n'.join(parts))
