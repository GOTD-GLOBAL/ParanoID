"""C1 source wiring; behavioral regression is CallControlDispatchTests on Mac."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent


def body(text, declaration):
    start = text.index(declaration)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return re.sub(r'//[^\n]*', '', text[opening + 1:end - 1])


class CallControlTargeting(unittest.TestCase):
    def test_every_scoped_controller_entry_checks_both_fields_before_mutation(self):
        text = (ROOT / 'ParanoidKit/Sources/ParanoidKit/Voice/CallController.swift').read_text()
        declarations = [
            'public func end(callId: String, generation: CallGeneration)',
            'public func reject(callId: String, generation: CallGeneration)',
            'public func hangup(callId: String, generation: CallGeneration)',
            'public func mute(_ muted: Bool, callId: String, generation: CallGeneration)',
            'public func speaker(_ speaker: Bool, callId: String, generation: CallGeneration)',
        ]
        for declaration in declarations:
            with self.subTest(entry=declaration):
                self.assertTrue(declaration in text, declaration)
                method = body(text, declaration)
                self.assertRegex(method, r'^\s*own\(\)\s*guard matchesCall\(callId: callId, generation: generation\) else \{ return \}')
        self.assertTrue('private func matchesCall(' in text, 'controller target predicate missing')
        match = body(text, 'private func matchesCall(')
        self.assertIn('call.identity.callId == callId', match)
        self.assertIn('call.generation == generation', match)

    def test_scoped_speaker_qualifies_method_shadowed_by_bool_parameter(self):
        declaration = 'func speaker(_ speaker: Bool, callId: String, generation: CallGeneration)'
        sources = [
            ('production', 'ParanoidKit/Sources/ParanoidKit/Voice/CallController.swift'),
            ('baseline', 'ParanoidKit/Tests/ParanoidKitTests/CallControlDispatchTests.swift'),
        ]
        for source, path in sources:
            with self.subTest(source=source):
                text = (ROOT / path).read_text()
                if source == 'baseline':
                    text = text.split('#if C1_LEGACY_BASELINE', 1)[1]
                method = body(text, declaration)
                self.assertRegex(method, r'\bself\.speaker\(speaker\)')
                self.assertNotRegex(method, r'(?<![\w.])speaker\(speaker\)')

    def test_app_and_coordinator_carry_the_captured_target(self):
        model = (ROOT / 'App/ParanoID/AppModel.swift').read_text()
        coordinator = (ROOT / 'App/ParanoID/Voice/CallCoordinator.swift').read_text()
        for declaration, call in [('func endCall()', 'end(callId: call.callId, generation: call.generation)'),
                                  ('func toggleMute()', 'setMuted(!call.muted, callId: call.callId, generation: call.generation)'),
                                  ('func toggleSpeaker()', 'setSpeaker(!call.speaker, callId: call.callId, generation: call.generation)')]:
            with self.subTest(entry=declaration):
                method = body(model, declaration)
                self.assertIn('guard let call', method)
                self.assertLess(method.index('guard let call'), method.index('Task {'))
                self.assertIn(call, method)
        for declaration, call in [('func end(callId:', 'controller.end(callId: callId, generation: generation)'),
                                  ('func setMuted(', 'controller.mute(muted, callId: callId, generation: generation)'),
                                  ('func setSpeaker(', 'controller.speaker(speaker, callId: callId, generation: generation)')]:
            with self.subTest(entry=declaration):
                self.assertTrue(declaration in coordinator, declaration)
                method = body(coordinator, declaration)
                self.assertIn('await owner.onOwner', method)
                self.assertIn(call, method)
        self.assertFalse(re.search(r'controller\.(?:reject|hangup)\(\)|controller\.(?:mute|speaker)\(\w+\)', coordinator),
                         'coordinator still invokes an unscoped control')

    def test_behavioral_test_uses_real_owner_and_a_held_dispatch(self):
        tests = (ROOT / 'ParanoidKit/Tests/ParanoidKitTests/CallControlDispatchTests.swift').read_text()
        for token in ['StateOwner(client:', 'await queued.wait()', 'await release.wait()',
                      'await release.open()', 'try await pending.value', 'owner: owner',
                      '#if C1_LEGACY_BASELINE', 'replaceAWithB()', 'b.localDescription']:
            self.assertIn(token, tests)
        self.assertNotIn('Task.sleep', tests)


if __name__ == '__main__':
    unittest.main()
