#!/usr/bin/env python3
"""RFC-0027 end-to-end host test: real identity-v3 server (loopback, pinned TLS, own
PostgreSQL, fixture registry) + real Android Java client classes + real JNI (messenger
core and Devnet signer). Synthetic keys only; never contacts Devnet or a hosted server.

Covers: login without v2 registration, E2EE text both ways after QR exchange, lost-reply
retry, replacement retiring the old phone, new phone messaging, restart persistence.
NOT a physical-phone test; calls are exercised by existing voice tests over the same
transport, not here.
"""
import base64
import getpass
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'
DEVNET = ROOT / 'clients/android-devnet'
PG = Path('/usr/lib/postgresql/16/bin')
# Two public test entropies (never funded, never on chain).
ENTROPY = {'alice': base64.b64encode(bytes([1]) * 32).decode(), 'bob': base64.b64encode(bytes([2]) * 32).decode()}
NAMES = {'alice': 'alice_login', 'bob': 'bob_login'}
ENTROPY2 = {'carol': base64.b64encode(bytes([3]) * 32).decode(), 'dave': base64.b64encode(bytes([4]) * 32).decode()}
NAMES2 = {'carol': 'carol_loop', 'dave': 'dave_loop'}


def main():
    os.umask(0o077)
    for manifest in ['server', 'clients/core', 'blockchain/solana/client']:
        subprocess.run(['cargo', 'build', '--locked', '--offline', '--manifest-path', str(ROOT / manifest / 'Cargo.toml')], check=True)
    subprocess.run(['python3', str(ANDROID / 'dependencies.py')], check=True)
    host = ANDROID / 'out/host-identity'
    host.mkdir(parents=True, exist_ok=True)
    cp = ':'.join(str(p) for p in [host, ANDROID / 'out/deps/json-20240303.jar', ANDROID / 'out/deps/zxing-core-3.5.3.jar'])
    names = ['CoreBridge', 'PinnedTls', 'SnapshotCodec', 'StorageGuard', 'SyncCycle', 'KeyClient', 'KeyTransport', 'SelfServiceClient', 'QrCodec',
             'RealtimeLoop', 'RealtimeTransport', 'VoiceRelayConfig', 'VoiceRelayTransport']
    subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-cp', cp, '-d', str(host)]
                   + [str(ANDROID / f'src/org/paranoid/text/{n}.java') for n in names]
                   + [str(DEVNET / f'src/org/paranoid/devnet/{n}.java') for n in ['SolanaBridge', 'IdentityLogin']]
                   + [str(ANDROID / 'test/IdentityLoginBridge.java'), str(ANDROID / 'test/IdentityRealtimeSmoke.java')], check=True)
    libs = ':'.join(str(ROOT / p) for p in ['clients/core/target/debug', 'blockchain/solana/client/target/debug'])
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'PARANOID_'))}
    with tempfile.TemporaryDirectory(prefix='paranoid-identity-v3-') as tmp:
        root = Path(tmp)
        sock = root / 'socket'
        sock.mkdir(mode=0o700)
        pg = server = bridge = None
        log = (root / 'fixture.log').open('w')
        try:
            subprocess.run([str(PG / 'initdb'), '-D', str(root / 'pg'), '--auth-local=trust', '--auth-host=scram-sha-256', '--no-locale', '-E', 'UTF8'], check=True, env=env, stdout=log, stderr=log)
            pg = subprocess.Popen([str(PG / 'postgres'), '-D', str(root / 'pg'), '-k', str(sock), '-c', 'listen_addresses=', '-c', 'unix_socket_permissions=0700'], env=env, stdout=log, stderr=log)
            for _ in range(100):
                if subprocess.run([str(PG / 'pg_isready'), '-h', str(sock)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    break
                time.sleep(.05)
            else:
                raise AssertionError('own PostgreSQL not ready')
            ip = None
            for candidate in ['127.0.0.31', '127.0.0.32', '127.0.0.33']:
                try:
                    with socket.socket() as probe:
                        probe.bind((candidate, 38443))
                    ip = candidate
                    break
                except OSError:
                    pass
            assert ip, 'no free fixture address; never kill another process'
            subprocess.run(['python3', str(ROOT / 'scripts/create-test-tls.py'), '--ip', ip, '--output', str(root / 'tls')], check=True, stdout=log)
            public = json.loads((root / 'tls/public-connection.json').read_text())
            realm, pin = public['server_url'], public['tls_spki_sha256']
            # Registry fixture maps each synthetic owner to its nickname.
            owner_of = {}
            for who, entropy in ENTROPY.items():
                out = subprocess.run(['java', '-Djava.library.path=' + libs, '-cp', cp, 'IdentityLoginBridge', '--owner', entropy], check=True, capture_output=True, text=True)
                owner_of[who] = out.stdout.strip()
                assert 32 <= len(owner_of[who]) <= 44, 'public owner address expected'
            owner_of2 = {}
            for who, entropy in ENTROPY2.items():
                out = subprocess.run(['java', '-Djava.library.path=' + libs, '-cp', cp, 'IdentityLoginBridge', '--owner', entropy], check=True, capture_output=True, text=True)
                owner_of2[who] = out.stdout.strip()
            (root / 'registry.json').write_text(json.dumps({owner_of[w]: NAMES[w] for w in ENTROPY}))
            env.update(PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={sock}',
                       PARANOID_KEY_REALM=realm, PARANOID_KEY_PIN=pin, PARANOID_MODE='identity-v3-local',
                       PARANOID_BIND=f'{ip}:38443', PARANOID_TLS_CERT=str(root / 'tls/server.crt'),
                       PARANOID_TLS_KEY=str(root / 'tls/server.key'),
                       PARANOID_REGISTRY_FIXTURE=str(root / 'registry.json'))
            binary = str(ROOT / 'server/target/debug/paranoid-server')
            subprocess.run([binary, 'identity-v3-init'], env=env, check=True, stdout=log, stderr=log)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(root / 'tls/server.crt'))))

            def start_server():
                process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
                for _ in range(100):
                    if process.poll() is not None:
                        raise AssertionError('identity-v3 server exited')
                    try:
                        with opener.open(realm + '/health', timeout=1) as response:
                            if response.status == 200:
                                return process
                    except OSError:
                        time.sleep(.05)
                raise AssertionError('identity-v3 server not ready')

            def start_bridge():
                return subprocess.Popen(['java', '-Djava.library.path=' + libs, '-cp', cp, 'IdentityLoginBridge', str(root / 'phones'), realm, pin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

            server = start_server()
            bridge = start_bridge()

            def rpc(phone, op, value='', ok=True):
                bridge.stdin.write(phone + '\t' + op + '\t' + base64.b64encode(value.encode()).decode() + '\n')
                bridge.stdin.flush()
                line = bridge.stdout.readline()
                assert line, 'JNI bridge exited'
                result = json.loads(base64.b64decode(line))
                if ok:
                    assert 'error' not in result, f'{phone}/{op}: {result.get("error")}'
                return result

            def login(phone, who, replace=False, ok=True):
                return rpc(phone, 'login', json.dumps({'entropy': ENTROPY[who], 'name': NAMES[who], 'replace': replace}), ok)

            # 1. Fresh phones: create local ID, then log in with the Devnet identity.
            one = rpc('one', 'create')
            assert one['identity'] and not one['active']
            # The old v2 self-registration path is absent on this server.
            assert rpc('one', 'sync', ok=False)['error'].startswith('http_404'), 'v2 registration must be refused'
            one = login('one', 'alice')
            assert one['login'] == 'active' and one['active'], one
            two = rpc('two', 'create')
            two = login('two', 'bob')
            assert two['login'] == 'active' and two['active']
            # Lost reply: logging in again from the same phone is idempotent.
            assert login('one', 'alice')['login'] == 'active'
            # 2. Verified QR exchange and E2EE text both ways.
            rpc('one', 'pair', json.dumps(two['contact']))
            rpc('two', 'pair', json.dumps(one['contact']))
            rpc('one', 'send', json.dumps({'account': two['account'], 'text': 'Привет от alice'}))
            rpc('one', 'sync')
            v = rpc('two', 'sync')
            got = [m for d in v['dialogs'] for m in d['messages']]
            assert any(m.get('text') == 'Привет от alice' for m in got), got
            rpc('two', 'send', json.dumps({'account': one['account'], 'text': 'Ответ bob'}))
            rpc('two', 'sync')
            v = rpc('one', 'sync')
            assert any(m.get('text') == 'Ответ bob' for d in v['dialogs'] for m in d['messages'])
            # 3. Restart server and JVM: login state and history persist.
            bridge.stdin.close(); bridge.wait(timeout=10); bridge = None
            server.terminate(); server.wait(timeout=10); server = None
            server = start_server(); bridge = start_bridge()
            v = rpc('one', 'sync')
            assert v['active'] and v['account'] == one['account']
            # 4. Alice moves to phone three: explicit replacement retires phone one.
            rpc('three', 'create')
            assert login('three', 'alice')['login'] == 'replace_required'
            three = login('three', 'alice', replace=True)
            assert three['login'] == 'active' and three['account'] != one['account']
            assert login('one', 'alice')['login'] == 'revoked'
            assert rpc('one', 'sync', ok=False).get('error', '').startswith('http_'), 'retired phone must lose access'
            # 5. New phone messages bob after a fresh contact exchange.
            rpc('three', 'pair', json.dumps(two['contact']))
            rpc('two', 'pair', json.dumps(three['contact']))
            rpc('three', 'send', json.dumps({'account': two['account'], 'text': 'Я на новом телефоне'}))
            rpc('three', 'sync')
            v = rpc('two', 'sync')
            assert any(m.get('text') == 'Я на новом телефоне' for d in v['dialogs'] for m in d['messages'])
            # 6. Real background loop on the same server: idles until ID login, then delivers.
            (root / 'registry.json').write_text(json.dumps({**{owner_of[w]: NAMES[w] for w in ENTROPY}, **{owner_of2[w]: NAMES2[w] for w in ENTROPY2}}))
            server.terminate(); server.wait(timeout=10); server = start_server()
            loop = subprocess.run(['timeout', '-s', 'QUIT', '-k', '5', '120', 'java', '-Djava.library.path=' + libs, '-cp', cp, 'IdentityRealtimeSmoke', realm, pin,
                                   ENTROPY2['carol'], NAMES2['carol'], ENTROPY2['dave'], NAMES2['dave']],
                                  capture_output=True, text=True, timeout=180)
            assert loop.returncode == 0 and 'PASS' in loop.stdout, (loop.stdout[-1500:], loop.stderr[-3000:])
            print('PASS identity-v3 real server + Android JVM/JNI: login without v2 registration, idempotent retry, '
                  'E2EE text both ways, restart persistence, explicit replacement retiring the old phone, new phone '
                  'messaging, background loop idles until login then delivers. NOT a physical-phone, live-Devnet or call test.')
        finally:
            if bridge is not None:
                bridge.stdin.close(); bridge.wait(timeout=10)
            if server is not None and server.poll() is None:
                server.terminate(); server.wait(timeout=10)
            if pg is not None and pg.poll() is None:
                pg.send_signal(signal.SIGINT); pg.wait(timeout=20)
            log.close()


if __name__ == '__main__':
    main()
