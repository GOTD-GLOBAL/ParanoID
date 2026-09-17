#!/usr/bin/env python3
"""Regression contract for the archival clean-v7/v8 CI harness (no runtime edits)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Wiring(unittest.TestCase):
    def test_v2_backup_and_one_off_recovery_are_blocking_ci_gates(self):
        workflow = (ROOT / '.github/workflows/server.yml').read_text()
        package = workflow.split('  native-package:\n', 1)[1].split('  postgres-http:\n', 1)[0]
        for name in ('deploy/test_reconcile_apk_cap_20260913.py',
                     'deploy/test_restore_active_after_rollback.py',
                     'scripts/check-v2-maintenance.py'):
            self.assertIn('python3 ' + name, package)
            self.assertTrue((ROOT / name).is_file())
        self.assertEqual(workflow.count('"scripts/check-v2-maintenance.py"'), 2)
        runner = (ROOT / 'scripts/check-v2-maintenance.py').read_text()
        for marker in ('self_service_v2=True', 'PARANOID_V2_OLD_RELEASE',
                       'PARANOID_TEST_PACKAGED', 'PARANOID_V2_RELEASE',
                       'test_v2_update.py', 'test_v2_maintenance_interrupts.py',
                       'check=True'):
            self.assertIn(marker, runner)

    def test_turn_offline_package_and_versioned_controller_gate(self):
        workflow = (ROOT / ".github/workflows/server.yml").read_text()
        package = workflow.split("  native-package:\n", 1)[1].split("  postgres-http:\n", 1)[0]
        for name in ('deploy/turn/test_package.py', 'deploy/turn/test_runtime.py',
                     'deploy/test_turn_environment.py', 'deploy/test_push_environment.py'):
            self.assertIn('python3 ' + name, package)
            self.assertTrue((ROOT / name).is_file())

    def test_server_uses_private_cluster_without_ci_tcp_bypass(self):
        workflow = (ROOT / ".github/workflows/server.yml").read_text()
        server = workflow.split("  postgres-http:\n", 1)[1].split("  client-core-and-tls:\n", 1)[0]
        self.assertIn("python3 scripts/check-server.py", server)
        self.assertNotIn("PARANOID_CI_TEST_DATABASE", server)
        self.assertNotIn("PARANOID_TEST_DATABASE_URL", server)
        self.assertIn("postgresql-16", server)

    def test_legacy_is_separate_red_and_all_other_targets_gate(self):
        workflow = (ROOT / ".github/workflows/server.yml").read_text()
        self.assertIn("  legacy-client-history:\n", workflow)
        supported, legacy = workflow.split("  legacy-client-history:\n", 1)
        self.assertIn('for source in clients/core/tests/*.rs', supported)
        self.assertIn('if [[ "$name" != self_service ]]', supported)
        self.assertIn('--lib --bins "${tests[@]}"', supported)
        self.assertIn('--test self_service -- --exact "${legacy[@]}"', supported)
        names = (ROOT / 'scripts/ci-legacy-client-tests.txt').read_text().splitlines()
        self.assertEqual(len(names), 14)
        self.assertEqual(len(set(names)), 14)
        source = (ROOT / 'clients/core/tests/self_service.rs').read_text()
        for name in names:
            self.assertTrue(name.isidentifier())
            self.assertIn('fn ' + name + '()', source)
        self.assertNotIn('--skip', legacy)
        self.assertIn('--test self_service', legacy)
        self.assertIn('result=$?', legacy)
        self.assertIn('exit "$result"', legacy)
        # Comments explain why no failure-masking attribute is allowed.
        self.assertNotIn('continue-on-error:', '\n'.join(
            line for line in workflow.splitlines() if not line.lstrip().startswith('#')))


if __name__ == "__main__":
    unittest.main()
