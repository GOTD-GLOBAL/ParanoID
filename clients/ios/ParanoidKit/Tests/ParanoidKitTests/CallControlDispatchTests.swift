import Foundation
import ParanoidKit
import XCTest

/// C1: a real StateOwner dispatch is held while authenticated controller input
/// replaces A with B. Only media/signaling ports are fakes; no sockets/Keychain.
final class CallControlDispatchTests: XCTestCase {
    private enum Action: CaseIterable, Sendable { case end, reject, hangup, mute, speaker }
    private enum UnexpectedWrite: Error { case save }
    private final class NoWrites: SnapshotSink {
        func save(_ snapshot: String) throws { throw UnexpectedWrite.save }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let held = waiters
            waiters.removeAll()
            for waiter in held { waiter.resume() }
        }
    }

    /// Test fixture only. Every operation/read after construction is inside
    /// owner.perform; actual controllers check owner.isOnOwner at runtime.
    private final class Rig: @unchecked Sendable {
        static let aID = String(repeating: "a", count: 64)
        static let bID = String(repeating: "c", count: 64)
        static let receiverID = String(repeating: "b", count: 64)
        let clock = CallTestClock()
        let aPorts = CallTestPorts()
        let bPorts = CallTestPorts()
        let receiverPorts = CallTestPorts()
        let a: CallController
        let b: CallController
        let receiver: CallController
        private var delayedB: CallTestSent?

        init(owner: StateOwner) {
            a = CallController(clock: clock.clock, owner: owner, sender: aPorts,
                               media: aPorts, observer: aPorts)
            b = CallController(clock: clock.clock, owner: owner, sender: bPorts,
                               media: bPorts, observer: bPorts)
            receiver = CallController(clock: clock.clock, owner: owner, sender: receiverPorts,
                                      media: receiverPorts, observer: receiverPorts)
            aPorts.controller = a
            bPorts.controller = b
            receiverPorts.controller = receiver
        }

        private func deliver(_ source: CallTestPorts, to destination: CallController,
                             from account: String) throws {
            let sent = try XCTUnwrap(source.take())
            destination.received(account: account, json: try sent.body.encoded())
        }

        func ringWithBReady() throws {
            a.connection(true)
            b.connection(true)
            receiver.connection(true)
            // Both readiness slots exist BEFORE A's offer. B is not an
            // unsolicited offer and never bypasses admission or busy checks.
            a.start(account: Self.receiverID, microphonePermission: true)
            try deliver(aPorts, to: receiver, from: Self.aID)
            try deliver(receiverPorts, to: a, from: Self.receiverID)
            b.start(account: Self.receiverID, microphonePermission: true)
            try deliver(bPorts, to: receiver, from: Self.bID)
            try deliver(receiverPorts, to: b, from: Self.receiverID)
            a.localDescription(a.generation, sdp: CallBodyTests.sdp)
            try deliver(aPorts, to: receiver, from: Self.aID)
            b.localDescription(b.generation, sdp: CallBodyTests.sdp)
            delayedB = try XCTUnwrap(bPorts.take())
            XCTAssertEqual(receiver.currentState, .incoming)
            XCTAssertEqual(receiver.presentation.account, Self.aID)
        }

        func replaceAWithB() throws {
            a.hangup() // authenticated remote end, not a user control on receiver
            try deliver(aPorts, to: receiver, from: Self.aID)
            XCTAssertEqual(receiver.currentState, .ended)
            let offer = try XCTUnwrap(delayedB)
            delayedB = nil
            receiver.received(account: Self.bID, json: try offer.body.encoded())
            XCTAssertEqual(receiver.currentState, .incoming)
            XCTAssertEqual(receiver.presentation.account, Self.bID)
        }

        func apply(_ action: Action, callId: String, generation: CallGeneration) {
            switch action {
            case .end: receiver.end(callId: callId, generation: generation)
            case .reject: receiver.reject(callId: callId, generation: generation)
            case .hangup: receiver.hangup(callId: callId, generation: generation)
            case .mute: receiver.mute(true, callId: callId, generation: generation)
            case .speaker: receiver.speaker(true, callId: callId, generation: generation)
            }
        }

        var effects: Effects {
            Effects(presentation: receiver.presentation, sent: receiverPorts.everySent.count,
                    closes: receiverPorts.closes, answers: receiverPorts.answers,
                    muted: receiverPorts.muted, speaker: receiverPorts.speaker)
        }
    }

    private struct Effects: Equatable, Sendable {
        let presentation: CallPresentation
        let sent: Int
        let closes: Int
        let answers: Int
        let muted: Bool
        let speaker: Bool
    }

    private func makeOwner() throws -> StateOwner {
        let trust = try ServiceTrust(realm: "https://127.0.0.2:38443",
                                     pin: String(repeating: "ab", count: 32))
        return StateOwner(client: try SelfServiceClient(saved: nil, sink: NoWrites(), fixture: trust))
    }

    private func assertDelayed(_ action: Action) async throws {
        let owner = try makeOwner()
        let rig = Rig(owner: owner)
        let old = try await owner.perform { _ in
            try rig.ringWithBReady()
            return rig.receiver.presentation
        }
        let queued = Gate()
        let release = Gate()
        // Models the final queued UI->owner action without blocking that owner:
        // remote A-end/B-offer processing must still be able to run.
        let pending = Task {
            await queued.open()
            await release.wait()
            try await owner.perform { _ in
                rig.apply(action, callId: old.callId, generation: old.generation)
            }
        }
        await queued.wait()
        let before: Effects
        do {
            before = try await owner.perform { _ in
                try rig.replaceAWithB()
                XCTAssertNotEqual(rig.receiver.presentation.callId, old.callId)
                XCTAssertNotEqual(rig.receiver.presentation.generation, old.generation)
                return rig.effects
            }
        } catch {
            await release.open()
            _ = try? await pending.value
            throw error
        }
        await release.open()
        try await pending.value
        let after = try await owner.perform { _ in rig.effects }
        XCTAssertEqual(after, before, "stale control must not change B or emit any signal/media operation")
        XCTAssertEqual(after.presentation.state, .incoming)
    }

    func testDelayedEndDoesNotRejectReplacement() async throws { try await assertDelayed(.end) }
    func testDelayedRejectDoesNotRejectReplacement() async throws { try await assertDelayed(.reject) }
    func testDelayedHangupDoesNotEndReplacement() async throws { try await assertDelayed(.hangup) }
    func testDelayedMuteDoesNotChangeReplacement() async throws { try await assertDelayed(.mute) }
    func testDelayedSpeakerDoesNotChangeReplacement() async throws { try await assertDelayed(.speaker) }

    func testBothTargetFieldsAreRequiredAndMatchingActionsStillWork() async throws {
        for action in Action.allCases {
            let owner = try makeOwner()
            let rig = Rig(owner: owner)
            try await owner.perform { _ in
                try rig.ringWithBReady()
                let old = rig.receiver.presentation
                try rig.replaceAWithB()
                let current = rig.receiver.presentation
                let before = rig.effects
                rig.apply(action, callId: old.callId, generation: current.generation)
                rig.apply(action, callId: current.callId, generation: old.generation)
                XCTAssertEqual(rig.effects, before, "either mismatched field must reject the action")
                rig.apply(action, callId: current.callId, generation: current.generation)
                switch action {
                case .end, .reject, .hangup:
                    XCTAssertEqual(rig.receiver.currentState, .ended)
                    XCTAssertEqual(rig.receiverPorts.everySent.last?.account, Rig.bID)
                case .mute: XCTAssertTrue(rig.receiver.presentation.muted)
                case .speaker: XCTAssertTrue(rig.receiver.presentation.speaker)
                }
            }
        }
    }

    func testMatchingEndPreservesCancelHangupAndMatchingMediaControls() {
        let outgoing = CallPair()
        outgoing.alice.start(account: CallPair.bob, microphonePermission: true)
        let dialing = outgoing.alice.presentation
        outgoing.alice.end(callId: dialing.callId, generation: dialing.generation)
        XCTAssertEqual(outgoing.alice.presentation.reason, .cancel)

        let connected = CallPair()
        connected.connect()
        let active = connected.bob.presentation
        connected.bob.mute(true, callId: active.callId, generation: active.generation)
        connected.bob.speaker(true, callId: active.callId, generation: active.generation)
        XCTAssertTrue(connected.bobPorts.muted)
        XCTAssertTrue(connected.bobPorts.speaker)
        connected.bob.end(callId: active.callId, generation: active.generation)
        XCTAssertEqual(connected.bob.presentation.reason, .hangup)
    }
}

#if C1_LEGACY_BASELINE
// Only used by test_call_control_baseline.py in its disposable cb52330 worktree.
// Adapt new test signatures to the OLD shipped coordinator/controller behavior.
// No target validation is added; all assertions above stay identical. Therefore
// baseline RED is wrong-call behavior, not merely a missing-overload compiler error.
extension CallController {
    func end(callId: String, generation: CallGeneration) {
        if currentState == .incoming { reject() }
        else if isActive { hangup() }
    }
    func reject(callId: String, generation: CallGeneration) { reject() }
    func hangup(callId: String, generation: CallGeneration) { hangup() }
    func mute(_ muted: Bool, callId: String, generation: CallGeneration) { mute(muted) }
    func speaker(_ speaker: Bool, callId: String, generation: CallGeneration) { self.speaker(speaker) }
}
#endif
