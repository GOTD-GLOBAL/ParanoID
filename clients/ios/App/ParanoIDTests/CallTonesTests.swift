import AVFoundation
import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// Deterministic control/session tests. Fake output completion is NOT audibility.
final class CallTonesTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
    private final class Session: CallToneSessionPort {
        var events: [String] = []
        var allowActivation = true
        var allowDeactivation = true
        var leases = 0
        var released = 0
        func activate(_ mode: CallTones.Mode) -> Bool {
            events.append("activate:\(mode)")
            if allowActivation { leases += 1 }
            return allowActivation
        }
        func deactivate() -> Bool {
            events.append("deactivate"); leases -= 1 // pinned RTCAudioSession consumes even on failure
            return allowDeactivation
        }
        func media(_ enabled: Bool) { events.append("media:\(enabled)") }
    }
    private final class Output: CallToneOutput, @unchecked Sendable {
        var heldStops = false
        var heldStarts = false
        var playSucceeds = true
        var mayHaveAudiblePlayback = false
        var token: UInt64 = 0
        var starts: [CallTones.Pattern] = []
        var stops: [@Sendable () -> Void] = []
        var pending: [@Sendable (Bool) -> Void] = []
        func stop(token: UInt64, completion: @escaping @Sendable () -> Void) {
            self.token = token
            let done: @Sendable () -> Void = { [weak self] in self?.mayHaveAudiblePlayback = false; completion() }
            if heldStops { stops.append(done) } else { done() }
        }
        func start(_ pattern: CallTones.Pattern, token: UInt64, deadline: TimeInterval?,
                   completion: @escaping @Sendable (Bool) -> Void) {
            starts.append(pattern)
            let done: @Sendable (Bool) -> Void = { [weak self] accepted in
                if self?.token == token { self?.mayHaveAudiblePlayback = accepted && pattern != .keepAlive }
                completion(accepted) // deliberately permit a late true callback to test the driver's fence
            }
            if heldStarts { pending.append(done) } else { done(playSucceeds) }
        }
    }
    private final class Timers: @unchecked Sendable {
        let clock: Clock
        var work: [(TimeInterval, DispatchWorkItem)] = []
        init(_ clock: Clock) { self.clock = clock }
        func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) { work.append((clock.now + delay, item)) }
        func advance(_ seconds: TimeInterval) {
            clock.now += seconds
            let due = work.filter { $0.0 <= clock.now }; work.removeAll { $0.0 <= clock.now }
            for (_, item) in due { item.perform() }
        }
    }
    private final class Fixture {
        let queue = DispatchQueue(label: "test.call-tones")
        let session = Session()
        let output = Output()
        let clock = Clock()
        let timers: Timers
        let tones: CallTones
        init() {
            let c = clock, t = Timers(clock); timers = t
            tones = CallTones(queue: queue, session: session, output: output,
                              now: { c.now }, schedule: { delay, item in t.schedule(delay, item) })
        }
        func changed(_ state: CallController.State, id: String = "c1", reason: CallBody.EndReason? = nil) {
            queue.sync { tones.changed(state: state, callId: id, reason: reason) }; drain()
        }
        func drain() { for _ in 0..<4 { queue.sync {} } }
        var started: CallTones.Sound? { queue.sync { tones.confirmedStart } }
        func advance(_ seconds: TimeInterval) { queue.sync { timers.advance(seconds) }; drain() }
    }

    func testEachToneIsAParseableWaveWithExactDurations() throws {
        for (wave, duration) in [(CallTones.ringPattern(), 4.0), (CallTones.ringbackPattern(), 5.0),
                                 (CallTones.busyPattern(), CallTones.busySeconds)] {
            let player = try AVAudioPlayer(data: Data(wave)) // parsing only, never play()
            XCTAssertEqual(player.duration, duration, accuracy: 1.0 / Double(CallTones.sampleRate))
        }
        XCTAssertEqual(CallTones.busyPattern().count, 44 + CallTones.sampleRate * 2 * 2)
    }
    func testRingbackHasExactlyOneSecondOfSignalThenFourSecondsOfZeroSamples() {
        let wave = CallTones.ringbackPattern(), boundary = 44 + CallTones.sampleRate * 2
        XCTAssertTrue(wave[44..<boundary].contains { $0 != 0 })
        XCTAssertTrue(wave[boundary...].allSatisfy { $0 == 0 })
    }
    func testOutgoingRingbackStopsForConnectingAndConnected() {
        let f = Fixture(); f.changed(.starting); XCTAssertNil(f.started)
        f.changed(.outgoing); XCTAssertEqual(f.started, .ringback)
        f.changed(.connecting); XCTAssertNil(f.started)
        f.changed(.connected); XCTAssertNil(f.started)
    }
    func testOnlyThreeOutgoingRingingReasonsProduceBusy() {
        for reason in CallBody.EndReason.allCases {
            let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.ended, reason: reason)
            XCTAssertEqual(f.started, [CallBody.EndReason.busy, .reject, .timeout].contains(reason) ? .busy : nil)
        }
    }
    func testIncomingRejectionAndAnsweredCallNeverProduceBusy() {
        let f = Fixture(); f.changed(.incoming); f.changed(.ended, reason: .reject); XCTAssertNil(f.started)
        f.changed(.starting, id: "c2"); f.changed(.outgoing, id: "c2"); f.changed(.connected, id: "c2")
        f.changed(.ended, id: "c2", reason: .busy); XCTAssertNil(f.started)
    }
    func testDuplicatePublicationDoesNotRestartPlayback() {
        let f = Fixture(); f.changed(.incoming)
        let count = f.output.starts.count
        f.changed(.incoming); XCTAssertEqual(f.output.starts.count, count)
    }
    func testNewIncomingIdGetsItsOwnDeadlineEvenWithoutIntermediateEnded() {
        let f = Fixture(); f.changed(.incoming); f.advance(50)
        f.changed(.incoming, id: "c2"); f.advance(11); XCTAssertEqual(f.started, .ring)
        f.advance(49); XCTAssertNil(f.started)
    }
    func testIncomingLimitActuallyStopsOutputAndReleasesAmbientSession() {
        let f = Fixture(); f.changed(.incoming); XCTAssertEqual(f.started, .ring)
        f.advance(60); XCTAssertNil(f.started); XCTAssertEqual(f.session.events.last, "deactivate")
        f.changed(.incoming); XCTAssertNil(f.started, "same presentation cannot extend expired ring")
    }
    func testBusyExpiresAndReleasesOutputSessionAfterTwoSeconds() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.ended, reason: .busy)
        f.advance(1.9); XCTAssertEqual(f.started, .busy)
        f.advance(0.1); XCTAssertNil(f.started); XCTAssertEqual(f.session.events.last, "deactivate")
    }
    func testPlaybackWaitsForSessionAndSessionSwitchWaitsForStopAcknowledgement() {
        let f = Fixture(); f.output.heldStops = true
        f.changed(.incoming)
        XCTAssertTrue(f.output.starts.isEmpty); XCTAssertTrue(f.session.events.filter { $0.hasPrefix("activate") }.isEmpty)
        f.queue.sync { f.output.heldStops = false; let work = f.output.stops; f.output.stops.removeAll(); work.forEach { $0() } }
        f.drain(); XCTAssertEqual(f.session.events.first { $0.hasPrefix("activate") }, "activate:incoming")
        XCTAssertEqual(f.started, .ring)
    }
    func testFailedPlayNeverCountsAsStarted() {
        let f = Fixture(); f.output.playSucceeds = false; f.changed(.incoming)
        XCTAssertNil(f.started); XCTAssertNotNil(f.queue.sync { f.tones.lastFailure })
    }
    func testFailedActivationNeverStartsAPlayer() {
        let f = Fixture(); f.session.allowActivation = false; f.changed(.incoming)
        XCTAssertTrue(f.output.starts.isEmpty); XCTAssertNil(f.started)
    }
    func testDelayedStartCompletionCannotResurrectEndedCall() {
        let f = Fixture(); f.output.heldStarts = true; f.changed(.incoming)
        f.changed(.ended, reason: .cancel)
        f.queue.sync { f.output.pending.forEach { $0(true) }; f.output.pending.removeAll() }
        f.drain(); XCTAssertNil(f.started)
    }
    func testOldBusyDeadlineCannotReleaseReplacementCall() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.ended, reason: .busy)
        f.changed(.starting, id: "c2"); f.changed(.outgoing, id: "c2")
        let releases = f.session.events.filter { $0 == "deactivate" }.count
        f.advance(3); XCTAssertEqual(f.started, .ringback)
        XCTAssertEqual(f.session.events.filter { $0 == "deactivate" }.count, releases)
    }
    func testIncomingPausesInBackgroundWithoutResettingDeadline() {
        let f = Fixture(); f.changed(.incoming); f.advance(20)
        f.queue.sync { f.tones.setForeground(false) }; f.drain(); XCTAssertNil(f.started)
        f.advance(20); f.queue.sync { f.tones.setForeground(true) }; f.drain(); XCTAssertEqual(f.started, .ring)
        f.advance(20); XCTAssertNil(f.started)
    }
    func testAbandonedAnswerRestoresAmbientWithoutExtendingRingDeadline() {
        let f = Fixture(); f.changed(.incoming); f.advance(10)
        f.queue.sync { f.tones.prepareCall() }; f.drain(); XCTAssertNil(f.started)
        f.queue.sync { f.tones.restoreIncoming() }; f.drain(); XCTAssertEqual(f.started, .ring)
        f.advance(50); XCTAssertNil(f.started)
    }
    func testInterruptionResumeCannotResurrectEndedCallOrCapture() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.connected)
        f.queue.sync { f.tones.setInterrupted(true) }; f.drain()
        f.changed(.ended, reason: .failed)
        let count = f.session.events.filter { $0.hasPrefix("activate") }.count
        f.queue.sync { f.tones.setInterrupted(false) }; f.drain()
        XCTAssertEqual(f.session.events.filter { $0.hasPrefix("activate") }.count, count)
        XCTAssertNil(f.started)
    }
    func testMediaResetDoesNotPermanentlySilenceLaterCalls() {
        let f = Fixture(); f.changed(.incoming)
        f.queue.sync { f.tones.mediaServicesReset() }; f.drain()
        f.changed(.ended, reason: .failed)
        f.changed(.starting, id: "c2"); f.changed(.outgoing, id: "c2")
        XCTAssertEqual(f.started, .ringback)
    }

    func testConnectedMediaDoesNotWaitForHeldSilentKeepaliveStop() {
        let f = Fixture(); f.changed(.starting)
        f.output.heldStops = true
        f.queue.sync { f.tones.enableAudio() }
        XCTAssertEqual(f.session.events.last, "media:true", "silent player must not stall connected media")
        f.queue.sync { f.tones.quiesceMedia() }
        XCTAssertEqual(f.session.events.last, "media:false", "capture revocation must not wait for player I/O")
        f.queue.sync {
            f.output.heldStops = false
            let work = f.output.stops; f.output.stops.removeAll(); work.forEach { $0() }
        }
        f.drain()
    }
    func testAudibleRingbackMustStopBeforeConnectedCapture() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing)
        f.output.heldStops = true
        let before = f.session.events.filter { $0 == "media:true" }.count
        f.queue.sync { f.tones.enableAudio() }
        XCTAssertEqual(f.session.events.filter { $0 == "media:true" }.count, before)
        f.queue.sync {
            f.output.heldStops = false
            let work = f.output.stops; f.output.stops.removeAll(); work.forEach { $0() }
        }
        f.drain(); XCTAssertEqual(f.session.events.last, "media:true")
    }

    func testReleaseCompletionSurvivesSupersedingFailedActivation() {
        let f = Fixture(); f.output.heldStops = true; f.session.allowActivation = false
        let session = f.session
        f.queue.sync { f.tones.release { session.released += 1 } }
        f.changed(.incoming)
        f.queue.sync {
            f.output.heldStops = false
            let work = f.output.stops; f.output.stops.removeAll(); work.forEach { $0() }
        }
        f.drain(); XCTAssertEqual(session.released, 1)
    }
    func testFailedDeactivationConsumesLeaseAndResumeAcquiresFreshLeaseWithoutCapture() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.connected)
        let captures = f.session.events.filter { $0 == "media:true" }.count
        f.session.allowDeactivation = false
        f.queue.sync { f.tones.setInterrupted(true) }; f.drain()
        XCTAssertEqual(f.session.leases, 0)
        f.session.allowDeactivation = true
        f.queue.sync { f.tones.setInterrupted(false) }; f.drain()
        XCTAssertEqual(f.session.leases, 1)
        XCTAssertEqual(f.session.events.filter { $0 == "media:true" }.count, captures)
        f.queue.sync { f.tones.release() }; f.drain(); XCTAssertEqual(f.session.leases, 0)
    }
    func testFreshIntentRecoversWhenInterruptionEndWasNotDelivered() {
        let f = Fixture(); f.changed(.starting)
        let before = f.session.events.count
        f.queue.sync { f.tones.setInterrupted(true); f.tones.release(); f.tones.prepareCall() }; f.drain()
        XCTAssertEqual(f.session.leases, 1)
        let later = Array(f.session.events.dropFirst(before))
        XCTAssertEqual(later.filter { $0 == "deactivate" || $0.hasPrefix("activate") }, ["deactivate", "activate:call"])
        XCTAssertFalse(later.contains("media:true"))
    }
    func testResetBalancesRetainedSDKLeaseBeforeReactivation() {
        let f = Fixture(); f.changed(.incoming); XCTAssertEqual(f.session.leases, 1)
        f.queue.sync { f.tones.mediaServicesReset() }; f.drain()
        XCTAssertEqual(f.session.leases, 1, "SDK reset does not erase activationCount")
        f.queue.sync { f.tones.release() }; f.drain(); XCTAssertEqual(f.session.leases, 0)
    }

    func testCoalescedInterruptionResumeRefreshesTheSessionAfterHeldStop() {
        for viaForeground in [false, true] {
            let f = Fixture(); f.changed(.incoming)
            let before = f.session.events.count
            f.output.heldStops = true
            f.queue.sync {
                f.tones.setInterrupted(true)
                if viaForeground { f.tones.setForeground(true) } else { f.tones.setInterrupted(false) }
                f.output.heldStops = false
                let work = f.output.stops; f.output.stops.removeAll(); work.forEach { $0() }
            }
            f.drain()
            let later = Array(f.session.events.dropFirst(before))
            XCTAssertEqual(later.filter { $0 == "deactivate" || $0.hasPrefix("activate") },
                           ["deactivate", "activate:incoming"])
            XCTAssertEqual(f.session.leases, 1)
            XCTAssertFalse(later.contains("media:true"))
            XCTAssertEqual(f.started, .ring)
        }
    }

    func testBusyCannotAcquireNewSessionAfterInterruptionOrReset() {
        for reset in [false, true] {
            let f = Fixture(); f.changed(.starting); f.changed(.outgoing); f.changed(.ended, reason: .busy)
            let activations = f.session.events.filter { $0.hasPrefix("activate") }.count
            f.queue.sync {
                if reset { f.tones.mediaServicesReset() }
                else { f.tones.setInterrupted(true); f.tones.setInterrupted(false) }
            }
            f.drain()
            XCTAssertNil(f.started)
            XCTAssertEqual(f.session.leases, 0)
            XCTAssertEqual(f.session.events.filter { $0.hasPrefix("activate") }.count, activations)
        }
    }

    func testInactivePermissionOverlayDoesNotCancelPreparationButBackgroundDoes() {
        let f = Fixture()
        f.queue.sync { f.tones.prepareCall() }; f.drain()
        f.queue.sync { f.tones.setForeground(false) }; f.drain()
        XCTAssertEqual(f.session.leases, 1, "inactive is not background")
        f.queue.sync { f.tones.cancelPreparationForBackground() }; f.drain()
        XCTAssertEqual(f.session.leases, 0)
        XCTAssertNil(f.started)
    }

    func testTerminalToneNeverEnablesCaptureAndQuiesceIsImmediate() {
        let f = Fixture(); f.changed(.starting); f.changed(.outgoing)
        f.queue.sync { f.tones.quiesceMedia() }; f.changed(.ended, reason: .busy)
        XCTAssertFalse(f.session.events.contains("media:true")); XCTAssertEqual(f.started, .busy)
        f.queue.sync { f.tones.release() }; f.drain(); XCTAssertNil(f.started)
    }
}
