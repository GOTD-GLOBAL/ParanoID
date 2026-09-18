import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// Production AppModel construction/start with isolated bootstrap inputs and
/// real metadata files/preferences. No user container, Keychain or server.
final class LocalMetadataBootstrapTests: XCTestCase {
    private enum Failure: Error { case locked, unexpectedCommit }
    private final class NoCommitSink: SnapshotSink {
        func save(_ snapshot: String) throws { throw Failure.unexpectedCommit }
    }

    private final class Fixture {
        let directory: URL
        let suiteName: String
        let defaults: UserDefaults
        let callBytes: Data
        var loads = 0

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("paranoid-metadata-bootstrap-" + UUID().uuidString)
            suiteName = "paranoid.tests.metadata-bootstrap." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            callBytes = try JSONEncoder().encode([
                "peer": [CallRecord(id: "old-call", account: "peer", kind: .missed,
                                    video: false, durationSeconds: 0, afterMessageId: nil)]
            ])
            defaults.set(["peer": "Alice"], forKey: ContactNames.defaultsKey)
            defaults.set(callBytes, forKey: CallLog.defaultsKey)
        }

        func store(_ name: String, key: String) -> LocalMetadataStore {
            LocalMetadataStore(name: name, legacyKey: key, directory: directory, defaults: defaults)
        }

        func load() -> (ContactNames, CallLog) {
            loads += 1
            return (ContactNames(store: store(ContactNames.fileName, key: ContactNames.defaultsKey)),
                    CallLog(store: store(CallLog.fileName, key: CallLog.defaultsKey)))
        }

        func assertUntouched(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(loads, 0, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), file: file, line: line)
            XCTAssertEqual(defaults.dictionary(forKey: ContactNames.defaultsKey) as? [String: String],
                           ["peer": "Alice"], file: file, line: line)
            XCTAssertEqual(defaults.data(forKey: CallLog.defaultsKey), callBytes, file: file, line: line)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testTrustUnavailableNoStandDoesNotLoadOrMigrateMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(openClient: { throw SelfServiceError.trustUnavailable },
                             loadLocalMetadata: { fixture.load() })
        // Screen reads must not turn a deferred store into an eager one.
        XCTAssertEqual(model.contactNames.name(for: "peer"), "")
        XCTAssertTrue(model.callLog.records(for: "peer").isEmpty)
        fixture.assertUntouched()
        model.start()
        XCTAssertEqual(model.stage, .noStand(nil))
        fixture.assertUntouched()
        model.start()
        fixture.assertUntouched()
    }

    @MainActor
    func testMalformedStandDoesNotLoadOrMigrateMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(openClient: { throw DebugFixtureProblem(reason: "invalid test fixture") },
                             loadLocalMetadata: { fixture.load() })
        fixture.assertUntouched()
        model.start()
        XCTAssertEqual(model.stage, .noStand("invalid test fixture"))
        fixture.assertUntouched()
    }

    @MainActor
    func testSuccessfulRetryMigratesBothTablesOnceAndKeepsThemUsable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var attempts = 0
        let trust = try ServiceTrust(realm: "https://127.0.0.2:38443",
                                     pin: String(repeating: "ab", count: 32))
        let model = AppModel(openClient: {
            attempts += 1
            if attempts == 1 { throw Failure.locked }
            // No identity: the real runtime cannot contact a server.
            return try SelfServiceClient(saved: nil, sink: NoCommitSink(), fixture: trust)
        }, loadLocalMetadata: { fixture.load() })
        fixture.assertUntouched()
        model.start()
        XCTAssertEqual(model.stage, .frozen)
        fixture.assertUntouched()
        model.retryOpen()
        XCTAssertEqual(model.stage, .running)
        XCTAssertEqual(fixture.loads, 1)
        XCTAssertEqual(model.contactNames.name(for: "peer"), "Alice")
        XCTAssertEqual(model.callLog.records(for: "peer").map(\.id), ["old-call"])
        XCTAssertNil(fixture.defaults.object(forKey: ContactNames.defaultsKey))
        XCTAssertNil(fixture.defaults.object(forKey: CallLog.defaultsKey))
        for (name, key) in [(ContactNames.fileName, ContactNames.defaultsKey),
                            (CallLog.fileName, CallLog.defaultsKey)] {
            let store = fixture.store(name, key: key)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
            XCTAssertTrue(store.isExcludedFromBackup())
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
        }
        model.callFinished(CallTermination(callId: "new-call", account: "peer", outgoing: true,
                                            connected: true, video: false, durationSeconds: 1,
                                            reason: .hangup))
        let reopened = CallLog(store: fixture.store(CallLog.fileName, key: CallLog.defaultsKey))
        XCTAssertEqual(reopened.records(for: "peer").map(\.id), ["old-call", "new-call"])
        model.start()
        XCTAssertEqual(fixture.loads, 1, "repeated start must not remigrate or replace in-memory values")
    }
}
