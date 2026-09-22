#!/usr/bin/env python3
"""Offline CI subset: real JNI/controller tests, no SBF artifact or live RPC.

The full check_host.py additionally verifies the exact SBF/program pins and
remains a separate artifact gate. This subset does not replace that gate.
"""
import hashlib
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / 'clients/android-devnet'
jar = Path(os.environ['JSON_JAR']).resolve()
assert hashlib.sha256(jar.read_bytes()).hexdigest() == '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed', 'unexpected org.json jar'
classes = CLIENT / 'out/controller'
classes.mkdir(parents=True, exist_ok=True)
src = CLIENT / 'src/org/paranoid/devnet'
tests = ['BridgeSmoke', 'RegistrationFlowTest', 'UiGenerationTest', 'DevnetWorkTest']
subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-cp', str(jar), '-d', str(classes),
                *[str(src / (name + '.java')) for name in
                  ['SolanaBridge', 'ProgramPin', 'DevnetRpc', 'RegistrationFlow', 'UiGeneration', 'DevnetWork']],
                *[str(CLIENT / 'test' / (name + '.java')) for name in tests]], check=True, cwd=ROOT)
for name in tests:
    subprocess.run(['java', '-Djava.library.path=' + str(ROOT / 'blockchain/solana/client/target/debug'),
                    '-cp', str(classes) + os.pathsep + str(jar), 'org.paranoid.devnet.' + name],
                   check=True, cwd=ROOT)
print('OFFLINE CONTROLLER PASS; SBF pin, Android runtime and live-chain gates are separate')
