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

    def test_first_key_is_read_back_before_use(self):
        source = (STORAGE / 'SnapshotStore.swift').read_text()
        for statement in ('let created = try keyStore.create()', 'let stored = try keyStore.load()',
                          'stored == created', 'try remember(stored)'):
            self.assertIn(statement, source)
        create = source.index('let created = try keyStore.create()')
        readback = source.index('let stored = try keyStore.load()', create)
        equality = source.index('stored == created', readback)
        remember = source.index('try remember(stored)', equality)
        self.assertLess(create, readback)
        self.assertLess(equality, remember)

    def test_no_eager_key_helper_remains(self):
        source = (STORAGE / 'KeychainKey.swift').read_text()
        self.assertNotIn('func loadOrCreate(', source)

    def test_remaining_storage_failure_is_not_expected(self):
        tests = (ROOT / 'ParanoidKit/Tests/ParanoidKitTests/SnapshotStoreTests.swift').read_text()
        self.assertNotIn('XCTExpectFailure(', tests)

if __name__ == '__main__':
    unittest.main()
