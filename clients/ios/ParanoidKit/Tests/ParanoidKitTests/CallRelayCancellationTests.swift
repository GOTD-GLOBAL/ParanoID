import ParanoidKit
import XCTest

/// REQ-CALL-006: termination cancels only its own request, even across hops.
final class CallRelayCancellationTests: XCTestCase {
    typealias Lane = VoiceRelayLaneTests.Lane
    typealias Waiter = VoiceRelayLaneTests.Waiter

    func testTerminalRequestClosesHeldEndpointWithoutReplacementOrRetry() async throws {
        let fixture = try await Lane.make()
        fixture.relay.script = [.rejected(Rejected(status: 401)), .body(Lane.document())]
        fixture.relay.hold = true
        let request = VoiceRelayLane.Request()
        let result = Waiter()
        await fixture.lane.request(under: fixture.run, request: request) { result.deliver($0) }
        try await fixture.relay.waitUntilHeld()
        request.cancel() // synchronous owner-side cancellation, no actor hop
        for _ in 0..<2000 {
            if fixture.relay.closes > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(fixture.relay.closes, 1, "held voice endpoint closed without another call")
        fixture.relay.release() // late 401 must not mint a second credential
        try await fixture.quiesce()
        XCTAssertEqual(fixture.relay.credentials.count, 1)
        XCTAssertFalse(result.delivered)
    }

    func testDelayedTerminalRequestCannotCancelReplacement() async throws {
        let fixture = try await Lane.make()
        fixture.relay.script = [.body(Lane.document()), .body(Lane.document())]
        fixture.relay.hold = true
        let old = VoiceRelayLane.Request()
        let current = VoiceRelayLane.Request()
        let first = Waiter()
        let second = Waiter()
        await fixture.lane.request(under: fixture.run, request: old) { first.deliver($0) }
        try await fixture.relay.waitUntilHeld()
        await fixture.lane.request(under: fixture.run, request: current) { second.deliver($0) }
        old.cancel() // A's delayed teardown must not close B
        // A's delayed request task must also not replace B after cancellation.
        await fixture.lane.request(under: fixture.run, request: old) { first.deliver($0) }
        fixture.relay.release()
        try await fixture.quiesce()
        XCTAssertEqual(second.outcome?.name, "relay")
        XCTAssertFalse(first.delivered)
        XCTAssertFalse(current.isCancelled)
        XCTAssertLessThanOrEqual(fixture.relay.concurrent, 1)
    }

    func testCancelledClaimIsSuppressedAgainOnOwnerDelivery() async throws {
        let fixture = try await Lane.make()
        let request = VoiceRelayLane.Request()
        let result = Waiter()
        // Models cancellation after the lane claims its result but before the
        // owner executes delivery. Guard must precede listener side effects too.
        request.cancel()
        await fixture.owner.deliverRelay(.failed, under: fixture.run,
                                        to: fixture.listener, request: request) {
            result.deliver($0)
        }
        XCTAssertFalse(result.delivered)
        XCTAssertEqual(fixture.listener.losses, 0)
    }

    func testCancellationBeforeRequestNeverOpensAnEndpoint() async throws {
        let fixture = try await Lane.make()
        let request = VoiceRelayLane.Request()
        request.cancel()
        let result = Waiter()
        await fixture.lane.request(under: fixture.run, request: request) { result.deliver($0) }
        try await fixture.quiesce()
        XCTAssertTrue(fixture.relay.credentials.isEmpty)
        XCTAssertFalse(result.delivered)
    }
}
