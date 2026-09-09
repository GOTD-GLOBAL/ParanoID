"""REQ-ID-006/DEPLOY-001: strict bounded migration capability gates."""
import json
import unittest
from pathlib import Path
from typing import Any

import test_containment

alpha = test_containment.alpha


class MigrationGates(unittest.TestCase):
    root: Path
    release: Path
    cfg: dict[str, str]
    manifest: dict[str, Any]
    setUp = test_containment.ContainmentTests.setUp

    def test_failed_update_and_failed_rollback_leave_service_stopped(self):
        from unittest.mock import patch
        alpha.point(self.root, alpha.stage(self.root, self.release))
        calls = []
        def systemd(args, **kwargs):
            calls.append(args)
            return str(self.root / 'paranoid-alpha.service').encode() if 'show' in args else b''
        with patch.object(alpha, 'command', side_effect=systemd), \
                patch.object(alpha, 'switch_offline'), \
                patch.object(alpha, 'wait_health', side_effect=RuntimeError('injected readiness failure')), \
                self.assertRaises(RuntimeError):
            alpha.update(self.root, self.release)
        self.assertEqual(calls[-1], ['systemctl', '--user', 'stop', 'paranoid-alpha.service'])

    def test_old_controller_rejected_even_with_new_binary(self):
        for name in ('schema.sql', 'key-schema.sql'):
            (self.release / name).write_bytes((alpha.HERE.parent / 'server' / name).read_bytes())
            self.manifest['sha256'][name] = alpha.digest(self.release / name)
        self.manifest.update(schema_contract='paranoid-key-v1', deployment_api=1)
        capability = {'deployment_api': 1, 'runtime': 'key-v1-local-lock-close-v1',
                      'schema': alpha.V0_SCHEMA, 'key_schema': alpha.KEY_SCHEMA}
        (self.release / 'paranoid-server').write_text('#!/usr/bin/python3\nprint(' + repr(json.dumps(capability)) + ')\n')
        (self.release / 'paranoid-server').chmod(0o700)
        (self.release / 'alpha.py').write_text("print('{}')\n")
        for name in ('paranoid-server', 'alpha.py'):
            self.manifest['sha256'][name] = alpha.digest(self.release / name)
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        alpha.point(self.root, alpha.stage(self.root, self.release))
        (self.root / 'config.json').write_text(json.dumps({**self.cfg, 'deployment': 'key-v1'}))
        with self.assertRaises(ValueError):
            alpha.candidate(self.root, self.release)

    def test_key_config_rejects_old_binary_even_with_key_manifest(self):
        for name in ('schema.sql', 'key-schema.sql'):
            (self.release / name).write_bytes((alpha.HERE.parent / 'server' / name).read_bytes())
            self.manifest['sha256'][name] = alpha.digest(self.release / name)
        self.manifest.update(schema_contract='paranoid-key-v1', deployment_api=1)
        (self.release / 'paranoid-server').write_text("#!/usr/bin/python3\nprint('{}')\n")
        (self.release / 'paranoid-server').chmod(0o700)
        self.manifest['sha256']['paranoid-server'] = alpha.digest(self.release / 'paranoid-server')
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        alpha.point(self.root, alpha.stage(self.root, self.release))
        (self.root / 'config.json').write_text(json.dumps({**self.cfg, 'deployment': 'key-v1'}))
        with self.assertRaises(ValueError):
            alpha.candidate(self.root, self.release)
        with self.assertRaises(ValueError):
            alpha.environment(self.root)
        with self.assertRaises(ValueError):
            alpha.point(self.root, alpha.current_release(self.root))

    def test_concurrent_operator_rejected_before_service_stop(self):
        import fcntl
        from unittest.mock import patch
        alpha.point(self.root, alpha.stage(self.root, self.release))
        with alpha.regular_file(self.root / 'operation.lock', alpha.os.O_RDWR | alpha.os.O_CREAT, restricted=True) as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(alpha, 'command', side_effect=AssertionError('must reject before service command')):
                with self.assertRaises(BlockingIOError):
                    alpha.update(self.root, self.release)
                with self.assertRaises(BlockingIOError):
                    alpha.switch(self.root, self.release)

    def test_changed_key_schema_is_not_a_compatible_rollback(self):
        (self.release / 'schema.sql').write_bytes((alpha.HERE.parent / 'server/schema.sql').read_bytes())
        (self.release / 'key-schema.sql').write_bytes((alpha.HERE.parent / 'server/key-schema.sql').read_bytes())
        self.manifest.update(schema_contract='paranoid-key-v1', deployment_api=1)
        for name in ('schema.sql', 'key-schema.sql'):
            self.manifest['sha256'][name] = alpha.digest(self.release / name)
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        alpha.point(self.root, alpha.stage(self.root, self.release))
        (self.root / 'config.json').write_text(json.dumps({**self.cfg, 'deployment': 'key-v1'}))
        self.manifest['release'] = 'changed-key'
        (self.release / 'key-schema.sql').write_text('arbitrary schema')
        self.manifest['sha256']['key-schema.sql'] = alpha.digest(self.release / 'key-schema.sql')
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaises(ValueError):
            alpha.candidate(self.root, self.release)

    def test_sticky_config_blocks_old_code_and_retains_tokens(self):
        target = alpha.stage(self.root, self.release)
        alpha.point(self.root, target)
        upgraded = {**self.cfg, 'deployment': 'key-v1'}
        (self.root / 'config.json').write_text(json.dumps(upgraded))
        self.assertEqual(alpha.config(self.root), upgraded)
        with self.assertRaises(ValueError):
            alpha.environment(self.root)
        with self.assertRaises(ValueError):
            alpha.point(self.root, target)
        with self.assertRaises(ValueError):
            alpha.candidate(self.root, self.release)
        upgraded['deployment'] = 'key-v2'
        (self.root / 'config.json').write_text(json.dumps(upgraded))
        with self.assertRaises(ValueError):
            alpha.config(self.root)

    def test_key_bundle_is_explicit_and_unknown_capabilities_fail(self):
        (self.release / 'key-schema.sql').write_bytes((alpha.HERE.parent / 'server/key-schema.sql').read_bytes())
        self.manifest.update(schema_contract='paranoid-key-v1', deployment_api=1)
        self.manifest['sha256']['key-schema.sql'] = alpha.digest(self.release / 'key-schema.sql')
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        self.assertEqual(alpha.verify(self.release), self.manifest)
        self.manifest['deployment_api'] = 2
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaises(ValueError):
            alpha.verify(self.release)


if __name__ == '__main__':
    unittest.main()
