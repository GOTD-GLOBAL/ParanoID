"""RFC-0020: push credential forwarding, entirely offline. The gateway is on exactly when the
reviewed config carries {"push": {"v": 1, "provider": "fcm"}} (flipped together with the unit by
`enable-push-v2`); the controller forwards a systemd credential path only, never key bytes."""
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
BASE = {'ip': '127.0.0.19', 'alice': 'a' * 64, 'bob': 'b' * 64, 'deployment': 'self-service-v2',
        'voice_turn': {'v': 1, 'relay_ip': '127.0.0.19'}}


class PushEnvironment(unittest.TestCase):
    def env(self, root, cfg, inherited):
        with contextlib.ExitStack() as stack:
            for name, value in (('config', cfg), ('current_release', root / 'release'), ('verify', {})):
                stack.enter_context(patch.object(alpha, name, return_value=value))
            stack.enter_context(patch.object(alpha, 'require_capability'))
            stack.enter_context(patch.dict(os.environ, inherited, clear=True))
            return alpha.environment(root)

    def test_settings_require_exact_v2_voice_shape(self):
        self.assertIsNone(alpha.push_settings(dict(BASE)))
        self.assertEqual(alpha.push_settings({**BASE, 'push': {'v': 1, 'provider': 'fcm'}}), {'v': 1, 'provider': 'fcm'})
        for bad in ({'v': 2, 'provider': 'fcm'}, {'v': 1, 'provider': 'apns'}, {'v': 1}, {'v': 1, 'provider': 'fcm', 'x': 1}, None, 'fcm'):
            with self.assertRaises(ValueError):
                alpha.push_settings({**BASE, 'push': bad})
        without_voice = {k: v for k, v in BASE.items() if k != 'voice_turn'}
        self.assertEqual(alpha.push_settings({**without_voice, 'push': {'v': 1, 'provider': 'fcm'}}), {'v': 1, 'provider': 'fcm'})
        with self.assertRaises(ValueError):
            alpha.push_settings({**BASE, 'deployment': 'key-v1', 'push': {'v': 1, 'provider': 'fcm'}})

    def test_off_by_default_then_exact_credential_forwarding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            credentials = root / 'credentials'
            credentials.mkdir(mode=0o700)
            turn = credentials / 'voice-turn-secret'
            turn.write_bytes(b'a' * 64)
            turn.chmod(0o400)
            inherited = {'CREDENTIALS_DIRECTORY': str(credentials), 'PARANOID_PUSH_CREDENTIAL_FILE': '/untrusted',
                         'PARANOID_PUSH_ENDPOINT': 'http://127.0.0.1:1/x'}
            # A credential file on disk alone never turns the gateway on.
            (root / 'push').mkdir(mode=0o700)
            (root / 'push/fcm-service-account.json').write_text(json.dumps(SA))
            loaded = credentials / 'push-fcm-credential'
            loaded.write_text(json.dumps(SA))
            loaded.chmod(0o400)
            env = self.env(root, dict(BASE), inherited)
            self.assertNotIn('PARANOID_PUSH_CREDENTIAL_FILE', env, 'config without push: gateway off, inherited value dropped')
            self.assertNotIn('PARANOID_PUSH_ENDPOINT', env, 'endpoint override never forwarded')
            cfg = {**BASE, 'push': {'v': 1, 'provider': 'fcm'}}
            env = self.env(root, cfg, inherited)
            self.assertEqual(env['PARANOID_PUSH_CREDENTIAL_FILE'], str(loaded))
            self.assertNotIn('PARANOID_PUSH_ENDPOINT', env)
            self.assertFalse(any('BEGIN PRIVATE KEY' in v for v in env.values()), 'key bytes never enter the environment')
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

    def test_unit_loads_credential_only_when_configured(self):
        root = Path('/home/paranoid/paranoid-alpha')
        with patch.object(alpha, 'config', return_value=dict(BASE)), patch.object(alpha, 'current_release'):
            self.assertNotIn('push-fcm-credential', alpha.unit(root))
        with patch.object(alpha, 'config', return_value={**BASE, 'push': {'v': 1, 'provider': 'fcm'}}), patch.object(alpha, 'current_release'):
            unit = alpha.unit(root)
        self.assertIn('LoadCredential=voice-turn-secret:' + str(root / 'voice-turn/issuer.secret'), unit)
        self.assertIn('LoadCredential=push-fcm-credential:' + str(root / 'push/fcm-service-account.json'), unit)
        self.assertNotIn('BEGIN PRIVATE KEY', unit)

    def test_config_accepts_push_key_only_with_voice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(alpha, 'installation'):
                for cfg, ok in (({**BASE, 'push': {'v': 1, 'provider': 'fcm'}}, True),
                                ({k: v for k, v in BASE.items() if k != 'voice_turn'} | {'push': {'v': 1, 'provider': 'fcm'}}, True),
                                ({**BASE, 'deployment': 'key-v1', 'push': {'v': 1, 'provider': 'fcm'}}, False),
                                ({**BASE, 'pushy': 1}, False)):
                    (root / 'config.json').write_text(json.dumps(cfg))
                    (root / 'config.json').chmod(0o600)
                    if ok:
                        self.assertEqual(alpha.config(root), cfg)
                    else:
                        with self.assertRaises(ValueError):
                            alpha.config(root)


if __name__ == '__main__':
    unittest.main()
