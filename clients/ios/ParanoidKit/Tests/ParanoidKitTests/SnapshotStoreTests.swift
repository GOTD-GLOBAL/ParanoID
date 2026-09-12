import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the at-rest rules: the five durable steps of a commit
/// in order, a freeze on any failure, the backup exclusion that has to sit on
/// the inode, the 9 MiB read ceiling and the continuity exclusive-or.
///
/// Everything runs against `FakeFileSystem`, an in-memory tree that records
/// every call and can fail exactly one of them; no real file, no Keychain, no
/// network. The Keychain half of the rule needs a real Keychain and lives in
/// `App/ParanoIDTests/KeychainStoreTests.swift`.
final class SnapshotStoreTests: XCTestCase {
    /// A snapshot-shaped text. Real snapshots hold private keys; this one is
    /// synthetic and is the only thing these tests ever store.
    private static let text = #"{"version":3,"realm":"https://127.0.0.2:38443","note":"[TEST ONLY] состояние 🎈"}"#
    private static let directory = URL(fileURLWithPath: "/fake/Application Support/paranoid",
                                       isDirectory: true)

    private func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func sealedSize(of value: String) -> Int {
        Data(value.utf8).count + SnapshotCodec.minimumSnapshotBytes
    }

    private func digest(_ data: Data?) -> String {
        SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func store(_ fileSystem: FakeFileSystem, key: SymmetricKey) -> SnapshotStore {
        SnapshotStore(directory: Self.directory, key: key, fileSystem: fileSystem)
    }

    private func storageError<Result>(_ body: @autoclosure () throws -> Result,
                                      file: StaticString = #filePath, line: UInt = #line) -> StorageError? {
        var caught: StorageError?
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            caught = error as? StorageError
            XCTAssertNotNil(caught, "expected StorageError, got \(error)", file: file, line: line)
        }
        return caught
    }

    // MARK: - the commit sequence (first-contact-v1.md:173-178)

