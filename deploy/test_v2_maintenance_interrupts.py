"""Actual SIGINT/SIGTERM during v2 backup: nonzero and preserved isolated data."""
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import unittest

import test_v2_update as fixtures


def child():
    root, identifier, phase, number = sys.argv[2:]
    controller = str(fixtures.CONTROLLER)
    def trace(frame, event, arg):
        if (event == 'call' and frame.f_code.co_filename == controller
                and frame.f_code.co_name == phase):
            sys.settrace(None)
            print('Reached v2 maintenance interruption boundary', flush=True)
            os.kill(os.getpid(), int(number))
        return trace
    sys.argv = [controller, 'backup-v2', '--root', root, '--expected-pg-system-id', identifier]
    sys.settrace(trace)
    runpy.run_path(controller, run_name='__main__')


class MaintenanceInterrupts(unittest.TestCase):
    def test_real_sigint_sigterm_during_encryption_and_restore_are_not_success(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            for phase in ('encrypt_v2_dump', 'verify_v2_backup'):
                with self.subTest(signal=sig.name, phase=phase):
                    f = fixtures.SafeV2Update()
                    f.setUp()
                    try:
                        result = subprocess.run([sys.executable, __file__, 'child', str(f.root), f.identifier, phase, str(sig.value)],
                                                capture_output=True, text=True, timeout=45,
                                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                        self.assertEqual(result.returncode, 130)
                        self.assertIn('interrupted', result.stderr)
                        self.assertNotIn('PASS', result.stdout + result.stderr)
                        self.assertNotIn('Traceback', result.stdout + result.stderr)
                        self.assertNotIn(str(f.root), result.stderr)
                        self.assertEqual(result.stdout, 'Reached v2 maintenance interruption boundary\n')
                        self.assertEqual((f.root / 'current').readlink(), f.old_pointer)
                        self.assertFalse((f.root / 'data/postmaster.pid').exists())
                        f.assert_identity()
                        with fixtures.alpha.lock(f.root), fixtures.alpha.database(f.root):
                            self.assertEqual(fixtures.alpha.sql(f.root, 'SELECT count(*) FROM ss_messages').strip(), b'1')
                            self.assertEqual(fixtures.alpha.sql(f.root, "SELECT mode FROM ss_accounts WHERE account='b'").strip(), b'revoked')
                        print(json.dumps({'signal': sig.name, 'phase': phase, 'exit': result.returncode, 'data_identity': 'preserved'}))
                    finally:
                        f.tearDown()


if __name__ == '__main__':
    if sys.argv[1:2] == ['child']:
        child()
    else:
        unittest.main()
