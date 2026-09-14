#!/usr/bin/env python3
"""Source wiring only: runtime storage regressions require the Mac XCTest run."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent
STORAGE = ROOT / 'ParanoidKit/Sources/ParanoidKit/Storage'

class BootstrapContract(unittest.TestCase):
    def test_welcome_does_not_create_a_persistent_key(self):
        source = (ROOT / 'App/ParanoID/AppModel.swift').read_text()
        start = source.split('    func start() {', 1)[1].split('    func retryOpen()', 1)[0]
        self.assertNotIn('loadOrCreate(', start)
        self.assertIn('keyStore: KeychainKey.standard', start)

    def test_pending_defaults_never_authorize_key_without_file(self):
        source = (STORAGE / 'StorageGuard.swift').read_text()
        self.assertNotIn('isFirstRunPending', source)
        self.assertNotIn('recordPendingFirstRun', source)
        self.assertNotIn('withdrawPendingFirstRun', source)

    def test_remaining_storage_failure_is_not_expected(self):
        tests = (ROOT / 'ParanoidKit/Tests/ParanoidKitTests/SnapshotStoreTests.swift').read_text()
        self.assertNotIn('XCTExpectFailure(', tests)

if __name__ == '__main__':
    unittest.main()
