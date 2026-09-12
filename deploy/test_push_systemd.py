"""RFC-0020: real local systemd/PG/TLS `enable-push-v2` on a v2 fixture — config+unit flip together, the
process sees only a credential path, failed readiness restores the exact previous config/unit, and the
gateway is never on without both the config key and the 0400 operator file. Local user manager only."""
import json
import os
import secrets
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

import test_v2_update as fixtures

alpha = fixtures.alpha
SA = {'type': 'service_account', 'project_id': 'para-no-id', 'private_key': '-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n',
      'client_email': 'gw@para-no-id.iam.gserviceaccount.com', 'token_uri': 'https://oauth2.googleapis.com/token'}


class EnablePushV2(unittest.TestCase):
    def test_actual_unit_flip_credential_only_and_failed_health_restore(self):
        f = fixtures.SafeV2Update()
        f.setUp()
        root = f.root
        name = 'paranoid-alpha-push-test-' + secrets.token_hex(4) + '.service'
        created = False
        try:
            # Candidate carries this controller (and, when packaged, the real runtime). The loopback
            # fixture cannot enable voice (public-mode server refuses a loopback relay), so push is
            # exercised on the plain v2 shape; production additionally carries voice_turn.
            candidate = f.make_candidate()
            with alpha.lock(root):
                alpha.point_v2(root, alpha.stage(root, candidate))
            (root / name).write_text(alpha.unit(root))
            created = True
            alpha.command(['systemctl', '--user', 'enable', '--now', root / name])
            alpha.wait_health(root)
            before_unit = (root / name).read_bytes()
            before_config = (root / 'config.json').read_bytes()
            # No operator file -> refused, nothing changed, service still healthy.
            with self.assertRaises((OSError, ValueError)):
                alpha.enable_push_v2(root, name)
            self.assertEqual((root / 'config.json').read_bytes(), before_config)
            (root / 'push').mkdir(mode=0o700)
            cred = root / 'push/fcm-service-account.json'
            cred.write_text(json.dumps(SA))
            cred.chmod(0o600)
            with self.assertRaises(ValueError):
                alpha.enable_push_v2(root, name)  # wrong mode
            cred.chmod(0o400)
            # Injected readiness failure after the flip -> exact previous config/unit restored, service active.
            original = alpha.wait_health
            calls = []
            def fail_once(checked_root):
                original(checked_root)
                if not calls:
                    calls.append(True)
                    raise RuntimeError('injected readiness failure')
            with patch.object(alpha, 'wait_health', side_effect=fail_once), self.assertRaisesRegex(RuntimeError, 'previous exact config/unit restored'):
                alpha.enable_push_v2(root, name)
            self.assertEqual((root / 'config.json').read_bytes(), before_config)
            self.assertEqual((root / name).read_bytes(), before_unit)
            self.assertEqual(alpha.command(['systemctl', '--user', 'is-active', name]).strip(), b'active')
            self.assertFalse((root / 'config.pending').exists())
            # Real enable.
            alpha.enable_push_v2(root, name)
            self.assertEqual(alpha.config(root)['push'], {'v': 1, 'provider': 'fcm'})
            unit = (root / name).read_text()
            self.assertIn('LoadCredential=push-fcm-credential:' + str(cred), unit)
            self.assertNotIn('voice-turn-secret', unit)
            self.assertNotIn('BEGIN PRIVATE KEY', unit)
            self.assertEqual(alpha.command(['systemctl', '--user', 'is-active', name]).strip(), b'active')
            alpha.health(root)
            # The running process received the credential path only, and the key bytes never appear in its environment.
            pid = alpha.command(['systemctl', '--user', 'show', name, '-p', 'MainPID', '--value']).strip().decode()
            environ = Path('/proc', pid, 'environ').read_bytes()
            self.assertNotIn(b'BEGIN PRIVATE KEY', environ)
            children = subprocess.run(['pgrep', '-P', pid], capture_output=True, text=True).stdout.split()
            saw_path = False
            for child in children:
                env = Path('/proc', child, 'environ').read_bytes()
                self.assertNotIn(b'BEGIN PRIVATE KEY', env)
                if b'PARANOID_PUSH_CREDENTIAL_FILE=' in env:
                    saw_path = True
                    value = [e for e in env.split(b'\0') if e.startswith(b'PARANOID_PUSH_CREDENTIAL_FILE=')][0]
                    self.assertTrue(value.endswith(b'/push-fcm-credential'), value)
            self.assertTrue(saw_path, 'server child must receive the systemd credential path')
            # Idempotence guard.
            with self.assertRaisesRegex(ValueError, 'already enabled'):
                alpha.enable_push_v2(root, name)
            # PG cluster and TLS identity unchanged; config changed exactly by the push key.
            self.assertEqual(f.identifier, alpha.cluster_identifier(root))
            for n in ('tls/server.key', 'tls/server.crt'):
                self.assertEqual(f.identity[n], __import__('hashlib').sha256((root / n).read_bytes()).hexdigest())
            self.assertEqual(alpha.config(root), {**json.loads(before_config), 'push': {'v': 1, 'provider': 'fcm'}})
            print('PASS actual enable-push-v2: refused without file/mode, failed-health exact restore, credential path only, same PG/TLS identity')
        finally:
            if created:
                alpha.command(['systemctl', '--user', 'stop', name])
                alpha.command(['systemctl', '--user', 'disable', name])
                subprocess.run(['systemctl', '--user', 'reset-failed', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                print('CLEANUP stopped/disabled only ' + name)
            f.tearDown()


if __name__ == '__main__':
    unittest.main()
