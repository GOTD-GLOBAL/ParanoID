"""Offline evidence/control boundaries; never starts a VM, relay or namespace."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import single_host_vm_runner as runner


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.trace = runner.Trace(self.root, {'run_id': '1' * 32}, 'fresh')

    def test_missing_failed_and_unexecuted_checks_never_become_observed(self):
        self.trace.begin('fresh')
        for name in ('active', 'relay_active', 'issuer_enabled'):
            self.trace.check(name, True)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            self.trace.finish()
        self.trace.check('registration_text', False)
        with self.assertRaisesRegex(ValueError, 'failed'):
            self.trace.finish()

    def test_actual_failed_command_is_retained_and_stops_case(self):
        self.trace.begin('relay-cli')
        argv = ['/usr/bin/python3', '-I', '-c', 'print("owned failure"); raise SystemExit(3)']
        with self.assertRaisesRegex(RuntimeError, 'command'):
            self.trace.command(argv)
        result = json.loads((self.root / 'relay-cli.json').read_text())
        self.assertEqual(result['result'], 'FAILED')
        self.assertEqual(result['commands'][0]['exit_code'], 3)
        self.assertEqual(result['commands'][0]['output'], 'owned failure\n')

    def test_timeout_remains_a_timeout_and_owned_child_is_reaped(self):
        self.trace.begin('relay-cli')
        argv = ['/usr/bin/python3', '-I', '-c', 'import time; time.sleep(10)']
        with self.assertRaises(subprocess.TimeoutExpired):
            self.trace.command(argv, timeout=0.02)
        result = json.loads((self.root / 'relay-cli.json').read_text())
        self.assertEqual(result['result'], 'FAILED')
        self.assertIsNone(result['commands'][0]['exit_code'])
        self.assertEqual(result['failure'], 'command_timeout')


class ScopeTests(unittest.TestCase):
    def test_recovery_requires_post_cutover_data_and_two_live_reopened_clients(self):
        before = {'through_sequence': 2, 'current_sequence': 2, 'count': 2, 'sha256': 'a' * 64}
        admitted = {'through_sequence': 4, 'current_sequence': 4, 'count': 4, 'sha256': 'b' * 64}
        reopened = {'one': {'active': True, 'connected': True},
                    'two': {'active': True, 'connected': True}}
        self.assertTrue(runner.recovery_data_observed(before, admitted, admitted, reopened))
        for changed in (before, {**admitted, 'sha256': 'c' * 64}, {**admitted, 'count': 2}):
            self.assertFalse(runner.recovery_data_observed(before, admitted, changed, reopened))
        self.assertFalse(runner.recovery_data_observed(before, before, before, reopened))
        self.assertFalse(runner.recovery_data_observed(before, admitted, admitted, {'one': reopened['one']}))
        self.assertFalse(runner.recovery_data_observed(before, admitted, admitted,
            {**reopened, 'two': {'active': True, 'connected': False}}))

    def test_guest_initial_boundary_rejects_physical_device_route_or_prior_setup(self):
        value = {'product': 'ParanoID Voice Fixture v1', 'links': ['lo'],
                 'network_pci': [], 'namespaces': [], 'routes': {'-4': [], '-6': []},
                 'physical_devices': []}
        runner.require_initial_observation(value)
        for change in ({'links': ['lo', 'eth0']}, {'namespaces': ['prior']},
                       {'network_pci': ['0000:00:03.0']}, {'physical_devices': ['eth0']},
                       {'routes': {'-4': [{'dst': 'default', 'dev': 'lo'}], '-6': []}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.require_initial_observation({**value, **change})

    def test_pristine_pam_initialization_never_overwrites_a_common_config(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / 'etc/pam.d').mkdir(parents=True)
            runner.require_pristine_pam(root)
            path = root / 'etc/pam.d/common-account'
            path.write_text('retained policy')
            with self.assertRaisesRegex(ValueError, 'pristine'):
                runner.require_pristine_pam(root)
            self.assertEqual(path.read_text(), 'retained policy')

    def test_incomplete_driver_cannot_begin_guest_mutation(self):
        with patch.object(runner, 'RUNNERS', {}), patch.object(runner, 'bootstrap') as bootstrap:
            with self.assertRaisesRegex(ValueError, 'complete reviewed suite'):
                runner.execute_suite({}, {})
            bootstrap.assert_not_called()


if __name__ == '__main__':
    unittest.main()
