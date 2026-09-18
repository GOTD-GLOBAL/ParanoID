#!/usr/bin/env python3
"""Real generated loopback pinned TLS reuse and independent lane regression."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence-dir', type=Path, required=True)
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='paranoid-pool-') as directory:
        tmp = Path(directory)
        subprocess.run(['python3', str(ROOT/'scripts/create-test-tls.py'), '--ip', '127.0.0.1', '--output', str(tmp/'tls')], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['openssl', 'pkcs12', '-export', '-in', str(tmp/'tls/server.crt'), '-inkey', str(tmp/'tls/server.key'), '-name', 'tls', '-out', str(tmp/'server.p12'), '-passout', 'pass:test-only'], check=True)
        cp = str(ANDROID/'out/deps/json-20240303.jar')
        names = ['CoreBridge', 'PinnedTls', 'KeyClient', 'KeyTransport', 'SyncCycle',
                 'SelfServiceClient', 'RealtimeLoop', 'RealtimeTransport',
                 'VoiceRelayConfig', 'VoiceRelayTransport', 'UpdateClient', 'UpdateManifest', 'UpdatePolicy']
        subprocess.run(['javac', '--release', '8', '-cp', cp, '-d', str(tmp)] + [str(ANDROID/f'src/org/paranoid/text/{name}.java') for name in names] + [str(ANDROID/'test/RealtimeTransportSmoke.java'), str(ANDROID/'test/ResponseTimeoutSmoke.java')], check=True)
        subprocess.run(['java', '-cp', str(tmp)+':'+cp, 'RealtimeTransportSmoke', str(tmp/'server.p12')], check=True)
        subprocess.run(['java', '-cp', str(tmp)+':'+cp, 'org.paranoid.text.ResponseTimeoutSmoke', str(tmp/'server.p12')], check=True, timeout=65)

if __name__ == '__main__':
    main()
