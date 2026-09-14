import Foundation
import ParanoidKit
import XCTest

/// F4 / SS-01 / REQ-ID-005/008, RFC-0021 and proposed ADR-0014.
/// Real core, sealed SnapshotStore, reconstructed client/owner/ProofFlow;
/// only disk faults and transport are simulated. No hosted requests.
final class InterruptedOnboardingTests: XCTestCase {
    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    func testSchemaZeroCheckpointResumesSameIdentityBeforeRegistration() async throws {
        let device = try Device(name: "f4-schema-zero", trust: Self.trust)
        failSecondWrite(on: device)
        XCTAssertThrowsError(try device.client.createIdentity()) {
            XCTAssertEqual($0 as? SelfServiceError, .commitFailed)
        }
        XCTAssertTrue(device.client.isBroken)
        device.fileSystem.failure = nil
        let checkpoint = try XCTUnwrap(try device.stored())
        XCTAssertEqual(try Snapshot.open(checkpoint).stateVersion, 0)
        let store = device.reopenStore()
        let resumed = try SelfServiceClient(saved: store.load(), sink: store, compiled: nil)
        let credential = try resumed.credential() as NSDictionary
        XCTAssertTrue(try resumed.hasIdentity())
        XCTAssertEqual(try device.stored(), checkpoint, "opening only validates; no write")
        let transport = FakeTransport(server: try StandServer(credential: resumed.credential()))
        transport.answer = { call in
            if call.path == ChallengeIntent.registrationChallengePath {
                // Inspect the sealed durable bytes, not the client's in-memory candidate.
                let durable = try XCTUnwrap(try device.stored())
                XCTAssertEqual(try Snapshot.open(durable).stateVersion, 3,
                               "upgrade must commit before the first registration request")
                let reopened = try SelfServiceClient(saved: durable, sink: device.reopenStore(), compiled: nil)
                XCTAssertEqual(try reopened.credential() as NSDictionary, credential)
            }
            return nil
        }
        let owner = StateOwner(client: resumed)
        let flow = ProofFlow(owner: owner, transport: transport, pacer: RecordingPacer())
        guard case .session = try await flow.connect() else { return XCTFail("session expected") }
        XCTAssertEqual(transport.calls.filter { $0.path == ChallengeIntent.registrationCommitPath }.count, 1)
        let final = try SelfServiceClient(saved: device.stored(), sink: device.reopenStore(), compiled: nil)
        XCTAssertEqual(try final.credential() as NSDictionary, credential)
        XCTAssertTrue(try final.registered())
        XCTAssertNotNil(try final.contactText())
        XCTAssertEqual(try final.updateTrust(), Self.trust)
    }