    func testSuccessfulCommitRunsTheFiveDurableStepsInOrder() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())

        try store.commit(Self.text)

        XCTAssertEqual(fileSystem.durableSteps, [
            .write(SnapshotStore.temporaryFileName, bytes: sealedSize(of: Self.text)),
            .fullSync(SnapshotStore.temporaryFileName, directory: false),
            .rename(SnapshotStore.temporaryFileName, SnapshotStore.fileName),
            .read(SnapshotStore.fileName),
            .fullSync("paranoid", directory: true),
        ])
        XCTAssertEqual(fileSystem.durableSteps.count, 5)
        XCTAssertFalse(store.isBroken)
        XCTAssertNil(store.brokenCause)
        XCTAssertTrue(store.snapshotExists())
        XCTAssertNil(fileSystem.contents(at: store.temporaryFileURL), "the candidate must not survive its commit")
    }

    func testTheCandidateIsExcludedFromBackupBeforeTheRenameNotAfterIt() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())

        try store.commit(Self.text)

        // The flag lives on the inode, so the only moment it can reach the
        // committed file is while that inode is still the temporary one.
        let excluded = try XCTUnwrap(
            fileSystem.log.firstIndex(of: .excludeFromBackup(SnapshotStore.temporaryFileName)))
        let renamed = try XCTUnwrap(
            fileSystem.log.firstIndex(of: .rename(SnapshotStore.temporaryFileName, SnapshotStore.fileName)))
        XCTAssertLessThan(excluded, renamed)
    }

    func testTheDirectoryIsCreatedOnceAndExcludedFromBackupAtCreation() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())

        try store.commit(Self.text)
        try store.commit(Self.text)

        XCTAssertEqual(fileSystem.log.filter { $0 == .createDirectory("paranoid") }.count, 1)
        let created = try XCTUnwrap(fileSystem.log.firstIndex(of: .createDirectory("paranoid")))
        let excluded = try XCTUnwrap(fileSystem.log.firstIndex(of: .excludeFromBackup("paranoid")))
        XCTAssertEqual(excluded, created + 1)
    }

    func testEveryCommitLeavesTheFileAndTheDirectoryExcludedFromBackup() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())

        try store.commit(Self.text)
        try store.commit(Self.text + " second")

        // The second commit replaces the inode under `text-state.enc`, which
        // is why the exclusion cannot be a one-off at creation: without it the
        // second candidate would enter the backup and an iCloud restore would
        // hand back a stale ratchet while the Keychain key still works.
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: store.fileURL))
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: store.directory))
        XCTAssertEqual(
            fileSystem.log.filter { $0 == .excludeFromBackup(SnapshotStore.temporaryFileName) }.count, 2)
        XCTAssertEqual(try store.load(), Self.text + " second")
    }

    // MARK: - any failure freezes (self-service.md:97-100)

    func testFullSyncFailureBreaksTheStoreAndLeavesTheCommittedBytesUntouched() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        try store.commit(Self.text)
        let committed = digest(fileSystem.contents(at: store.fileURL))

        fileSystem.failure = { call in
            guard case .fullSync = call else { return nil }
            return FileSystemError(.fullSync, store.temporaryFileURL, errno: EIO)
        }
        XCTAssertEqual(storageError(try store.commit("{\"version\":3,\"n\":2}")), .broken)

        XCTAssertTrue(store.isBroken)
        XCTAssertEqual((store.brokenCause as? FileSystemError)?.operation, .fullSync)
        // The rename never ran, so the state on disk is byte for byte the one
        // that was committed successfully.
        XCTAssertEqual(digest(fileSystem.contents(at: store.fileURL)), committed)
        XCTAssertNil(fileSystem.contents(at: store.temporaryFileURL), "the failed candidate must be removed")
    }

    func testWriteFailureOnTheFirstCommitLeavesNoStateFileAtAll() {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        fileSystem.failure = { call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, store.temporaryFileURL, errno: ENOSPC)
        }

        XCTAssertEqual(storageError(try store.commit(Self.text)), .broken)

        XCTAssertTrue(store.isBroken)
        XCTAssertFalse(store.snapshotExists())
        XCTAssertNil(fileSystem.contents(at: store.temporaryFileURL))
    }

    func testReadbackMismatchBreaksTheStore() {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        // One flipped bit is all it takes: the comparison is byte for byte.
        fileSystem.readReturns = { data in
            var copy = data
            copy[copy.startIndex] ^= 0x01
            return copy
        }

        XCTAssertEqual(storageError(try store.commit(Self.text)), .broken)

        XCTAssertTrue(store.isBroken)
        XCTAssertEqual(store.brokenCause as? StorageError, .readbackMismatch)
    }

    func testABrokenStoreNeverTouchesTheFileSystemAgain() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        fileSystem.failure = { call in
            guard case .rename = call else { return nil }
            return FileSystemError(.rename, store.fileURL, errno: EIO)
        }
        XCTAssertEqual(storageError(try store.commit(Self.text)), .broken)
        let cause = store.brokenCause
        fileSystem.failure = nil
        fileSystem.log.removeAll()

        XCTAssertEqual(storageError(try store.commit(Self.text)), .broken)
        XCTAssertEqual(storageError(try store.load()), .broken)

        XCTAssertTrue(fileSystem.log.isEmpty, "a broken store must not write, read or fsync anything")
        XCTAssertEqual((cause as? FileSystemError)?.operation, .rename)
        XCTAssertEqual((store.brokenCause as? FileSystemError)?.operation, .rename,
                       "the first cause is the one that is kept")
    }

    // MARK: - load

    func testLoadReturnsNilWithoutAStateFileAndTheCommittedTextAfterOne() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())

        XCTAssertNil(try store.load())
        try store.commit(Self.text)
        XCTAssertEqual(try store.load(), Self.text)
    }

    func testLoadRefusesAStoredFileAboveTheNineMebibyteCeiling() {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        fileSystem.seed(directory: Self.directory)
        fileSystem.seed(file: store.fileURL,
                        data: Data(count: SnapshotStore.maximumStoredBytes + 1))

        XCTAssertEqual(storageError(try store.load()), .broken)

        XCTAssertEqual((store.brokenCause as? FileSystemError)?.operation, .read)
        XCTAssertEqual(SnapshotStore.maximumStoredBytes, 9 * 1024 * 1024)
    }

    func testLoadOfAFileSealedUnderAnotherKeyBreaksInsteadOfStartingOver() throws {
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        fileSystem.seed(directory: Self.directory)
        fileSystem.seed(file: store.fileURL,
                        data: try SnapshotCodec.seal(key: newKey(), value: Self.text))

        XCTAssertEqual(storageError(try store.load()), .broken)

        XCTAssertEqual(store.brokenCause as? SnapshotCodecError, .authenticationFailure)
    }

    // MARK: - continuity (StorageGuard.java:7-8)

    func testContinuityFreezesWhenOnlyOneOfThePairExists() {
        XCTAssertEqual(StorageGuard.continuity(snapshotExists: false, keyExists: true), .frozen)
        XCTAssertEqual(StorageGuard.continuity(snapshotExists: true, keyExists: false), .frozen)
        XCTAssertEqual(StorageGuard.continuity(snapshotExists: false, keyExists: false), .fresh)
        XCTAssertEqual(StorageGuard.continuity(snapshotExists: true, keyExists: true), .retained)

        XCTAssertEqual(storageError(try StorageGuard.requireContinuity(snapshotExists: false, keyExists: true)),
                       .frozen)
        XCTAssertEqual(storageError(try StorageGuard.requireContinuity(snapshotExists: true, keyExists: false)),
                       .frozen)
        XCTAssertNoThrow(try StorageGuard.requireContinuity(snapshotExists: false, keyExists: false))
        XCTAssertNoThrow(try StorageGuard.requireContinuity(snapshotExists: true, keyExists: true))
        XCTAssertEqual(StorageGuard.account, "paranoid-text-state-v0")
    }

    // MARK: - install marker

    func testInstallMarkerIsAbsentUntilItIsRecorded() throws {
        let suite = "global.paranoid.messenger.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = InstallMarker(defaults: defaults)

        XCTAssertFalse(marker.isPresent)
        try marker.record()
        XCTAssertTrue(marker.isPresent)
        XCTAssertTrue(InstallMarker(defaults: defaults).isPresent)
        XCTAssertEqual(InstallMarker.key, "paranoid.install.v1")

        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(InstallMarker(defaults: defaults).isPresent,
                       "the marker must disappear with the container")
    }
}

