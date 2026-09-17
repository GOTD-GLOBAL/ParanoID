#!/usr/bin/env python3
"""REQ-MSG-004/DEPLOY-002: fresh packaged v2 backup/rollback CI.

Only synthetic private PostgreSQL/TLS fixtures, no systemd or remote services.
The default baseline is the just-built package: this proves same-schema code
switch/rollback, not historical binary compatibility. Set
PARANOID_V2_OLD_RELEASE explicitly for a retained historical package check.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    # Strict packages must never gain __pycache__ during verification/imports.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('v2_ci_builder', ROOT / 'deploy/build.py')
    assert spec and spec.loader
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    artifact = builder.main(self_service_v2=True)
    release = artifact.parent / 'release'
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1',
           'PARANOID_V2_OLD_RELEASE': os.environ.get('PARANOID_V2_OLD_RELEASE', str(release)),
           'PARANOID_TEST_PACKAGED': '1', 'PARANOID_V2_RELEASE': str(release)}
    for test in ('test_v2_update.py', 'test_v2_maintenance_interrupts.py'):
        subprocess.run([sys.executable, str(ROOT / 'deploy' / test), '-v'],
                       cwd=ROOT, env=env, check=True)
    print('Packaged v2 backup/rollback/interrupt checks passed; no hosted actions.', flush=True)


if __name__ == '__main__':
    main()
