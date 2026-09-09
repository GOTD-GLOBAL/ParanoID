"""REQ-ID-006/MSG-004/DEPLOY-001: actual JNI + packaged systemd/PG16/TLS migration.
Run with PYTHONDONTWRITEBYTECODE=1 and PARANOID_KEY_RELEASE; synthetic fixtures only.
Requires compiled public host JNI/classes (same prerequisites as check-registration.py).
"""
import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

from test_native import load

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


class PackagedKeyE2EE(unittest.TestCase):
    def test_populated_jni_systemd_migration_update_rollback_restore(self):
        os.umask(0o077)
        release = Path(os.environ['PARANOID_KEY_RELEASE'])
        alpha = load('e2ee_packaged_alpha', release / 'alpha.py')
        with tempfile.TemporaryDirectory(prefix='paranoid-key-e2ee-') as temp:
            base = Path(temp)
            root = base / 'paranoid-alpha'
            name = 'paranoid-alpha-keytest-' + uuid.uuid4().hex[:8] + '.service'
            self.assertEqual(alpha.command(['systemctl', '--user', 'show', name, '-p', 'LoadState', '--value']).strip(), b'not-found')
            alpha.initialize(root, '127.0.0.22')
            alpha.point(root, alpha.stage(root, release))
            identity = {n: (root / n).read_bytes() for n in ('config.json', 'tls/server.key', 'tls/server.crt')}
            realm, pin = alpha.public_realm(root)
            classpath = ':'.join(str(ROOT / p) for p in ('clients/android/out/host', 'clients/android/out/deps/json-20240303.jar', 'clients/android/out/deps/zxing-core-3.5.3.jar'))
            java = ['java', '-Djava.library.path=' + str(ROOT / 'clients/core/target/debug'), '-cp', classpath]
            subprocess.run(java + ['LegacyMigrationSmoke', str(base / 'phones'), realm, pin], check=True)
            envelope = json.loads((base / 'phones/legacy-envelope.json').read_text())
            frame = base64.b64decode(envelope['ciphertext'], validate=True)
            message_id = str(uuid.UUID(envelope['id']))
            with alpha.lock(root), alpha.database(root):
                alpha.sql(root, (release / 'schema.sql').read_text())
                alpha.sql(root, f"INSERT INTO envelopes VALUES(1,0,1,'{message_id}',decode('{frame.hex()}','hex')); UPDATE room_state SET sequence=1,used_bytes={len(frame)}")
            (root / name).write_text(alpha.unit(root))
            bridge = None
            enabled = False
            def manager(action):
                return alpha.command(['systemctl', '--user', action, name])
            def start_bridge():
                return subprocess.Popen(java + ['RegistrationBridge', str(base / 'phones'), realm, pin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            def rpc(phone, operation, value=''):
                assert bridge is not None and bridge.stdin is not None and bridge.stdout is not None
                bridge.stdin.write(phone + '\t' + operation + '\t' + base64.b64encode(value.encode()).decode() + '\n')
                bridge.stdin.flush()
                line = bridge.stdout.readline()
                self.assertTrue(line, 'real JNI bridge exited')
                response = json.loads(base64.b64decode(line))
                self.assertNotIn('error', response, operation)
                return response
            def sync_all():
                for phone in ('two', 'one', 'two', 'one'):
                    rpc(phone, 'sync')
            try:
                alpha.command(['systemctl', '--user', 'enable', '--now', root / name])
                enabled = True
                alpha.wait_health(root)
                manager('stop')
                alpha.migrate_key(root, release)
                manager('start')
                alpha.wait_health(root)
                bridge = start_bridge()
                for slot, phone in enumerate(('one', 'two')):
                    view = rpc(phone, 'create')
                    request = view['request']
                    credential = request['credential']
                    fields = ['paranoid-credential-v1'] + [credential[k] for k in ('root', 'account', 'device', 'auth', 'realm', 'pin', 'olm')]
                    fingerprint = hashlib.sha256(b''.join(len(f.encode()).to_bytes(4, 'big') + f.encode() for f in fields)).hexdigest()
                    request_file = base / (phone + '-public-request.json')
                    grant_file = base / (phone + '-public-grant.json')
                    request_file.write_text(json.dumps(request))
                    subprocess.run([release / 'paranoid-server', 'key-admin-approve', str(slot), fingerprint, credential['olm'], request_file, grant_file], env=alpha.environment(root), check=True)
                    self.assertTrue(rpc(phone, 'grant', grant_file.read_text())['active'])
                alpha.health(root)  # Both legacy tokens are now revoked; no client authority used.
                a, b = rpc('one', 'view'), rpc('two', 'view')
                rpc('one', 'pair', json.dumps(b['contact']))
                rpc('two', 'pair', json.dumps(a['contact']))
                rpc('one', 'send', 'После миграции')
                sync_all()
                candidate = base / 'candidate'
                shutil.copytree(release, candidate)
                with (candidate / 'README.md').open('a') as stream:
                    stream.write('\nSynthetic compatible code-rollback fixture; same built binary.\n')
                manifest = json.loads((candidate / 'manifest.json').read_text())
                manifest['release'] += '-compatible'
                manifest['sha256']['README.md'] = alpha.digest(candidate / 'README.md')
                (candidate / 'manifest.json').write_text(json.dumps(manifest))
                alpha.update(root, candidate, name)
                rpc('two', 'send', 'После обновления')
                sync_all()
                assert bridge.stdin is not None and bridge.stdout is not None
                bridge.stdin.close()
                bridge.wait(timeout=10)
                bridge.stdout.close()
                bridge = None
                alpha.update(root, release, name)
                bridge = start_bridge()
                sync_all()
                for phone in ('one', 'two'):
                    view = rpc(phone, 'view')
                    self.assertEqual({m['text'] for m in view['messages']}, {'До миграции', 'После миграции', 'После обновления'})
                    self.assertEqual(len(view['messages']), 3)
                    self.assertTrue(view['active'])
                # Readiness and revoked-token behavior are separate tests.
                import ssl
                import urllib.error
                import urllib.request
                context = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
                for token in (alpha.config(root)['alice'], alpha.config(root)['bob']):
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        opener.open(urllib.request.Request(realm + '/v0/messages', headers={'Authorization': 'Bearer ' + token}), timeout=5)
                    self.assertEqual(rejected.exception.code, 401)
                manager('stop')
                with alpha.lock(root), alpha.database(root):
                    saved = alpha.backup(root)
                    record = json.loads((saved / 'manifest.json').read_text())
                    restored = record['restore_database']
                    for table, order in (('envelopes', 'sequence'), ('room_state', 'id'), ('key_meta', 'id'), ('key_grants', 'slot')):
                        query = f'SELECT row_to_json(t) FROM (SELECT * FROM {table} ORDER BY {order}) t'
                        self.assertEqual(alpha.sql(root, query), alpha.sql(root, query, restored))
                    env = alpha.environment(root)
                    env['PARANOID_DATABASE_URL'] = env['PARANOID_DATABASE_URL'].replace('/postgres?', '/' + restored + '?')
                    restored_server = subprocess.Popen([release / 'paranoid-server'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        alpha.wait_health(root)
                        sync_all()  # Actual JNI/E2EE clients consume the isolated restored DB.
                        for phone in ('one', 'two'):
                            self.assertEqual(len(rpc(phone, 'view')['messages']), 3)
                    finally:
                        restored_server.terminate()
                        restored_server.wait(timeout=15)
                for item in ('tls/server.key', 'tls/server.crt'):
                    self.assertEqual(identity[item], (root / item).read_bytes())
                self.assertEqual(alpha.config(root), {**json.loads(identity['config.json']), 'deployment': 'key-v1'})
                print('PASS: packaged native systemd/PG16/pinned-TLS/JNI populated migration; two real key activations; private readiness; E2EE/receipts; post-update rows survive code rollback and JVM restart; complete four-table restore + real client sync; TLS/tokens retained. Not physical-phone evidence.')
            finally:
                if bridge is not None:
                    assert bridge.stdin is not None and bridge.stdout is not None
                    bridge.stdin.close()
                    bridge.wait(timeout=10)
                    bridge.stdout.close()
                if enabled:
                    manager('stop')
                    manager('disable')
                    alpha.command(['systemctl', '--user', 'daemon-reload'])


if __name__ == '__main__':
    unittest.main()
