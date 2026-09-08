#!/usr/bin/env python3
"""REQ-DEPLOY-001/MSG-004/SEC-001: real systemd + PG + direct TLS lifecycle."""
import hashlib
import http.client
import importlib.util
import json
import os
import shutil
import signal
import ssl
import subprocess
import tarfile
import tempfile
import time
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('alpha', HERE / 'alpha.py')
assert spec and spec.loader
alpha = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alpha)


class Lifecycle(unittest.TestCase):
    def test_real_lifecycle(self):
        self.assertTrue((HERE / 'build.py').exists(), 'reproducible builder missing')
        self.assertTrue(hasattr(alpha, 'install'), 'guided installation command missing')
        built = subprocess.run(['python3', HERE / 'build.py'], check=True, capture_output=True, text=True)
        print(built.stdout, end='', flush=True)
        artifact = Path(next(line.removeprefix('Built ') for line in built.stdout.splitlines() if line.startswith('Built ')))
        release = artifact.parent / 'release'
        unit_name = 'paranoid-alpha-local-test.service'
        load = alpha.command(['systemctl', '--user', 'show', unit_name, '-p', 'LoadState']).decode()
        self.assertIn('not-found', load, 'refuse existing unit')
        with tempfile.TemporaryDirectory(prefix='paranoid-integration-') as temp:
            root = Path(temp) / 'paranoid-alpha'
            expected = artifact.with_suffix('.tar.sha256').read_text().split()[0]
            self.assertEqual(alpha.digest(artifact), expected)
            unpacked = Path(temp) / 'unpacked'
            with tarfile.open(artifact) as archive:
                archive.extractall(unpacked, filter='data')
            release = unpacked / 'release'
            alpha.verify(release)
            try:
                alpha.command(['python3', release / 'alpha.py', 'install', '--root', root,
                               '--ip', '127.0.0.1', '--release', release, '--unit-name', unit_name])
                self.assertEqual(alpha.command(['systemctl', '--user', 'is-enabled', unit_name]).strip(), b'enabled')
                self.wait(root)
                descriptor = json.loads((root / 'tls/public-connection.json').read_text())
                java = Path(temp) / 'java'
                java.mkdir()
                alpha.command(['javac', '-d', java, ROOT / 'clients/android/src/org/paranoid/text/PinnedTls.java',
                               HERE / 'PinnedEndpointSmoke.java'])
                print(alpha.command(['java', '-cp', java, 'PinnedEndpointSmoke',
                                     descriptor['server_url'], descriptor['tls_spki_sha256']]).decode().strip(), flush=True)
                cfg = alpha.config(root)
                for changes in ({'PARANOID_BIND': '127.0.0.1:38444'},
                                {'PARANOID_BIND': '127.0.0.2:38443', 'PARANOID_CI_TEST_DATABASE': '1'},
                                {'PARANOID_BIND': '127.0.0.2:38443', 'PARANOID_TLS_KEY': '/nonexistent-alpha-key'}):
                    env = alpha.environment(root)
                    env.update(changes)
                    rejected = subprocess.run([release / 'paranoid-server'], env=env,
                                              capture_output=True, timeout=3, check=False)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertNotIn(cfg['alice'].encode(), rejected.stderr)
                    self.assertNotIn(cfg['bob'].encode(), rejected.stderr)
                print('PASS: alpha wrong-port, CI-override and missing-key gates fail closed', flush=True)
                ctx = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))
                def request(method, path, payload=None, token=None, context=ctx):
                    conn = http.client.HTTPSConnection('127.0.0.1', 38443, context=context, timeout=5)
                    headers = {'Content-Type': 'application/json'}
                    if token:
                        headers['Authorization'] = 'Bearer ' + token
                    conn.request(method, path, json.dumps(payload) if payload else None, headers)
                    response = conn.getresponse()
                    status, body = response.status, response.read()
                    conn.close()
                    return status, json.loads(body)
                self.assertEqual(request('GET', '/v0/messages')[0], 401)
                with self.assertRaises(ssl.SSLError):
                    request('GET', '/health', context=ssl.create_default_context())
                plain = http.client.HTTPConnection('127.0.0.1', 38443, timeout=3)
                try:
                    plain.request('GET', '/health')
                    with self.assertRaises((ConnectionError, http.client.HTTPException, TimeoutError)):
                        plain.getresponse()
                finally:
                    plain.close()
                slow = http.client.HTTPSConnection('127.0.0.1', 38443, context=ctx, timeout=15)
                try:
                    slow.putrequest('POST', '/v0/messages')
                    slow.putheader('Content-Type', 'application/json')
                    slow.putheader('Content-Length', '100')
                    slow.putheader('Authorization', 'Bearer ' + cfg['alice'])
                    slow.endheaders()  # Deliberately withhold body: real timeout, no mutation.
                    self.assertEqual(slow.getresponse().status, 408)
                finally:
                    slow.close()
                statuses = [request('GET', '/health')[0] for _ in range(100)]
                self.assertIn(429, statuses, 'alpha ingress budget must reject bursts')
                time.sleep(1.1)
                envelope = {'id': str(uuid.uuid4()), 'recipient': 'bob', 'ciphertext': 'AQID'}
                ack = request('POST', '/v0/messages', envelope, cfg['alice'])
                self.assertEqual(ack[0], 200)
                self.assertEqual(request('POST', '/v0/messages', envelope, cfg['alice']), ack)
                page = request('GET', '/v0/messages?after=0', token=cfg['bob'])[1]
                self.assertEqual(len(page['messages']), 1)
                with self.assertRaises(BlockingIOError):
                    alpha.switch(root, release)
                print('PASS: unpacked/checksummed bundle CLI install+enable, direct TLS, trust/plaintext/auth rejection, rate budget, durable retry, live-update lock', flush=True)
                # Kill actual server child; unit restarts the whole group.
                pid = int(alpha.command(['systemctl', '--user', 'show', unit_name, '-p', 'MainPID', '--value']))
                children = Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
                server_pid = next(int(c) for c in children if Path(f'/proc/{c}/comm').read_text().strip() == 'paranoid-server')
                os.kill(server_pid, signal.SIGKILL)
                new_pid = pid
                for _ in range(100):
                    new_pid = int(alpha.command(['systemctl', '--user', 'show', unit_name, '-p', 'MainPID', '--value']))
                    if new_pid and new_pid != pid:
                        break
                    time.sleep(.1)
                self.assertNotEqual(new_pid, pid)
                self.wait(root)
                self.assertEqual(request('GET', '/v0/messages?after=0', token=cfg['bob'])[1], page)
                print('PASS: real systemd crash restart retains history', flush=True)
                alpha.command(['systemctl', '--user', 'stop', unit_name])
                # A separately identified same-schema artifact models a code release.
                candidate = Path(temp) / 'candidate'
                shutil.copytree(release, candidate)
                manifest = json.loads((candidate / 'manifest.json').read_text())
                manifest['release'] += '-update-test'
                (candidate / 'manifest.json').write_text(json.dumps(manifest))
                fragment = alpha.command(['systemctl', '--user', 'show', unit_name, '-p', 'FragmentPath', '--value']).decode().strip()
                self.assertEqual(Path(fragment).resolve(), root / unit_name)
                alpha.update(root, candidate, unit_name)
                self.wait(root)
                envelope['id'] = str(uuid.uuid4())
                self.assertEqual(request('POST', '/v0/messages', envelope, cfg['alice'])[0], 200)
                after_update = request('GET', '/v0/messages?after=0', token=cfg['bob'])[1]
                self.assertEqual(len(after_update['messages']), 2)
                alpha.command(['systemctl', '--user', 'stop', unit_name])
                alpha.update(root, release, unit_name)
                self.wait(root)
                self.assertEqual(request('GET', '/v0/messages?after=0', token=cfg['bob'])[1], after_update)
                backups = list((root / 'backups').glob('*/manifest.json'))
                self.assertEqual(len(backups), 2)
                for m in backups:
                    b = json.loads(m.read_text())
                    self.assertTrue(b['verified'])
                    self.assertEqual(hashlib.sha256((m.parent / 'history.dump').read_bytes()).hexdigest(), b['sha256'])
                self.assertEqual(alpha.config(root), cfg)
                old_pointer = (root / 'current').resolve()
                bad = Path(temp) / 'bad-schema'
                shutil.copytree(release, bad)
                bad_manifest = json.loads((bad / 'manifest.json').read_text())
                (bad / 'schema.sql').write_text('-- incompatible schema fixture\n')
                bad_manifest['sha256']['schema.sql'] = alpha.digest(bad / 'schema.sql')
                (bad / 'manifest.json').write_text(json.dumps(bad_manifest))
                with self.assertRaises(ValueError):
                    alpha.update(root, bad, unit_name)
                self.assertEqual((root / 'current').resolve(), old_pointer)
                self.wait(root)
                broken = Path(temp) / 'broken-binary'
                shutil.copytree(release, broken)
                m = json.loads((broken / 'manifest.json').read_text())
                m['release'] += '-broken-test'
                (broken / 'paranoid-server').write_bytes(b'intentional exec-format failure fixture\n')
                m['sha256']['paranoid-server'] = alpha.digest(broken / 'paranoid-server')
                (broken / 'manifest.json').write_text(json.dumps(m))
                with self.assertRaises(RuntimeError):
                    alpha.update(root, broken, unit_name)
                self.assertEqual((root / 'current').resolve(), old_pointer)
                self.assertEqual(request('GET', '/v0/messages?after=0', token=cfg['bob'])[1], after_update)
                print('PASS: incompatible schema refused before stop; broken executable update automatically returns to healthy previous release', flush=True)
                print('PASS: update + rollback retain post-update history, two dump restores/data comparisons/checksums, unchanged credentials/TLS', flush=True)
            finally:
                subprocess.run(['systemctl', '--user', 'stop', unit_name], check=False, capture_output=True)
                subprocess.run(['systemctl', '--user', 'disable', unit_name], check=False, capture_output=True)
                subprocess.run(['systemctl', '--user', 'daemon-reload'], check=False, capture_output=True)
                subprocess.run(['systemctl', '--user', 'reset-failed', unit_name], check=False, capture_output=True)

    def wait(self, root):
        for _ in range(200):
            try:
                alpha.health(root)
                return
            except (OSError, ValueError, TypeError, RuntimeError):
                time.sleep(.1)
        self.fail('TLS/database did not become ready')


if __name__ == '__main__':
    unittest.main()
