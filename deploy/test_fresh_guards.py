"""V2 discard boundary tests. Only synthetic files; mount records are injected."""
import io
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from test_containment import ContainmentTests, alpha


class FreshGuards(unittest.TestCase):
    root: Path
    base: Path
    setUp = ContainmentTests.setUp

    def test_exact_public_ip_or_explicit_loopback_only(self):
        for ip, reviewed in [('157.180.49.125', '157.180.49.125'), ('127.0.0.19', '127.0.0.19')]:
            alpha.reviewed_v2_ip(ip, reviewed)
        for ip, reviewed in [('157.180.49.125', None), ('157.180.49.125', '157.180.49.126'),
                             ('192.0.2.10', '192.0.2.10'), ('0.0.0.0', '0.0.0.0'),
                             ('224.0.0.1', '224.0.0.1'), ('::1', '::1')]:
            with self.subTest(ip=ip, reviewed=reviewed), self.assertRaises(ValueError):
                alpha.reviewed_v2_ip(ip, reviewed)

    def test_discard_tree_rejects_redirect_hardlink_fifo_and_mount(self):
        alpha.validate_discard_tree(self.root)
        path = self.root / 'data/unexpected'
        path.symlink_to(self.root / 'tls')
        with self.assertRaises(ValueError):
            alpha.validate_discard_tree(self.root)
        path.unlink()
        os.link(self.root / 'tls/server.key', path)
        with self.assertRaises(ValueError):
            alpha.validate_discard_tree(self.root)
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(ValueError):
            alpha.validate_discard_tree(self.root)
        path.unlink()
        original_open = Path.open
        def mounted(path, *args, **kwargs):
            if path == Path('/proc/self/mountinfo'):
                return io.StringIO(f'1 2 3:4 / {self.root}/data/bind rw - ext4 none rw\n')
            return original_open(path, *args, **kwargs)
        with patch.object(Path, 'open', new=mounted), self.assertRaisesRegex(ValueError, 'mount'):
            alpha.validate_discard_tree(self.root)
        self.assertEqual((self.root / 'tls/server.key').read_text(), 'synthetic')

    def test_data_initializer_refuses_existing_data_before_command(self):
        with patch.object(alpha, 'command', side_effect=AssertionError('must not run initdb')), self.assertRaises(FileExistsError):
            alpha.initialize_data(self.root)

    def test_discard_rejects_root_redirect_and_privileged_caller(self):
        alias = self.base / 'paranoid-alias'
        alias.symlink_to(self.root)
        with self.assertRaises(ValueError):
            alpha.validate_discard_tree(alias)
        with patch.object(alpha.os, 'geteuid', return_value=0), self.assertRaises(ValueError):
            alpha.validate_discard_tree(self.root)


if __name__ == '__main__':
    unittest.main()
