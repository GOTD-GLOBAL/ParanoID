"""Synthetic real crypto/files; FakeOps explicitly replaces systemd/network only."""
import datetime as dt
import importlib.util
import ipaddress
import os
from pathlib import Path
import tempfile
import unittest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

SOURCE = Path(__file__).with_name('tls_renewal.py')

class FakeOps:
    def __init__(self): self.calls = []
    def preflight(self): pass
    def guard(self): return {'unit': 'fixture-loaded-unit'}
    def health(self): self.calls.append('health')
    def stop(self): self.calls.append('stop')
    def start(self): self.calls.append('start')
    def served(self, raw): self.calls.append('served')

class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'alpha'
        self.state = Path(self.tmp.name) / 'state'
        for p in [self.root, self.root/'tls', self.root/'data', self.root/'releases', self.root/'releases/r1', self.state]:
            p.mkdir(mode=0o700)
        self.put(self.root/'releases/r1/alpha.py', b'# synthetic release')
        (self.root/'current').symlink_to('releases/r1')
        for name in ['config.json', 'paranoid-alpha.service', 'operation.lock']:
            self.put(self.root/name, b'{}')
        self.now = dt.datetime(2026, 9, 13, 12)
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.put(self.root/'tls/server.key', self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.old = self.make_cert(60)
        self.put(self.root/'tls/server.crt', self.old)
        import hashlib
        self.pin = hashlib.sha256(self.key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()
        self.ops = FakeOps()
    def put(self, p, raw):
        p.write_bytes(raw); p.chmod(0o600)
    def make_cert(self, days):
        name = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, 'synthetic')])
        return (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(self.key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(self.now-dt.timedelta(days=2))
                .not_valid_after(self.now+dt.timedelta(days=days))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), False)
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
                .sign(self.key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
    def engine(self):
        self.assertTrue(SOURCE.exists(), 'renewal implementation missing')
        spec = importlib.util.spec_from_file_location('renewal_under_test', SOURCE)
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        self.m = m
        return m.Renewal(self.root, self.state, self.pin, '127.0.0.1', self.ops, self.now)
    def snapshot(self):
        return {str(p): (p.lstat().st_ino, p.lstat().st_mtime_ns, p.read_bytes())
                for p in Path(self.tmp.name).rglob('*') if p.is_file()}
    def test_not_due_and_check_are_read_only(self):
        e = self.engine(); before = self.snapshot()
        for check in (True, False):
            result = e.run(check=check)
            self.assertEqual(result['result'], 'not_due')
            self.assertIn('next_due', result)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(self.ops.calls, [])
        e.pin = '0'*64
        with self.assertRaises(ValueError): e.run()
        self.assertEqual(before, self.snapshot())

    def test_due_preserves_identity_metadata_and_next_run_noop(self):
        self.old = self.make_cert(30); self.put(self.root/'tls/server.crt', self.old)
        e = self.engine(); key_before = (self.root/'tls/server.key').read_bytes()
        self.assertEqual(e.run(check=True)['result'], 'due')
        self.assertEqual(e.run()['result'], 'renewed')
        new_raw = (self.root/'tls/server.crt').read_bytes()
        old, new = map(x509.load_pem_x509_certificate, [self.old, new_raw])
        self.assertEqual(old.subject, new.subject)
        self.assertEqual(old.issuer, new.issuer)
        self.assertEqual(list(old.extensions), list(new.extensions))
        self.assertNotEqual(old.serial_number, new.serial_number)
        self.assertEqual(new.not_valid_before, self.now-dt.timedelta(minutes=5))
        self.assertEqual(new.not_valid_after-new.not_valid_before, dt.timedelta(days=90))
        self.assertEqual(key_before, (self.root/'tls/server.key').read_bytes())
        self.assertEqual((self.root/'tls/server.crt').stat().st_mode & 0o777, 0o600)
        before = self.snapshot(); self.ops.calls.clear()
        self.assertEqual(e.run()['result'], 'not_due')
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.ops.calls, [])
        self.assertTrue(list(self.state.glob('*/journal.json')))

    def test_failed_readiness_rolls_back_and_persists_failure(self):
        self.old = self.make_cert(20); self.put(self.root/'tls/server.crt', self.old)
        e = self.engine()
        def health():
            self.ops.calls.append('health')
            if self.ops.calls.count('start') == 1: raise RuntimeError('injected readiness')
        self.ops.health = health
        with self.assertRaises(RuntimeError): e.run()
        self.assertEqual((self.root/'tls/server.crt').read_bytes(), self.old)
        self.assertEqual(self.ops.calls.count('start'), 2)
        self.assertTrue((self.state/'failure.json').exists())
        self.assertIn('rolled_back', next(self.state.glob('*/journal.json')).read_text())

    def crash_after_rename(self):
        self.old = self.make_cert(20); self.put(self.root/'tls/server.crt', self.old)
        e = self.engine()
        def crash(): raise SystemExit('injected hard interruption')
        self.ops.start = crash
        with self.assertRaises(SystemExit): e.run()
        self.ops = FakeOps()
        return self.engine()

    def test_crash_replayed_before_not_due(self):
        e = self.crash_after_rename()
        self.assertNotEqual((self.root/'tls/server.crt').read_bytes(), self.old)
        before = self.snapshot()
        self.assertEqual(e.run(check=True)['result'], 'recovery_required')
        self.assertEqual(before, self.snapshot())
        with self.assertRaisesRegex(RuntimeError, 'interrupted transaction recovered'): e.run()
        self.assertEqual((self.root/'tls/server.crt').read_bytes(), self.old)
        self.assertIn('rolled_back', next(self.state.glob('*/journal.json')).read_text())
        self.assertEqual(e.run()['result'], 'renewed')

    def test_pending_unknown_drift_refuses_overwrite(self):
        for target in ('config.json', 'tls/server.key', 'tls/server.crt'):
            with self.subTest(target=target):
                # Fresh independent real filesystem for each drift case.
                self.setUp(); e = self.crash_after_rename()
                path = self.root/target
                self.put(path, b'unknown drift')
                current = (self.root/'tls/server.crt').read_bytes()
                with self.assertRaises(ValueError): e.run()
                self.assertEqual((self.root/'tls/server.crt').read_bytes(), current)
                self.assertEqual(self.ops.calls, [])

    def test_modes_symlinks_hardlinks_and_lock_contention(self):
        import fcntl
        e = self.engine()
        with open(self.root/'operation.lock', 'rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): e.run()
        for target in ('tls/server.key', 'tls/server.crt', 'operation.lock'):
            path = self.root/target
            path.chmod(0o644)
            with self.assertRaises(ValueError): e.run()
            path.chmod(0o600)
            saved = path.with_suffix('.saved'); path.rename(saved); path.symlink_to(saved)
            with self.assertRaises(OSError): e.run()
            path.unlink(); saved.rename(path)
            os.link(path, saved)
            with self.assertRaises(ValueError): e.run()
            saved.unlink()
        self.state.chmod(0o755)
        with self.assertRaises(ValueError): e.run()
        self.assertEqual(self.ops.calls, [])

    def test_system_ops_stop_waits_for_job_and_health_is_bounded(self):
        e = self.engine()
        self.assertTrue(hasattr(self.m, 'SystemOps'), 'real system operations missing')
        from unittest.mock import patch
        ops = self.m.SystemOps(self.root, unit='fixture.service', ip='127.0.0.1')
        states = iter(['ActiveState=inactive\nMainPID=0\nJob=17', 'ActiveState=inactive\nMainPID=0\nJob=0'])
        calls = []
        def command(args, timeout=60):
            calls.append(args)
            return next(states) if 'show' in args else ''
        with patch.object(self.m, 'command', command), patch.object(self.m.time, 'sleep'):
            ops.stop()
        self.assertEqual(sum('show' in c for c in calls), 2)
        with patch.object(self.m, 'command', return_value='ActiveState=inactive\nMainPID=0\nJob=1'), patch.object(self.m.time, 'sleep'):
            with self.assertRaises(RuntimeError): ops.stop()
        with patch.object(self.m, 'command', side_effect=RuntimeError('synthetic fail')), patch.object(self.m.time, 'sleep'):
            with self.assertRaises(RuntimeError): ops.health()

    def test_executable_release_and_inactive_refusal(self):
        self.old = self.make_cert(20); self.put(self.root/'tls/server.crt', self.old)
        (self.root/'releases/r1/alpha.py').chmod(0o755)
        e = self.engine()
        self.assertEqual(e.run()['result'], 'renewed')
        self.old = self.make_cert(20); self.put(self.root/'tls/server.crt', self.old)
        def inactive(): raise RuntimeError('operator stopped unit')
        self.ops.preflight = inactive
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, 'operator stopped'): e.run()
        self.assertEqual(before, self.snapshot())

    def test_real_ops_preflight_guard_start_and_exact_der(self):
        self.engine()
        from unittest.mock import patch, MagicMock
        ops = self.m.SystemOps(self.root, unit='paranoid-alpha.service', ip='127.0.0.1')
        self.assertTrue(hasattr(ops, 'preflight'), 'real preflight missing')
        def command(args, timeout=60):
            if 'timedatectl' in args: return 'yes\n'
            if 'cat' in args: return 'synthetic loaded unit'
            if 'show' in args:
                return 'ActiveState=active\nMainPID=42\nJob=0\nNeedDaemonReload=no\nFragmentPath='+str(self.root/'paranoid-alpha.service')+'\nDropInPaths=\n'
            return ''
        with patch.object(self.m, 'command', command):
            ops.preflight(); self.assertEqual(ops.guard(), ops.guard()); ops.start()
        with patch.object(self.m, 'command', return_value='ActiveState=inactive\nMainPID=0\nJob=0'):
            with self.assertRaises(ValueError): ops.preflight()
        der = x509.load_pem_x509_certificate(self.old).public_bytes(serialization.Encoding.DER)
        ctx = MagicMock(); ctx.wrap_socket.return_value.__enter__.return_value.getpeercert.return_value = der
        with patch.object(self.m.ssl, 'create_default_context', return_value=ctx), patch.object(self.m.socket, 'create_connection'):
            ops.served(self.old)
            ctx.wrap_socket.return_value.__enter__.return_value.getpeercert.return_value = b'wrong DER'
            with self.assertRaises(ValueError): ops.served(self.old)

    def test_cli_and_timer_contract(self):
        import subprocess
        result = subprocess.run(['python', str(SOURCE), '--force'], capture_output=True)
        self.assertNotEqual(result.returncode, 0, 'CLI silently accepts force')
        service = SOURCE.with_name('paranoid-tls-renewal.service')
        timer = SOURCE.with_name('paranoid-tls-renewal.timer')
        self.assertTrue(service.exists() and timer.exists(), 'systemd templates missing')
        self.assertIn('TimeoutStartSec=15min', service.read_text())
        self.assertIn('OnCalendar=daily', timer.read_text())
        self.assertIn('Persistent=true', timer.read_text())
        self.assertNotIn('PartOf=paranoid-alpha', service.read_text())
        self.assertIn('Unit=paranoid-tls-renewal.service', timer.read_text())

    def test_loaded_guard_excludes_transient_exec_start_metadata(self):
        self.engine()
        from unittest.mock import patch
        ops = self.m.SystemOps(self.root)
        requested = []
        def fields(props):
            requested.extend(props)
            return {'FragmentPath': str(self.root/'paranoid-alpha.service'), 'NeedDaemonReload': 'no', 'DropInPaths': ''}
        with patch.object(ops, 'fields', fields), patch.object(self.m, 'command', return_value='unit'):
            ops.guard()
        self.assertNotIn('ExecStart', requested, 'ExecStart show includes changing pid/start_time')

    def test_rejects_ca_and_implausible_validity_without_writes(self):
        e = self.engine()
        cert = x509.load_pem_x509_certificate(self.old)
        for ca, days in [(True, 60), (False, 500)]:
            with self.subTest(ca=ca, days=days):
                raw = (x509.CertificateBuilder().subject_name(cert.subject).issuer_name(cert.subject)
                       .public_key(self.key.public_key()).serial_number(x509.random_serial_number())
                       .not_valid_before(self.now-dt.timedelta(days=1)).not_valid_after(self.now+dt.timedelta(days=days))
                       .add_extension(cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value, False)
                       .add_extension(x509.BasicConstraints(ca=ca, path_length=None), True)
                       .sign(self.key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
                self.put(self.root/'tls/server.crt', raw)
                before = self.snapshot()
                with self.assertRaises(ValueError): e.run()
                self.assertEqual(before, self.snapshot())

    def test_atomic_refuses_symlink_and_preserves_mode_owner(self):
        self.engine()
        p = self.state/'receipt.json'; p.symlink_to(self.root/'config.json')
        with self.assertRaises(OSError): self.m.atomic(p, b'new')
        self.assertTrue(p.is_symlink())
        p.unlink(); self.put(p, b'old')
        meta = p.stat()
        self.m.atomic(p, b'new')
        self.assertEqual((p.stat().st_uid, p.stat().st_gid, p.stat().st_mode), (meta.st_uid, meta.st_gid, meta.st_mode))

if __name__ == '__main__': unittest.main()
