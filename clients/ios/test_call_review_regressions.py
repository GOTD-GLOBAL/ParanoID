"""Linux source contracts only; Swift behavioral tests require the Apple toolchain."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent
VOICE = ROOT / 'ParanoidKit/Sources/ParanoidKit/Voice'
APP = ROOT / 'App/ParanoID/Voice'

class CallReviewContracts(unittest.TestCase):
    def test_answer_consent_is_checked_on_owner_before_mutation(self):
        controller = (VOICE / 'CallController.swift').read_text()
        signature = 'public func answer(microphonePermission: Bool, callId: String, generation: CallGeneration)'
        self.assertIn(signature, controller)
        body = controller.split(signature, 1)[1].split('///', 1)[0]
        self.assertIn('call.identity.callId == callId', body)
        self.assertIn('call.generation == generation', body)
        self.assertLess(body.index('call.generation == generation'), body.index('answer(microphonePermission: microphonePermission)'))
        coordinator = (APP / 'CallCoordinator.swift').read_text()
        body = coordinator.split('func answer(microphone:', 1)[1].split('///', 1)[0]
        self.assertIn('callId: String, generation: CallGeneration', body)
        self.assertIn('callId: callId, generation: generation', body)
        self.assertIn('owner.onOwner', body)
        model = (ROOT / 'App/ParanoID/AppModel.swift').read_text()
        intent = model.split('private func beginCallIntent(', 1)[1].split('private func cancelCallIntent', 1)[0]
        self.assertIn('let answerGeneration = answer && call?.callId == callId ? call?.generation : nil', intent)
        self.assertLess(intent.index('let answerGeneration'), intent.index('await AppModel.requestMicrophone()'))
        for granted in ('true', 'false'):
            self.assertIn(f'answer(microphone: {granted}, callId: callId, generation: answerGeneration)', intent)
        self.assertIn('call.generation == answerGeneration', intent)

    def test_terminal_cancels_its_request_not_the_lane(self):
        coordinator = (APP / 'CallCoordinator.swift').read_text()
        close = coordinator.split('func close() {', 1)[1].split('private func mediaClosed', 1)[0]
        self.assertIn('relayRequest?.cancel()', close)
        self.assertNotIn('relay.cancel()', close)
        lane = (VOICE / 'VoiceRelayLane.swift').read_text()
        self.assertIn('public final class Request:', lane)
        request = lane.split('public func request(under', 1)[1].split('/// Drops', 1)[0]
        self.assertLess(request.index('guard !request.isCancelled'), request.index('cancelCurrent()'))
        self.assertIn('request: request', request)
        self.assertIn('guard !pending.isCancelled else { return }', lane)
        self.assertIn('request: request', coordinator)
        self.assertIn('request.cancel()', lane)

    def test_freeze_hook_is_attached_before_listener_setup(self):
        coordinator = (APP / 'CallCoordinator.swift').read_text()
        attach = coordinator.split('func attach() async {', 1)[1].split('startTicking()', 1)[0]
        self.assertIn('await owner.setFreezeHandler', attach)
        self.assertIn('self?.authorizationLost()', attach)
        self.assertLess(attach.index('setFreezeHandler'), attach.index('owner.perform'))

    def test_cancel_is_guarded_before_owner_listener_side_effects(self):
        lane = (VOICE / 'VoiceRelayLane.swift').read_text()
        body = lane.split('public func deliverRelay', 1)[1].split('// MARK:', 1)[0]
        self.assertIn('guard request?.isCancelled != true', body)
        self.assertLess(body.index('guard request?.isCancelled != true'),
                        body.index('listener?.authorizationLost()'))

    def test_remote_only_video_disables_proximity(self):
        import re
        source = (APP / 'AudioSessionController.swift').read_text()
        match = re.search(r'let proximity = (.*)', source)
        assert match is not None, 'missing production proximity predicate'
        expression = match.group(1)
        # Evaluate only the repository's Boolean predicate, with no builtins,
        # calls, attribute access, literals or unknown names permitted.
        tokens = re.findall(r'[A-Za-z]+|&&|\|\||!|\(|\)', expression)
        self.assertEqual(''.join(tokens), re.sub(r'\s+', '', expression))
        self.assertTrue(set(tokens) <= {'held', 'audible', 'video', 'remoteVideo',
                                       'speaker', 'headset', 'isHeadsetRoute',
                                       '&&', '||', '!', '(', ')'})
        expression = expression.replace('&&', ' and ').replace('||', ' or ').replace('!', ' not ')
        values = dict(held=True, audible=True, video=False, remoteVideo=True,
                      speaker=False, headset=False, isHeadsetRoute=False)
        self.assertFalse(eval(expression, {'__builtins__': {}}, values),
                         'remote-only video must not blank the screen')
        values['remoteVideo'] = False
        self.assertTrue(eval(expression, {'__builtins__': {}}, values),
                        'audio-only earpiece proximity is preserved')

if __name__ == '__main__':
    unittest.main()
