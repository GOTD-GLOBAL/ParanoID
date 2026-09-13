"""REQ-MSG-004/DEPLOY-001/SEC-001: real same-v2 encrypted backup and rollback.

All database operations use a newly initialized private temporary PostgreSQL
cluster. No systemd or remote host calls. Old release is an immutable v2 bundle;
controller under test is this worktree unless PARANOID_TEST_PACKAGED selects a
coordinator-built candidate. Synthetic payload bytes are not E2EE evidence.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_native import load

HERE = Path(__file__).resolve().parent
OLD = Path(os.environ.get('PARANOID_V2_OLD_RELEASE', '/home/codex/paranoid-self-service-evidence/server-build-zeu65f67/release'))
CONTROLLER = (Path(os.environ['PARANOID_V2_RELEASE']) if os.environ.get('PARANOID_TEST_PACKAGED') == '1' else HERE) / 'alpha.py'
alpha = load('safe_v2_alpha', CONTROLLER)


class SafeV2Update(unittest.TestCase):
    def setUp(self):
        os.umask(0o077)
        self.temp = tempfile.TemporaryDirectory(prefix='paranoid-safe-v2-')
        self.base = Path(self.temp.name)
        self.root = self.base / 'paranoid-alpha'
        alpha.initialize(self.root, '127.0.0.23')
        alpha.point(self.root, alpha.stage(self.root, OLD))
        alpha.fresh_v2(self.root, OLD, '127.0.0.23')
        self.identifier = alpha.cluster_identifier(self.root)
        self.identity = {n: hashlib.sha256((self.root / n).read_bytes()).hexdigest()
                         for n in ('config.json', 'tls/server.key', 'tls/server.crt')}
        self.old_pointer = (self.root / 'current').readlink()
        with alpha.lock(self.root), alpha.database(self.root):
            alpha.sql(self.root, "INSERT INTO ss_accounts VALUES ('a','root-a','active'), ('b','root-b','revoked'); "
                      "INSERT INTO ss_devices VALUES ('a','da','aa','fa','ca'),('b','db','ab','fb','cb'); "
                      "INSERT INTO ss_conversations VALUES('a','b'); "
                      "INSERT INTO ss_messages VALUES(1,'a','b','first',decode('010203','hex'),'a','b'); "
                      "UPDATE ss_meta SET sequence=1,registration_window=1720000000,registrations=2")

    def tearDown(self):
        self.assertFalse((self.root / 'data/postmaster.pid').exists(), 'fixture left its own PG alive')
        self.temp.cleanup()

    def make_candidate(self):
        release = self.base / 'candidate'
        source = Path(os.environ['PARANOID_V2_RELEASE']) if os.environ.get('PARANOID_TEST_PACKAGED') == '1' else OLD
        shutil.copytree(source, release)
        release.chmod(0o700)
        for member in release.iterdir():
            member.chmod(0o700 if member.name == 'paranoid-server' else 0o600)
        # Coordinator-packaged runs use the actual final candidate runtime;
        # source-only development uses old runtime without a shared Cargo build.
        shutil.copy2(CONTROLLER, release / 'alpha.py')
        manifest = json.loads((release / 'manifest.json').read_text())
        manifest['sha256']['alpha.py'] = alpha.digest(release / 'alpha.py')
        manifest['release'] = hashlib.sha256(json.dumps(manifest['sha256'], sort_keys=True).encode()).hexdigest()[:20]
        (release / 'manifest.json').write_text(json.dumps(manifest))
        alpha.verify(release)
        return release

    def test_optional_push_schema_matches_runtime_contract(self):
        source=(HERE.parent/'server/src/self_service_http.rs').read_text()
        self.assertIn(alpha.PUSH_TABLE_SQL.replace('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ',1),source)

    def add_push_fixture(self):
        alpha.sql(self.root, "CREATE TABLE ss_push_tokens(account TEXT PRIMARY KEY REFERENCES ss_accounts(account),device TEXT NOT NULL REFERENCES ss_devices(device),platform TEXT NOT NULL CHECK(platform='fcm'),token TEXT NOT NULL CHECK(octet_length(token) BETWEEN 1 AND 4096),updated BIGINT NOT NULL CHECK(updated>0))")
        alpha.sql(self.root, "INSERT INTO ss_push_tokens VALUES ('a','da','fcm','synthetic-not-a-real-token',1)")

    def test_optional_push_schema_and_rows_are_verified_in_encrypted_restore(self):
        with alpha.lock(self.root), alpha.database(self.root):
            self.add_push_fixture()
            destination=alpha.backup_v2(self.root)
            record=json.loads((destination/'manifest.json').read_text())
            self.assertTrue(record['verified'])
            self.assertIn('ss_push_tokens',record['tables'])
            self.assertTrue(record['row_digests']['ss_push_tokens'].startswith('1|'))
            self.assertEqual(alpha.v2_rows(self.root),alpha.v2_rows(self.root,record['restore_database']))
            # Verification must not merely restore rows: it must detect a changed
            # push token without printing it or replacing the current database.
            before=alpha.v2_rows(self.root)
            alpha.sql(self.root,"UPDATE ss_push_tokens SET token='changed-synthetic-token'")
            with self.assertRaises(RuntimeError):alpha.verify_v2_backup(self.root,destination)
            self.assertNotEqual(before['ss_push_tokens'],alpha.v2_rows(self.root)['ss_push_tokens'])

    def test_optional_push_schema_drift_is_still_rejected(self):
        with alpha.lock(self.root), alpha.database(self.root):
            self.add_push_fixture()
            alpha.sql(self.root,"ALTER TABLE ss_push_tokens ADD COLUMN unreviewed TEXT")
            with self.assertRaises(ValueError):alpha.backup_v2(self.root)

    def assert_identity(self):
        self.assertEqual(self.identifier, alpha.cluster_identifier(self.root))
        self.assertEqual(self.identity, {n: hashlib.sha256((self.root / n).read_bytes()).hexdigest() for n in self.identity})

    def test_real_encrypted_archive_restore_preserves_all_rows_and_revocation(self):
        with alpha.lock(self.root), alpha.database(self.root):
            archive = alpha.backup_v2(self.root)
            manifest = json.loads((archive / 'manifest.json').read_text())
            self.assertTrue(manifest['verified'])
            self.assertEqual(manifest['pg_system_id'], self.identifier)
            self.assertEqual(set(manifest['tables']), {'room_state', 'ss_meta', 'ss_accounts', 'ss_devices', 'ss_conversations', 'ss_messages'})
            self.assertNotEqual(manifest['restore_database'], 'postgres')
            restored = manifest['restore_database']
            self.assertEqual(alpha.sql(self.root, "SELECT mode FROM ss_accounts WHERE account='b'", restored).strip(), b'revoked')
            self.assertEqual(alpha.sql(self.root, 'SELECT sequence,registrations FROM ss_meta', restored).strip(), b'1|2')
            self.assertEqual(alpha.sql(self.root, "SELECT encode(ciphertext,'hex') FROM ss_messages", restored).strip(), b'010203')
            self.assertEqual(alpha.schema_snapshot(self.root, 'postgres'), alpha.schema_snapshot(self.root, restored))
        self.assertEqual(set(p.name for p in archive.iterdir()), {'history.enc', 'manifest.json'})
        self.assertEqual((self.root / 'backup.key').stat().st_mode & 0o777, 0o600)
        self.assertEqual((archive / 'history.enc').stat().st_mode & 0o777, 0o600)
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertNotIn(b'PGDMP', (archive / 'history.enc').read_bytes())
        self.assertNotIn(b'root-a', (archive / 'history.enc').read_bytes())
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        self.assert_identity()

    def test_failed_restore_comparison_aborts_cutover_preserves_live_rows(self):
        candidate = self.make_candidate()
        original = alpha.command
        def corrupt_restore(args, **kwargs):
            result = original(args, **kwargs)
            if str(args[0]).endswith('/pg_restore') and '--exit-on-error' in args:
                restored = args[args.index('-d') + 1]
                self.assertNotEqual(restored, 'postgres')
                alpha.sql(self.root, "UPDATE ss_accounts SET mode='active' WHERE account='b'", restored)
            return result
        with patch.object(alpha, 'command', side_effect=corrupt_restore), self.assertRaises(RuntimeError):
            alpha.switch_v2_offline(self.root, candidate, self.identifier)
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        with alpha.lock(self.root), alpha.database(self.root):
            self.assertEqual(alpha.sql(self.root, "SELECT mode FROM ss_accounts WHERE account='b'").strip(), b'revoked')
            self.assertEqual(alpha.sql(self.root, 'SELECT count(*) FROM ss_messages').strip(), b'1')
        self.assert_identity()

    def test_same_data_code_rollback_keeps_post_update_messages(self):
        candidate = self.make_candidate()
        alpha.switch_v2_offline(self.root, candidate, self.identifier)
        self.assertNotEqual(self.old_pointer, (self.root / 'current').readlink())
        with alpha.lock(self.root), alpha.database(self.root):
            alpha.sql(self.root, "INSERT INTO ss_messages VALUES(2,'a','b','post-update',decode('040506','hex'),'a','b'); UPDATE ss_meta SET sequence=2")
        alpha.switch_v2_offline(self.root, OLD, self.identifier)
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        with alpha.lock(self.root), alpha.database(self.root):
            self.assertEqual(alpha.sql(self.root, 'SELECT sequence FROM ss_messages ORDER BY sequence').strip(), b'1\n2')
            self.assertEqual(alpha.sql(self.root, 'SELECT sequence FROM ss_meta').strip(), b'2')
            self.assertEqual(alpha.sql(self.root, "SELECT mode FROM ss_accounts WHERE account='b'").strip(), b'revoked')
        self.assert_identity()

    def test_wrong_cluster_or_held_lock_refuses_without_cutover_or_backup(self):
        candidate = self.make_candidate()
        with self.assertRaises(ValueError):
            alpha.switch_v2_offline(self.root, candidate, '1')
        with alpha.lock(self.root), self.assertRaises(BlockingIOError):
            alpha.switch_v2_offline(self.root, candidate, self.identifier)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])
        self.assertFalse((self.root / 'backup.key').exists())
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        self.assert_identity()

    def test_wrong_schema_or_changed_component_refuses_before_backup(self):
        candidate = self.make_candidate()
        (candidate / 'self-service-schema.sql').write_text('CREATE TABLE altered(id integer);')
        manifest = json.loads((candidate / 'manifest.json').read_text())
        manifest['sha256']['self-service-schema.sql'] = alpha.digest(candidate / 'self-service-schema.sql')
        (candidate / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            alpha.switch_v2_offline(self.root, candidate, self.identifier)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())

    def test_existing_backup_key_is_never_followed_or_overwritten(self):
        elsewhere = self.base / 'protected-key'
        elsewhere.write_bytes(b'preserved bytes')
        (self.root / 'backup.key').symlink_to(elsewhere)
        with alpha.lock(self.root), alpha.database(self.root), self.assertRaises((ValueError, OSError)):
            alpha.backup_v2(self.root)
        self.assertEqual(elsewhere.read_bytes(), b'preserved bytes')
        self.assertEqual(list((self.root / 'backups').iterdir()), [])



    def test_corrupt_encrypted_archive_rejects_before_any_restore(self):
        with alpha.lock(self.root), alpha.database(self.root):
            archive = alpha.backup_v2(self.root)
            original = (archive / 'history.enc').read_bytes()
            cases = {'truncated': original[:-17],
                     'changed_tag': original[:-1] + bytes([original[-1] ^ 1]),
                     'changed_header': bytes([original[0] ^ 1]) + original[1:]}
            before_databases = alpha.sql(self.root, 'SELECT datname FROM pg_database ORDER BY datname')
            for kind, damaged in cases.items():
                with self.subTest(kind=kind):
                    (archive / 'history.enc').write_bytes(damaged)
                    with self.assertRaises((ValueError, RuntimeError)):
                        alpha.verify_v2_backup(self.root, archive)
                    self.assertEqual(alpha.sql(self.root, 'SELECT datname FROM pg_database ORDER BY datname'), before_databases)
            (archive / 'history.enc').write_bytes(original)
            key = (self.root / 'backup.key').read_bytes()
            (self.root / 'backup.key').write_bytes(bytes(x ^ 1 for x in key))
            with self.assertRaises((ValueError, RuntimeError)):
                alpha.verify_v2_backup(self.root, archive)
            (self.root / 'backup.key').write_bytes(key)
            self.assertEqual(alpha.sql(self.root, 'SELECT datname FROM pg_database ORDER BY datname'), before_databases)

    def test_same_schema_binary_restarts_with_original_pinned_tls(self):
        candidate = self.make_candidate()
        alpha.switch_v2_offline(self.root, candidate, self.identifier)
        for release in (candidate, OLD):
            alpha.switch_v2_offline(self.root, release, self.identifier)
            process = subprocess.Popen(['python3', str(CONTROLLER), 'run', '--root', str(self.root)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                alpha.wait_health(self.root)
                self.assertIsNone(process.poll())
                self.assertEqual(alpha.sql(self.root, 'SELECT count(*) FROM ss_messages').strip(), b'1')
            finally:
                if process.poll() is None:
                    process.terminate()
                self.assertEqual(process.wait(timeout=40), 0)
        self.assert_identity()



    def test_unrelated_or_inactive_unit_is_rejected_before_stop(self):
        candidate = self.make_candidate()
        (self.root / 'paranoid-alpha.service').write_text(alpha.unit(self.root))
        for fragment, active, enabled in ((str(self.base / 'neighbor.service'), 'active', 'enabled'),
                                           (str(self.root / 'paranoid-alpha.service'), 'inactive', 'enabled'),
                                           (str(self.root / 'paranoid-alpha.service'), 'active', 'disabled')):
            with self.subTest(fragment=fragment, active=active, enabled=enabled):
                manager = []
                native = alpha.command
                def controlled(args, **kwargs):
                    if str(args[0]) == 'systemctl':
                        manager.append([str(x) for x in args])
                        if 'show' not in args:
                            self.fail('unit preflight performed a state change')
                        return ('FragmentPath=' + fragment + '\nActiveState=' + active
                                + '\nUnitFileState=' + enabled + '\n').encode()
                    return native(args, **kwargs)
                with patch.object(alpha, 'command', side_effect=controlled), self.assertRaises(ValueError):
                    alpha.update_v2(self.root, candidate, self.identifier)
                self.assertTrue(manager, 'expected read-only unit verification')
                self.assertEqual(list((self.root / 'backups').iterdir()), [])
                self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        self.assert_identity()



    def test_actual_schema_drift_refused_before_encrypted_backup(self):
        candidate = self.make_candidate()
        with alpha.lock(self.root), alpha.database(self.root):
            alpha.sql(self.root, 'CREATE TABLE unexpected_state(id integer)')
        with self.assertRaises(ValueError):
            alpha.switch_v2_offline(self.root, candidate, self.identifier)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])
        self.assertFalse((self.root / 'backup.key').exists())
        self.assertEqual(self.old_pointer, (self.root / 'current').readlink())
        self.assert_identity()



    def test_staged_release_fsynced_before_durable_pointer_switch(self):
        candidate = self.make_candidate()
        synced = set()
        original = os.fsync
        def observed(fd):
            info = os.fstat(fd)
            synced.add((info.st_dev, info.st_ino))
            return original(fd)
        with patch.object(alpha.os, 'fsync', side_effect=observed):
            alpha.switch_v2_offline(self.root, candidate, self.identifier)
        target = alpha.current_release(self.root)
        for path in [self.root, self.root / 'releases', target, *target.iterdir()]:
            info = path.stat()
            self.assertIn((info.st_dev, info.st_ino), synced, 'new release file/directory or current parent not fsynced')


if __name__ == '__main__':
    unittest.main()
