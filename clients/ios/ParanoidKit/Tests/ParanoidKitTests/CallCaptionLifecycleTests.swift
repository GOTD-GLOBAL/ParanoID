import XCTest
@testable import ParanoidKit

/// Characterizes existing controller behavior behind the connection caption.
/// These are owner/clock/wire-body tests, not OS suspension or audibility tests.
final class CallCaptionLifecycleTests: XCTestCase {
    private func queuedOfferAndEnd() throws -> (CallPair, CallTestSent, CallTestSent) {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.deliver(to: pair.bob, from: CallPair.alice,
                     try XCTUnwrap(pair.alicePorts.take()))
        let ready = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertFalse(pair.bob.isActive, "readiness is not a live call")
        pair.screen(false, of: pair.bob)
        // No receive occurs while backgrounded. The relay retains these two
        // controls until foreground resumes, before the readiness deadline.
        pair.deliver(to: pair.alice, from: CallPair.bob, ready)
        pair.alice.localDescription(pair.alice.generation, sdp: CallBodyTests.sdp)
        let offer = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(offer.body.kind, .offer)
        pair.alice.hangup()
        let end = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(end.body.kind, .end)
        XCTAssertFalse(pair.alice.isActive, "caller ended before callee resumed")
        return (pair, offer, end)
    }

    func testPreservedReadinessCanRecordAnAlreadyEndedCallerAfterResume() throws {
        let (pair, offer, end) = try queuedOfferAndEnd()
        pair.screen(true, of: pair.bob)
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming)
        pair.deliver(to: pair.bob, from: CallPair.alice, end)
        XCTAssertEqual(pair.bob.currentState, .ended)
        XCTAssertEqual(pair.bobPorts.terminations.count, 1)
        let record = try XCTUnwrap(pair.bobPorts.lastTermination)
        XCTAssertEqual(record.callId, offer.body.callId)
        XCTAssertFalse(record.outgoing)
        XCTAssertFalse(record.connected)
        XCTAssertEqual(record.reason, end.body.endReason)
        // Exact control replay does not create another row.
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        pair.deliver(to: pair.bob, from: CallPair.alice, end)
        XCTAssertEqual(pair.bobPorts.terminations.count, 1)
    }

    func testColdControllerWithoutReadinessCannotAdmitTheQueuedOffer() throws {
        let (_, offer, end) = try queuedOfferAndEnd()
        let cold = CallPair()
        cold.deliver(to: cold.bob, from: CallPair.alice, offer)
        cold.deliver(to: cold.bob, from: CallPair.alice, end)
        XCTAssertFalse(cold.bob.isActive)
        XCTAssertEqual(cold.bob.currentState, .idle)
        XCTAssertTrue(cold.bobPorts.terminations.isEmpty)
    }

    func testExpiredQueuedOfferAndEndDoNotCreateATerminationAfterResume() throws {
        let (pair, offer, end) = try queuedOfferAndEnd()
        pair.time.advance(millis: CallController.ttlMillis + 1)
        pair.bob.tick()
        pair.screen(true, of: pair.bob)
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        pair.deliver(to: pair.bob, from: CallPair.alice, end)
        XCTAssertFalse(pair.bob.isActive)
        XCTAssertEqual(pair.bob.currentState, .idle)
        XCTAssertTrue(pair.bobPorts.terminations.isEmpty)
    }
}
