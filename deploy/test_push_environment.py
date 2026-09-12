"""RFC-0020: push credential forwarding, entirely offline. The controller forwards a
path only; the gateway is on exactly when the operator placed the service-account
file under <root>/push/ and systemd loaded it as a credential."""
import contextlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_native import load

alpha = load('push_environment_alpha', Path(__file__).parent / 'alpha.py')

SA = {'type': 'service_account', 'project_id': 'para-no-id', 'private_key': '-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n',
      'client_email': 'gw@para-no-id.iam.gserviceaccount.com', 'token_uri': 'https://oauth2.googleapis.com/token'}


class PushEnvironment(unittest.TestCase):
    def env(self, root, cfg, inherited):
        with contextlib.ExitStack() as stack:
            for name, value in (('config', cfg), ('current_release', root / 'release'), ('verify', {})):
                stack.enter_context(patch.object(alpha, name, return_value=value))
            stack.enter_context(patch.object(alpha, 'require_capability'))
            stack.enter_context(patch.dict(os.environ, inherited, clear=True))
            return alpha.environment(root)

    def test_off_by_default_then_exact_credential_forwarding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = {'ip': '127.0.0.19', 'alice': 'a' * 64, 'bob': 'b' * 64, 'deployment': 'self-service-v2'}
            credentials = root / 'credentials'
            credentials.mkdir(mode=0o700)
            inherited = {'CREDENTIALS_DIRECTORY': str(credentials), 'PARANOID_PUSH_CREDENTIAL_FILE': '/untrusted',
                         'PARANOID_PUSH_ENDPOINT': 'http://127.0.0.1:1/x'}
            env = self.env(root, cfg, inherited)
            self.assertNotIn('PARANOID_PUSH_CREDENTIAL_FILE', env, 'no push file: gateway off, inherited value dropped')
            self.assertNotIn('PARANOID_PUSH_ENDPOINT', env, 'endpoint override never forwarded')
            # Operator placed the file; systemd loaded it.
            (root / 'push').mkdir(mode=0o700)
            (root / 'push/fcm-service-account.json').write_text(json.dumps(SA))
            loaded = credentials / 'push-fcm-credential'
            loaded.write_text(json.dumps(SA))
            loaded.chmod(0o400)
            env = self.env(root, cfg, inherited)
            self.assertEqual(env['PARANOID_PUSH_CREDENTIAL_FILE'], str(loaded))
            self.assertNotIn('PARANOID_PUSH_ENDPOINT', env)
            self.assertFalse(any('BEGIN PRIVATE KEY' in v for v in env.values()), 'key bytes never enter the environment')
            # Wrong shapes fail closed.
            loaded.chmod(0o644)
            with self.assertRaises(ValueError):
                self.env(root, cfg, inherited)
            loaded.chmod(0o400)
            for bad in ({**SA, 'type': 'authorized_user'}, {**SA, 'token_uri': 'http://evil/token'}, 'not json', {}):
                loaded.chmod(0o600)
                loaded.write_text(bad if isinstance(bad, str) else json.dumps(bad))
                loaded.chmod(0o400)
                with self.assertRaises(ValueError):
                    self.env(root, cfg, inherited)
            loaded.unlink()
            loaded.symlink_to('/dev/null')
            with self.assertRaises((OSError, ValueError)):
                self.env(root, cfg, inherited)
            with self.assertRaises(ValueError):
                self.env(root, cfg, {})

    def test_unit_loads_credential_only_when_file_present(self):
        cfg = {'ip': '127.0.0.19', 'deployment': 'self-service-v2'}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(alpha, 'config', return_value=cfg), patch.object(alpha, 'current_release'):
                self.assertNotIn('push-fcm-credential', alpha.unit(root))
                (root / 'push').mkdir(mode=0o700)
                (root / 'push/fcm-service-account.json').write_text(json.dumps(SA))
                unit = alpha.unit(root)
            self.assertIn('LoadCredential=push-fcm-credential:' + str(root / 'push/fcm-service-account.json'), unit)
            self.assertNotIn('BEGIN PRIVATE KEY', unit)


if __name__ == '__main__':
    unittest.main()
