"""Real PG16 populated offline migration; synthetic private state only."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_native import load

HERE = Path(__file__).resolve().parent
alpha = load('migration_alpha', HERE / 'alpha.py')


class NativeMigration(unittest.TestCase):
    def test_existing_postmaster_cannot_be_adopted_by_offline_operation(self):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-pg-owner-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            release = Path(os.environ['PARANOID_KEY_RELEASE'])
            alpha.initialize(root, '127.0.0.1')
            alpha.point(root, alpha.stage(root, release))
            with alpha.database(root) as original:
                with self.assertRaises(RuntimeError), alpha.database(root):
                    self.fail('offline operation adopted somebody else\'s running PG')
                self.assertIsNone(original.poll())

    def test_unknown_actual_database_schema_refused_before_sticky_intent(self):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-key-drift-') as tmp:
            root = Path(tmp) / 'paranoid-alpha'
            release = Path(os.environ['PARANOID_KEY_RELEASE'])
            alpha.initialize(root, '127.0.0.1')
            alpha.point(root, alpha.stage(root, release))
            before = (root / 'config.json').read_bytes()
            with alpha.lock(root), alpha.database(root):
                alpha.sql(root, (release / 'schema.sql').read_text())
                alpha.sql(root, 'CREATE TABLE unexpected_state(id integer)')
            with self.assertRaises(ValueError):
                alpha.migrate_key(root, release)
            self.assertEqual((root / 'config.json').read_bytes(), before)

    def test_populated_migration_preserves_identity_and_blocks_downgrade(self):
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='paranoid-key-native-') as tmp:
            base = Path(tmp)
            release = Path(os.environ['PARANOID_KEY_RELEASE'])
            old = base / 'old'
            shutil.copytree(release, old)
            (old / 'key-schema.sql').unlink()
            manifest = json.loads((old / 'manifest.json').read_text())
            manifest['release'] = 'v0-fixture'
            manifest['schema_contract'] = 'paranoid-dev-v0'
            manifest.pop('deployment_api')
            del manifest['sha256']['key-schema.sql']
            if 'PARANOID_V0_BINARY' in os.environ:
                shutil.copy2(Path(os.environ['PARANOID_V0_BINARY']), old / 'paranoid-server')
                shutil.copy2(Path(os.environ['PARANOID_V0_CONTROLLER']), old / 'alpha.py')
                for member in ('paranoid-server', 'alpha.py'):
                    manifest['sha256'][member] = alpha.digest(old / member)
            (old / 'manifest.json').write_text(json.dumps(manifest))
            root = base / 'paranoid-alpha'
            alpha.initialize(root, '127.0.0.1')
            alpha.point(root, alpha.stage(root, old))
            identity = {n: (root / n).read_bytes() for n in ('config.json', 'tls/server.key', 'tls/server.crt')}
            with alpha.lock(root), alpha.database(root):
                alpha.sql(root, (old / 'schema.sql').read_text())
                alpha.sql(root, "INSERT INTO envelopes VALUES(1,0,1,'fixture',decode('010203','hex')); UPDATE room_state SET sequence=1,used_bytes=3")
            legacy_process = subprocess.Popen(['python3', old / 'alpha.py', 'run', '--root', root],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                alpha.wait_health(root)
            finally:
                legacy_process.terminate()
                legacy_process.wait(timeout=40)
            self.assertTrue(callable(getattr(alpha, 'migrate_key', None)), 'offline migration missing')
            from unittest.mock import patch
            before_pointer = (root / 'current').readlink()
            with patch.object(alpha, 'backup', side_effect=RuntimeError('injected restore failure')), self.assertRaises(RuntimeError):
                alpha.migrate_key(root, release)
            self.assertEqual((root / 'config.json').read_bytes(), identity['config.json'])
            self.assertEqual((root / 'current').readlink(), before_pointer)
            durable_config = alpha.atomic_config
            def crash_after_intent(root, value):
                durable_config(root, value)
                raise RuntimeError('injected crash after durable intent')
            with patch.object(alpha, 'atomic_config', side_effect=crash_after_intent), self.assertRaises(RuntimeError):
                alpha.migrate_key(root, release)
            with self.assertRaises(ValueError):
                alpha.environment(root)
            with alpha.lock(root), alpha.database(root):
                self.assertEqual(alpha.sql(root, "SELECT to_regclass('key_meta') IS NULL").strip(), b't')
            with patch.object(alpha, 'point', side_effect=RuntimeError('injected crash after schema commit')), self.assertRaises(RuntimeError):
                alpha.migrate_key(root, release)
            self.assertEqual((root / 'current').readlink(), before_pointer)
            alpha.migrate_key(root, release)
            self.assertEqual(alpha.config(root), {**json.loads(identity['config.json']), 'deployment': 'key-v1'})
            for name in ('tls/server.key', 'tls/server.crt'):
                self.assertEqual((root / name).read_bytes(), identity[name])
            with alpha.lock(root), alpha.database(root):
                self.assertEqual(alpha.sql(root, 'SELECT sequence,used_bytes FROM room_state').strip(), b'1|3')
                self.assertEqual(alpha.sql(root, 'SELECT count(*) FROM envelopes').strip(), b'1')
                self.assertEqual(alpha.sql(root, 'SELECT version FROM key_meta').strip(), b'1')
                rejected = subprocess.run([old / 'paranoid-server'], env={**alpha.environment(root), 'PARANOID_MODE': 'closed-alpha-v0'}, capture_output=True, timeout=10, check=False)
                self.assertNotEqual(rejected.returncode, 0)
            if 'PARANOID_V0_CONTROLLER' in os.environ:
                refused_controller = subprocess.run(['python3', old / 'alpha.py', 'health', '--root', root],
                                                    capture_output=True, timeout=10, check=False)
                self.assertNotEqual(refused_controller.returncode, 0)
            with self.assertRaises(ValueError):
                alpha.switch(root, old)
            # Idempotent CLI resume does not reinitialize tables or history.
            resumed = subprocess.run(['python3', HERE / 'alpha.py', 'migrate-key', '--root', root,
                                      '--release', release], capture_output=True, timeout=40, check=False)
            self.assertEqual(resumed.returncode, 0, resumed.stderr.decode())
            self.assertEqual(alpha.environment(root)['PARANOID_MODE'], 'closed-alpha-key-v1')
            self.assertEqual(alpha.environment(root)['PARANOID_REVIEWED_KEY_IP'], '127.0.0.1')
            with alpha.lock(root), alpha.database(root):
                for slot in (0, 1):
                    alpha.sql(root, f"INSERT INTO key_grants VALUES({slot},'grant{slot}','fixture-public','fp{slot}','acct{slot}','dev{slot}','auth{slot}',0,'active')")
            process = subprocess.Popen(['python3', HERE / 'alpha.py', 'run', '--root', root],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                alpha.wait_health(root)
                self.assertIsNone(process.poll())
            finally:
                process.terminate()
                process.wait(timeout=40)
            with alpha.lock(root), alpha.database(root):
                saved = alpha.backup(root)
                record = json.loads((saved / 'manifest.json').read_text())
                self.assertEqual(set(record.get('tables', [])), {'envelopes', 'room_state', 'key_meta', 'key_grants'})
                for name in identity:
                    copy = saved / 'identity' / name
                    self.assertEqual(copy.read_bytes(), (root / name).read_bytes())
                    self.assertEqual(record['identity_sha256'][name], alpha.digest(copy))
                native_command = alpha.command
                def corrupt_restored_grant(args, **kwargs):
                    output = native_command(args, **kwargs)
                    if str(args[0]).endswith('/pg_restore') and '--exit-on-error' in args:
                        restored_db = args[args.index('-d') + 1]
                        alpha.sql(root, "UPDATE key_grants SET mode='revoked' WHERE slot=0", restored_db)
                    return output
                with patch.object(alpha, 'command', side_effect=corrupt_restored_grant), self.assertRaises(RuntimeError):
                    alpha.backup(root)
                self.assertEqual(alpha.sql(root, "SELECT mode FROM key_grants WHERE slot=0").strip(), b'active')



if __name__ == '__main__':
    unittest.main()
