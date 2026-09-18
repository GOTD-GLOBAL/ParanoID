import Foundation
import XCTest
@testable import ParanoidKit

/// The file that holds this phone's own metadata, and the one promise it makes:
/// **an OS backup does not carry it**.
///
/// The cases below are the promise itself (the flag is on the inode the rename
/// moves, and it survives every later replacement), what happens when the
/// device will not prove it (the file goes rather than waiting for the next
/// backup), and the migration off the preferences that used to hold these
/// tables — which must be repeatable, because a phone that dies halfway
/// through it must not lose the names it had.
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

    // MARK: - the promise

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
    }

    /// The regression the inode rule exists for: the flag belongs to the inode
    /// a rename moves, so a second save that forgot to set it on its own
    /// candidate would commit a file an iCloud backup takes.
    func testEveryLaterSaveIsExcludedTooAndNotOnlyTheFirst() throws {
        let store = self.store()
        XCTAssertTrue(store.save(table))
        for round in 1...3 {
            let next = Data(#"{"7c85ae":"Серёга \#(round)"}"#.utf8)
            XCTAssertTrue(store.save(next))
            XCTAssertEqual(store.load(migrating: nothingCarried), next)
            XCTAssertTrue(store.isExcludedFromBackup(), "save \(round) committed a file a backup would take")
        }
    }

    func testTheFlagIsSetOnTheCandidateBeforeTheRename() {
        let fake = FakeFileSystem()
        XCTAssertTrue(store(fake).save(table))
        let interesting = fake.log.filter {
            switch $0 {
            case .fileExists, .removeItem: return false
            default: return true
            }
        }
        let parent = directory.lastPathComponent
        XCTAssertEqual(interesting, [
            .createDirectory(parent),
            .excludeFromBackup(parent),
            .write("metadata.v1.json.tmp", bytes: table.count),
            // Before the rename, and on the candidate: this line is the rule.
            .excludeFromBackup("metadata.v1.json.tmp"),
            .fullSync("metadata.v1.json.tmp", directory: false),
            .rename("metadata.v1.json.tmp", "metadata.v1.json"),
            .read("metadata.v1.json"),
            .readBackupFlag("metadata.v1.json"),
            .fullSync(parent, directory: true),
        ], "the commit sequence is the snapshot's, or the flag does not reach the committed inode")
    }

    // MARK: - when the device will not prove it

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

    func testAFailedCommitLeavesNoCandidateBehind() {
        let fake = FakeFileSystem()
        fake.failure = { if case .rename = $0 { return FileSystemError(.rename, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }
        XCTAssertFalse(store(fake).save(table))
        XCTAssertTrue(fake.log.contains(.removeItem("metadata.v1.json.tmp")))
        XCTAssertNil(fake.contents(at: store(fake).fileURL))
    }

    func testATableAboveTheCeilingIsRefusedRatherThanWrittenUnreadable() {
        let store = self.store()
        let huge = Data(count: LocalMetadataStore.maximumStoredBytes + 1)
        XCTAssertFalse(store.save(huge), "a file the read ceiling would refuse is not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - the migration off the preferences

    func testThePreferenceIsMigratedOnceAndThenCleared() {
        defaults.set(table, forKey: Self.legacyKey)
        let store = self.store()

        XCTAssertEqual(store.load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertNil(defaults.object(forKey: Self.legacyKey),
                     "the old copy is what a backup carried; it does not stay behind")
        XCTAssertEqual(try? Data(contentsOf: store.fileURL), table)
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

    func testAFileTheDeviceWillNotReadFallsBackToThePreferenceRatherThanLosingIt() {
        defaults.set(table, forKey: Self.legacyKey)
        let fake = FakeFileSystem()
        fake.seed(directory: directory)
        fake.seed(file: store(fake).fileURL, data: table)
        fake.failure = { if case .read = $0 { return FileSystemError(.read, URL(fileURLWithPath: "/x"), errno: EIO) }; return nil }

        // A device that will not hand the file back is not a device that has
        // no names: the old value is read instead, and it stays where it is
        // until a commit that can be proven replaces it.
        XCTAssertEqual(store(fake).load(migrating: { $0.data(forKey: Self.legacyKey) }), table)
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), table)
    }

    func testAPreferenceHoldingNothingWorthKeepingIsStillCleared() {
        defaults.set(Data(), forKey: Self.legacyKey)
        XCTAssertNil(store().load(migrating: { _ in nil }))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey),
                     "an unusable old value is still an old value a backup carried")
    }

    func testClearingForgetsBothTheFileAndThePreference() {
        defaults.set(table, forKey: Self.legacyKey)
        let store = self.store()
        XCTAssertTrue(store.save(table))
        XCTAssertTrue(store.clear())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
        XCTAssertNil(store.load(migrating: { $0.data(forKey: Self.legacyKey) }))
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
