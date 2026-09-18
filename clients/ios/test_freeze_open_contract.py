#!/usr/bin/env python3
"""Linux source regressions for F1/F3; not Swift/runtime execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent

class FreezeOpenContractTests(unittest.TestCase):
    def test_owner_notifies_synchronously_after_every_operation(self):
        text = (ROOT / 'ParanoidKit/Sources/ParanoidKit/Realtime/StateOwner.swift').read_text()
        body = text.split('public func perform<T: Sendable>', 1)[1].split('// MARK:', 1)[0]
        self.assertIn('defer { notifyFreezeIfNeeded() }', body)
        notify = text.split('private func notifyFreezeIfNeeded()', 1)[1].split('// MARK:', 1)[0]
        self.assertLess(notify.index('enabled = false'), notify.index('freezeHandler?()'))
        self.assertLess(notify.index('freezeNotified = true'), notify.index('freezeHandler?()'))
        self.assertNotIn('Task {', notify)
        self.assertIn('guard !closed, !client.isBroken else', text)
        self.assertIn('guard !closed, !client.isBroken, enabled else', text)

    def test_bootstrap_factory_sends_client_result_to_runtime(self):
        text = (ROOT / 'App/ParanoID/AppModel.swift').read_text()
        # A stored closure may retain actor-connected captures; its result must
        # explicitly transfer ownership to Runtime, not make the client Sendable.
        for declaration in (
            'private let openClient: (() throws -> sending SelfServiceClient)?',
            # The initializer gained a second parameter (the metadata factory,
            # PR47 bootstrap follow-up), so the contract is the closure type and
            # the parameter boundary, not the whole one-line signature.
            'init(openClient: (() throws -> sending SelfServiceClient)? = nil,',
        ):
            with self.subTest(declaration=declaration):
                self.assertIn(declaration, text)
        self.assertIn('init(client: sending SelfServiceClient, model: AppModel)', text)

    def test_successful_open_clears_only_bootstrap_failure(self):
        text = (ROOT / 'App/ParanoID/AppModel.swift').read_text()
        body = text.split('func start() {', 1)[1].split('func retryOpen()', 1)[0]
        self.assertIn('isBroken = false', body)
        self.assertLess(body.index('guard runtime == nil'), body.index('isBroken = false'))
        self.assertLess(body.index('runtime = built'), body.index('isBroken = false'))
        self.assertLess(body.index('isBroken = false'), body.index('stage = .running'))
        self.assertIn('frozenDetail = Strings.Status.brokenDetails', body)
        self.assertIn('lastStatus = Strings.Status.openingDetails', body)
        self.assertIn('guard runtime == nil else', text.split('func retryOpen()', 1)[1])

if __name__ == '__main__':
    unittest.main()