/// An in-memory file system that records every call and can fail a chosen one.
///
/// It models the two details the commit rules depend on: a `rename` moves the
/// inode, carrying its `isExcludedFromBackup` flag to the new name, and a
/// `write` to an existing path keeps that inode. Anything the real
/// implementation does beyond that (data protection classes, `F_FULLFSYNC`
/// semantics) is not modelled — those are exercised for real by
/// `KeychainStoreTests` on the simulator.
final class FakeFileSystem: FileSystem {
    /// One call, named by the last path component so an expectation reads as
    /// the commit sequence does.
    enum Call: Equatable {
        case fileExists(String)
        case createDirectory(String)
        case excludeFromBackup(String)
        case readBackupFlag(String)
        case write(String, bytes: Int)
        case fullSync(String, directory: Bool)
        case rename(String, String)
        case read(String)
        case removeItem(String)

        /// The five steps that have to reach the device, in the order
        /// `SnapshotStore` performs them. Metadata calls are not among them.
        var isDurable: Bool {
            switch self {
            case .write, .fullSync, .rename, .read: return true
            case .fileExists, .createDirectory, .excludeFromBackup, .readBackupFlag, .removeItem: return false
            }
        }
    }

    private struct Node {
        var data: Data?
        var isDirectory: Bool
        var excluded = false
    }

    /// Every call, in order.
    var log: [Call] = []
    /// Returns an error to fail that call with, or `nil` to let it run.
    var failure: ((Call) -> Error?)?
    /// Rewrites what `read` hands back, to model a device that returns
    /// something other than what was written.
    var readReturns: ((Data) -> Data)?

    private var nodes: [String: Node] = [:]

    var durableSteps: [Call] { log.filter(\.isDurable) }

    func contents(at url: URL) -> Data? { nodes[url.path]?.data }

    func seed(directory url: URL) { nodes[url.path] = Node(data: nil, isDirectory: true, excluded: true) }

    func seed(file url: URL, data: Data) { nodes[url.path] = Node(data: data, isDirectory: false, excluded: true) }

    private func record(_ call: Call) throws {
        log.append(call)
        if let error = failure?(call) { throw error }
    }

    private func inode(at url: URL, _ operation: FileSystemError.Operation) throws -> Node {
        guard let node = nodes[url.path] else {
            throw FileSystemError(operation, url, errno: ENOENT)
        }
        return node
    }

    func fileExists(at url: URL) -> Bool {
        log.append(.fileExists(url.lastPathComponent))
        return nodes[url.path] != nil
    }

    func createDirectory(at url: URL) throws {
        try record(.createDirectory(url.lastPathComponent))
        nodes[url.path] = Node(data: nil, isDirectory: true)
    }

    func excludeFromBackup(at url: URL) throws {
        try record(.excludeFromBackup(url.lastPathComponent))
        var node = try inode(at: url, .excludeFromBackup)
        node.excluded = true
        nodes[url.path] = node
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool {
        try record(.readBackupFlag(url.lastPathComponent))
        return try inode(at: url, .readBackupFlag).excluded
    }

    func write(_ data: Data, to url: URL) throws {
        try record(.write(url.lastPathComponent, bytes: data.count))
        // Truncating an existing file keeps its inode, and with it the backup
        // flag; a new path is a new inode, which starts included in backups.
        var node = nodes[url.path] ?? Node(data: nil, isDirectory: false)
        node.data = data
        node.isDirectory = false
        nodes[url.path] = node
    }

    func fullSync(at url: URL, directory: Bool) throws {
        try record(.fullSync(url.lastPathComponent, directory: directory))
        let node = try inode(at: url, .fullSync)
        guard node.isDirectory == directory else {
            throw FileSystemError(.fullSync, url, errno: ENOTDIR)
        }
    }

    func rename(from source: URL, to destination: URL) throws {
        try record(.rename(source.lastPathComponent, destination.lastPathComponent))
        let node = try inode(at: source, .rename)
        nodes[destination.path] = node
        nodes.removeValue(forKey: source.path)
    }

    func read(at url: URL, maximumBytes: Int) throws -> Data {
        try record(.read(url.lastPathComponent))
        guard let data = try inode(at: url, .read).data else {
            throw FileSystemError(.read, url, errno: EISDIR)
        }
        guard data.count <= maximumBytes else {
            throw FileSystemError(.read, url, code: Int(EFBIG), reason: "stored snapshot above the read limit")
        }
        return readReturns?(data) ?? data
    }

    func removeItem(at url: URL) throws {
        try record(.removeItem(url.lastPathComponent))
        nodes.removeValue(forKey: url.path)
    }
}
