import Darwin
import ParanoidKit
import XCTest

/// The real owner's commit failure reaches live call teardown without a tick.
final class CallFreezeIntegrationTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        let pair = CallPair()
        var freezeCount = 0
    }

    func testConnectedCallEndsSynchronouslyWhenUnrelatedCommitFreezes() async throws {
        let device = try Device(name: "call-freeze", trust: VoiceRelayLaneTests.stand)
        let owner = StateOwner(client: device.client)
        let calls = Calls()
        let run = await owner.start()
        try await owner.perform(run) { _ in
            calls.pair.connect()
            XCTAssertEqual(calls.pair.bob.currentState, .connected)
        }
        await owner.setFreezeHandler {
            XCTAssertTrue(owner.isOnOwner)
            calls.freezeCount += 1
            calls.pair.bob.authorizationLost()
            XCTAssertEqual(calls.pair.bob.currentState, .ended)
            XCTAssertGreaterThan(calls.pair.bobPorts.closes, 0)
        }
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: ENOSPC)
        }
        // A non-call mutation fails, and even swallowing its error must not
        // defer media cleanup until the next heartbeat.
        try await owner.perform(run) { client in
            _ = try? client.createIdentity()
        }
        XCTAssertEqual(calls.freezeCount, 1)
        XCTAssertEqual(calls.pair.bob.currentState, .ended)
        XCTAssertGreaterThan(calls.pair.bobPorts.closes, 0)
    }
}
