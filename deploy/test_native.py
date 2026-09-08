#!/usr/bin/env python3
"""REQ-DEPLOY-001/MSG-004/SEC-001: real PG/TLS lifecycle without systemd.

Builds a fresh bundle unless PARANOID_ALPHA_ARTIFACT selects an existing tar.
Only disposable synthetic state; no production connections or user-manager edits.
"""
import http.client
import importlib.util
import json
import os
import shutil
import socket
import ssl
import subprocess
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NativeLifecycle(unittest.TestCase):
    def test_archive_tls_history_update_and_code_rollback(self):
        os.umask(0o077)
        builder = load('builder', HERE / 'build.py')
        artifact = Path(os.environ['PARANOID_ALPHA_ARTIFACT']) if 'PARANOID_ALPHA_ARTIFACT' in os.environ else builder.main()
        with tempfile.TemporaryDirectory(prefix='paranoid-native-') as tmp:
            base = Path(tmp)
            with tarfile.open(artifact) as archive:
                expected = {'release/' + name for name in ('paranoid-server', 'schema.sql', 'alpha.py',
                                                           'create-test-tls.py', 'README.md', 'manifest.json')}
                self.assertEqual(set(archive.getnames()), expected)
                self.assertEqual(len(archive.getmembers()), len(expected))
                self.assertTrue(all(m.isfile() for m in archive.getmembers()))
                archive.extractall(base, filter='data')
            release = base / 'release'
            alpha = load('packaged_alpha', release / 'alpha.py')
            self.assertEqual(alpha.digest(artifact), artifact.with_suffix('.tar.sha256').read_text().split()[0])
            alpha.verify(release)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 38443))  # Refuse occupied test port.
            root = base / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.1')
            alpha.point(root, alpha.stage(root, release))
            cfg = alpha.config(root)
            identity = {n: (root / n).read_bytes() for n in ('config.json', 'tls/server.key', 'tls/server.crt')}
            ctx = ssl.create_default_context(cafile=str(root / 'tls/server.crt'))

            def request(method, path, payload=None):
                conn = http.client.HTTPSConnection('127.0.0.1', 38443, context=ctx, timeout=5)
                try:
                    conn.request(method, path, json.dumps(payload) if payload else None,
                                 {'Content-Type': 'application/json',
                                  'Authorization': 'Bearer ' + cfg['alice' if method == 'POST' else 'bob']})
                    response = conn.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    conn.close()

            def start():
                process = subprocess.Popen(['python3', release / 'alpha.py', 'run', '--root', root],
                                           env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    alpha.wait_health(root)
                except BaseException:
                    stop(process)
                    raise
                return process

            def stop(process):
                process.terminate()
                process.wait(timeout=40)

            envelope = {'id': str(uuid.uuid4()), 'recipient': 'bob', 'ciphertext': 'AQID'}
            process = start()
            try:
                ack = request('POST', '/v0/messages', envelope)
                self.assertEqual(ack[0], 200)
                self.assertEqual(request('POST', '/v0/messages', envelope), ack)
                self.assertEqual(len(request('GET', '/v0/messages?after=0')[1]['messages']), 1)
                with self.assertRaises(BlockingIOError):
                    alpha.switch(root, release)
            finally:
                stop(process)
            candidate = base / 'candidate'
            shutil.copytree(release, candidate)
            manifest = json.loads((candidate / 'manifest.json').read_text())
            manifest['release'] += '-native-test'
            (candidate / 'manifest.json').write_text(json.dumps(manifest))
            alpha.switch(root, candidate)
            process = start()
            try:
                envelope['id'] = str(uuid.uuid4())
                self.assertEqual(request('POST', '/v0/messages', envelope)[0], 200)
                page = request('GET', '/v0/messages?after=0')[1]
                self.assertEqual(len(page['messages']), 2)
            finally:
                stop(process)
            alpha.switch(root, release)
            process = start()
            try:
                self.assertEqual(request('GET', '/v0/messages?after=0')[1], page)
            finally:
                stop(process)
            manifests = list((root / 'backups').glob('*/manifest.json'))
            self.assertEqual(len(manifests), 2)
            for path in manifests:
                backup = json.loads(path.read_text())
                self.assertTrue(backup['verified'])
                self.assertEqual(backup['sha256'], alpha.digest(path.parent / 'history.dump'))
            self.assertEqual(identity, {n: (root / n).read_bytes() for n in identity})
            print('PASS: real archive/PG16/TLS/auth retry/live lock; same-binary update/code rollback '
                  'retain post-update history; two dump/restore/full-row comparisons; unchanged TLS/config; no systemd')


if __name__ == '__main__':
    unittest.main()
