"""Real local systemd/PG/TLS v2 update and failed-readiness same-data recovery.

Creates one unique paranoid-alpha-v2-test-* user unit and removes only that unit.
Requires local user manager. Never contacts or mutates the hosted service.
"""
import os
import runpy
import signal
import sys
from pathlib import Path
import secrets
import subprocess
import unittest
from unittest.mock import patch

import test_v2_update as fixtures

alpha = fixtures.alpha


class SystemdV2Update(unittest.TestCase):
    def test_actual_manager_update_and_failed_health_preserve_new_rows(self):
        f = fixtures.SafeV2Update()
        f.setUp()
        root = f.root
        name = 'paranoid-alpha-v2-test-' + secrets.token_hex(4) + '.service'
        created = False
        try:
            self.assertEqual(alpha.command(['systemctl', '--user', 'show', name, '-p', 'LoadState', '--value']).strip(), b'not-found')
            candidate = f.make_candidate()
            target_id = alpha.verify(candidate)['release']
            (root / name).write_text(alpha.unit(root))
            created = True
            alpha.command(['systemctl', '--user', 'enable', '--now', root / name])
            alpha.wait_health(root)
            alpha.update_v2(root, candidate, f.identifier, name)
            self.assertEqual(alpha.current_release(root).name, target_id)
            self.assertEqual(alpha.command(['systemctl', '--user', 'is-active', name]).strip(), b'active')
            alpha.update_v2(root, fixtures.OLD, f.identifier, name)
            self.assertEqual(alpha.current_release(root), f.old_pointer)
            original = alpha.wait_health
            injected = []
            def fail_new_health(checked_root):
                original(checked_root)
                if alpha.current_release(checked_root).name == target_id:
                    alpha.sql(root, "INSERT INTO ss_messages VALUES(2,'a','b','after-new-start',decode('aabbcc','hex'),'a','b'); UPDATE ss_meta SET sequence=2")
                    injected.append(True)
                    raise RuntimeError('injected new-release readiness failure')
            with patch.object(alpha, 'wait_health', side_effect=fail_new_health), self.assertRaisesRegex(RuntimeError, 'previous release ready'):
                alpha.update_v2(root, candidate, f.identifier, name)
            self.assertEqual(injected, [True])
            self.assertEqual(alpha.current_release(root), f.old_pointer)
            self.assertEqual(alpha.command(['systemctl', '--user', 'is-active', name]).strip(), b'active')
            alpha.health(root)
            self.assertEqual(alpha.sql(root, 'SELECT sequence FROM ss_messages ORDER BY sequence').strip(), b'1\n2')
            self.assertEqual(alpha.sql(root, 'SELECT sequence FROM ss_meta').strip(), b'2')
            self.assertEqual(alpha.sql(root, "SELECT mode FROM ss_accounts WHERE account='b'").strip(), b'revoked')
            f.assert_identity()
            print('PASS actual dedicated local unit update, reverse update and failed-health automatic same-current-data rollback; post-update row preserved; original PG/TLS/config retained')
        finally:
            if created:
                alpha.command(['systemctl', '--user', 'stop', name])
                alpha.command(['systemctl', '--user', 'disable', name])
                subprocess.run(['systemctl', '--user', 'reset-failed', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                print('CLEANUP stopped/disabled only ' + name)
            f.tearDown()



    def test_actual_sigint_sigterm_after_cutover_restore_old_readiness(self):
        f = fixtures.SafeV2Update()
        f.setUp()
        root = f.root
        name = 'paranoid-alpha-v2-test-' + secrets.token_hex(4) + '.service'
        created = False
        try:
            self.assertEqual(alpha.command(['systemctl', '--user', 'show', name, '-p', 'LoadState', '--value']).strip(), b'not-found')
            candidate = f.make_candidate()
            (root / name).write_text(alpha.unit(root))
            created = True
            alpha.command(['systemctl', '--user', 'enable', '--now', root / name])
            alpha.wait_health(root)
            for sig in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(signal=sig.name):
                    result = subprocess.run([sys.executable, __file__, 'interrupt-child', str(root), str(candidate), f.identifier, name, str(sig.value)],
                                            capture_output=True, text=True, timeout=60,
                                            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                    self.assertEqual(result.returncode, 130)
                    self.assertEqual(result.stdout, 'Reached durable pointer cutover\n')
                    self.assertIn('interrupted', result.stderr)
                    self.assertNotIn('PASS', result.stdout + result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertNotIn(str(root), result.stderr)
                    self.assertEqual(alpha.current_release(root), f.old_pointer)
                    self.assertEqual(alpha.command(['systemctl', '--user', 'is-active', name]).strip(), b'active')
                    alpha.health(root)
                    self.assertEqual(alpha.sql(root, 'SELECT count(*) FROM ss_messages').strip(), b'1')
                    f.assert_identity()
                    print('PASS actual ' + sig.name + ' after fsynced pointer cutover: exit130, old code ready, PG/TLS/config/history retained')
        finally:
            if created:
                alpha.command(['systemctl', '--user', 'stop', name])
                alpha.command(['systemctl', '--user', 'disable', name])
                subprocess.run(['systemctl', '--user', 'reset-failed', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                print('CLEANUP stopped/disabled only ' + name)
            f.tearDown()


def interrupt_child():
    root, candidate, identifier, name, number = sys.argv[2:]
    controller = str(fixtures.CONTROLLER)
    def trace(frame, event, arg):
        if event == 'return' and frame.f_code.co_filename == controller and frame.f_code.co_name == 'point_v2':
            sys.settrace(None)
            print('Reached durable pointer cutover', flush=True)
            os.kill(os.getpid(), int(number))
        return trace
    sys.argv = [controller, 'update-v2', '--root', root, '--release', candidate, '--expected-pg-system-id', identifier, '--unit-name', name]
    sys.settrace(trace)
    runpy.run_path(controller, run_name='__main__')


if __name__ == '__main__':
    if sys.argv[1:2] == ['interrupt-child']:
        interrupt_child()
    else:
        unittest.main()
