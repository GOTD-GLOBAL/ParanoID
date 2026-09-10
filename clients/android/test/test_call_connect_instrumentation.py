"""Offline source-contract checks, NOT Android execution or callback race proof."""
from pathlib import Path
import unittest


class InstrumentationContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(__file__).with_name('VoiceAppInstrumentation.java').read_text()

    def test_safe_commands_and_owner_errors(self):
        for text in ('"controller_view"', '"arm_terminal_observer"', '"terminal_events"',
                     '"owner_stopped"', '"owner_deadline"', '"observation_error"'):
            self.assertIn(text, self.source)

    def test_no_product_mutation_in_terminal_probe(self):
        self.assertIn('// BEGIN CALL-CONNECT01 TEST-ONLY', self.source)
        if '// BEGIN CALL-CONNECT01 TEST-ONLY' not in self.source: return
        probe = self.source.split('// BEGIN CALL-CONNECT01 TEST-ONLY')[1].split('// END CALL-CONNECT01 TEST-ONLY')[0]
        for forbidden in ('getLocalDescription(', 'getRemoteDescription(', 'setMuted(', 'setSpeaker(', '.answer(', '.hangup(', '.authorizationLost(', 'getMessage(', '.toString()', 'Thread.sleep', 'new ServerSocket', 'mediaBinding('):
            self.assertNotIn(forbidden, probe)
        for required in ('method.invoke(original, args)', 'throw wrapped.getCause()',
                         'terminalEvents.size() == 256', 'terminalTruncated++',
                         'SystemClock.elapsedRealtimeNanos()', 'first_terminal_origin',
                         'original.onError(reason)', 'original.onLocalDescription(type, exactSdp)'):
            self.assertIn(required, probe)


if __name__ == '__main__': unittest.main()
