"""REQ-DEPLOY-001/SEC-001: fail closed before writing or stopping services."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('alpha', HERE / 'alpha.py')
assert spec and spec.loader
alpha = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alpha)
FILES = ('paranoid-server', 'schema.sql', 'alpha.py', 'create-test-tls.py', 'README.md')


class ContainmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='paranoid-containment-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'paranoid-alpha'
        self.root.mkdir(mode=0o700)
        for name in ('data', 'socket', 'releases', 'backups', 'tls'):
            (self.root / name).mkdir(mode=0o700)
        self.cfg = {'ip': '127.0.0.1', 'alice': 'a' * 64, 'bob': 'b' * 64}
        for name, content in [('config.json', json.dumps(self.cfg)), ('tls/server.key', 'synthetic'),
                              ('tls/server.crt', 'synthetic')]:
            (self.root / name).write_text(content)
            (self.root / name).chmod(0o600)
        self.release = self.base / 'candidate'
        self.release.mkdir(mode=0o700)
        for name in FILES:
            (self.release / name).write_text('synthetic ' + name)
        self.manifest = {'release': 'fixture-1', 'sha256': {n: alpha.digest(self.release / n) for n in FILES}}
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_current_and_next_unsafe_states_rejected_without_writes(self):
        target = alpha.stage(self.root, self.release)
        pointer = self.root / 'current'
        for link in (self.release, self.root / 'releases/missing',
                     self.root / 'releases' / '..' / 'releases' / target.name,
                     self.root / 'releases' / '.', self.root / 'releases' / '..'):
            with self.subTest(link=link):
                pointer.symlink_to(link)
                try:
                    with self.assertRaises((ValueError, OSError)):
                        alpha.config(self.root)
                finally:
                    pointer.unlink()
        pointer.write_text('not a link')
        with self.assertRaises(ValueError):
            alpha.config(self.root)
        pointer.unlink()
        pointer.symlink_to(target)
        (target / 'schema.sql').write_text('tampered')
        with self.assertRaises(ValueError):
            alpha.config(self.root)
        (target / 'schema.sql').write_bytes((self.release / 'schema.sql').read_bytes())
        (self.root / 'next').symlink_to(self.base / 'missing')
        with self.assertRaises(ValueError):
            alpha.stage(self.root, self.release)
        self.assertFalse(os.path.lexists(self.root / 'lifecycle.lock'))

    def test_public_or_non_directory_persistent_paths_rejected(self):
        for name in ('data', 'socket', 'releases', 'backups', 'tls'):
            path = self.root / name
            with self.subTest(path=name):
                path.chmod(0o755)
                with self.assertRaises(ValueError):
                    alpha.stage(self.root, self.release)
                path.chmod(0o700)
                saved = self.base / ('saved-' + name)
                path.rename(saved)
                path.write_text('not a directory')
                path.chmod(0o600)
                with self.assertRaises(ValueError):
                    alpha.stage(self.root, self.release)
                path.unlink()
                saved.rename(path)
        with patch.object(alpha.os, 'geteuid', return_value=os.geteuid() + 1000), self.assertRaises(ValueError):
            alpha.stage(self.root, self.release)

    def test_cli_stage_validates_candidate_before_lock(self):
        import subprocess
        self.manifest['release'] = '..'
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        result = subprocess.run(['python3', HERE / 'alpha.py', 'stage', '--root', self.root,
                                 '--release', self.release], capture_output=True, timeout=5, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(os.path.lexists(self.root / 'lifecycle.lock'))
        self.assertEqual(list((self.root / 'releases').iterdir()), [])

    def test_run_missing_current_and_unit_invalid_config_are_read_only(self):
        with self.assertRaises((ValueError, OSError)):
            alpha.run(self.root)
        self.assertFalse(os.path.lexists(self.root / 'lifecycle.lock'))
        (self.root / 'config.json').write_text('{}')
        with self.assertRaises(ValueError):
            alpha.unit(self.root)

    def test_init_refuses_generator_created_config_without_overwrite(self):
        root = self.base / 'paranoid-new'
        def generator(args, **kwargs):
            self.assertEqual(str(args[0]), 'python3', 'must refuse before initdb')
            (root / 'config.json').write_text('PRESERVE SYNTHETIC OPERATOR FILE')
            return b''
        with patch.object(alpha, 'command', side_effect=generator) as command:
            with self.assertRaises(FileExistsError):
                alpha.initialize(root, '127.0.0.1')
            self.assertEqual(command.call_count, 1)
        self.assertEqual((root / 'config.json').read_text(), 'PRESERVE SYNTHETIC OPERATOR FILE')

    def test_install_checks_inputs_before_systemd(self):
        alias = self.base / 'alias'
        alias.symlink_to(self.base)
        for root, ip in ((alias / 'paranoid-new', '127.0.0.1'),
                         (self.base / 'paranoid-new', 2130706433), (self.root, '127.0.0.1')):
            with self.subTest(root=root, ip=ip), \
                    patch.object(alpha, 'command', side_effect=AssertionError('must reject before command')), \
                    self.assertRaises((ValueError, OSError)):
                alpha.install(root, ip, self.release)

    def test_direct_lifecycle_helpers_validate_before_side_effects(self):
        with self.assertRaises((ValueError, OSError)):
            alpha.point(self.root, self.release)
        self.assertFalse(os.path.lexists(self.root / 'current'))
        (self.root / 'backups').rmdir()
        (self.root / 'backups').symlink_to(self.base)
        with patch.object(alpha, 'command', side_effect=AssertionError('must reject before command')), \
                self.assertRaises((ValueError, OSError)):
            alpha.backup(self.root)
        with patch.object(alpha.subprocess, 'Popen', side_effect=AssertionError('must reject before process')), \
                self.assertRaises((ValueError, OSError)), alpha.database(self.root):
            self.fail('unsafe database started')
        self.assertFalse(os.path.lexists(self.root / 'lifecycle.lock'))

    def test_candidate_collision_rejected_before_stop_or_backup(self):
        target = alpha.stage(self.root, self.release)
        alpha.point(self.root, target)
        self.manifest['release'] = 'fixture-2'
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        collision = self.root / 'releases/fixture-2'
        collision.symlink_to(self.release)
        with patch.object(alpha, 'command', side_effect=AssertionError('must reject before command')):
            with self.assertRaises((ValueError, OSError)):
                alpha.update(self.root, self.release)
            with self.assertRaises((ValueError, OSError)):
                alpha.switch(self.root, self.release)
        self.assertFalse(os.path.lexists(self.root / 'lifecycle.lock'))
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_invalid_installation_rejected_before_update_commands(self):
        target = alpha.stage(self.root, self.release)
        alpha.point(self.root, target)
        for name in ('data', 'socket', 'releases', 'backups', 'tls', 'config.json', 'lifecycle.lock', 'current'):
            with self.subTest(path=name):
                path = self.root / name
                saved = self.base / ('saved-' + name)
                if os.path.lexists(path):
                    path.rename(saved)
                outside = self.release if name == 'current' else saved
                path.symlink_to(outside)
                try:
                    with patch.object(alpha, 'command', side_effect=AssertionError('must reject before command')) as command:
                        with self.assertRaises((ValueError, OSError)):
                            alpha.update(self.root, self.release)
                        command.assert_not_called()
                finally:
                    path.unlink()
                    if os.path.lexists(saved):
                        saved.rename(path)
        (self.root / 'config.json').write_text(json.dumps({**self.cfg, 'alice': 'short'}))
        with patch.object(alpha, 'command') as command:
            with self.assertRaises(ValueError):
                alpha.update(self.root, self.release)
            command.assert_not_called()

    def test_lock_redirection_and_preexisting_unsafe_files_rejected(self):
        outside = self.base / 'outside-lock'
        outside.write_text('DO NOT CHANGE')
        outside.chmod(0o600)
        lock = self.root / 'lifecycle.lock'
        lock.symlink_to(outside)
        with self.assertRaises((ValueError, OSError)), alpha.lock(self.root):
            self.fail('redirected lock acquired')
        self.assertEqual(outside.read_text(), 'DO NOT CHANGE')
        lock.unlink()
        os.link(outside, lock)
        with self.assertRaises((ValueError, OSError)), alpha.lock(self.root):
            self.fail('external hard-linked lock acquired')
        lock.unlink()
        lock.write_text('')
        lock.chmod(0o644)
        with self.assertRaises((ValueError, OSError)), alpha.lock(self.root):
            self.fail('public lock acquired')
        lock.unlink()
        os.mkfifo(lock)
        with self.assertRaises((ValueError, OSError)), alpha.lock(self.root):
            self.fail('FIFO lock acquired')

    def test_config_exact_shape_ipv4_and_distinct_hex_tokens(self):
        invalid = [[], None, {}, {**self.cfg, 'extra': 'unexpected'},
                   {**self.cfg, 'ip': 'example.invalid:443/#'}, {**self.cfg, 'ip': '::1'},
                   {**self.cfg, 'ip': '127.000.0.1'}, {**self.cfg, 'ip': 2130706433},
                   {**self.cfg, 'alice': 'short'}, {**self.cfg, 'alice': 'z' * 64},
                   {**self.cfg, 'bob': self.cfg['alice']}, {**self.cfg, 'bob': 'A' * 64},
                   {**self.cfg, 'bob': 123}]
        for cfg in invalid:
            with self.subTest(config=cfg):
                (self.root / 'config.json').write_text(json.dumps(cfg))
                with self.assertRaises(ValueError):
                    alpha.config(self.root)
        (self.root / 'config.json').write_text(json.dumps(self.cfg)[:-1] + ', "ip": "127.0.0.1"}')
        with self.assertRaises(ValueError):
            alpha.config(self.root)
        (self.root / 'config.json').write_text(json.dumps(self.cfg))
        self.assertEqual(alpha.config(self.root), self.cfg)

    def test_release_ids_and_nonregular_members_rejected(self):
        for version in ('.', '..', '../escape', '', 1):
            with self.subTest(version=version):
                self.manifest['release'] = version
                (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
                with self.assertRaises((ValueError, OSError)):
                    alpha.verify(self.release)
        self.manifest['release'] = 'fixture-1'
        (self.release / 'manifest.json').write_text(json.dumps(self.manifest))
        for name in (*FILES, 'manifest.json'):
            with self.subTest(member=name):
                source = self.release / name
                outside = self.base / ('outside-' + name)
                source.rename(outside)
                source.symlink_to(outside)
                try:
                    with self.assertRaises((ValueError, OSError)):
                        alpha.verify(self.release)
                finally:
                    source.unlink()
                    outside.rename(source)
        (self.release / 'secret.json').write_text('synthetic')
        with self.assertRaises((ValueError, OSError)):
            alpha.verify(self.release)

    def test_symlink_ancestor_rejected_before_initialization(self):
        alias = self.base / 'alias'
        actual = self.base / 'real'
        actual.mkdir()
        alias.symlink_to(actual, target_is_directory=True)
        with patch.object(alpha, 'command') as command:
            with self.assertRaises((ValueError, OSError)):
                alpha.initialize(alias / 'paranoid-new', '127.0.0.1')
            command.assert_not_called()
        self.assertEqual(list(actual.iterdir()), [])

    def test_unsafe_root_rejected_on_existing_installation(self):
        alias = self.base / 'alias'
        alias.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            alpha.stage(alias / self.root.name, self.release)
        with self.assertRaises((ValueError, OSError)):
            alpha.stage(self.root / '..' / self.root.name, self.release)
        unsafe = self.base / 'unsafe'
        unsafe.mkdir(mode=0o777)
        unsafe.chmod(0o777)
        self.root.rename(unsafe / self.root.name)
        with self.assertRaises((ValueError, OSError)):
            alpha.stage(unsafe / self.root.name, self.release)

    def test_redirected_persistent_directories_rejected_before_stage(self):
        for name in ('data', 'socket', 'releases', 'backups', 'tls'):
            with self.subTest(directory=name):
                original = self.root / name
                outside = self.base / ('outside-' + name)
                original.rename(outside)
                original.symlink_to(outside, target_is_directory=True)
                before = sorted(str(p.relative_to(outside)) for p in outside.rglob('*'))
                try:
                    with self.assertRaises((ValueError, OSError)):
                        alpha.stage(self.root, self.release)
                    self.assertEqual(before, sorted(str(p.relative_to(outside)) for p in outside.rglob('*')))
                finally:
                    original.unlink()
                    outside.rename(original)


if __name__ == '__main__':
    unittest.main()
