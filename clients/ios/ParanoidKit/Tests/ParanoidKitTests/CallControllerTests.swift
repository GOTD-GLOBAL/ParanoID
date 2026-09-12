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

        pair.bob.video(true)
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
        pair.alice.video(true)
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

        pair.alice.video(false)
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
        early.bob.video(true)
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
        unavailable.alice.video(true)
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
        announced.bob.video(true)
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
}
