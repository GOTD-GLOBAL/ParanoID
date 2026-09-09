#!/usr/bin/env python3
"""Regression contract for the archival clean-v7/v8 CI harness (no runtime edits)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Wiring(unittest.TestCase):
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
