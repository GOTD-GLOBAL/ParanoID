#!/usr/bin/env python3
"""LIVE Devnet sponsored-registration check: local identity-v3 server (loopback, own
PostgreSQL, live Devnet registry verifier) with PARANOID_SPONSOR_KEYPAIR_FILE, and the real
Java RegistrationFlow + JNI library registering a fresh UNFUNDED owner. Spends test SOL only
from the sponsor file given in argv[1]. Prints public values only."""
import getpass, json, os, socket, subprocess, sys, tempfile, time, ssl, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'; DEVNET = ROOT / 'clients/android-devnet'
PG = Path('/usr/lib/postgresql/16/bin')
sponsor_file = sys.argv[1]
os.umask(0o077)
for m in ['server', 'blockchain/solana/client']:
    subprocess.run(['cargo', 'build', '-q', '--locked', '--offline', '--manifest-path', str(ROOT / m / 'Cargo.toml')], check=True)
host = ANDROID / 'out/host-sponsor'; host.mkdir(parents=True, exist_ok=True)
cp = f"{host}:{ANDROID/'out/deps/json-20240303.jar'}"
text = ['CoreBridge', 'PinnedTls', 'SyncCycle', 'KeyTransport', 'KeyClient', 'SnapshotCodec']
subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-cp', cp, '-d', str(host)]
               + [str(ANDROID / f'src/org/paranoid/text/{n}.java') for n in text]
               + [str(DEVNET / f'src/org/paranoid/devnet/{n}.java') for n in ['SolanaBridge', 'RegistrationFlow', 'DevnetRpc', 'ProgramPin']]
               + [str(DEVNET / 'test/SponsoredLive.java')], check=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'PARANOID_'))}
with tempfile.TemporaryDirectory(prefix='paranoid-sponsor-') as tmp:
    root = Path(tmp); sock = root / 's'; sock.mkdir(mode=0o700); log = (root / 'log').open('w')
    pg = server = None
    try:
        subprocess.run([str(PG / 'initdb'), '-D', str(root / 'pg'), '--auth-local=trust', '--no-locale', '-E', 'UTF8'], check=True, env=env, stdout=log, stderr=log)
        pg = subprocess.Popen([str(PG / 'postgres'), '-D', str(root / 'pg'), '-k', str(sock), '-c', 'listen_addresses='], env=env, stdout=log, stderr=log)
        for _ in range(100):
            if subprocess.run([str(PG / 'pg_isready'), '-h', str(sock)], env=env, capture_output=True).returncode == 0: break
            time.sleep(.05)
        ip = next(c for c in ['127.0.0.41', '127.0.0.42', '127.0.0.43'] if socket.socket().connect_ex((c, 38443)) != 0)
        subprocess.run(['python3', str(ROOT / 'scripts/create-test-tls.py'), '--ip', ip, '--output', str(root / 'tls')], check=True, stdout=log)
        pub = json.loads((root / 'tls/public-connection.json').read_text()); realm, pin = pub['server_url'], pub['tls_spki_sha256']
        env.update(PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={sock}', PARANOID_KEY_REALM=realm,
                   PARANOID_KEY_PIN=pin, PARANOID_MODE='identity-v3-local', PARANOID_BIND=f'{ip}:38443',
                   PARANOID_TLS_CERT=str(root / 'tls/server.crt'), PARANOID_TLS_KEY=str(root / 'tls/server.key'),
                   PARANOID_SPONSOR_KEYPAIR_FILE=sponsor_file)
        binary = str(ROOT / 'server/target/debug/paranoid-server')
        subprocess.run([binary, 'identity-v3-init'], env=env, check=True, stdout=log, stderr=log)
        server = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
        ctx = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
        for _ in range(200):
            try:
                urllib.request.urlopen(realm + '/health', context=ctx, timeout=1); break
            except OSError: time.sleep(.05)
        libs = str(ROOT / 'blockchain/solana/client/target/debug') + ':' + str(ROOT / 'clients/core/target/debug')
        r = subprocess.run(['java', '-Djava.library.path=' + libs, '-cp', cp, 'org.paranoid.devnet.SponsoredLive', realm, pin], capture_output=True, text=True, timeout=300)
        print(r.stdout.strip()); print(r.stderr.strip()[-1500:])
        sys.exit(r.returncode)
    finally:
        for p in (server, pg):
            if p: p.terminate(); p.wait(10)
        log.close()
