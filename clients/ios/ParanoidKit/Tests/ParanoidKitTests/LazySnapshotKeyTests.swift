import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// Actual SnapshotStore/StorageGuard logic with a synthetic key store and file
/// system. CryptoKit sealing is real; Keychain execution is a separate suite.
final class LazySnapshotKeyTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fake/Application Support/paranoid", isDirectory: true)
    private let text = "[TEST ONLY] lazy snapshot"

    func testWelcomeAndRelaunchCreateNoWrappingKey() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        for _ in 0..<2 {
            let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
            XCTAssertNil(try store.load())
            XCTAssertFalse(try keys.exists())
        }
        XCTAssertEqual(keys.creations, 0)
        XCTAssertEqual(keys.deletions, 0)
    }

    func testFirstCommitCreatesOnceAndReopensWithTheSameKey() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertNil(try store.load())
        try store.commit(text)
        XCTAssertEqual(keys.creations, 1)
        try store.commit(text + " updated")
        let reopened = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertEqual(try reopened.load(), text + " updated")
        XCTAssertEqual(keys.creations, 1)
        XCTAssertEqual(keys.deletions, 0)
    }

    func testMissingRetainedFileRefusesLoadAndCommitWithoutReplacingKey() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try store.commit(text)
        let sealed = try fs.read(at: store.fileURL, maximumBytes: SnapshotStore.maximumStoredBytes)
        try fs.removeItem(at: store.fileURL)
        let reopened = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertThrowsError(try reopened.commit("must not replace lost state"))
        XCTAssertEqual(keys.creations, 1)
        XCTAssertEqual(keys.deletions, 0)
        XCTAssertEqual(try SnapshotCodec.open(key: XCTUnwrap(keys.material), value: sealed), text)
    }

    func testMissingRetainedKeyRefusesLoadAndCommitWithoutGenerating() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try store.commit(text)
        keys.material = nil // fault injection, not a product reset
        let reopened = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertThrowsError(try reopened.commit(text))
        XCTAssertEqual(keys.creations, 1)
        XCTAssertTrue(reopened.snapshotExists())
    }

    func testUnreadableKeyIsNotTreatedAsAbsent() throws {
        let keys = MemoryWrappingKey()
        keys.unreadable = true
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: FakeFileSystem())
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.commit(text))
        XCTAssertEqual(keys.creations, 0)
    }

    func testWriteFailureAfterKeyCreationKeepsKeyAndFreezesNextLaunch() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        fs.failure = { call in
            if case .write = call { return FileSystemError(.write, self.directory, errno: EIO) }
            return nil
        }
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try store.commit(text))
        XCTAssertTrue(try keys.exists())
        XCTAssertFalse(store.snapshotExists())
        XCTAssertEqual(keys.creations, 1)
        let reopened = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertEqual(keys.deletions, 0)
    }

    func testRunningStoreNeverRegeneratesAfterBothHalvesDisappear() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try store.commit(text)
        keys.material = nil
        try fs.removeItem(at: store.fileURL)
        XCTAssertThrowsError(try store.commit(text + " must not regenerate"))
        XCTAssertEqual(keys.creations, 1)
        XCTAssertFalse(store.snapshotExists())
    }

    func testRunningStoreRefusesAReplacedWrappingKey() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try store.commit(text)
        keys.material = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try store.commit(text + " must not rewrap"))
        XCTAssertTrue(store.isBroken)
        XCTAssertEqual(keys.creations, 1)
    }

    func testDirectCommitRefusesKeyOnlyState() throws {
        let keys = MemoryWrappingKey()
        _ = try keys.create()
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try store.commit(text)) { error in
            XCTAssertEqual(error as? StorageError, .broken)
        }
        XCTAssertEqual(store.brokenCause as? StorageError, .frozen)
        XCTAssertEqual(keys.creations, 1)
        XCTAssertEqual(keys.deletions, 0)
        XCTAssertFalse(fs.log.contains { if case .write = $0 { return true }; return false })
    }

    func testDirectCommitRefusesFileOnlyState() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        let prior = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try prior.commit(text)
        let before = fs.contents(at: prior.fileURL)
        keys.material = nil
        let writes = fs.log.filter { if case .write = $0 { return true }; return false }.count
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try store.commit(text + " must not replace")) { error in
            XCTAssertEqual(error as? StorageError, .broken)
        }
        XCTAssertEqual(store.brokenCause as? StorageError, .frozen)
        XCTAssertEqual(keys.creations, 1)
        XCTAssertEqual(keys.deletions, 0)
        XCTAssertEqual(fs.contents(at: prior.fileURL), before)
        XCTAssertEqual(fs.log.filter { if case .write = $0 { return true }; return false }.count, writes)
    }

    func testDirectCommitRefusesUnreadableKey() throws {
        let keys = MemoryWrappingKey()
        keys.unreadable = true
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try store.commit(text)) { error in
            XCTAssertEqual(error as? StorageError, .broken)
        }
        XCTAssertEqual(store.brokenCause as? StorageError, .keychain(-25308))
        XCTAssertEqual(keys.creations, 0)
        XCTAssertEqual(keys.deletions, 0)
        XCTAssertFalse(fs.log.contains { if case .write = $0 { return true }; return false })
    }

    func testFirstKeyIsReadBackBeforeAnyCandidateWrite() throws {
        let keys = MemoryWrappingKey()
        let fs = FakeFileSystem()
        fs.failure = { call in
            if case .write = call { XCTAssertEqual(keys.events, ["load", "create", "load"]) }
            return nil
        }
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        try store.commit(text)
        XCTAssertEqual(keys.events, ["load", "create", "load"])
        XCTAssertEqual(try store.load(), text)
    }

    func testFailedFirstKeyReadbackNeverWritesOrDeletes() throws {
        for fault in [MemoryWrappingKey.CreateFault.missing, .different, .unreadable] {
            let keys = MemoryWrappingKey()
            keys.createFault = fault
            let fs = FakeFileSystem()
            let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
            XCTAssertThrowsError(try store.commit(text)) { error in
                XCTAssertEqual(error as? StorageError, .broken)
            }
            let cause: StorageError = fault == .unreadable ? .keychain(-25308) : .frozen
            XCTAssertEqual(store.brokenCause as? StorageError, cause)
            XCTAssertEqual(keys.creations, 1)
            XCTAssertEqual(keys.deletions, 0)
            XCTAssertFalse(store.snapshotExists())
            XCTAssertFalse(fs.log.contains { if case .write = $0 { return true }; return false })
            XCTAssertThrowsError(try store.commit(text))
            XCTAssertEqual(keys.creations, 1, "the broken store cannot try creating again")
        }
    }

    func testCreateFailureIsTerminalWithoutWritingSnapshot() throws {
        let keys = MemoryWrappingKey()
        keys.refuseCreation = true
        let fs = FakeFileSystem()
        let store = SnapshotStore(directory: directory, keyStore: keys, fileSystem: fs)
        XCTAssertThrowsError(try store.commit(text))
        XCTAssertTrue(store.isBroken)
        XCTAssertFalse(store.snapshotExists())
        XCTAssertEqual(keys.creations, 0)
        XCTAssertFalse(fs.log.contains { if case .write = $0 { return true }; return false })
    }
}

final class MemoryWrappingKey: WrappingKeyStore {
    enum CreateFault: Equatable { case none, missing, different, unreadable }
    var createFault = CreateFault.none
    var events: [String] = []
    var material: SymmetricKey?
    var creations = 0
    var deletions = 0
    var unreadable = false
    var refuseCreation = false
    func exists() throws -> Bool {
        if unreadable { throw StorageError.keychain(-25308) }
        return material != nil
    }
    func load() throws -> SymmetricKey? {
        events.append("load")
        if unreadable { throw StorageError.keychain(-25308) }
        return material
    }
    func create() throws -> SymmetricKey {
        events.append("create")
        if refuseCreation { throw StorageError.keychain(-25291) }
        guard material == nil else { throw StorageError.keychain(-25299) }
        let key = SymmetricKey(size: .bits256)
        material = key
        creations += 1
        switch createFault {
        case .none: break
        case .missing: material = nil
        case .different: material = SymmetricKey(size: .bits256)
        case .unreadable: unreadable = true
        }
        return key
    }
    func deleteRetained() throws {
        if material != nil { deletions += 1 }
        material = nil
    }
}
