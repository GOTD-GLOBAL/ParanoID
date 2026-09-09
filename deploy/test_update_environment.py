"""REQ-CLIENT-003/DEPLOY-001: v2-only optional feed environment, no publication.

Unit scope: isolate already-tested config/release capability I/O; exercise the
real environment builder and clean_env. Packaged native TLS checks are separate.
"""
import contextlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_native import load

HERE = Path(__file__).resolve().parent
alpha = load('update_environment_alpha',
             (Path(os.environ['PARANOID_V2_RELEASE'])
              if os.environ.get('PARANOID_TEST_PACKAGED') == '1' else HERE) / 'alpha.py')


class UpdateEnvironment(unittest.TestCase):
    def environment(self, root, deployment=None):
        config = {'ip': '127.0.0.19', 'alice': 'a' * 64, 'bob': 'b' * 64}
        if deployment is not None:
            config['deployment'] = deployment
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(alpha, 'config', return_value=config))
            stack.enter_context(patch.object(alpha, 'current_release', return_value=root / 'release'))
            stack.enter_context(patch.object(alpha, 'verify', return_value={}))
            stack.enter_context(patch.object(alpha, 'require_capability'))
            stack.enter_context(patch.dict(os.environ, {'PARANOID_ANDROID_UPDATE_ROOT': '/untrusted/inherited'}))
            return alpha.environment(root)

    def test_v2_selects_own_missing_feed_without_creating_it(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-update-env-') as tmp:
            root = Path(tmp)
            before = list(root.iterdir())
            env = self.environment(root, 'self-service-v2')
            self.assertEqual(env.get('PARANOID_ANDROID_UPDATE_ROOT'), str(root / 'updates'))
            self.assertEqual(env['PARANOID_MODE'], 'self-service-v2')
            self.assertEqual(env['PARANOID_REVIEWED_SELF_SERVICE_IP'], '127.0.0.19')
            self.assertNotIn('PARANOID_ALICE_TOKEN', env)
            self.assertNotIn('PARANOID_BOB_TOKEN', env)
            self.assertEqual(list(root.iterdir()), before)
            self.assertFalse((root / 'updates').exists())

    def test_legacy_modes_do_not_inherit_feed_and_keep_existing_authority(self):
        root = Path('/unused/private-fixture')
        for deployment, mode in ((None, 'closed-alpha-v0'), ('key-v1', 'closed-alpha-key-v1')):
            with self.subTest(deployment=deployment):
                env = self.environment(root, deployment)
                self.assertNotIn('PARANOID_ANDROID_UPDATE_ROOT', env)
                self.assertEqual(env['PARANOID_MODE'], mode)
                self.assertEqual(env['PARANOID_ALICE_TOKEN'], 'a' * 64)
                self.assertEqual(env['PARANOID_BOB_TOKEN'], 'b' * 64)
                self.assertEqual(env.get('PARANOID_REVIEWED_KEY_IP'), '127.0.0.19' if deployment else None)
                self.assertNotIn('PARANOID_REVIEWED_SELF_SERVICE_IP', env)


if __name__ == '__main__':
    unittest.main()
