import Foundation
import XCTest
@testable import ParanoidKit

/// The file that holds this phone's own metadata, and the two promises it makes:
/// **an OS backup does not carry it**, and **no failure of this store destroys
/// the table it is holding**.
///
/// The first half of this file is the backup promise: the flag is on the inode
/// the rename moves, it is there before any row is, and it survives every later
/// replacement. The second half is the promise the PR47 review found broken in
/// three places — a failed directory sync deleting the only copy, a transient
/// read failure becoming an empty table that then overwrote the real one, and a
/// preference retired against bytes nobody had parsed. Each of those has a case
/// here that fails against the first draft.
final class LocalMetadataStoreTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private static let legacyKey = "paranoid.tests.metadata.v1"
    private static let name = "metadata.v1.json"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-metadata-" + UUID().uuidString, isDirectory: true)
        suiteName = "paranoid.tests.metadata." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suiteName = nil
        directory = nil
        try super.tearDownWithError()
    }

    private func store(_ fileSystem: FileSystem = DataProtectionFileSystem()) -> LocalMetadataStore {
        LocalMetadataStore(name: Self.name, legacyKey: Self.legacyKey,
                           directory: directory, defaults: defaults, fileSystem: fileSystem)
    }

    /// Nothing is migrated: the case is only about the file.
    private func nothingCarried(_: UserDefaults) -> Data? { nil }

    private let table = Data(#"{"7c85ae":"Серёга"}"#.utf8)

    private func reads(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: - the backup promise

    func testASavedTableIsReadBackAndNoBackupCarriesIt() throws {
        let store = self.store()
        XCTAssertTrue(store.save(table))
        XCTAssertEqual(store.load(migrating: nothingCarried), table)
        XCTAssertTrue(store.isExcludedFromBackup(), "a backup would otherwise carry who this phone talks to")

        // The flag is really on the file, not only in this type's account of it.
        var url = store.fileURL
        url.removeAllCachedResourceValues()
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // And the directory carries it too, for anything that lands beside it.
        var parent = directory!
        parent.removeAllCachedResourceValues()
        XCTAssertEqual(try parent.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // No candidate is left behind for a backup to find instead.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
    }

    /// The regression the inode rule exists for: the flag belongs to the inode
    /// a rename moves, so a second save that forgot to set it on its own
    /// candidate would commit a file an iCloud backup takes.
    func testEveryLaterSaveIsExcludedTooAndNotOnlyTheFirst() {
        let store = self.store()
        XCTAssertTrue(store.save(table))
        for round in 1...3 {
            let next = Data(#"{"7c85ae":"Серёга \#(round)"}"#.utf8)
            XCTAssertTrue(store.save(next))
            XCTAssertEqual(store.load(migrating: nothingCarried), next)
            XCTAssertTrue(store.isExcludedFromBackup(), "save \(round) committed a file a backup would take")
        }
    }

    func testTheFlagIsOnTheCandidateBeforeAnyRowIsAndBeforeTheRename() {
        let fake = FakeFileSystem()
        XCTAssertTrue(store(fake).save(table))
        let interesting = fake.log.filter {
            if case .fileExists = $0 { return false }
            return true
        }
        let parent = directory.lastPathComponent
        XCTAssertEqual(interesting, [
            .createDirectory(parent),
            .excludeFromBackup(parent),
            // Any candidate of an interrupted run goes first: it may predate
            // its own exclusion.
            .removeItem("metadata.v1.json.tmp"),
            // The inode is flagged while it is still empty, so no interruption
            // can leave the table in an unflagged file.
            .write("metadata.v1.json.tmp", bytes: 0),
            .excludeFromBackup("metadata.v1.json.tmp"),
            .write("metadata.v1.json.tmp", bytes: table.count),
            .fullSync("metadata.v1.json.tmp", directory: false),
            .rename("metadata.v1.json.tmp", "metadata.v1.json"),
            .read("metadata.v1.json"),
            .readBackupFlag("metadata.v1.json"),
            .fullSync(parent, directory: true),
        ], "the commit sequence is the snapshot's, or the flag does not reach the committed inode")
    }

    func testACandidateLeftByAnInterruptedRunIsNotReused() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = self.store()
        // What a crash between the write and the flag would leave: a file with
        // rows in it that no backup exclusion ever reached.
        try Data(#"{"old":"candidate"}"#.utf8).write(to: store.temporaryFileURL)
        XCTAssertTrue(store.save(table))
        XCTAssertEqual(reads(store.fileURL), table)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
    }

    // MARK: - when the device will not prove the exclusion

    func testAFileThatCannotBeProvenExcludedIsRemovedRatherThanLeftForTheBackup() {
        let store = self.store(LyingBackupFileSystem())
        XCTAssertFalse(store.save(table), "a file that may be backed up is not a successful save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "the committed file must not survive an unproven exclusion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
    }

    func testAStoredByteThatDoesNotComeBackIsRemovedRatherThanTrusted() {
        let fake = FakeFileSystem()
        fake.readReturns = { _ in Data("{}".utf8) }
        XCTAssertFalse(store(fake).save(table))
        XCTAssertTrue(fake.log.contains(.removeItem("metadata.v1.json")))
    }

    /// Adversarial review, 2026-09-18: the same class as the directory-sync
    /// defect, one line further on. By the time the verification runs, the
    /// rename has already unlinked the copy this table replaced — so a check
    /// that merely *throws* must not delete what it could not check.
    func testAThrowingReadbackKeepsTheCommittedFileRatherThanDeletingIt() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        XCTAssertFalse(store.save(table), "an unverified commit is not a successful save")
        XCTAssertEqual(fake.contents(at: store.fileURL), table,
                       "but it is the only table there is, and an unanswered question is not proof against it")
        XCTAssertFalse(fake.log.contains(.removeItem("metadata.v1.json")))
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table, "nor is the preference retired on it")
    }

    func testAThrowingBackupFlagReadKeepsTheCommittedFileToo() {
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.failure = {
            if case .readBackupFlag = $0 {
                return FileSystemError(.readBackupFlag, URL(fileURLWithPath: "/x"), errno: EIO)
            }
            return nil
        }
        XCTAssertFalse(store.save(table))
        XCTAssertEqual(fake.contents(at: store.fileURL), table,
                       "the candidate's inode was flagged before the rename; a question the device would not answer does not undo that")
        XCTAssertFalse(fake.log.contains(.removeItem("metadata.v1.json")))
    }

    /// Adversarial review, 2026-09-18: once a save can legitimately keep both
    /// copies — which the directory-sync fix introduced — the preference may be
    /// *older* than the file, so it must never be written back over it.
    func testAnUnreadableFileIsNeverOverwrittenByThePreferenceBehindIt() {
        let stale = Data(#"{"old":"stale"}"#.utf8)
        let newer = Data(#"{"new":"current"}"#.utf8)
        defaults.set(stale, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: newer)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), stale,
                       "the old copy is still shown rather than nothing")
        XCTAssertTrue(store.isSealed)
        XCTAssertEqual(fake.contents(at: store.fileURL), newer,
                       "but the newer table is not replaced by it")
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), stale)
    }

    func testAFailedCommitLeavesNoCandidateBehind() {
        let fake = FakeFileSystem()
        fake.failure = { if case .rename = $0 { return FileSystemError(.rename, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }
        let store = self.store(fake)
        XCTAssertFalse(store.save(table))
        XCTAssertTrue(fake.log.contains(.removeItem("metadata.v1.json.tmp")))
        XCTAssertNil(fake.contents(at: store.fileURL))
    }

    func testATableAboveTheCeilingIsRefusedRatherThanWrittenUnreadable() {
        let store = self.store()
        let huge = Data(count: LocalMetadataStore.maximumStoredBytes + 1)
        XCTAssertFalse(store.save(huge), "a file the read ceiling would refuse is not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// PR47 review, defect 4: the ceiling has to clear the largest table the
    /// product itself admits, or that table never migrates and stays in the
    /// backup-eligible preference for ever.
    func testTheCeilingClearsTheLargestLogTheCoreAdmits() throws {
        var records: [String: [CallRecord]] = [:]
        for peer in 0..<64 {
            let account = String(repeating: "0", count: 62) + String(format: "%02x", peer)
            records[account] = (0..<CallLog.perAccountLimit).map { index in
                CallRecord(id: String(format: "%08x-0000-4000-8000-000000000000", index),
                           account: account, kind: .outgoing, video: false, durationSeconds: 60,
                           afterMessageId: "12345678-1234-4234-8234-123456789abc")
            }
        }
        let encoded = try JSONEncoder().encode(records)
        XCTAssertLessThanOrEqual(encoded.count, LocalMetadataStore.maximumStoredBytes,
                                 "64 conversations of 500 calls is admissible; it must be storable")
    }

    // MARK: - PR47 review: no failure of this store destroys the table

    /// Defect 1. The directory sync makes the *rename* durable. Losing it is a
    /// reason to answer `false`, never a reason to delete the file that has
    /// already been committed, verified and proven excluded — by then it is the
    /// only copy there is.
    func testAFailedDirectorySyncKeepsTheCommittedFileAndThePreference() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.failure = {
            if case .fullSync(_, directory: true) = $0 {
                return FileSystemError(.fullSync, URL(fileURLWithPath: "/x"), errno: EIO)
            }
            return nil
        }
        XCTAssertFalse(store.save(table), "an unproven rename is not a successful save")
        XCTAssertEqual(fake.contents(at: store.fileURL), table, "the only remaining copy must not be deleted")
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table,
                       "nor may the copy that would survive a power loss be retired")
    }

    /// Defect 2. A file that exists and will not open is not an empty table.
    /// Without the seal the caller starts empty and its next write replaces a
    /// table it never read.
    func testAnUnreadableFileWithNothingBehindItSealsTheStore() {
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: table)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        XCTAssertNil(store.load(migrating: nothingCarried))
        XCTAssertTrue(store.isSealed)
        XCTAssertFalse(store.save(Data("{}".utf8)), "a sealed store writes nothing")
        XCTAssertFalse(store.clear(), "and an emptied in-memory table is not a deletion")
        XCTAssertEqual(fake.contents(at: store.fileURL), table, "the table nobody could read is still there")

        // A later launch that can read it takes the seal off again.
        fake.failure = nil
        XCTAssertEqual(store.load(migrating: nothingCarried), table)
        XCTAssertFalse(store.isSealed)
        XCTAssertTrue(store.save(Data("{}".utf8)))
    }

    /// Defect 2, through the caller that suffers from it: the names a phone
    /// already migrated must survive a read that fails once.
    func testATransientReadFailureCannotOverwriteNamesTheStoreHolds() {
        let fake = FakeFileSystem()
        let store = LocalMetadataStore(name: ContactNames.fileName, legacyKey: ContactNames.defaultsKey,
                                       directory: directory, defaults: defaults, fileSystem: fake)
        let stored = Data(#"{"alice":"Алиса"}"#.utf8)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: stored)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        var names = ContactNames(store: store)
        XCTAssertEqual(names.name(for: "alice"), "", "this launch genuinely has no table to show")
        fake.failure = nil
        names.rename("Боря", for: "boris")
        XCTAssertEqual(fake.contents(at: store.fileURL), stored, "and it must not write its empty table over the real one")
    }

    /// Defect 3, first half: bytes coming back is not proof. The preference is
    /// retired only against a file that is also provably excluded.
    func testAReadableFileWhoseExclusionCannotBeProvenDoesNotRetireThePreference() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: table)
        fake.failure = {
            if case .readBackupFlag = $0 {
                return FileSystemError(.readBackupFlag, URL(fileURLWithPath: "/x"), errno: EIO)
            }
            return nil
        }
        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table,
                       "an unproven file does not end the old copy's life")
    }

    /// Defect 3, second half: a file this build cannot parse is not an empty
    /// table either. The preference beside it is the better copy and is used,
    /// and the unusable file is written over rather than trusted.
    func testACorruptFileBesideAGoodPreferenceIsReplacedByIt() {
        let fake = FakeFileSystem()
        let store = self.store(fake)
        defaults.set(table, forKey: Self.legacyKey)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: Data("not this build's table".utf8))

        let loaded = store.load(migrating: { $0.data(forKey: Self.legacyKey) },
                                validate: { $0.starts(with: Data("{".utf8)) })
        XCTAssertEqual(loaded, table)
        XCTAssertEqual(fake.contents(at: store.fileURL), table, "the unusable file is replaced, not kept")
        XCTAssertNil(defaults.object(forKey: Self.legacyKey), "and only now may the preference go")
    }

    /// Defect 5: a save that succeeds later in the same run finishes the
    /// migration the first one could not, without waiting for a relaunch.
    func testASuccessfulSaveAfterAFailedMigrationRetiresThePreference() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.failure = { if case .write = $0 { return FileSystemError(.write, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table, "a failed migration keeps the old copy")

        fake.failure = nil
        let updated = Data(#"{"7c85ae":"Серёга","other":"Мама"}"#.utf8)
        XCTAssertTrue(store.save(updated))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    // MARK: - the migration off the preferences

    func testThePreferenceIsMigratedOnceAndThenCleared() {
        defaults.set(table, forKey: Self.legacyKey)
        let store = self.store()

        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertNil(defaults.object(forKey: Self.legacyKey),
                     "the old copy is what a backup carried; it does not stay behind")
        XCTAssertEqual(reads(store.fileURL), table)
        XCTAssertTrue(store.isExcludedFromBackup())
        // A second launch reads the file and asks the preferences for nothing.
        XCTAssertEqual(store.load(migrating: { _ in XCTFail("the file is the only copy now"); return nil }), table)
    }

    func testAnInterruptedMigrationRepeatsRatherThanLosingTheTable() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        fake.failure = { if case .write = $0 { return FileSystemError(.write, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        // The phone still shows the names it had…
        XCTAssertEqual(store(fake).load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        // …and the old value survives, because nothing durable replaced it.
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table)
        // The next launch, with a disk that works, finishes the move.
        XCTAssertEqual(store().load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    func testAFileTheDeviceWillNotReadFallsBackToThePreferenceThatStandsBehindIt() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: table)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        // The old copy is shown rather than nothing — but it is not written
        // back, because a file that will not open may be newer than it.
        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table)
        XCTAssertTrue(store.isSealed)
        XCTAssertFalse(store.save(Data("{}".utf8)))
    }

    func testAPreferenceHoldingNothingWorthKeepingIsStillCleared() {
        defaults.set(Data(), forKey: Self.legacyKey)
        XCTAssertNil(store().load(migrating: { _ in nil }))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey),
                     "an unusable old value is still an old value a backup carried")
    }

    func testClearingForgetsTheFileTheCandidateAndThePreference() throws {
        defaults.set(table, forKey: Self.legacyKey)
        let store = self.store()
        XCTAssertTrue(store.save(table))
        try Data("left behind".utf8).write(to: store.temporaryFileURL)

        XCTAssertTrue(store.clear())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
        XCTAssertNil(store.load(migrating: { $0.data(forKey: Self.legacyKey) }))
    }

    func testClearingRemovesTheFileTheCandidateAndMakesTheRemovalDurable() {
        let fake = FakeFileSystem()
        let store = self.store(fake)
        XCTAssertTrue(store.save(table))
        fake.log.removeAll()
        XCTAssertTrue(store.clear())
        XCTAssertEqual(fake.log.filter { if case .fileExists = $0 { return false }; return true }, [
            .removeItem("metadata.v1.json"),
            .removeItem("metadata.v1.json.tmp"),
            .fullSync(directory.lastPathComponent, directory: true),
        ], "an emptied table that comes back after a power loss is the same disclosure")
    }

    /// Adversarial review, 2026-09-18: the preference is the backup-eligible
    /// copy and the one a later launch would resurrect the emptied table from,
    /// so it goes first and unconditionally — not after a directory sync that
    /// may never happen.
    func testClearingRetiresThePreferenceEvenWhenTheRemovalCannotBeMadeDurable() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        let store = self.store(fake)
        fake.seed(directory: directory)
        fake.seed(file: store.fileURL, data: table)
        fake.failure = {
            if case .fullSync(_, directory: true) = $0 {
                return FileSystemError(.fullSync, URL(fileURLWithPath: "/x"), errno: EIO)
            }
            return nil
        }
        XCTAssertFalse(store.clear(), "an undurable removal is not a successful one")
        XCTAssertNil(fake.contents(at: store.fileURL), "the file the owner emptied is gone")
        XCTAssertNil(defaults.object(forKey: Self.legacyKey),
                     "and so is the backup-eligible copy that would otherwise bring it back")
    }

    func testAStoreWithNoPreferencesMigratesNothing() {
        let store = LocalMetadataStore(name: Self.name, legacyKey: Self.legacyKey,
                                       directory: directory, defaults: nil)
        XCTAssertNil(store.load(migrating: { _ in XCTFail("there is no suite to read"); return nil }))
        XCTAssertTrue(store.save(table))
        XCTAssertEqual(store.load(migrating: { _ in nil }), table)
    }
}

/// A file system that does everything for real but refuses to confirm the
/// backup flag, which is the one answer the store is not allowed to assume.
private struct LyingBackupFileSystem: FileSystem {
    private let real = DataProtectionFileSystem()

    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func excludeFromBackup(at url: URL) throws { try real.excludeFromBackup(at: url) }
    func isExcludedFromBackup(at url: URL) throws -> Bool { false }
    func write(_ data: Data, to url: URL) throws { try real.write(data, to: url) }
    func fullSync(at url: URL, directory: Bool) throws { try real.fullSync(at: url, directory: directory) }
    func rename(from source: URL, to destination: URL) throws { try real.rename(from: source, to: destination) }
    func read(at url: URL, maximumBytes: Int) throws -> Data { try real.read(at: url, maximumBytes: maximumBytes) }
    func removeItem(at url: URL) throws { try real.removeItem(at: url) }
}
