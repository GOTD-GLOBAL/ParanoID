import Foundation
import ParanoidKit
import XCTest

/// Real core + failing synthetic sink. No network/Keychain or heartbeat clock.
final class OwnerFreezeNotificationTests: XCTestCase {
    private enum Failure: Error { case disk }
    private final class BrokenSink: SnapshotSink {
        func save(_ snapshot: String) throws { throw Failure.disk }
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Bool] = []
        func record(_ onOwner: Bool) { lock.withLock { entries.append(onOwner) } }
        var values: [Bool] { lock.withLock { entries } }
    }
    private func owner() throws -> StateOwner {
        let trust = try ServiceTrust(realm: "https://127.0.0.2:38443",
                                     pin: String(repeating: "ab", count: 32))
        return StateOwner(client: try SelfServiceClient(saved: nil, sink: BrokenSink(), fixture: trust))
    }

    func testUserCommitFailureNotifiesBeforeReturnEvenWithParkedGeneration() async throws {
        let owner = try owner()
        let events = Events()
        await owner.setFreezeHandler { events.record(owner.isOnOwner) }
        let parked = await owner.start()
        do {
            try await owner.perform { try $0.createIdentity() }
            XCTFail("sink must fail")
        } catch {}
        XCTAssertEqual(events.values, [true], "synchronous terminal callback before UI catches")
        do {
            try await owner.perform(parked) { _ in XCTFail("late receive cannot enter") }
            XCTFail("superseded receive must fail")
        } catch is Superseded {} catch { XCTFail("unexpected error: \(error)") }
        _ = await owner.start()
        let restarted = await owner.restart()
        let current = await owner.current
        XCTAssertNil(restarted)
        XCTAssertNil(current)
        XCTAssertEqual(events.values, [true], "no repeat callback or resurrection")
    }

    func testOperationThatCatchesItsOwnCommitErrorStillNotifies() async throws {
        let owner = try owner()
        let events = Events()
        await owner.setFreezeHandler { events.record(owner.isOnOwner) }
        _ = await owner.start()
        try await owner.perform { client in
            do { try client.createIdentity() } catch {}
        }
        XCTAssertEqual(events.values, [true])
        let current = await owner.current
        XCTAssertNil(current)
    }

    func testLateHandlerSeesAnAlreadyFrozenClientOnce() async throws {
        let owner = try owner()
        do { try await owner.perform { try $0.createIdentity() } } catch {}
        let events = Events()
        await owner.setFreezeHandler { events.record(owner.isOnOwner) }
        XCTAssertEqual(events.values, [true])
    }

    func testOrdinaryOperationFailureDoesNotRevokeMediaAuthority() async throws {
        let owner = try owner()
        let events = Events()
        await owner.setFreezeHandler { events.record(owner.isOnOwner) }
        let generation = await owner.start()
        do { try await owner.perform { _ in throw Failure.disk } } catch {}
        XCTAssertTrue(events.values.isEmpty)
        let current = await owner.current
        XCTAssertEqual(current, generation)
    }
}
