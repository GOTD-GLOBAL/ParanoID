"""Source-only fences for PR50 audio executor/session ownership; not an audio runtime test."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parent
VOICE=ROOT/'App/ParanoID/Voice'

class ToneLifecycleContract(unittest.TestCase):
    def test_players_are_not_on_the_main_actor_or_state_owner(self):
        tones=(VOICE/'CallTones.swift').read_text()
        self.assertNotIn('AVAudioPlayer(',tones)
        self.assertNotIn('@MainActor',tones)
        playback=(VOICE/'CallTonePlayback.swift').read_text()
        self.assertIn('queue.async',playback)
        self.assertIn('candidate.volume = 0',playback)
        self.assertIn('let started = candidate.play()',playback)
        self.assertIn('isCurrent(token)',playback)

    def test_session_and_presentation_are_owned_together(self):
        coordinator=(VOICE/'CallCoordinator.swift').read_text()
        model=(ROOT/'App/ParanoID/AppModel.swift').read_text()
        audio=(VOICE/'AudioSessionController.swift').read_text()
        self.assertIn('audio.callChanged(presentation)',coordinator)
        self.assertIn('audio.quiesceMedia()',coordinator)
        self.assertNotIn('tones.changed(',model)
        self.assertIn('AVAudioSession.Category.ambient',audio)
        self.assertIn('toneDriver',audio)

    def test_recovery_retires_logical_lease_and_release_completion(self):
        tones=(VOICE/'CallTones.swift').read_text()
        audio=(VOICE/'AudioSessionController.swift').read_text()
        self.assertIn('let released = session.deactivate()',tones)
        self.assertIn('currentMode = nil // RTCAudioSession consumes its activation count even on failure',tones)
        self.assertIn('lastFailure = "activate_failed"; finishRelease(); resolvePrepared(false); return',tones)
        self.assertIn('held = false // the SDK balances the lease even when setActive(false) throws',audio)
        self.assertIn('interrupted = false // a fresh explicit intent may retry the OS',tones)

    def test_interruption_refresh_survives_coalesced_callbacks(self):
        tones=(VOICE/'CallTones.swift').read_text()
        body=tones.split('func setInterrupted(_ value: Bool)',1)[1].split('func mediaServicesReset()',1)[0]
        self.assertIn('needsSessionRefresh = true',body)

    def test_terminal_tail_cannot_acquire_a_new_session(self):
        tones=(VOICE/'CallTones.swift').read_text()
        apply=tones.split('private func apply(token:',1)[1]
        self.assertIn('guard !terminal else',apply)
        self.assertLess(apply.index('guard !terminal else'),apply.index('guard session.activate(mode)'))

    def test_session_observers_wait_until_coordinator_construction_finishes(self):
        audio=(VOICE/'AudioSessionController.swift').read_text()
        initializer=audio.split('init(events:',1)[1].split('private final class ToneSessionPort',1)[0]
        self.assertNotIn('subscribe()',initializer)
        changed=audio.split('func callChanged(',1)[1].split('func restoreIncoming()',1)[0]
        self.assertIn('subscribe()',changed)

if __name__=='__main__': unittest.main()
