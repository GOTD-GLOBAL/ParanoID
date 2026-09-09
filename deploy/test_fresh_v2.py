"""Fresh-only packaged v2: real private PG/TLS, no live host or user manager."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_native import load

HERE = Path(__file__).resolve().parent
alpha = load('fresh_alpha', (Path(os.environ['PARANOID_V2_RELEASE']) if os.environ.get('PARANOID_TEST_PACKAGED') == '1' else HERE) / 'alpha.py')


import base64
import hashlib
import http.client
import json
import ssl
import time
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def lp(values):
    return b''.join(len(str(v).encode()).to_bytes(4, 'big') + str(v).encode() for v in values)


def b64(raw):
    return base64.b64encode(raw).decode().rstrip('=')


class Peer:
    """Independent synthetic signer; opaque payload tests, NOT client E2EE."""
    def __init__(self, realm, pin):
        root, self.auth = Ed25519PrivateKey.generate(), Ed25519PrivateKey.generate()
        def public(key):
            return b64(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
        self.c = {'root': public(root), 'account': hashlib.sha256(lp(['paranoid-account-v1', public(root)])).hexdigest(),
                  'device': str(uuid.uuid4()), 'auth': public(self.auth), 'realm': realm, 'pin': pin, 'olm': 'a' * 64}
        transcript = lp(['paranoid-credential-v1'] + [self.c[n] for n in ('root', 'account', 'device', 'auth', 'realm', 'pin', 'olm')])
        self.c['signature'] = b64(root.sign(transcript))
        self.fp = hashlib.sha256(transcript).hexdigest()

    def signed(self, request, purpose, method, path, body=b''):
        time.sleep(.56)  # Respect actual challenge admission budget, not readiness polling.
        register = purpose == 'register'
        payload = {'credential': self.c if register else self.fp, 'purpose': purpose,
                   'method': method, 'path': path, 'body': hashlib.sha256(body).hexdigest()}
        if not register:
            payload.update(account=self.c['account'], device=self.c['device'])
        code, challenge = request('POST', '/v2/' + ('registration' if register else 'auth') + '/challenge', json.dumps(payload).encode())
        assert code == 200, (code, challenge)
        fields = ('id', 'nonce', 'epoch', 'expires', 'realm', 'pin', 'account', 'device', 'credential', 'purpose', 'method', 'path', 'body')
        signature = b64(self.auth.sign(lp(['paranoid-proof-v2'] + [challenge[n] for n in fields])))
        return request(method, path, body, 'ParanoidV2 ' + challenge['id'] + '.' + signature)


class FreshV2(unittest.TestCase):
    def test_replace_discards_only_confirmed_stopped_cluster_without_backup(self):
        self.assertTrue(callable(getattr(alpha, 'replace_v2', None)), 'replace-v2 missing')
        os.umask(0o077)
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        with tempfile.TemporaryDirectory(prefix='paranoid-replace-v2-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, release))
            c = alpha.config(root)
            alpha.atomic_config(root, {**c, 'deployment': 'key-v1'})
            with alpha.lock(root), alpha.database(root):
                alpha.sql(root, (release / 'schema.sql').read_text())
                alpha.sql(root, 'CREATE DATABASE verify_disposable')
            with self.assertRaises(ValueError):
                alpha.fresh_v2(root, release, '127.0.0.19')
            self.assertEqual(alpha.config(root), {**c, 'deployment': 'key-v1'})
            identifier = alpha.cluster_identifier(root)
            identity = {n: (root / n).read_bytes() for n in ('tls/server.key', 'tls/server.crt')}
            (root / 'backups/sentinel').write_bytes(b'untouched outside data')
            with self.assertRaises(ValueError):
                alpha.replace_v2(root, release, '127.0.0.19', identifier, False)
            with self.assertRaises(ValueError):
                alpha.replace_v2(root, release, '127.0.0.19', '1', True)
            with alpha.lock(root), self.assertRaises(BlockingIOError):
                alpha.replace_v2(root, release, '127.0.0.19', identifier, True)
            with alpha.database(root), self.assertRaises(RuntimeError):
                alpha.replace_v2(root, release, '127.0.0.19', identifier, True)
            (root / 'data/redirect').symlink_to(root / 'tls')
            with self.assertRaises(ValueError):
                alpha.replace_v2(root, release, '127.0.0.19', identifier, True)
            (root / 'data/redirect').unlink()  # synthetic test link only
            result = subprocess.run(['python3', release / 'alpha.py', 'replace-v2', '--root', root,
                                     '--release', release, '--ip', '127.0.0.19',
                                     '--expected-pg-system-id', identifier, '--discard-server-database'],
                                    env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                    capture_output=True, check=True, timeout=40)
            self.assertIn(b'without backup', result.stdout)
            self.assertEqual(alpha.config(root), {**c, 'deployment': 'self-service-v2'})
            self.assertNotEqual(alpha.cluster_identifier(root), identifier)
            with alpha.lock(root), alpha.database(root):
                self.assertEqual(alpha.sql(root, "SELECT count(*) FROM pg_database WHERE datname='verify_disposable'").strip(), b'0')
                self.assertEqual(alpha.sql(root, 'SELECT count(*) FROM ss_accounts').strip(), b'0')
            self.assertEqual(identity, {n: (root / n).read_bytes() for n in identity})
            self.assertEqual([p.name for p in (root / 'backups').iterdir()], ['sentinel'])
            self.assertEqual((root / 'backups/sentinel').read_bytes(), b'untouched outside data')
            with self.assertRaises(ValueError):
                alpha.replace_v2(root, release, '127.0.0.19', alpha.cluster_identifier(root), True)
            print('PASS: confirmed synthetic cluster replaced in place; verify DB discarded, no backup, preserved TLS/config fields/outside-data sentinel; repeat/live/lock/redirect/wrong-id denied')

    def test_v2_legacy_backup_update_switch_refused_before_side_effects(self):
        os.umask(0o077)
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        with tempfile.TemporaryDirectory(prefix='paranoid-v2-gates-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, release))
            alpha.fresh_v2(root, release, '127.0.0.19')
            with self.assertRaisesRegex(ValueError, 'v2'):
                alpha.backup(root)
            with self.assertRaisesRegex(ValueError, 'v2'):
                alpha.switch(root, release)
            with self.assertRaisesRegex(ValueError, 'v2'):
                alpha.update(root, release)
            self.assertEqual(list((root / 'backups').iterdir()), [])

    def test_readiness_rejects_wrong_binding_missing_columns_and_disabled_guard(self):
        os.umask(0o077)
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        with tempfile.TemporaryDirectory(prefix='paranoid-v2-health-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, release))
            alpha.fresh_v2(root, release, '127.0.0.19')
            with alpha.lock(root), alpha.database(root):
                alpha.v2_readiness(root)
                alpha.sql(root, "UPDATE ss_meta SET pin='wrong'")
                with self.assertRaises(ValueError):
                    alpha.v2_readiness(root)
                alpha.sql(root, "UPDATE ss_meta SET pin='" + alpha.public_realm(root)[1] + "'")
                alpha.sql(root, 'ALTER TABLE ss_devices RENAME auth TO broken_auth')
                with self.assertRaises(subprocess.CalledProcessError):
                    alpha.v2_readiness(root)
                alpha.sql(root, 'ALTER TABLE ss_devices RENAME broken_auth TO auth')
                alpha.sql(root, 'ALTER TABLE room_state DISABLE TRIGGER key_schema_startup_guard')
                with self.assertRaises(ValueError):
                    alpha.v2_readiness(root)
                alpha.sql(root, 'ALTER TABLE room_state ENABLE TRIGGER key_schema_startup_guard')
                alpha.v2_readiness(root)

    def test_fresh_initializer_refuses_old_tables_before_config_change(self):
        os.umask(0o077)
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        with tempfile.TemporaryDirectory(prefix='paranoid-v2-empty-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, release))
            before = (root / 'config.json').read_bytes()
            with alpha.lock(root), alpha.database(root):
                alpha.sql(root, (release / 'schema.sql').read_text())
            with self.assertRaises(ValueError):
                alpha.fresh_v2(root, release, '127.0.0.19')
            self.assertEqual((root / 'config.json').read_bytes(), before)
            self.assertEqual(list((root / 'backups').iterdir()), [])

    def test_install_v2_uses_existing_isolated_unit_flow(self):
        from unittest.mock import patch
        self.assertTrue(callable(getattr(alpha, 'install_v2', None)), 'install-v2 missing')
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-install-v2-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            native_command = alpha.command
            manager_calls = []
            def command(args, **kwargs):
                if str(args[0]) == 'systemctl':
                    manager_calls.append([str(a) for a in args])
                    return b'not-found\n' if 'show' in args else b''
                return native_command(args, **kwargs)
            # Only user-manager activation is intercepted; initdb, schema, TLS,
            # capability probes and systemd-analyze unit validation are real.
            with patch.object(alpha, 'command', side_effect=command), patch.object(alpha, 'wait_health'):
                alpha.install_v2(root, '127.0.0.19', release, 'paranoid-alpha-fixture.service')
            self.assertEqual(alpha.config(root)['deployment'], 'self-service-v2')
            self.assertEqual(manager_calls[-1], ['systemctl', '--user', 'enable', '--now', str(root / 'paranoid-alpha-fixture.service')])
            self.assertEqual(len(manager_calls), 2)
            self.assertEqual(list((root / 'backups').iterdir()), [])

    def test_fresh_initialization_restart_preserves_tls_and_has_no_grants(self):
        self.assertTrue(callable(getattr(alpha, 'fresh_v2', None)), 'fresh-v2 operation missing')
        os.umask(0o077)
        release = Path(os.environ['PARANOID_V2_RELEASE'])
        with tempfile.TemporaryDirectory(prefix='paranoid-fresh-v2-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            neighbor = Path(tmp) / 'neighbor'
            neighbor.write_bytes(b'untouched')
            alpha.initialize(root, '127.0.0.19')
            alpha.point(root, alpha.stage(root, release))
            identity = {n: (root / n).read_bytes() for n in ('tls/server.key', 'tls/server.crt')}
            alpha.fresh_v2(root, release, '127.0.0.19')
            self.assertEqual(alpha.environment(root)['PARANOID_MODE'], 'self-service-v2')
            self.assertNotIn('PARANOID_ALICE_TOKEN', alpha.environment(root))
            self.assertIn('Restart=on-failure', alpha.unit(root))
            self.assertIn('WantedBy=default.target', alpha.unit(root))
            denied = alpha.environment(root)
            denied.pop('PARANOID_REVIEWED_SELF_SERVICE_IP')
            rejected = subprocess.run([str(release / 'paranoid-server')], env=denied, capture_output=True, timeout=10, check=False)
            self.assertNotEqual(rejected.returncode, 0)
            with alpha.lock(root), alpha.database(root):
                for mode in ('closed-alpha-v0', 'closed-alpha-key-v1'):
                    rejected = subprocess.run([str(release / 'paranoid-server')],
                                              env={**alpha.environment(root), 'PARANOID_MODE': mode,
                                                   'PARANOID_ALICE_TOKEN': 'a' * 64, 'PARANOID_BOB_TOKEN': 'b' * 64},
                                              capture_output=True, timeout=10, check=False)
                    self.assertNotEqual(rejected.returncode, 0)
                alpha.v2_readiness(root)
                alpha.sql(root, 'ALTER TABLE ss_devices RENAME COLUMN auth TO bad_auth')
                with self.assertRaises(subprocess.CalledProcessError):
                    alpha.v2_readiness(root)
                alpha.sql(root, 'ALTER TABLE ss_devices RENAME COLUMN bad_auth TO auth')
                alpha.sql(root, 'ALTER TABLE room_state DISABLE TRIGGER key_schema_startup_guard')
                with self.assertRaises(ValueError):
                    alpha.v2_readiness(root)
                alpha.sql(root, 'ALTER TABLE room_state ENABLE TRIGGER key_schema_startup_guard')
            context = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
            def request(method, path, body=b'', auth=None):
                conn = http.client.HTTPSConnection('127.0.0.19', 38443, context=context, timeout=5)
                headers = {'Content-Type': 'application/json'}
                if auth:
                    headers['Authorization'] = auth
                try:
                    conn.request(method, path, body, headers)
                    response = conn.getresponse()
                    raw = response.read()
                    return response.status, json.loads(raw) if raw else None
                finally:
                    conn.close()
            peers = [Peer(*alpha.public_realm(root)) for _ in range(3)]
            bodies = [json.dumps({'id': str(uuid.uuid4()), 'recipient': peers[0].c['account'], 'ciphertext': 'AQID'}).encode() for _ in range(2)]
            for iteration in range(2):
                process = subprocess.Popen(['python3', release / 'alpha.py', 'run', '--root', root],
                                           env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    alpha.wait_health(root)
                    self.assertIsNone(process.poll())
                    self.assertEqual(alpha.sql(root, 'SELECT count(*) FROM ss_accounts').strip(), b'0' if iteration == 0 else b'3')
                    self.assertEqual(alpha.sql(root, "SELECT to_regclass('key_grants') IS NULL").strip(), b't')
                    for peer in peers:
                        code, registered = peer.signed(request, 'register', 'POST', '/v2/registration/commit', b'{}')
                        self.assertEqual((code, registered['mode']), (200, 'active'))
                    for peer, body in zip(peers[1:], bodies):
                        self.assertEqual(peer.signed(request, 'message', 'POST', '/v2/messages', body)[0], 200)
                    code, inbox = peers[0].signed(request, 'message', 'GET', '/v2/messages?after=0')
                    self.assertEqual(code, 200)
                    self.assertEqual([m['id'] for m in inbox['messages']], [json.loads(b)['id'] for b in bodies])
                    self.assertEqual([m['ciphertext'] for m in inbox['messages']], ['AQID', 'AQID'])
                    self.assertEqual(alpha.sql(root, 'SELECT count(*) FROM ss_messages').strip(), b'2')
                    self.assertEqual(request('GET', '/v1/messages')[0], 404)
                    self.assertEqual(request('GET', '/v2/messages', auth='Bearer ' + 'a' * 64)[0], 401)
                finally:
                    process.terminate()
                    process.wait(timeout=40)
            self.assertEqual(identity, {n: (root / n).read_bytes() for n in identity})
            self.assertEqual(list((root / 'backups').iterdir()), [])
            self.assertEqual(neighbor.read_bytes(), b'untouched')
            with self.assertRaises(ValueError):
                alpha.fresh_v2(root, release, '127.0.0.19')
            # Legacy recovery code does not compare ss_*; it must refuse BEFORE
            # dumping anything, not pretend a partially verified backup is v2-safe.
            with alpha.lock(root), alpha.database(root), self.assertRaisesRegex(ValueError, 'v2'):
                alpha.backup(root)
            self.assertEqual(list((root / 'backups').iterdir()), [])
            print('PASS: fresh packaged PG/TLS, three self-registering proof identities/no grants, two messages retried across supervisor restart, unchanged TLS/neighbor, zero backups; opaque payloads, not E2EE')


if __name__ == '__main__':
    unittest.main()
