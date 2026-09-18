import AVFoundation
import ParanoidKit
import XCTest

@testable import ParanoID

/// The three sounds a call makes, and the rules about when each one may sound.
///
/// `test_ui_contract.py` measures that the tones are driven by the published
/// controller view and by nothing else. This file measures the state machine
/// itself, transition by transition, against the rules of Android's
/// `CallTones.java`: a ring only for an incoming call, a ringback only for an
/// outgoing one that is still ringing, a busy tone only for the three ends
/// Android answers, and nothing at all once the call is connected.
///
/// It also checks that the synthesised waves are files the platform will really
/// play, the way `CallAudioSessionTests` checks the silent keep-alive. No
/// microphone is opened and no call is placed.
@MainActor
final class CallTonesTests: XCTestCase {
    private var tones: CallTones!

    override func setUp() {
        super.setUp()
        tones = CallTones()
    }

    override func tearDown() {
        tones?.release()
        tones = nil
        super.tearDown()
    }

    private func changed(_ state: CallController.State,
                         call: String = "c1",
                         reason: CallBody.EndReason? = nil) {
        tones.changed(state: state, callId: call, reason: reason)
    }

    // MARK: - the waves

    func testEachToneIsAWaveFileThePlatformWillPlay() throws {
        for wave in [CallTones.ringPattern(), CallTones.ringbackPattern(), CallTones.busyPattern()] {
            XCTAssertEqual(Array(wave[0..<4]), Array("RIFF".utf8), "not a RIFF container")
            XCTAssertEqual(Array(wave[8..<12]), Array("WAVE".utf8), "not a WAVE file")
            XCTAssertEqual(Array(wave[12..<16]), Array("fmt ".utf8), "no format chunk")
            XCTAssertEqual(Array(wave[36..<40]), Array("data".utf8), "no data chunk")
            XCTAssertNoThrow(try AVAudioPlayer(data: Data(wave)),
                             "the platform refused a tone this client synthesised")
        }
    }

    func testTheRingbackIsOneSecondOnAndFourOff() {
        let wave = CallTones.ringbackPattern()
        let samples = (wave.count - 44) / 2
        XCTAssertEqual(samples, CallTones.sampleRate * 5, "the pattern is five seconds long")
        // The first second carries the tone and the rest is silence, so a loop
        // sounds the way a telephone line does.
        XCTAssertTrue(wave[44..<(44 + 1_000)].contains { $0 != 0 }, "the burst is silent")
        XCTAssertFalse(wave[(44 + CallTones.sampleRate * 3)...].contains { $0 != 0 },
                       "the gap between bursts is not silent")
    }

    // MARK: - an outgoing call

    func testAnOutgoingCallRingsBackUntilItIsAnswered() {
        changed(.starting)
        XCTAssertEqual(tones.sounding, [], "nothing sounds before the peer is reached")
        changed(.outgoing)
        XCTAssertEqual(tones.sounding, [.ringback], "the caller hears nothing while waiting")
        changed(.connecting)
        XCTAssertEqual(tones.sounding, [], "the ringback outlived the ring")
        changed(.connected)
        XCTAssertEqual(tones.sounding, [], "a connected call sounds only of the other person")
    }

    func testAnUnansweredOutgoingCallEndsWithTheBusyTone() {
        for reason in [CallBody.EndReason.busy, .reject, .timeout] {
            let tones = CallTones()
            tones.changed(state: .starting, callId: "c1", reason: nil)
            tones.changed(state: .outgoing, callId: "c1", reason: nil)
            tones.changed(state: .ended, callId: "c1", reason: reason)
            XCTAssertEqual(tones.sounding, [.busy], "no busy tone for \(reason.rawValue)")
            tones.release()
        }
    }

    func testAnOutgoingCallTheCallerGaveUpOnIsSilent() {
        for reason in [CallBody.EndReason.hangup, .cancel, .failed, .unavailable] {
            let tones = CallTones()
            tones.changed(state: .starting, callId: "c1", reason: nil)
            tones.changed(state: .outgoing, callId: "c1", reason: nil)
            tones.changed(state: .ended, callId: "c1", reason: reason)
            XCTAssertEqual(tones.sounding, [], "\(reason.rawValue) is not a busy line")
            tones.release()
        }
    }

    func testAnAnsweredCallThatEndsMakesNoSound() {
        changed(.starting)
        changed(.outgoing)
        changed(.connected)
        changed(.ended, reason: .hangup)
        XCTAssertEqual(tones.sounding, [], "a finished conversation is not a busy line")
    }

    // MARK: - an incoming call

    func testAnIncomingCallRingsAndStopsWhenItIsAnswered() {
        changed(.incoming)
        XCTAssertEqual(tones.sounding, [.ring])
        changed(.connecting)
        XCTAssertEqual(tones.sounding, [])
    }

    func testAnIncomingCallThisPhoneRefusedDoesNotSoundBusy() {
        changed(.incoming)
        changed(.ended, reason: .reject)
        XCTAssertEqual(tones.sounding, [], "the busy tone belongs to the caller, not the callee")
    }

    func testTheRingStopsByItselfRatherThanForever() {
        XCTAssertEqual(CallTones.maximumRingSeconds, 60, "Android's MAX_RING_MS is a minute")
    }

    // MARK: - the rules that hold for every call

    func testTheSameStateTwiceChangesNothing() {
        changed(.starting)
        changed(.outgoing)
        let first = tones.sounding
        changed(.outgoing)
        XCTAssertEqual(tones.sounding, first, "a republished view restarted the tone")
    }

    func testANewCallIsHeardEvenInTheSameState() {
        changed(.incoming, call: "c1")
        XCTAssertEqual(tones.sounding, [.ring])
        changed(.ended, call: "c1", reason: .cancel)
        changed(.incoming, call: "c2")
        XCTAssertEqual(tones.sounding, [.ring], "the second call never rang")
    }

    func testReleasingSilencesEverything() {
        changed(.incoming)
        XCTAssertEqual(tones.sounding, [.ring])
        tones.release()
        XCTAssertEqual(tones.sounding, [], "a torn-down call left a sound behind")
    }
}