    func testActiveCheckpointPreparesDurableQRWithoutRegisteringAgain() async throws {
        let device = try Device(name: "f4-active", trust: Self.trust)
        try device.client.createIdentity()
        let credential = try device.client.credential() as NSDictionary
        failSecondWrite(on: device)
        XCTAssertThrowsError(try device.client.registrationResult(
            status: SelfServiceClientTests.activeStatus(for: device.client.credential()))) {
            XCTAssertEqual($0 as? SelfServiceError, .commitFailed)
        }
        XCTAssertTrue(device.client.isBroken)
        device.fileSystem.failure = nil
        let checkpoint = try XCTUnwrap(try device.stored())
        let store = device.reopenStore()
        let resumed = try SelfServiceClient(saved: store.load(), sink: store, compiled: nil)
        XCTAssertTrue(try resumed.registered())
        XCTAssertNil(try resumed.contactText())
        XCTAssertEqual(try device.stored(), checkpoint)
        let commits = device.commits
        let transport = FakeTransport(server: try StandServer(credential: resumed.credential()))
        transport.answer = { _ in
            let durable = try SelfServiceClient(saved: device.stored(), sink: device.reopenStore(), compiled: nil)
            XCTAssertNotNil(try durable.contactText(), "own QR must be durable before discovery/session")
            XCTAssertEqual(try durable.credential() as NSDictionary, credential)
            return nil
        }
        let owner = StateOwner(client: resumed)
        let flow = ProofFlow(owner: owner, transport: transport, pacer: RecordingPacer())
        guard case .session = try await flow.connect() else { return XCTFail("session expected") }
        XCTAssertFalse(transport.calls.contains { $0.path.hasPrefix("/v2/registration/") })
        XCTAssertEqual(device.commits, commits + 1, "only missing contact preparation is committed")
        let final = try SelfServiceClient(saved: device.stored(), sink: device.reopenStore(), compiled: nil)
        XCTAssertEqual(try final.credential() as NSDictionary, credential)
        let contact = try XCTUnwrap(try final.contactText())
        let peer = try Device(name: "f4-qr-reader", trust: Self.trust)
        try peer.register()
        XCTAssertEqual(try peer.client.previewContact(contact)["account"] as? String,
                       credential["account"] as? String)
        let settled = try device.stored()
        _ = try await flow.connect()
        XCTAssertEqual(device.commits, commits + 1)
        XCTAssertEqual(try device.stored(), settled, "repeat connection must not rotate fallback material")
    }

    func testFailedSchemaUpgradeFreezesBeforeAnyRequest() async throws {
        try await assertFailedResume(activeCheckpoint: false)
    }

    func testFailedContactPreparationFreezesBeforeAnyRequest() async throws {
        try await assertFailedResume(activeCheckpoint: true)
    }

    func testFreshWelcomeResumeCreatesNothingAndDialsNothing() async throws {
        let device = try Device(name: "f4-welcome", trust: Self.trust)
        try device.client.resumeOnboarding()
        let owner = StateOwner(client: device.client)
        let transport = FakeTransport(server: try StandServer(credential: [:]))
        let flow = ProofFlow(owner: owner, transport: transport)
        guard case .idle = try await flow.connect() else { return XCTFail("Welcome is idle") }
        XCTAssertEqual(device.commits, 0)
        XCTAssertNil(try device.stored())
        XCTAssertTrue(transport.calls.isEmpty)
    }

    private func assertFailedResume(activeCheckpoint: Bool) async throws {
        let device = try Device(name: "f4-resume-fault", trust: Self.trust)
        if activeCheckpoint { try device.client.createIdentity() }
        failSecondWrite(on: device)
        if activeCheckpoint {
            let status = try SelfServiceClientTests.activeStatus(for: device.client.credential())
            XCTAssertThrowsError(try device.client.registrationResult(status: status))
        } else {
            XCTAssertThrowsError(try device.client.createIdentity())
        }
        device.fileSystem.failure = nil
        let checkpoint = try XCTUnwrap(try device.stored())
        let store = device.reopenStore()
        let resumed = try SelfServiceClient(saved: store.load(), sink: store, compiled: nil)
        let transport = FakeTransport(server: try StandServer(credential: resumed.credential()))
        let owner = StateOwner(client: resumed)
        let flow = ProofFlow(owner: owner, transport: transport, pacer: RecordingPacer())
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: ENOSPC)
        }
        await assertThrows({ try await flow.connect() }) {
            XCTAssertEqual($0 as? SelfServiceError, .commitFailed)
        }
        XCTAssertTrue(transport.calls.isEmpty)
        device.fileSystem.failure = nil
        XCTAssertEqual(try device.stored(), checkpoint, "no replacement or reset on failed continuation")
        await assertThrows({ try await flow.connect() }) {
            XCTAssertEqual($0 as? SelfServiceError, .frozen)
        }
        XCTAssertTrue(transport.calls.isEmpty, "same process stays frozen even after disk recovers")
    }

    private func failSecondWrite(on device: Device) {
        var writes = 0
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            writes += 1
            guard writes == 2 else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: EIO)
        }
    }
}
