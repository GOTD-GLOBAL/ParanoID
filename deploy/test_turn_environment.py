"""REQ-CALL-006: versioned controller credential forwarding, entirely offline."""
import contextlib
import os
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_native import load

alpha = load('turn_environment_alpha', Path(__file__).parent / 'alpha.py')


class TurnEnvironment(unittest.TestCase):
    def test_new_capability_refuses_an_old_or_mismatched_server(self):
        release = Path('/unused/release')
        current = json.dumps({'api': 1, 'issuer': 'signed-session-turn-v1'}).encode()
        controller = json.dumps(alpha.TURN_CONTROLLER_CAPABILITY).encode()
        with patch.object(alpha, 'command', side_effect=[current, controller]):
            alpha.voice_turn_capability(release)
        for server in (b'{}', b'{"api":1,"issuer":"old"}', current[:-1] + b',"extra":0}'):
            with patch.object(alpha, 'command', side_effect=[server, controller]):
                with self.assertRaises(ValueError):
                    alpha.voice_turn_capability(release)

    def env(self, root, cfg, inherited):
        with contextlib.ExitStack() as stack:
            for name, value in (('config', cfg), ('current_release', root / 'release'), ('verify', {})):
                stack.enter_context(patch.object(alpha, name, return_value=value))
            stack.enter_context(patch.object(alpha, 'require_capability'))
            stack.enter_context(patch.dict(os.environ, inherited, clear=True))
            return alpha.environment(root)

    def test_optional_config_and_exact_credential_forwarding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = {'ip': '127.0.0.19', 'alice': 'a' * 64, 'bob': 'b' * 64, 'deployment': 'self-service-v2'}
            credentials = root / 'credentials'
            credentials.mkdir(mode=0o700)
            secret = credentials / 'voice-turn-secret'
            secret.write_bytes(b'a' * 64)
            secret.chmod(0o400)
            inherited = {'CREDENTIALS_DIRECTORY': str(credentials),
                         'PARANOID_TURN_SECRET_FILE': '/untrusted', 'PARANOID_TURN_RELAY_IP': '8.8.8.8'}
            env = self.env(root, cfg, inherited)
            self.assertNotIn('PARANOID_TURN_SECRET_FILE', env)
            self.assertNotIn('PARANOID_TURN_RELAY_IP', env)
            cfg['voice_turn'] = {'v': 1, 'relay_ip': cfg['ip']}
            env = self.env(root, cfg, inherited)
            self.assertEqual(env['PARANOID_TURN_SECRET_FILE'], str(secret))
            self.assertEqual(env['PARANOID_TURN_RELAY_IP'], cfg['ip'])
            self.assertNotIn('a' * 64, env.values())
            secret.chmod(0o644)
            with self.assertRaises(ValueError):
                self.env(root, cfg, inherited)
            secret.unlink()
            secret.symlink_to('/dev/null')
            with self.assertRaises((OSError, ValueError)):
                self.env(root, cfg, inherited)
            with self.assertRaises(ValueError):
                self.env(root, cfg, {})

    def test_config_and_unit_versions(self):
        cfg = {'ip': '127.0.0.19', 'deployment': 'self-service-v2',
               'voice_turn': {'v': 1, 'relay_ip': '127.0.0.19'}}
        self.assertEqual(alpha.turn_settings(cfg), cfg['voice_turn'])
        for bad in ({'v': True, 'relay_ip': cfg['ip']}, {'v': 2, 'relay_ip': cfg['ip']},
                    {'v': 1, 'relay_ip': '8.8.8.8'}, {'v': 1, 'relay_ip': cfg['ip'], 'extra': 1}):
            with self.assertRaises(ValueError):
                alpha.turn_settings({**cfg, 'voice_turn': bad})
        with self.assertRaises(ValueError):
            alpha.turn_settings({**cfg, 'deployment': 'key-v1'})
        root = Path('/home/paranoid/paranoid-alpha')
        with patch.object(alpha, 'config', return_value=cfg), patch.object(alpha, 'current_release'):
            unit = alpha.unit(root)
        self.assertIn('LoadCredential=voice-turn-secret:' + str(root / 'voice-turn/issuer.secret'), unit)
        self.assertNotIn('a' * 64, unit)
        del cfg['voice_turn']
        with patch.object(alpha, 'config', return_value=cfg), patch.object(alpha, 'current_release'):
            self.assertNotIn('LoadCredential', alpha.unit(root))


if __name__ == '__main__':
    unittest.main()
