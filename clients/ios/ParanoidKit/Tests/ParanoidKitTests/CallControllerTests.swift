import Foundation
import ParanoidKit
import XCTest

/// The call controller's clock: every deadline, every ceiling, and the eleven
/// scenarios the Android smoke walks the same state machine through.
///
/// `CallBodyTests` owns the body table and the happy path over the fake ports.
/// This file owns what only time can decide — the 45-second ring, the
/// 30 seconds of peer silence, the 10-second ICE recovery, the 15-minute call,
/// the 10-second heartbeat with one outstanding at a time, the knock ceilings,
/// the bounded terminal memory and the clock-change verdict — and it transcribes
/// every scenario of `clients/android/test/CallControllerSmoke.java` so that the
/// two clients refuse and allow the same things.
///
/// The Android labels are carried over verbatim, because they are what
/// `clients/ios/test_call_controller_parity.py` compares: every
/// `check(…, "<label>")` of the smoke must appear here as the message of the
/// assertion that mirrors it. Where the two clients genuinely differ — the size
/// of the description this client is willing to send, which the frame budget
/// caps below the core's own limit — the label is kept and the message says
/// what decides it here.
final class CallControllerTests: XCTestCase {
    // MARK: - Helpers

    /// The next control a side enqueued. It is `CallControllerSmoke.Port.take`
    /// (`clients/android/test/CallControllerSmoke.java:44`), whose failure
    /// message this carries.
    private func take(_ port: CallTestPorts,
                      file: StaticString = #filePath,
                      line: UInt = #line) throws -> CallTestSent {
        try XCTUnwrap(port.take(), "expected outgoing control", file: file, line: line)
    }

    /// The call-v2 fixture description padded with one attribute line that
    /// ``SdpExtract`` ignores, to exactly `bytes` UTF-8 bytes.
    private static func padded(toBytes bytes: Int) -> String {
        let fixed = CallBodyTests.sdp + "a=x:\r\n"
        let filler = bytes - fixed.utf8.count
        precondition(filler >= 0, "the fixture description is already larger than \(bytes) bytes")
        let padded = CallBodyTests.sdp + "a=x:" + String(repeating: "y", count: filler) + "\r\n"
        precondition(padded.utf8.count == bytes)
        return padded
    }

    // MARK: - permissionAndFreshness

