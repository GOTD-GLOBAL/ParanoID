"""REQ-CALL-006: measured systemd ABI, offline descriptor tests, no services/network.

Real synthetic xattrs/fds are used where Linux can represent the case. Root UID
metadata is simulated in unprivileged tests; actual persistent-unit acceptance
remains a separate required inert matrix. No production path override is added.
"""
import ctypes
import errno
import os
from pathlib import Path
import stat
import sys
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import runtime


def acl(uid, permission):
    return struct.pack('<I', 2) + b''.join(struct.pack('<HHI', *entry) for entry in (
        (1, permission, 0xffffffff), (2, permission, uid), (4, 0, 0xffffffff),
        (16, permission, 0xffffffff), (32, 0, 0xffffffff)))


class DescriptorTests(unittest.TestCase):
    def setUp(self):
        self.uid = os.geteuid()
        self.assertNotEqual(self.uid, 0, 'run offline fixtures unprivileged')
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.secret = self.directory / 'voice-turn-secret'
        self.secret.write_bytes(b'a' * 64)
        self.secret.chmod(0o400)
        self.directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        self.real_fstat = os.fstat
        self.dir_inode = self.directory.stat().st_ino
        self.file_inode = self.secret.stat().st_ino
        self.layout = 'acl'
        self.file_layout = 'acl'
        os.setxattr(self.directory_fd, 'system.posix_acl_access', acl(self.uid, 5))
        os.setxattr(self.secret, 'system.posix_acl_access', acl(self.uid, 4))

    def tearDown(self):
        os.fchmod(self.directory_fd, 0o700)
        os.close(self.directory_fd)
        self.tmp.cleanup()

    def metadata(self, fd):
        original = self.real_fstat(fd)
        value = SimpleNamespace(**{k: getattr(original, k) for k in dir(original) if k.startswith('st_')})
        layout = self.layout if original.st_ino == self.dir_inode else self.file_layout
        value.st_uid = 0 if layout == 'acl' else self.uid
        return value

    def load(self, meta=None):
        with patch.object(runtime.os, 'fstat', side_effect=meta or self.metadata):
            return runtime._read_systemd_copy(self.directory_fd, self.uid)

    def owned(self):
        self.layout = self.file_layout = 'owned'
        self.directory.chmod(0o500)
        self.secret.chmod(0o400)

    def test_observed_root_0550_and_0440_exact_acl_is_readable(self):
        self.assertTrue(self.load() == 'a' * 64)

    def test_generic_reader_still_rejects_observed_acl_mask_mode(self):
        with patch.object(runtime.os, 'fstat', side_effect=self.metadata):
            with self.assertRaises(ValueError):
                runtime.read_secret(self.secret)

    def test_private_fallback_does_not_query_acl(self):
        self.owned()
        with patch.object(runtime, '_read_acl', side_effect=AssertionError('unexpected ACL query')):
            self.assertTrue(self.load() == 'a' * 64)

    def test_directory_size_and_links_are_not_pinned_to_measurement(self):
        def meta(fd):
            m = self.metadata(fd)
            if m.st_ino == self.dir_inode:
                m.st_size, m.st_nlink = 913, 7
            return m
        self.assertTrue(self.load(meta) == 'a' * 64)

    def test_nonzero_owning_gid_is_safe_with_zero_group_acl(self):
        def meta(fd):
            m = self.metadata(fd); m.st_gid = 12345; return m
        self.assertTrue(self.load(meta) == 'a' * 64)

    def test_mixed_layout_pairs_are_rejected(self):
        self.file_layout = 'owned'; self.secret.chmod(0o400)
        with self.assertRaises(ValueError): self.load()
        self.layout, self.file_layout = 'owned', 'acl'
        self.directory.chmod(0o500)
        os.setxattr(self.secret, 'system.posix_acl_access', acl(self.uid, 4))
        with self.assertRaises(ValueError): self.load()

    def test_wrong_uid_modes_type_links_and_size_are_rejected(self):
        variants = [('file', 'st_uid', self.uid + 1), ('directory', 'st_uid', self.uid + 1),
                    ('file', 'st_mode', stat.S_IFREG | 0o600),
                    ('file', 'st_mode', stat.S_IFREG | 0o444),
                    ('file', 'st_mode', stat.S_IFREG | 0o4440),
                    ('file', 'st_mode', stat.S_IFIFO | 0o440),
                    ('directory', 'st_mode', stat.S_IFDIR | 0o750),
                    ('directory', 'st_mode', stat.S_IFDIR | 0o555),
                    ('directory', 'st_mode', stat.S_IFREG | 0o550),
                    ('file', 'st_nlink', 2), ('file', 'st_size', 63), ('file', 'st_size', 65)]
        for kind, field, value in variants:
            with self.subTest(kind=kind, field=field, value=value):
                def meta(fd):
                    m = self.metadata(fd)
                    if (m.st_ino == self.dir_inode) == (kind == 'directory'): setattr(m, field, value)
                    return m
                with self.assertRaises(ValueError): self.load(meta)

    def test_fallback_runtime_0600_is_rejected(self):
        self.owned(); self.secret.chmod(0o600)
        with self.assertRaises(ValueError): self.load()

    def test_fd_metadata_races_are_rejected(self):
        for kind in ('file', 'directory'):
            for field in ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_nlink', 'st_size', 'st_ctime_ns'):
                with self.subTest(kind=kind, field=field):
                    calls = 0
                    def meta(fd):
                        nonlocal calls
                        m = self.metadata(fd)
                        if (m.st_ino == self.dir_inode) == (kind == 'directory'):
                            calls += 1
                            if calls > 1: setattr(m, field, getattr(m, field) + 1)
                        return m
                    with self.assertRaises(ValueError): self.load(meta)

    def test_actual_file_symlink_hardlink_and_fifo_are_rejected(self):
        self.directory.chmod(0o700)
        self.secret.unlink(); self.secret.symlink_to(self.directory / 'missing')
        os.setxattr(self.directory_fd, 'system.posix_acl_access', acl(self.uid, 5))
        with self.assertRaises((OSError, ValueError)): self.load()
        self.directory.chmod(0o700)
        self.secret.unlink(); os.mkfifo(self.secret, 0o400)
        os.setxattr(self.directory_fd, 'system.posix_acl_access', acl(self.uid, 5))
        with self.assertRaises(ValueError): self.load()
        self.directory.chmod(0o700)
        self.secret.unlink(); self.secret.write_bytes(b'a' * 64); self.secret.chmod(0o400)
        os.setxattr(self.secret, 'system.posix_acl_access', acl(self.uid, 4))
        os.link(self.secret, self.directory / 'second-link')
        os.setxattr(self.directory_fd, 'system.posix_acl_access', acl(self.uid, 5))
        with self.assertRaises(ValueError): self.load()

    def test_real_six_entry_acl_exceeds_fixed_buffer(self):
        original = acl(self.uid, 4)
        extra = original[:20] + struct.pack('<HHI', 2, 4, self.uid + 1) + original[20:]
        os.setxattr(self.secret, 'system.posix_acl_access', extra)
        fd = os.open(self.secret, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            self.assertEqual(len(os.getxattr(fd, 'system.posix_acl_access')), 52)
            with self.assertRaises(ValueError): runtime._read_acl(fd)
        finally: os.close(fd)

    def test_malformed_content_and_bounded_same_fd_read(self):
        for data in (b'G' * 64, b'a' * 63, b'a' * 64 + b'\n'):
            self.secret.chmod(0o600); self.secret.write_bytes(data)
            os.setxattr(self.secret, 'system.posix_acl_access', acl(self.uid, 4))
            with self.assertRaises(ValueError): self.load()
        self.secret.chmod(0o600); self.secret.write_bytes(b'a' * 64)
        os.setxattr(self.secret, 'system.posix_acl_access', acl(self.uid, 4))
        original_read = os.read
        with patch.object(runtime.os, 'read', wraps=original_read) as reader:
            self.assertTrue(self.load() == 'a' * 64)
            reader.assert_called_once()
            self.assertEqual(reader.call_args.args[1], 65)

    def test_acl_exact_encoding_and_entry_negatives(self):
        correct = acl(self.uid, 4)
        entries = [struct.unpack_from('<HHI', correct, 4 + 8*i) for i in range(5)]
        variants = [correct[:43], correct + b'\x00', struct.pack('<I', 3) + correct[4:],
                    struct.pack('>I', 2) + correct[4:], struct.pack('<I', 2) + b''.join(struct.pack('>HHI', *x) for x in entries)]
        for index, replacement in [(1, (2, self.uid + 1, self.uid)), (1, (2, 4, self.uid + 1)),
                                   (1, (2, 4, 0)), (2, (8, 0, 55)), (2, (4, 4, 0xffffffff)),
                                   (3, (16, 5, 0xffffffff)), (4, (32, 4, 0xffffffff)),
                                   (0, (1, 6, 0xffffffff)), (0, (1, 4, 0))]:
            changed = entries.copy(); changed[index] = replacement
            variants.append(struct.pack('<I', 2) + b''.join(struct.pack('<HHI', *x) for x in changed))
        variants.append(struct.pack('<I', 2) + b''.join(struct.pack('<HHI', *x) for x in reversed(entries)))
        for raw in variants:
            with self.subTest(case=variants.index(raw)):
                with patch.object(runtime, '_read_acl', side_effect=[acl(self.uid, 5), raw]):
                    with self.assertRaises(ValueError): self.load()

    def test_directory_acl_write_or_wrong_mask_is_rejected(self):
        for permission in (4, 6, 7):
            with patch.object(runtime, '_read_acl', return_value=acl(self.uid, permission)):
                with self.assertRaises(ValueError): self.load()

    def test_acl_absent_or_oversized_has_no_private_fallback(self):
        for error in (errno.ENODATA, errno.EOPNOTSUPP, errno.ERANGE):
            with patch.object(runtime, '_read_acl', side_effect=OSError(error, 'synthetic ACL error')):
                with self.assertRaises((OSError, ValueError)): self.load()


class AbiAndPathTests(unittest.TestCase):
    def test_trusted_ancestor_requires_root_and_no_special_or_write_bits(self):
        for uid, mode in ((1003, 0o755), (0, 0o775), (0, 0o757), (0, 0o1755),
                          (0, 0o2755), (0, 0o4755)):
            meta = SimpleNamespace(st_uid=uid, st_mode=stat.S_IFDIR | mode)
            with patch.object(runtime.os, 'fstat', return_value=meta):
                with self.assertRaises(ValueError): runtime._require_trusted_ancestor(17)

    def test_production_traversal_holds_nofollow_single_component_descriptors(self):
        env = {'CREDENTIALS_DIRECTORY':'/run/credentials/paranoid-turn.service',
               'RUNTIME_DIRECTORY':'/run/paranoid-turn'}
        meta = SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        with patch.dict(runtime.os.environ, env, clear=True), \
             patch.object(runtime.os, 'geteuid', return_value=1003), \
             patch.object(runtime.os, 'open', side_effect=[10, 11, 12, 13]) as opener, \
             patch.object(runtime.os, 'close') as closer, \
             patch.object(runtime.os, 'fstat', return_value=meta), \
             patch.object(runtime, '_read_systemd_copy', return_value='synthetic') as reader:
            self.assertEqual(runtime.read_systemd_secret(), 'synthetic')
            reader.assert_called_once_with(13, 1003)
            self.assertEqual([call.args[0] for call in opener.call_args_list],
                             ['/', 'run', 'credentials', 'paranoid-turn.service'])
            for call in opener.call_args_list:
                self.assertEqual(call.args[1] & (os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC),
                                 os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.assertEqual([call.kwargs.get('dir_fd') for call in opener.call_args_list],
                             [None, 10, 11, 12])
            self.assertEqual([call.args[0] for call in closer.call_args_list], [13, 12, 11, 10])

    def test_libc_binding_is_typed_fixed_single_call(self):
        raw = acl(os.geteuid(), 4)
        class Getter:
            calls = 0
            def __call__(self, fd, name, buffer, capacity):
                self.calls += 1
                self.args = (fd, name, capacity)
                ctypes.memmove(buffer, raw, len(raw)); return len(raw)
        getter = Getter()
        with patch.object(runtime.ctypes, 'CDLL', return_value=SimpleNamespace(fgetxattr=getter)) as library:
            self.assertEqual(runtime._read_acl(17), raw)
            library.assert_called_once_with(None, use_errno=True)
        self.assertEqual(getter.calls, 1)
        self.assertEqual(getter.args, (17, b'system.posix_acl_access', 44))
        self.assertEqual(getter.restype, ctypes.c_ssize_t)
        self.assertEqual(getter.argtypes, [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t])

    def test_libc_error_short_long_and_missing_symbol_fail_closed(self):
        for result in (-1, 0, 43, 45, 52):
            getter = unittest.mock.Mock(return_value=result)
            with patch.object(runtime.ctypes, 'CDLL', return_value=SimpleNamespace(fgetxattr=getter)):
                with self.assertRaises(ValueError): runtime._read_acl(17)
                getter.assert_called_once()
        with patch.object(runtime.ctypes, 'CDLL', return_value=SimpleNamespace()):
            with self.assertRaises(ValueError): runtime._read_acl(17)

    def test_child_directory_open_refuses_symlink_and_path_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); (p / 'target').mkdir(); (p / 'alias').symlink_to(p / 'target')
            parent = os.open(p, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with self.assertRaises(OSError): runtime._open_child_directory(parent, 'alias')
                for component in ('../target', '.', '..', '/tmp', 'target/child', ''):
                    with self.assertRaises(ValueError): runtime._open_child_directory(parent, component)
            finally: os.close(parent)

    def test_production_paths_are_literal_and_root_is_refused_before_open(self):
        valid = {'CREDENTIALS_DIRECTORY':'/run/credentials/paranoid-turn.service',
                 'RUNTIME_DIRECTORY':'/run/paranoid-turn'}
        for field in valid:
            for value in ('/tmp/fixture', valid[field] + '/', valid[field].replace('/run/', '/run//')):
                env = dict(valid); env[field] = value
                with patch.dict(runtime.os.environ, env, clear=True), patch.object(runtime.os, 'open') as opener:
                    with self.assertRaises(ValueError): runtime.read_systemd_secret()
                    opener.assert_not_called()
        with patch.dict(runtime.os.environ, valid, clear=True), patch.object(runtime.os, 'geteuid', return_value=0), patch.object(runtime.os, 'open') as opener:
            with self.assertRaises(ValueError): runtime.read_systemd_secret()
            opener.assert_not_called()


class EntryPointTests(unittest.TestCase):
    def test_check_and_run_require_literal_systemd_entry_point(self):
        class BoundaryReached(Exception):
            pass
        for operation in ('check', 'run'):
            with self.subTest(operation=operation), patch.object(sys, 'argv', ['runtime.py', operation]), \
                    patch.object(runtime.package, 'verify', return_value={'provenance': {'profile': 'paranoid-turn-v1'}}), \
                    patch.object(runtime, 'read_systemd_secret', side_effect=BoundaryReached) as reader, \
                    patch.object(runtime, 'read_secret', side_effect=AssertionError('generic path must not bypass runtime boundary')):
                with self.assertRaises(BoundaryReached):
                    runtime.main()
                reader.assert_called_once_with()


if __name__ == '__main__':
    unittest.main(verbosity=2)
