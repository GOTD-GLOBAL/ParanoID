import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

final class OpeningRetryTests: XCTestCase {
    private enum Failure: Error { case locked, disk }
    private final class FailingSink: SnapshotSink {
        func save(_ snapshot: String) throws { throw Failure.disk }
    }

    /// Only the bootstrap input is substituted; start/retry, the real core,
    /// runtime, owner and UI gates are production code. The client has no ID,
    /// so it cannot reach any server, and its first commit deliberately fails.
    @MainActor
    func testRetryClearsInitialFailureButCannotClearAFailedCommit() async throws {
        var attempts = 0
        let trust = try ServiceTrust(realm: "https://127.0.0.2:38443",
                                     pin: String(repeating: "ab", count: 32))
        let model = AppModel(openClient: {
            attempts += 1
            if attempts == 1 { throw Failure.locked }
            return try SelfServiceClient(saved: nil, sink: FailingSink(), fixture: trust)
        })
        model.start()
        XCTAssertEqual(model.stage, .frozen)
        XCTAssertTrue(model.isBroken)
        model.retryOpen()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.stage, .running)
        XCTAssertFalse(model.isBroken)
        XCTAssertFalse(model.view.hasIdentity)
        model.createIdentity()
        XCTAssertTrue(model.isCreating, "Create is usable after the initial retry")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isCreating && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(model.isCreating)
        XCTAssertTrue(model.isBroken)
        XCTAssertEqual(model.stage, .frozen)
        model.retryOpen()
        XCTAssertEqual(attempts, 2, "no new runtime after a commit failure")
        XCTAssertTrue(model.isBroken)
        model.published(connected: true, status: "late network reply")
        model.publishConnecting(resumed: true)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.stage, .frozen)
    }
}