    /// `CallControllerSmoke.permissionAndFreshness`
    /// (`clients/android/test/CallControllerSmoke.java:55-65`).
    func testPermissionAndFreshness() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: false)
        XCTAssertTrue(pair.alicePorts.pendingCount == 0 && pair.alicePorts.offers == 0,
                      "denied outgoing permission cannot send or capture")

        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertEqual(pair.alicePorts.offers, 0, "knock cannot create media")

        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertEqual(pair.bobPorts.offers + pair.bobPorts.answers, 0,
                       "incoming knock cannot create media")

        pair.deliver(to: pair.alice, from: CallPair.bob, try take(pair.bobPorts))
        XCTAssertEqual(pair.alicePorts.offers, 1, "ready permits only explicit caller media")

        pair.alice.localDescription(pair.alice.generation, sdp: CallBodyTests.sdp)
        let offer = try take(pair.alicePorts)

        // A restart destroys the readiness slots, so the same authenticated
        // offer finds nothing to ring (`voice-v1.md:90-91`).
        let restartedPorts = CallTestPorts()
        let restarted = CallController(clock: pair.time.clock, owner: pair.owner,
                                       sender: restartedPorts, media: restartedPorts,
                                       observer: restartedPorts)
        restartedPorts.controller = restarted
        restarted.connection(true)
        pair.deliver(to: restarted, from: CallPair.alice, offer)
        XCTAssertNotEqual(restarted.currentState, .incoming, "old offer cannot ring after restart")

        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming, "matching fresh offer rings")
        XCTAssertEqual(pair.bobPorts.answers, 0, "incoming ring never captures")

        pair.bob.answer(microphonePermission: false)
        XCTAssertTrue(pair.bobPorts.answers == 0 && !pair.bob.isActive,
                      "denied Answer closes without capture")
    }

    // MARK: - lifecycleAndCommit

    /// `CallControllerSmoke.lifecycleAndCommit`
    /// (`clients/android/test/CallControllerSmoke.java:66-75`).
    func testLifecycleAndCommit() throws {
        let pair = CallPair()
        pair.connect()
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 1, "caller applies authenticated answer")
        XCTAssertEqual(pair.alice.currentState, .connected, "actual media callback drives connected")

        pair.alice.mute(true)
        pair.alice.speaker(true)
        XCTAssertTrue(pair.alicePorts.muted && pair.alicePorts.speaker,
                      "route and mute reach actual media port")

        let stale = pair.alice.generation
        pair.alice.hangup()
        XCTAssertTrue(!pair.alice.isActive && pair.alicePorts.closes > 0, "local end cleans media")

        let before = pair.alicePorts.pendingCount
        pair.alice.localDescription(stale, sdp: CallBodyTests.sdp)
        pair.alice.mediaState(stale, .connected)
        XCTAssertTrue(!pair.alice.isActive && pair.alicePorts.pendingCount == before,
                      "stale callbacks cannot recreate call or signaling")

        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertTrue(!pair.bob.isActive && pair.bobPorts.closes > 0, "remote end cleans media")

        let failed = CallPair()
        failed.alicePorts.failSave = true
        failed.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertTrue(!failed.alice.isActive && failed.alicePorts.offers == 0,
                      "failed durable enqueue grants no media authority")
    }

    // MARK: - wrongContextsAndReplay

    /// `CallControllerSmoke.wrongContextsAndReplay`
    /// (`clients/android/test/CallControllerSmoke.java:76-85`).
    func testWrongContextsAndReplay() throws {
        let pair = CallPair()
        pair.ready()
        pair.alice.localDescription(pair.alice.generation, sdp: CallBodyTests.sdp)
        let offer = try take(pair.alicePorts)

        pair.deliver(to: pair.bob, from: CallPair.alice, offer) { members in
            members["callee_nonce"] = String(repeating: "f", count: 64)
        }
        XCTAssertNotEqual(pair.bob.currentState, .incoming, "wrong readiness nonce cannot ring")

        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming,
                       "invalid event did not consume legitimate slot")

        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertTrue(pair.bobPorts.answers == 0 && pair.bob.currentState == .incoming,
                      "duplicate offer cannot capture or reset call")

        pair.bob.reject()
        XCTAssertFalse(pair.bob.isActive, "explicit rejection terminal")
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertFalse(pair.bob.isActive, "late offer cannot resurrect rejected call")

        let expired = CallPair()
        expired.ready()
        expired.time.advance(millis: CallController.ttlMillis + 1)
        expired.bob.tick()
        expired.alice.localDescription(expired.alice.generation, sdp: CallBodyTests.sdp)
        if let late = expired.alicePorts.take() {
            expired.deliver(to: expired.bob, from: CallPair.alice, late)
        }
        XCTAssertNotEqual(expired.bob.currentState, .incoming, "expired readiness cannot ring")
    }

    // MARK: - heartbeatAndAuthority

    /// `CallControllerSmoke.heartbeatAndAuthority`
    /// (`clients/android/test/CallControllerSmoke.java:86-103`).
    func testHeartbeatAndAuthority() throws {
        let pair = CallPair()
        pair.connect()
        pair.time.advance(millis: CallController.heartbeatMillis + 1)
        pair.alice.tick()
        pair.bob.tick()
        XCTAssertEqual(try take(pair.alicePorts).body.kind, .heartbeat,
                       "active caller sends authenticated heartbeat")
        XCTAssertEqual(try take(pair.bobPorts).body.kind, .heartbeat,
                       "active callee sends authenticated heartbeat")

        pair.time.advance(millis: CallController.silenceMillis - CallController.heartbeatMillis + 1)
        pair.alice.tick()
        pair.bob.tick()
        XCTAssertTrue(!pair.alice.isActive && !pair.bob.isActive,
                      "peer silence ends both media paths")
        XCTAssertEqual(pair.alice.presentation.reason, .timeout, "and it ends as a timeout")

        let revoked = CallPair()
        revoked.connect()
        revoked.alice.authorizationLost()
        XCTAssertTrue(!revoked.alice.isActive && revoked.alicePorts.closes > 0,
                      "known auth loss stops immediately")

        let blocked = CallPair()
        blocked.connect()
        blocked.bob.block(account: CallPair.alice)
        XCTAssertTrue(!blocked.bob.isActive && blocked.bobPorts.closes > 0,
                      "block stops active peer")

        let pending = CallPair()
        pending.connect()
        pending.alicePorts.holdHeartbeat = true
        pending.time.advance(millis: CallController.heartbeatMillis + 1)
        pending.alice.tick()
        pending.time.advance(millis: CallController.heartbeatMillis + 1)
        pending.alice.tick()
        XCTAssertEqual(pending.alicePorts.pendingCount, 1,
                       "only one heartbeat may await actual server acceptance")

        let offline = CallPair()
        offline.alice.connection(false)
        offline.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertTrue(offline.alicePorts.pendingCount == 0 && offline.alicePorts.offers == 0,
                      "offline call does not enter durable outbox")

        let lapse = CallPair()
        lapse.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try take(lapse.alicePorts)
        lapse.bob.connection(false)
        lapse.deliver(to: lapse.bob, from: CallPair.alice, knock)
        XCTAssertEqual(lapse.bobPorts.pendingCount, 1,
                       "authenticated durable knock is processed despite transient offline flag")

        let relay = CallPair()
        relay.alicePorts.deferMedia = true
        relay.alice.start(account: CallPair.bob, microphonePermission: true)
        relay.deliver(to: relay.bob, from: CallPair.alice, try take(relay.alicePorts))
        relay.alice.connection(false)
        relay.deliver(to: relay.alice, from: CallPair.bob, try take(relay.bobPorts))
        XCTAssertEqual(relay.alice.currentState, .authorizing,
                       "ready during transient offline still advances caller intent")

        let drop = CallPair()
        drop.connect()
        drop.alice.connection(false)
        drop.time.advance(millis: CallController.heartbeatMillis + 1)
        drop.alice.tick()
        XCTAssertTrue(drop.alice.isActive,
                      "transient offline does not immediately end an active call")
        XCTAssertEqual(drop.alicePorts.pendingCount, 0,
                       "and no heartbeat backlog is built while the lane is down")
        drop.alice.connection(true)
        drop.time.advance(millis: 1)
        drop.alice.tick()
        XCTAssertGreaterThan(drop.alicePorts.pendingCount, 0,
                             "restored connection resumes heartbeats")
    }

    // MARK: - crossingAndClock

    /// `CallControllerSmoke.crossingAndClock`
    /// (`clients/android/test/CallControllerSmoke.java:104-109`).
    func testCrossingAndClock() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.bob.start(account: CallPair.alice, microphonePermission: true)
        let fromAlice = try take(pair.alicePorts)
        let fromBob = try take(pair.bobPorts)
        pair.deliver(to: pair.bob, from: CallPair.alice, fromAlice)
        pair.deliver(to: pair.alice, from: CallPair.bob, fromBob)
        while let sent = pair.alicePorts.take() {
            pair.deliver(to: pair.bob, from: CallPair.alice, sent)
        }
        while let sent = pair.bobPorts.take() {
            pair.deliver(to: pair.alice, from: CallPair.bob, sent)
        }
        XCTAssertTrue(!pair.alice.isActive && !pair.bob.isActive
                      && pair.alicePorts.offers + pair.bobPorts.offers == 0,
                      "crossing attempts end busy without implicit answer")
        XCTAssertEqual(pair.alice.presentation.reason, .busy, "and both sides say so")

        let jump = CallPair()
        jump.ready()
        jump.time.moveWall(millis: -60_000)
        jump.bob.tick()
        jump.alice.tick()
        XCTAssertFalse(jump.alice.isActive, "wall-clock rollback cannot extend negotiation")
        XCTAssertEqual(jump.alice.presentation.reason, .failed,
                       "a clock this device stopped trusting ends the call as failed")
    }

    // MARK: - answerBindingAndTerminal

    /// `CallControllerSmoke.answerBindingAndTerminal`
    /// (`clients/android/test/CallControllerSmoke.java:110-120`).
    func testAnswerBindingAndTerminal() throws {
        let pair = CallPair()
        pair.ring()
        pair.bob.answer(microphonePermission: true)
        pair.bob.localDescription(pair.bob.generation, sdp: CallBodyTests.answerSdp)
        let answer = try take(pair.bobPorts)

        pair.deliver(to: pair.alice, from: CallPair.bob, answer) { members in
            members["offer_digest"] = String(repeating: "f", count: 64)
        }
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 0,
                       "wrong offer digest never enters media engine")

        pair.deliver(to: pair.alice, from: CallPair.bob, answer) { members in
            members["caller_nonce"] = String(repeating: "f", count: 64)
        }
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 0,
                       "wrong caller nonce never enters media engine")

        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 1, "answer applies once")

        let cancel = CallPair()
        cancel.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try take(cancel.alicePorts)
        cancel.alice.hangup()
        cancel.deliver(to: cancel.bob, from: CallPair.alice, knock)
        cancel.deliver(to: cancel.alice, from: CallPair.bob, try take(cancel.bobPorts))
        XCTAssertTrue(cancel.alicePorts.offers == 0 && !cancel.alice.isActive,
                      "late ready cannot reopen caller intent")

        let end = CallPair()
        end.ready()
        end.alice.hangup()
        end.deliver(to: end.bob, from: CallPair.alice, try take(end.alicePorts))
        XCTAssertTrue(end.bobPorts.answers == 0 && !end.bob.isActive,
                      "post-ready pre-offer end closes readiness without capture")
    }

    // MARK: - engineLimitsAndCallbacks

    /// `CallControllerSmoke.engineLimitsAndCallbacks`
    /// (`clients/android/test/CallControllerSmoke.java:121-132`).
    func testEngineLimitsAndCallbacks() throws {
        let pair = CallPair()
        pair.connect()
        pair.alice.mediaState(pair.alice.generation, .disconnected)
        XCTAssertTrue(pair.alice.presentation.reconnecting,
                      "ICE loss is visible before its failure deadline")
        pair.time.advance(millis: CallController.disconnectedMillis - 1)
        pair.alice.tick()
        XCTAssertTrue(pair.alice.isActive, "brief ICE loss gets bounded recovery")

        pair.alice.mediaState(pair.alice.generation, .connected)
        pair.time.advance(millis: 1)
        pair.alice.tick()
        XCTAssertTrue(pair.alice.isActive && !pair.alice.presentation.reconnecting,
                      "ICE reconnection cancels disconnect deadline and presentation")

        pair.alice.mediaState(pair.alice.generation, .disconnected)
        pair.time.advance(millis: CallController.disconnectedMillis + 1)
        pair.alice.tick()
        XCTAssertFalse(pair.alice.isActive, "ICE disconnection deadline cleans media")
        XCTAssertEqual(pair.alice.presentation.reason, .failed, "and it ends as a failure")

        let large = CallPair()
        large.ready()
        large.alice.localDescription(large.alice.generation,
                                     sdp: String(repeating: "x", count: CallBody.maxSdpBytes + 1))
        XCTAssertTrue(!large.alice.isActive && large.alicePorts.closes > 0,
                      "oversized local SDP cleans capture before offer")

        let failed = CallPair()
        failed.ready()
        failed.alicePorts.failSave = true
        failed.alice.localDescription(failed.alice.generation, sdp: CallBodyTests.sdp)
        XCTAssertTrue(!failed.alice.isActive && failed.alicePorts.closes > 0,
                      "offer enqueue failure cleans already-created caller media")

        // Ninety healthy rounds of heartbeats in both directions: the peer is
        // never silent, so nothing but the fifteen-minute ceiling can stop it.
        let limited = CallPair()
        limited.connect()
        var rounds = 0
        while rounds < 90, limited.alice.isActive {
            rounds += 1
            limited.time.advance(millis: CallController.heartbeatMillis)
            limited.alice.tick()
            limited.bob.tick()
            while let sent = limited.alicePorts.take() {
                limited.deliver(to: limited.bob, from: CallPair.alice, sent)
            }
            while let sent = limited.bobPorts.take() {
                limited.deliver(to: limited.alice, from: CallPair.bob, sent)
            }
        }
        XCTAssertTrue(!limited.alice.isActive && !limited.bob.isActive,
                      "15-minute limit holds with healthy heartbeats")
        XCTAssertEqual(rounds, Int(CallController.maximumCallMillis / CallController.heartbeatMillis),
                       "and it holds at fifteen minutes exactly, not before")
    }

    // MARK: - delayedCompletionIsolation

    /// `CallControllerSmoke.delayedCompletionIsolation`
    /// (`clients/android/test/CallControllerSmoke.java:133-139`).
    func testDelayedCompletionIsolation() throws {
        let pair = CallPair()
        pair.alicePorts.deferSignals = true
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        let stale = pair.alice.generation

        pair.alice.hangup()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        let current = pair.alice.generation
        XCTAssertTrue(current != stale && pair.alice.isActive, "new intent has a fresh generation")

        // The first knock's completion, answered long after its call is gone.
        pair.alicePorts.settle(0, accepted: false)
        XCTAssertTrue(pair.alice.isActive && pair.alice.generation == current,
                      "late old rejection cannot terminate a new call")

        pair.alicePorts.settle(0, accepted: true)
        pair.alice.mediaState(stale, .failed)
        pair.alice.localDescription(stale, sdp: CallBodyTests.sdp)
        XCTAssertTrue(pair.alice.isActive && pair.alicePorts.offers == 0,
                      "old acceptance and media callbacks cannot mutate new intent")

        pair.alicePorts.settleLast(accepted: false)
        XCTAssertFalse(pair.alice.isActive, "current asynchronous enqueue failure still terminates")
    }

    // MARK: - cancelBeforeReadyDelivery

    /// `CallControllerSmoke.cancelBeforeReadyDelivery`
    /// (`clients/android/test/CallControllerSmoke.java:140-150`).
    func testCancelBeforeReadyDelivery() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertEqual(pair.bobPorts.pendingCount, 1,
                       "receiver readiness exists while ready response is delayed")

        pair.alice.hangup()
        let cancel = try take(pair.alicePorts)
        XCTAssertTrue(cancel.body.calleeNonce.isEmpty, "caller cannot know undelivered ready nonce")
        pair.deliver(to: pair.bob, from: CallPair.alice, cancel)

        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertEqual(pair.bobPorts.pendingCount, 2,
                       "pre-ready cancel releases peer readiness for immediate fresh knock")

        _ = pair.bobPorts.take()
        pair.deliver(to: pair.alice, from: CallPair.bob, try take(pair.bobPorts))
        XCTAssertEqual(pair.alicePorts.offers, 1,
                       "fresh ready after cancellation permits only fresh caller intent")

        let active = CallPair()
        active.ring()
        active.alice.hangup()
        let correct = try take(active.alicePorts)
        active.deliver(to: active.bob, from: CallPair.alice, correct) { members in
            members["callee_nonce"] = ""
            members["offer_digest"] = ""
        }
        XCTAssertTrue(active.bob.isActive && active.bob.currentState == .incoming,
                      "empty pre-ready end cannot terminate active ringing context")
        active.deliver(to: active.bob, from: CallPair.alice, correct)
        XCTAssertFalse(active.bob.isActive, "exact ringing end still terminates")
    }

    // MARK: - relayAuthorityBeforeCapture

    /// `CallControllerSmoke.relayAuthorityBeforeCapture`
    /// (`clients/android/test/CallControllerSmoke.java:151-165`).
    func testRelayAuthorityBeforeCapture() throws {
        let pair = CallPair()
        pair.alicePorts.deferMedia = true
        pair.ready()
        let generation = pair.alice.generation
        XCTAssertTrue(pair.alice.currentState == .authorizing && !pair.alice.presentation.mediaActive,
                      "issuer request waits without capture authority")

        pair.alice.mute(true)
        pair.alice.speaker(true)
        XCTAssertTrue(!pair.alicePorts.muted && !pair.alicePorts.speaker,
                      "pending authorization cannot open media routes")

        XCTAssertTrue(pair.alice.mediaAuthorized(generation, authorized: true)
                      && pair.alicePorts.muted && pair.alicePorts.speaker,
                      "validated current response applies retained intent")
        XCTAssertFalse(pair.alice.mediaAuthorized(generation, authorized: true),
                       "duplicate authorization cannot restart media")

        let cancelled = CallPair()
        cancelled.alicePorts.deferMedia = true
        cancelled.ready()
        let superseded = cancelled.alice.generation
        cancelled.alice.hangup()
        cancelled.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertTrue(!cancelled.alice.mediaAuthorized(superseded, authorized: true)
                      && cancelled.alice.isActive,
                      "late authorization cannot capture or terminate new intent")

        let denied = CallPair()
        denied.alicePorts.deferMedia = true
        denied.ready()
        XCTAssertTrue(!denied.alice.mediaAuthorized(denied.alice.generation, authorized: false)
                      && !denied.alice.isActive,
                      "issuer failure terminates before capture")

        let expired = CallPair()
        expired.alicePorts.deferMedia = true
        expired.ready()
        let late = expired.alice.generation
        expired.time.advance(millis: CallController.ttlMillis + 1)
        XCTAssertTrue(!expired.alice.mediaAuthorized(late, authorized: true) && !expired.alice.isActive,
                      "authorization cannot extend negotiation deadline")
        XCTAssertEqual(expired.alice.presentation.reason, .timeout,
                       "and the caller is told the window closed, not that anything failed")

        let receiver = CallPair()
        receiver.ring()
        receiver.bobPorts.deferMedia = true
        receiver.bob.answer(microphonePermission: true)
        XCTAssertTrue(receiver.bob.currentState == .authorizing
                      && !receiver.bob.presentation.mediaActive,
                      "explicit Answer still waits for relay authority")
        receiver.bob.authorizationLost()
        XCTAssertFalse(receiver.bob.mediaAuthorized(receiver.bob.generation, authorized: true),
                       "revoked consent never resumes")
    }

    // MARK: - videoConsentAndSignaling

    /// `CallControllerSmoke.videoConsentAndSignaling`, first half
    /// (`clients/android/test/CallControllerSmoke.java:166-192`).
    ///
    /// The camera is never opened by anything that arrives from the network:
    /// not a knock, not media authority, not a ring, not an answer. It opens
    /// once, from one explicit local toggle, and what the peer learns about it
    /// is one `media` control — never a change of the video section's
    /// direction, which stays `sendrecv` for the whole call
    /// (`call-v2.md:56-58`).
    func testVideoConsentAndSignaling() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try take(pair.alicePorts)
        XCTAssertTrue(knock.body.version == 2 && knock.body.video,
                      "v2 knock advertises video capability")

        pair.deliver(to: pair.bob, from: CallPair.alice, knock)
        XCTAssertEqual(pair.bobPorts.videoCalls, 0, "incoming knock never touches the camera")

        pair.deliver(to: pair.alice, from: CallPair.bob, try take(pair.bobPorts))
        XCTAssertTrue(pair.alicePorts.videoCalls == 0 && !pair.alicePorts.video,
                      "audio-first: media authority alone never opens the camera")

        pair.alice.localDescription(pair.alice.generation, sdp: CallBodyTests.sdp)
        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertEqual(pair.bobPorts.videoCalls, 0, "incoming ring never opens the camera")

        pair.bob.video(true, generation: pair.bob.generation)
        XCTAssertEqual(pair.bobPorts.videoCalls, 0, "video toggle before Answer is ignored (no media)")

        pair.bob.answer(microphonePermission: true)
        pair.bob.localDescription(pair.bob.generation, sdp: CallBodyTests.answerSdp)
        let answer = try take(pair.bobPorts)
        XCTAssertTrue(answer.body.kind == .answer && answer.body.video,
                      "answer body carries video flag")

        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        pair.alice.mediaState(pair.alice.generation, .connected)
        pair.bob.mediaState(pair.bob.generation, .connected)
        XCTAssertTrue(pair.alicePorts.pendingCount == 0 && pair.bobPorts.pendingCount == 0,
                      "no media control before anyone turns video on")

        pair.alice.speaker(false)
        pair.alice.video(true, generation: pair.alice.generation)
        XCTAssertTrue(pair.alicePorts.video && pair.alicePorts.videoCalls == 1
                      && pair.alicePorts.speaker && pair.alice.presentation.localVideo,
                      "explicit toggle opens camera and routes to speaker")

        let cameraOn = try take(pair.alicePorts)
        XCTAssertTrue(cameraOn.body.kind == .media && cameraOn.body.video && cameraOn.body.seq >= 2,
                      "authenticated media control announces camera on")

        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOn)
        XCTAssertTrue(pair.bob.presentation.remoteVideo && pair.bobPorts.videoCalls == 0,
                      "peer learns remote video without opening its own camera")
        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOn)
        XCTAssertTrue(pair.bob.presentation.remoteVideo, "replayed media control is idempotent")

        pair.alice.video(false, generation: pair.alice.generation)
        XCTAssertTrue(!pair.alicePorts.video && !pair.alicePorts.speaker
                      && !pair.alice.presentation.localVideo,
                      "video off restores previous audio route")
        let cameraOff = try take(pair.alicePorts)
        XCTAssertFalse(cameraOff.body.video, "media control announces camera off")
        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOff)
        XCTAssertFalse(pair.bob.presentation.remoteVideo, "peer sees camera off")

        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOn)
        XCTAssertFalse(pair.bob.presentation.remoteVideo,
                       "lower-sequence replay of camera-on is ignored")

        pair.time.advance(millis: CallController.heartbeatMillis + 1)
        pair.alice.tick()
        let heartbeat = try take(pair.alicePorts)
        XCTAssertTrue(heartbeat.body.kind == .heartbeat && !heartbeat.body.video,
                      "heartbeat never carries video")

        let before = pair.bobPorts.pendingCount
        pair.deliver(to: pair.bob, from: CallPair.alice, heartbeat) { $0["video"] = true }
        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOff) { $0["v"] = 1 }
        pair.deliver(to: pair.bob, from: CallPair.alice, cameraOff) { $0["video"] = "true" }
        XCTAssertTrue(pair.bob.isActive && pair.bobPorts.pendingCount == before,
                      "invalid video/v1 bodies are ignored without effect")

        pair.alice.hangup()
        XCTAssertTrue(!pair.alice.isActive && pair.alicePorts.closes > 0,
                      "hangup with video active closes engine")
    }

    /// `CallControllerSmoke.videoConsentAndSignaling`, second half
    /// (`clients/android/test/CallControllerSmoke.java:193-207`): the explicit
    /// video-call intent, the callee that turns its camera on while answering,
    /// a camera that cannot run, and the size of the description this client
    /// will send.
    func testVideoIntentAnnouncementAndCameraFailure() throws {
        let intent = CallPair()
        intent.alice.start(account: CallPair.bob, microphonePermission: true, videoIntent: true)
        intent.deliver(to: intent.bob, from: CallPair.alice, try take(intent.alicePorts))
        XCTAssertEqual(intent.alicePorts.videoCalls, 0, "video intent waits for media authority")

        intent.deliver(to: intent.alice, from: CallPair.bob, try take(intent.bobPorts))
        XCTAssertTrue(intent.alicePorts.video && intent.alicePorts.speaker
                      && intent.alice.presentation.localVideo,
                      "video-call intent opens camera only after ready+authorization")
        XCTAssertEqual(intent.alicePorts.pendingCount, 0,
                       "media control is deferred until the answer is known")

        let early = CallPair()
        early.ring()
        early.bob.answer(microphonePermission: true)
        early.bob.video(true, generation: early.bob.generation)
        XCTAssertTrue(early.bobPorts.video && early.bobPorts.pendingCount == 0,
                      "callee camera during negotiation is not announced before its answer")

        early.bob.localDescription(early.bob.generation, sdp: CallBodyTests.answerSdp)
        let sentAnswer = try take(early.bobPorts)
        let announcement = try take(early.bobPorts)
        XCTAssertTrue(sentAnswer.body.kind == .answer && announcement.body.kind == .media
                      && announcement.body.seq == 2,
                      "answer precedes media announcement")
        early.deliver(to: early.alice, from: CallPair.bob, sentAnswer)
        early.deliver(to: early.alice, from: CallPair.bob, announcement)
        XCTAssertTrue(early.alice.presentation.remoteVideo,
                      "caller learns callee camera announced after answer")

        let unavailable = CallPair()
        unavailable.connect()
        unavailable.alice.video(true, generation: unavailable.alice.generation)
        _ = try take(unavailable.alicePorts)
        unavailable.alice.videoUnavailable(unavailable.alice.generation)
        XCTAssertTrue(!unavailable.alicePorts.video && !unavailable.alice.presentation.localVideo
                      && !unavailable.alicePorts.speaker,
                      "camera failure stops capture, restores route, keeps call")
        let announcedOff = try take(unavailable.alicePorts)
        XCTAssertTrue(!announcedOff.body.video && unavailable.alice.isActive,
                      "camera failure announces off and keeps the call")

        // The two size checks. The core's `MAX_SDP` is 12288 bytes, but a call
        // control travels inside one frame2 envelope whose measured ceiling is
        // 10040 bytes, so this client holds what it sends to
        // `SdpExtract.maxSdpBytes` — 9000 — and a description above that is a
        // bug on this side that ends the call instead of travelling.
        let large = CallPair()
        large.ready()
        large.alice.localDescription(large.alice.generation,
                                     sdp: Self.padded(toBytes: CallBody.maxSdpBytes + 1))
        XCTAssertFalse(large.alice.isActive, "12288-byte SDP limit")

        let fits = CallPair()
        fits.ready()
        fits.alice.localDescription(fits.alice.generation,
                                    sdp: Self.padded(toBytes: SdpExtract.maxSdpBytes))
        XCTAssertTrue(fits.alice.isActive,
                      "12288-byte SDP accepted on Android; here the 9000-byte frame budget is the "
                      + "bound, and a description at exactly that size still travels")

        let overBudget = CallPair()
        overBudget.ready()
        overBudget.alice.localDescription(overBudget.alice.generation,
                                          sdp: Self.padded(toBytes: SdpExtract.maxSdpBytes + 1))
        XCTAssertFalse(overBudget.alice.isActive,
                       "one byte over the frame budget is already too much")
        XCTAssertEqual(overBudget.alice.presentation.reason, .failed,
                       "and it is this side's bug, not a timeout")
    }

    // MARK: - The camera and the call it was meant for

    /// Ends the live call on both sides and connects a fresh one, leaving both
    /// outboxes empty, so that an action taken in the first call can be
    /// delivered while the second is the one that is live.
    ///
    /// It is the shape of every asynchronous camera scenario: the tap, then a
    /// permission dialog or a hop onto this thread, and a different call by
    /// the time the answer arrives.
    private func replaceCall(_ pair: CallPair,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
        pair.alice.hangup()
        while let sent = pair.alicePorts.take() {
            pair.deliver(to: pair.bob, from: CallPair.alice, sent)
        }
        while pair.bobPorts.take() != nil {}
        XCTAssertTrue(!pair.alice.isActive && !pair.bob.isActive,
                      "the first call is over on both sides", file: file, line: line)
        pair.connect()
        XCTAssertTrue(pair.alice.currentState == .connected
                      && pair.alicePorts.pendingCount == 0 && pair.bobPorts.pendingCount == 0,
                      "the replacement is connected and nothing is left in either outbox",
                      file: file, line: line)
    }

    /// A camera action belongs to the call it was taken in, and to no other.
    ///
    /// The permission dialog is the delay that makes this reachable: the user
    /// presses «Включить камеру» in call A, the system asks for the camera, and
    /// the answer can arrive at any later moment — after A has ended and after
    /// an audio-only call B with a different peer has taken its place. A
    /// platform grant says this application may see a camera; it does not say
    /// which call the user meant, so the action carries the generation it was
    /// taken in and the state owner refuses it against the call that is live.
    /// Otherwise the grant opens the camera in B and announces it, over an
    /// authenticated `media` control, to a peer nobody turned a camera on for.
    func testADelayedCameraActionCannotReachTheCallThatReplacedItsOwn() throws {
        let pair = CallPair()
        pair.connect()
        // Pressed in A, with A's generation, before the dialog is raised.
        let tapped = pair.alice.generation
        try replaceCall(pair)
        XCTAssertNotEqual(pair.alice.generation, tapped,
                          "the call that replaced it is a different generation")

        let opened = pair.alicePorts.videoCalls
        pair.alice.video(true, generation: tapped)
        XCTAssertTrue(!pair.alicePorts.video && pair.alicePorts.videoCalls == opened
                      && !pair.alice.presentation.localVideo,
                      "a camera grant for a call that is over opens no camera in the call that "
                      + "replaced it")
        XCTAssertEqual(pair.alicePorts.pendingCount, 0,
                       "and the peer of that call is told nothing: no authenticated media control "
                       + "announces a camera nobody turned on for it")

        // The same crossing the other way round: the camera is legitimately on
        // in B when a "camera off" queued in A is finally delivered.
        pair.alice.video(true, generation: pair.alice.generation)
        let announced = try take(pair.alicePorts)
        XCTAssertTrue(announced.body.video && pair.alicePorts.video,
                      "the live call's own toggle still opens the camera and announces it")

        pair.alice.video(false, generation: tapped)
        XCTAssertTrue(pair.alicePorts.video && pair.alice.presentation.localVideo
                      && pair.alicePorts.pendingCount == 0,
                      "a camera action queued in a call that is over leaves the live call's "
                      + "camera exactly as its own user set it")
    }

    /// The camera the background took away comes back to the call it was taken
    /// from, and to nothing else (`call-v2.md:67-69`).
    ///
    /// "The user had it on" is a fact about one call. Recorded as a bare flag
    /// on the application it would say only *that* a camera was on: a call
    /// that ends while the application is away — the peer hangs up, the ring
    /// times out — and a second call in its place would then inherit the
    /// resume, and the return to the screen would open the camera on a peer
    /// the user never showed it to.
    func testTheCameraPausedByTheBackgroundIsResumedOnlyInTheCallItWasPausedIn() throws {
        let same = CallPair()
        same.connect()
        same.alice.video(true, generation: same.alice.generation)
        XCTAssertTrue(try take(same.alicePorts).body.video, "the camera is on and the peer knows")

        same.screen(false, of: same.alice)
        XCTAssertTrue(!same.alicePorts.video && !same.alice.presentation.localVideo,
                      "leaving the screen stops the capture")
        XCTAssertFalse(try take(same.alicePorts).body.video,
                       "and the peer is told the camera went off")
        XCTAssertTrue(same.alice.isActive && same.alice.currentState == .connected,
                      "the call itself runs on: only the camera stopped")

        same.screen(true, of: same.alice)
        XCTAssertTrue(same.alicePorts.video && same.alice.presentation.localVideo,
                      "the camera the user had on comes back with the screen")
        XCTAssertTrue(try take(same.alicePorts).body.video, "and the peer is told it is back")

        // The same pause, in a call that does not survive the background.
        let replaced = CallPair()
        replaced.connect()
        replaced.alice.video(true, generation: replaced.alice.generation)
        _ = try take(replaced.alicePorts)
        replaced.screen(false, of: replaced.alice)
        _ = try take(replaced.alicePorts)
        try replaceCall(replaced)

        let opened = replaced.alicePorts.videoCalls
        replaced.screen(true, of: replaced.alice)
        XCTAssertTrue(!replaced.alicePorts.video && replaced.alicePorts.videoCalls == opened
                      && !replaced.alice.presentation.localVideo,
                      "the audio-only call that replaced it inherits no camera")
        XCTAssertEqual(replaced.alicePorts.pendingCount, 0,
                       "and its peer is told of none")
    }

    /// A "video call" whose media authority arrives while the application is
    /// away keeps the intent and opens nothing until the screen comes back.
    ///
    /// This is the gap a pause cannot see: at the moment the application
    /// leaves, the camera of a video call that is still authorizing is not on
    /// yet, so there is nothing to pause — and the engine that becomes ready a
    /// moment later would otherwise start a capture with the application off
    /// the screen, and announce it.
    func testAVideoCallAuthorizedInTheBackgroundCapturesNothingUntilTheScreenIsBack() throws {
        let intent = CallPair()
        intent.alice.start(account: CallPair.bob, microphonePermission: true, videoIntent: true)
        intent.deliver(to: intent.bob, from: CallPair.alice, try take(intent.alicePorts))
        intent.screen(false, of: intent.alice)

        intent.deliver(to: intent.alice, from: CallPair.bob, try take(intent.bobPorts))
        XCTAssertTrue(intent.alice.presentation.mediaActive && intent.alicePorts.offers == 1,
                      "the call itself is authorized and its media exists")
        XCTAssertTrue(!intent.alicePorts.video && intent.alicePorts.videoCalls == 0
                      && !intent.alice.presentation.localVideo,
                      "a video call that becomes ready off the screen opens no camera")

        intent.screen(true, of: intent.alice)
        XCTAssertTrue(intent.alicePorts.video && intent.alice.presentation.localVideo,
                      "and the intent it was started with is applied on the way back")

        // An explicit toggle taken while the application is away is the same
        // rule: the intent is kept with its call, the capture waits.
        let toggled = CallPair()
        toggled.connect()
        toggled.screen(false, of: toggled.alice)
        toggled.alice.video(true, generation: toggled.alice.generation)
        XCTAssertTrue(!toggled.alicePorts.video && toggled.alicePorts.pendingCount == 0,
                      "a camera asked for off the screen captures nothing and announces nothing")
        toggled.screen(true, of: toggled.alice)
        XCTAssertTrue(toggled.alicePorts.video && toggled.alice.presentation.localVideo,
                      "and it opens once there is a screen to show it on")
        XCTAssertTrue(try take(toggled.alicePorts).body.video, "the peer learns it then")
    }

    /// One trip to the background produces four reports of the screen, they
    /// reach this thread through unstructured tasks that nothing orders
    /// against each other, and whether the application is on the screen is
    /// state that stays — so a pair applied the wrong way round does not
    /// merely arrive late. It settles on the older answer and stays there: the
    /// camera button would record intents that open nothing, with no notice
    /// and nothing on the screen to show for it, until another whole trip to
    /// the background happened to set it right.
    ///
    /// The reports are therefore numbered where they are taken, and the one
    /// that describes a superseded screen is dropped here.
    func testAScreenReportThatArrivesAfterANewerOneIsIgnored() throws {
        let late = CallPair()
        late.connect()

        // The trip: inactive (1, on screen), background (2, off), inactive
        // (3, on), active (4, on) — and the one that says the application left
        // the screen is the one that is delayed past all of them.
        late.alice.foreground(true, phase: 1)
        late.alice.foreground(true, phase: 3)
        late.alice.foreground(true, phase: 4)
        late.alice.foreground(false, phase: 2)

        late.alice.video(true, generation: late.alice.generation)
        XCTAssertTrue(late.alicePorts.video && late.alice.presentation.localVideo,
                      "the camera opens: the application is on the screen, whatever order the "
                      + "reports of it arrived in")
        XCTAssertTrue(try take(late.alicePorts).body.video, "and its peer is told")

        // The other direction of the same crossing: a stale "on screen" must
        // not unblock a capture while the application is away.
        let away = CallPair()
        away.connect()
        away.alice.foreground(false, phase: 2)
        away.alice.foreground(true, phase: 1)

        away.alice.video(true, generation: away.alice.generation)
        XCTAssertTrue(!away.alicePorts.video && !away.alice.presentation.localVideo
                      && away.alicePorts.pendingCount == 0,
                      "no capture starts off the screen on the strength of an older report")
        away.alice.foreground(true, phase: 3)
        XCTAssertTrue(away.alicePorts.video && away.alice.presentation.localVideo,
                      "and the intent it kept is paid when the screen really is back")
    }

    // MARK: - The constants of the runtime

    /// Every timer and ceiling is the Android one, to the millisecond
    /// (`CallController.java:35-37`).
    func testTheConstantsAreTheAndroidOnes() {
        XCTAssertEqual(CallController.ttlMillis, 45_000)
        XCTAssertEqual(CallController.heartbeatMillis, 10_000)
        XCTAssertEqual(CallController.silenceMillis, 30_000)
        XCTAssertEqual(CallController.disconnectedMillis, 10_000)
        XCTAssertEqual(CallController.maximumCallMillis, 900_000)
        XCTAssertEqual(CallController.clockSkewMillis, 5_000)
        XCTAssertEqual(CallController.tickMillis, 1_000)
        XCTAssertEqual(CallController.maximumReadiness, 8)
        XCTAssertEqual(CallController.maximumTerminals, 64)
        XCTAssertEqual(CallController.knocksPerPeerPerMinute, 6)
        XCTAssertEqual(CallController.knocksPerMinute, 24)
        XCTAssertEqual(CallController.knockWindowMillis, 60_000)
        XCTAssertEqual(CallController.maximumPendingCallEnvelopes, 16)
        // The body's own window is the same 45 seconds the controller holds a
        // call and a terminal identifier for.
        XCTAssertEqual(CallController.ttlMillis, CallBody.ttlMillis)
        XCTAssertEqual(CallController.clockSkewMillis, CallBody.futureSkewMillis)
    }

    // MARK: - What each deadline ends the call as

    /// The four deadlines, each with the reason the protocol gives it: 45
    /// seconds of ringing or negotiating and 15 minutes of call are `timeout`,
    /// 30 seconds of peer silence is `timeout`, 10 seconds of lost ICE is
    /// `failed` (`voice-v1.md:113-117,133`).
    func testEachDeadlineEndsTheCallWithItsOwnReason() throws {
        // 45 seconds: the ring, on both sides at once.
        let ringing = CallPair()
        ringing.ring()
        ringing.time.advance(millis: CallController.ttlMillis)
        ringing.alice.tick()
        ringing.bob.tick()
        XCTAssertFalse(ringing.alice.isActive, "the caller's negotiation window closed")
        XCTAssertEqual(ringing.alice.presentation.reason, .timeout)
        XCTAssertFalse(ringing.bob.isActive, "and so did the ringing callee's")
        XCTAssertEqual(ringing.bob.presentation.reason, .timeout)

        // One millisecond earlier it is still ringing.
        let almost = CallPair()
        almost.ring()
        almost.time.advance(millis: CallController.ttlMillis - 1)
        almost.bob.tick()
        XCTAssertEqual(almost.bob.currentState, .incoming, "the last millisecond still rings")

        // 30 seconds of silence, counted from the last thing heard from the
        // peer and not from the call's start.
        let silent = CallPair()
        silent.connect()
        silent.time.advance(millis: CallController.silenceMillis - 1)
        silent.alice.tick()
        XCTAssertTrue(silent.alice.isActive, "a peer that spoke 29 seconds ago is not silent")
        silent.time.advance(millis: 1)
        silent.alice.tick()
        XCTAssertFalse(silent.alice.isActive, "thirty seconds without a control is the end")
        XCTAssertEqual(silent.alice.presentation.reason, .timeout)

        // A `media` control refreshes the silence deadline exactly as a
        // heartbeat does (`call-v2.md:27`).
        let announced = CallPair()
        announced.connect()
        announced.time.advance(millis: CallController.silenceMillis - 1)
        announced.bob.video(true, generation: announced.bob.generation)
        announced.deliver(to: announced.alice, from: CallPair.bob, try take(announced.bobPorts))
        announced.time.advance(millis: CallController.silenceMillis - 1)
        announced.alice.tick()
        XCTAssertTrue(announced.alice.isActive, "a media control is a sign of life like any other")

        // 10 seconds of lost ICE, as a failure and not as a timeout.
        let lost = CallPair()
        lost.connect()
        lost.alice.mediaState(lost.alice.generation, .disconnected)
        lost.time.advance(millis: CallController.disconnectedMillis)
        lost.alice.tick()
        XCTAssertFalse(lost.alice.isActive)
        XCTAssertEqual(lost.alice.presentation.reason, .failed, "lost ICE is a failure")

        // 15 minutes, with a peer that never goes silent: the ceiling is
        // measured from the explicit intent, so nothing the peer does moves it.
        let long = CallPair()
        long.ring()
        long.bob.answer(microphonePermission: true)
        long.bob.localDescription(long.bob.generation, sdp: CallBodyTests.answerSdp)
        let answer = try take(long.bobPorts)
        long.deliver(to: long.alice, from: CallPair.bob, answer)
        long.alice.mediaState(long.alice.generation, .connected)
        var elapsed: Int64 = 0
        var seq: Int64 = 2
        while elapsed < CallController.maximumCallMillis - 1 {
            let step = min(CallController.silenceMillis - 1,
                           CallController.maximumCallMillis - 1 - elapsed)
            long.time.advance(millis: step)
            elapsed += step
            long.deliver(to: long.alice, from: CallPair.bob,
                         CallBody.heartbeat(answer.body.identity, seq: seq,
                                            sentMillis: long.time.wallMillis))
            seq += 1
            long.alice.tick()
            while long.alicePorts.take() != nil {}
        }
        XCTAssertTrue(long.alice.isActive, "a call that is not yet fifteen minutes old runs on")
        long.time.advance(millis: 1)
        long.alice.tick()
        XCTAssertFalse(long.alice.isActive, "fifteen minutes is the ceiling")
        XCTAssertEqual(long.alice.presentation.reason, .timeout)
    }

    // MARK: - The knock ceilings

    /// Six knocks per peer per minute and twenty-four across every peer, both
    /// on monotonic time (`voice-v1.md:96-97`).
    func testTheKnockCeilingsAreSixPerPeerAndTwentyFourInTotal() throws {
        let peer = CallPair()
        let caller = String(repeating: "c", count: 64)
        for attempt in 1...CallController.knocksPerPeerPerMinute {
            XCTAssertTrue(knockAndRelease(peer, from: caller),
                          "knock \(attempt) of six is answered")
        }
        XCTAssertFalse(knockAndRelease(peer, from: caller),
                       "the seventh knock of one peer inside a minute is not answered")

        // The window is a minute of monotonic time, and moving the wall clock
        // inside the skew tolerance buys nothing.
        peer.time.advance(millis: CallController.knockWindowMillis)
        XCTAssertTrue(knockAndRelease(peer, from: caller),
                      "a minute later the peer may knock again")

        let crowd = CallPair()
        for index in 0..<CallController.knocksPerMinute {
            XCTAssertTrue(knockAndRelease(crowd, from: Self.account(index)),
                          "knock \(index + 1) of twenty-four is answered")
        }
        XCTAssertFalse(knockAndRelease(crowd, from: Self.account(CallController.knocksPerMinute)),
                       "the twenty-fifth knock of the minute is not answered, whoever sent it")
    }

    /// One knock from `account`, and the readiness slot released again so that
    /// the next knock is admitted on its own merits and not on the one-slot-per
    /// -peer rule.
    ///
    /// - Returns: whether `ready` was answered.
    private func knockAndRelease(_ pair: CallPair, from account: String) -> Bool {
        // Whatever the receiver enqueued earlier is not an answer to this
        // knock, so the outbox starts empty.
        while pair.bobPorts.take() != nil {}
        let knock = pair.knockBody()
        pair.deliver(to: pair.bob, from: account, knock)
        let answered = pair.bobPorts.take() != nil
        pair.deliver(to: pair.bob, from: account,
                     CallBody.end(knock.identity, seq: 2, reason: .cancel,
                                  sentMillis: pair.time.wallMillis))
        return answered
    }

    /// 64 lowercase hexadecimal digits ending in `index`.
    private static func account(_ index: Int) -> String {
        String(repeating: "0", count: 62) + String(format: "%02x", index)
    }

    // MARK: - The bounded terminal memory

    /// At most 64 ended calls are remembered at once, and a full table refuses
    /// new calls rather than forgetting one — because a forgotten identifier is
    /// one a retried control reopens (`voice-v1.md:97-98`).
    func testTheTerminalTableIsBoundedAndAFullOneRefusesNewCalls() throws {
        let pair = CallPair()
        for round in 1...CallController.maximumTerminals {
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            XCTAssertTrue(pair.alice.isActive, "call \(round) of sixty-four is admitted")
            _ = pair.alicePorts.take()
            pair.alice.hangup()
            _ = pair.alicePorts.take()
        }
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertFalse(pair.alice.isActive, "a full terminal table refuses a new call")
        XCTAssertEqual(pair.alice.presentation.reason, .unavailable,
                       "and says the device is unavailable rather than rejecting the peer")

        // The entries expire with the calls they name, so the device takes
        // calls again one TTL later.
        pair.time.advance(millis: CallController.ttlMillis + 1)
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertTrue(pair.alice.isActive, "expired terminal identifiers free the table again")
    }

    /// When the table is full at the moment a live call ends, its identifier
    /// cannot be stored — so the device stops admitting anything at all for one
    /// TTL instead of forgetting the call (`CallController.java:355-359`).
    func testAnOverflowingTerminalTableStopsAdmittingControls() throws {
        let pair = CallPair()
        for _ in 1...(CallController.maximumTerminals - 1) {
            pair.bob.start(account: CallPair.alice, microphonePermission: true)
            _ = pair.bobPorts.take()
            pair.bob.hangup()
            _ = pair.bobPorts.take()
        }
        // 63 remembered. A third peer knocks, the slot is granted, and then a
        // call of this device's own starts.
        let third = String(repeating: "c", count: 64)
        let knock = pair.knockBody()
        pair.deliver(to: pair.bob, from: third, knock)
        let ready = try take(pair.bobPorts)
        pair.bob.start(account: CallPair.alice, microphonePermission: true)
        _ = pair.bobPorts.take()

        // The third peer's offer arrives to a busy device: it is answered
        // `busy` and its identifier remembered — the sixty-fourth.
        guard let description = CallDescription(sdp: CallBodyTests.sdp) else {
            return XCTFail("the fixture description is the one this client sends")
        }
        var identity = knock.identity
        identity.calleeNonce = ready.body.calleeNonce
        pair.deliver(to: pair.bob, from: third,
                     CallBody.offer(identity, description: description,
                                    sentMillis: pair.time.wallMillis))

        // Now the live call ends with no room left for its own identifier.
        pair.bob.hangup()
        XCTAssertFalse(pair.bob.isActive)
        XCTAssertFalse(knockAndRelease(pair, from: third),
                       "an overflowing terminal table admits no control at all")
        pair.bob.start(account: CallPair.alice, microphonePermission: true)
        XCTAssertFalse(pair.bob.isActive, "and no new call either")

        pair.time.advance(millis: CallController.ttlMillis + 1)
        pair.bob.start(account: CallPair.alice, microphonePermission: true)
        XCTAssertTrue(pair.bob.isActive, "one TTL later the device takes calls again")
    }

    // MARK: - What a completion means

    /// A completion means the durable local commit **and** the server's
    /// validated acceptance, and the core refuses the seventeenth call envelope
    /// a peer's outbox would hold (`voice-v1.md:145-149`,
    /// `clean_service.rs:396-400`).
    func testACallControlIsRefusedOnceTheOutboxAlreadyHoldsSixteen() throws {
        let pair = CallPair()
        pair.alicePorts.deferSignals = true
        pair.alicePorts.callOutboxLimit = CallController.maximumPendingCallEnvelopes
        // Each round leaves two envelopes the server has not answered: the
        // knock and the terminal end.
        for _ in 1...(CallController.maximumPendingCallEnvelopes / 2) {
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            XCTAssertTrue(pair.alice.isActive)
            pair.alice.hangup()
        }
        XCTAssertEqual(pair.alicePorts.outstanding, CallController.maximumPendingCallEnvelopes,
                       "sixteen call envelopes are waiting for the server")

        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertFalse(pair.alice.isActive, "the seventeenth call envelope is refused")
        XCTAssertEqual(pair.alice.presentation.reason, .failed,
                       "and a refused enqueue terminates locally")
        XCTAssertEqual(pair.alicePorts.offers, 0, "nothing captured on the way")
    }

    // MARK: - The flag that flickers

    /// The lane's online flag drops and comes back on every server-forced
    /// reconnect (`RealtimeLoop.java:237,280`, `current-state.md:19-22`,
    /// issue #19). A readiness answer enqueued into the middle of that flicker
    /// is the one thing that must not be lost: it is durable, it carries its
    /// own 45-second expiry, and losing it costs the caller the whole call.
    func testAnOfflineFlickerNeverLosesTheReadyAnswer() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try take(pair.alicePorts)

        // The knock arrives exactly while the receiver's lane is down.
        pair.bob.connection(false)
        pair.deliver(to: pair.bob, from: CallPair.alice, knock)
        let ready = try take(pair.bobPorts)
        XCTAssertEqual(ready.body.kind, .ready,
                       "the readiness answer is enqueued whatever the flag says")
        pair.bob.connection(true)

        // And the caller's own lane flickers while that answer reaches it.
        pair.alice.connection(false)
        pair.deliver(to: pair.alice, from: CallPair.bob, ready)
        pair.alice.connection(true)
        XCTAssertEqual(pair.alicePorts.offers, 1, "the caller's intent survived the flicker")

        pair.alice.localDescription(pair.alice.generation, sdp: CallBodyTests.sdp)
        pair.deliver(to: pair.bob, from: CallPair.alice, try take(pair.alicePorts))
        XCTAssertEqual(pair.bob.currentState, .incoming,
                       "the slot the flicker did not lose is the one that rings")
    }

    // MARK: - The microphone, refused on an incoming call

    /// Android answers a denied microphone on a ringing call with
    /// `calls().answer(false)` (`MainActivity.java:600`), which is
    /// `finish("reject", true)` (`CallController.java:109`): the peer is told
    /// `reject`, and this side is `ended`.
    func testMicrophoneDeniedOnAnIncomingCallEndsAsRejectAndTellsThePeer() throws {
        let pair = CallPair()
        pair.ring()
        XCTAssertEqual(pair.bob.currentState, .incoming)

        pair.bob.answer(microphonePermission: false)
        XCTAssertEqual(pair.bob.currentState, .ended, "a refused microphone is terminal")
        XCTAssertFalse(pair.bob.isActive)
        XCTAssertEqual(pair.bob.presentation.reason, .reject,
                       "the reason is the one Android sends for the same refusal")
        XCTAssertEqual(pair.bobPorts.answers, 0, "and nothing was captured")
        XCTAssertEqual(pair.bobPorts.videoCalls, 0)
        XCTAssertGreaterThan(pair.bobPorts.closes, 0, "the terminal path disposes the engine")

        let end = try take(pair.bobPorts)
        XCTAssertEqual(end.body.kind, .end)
        XCTAssertEqual(end.body.endReason, .reject, "the caller is told, and told the truth")
        pair.deliver(to: pair.alice, from: CallPair.bob, end)
        XCTAssertFalse(pair.alice.isActive, "and the caller stops ringing")
        XCTAssertEqual(pair.alice.presentation.reason, .reject)
    }

    // MARK: - The five seconds the two clocks may disagree by

    /// `CLOCK_SKEW` is the whole tolerance. Between two entries into the
    /// controller the wall clock may have moved five seconds more, or five
    /// seconds less, than the monotonic one and still be believed; one
    /// millisecond beyond that is a clock this device stops trusting, and then
    /// every readiness slot goes and a live call ends as `failed` — without a
    /// word to the peer, because a body dated from that clock is one the peer
    /// would refuse anyway (`voice-v1.md:92-93`, `CallController.java:351`).
    func testFiveSecondsOfSkewIsBelievedAndOneMillisecondMoreResetsTheCall() throws {
        // Forwards, exactly the tolerance: the negotiation survives it.
        let ahead = CallPair()
        ahead.ready()
        ahead.time.moveWall(millis: CallController.clockSkewMillis)
        ahead.alice.tick()
        XCTAssertTrue(ahead.alice.isActive, "five seconds ahead is still the same clock")
        ahead.alice.localDescription(ahead.alice.generation, sdp: CallBodyTests.sdp)
        ahead.deliver(to: ahead.bob, from: CallPair.alice, try take(ahead.alicePorts))
        XCTAssertEqual(ahead.bob.currentState, .incoming,
                       "and the readiness slot granted before the drift still rings")

        // Backwards, exactly the tolerance: the same verdict.
        let behind = CallPair()
        behind.connect()
        behind.time.moveWall(millis: -CallController.clockSkewMillis)
        behind.alice.tick()
        XCTAssertTrue(behind.alice.isActive, "five seconds behind is still the same clock")

        // One millisecond more, on a connected call: terminal, and silent.
        let reset = CallPair()
        reset.connect()
        while reset.alicePorts.take() != nil {}
        reset.time.moveWall(millis: CallController.clockSkewMillis + 1)
        reset.alice.tick()
        XCTAssertFalse(reset.alice.isActive, "one millisecond past the tolerance is a clock change")
        XCTAssertEqual(reset.alice.currentState, .ended)
        XCTAssertEqual(reset.alice.presentation.reason, .failed,
                       "which ends the call as failed and not as a timeout")
        XCTAssertNil(reset.alicePorts.take(),
                     "and sends nothing from a clock this device stopped trusting")
        XCTAssertGreaterThan(reset.alicePorts.closes, 0, "the engine is disposed all the same")

        // And the readiness slots a receiver is holding go with it.
        let dropped = CallPair()
        dropped.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try take(dropped.alicePorts)
        dropped.deliver(to: dropped.bob, from: CallPair.alice, knock)
        let ready = try take(dropped.bobPorts)
        dropped.time.moveWall(millis: CallController.clockSkewMillis + 1)
        dropped.bob.tick()
        guard let description = CallDescription(sdp: CallBodyTests.sdp) else {
            return XCTFail("the fixture description is the one this client sends")
        }
        var identity = knock.body.identity
        identity.calleeNonce = ready.body.calleeNonce
        dropped.deliver(to: dropped.bob, from: CallPair.alice,
                        CallBody.offer(identity, description: description,
                                       sentMillis: dropped.time.wallMillis))
        XCTAssertNotEqual(dropped.bob.currentState, .incoming,
                          "a clock reset drops every readiness slot it had granted")
    }

    // MARK: - How the controls of a live call are numbered

    /// `seq` 1 belongs to the offer and to the answer alone, so every control
    /// of a call already under way starts at two: a heartbeat, the `media`
    /// that announces a camera, and the terminal `end` all draw the next
    /// number from the call's own counter, and no number is ever used twice —
    /// which is what lets the peer refuse anything that does not move forward
    /// (`voice-v1.md:105-107`, `call-v2.md:27-30`).
    func testHeartbeatsAreNumberedFromTwoAndShareTheCallsOwnCounter() throws {
        let pair = CallPair()
        pair.connect()
        var numbers: [Int64] = []

        for _ in 1...2 {
            pair.time.advance(millis: CallController.heartbeatMillis)
            pair.alice.tick()
            pair.bob.tick()
            let heartbeat = try take(pair.alicePorts)
            XCTAssertEqual(heartbeat.body.kind, .heartbeat, "ten seconds is one heartbeat")
            numbers.append(heartbeat.body.seq)
            pair.deliver(to: pair.bob, from: CallPair.alice, heartbeat)
            while let fromBob = pair.bobPorts.take() {
                pair.deliver(to: pair.alice, from: CallPair.bob, fromBob)
            }
        }

        // The camera goes on in between, and its announcement takes the next
        // number of the same counter rather than one of its own.
        pair.alice.video(true, generation: pair.alice.generation)
        let announcement = try take(pair.alicePorts)
        XCTAssertEqual(announcement.body.kind, .media)
        numbers.append(announcement.body.seq)
        pair.deliver(to: pair.bob, from: CallPair.alice, announcement)

        pair.time.advance(millis: CallController.heartbeatMillis)
        pair.alice.tick()
        let resumed = try take(pair.alicePorts)
        XCTAssertEqual(resumed.body.kind, .heartbeat)
        numbers.append(resumed.body.seq)
        pair.deliver(to: pair.bob, from: CallPair.alice, resumed)

        XCTAssertEqual(numbers, [2, 3, 4, 5],
                       "the controls of a live call are numbered from two, in order")
        XCTAssertTrue(pair.bob.isActive, "and the peer accepted every one of them")
        XCTAssertTrue(pair.bob.presentation.remoteVideo,
                      "including the one that said the camera went on")

        pair.alice.hangup()
        let end = try take(pair.alicePorts)
        XCTAssertEqual(end.body.kind, .end)
        XCTAssertEqual(end.body.seq, 6, "and the terminal control is the next number again")
    }

    // MARK: - Every terminal path, and what it tells the peer

    /// One terminal path on a fresh pair: this side ends, with the reason the
    /// protocol's table gives that path, and the peer is told by an `end`
    /// carrying the same reason — or is not told at all, which is the whole
    /// point on the paths where this device may no longer speak for itself or
    /// no longer trusts the clock it would date the body from
    /// (`voice-v1.md:108-119`, `CallController.java:109-120,294,351`).
    ///
    /// - Parameter path: the setup and the terminal action. It returns the
    ///   side that ended and its ports, and it empties that outbox before the
    ///   terminal action, so what remains is what the terminal path sent.
    private func assertTerminal(_ reason: CallBody.EndReason,
                                toldPeer: Bool,
                                _ what: String,
                                file: StaticString = #filePath,
                                line: UInt = #line,
                                _ path: (CallPair) throws -> (CallController, CallTestPorts))
        rethrows {
        let pair = CallPair()
        let (controller, port) = try path(pair)
        XCTAssertEqual(controller.currentState, .ended, what, file: file, line: line)
        XCTAssertFalse(controller.isActive, what, file: file, line: line)
        XCTAssertEqual(controller.presentation.reason, reason, what, file: file, line: line)
        var ends: [CallBody] = []
        while let sent = port.take() {
            if sent.body.kind == .end { ends.append(sent.body) }
        }
        guard toldPeer else {
            return XCTAssertTrue(ends.isEmpty, "the peer must not be told: \(what)",
                                 file: file, line: line)
        }
        guard let end = ends.last else {
            return XCTFail("no end reached the peer: \(what)", file: file, line: line)
        }
        XCTAssertEqual(end.endReason, reason, what, file: file, line: line)
        XCTAssertGreaterThanOrEqual(end.seq, 2, "a terminal control is never seq 1: \(what)",
                                    file: file, line: line)
    }

    /// Empties an outbox, so that what it holds afterwards was sent by the
    /// terminal path under test and by nothing before it.
    private func drain(_ port: CallTestPorts) {
        while port.take() != nil {}
    }

    /// The whole terminal table in one place: no path out of a call is silent
    /// about why, and each one either tells the peer or deliberately does not.
    func testEveryTerminalPathEndsWithItsOwnReason() throws {
        // The user's own two ends, which differ only by whether the peer had
        // answered yet (`CallController.java:116`).
        assertTerminal(.cancel, toldPeer: true, "an outgoing call ends as cancel until it is answered") { pair in
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            self.drain(pair.alicePorts)
            pair.alice.hangup()
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.hangup, toldPeer: true, "and as hangup once the answer is known") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.alice.hangup()
            return (pair.alice, pair.alicePorts)
        }

        // The three refusals of a ringing call.
        assertTerminal(.reject, toldPeer: true, "an explicit rejection is a reject") { pair in
            pair.ring()
            self.drain(pair.bobPorts)
            pair.bob.reject()
            return (pair.bob, pair.bobPorts)
        }
        assertTerminal(.reject, toldPeer: true, "and so is a microphone the callee refuses") { pair in
            pair.ring()
            self.drain(pair.bobPorts)
            pair.bob.answer(microphonePermission: false)
            return (pair.bob, pair.bobPorts)
        }
        assertTerminal(.unavailable, toldPeer: true, "answering with no lane is unavailable") { pair in
            pair.ring()
            self.drain(pair.bobPorts)
            pair.bob.connection(false)
            pair.bob.answer(microphonePermission: true)
            return (pair.bob, pair.bobPorts)
        }

        // The deadlines.
        assertTerminal(.timeout, toldPeer: true, "forty-five seconds of ringing is a timeout") { pair in
            pair.ring()
            self.drain(pair.bobPorts)
            pair.time.advance(millis: CallController.ttlMillis)
            pair.bob.tick()
            return (pair.bob, pair.bobPorts)
        }
        assertTerminal(.timeout, toldPeer: true, "thirty seconds of peer silence is a timeout") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.time.advance(millis: CallController.silenceMillis)
            pair.alice.tick()
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.failed, toldPeer: true, "ten seconds of lost ICE is a failure") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.alice.mediaState(pair.alice.generation, .disconnected)
            pair.time.advance(millis: CallController.disconnectedMillis)
            pair.alice.tick()
            return (pair.alice, pair.alicePorts)
        }

        // The media engine's own verdicts.
        assertTerminal(.failed, toldPeer: true, "an engine that reports failed is a failure") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.alice.mediaState(pair.alice.generation, .failed)
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.failed, toldPeer: true, "a description this client cannot send is a failure") { pair in
            pair.ready()
            self.drain(pair.alicePorts)
            pair.alice.localDescription(pair.alice.generation,
                                        sdp: Self.padded(toBytes: SdpExtract.maxSdpBytes + 1))
            return (pair.alice, pair.alicePorts)
        }

        // The paths this device may not speak on.
        assertTerminal(.unavailable, toldPeer: false, "lost authority stops without a word") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.alice.authorizationLost()
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.unavailable, toldPeer: false, "and a blocked peer is told nothing") { pair in
            pair.connect()
            self.drain(pair.bobPorts)
            pair.bob.block(account: CallPair.alice)
            return (pair.bob, pair.bobPorts)
        }
        assertTerminal(.failed, toldPeer: false, "a clock change ends the call silently") { pair in
            pair.connect()
            self.drain(pair.alicePorts)
            pair.time.moveWall(millis: CallController.clockSkewMillis + 1)
            pair.alice.tick()
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.failed, toldPeer: false, "a refused enqueue cannot be reported by another enqueue") { pair in
            pair.alicePorts.deferSignals = true
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            self.drain(pair.alicePorts)
            pair.alicePorts.settleLast(accepted: false)
            return (pair.alice, pair.alicePorts)
        }

        // The peer's own reason, adopted as it stands and never echoed back.
        try assertTerminal(.reject, toldPeer: false, "the peer's end carries the reason this side shows") { pair in
            pair.ring()
            pair.bob.reject()
            let end = try self.take(pair.bobPorts)
            self.drain(pair.alicePorts)
            pair.deliver(to: pair.alice, from: CallPair.bob, end)
            return (pair.alice, pair.alicePorts)
        }
        try assertTerminal(.busy, toldPeer: false, "a peer already in a call answers busy") { pair in
            pair.bob.start(account: CallPair.alice, microphonePermission: true)
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            let knock = try self.take(pair.alicePorts)
            pair.deliver(to: pair.bob, from: CallPair.alice, knock)
            var busy: CallTestSent?
            while let sent = pair.bobPorts.take() {
                if sent.body.kind == .end { busy = sent }
            }
            self.drain(pair.alicePorts)
            pair.deliver(to: pair.alice, from: CallPair.bob, try XCTUnwrap(busy))
            return (pair.alice, pair.alicePorts)
        }

        // An intent that never became a call is terminal and visible too, and
        // it sends nothing at all.
        assertTerminal(.reject, toldPeer: false, "a denied microphone never starts a call") { pair in
            pair.alice.start(account: CallPair.bob, microphonePermission: false)
            return (pair.alice, pair.alicePorts)
        }
        assertTerminal(.unavailable, toldPeer: false, "and neither does a device with no lane") { pair in
            pair.alice.connection(false)
            pair.alice.start(account: CallPair.bob, microphonePermission: true)
            return (pair.alice, pair.alicePorts)
        }
    }
}
