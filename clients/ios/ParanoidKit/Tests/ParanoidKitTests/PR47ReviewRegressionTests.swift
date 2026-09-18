// Review regression proposals for PR47 HEAD 173b45b.
// NOT EXECUTED: coordinator has no Swift/Xcode toolchain.
// Copy into ParanoidKit/Tests/ParanoidKitTests beside SnapshotStoreTests.swift
// (uses its existing FakeFileSystem), then run --filter PR47ReviewRegressionTests.
import Foundation
import XCTest
@testable import ParanoidKit

final class PR47ReviewRegressionTests: XCTestCase {
    private let key = "pr47.review.metadata"
    private let directory = URL(fileURLWithPath: "/pr47-review-fixture", isDirectory: true)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "pr47.review." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func store(_ fake: FakeFileSystem, _ defaults: UserDefaults) -> LocalMetadataStore {
        LocalMetadataStore(name: "metadata.json", legacyKey: key, directory: directory,
                           defaults: defaults, fileSystem: fake)
    }

    func testDirectorySyncFailureDoesNotDeleteAlreadyProvenExcludedCopy() throws {
        try withDefaults { defaults in
            let fake = FakeFileSystem()
            let store = self.store(fake, defaults)
            fake.seed(directory: directory)
            fake.seed(file: store.fileURL, data: Data("old".utf8))
            fake.failure = {
                if case .fullSync(_, directory: true) = $0 {
                    return FileSystemError(.fullSync, self.directory, code: 5, reason: "injected")
                }
                return nil
            }
            XCTAssertFalse(store.save(Data("new".utf8)))
            // Old or new recovery policy can differ, but deleting the ONLY
            // remaining proven-excluded copy is not a recovery strategy.
            XCTAssertNotNil(fake.contents(at: store.fileURL))
        }
    }

    func testReadableFileDoesNotRetireLegacyWithoutExclusionProof() throws {
        try withDefaults { defaults in
            let fake = FakeFileSystem()
            let store = self.store(fake, defaults)
            let data = Data("legacy".utf8)
            defaults.set(data, forKey: key)
            fake.seed(directory: directory)
            fake.seed(file: store.fileURL, data: data)
            fake.failure = {
                if case .readBackupFlag = $0 {
                    return FileSystemError(.readBackupFlag, self.directory, code: 5, reason: "injected")
                }
                return nil
            }
            _ = store.load(migrating: { $0.data(forKey: self.key) })
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
    }

    func testSuccessfulSaveAfterFailedMigrationRetiresLegacyWithoutRelaunch() throws {
        try withDefaults { defaults in
            let fake = FakeFileSystem()
            let store = self.store(fake, defaults)
            let data = Data("legacy".utf8)
            defaults.set(data, forKey: key)
            fake.failure = {
                if case .write = $0 {
                    return FileSystemError(.write, self.directory, code: 5, reason: "injected")
                }
                return nil
            }
            XCTAssertEqual(store.load(migrating: { $0.data(forKey: self.key) }), data)
            XCTAssertEqual(defaults.data(forKey: key), data)
            fake.failure = nil
            XCTAssertTrue(store.save(Data("updated".utf8)))
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testTransientReadFailureCannotOverwritePreviouslyMigratedNames() throws {
        try withDefaults { defaults in
            let fake = FakeFileSystem()
            let store = LocalMetadataStore(name: ContactNames.fileName,
                                           legacyKey: ContactNames.defaultsKey,
                                           directory: directory, defaults: defaults,
                                           fileSystem: fake)
            fake.seed(directory: directory)
            fake.seed(file: store.fileURL, data: Data(#"{"alice":"Alice"}"#.utf8))
            fake.failure = {
                if case .read = $0 {
                    return FileSystemError(.read, self.directory, code: 5, reason: "injected")
                }
                return nil
            }
            var names = ContactNames(store: store)
            fake.failure = nil
            names.rename("Bob", for: "bob")
            XCTAssertEqual(ContactNames(store: store).name(for: "alice"), "Alice")
        }
    }

    func testMaximumAdmittedCallLogFitsTheClaimedMigrationBudget() throws {
        var records: [String: [CallRecord]] = [:]
        for peer in 0..<64 {
            let account = String(repeating: "0", count: 62) + String(format: "%02x", peer)
            records[account] = (0..<CallLog.perAccountLimit).map { index in
                CallRecord(id: String(format: "%08x-0000-4000-8000-000000000000", index),
                           account: account, kind: .outgoing, video: false,
                           durationSeconds: 60,
                           afterMessageId: "12345678-1234-4234-8234-123456789abc")
            }
        }
        let encoded = try JSONEncoder().encode(records)
        XCTAssertLessThanOrEqual(encoded.count, LocalMetadataStore.maximumStoredBytes,
                                "Valid pre-upgrade history must not remain forever in backup-eligible defaults")
    }
}
