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

    /// The container these tests commit into: a first commit withdraws from
    /// it the claim that nothing has been committed. One scratch suite for
    /// the whole run, emptied
    /// around every case, so the cases stay independent of each other and
    /// nothing of the run reaches the defaults the application uses. The name
    /// is fixed rather than unique per run, because a removed domain still
    /// leaves its (empty) file behind in the host's preferences and a name
    /// minted per run would leave one more of them on every execution.
    ///
    /// Neither of the two below has a value until `setUpWithError` gives it
    /// one: the standard defaults are not a safe stand-in for a scratch suite,
    /// not even as a placeholder that is never read.
    private static let suiteName = "global.paranoid.messenger.tests.storage"
    private var defaults: UserDefaults!
    private var marker: InstallMarker!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        marker = InstallMarker(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        try super.tearDownWithError()
    }

    private func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func sealedSize(of value: String) -> Int {
        Data(value.utf8).count + SnapshotCodec.minimumSnapshotBytes
    }

    private func digest(_ data: Data?) -> String {
        SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func store(_ fileSystem: FakeFileSystem, key: SymmetricKey) -> SnapshotStore {
        SnapshotStore(directory: Self.directory, key: key, fileSystem: fileSystem, marker: marker)
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

    /// The withdrawal between steps 2 and 3 is about *a container*, and the
    /// command-line tools of this package have none: their wrapping key lives
    /// in process memory, they never run the launch rule, and their
    /// `UserDefaults.standard` is the preferences of whoever ran them — a
    /// bundle-less process writes `~/Library/Preferences/<process>.plist`,
    /// which no launch of this client will ever read. So they commit with no
    /// marker at all, and this is both halves of that: the store commits
    /// exactly as ever when it has no container, and the two tools ask for
    /// none.
    func testAStoreWithNoContainerCommitsAsEverAndTheToolsAskForNone() throws {
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: FakeFileSystem(), marker: nil)
        try store.commit(Self.text)

        XCTAssertTrue(store.snapshotExists(), "the file itself is committed exactly as ever")
        XCTAssertEqual(try store.load(), Self.text)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // ParanoidKitTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // the package
        for tool in ["service-bridge", "voice-lane-probe"] {
            let source = root.appendingPathComponent("Sources/\(tool)/main.swift")
            let text = try String(contentsOf: source, encoding: .utf8)
            let constructions = text.components(separatedBy: "SnapshotStore(").dropFirst()
            XCTAssertFalse(constructions.isEmpty, "\(tool): no store to check")
            for construction in constructions {
                // Up to the parenthesis that closes the call, so an argument
                // which is itself a call cannot end the list early.
                var depth = 1
                let arguments = construction.prefix {
                    if $0 == "(" { depth += 1 }
                    if $0 == ")" { depth -= 1 }
                    return depth > 0
                }
                XCTAssertTrue(arguments.contains("marker: nil"),
                              "\(tool): a store is built with the default container — "
                              + "SnapshotStore(\(arguments))")
            }
        }
    }

    func testInstallMarkerIsAbsentUntilItIsRecorded() throws {
        // A container of this test's own, because the case ends by destroying
        // it. The name is fixed and emptied on the way in: a removed domain
        // leaves its file behind in the host's preferences, and a name minted
        // per run would leave one more of them on every execution.
        let suite = "global.paranoid.messenger.tests.marker"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = InstallMarker(defaults: defaults)

        XCTAssertFalse(marker.isPresent)
        try marker.record()
        XCTAssertTrue(marker.isPresent)
        XCTAssertTrue(InstallMarker(defaults: defaults).isPresent)
        XCTAssertEqual(InstallMarker.key, "paranoid.install.v1")

        // The second fact is independent of the first, is read only by its
        // presence, and disappears with the same container.
        XCTAssertFalse(marker.isFirstRunPending)
        try marker.recordPendingFirstRun()
        XCTAssertTrue(InstallMarker(defaults: defaults).isFirstRunPending)
        XCTAssertEqual(InstallMarker.pendingKey, "paranoid.firstrun.pending.v1")
        try marker.withdrawPendingFirstRun()
        XCTAssertFalse(marker.isFirstRunPending)
        XCTAssertNoThrow(try marker.withdrawPendingFirstRun(),
                         "withdrawing what is not there is not a failure")
        XCTAssertTrue(marker.isPresent, "withdrawing the first run is not forgetting the install")
        XCTAssertNotEqual(InstallMarker.pendingKey, InstallMarker.key,
                          "the meaning of paranoid.install.v1 is never reinterpreted in place")

        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(InstallMarker(defaults: defaults).isPresent,
                       "the marker must disappear with the container")
        XCTAssertFalse(InstallMarker(defaults: defaults).isFirstRunPending,
                       "and so must the rest of what it remembered")
    }

    // MARK: - the startup rule (StorageGuard.start)

    /// The owner reviewer's scenario, as he stated it (pull request #36, the
    /// second review of 67af672): a new-format installation commits an
    /// identity; the commit's bookkeeping is lost, rolled back or never
    /// persisted while the install markers survive; the state file is then
    /// lost before any launch could repair the bookkeeping; and the launch
    /// after that finds a key, a marker and nothing else. Under the previous
    /// rule that launch was the interrupted first run and offered a fresh
    /// identity over the key of the lost file. It must be a freeze, with the
    /// key kept, nothing recorded, and the same freeze on the launch after it.
    ///
    /// The loss is simulated the way a preferences domain suffers it: every
    /// fact of the container except the install markers is removed. Under
    /// this rule that removes nothing — after a commit the container holds no
    /// fact whose loss could open anything, which the assertion in the middle
    /// states outright — and under the previous rule it removed
    /// `paranoid.snapshot.v1`, which is what turned the last launch into a
    /// fresh one.
    func testALostCommitRecordAndALostFileDoNotAddUpToAFreshInstall() throws {
        let key = FakeRetainedKey(present: false)
        let fileSystem = FakeFileSystem()

        // 1. The installation: a first launch, the key, an identity committed.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true
        let store = store(fileSystem, key: newKey())
        try store.commit(Self.text)
        XCTAssertTrue(store.snapshotExists())

        // 2. The bookkeeping of that commit is lost; the install markers of
        //    this rule and of the previous one survive.
        let installMarkers: Set<String> = [InstallMarker.key, "paranoid.install.v2"]
        let facts = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("paranoid.") })
        XCTAssertEqual(facts, [InstallMarker.key],
                       "after a commit the container holds nothing whose loss could open the client")
        for fact in facts.subtracting(installMarkers) {
            defaults.removeObject(forKey: fact)
        }

        // 3. The state file is lost before any later launch.
        try fileSystem.removeItem(at: store.fileURL)
        XCTAssertFalse(store.snapshotExists())

        // 4. The launch refuses, keeps the key, records nothing, and refuses
        //    again.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
        XCTAssertTrue(key.present, "the wrapping key of the lost file is kept for a person")
        XCTAssertFalse(marker.isFirstRunPending, "and the refusal records nothing")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen,
                       "reproducible on the next launch, not a one-off")
    }

    /// The reviewer's second fixture: a preferences domain whose same-process
    /// read-back succeeds and whose update then disappears, which a real
    /// `UserDefaults` cannot be made to show — `set` and `removeObject` are
    /// acknowledged from the in-process cache, and whether they reach the
    /// plist is another process's business. The rule is inverted so that the
    /// write it opens on fails safe when it is lost: the fact recorded before
    /// the key is created is what a key with no file is read on, and a
    /// container that lost it freezes instead of starting over.
    func testAPendingFactWhoseWriteNeverPersistedFreezesTheKeyItExplained() throws {
        let volatile = try XCTUnwrap(VolatileDefaults(suiteName: Self.suiteName))
        let marker = InstallMarker(defaults: volatile)
        let key = FakeRetainedKey(present: false)
        try marker.record()
        volatile.persist()

        // The launch that finds the container empty records the fact, reads
        // it back, and the application creates the key on its answer.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.isFirstRunPending, "acknowledged in this process")
        key.present = true

        // The write never reached the plist.
        volatile.reopen()
        XCTAssertTrue(marker.isPresent)
        XCTAssertFalse(marker.isFirstRunPending)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
        XCTAssertTrue(key.present)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen,
                       "and it stays a freeze, which a person can resolve")
    }

    /// The same fixture on the withdrawal: a first commit whose withdrawal was
    /// acknowledged and never persisted leaves the container claiming it has
    /// committed nothing, beside the file that proves otherwise. The launch
    /// that opens the file withdraws the claim again — a repair the previous
    /// rule made too — and from then on the file's loss freezes.
    func testAWithdrawalThatNeverPersistedIsWithdrawnAgainByTheLaunchThatOpensTheFile() throws {
        let volatile = try XCTUnwrap(VolatileDefaults(suiteName: Self.suiteName))
        let marker = InstallMarker(defaults: volatile)
        let key = FakeRetainedKey(present: false)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true
        volatile.persist()

        let fileSystem = FakeFileSystem()
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: fileSystem, marker: marker)
        try store.commit(Self.text)
        XCTAssertFalse(marker.isFirstRunPending, "withdrawn, as far as this process can see")
        volatile.reopen()
        XCTAssertTrue(marker.isFirstRunPending, "the claim is back, and it is false")

        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)
        XCTAssertFalse(marker.isFirstRunPending, "the launch that opens the file withdraws it again")
        volatile.persist()
        volatile.reopen()
        XCTAssertFalse(marker.isFirstRunPending)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// The remainder this rule does not close, kept executable so that nobody
    /// has to rediscover it: the withdrawal at the first commit is a defaults
    /// write like any other. If it is acknowledged and never persisted, and
    /// the state file is then lost before any launch has seen it, the launch
    /// after that finds the key, no file and a container still claiming that
    /// nothing was committed here — and opens on the claim. The window is the
    /// one between the first commit and the next launch, where the previous
    /// rule's record was exposed on every later day; closing it means a fact
    /// that lives where the key lives, or a key created at the first commit as
    /// Android's is, and both are the owner's decision (`StorageGuard`, and
    /// `docs/security/ios-client-threats.md`). A strict expected failure: the
    /// day the rule closes it, this test fails by passing and the expectation
    /// is removed.
    func testTheRemainderAWithdrawalThatNeverPersistedAndAFileLostBeforeAnyLaunchSawIt() throws {
        let volatile = try XCTUnwrap(VolatileDefaults(suiteName: Self.suiteName))
        let marker = InstallMarker(defaults: volatile)
        let key = FakeRetainedKey(present: false)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true
        volatile.persist()

        let fileSystem = FakeFileSystem()
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: fileSystem, marker: marker)
        try store.commit(Self.text)
        volatile.reopen()                                   // the withdrawal never reached the plist
        try fileSystem.removeItem(at: store.fileURL)        // and the file is lost before any launch

        try XCTExpectFailure("a withdrawal that never persisted, and a file lost before any launch saw it, "
                         + "still open the client; see StorageGuard for what closing it takes",
                         strict: true) {
            XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        }
        XCTAssertEqual(key.destroyed, 0, "whatever the answer, nothing is deleted")
    }

    /// What every installation of every build shipped before this rule holds:
    /// `paranoid.install.v1`, a committed state file and a Keychain key, and
    /// no word about its first run, because no build wrote one. The upgrade
    /// therefore needs no rule of its own: a key without a file there freezes
    /// for the same reason it freezes anywhere — the container cannot vouch
    /// for it — which is what the previous form of this rule promised the
    /// container of the owner's own iPhone.
    func testAContainerFromABuildBeforeThisRuleFreezesOverItsMissingFile() throws {
        // The upgraded container, stated exactly: the old marker, nothing else.
        defaults.set(true, forKey: InstallMarker.key)
        XCTAssertTrue(marker.isPresent)
        XCTAssertFalse(marker.isFirstRunPending)
        let key = FakeRetainedKey(present: true)

        // The state file is gone by the first launch of this build — the
        // window a background update leaves open, and the accident the rule
        // exists for.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
        XCTAssertTrue(key.present, "the wrapping key of the missing file is kept for a person")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen,
                       "and the refusal is reproducible, not a one-off")

        // The ordinary upgrade — the file is still there — is the ordinary
        // launch, and it records nothing a later launch could open on.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)
        XCTAssertFalse(marker.isFirstRunPending)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)

        // The facts of the previous, unshipped form of this rule are not this
        // rule's word either: a container that holds them and no pending fact
        // — an interrupted first run under that form — freezes, and a
        // reinstall is what it takes.
        defaults.set(true, forKey: "paranoid.install.v2")
        defaults.set(true, forKey: "paranoid.snapshot.v1")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// The one relief an installation from before this rule does get, and the
    /// moment it earns it: a launch that finds neither a key nor a state file
    /// can *see* that the container holds nothing, so it records that, and an
    /// interrupted first run after it opens normally.
    func testAnUpgradedContainerEarnsItsWordOnceItHoldsNeitherHalf() throws {
        defaults.set(true, forKey: InstallMarker.key)
        let key = FakeRetainedKey(present: false)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.isFirstRunPending, "observed, not assumed: the container is empty")

        // The application creates the key on that launch and the user closes
        // Welcome without «Создать ID»; the launch after it is the interrupted
        // first run, and it must not be a permanent freeze.
        key.present = true
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// A first run that shows Welcome and is closed without «Создать ID»
    /// leaves the wrapping key the launch created and no state file, because
    /// nothing is committed until an identity is created. That is the state of
    /// an interrupted first run, and the launch after it must not freeze — the
    /// user reaches it by doing nothing wrong, and a frozen client has no way
    /// back. What tells it apart from a file that has gone missing is the
    /// container's own word, given before the key existed.
    func testAKeyFromAFirstRunThatCommittedNothingIsNotAFreeze() throws {
        let key = FakeRetainedKey(present: false)

        // Launch 1: an empty container. The fact is on record before the
        // application creates the key, which it does right after this answer.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.isFirstRunPending)
        key.present = true

        // Launch 2, after Welcome was closed: the same key, still no file.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertEqual(key.destroyed, 0, "the key of this installation is not a stale one")
        XCTAssertTrue(key.present, "and it is the key every later commit is sealed with")

        // The user creates the identity on that launch: the commit withdraws
        // the word, and from the next launch on this is the ordinary retained
        // launch.
        let fileSystem = FakeFileSystem()
        let store = store(fileSystem, key: newKey())
        try store.commit(Self.text)
        XCTAssertFalse(marker.isFirstRunPending, "the commit withdraws it, not the next launch")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)

        // And the dangerous half of the same row is unchanged: a container
        // that has held a state file freezes when the file is gone, so nothing
        // ever starts a second identity over a snapshot that was there.
        try fileSystem.removeItem(at: store.fileURL)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
    }

    /// Where in the commit the word is withdrawn, and why there. After the
    /// candidate is synced: a candidate that could not be written or synced
    /// leaves it standing, nothing was renamed and nothing is claimed, so the
    /// next launch may try the first run again. Before the rename: a positive
    /// claim must never be on disk while false, so a rename that fails does so
    /// after the withdrawal — the deliberate cost, a container with nothing
    /// yet that freezes, rather than a container with a file that goes on
    /// claiming it has none.
    func testTheFirstCommitWithdrawsTheWordAfterTheSyncAndBeforeTheRename() throws {
        let key = FakeRetainedKey(present: false)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true

        let unsynced = FakeFileSystem()
        unsynced.failure = { call in
            guard case let .fullSync(_, directory) = call, !directory else { return nil }
            return FileSystemError(.fullSync, Self.directory, errno: EIO)
        }
        XCTAssertEqual(storageError(try store(unsynced, key: newKey()).commit(Self.text)), .broken)
        XCTAssertTrue(marker.isFirstRunPending, "nothing was renamed, so nothing is claimed")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)

        let unrenamed = FakeFileSystem()
        unrenamed.failure = { call in
            guard case .rename = call else { return nil }
            return FileSystemError(.rename, Self.directory, errno: EIO)
        }
        XCTAssertEqual(storageError(try store(unrenamed, key: newKey()).commit(Self.text)), .broken)
        XCTAssertFalse(marker.isFirstRunPending, "withdrawn before the rename that failed")
        XCTAssertTrue(unrenamed.log.contains(.rename(SnapshotStore.temporaryFileName, SnapshotStore.fileName)),
                      "the rename was attempted, and refused")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen,
                       "the deliberate cost: a freeze, on a container that has nothing yet")
        XCTAssertEqual(key.destroyed, 0)
    }

    /// The install marker is a `UserDefaults` entry and the state file is not,
    /// so the two can be lost separately. A missing marker beside a state file
    /// is therefore not proof of a reinstall — a reinstall would have taken
    /// the file with it — and the key that opens that file must survive the
    /// launch. A freeze a person can investigate is recoverable; a deleted
    /// wrapping key is not.
    func testAMissingMarkerBesideAStateFilePreservesBothAndRefusesToProceed() throws {
        let key = FakeRetainedKey(present: true)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .frozen)

        XCTAssertEqual(key.destroyed, 0, "the key that opens the retained file must stay")
        XCTAssertTrue(key.present)
        XCTAssertFalse(marker.isPresent,
                       "recording the marker would make the next launch an ordinary one")
        XCTAssertFalse(marker.isFirstRunPending, "a refusal records nothing either")

        // Still frozen on every later launch, and still holding both halves.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// A reinstall is the case the marker exists for, and it is unchanged: the
    /// container is gone, so no state file can be there, and the key of the
    /// previous installation is deleted rather than reused (D-004). The new
    /// installation's first run is then on record before its own key exists.
    func testAMissingMarkerWithNoStateFileIsStillAReinstall() throws {
        let key = FakeRetainedKey(present: true)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)

        XCTAssertEqual(key.destroyed, 1)
        XCTAssertFalse(key.present, "a stale key is never reused to recover anything")
        XCTAssertTrue(marker.isPresent)
        XCTAssertTrue(marker.isFirstRunPending, "the first run of the new installation is on record")
    }

    /// A container that cannot keep its facts.
    ///
    /// The launch that finds a stale claim beside a state file is repairing
    /// bookkeeping, not deciding anything: it holds both halves, it
    /// regenerates nothing, and it opens the retained state either way.
    /// Failing it closed would turn the ordinary launch of a healthy
    /// installation into the frozen screen, whose only way out for a user is a
    /// reinstall — which destroys the very identity the freeze was protecting.
    ///
    /// The commit is the opposite choice, deliberately, and it is what makes
    /// the soft one safe: a container that cannot stop claiming it has
    /// committed nothing breaks the store before the rename, so nothing is on
    /// disk, no identity is adopted (`SelfServiceClient.apply` commits before
    /// it adopts) and nothing is sent. And a container that cannot record its
    /// first run at all is refused before any key exists.
    func testALaunchIsNotFrozenByAContainerThatCannotWithdrawWhatItClaims() throws {
        let deaf = try XCTUnwrap(DeafDefaults(suiteName: Self.suiteName))
        let marker = InstallMarker(defaults: deaf)
        try marker.record()
        try marker.recordPendingFirstRun()
        let key = FakeRetainedKey(present: true)
        deaf.accepts = false

        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)
        XCTAssertTrue(marker.isFirstRunPending, "the withdrawal really was refused")

        let fileSystem = FakeFileSystem()
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: fileSystem, marker: marker)
        XCTAssertEqual(storageError(try store.commit(Self.text)), .broken)
        XCTAssertTrue(store.isBroken)
        XCTAssertEqual(store.brokenCause as? StorageError, .installMarkerUnavailable)
        XCTAssertFalse(store.snapshotExists(), "nothing was renamed")
        XCTAssertFalse(fileSystem.log.contains { if case .rename = $0 { return true } else { return false } })
        XCTAssertNil(fileSystem.contents(at: store.temporaryFileURL), "and the candidate did not stay behind")

        // The empty container that cannot say so: refused before the caller
        // could create a key it would later find unexplained.
        key.present = false
        deaf.accepts = true
        try marker.withdrawPendingFirstRun()
        deaf.accepts = false
        XCTAssertEqual(storageError(try StorageGuard.start(snapshotExists: false, marker: marker, key: key)),
                       .installMarkerUnavailable)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// A file without its key freezes before anything is withdrawn. A freeze
    /// touches nothing, so it is the same freeze on every later launch; and
    /// nothing reads the fact from that state anyway — the file decides
    /// while it is there, and once it is gone the container holds neither
    /// half and records the fact afresh.
    func testAFileWithoutItsKeyFreezesAndWithdrawsNothing() throws {
        try marker.record()
        try marker.recordPendingFirstRun()
        let key = FakeRetainedKey(present: false)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .frozen)
        XCTAssertTrue(marker.isFirstRunPending, "a freeze withdraws nothing")
        XCTAssertEqual(key.destroyed, 0)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .frozen,
                       "and it is the same freeze on the next launch")

        // The file gone as well: neither half, and a first run recorded afresh.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.isFirstRunPending)
    }

    /// An iCloud restore onto a new iPhone brings the defaults back — the
    /// marker, and whatever the backup caught the container claiming — while
    /// the `ThisDeviceOnly` key and the excluded file stay behind. The launch
    /// has nothing to protect, so it starts clean: it records the first run
    /// afresh, and the run after it opens on that record.
    func testARestoredContainerWithNeitherHalfStartsAFirstRun() throws {
        for restoredMidFirstRun in [false, true] {
            defaults.removePersistentDomain(forName: Self.suiteName)
            let key = FakeRetainedKey(present: false)
            try marker.record()
            if restoredMidFirstRun { try marker.recordPendingFirstRun() }

            XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
            XCTAssertTrue(marker.isFirstRunPending)

            key.present = true
            XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
            XCTAssertEqual(key.destroyed, 0)
        }
    }
}

/// A stand-in for the Keychain item: the two answers the startup rule asks for
/// and a note of whether it was told to delete anything.
///
/// The real item is driven by `App/ParanoIDTests/KeychainStoreTests.swift` on
/// the simulator, inside an application that owns a keychain group; an
/// unsigned host test binary is refused with `errSecMissingEntitlement` before
/// any rule is reached.
final class FakeRetainedKey: RetainedKey {
    /// Whether an item is in the account right now.
    var present: Bool
    /// How many keys this account has actually lost. Asking an empty account
    /// to delete is `errSecItemNotFound`, which the real one reports as
    /// success, so only a removal counts — that is the irreversible act.
    private(set) var destroyed = 0

    init(present: Bool) { self.present = present }

    func exists() throws -> Bool { present }

    func deleteRetained() throws {
        guard present else { return }
        destroyed += 1
        present = false
    }
}

/// A preferences domain that stops accepting writes and removals, which is
/// the one failure `InstallMarker` is written to report and the one a real
/// `UserDefaults` cannot be made to produce: its read-back is served from the
/// same in-process cache the change went into, so the check never fires
/// there. Dropping the change before the read-back is what a domain that
/// cannot be written looks like from inside.
final class DeafDefaults: UserDefaults {
    /// Changes go through until this is cleared; reads always do, so a fixture
    /// can put a container into a known state first.
    var accepts = true

    override func set(_ value: Any?, forKey defaultName: String) {
        guard accepts else { return }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard accepts else { return }
        super.removeObject(forKey: defaultName)
    }
}

/// A preferences domain whose changes are acknowledged from an in-process
/// view and reach the store only on `persist()` — the other failure, and the
/// one the owner's reviewer asked to see exercised: the same-process read-back
/// succeeds, and the change is gone after `reopen()`, as a write is that never
/// left the daemon's cache before the plist stopped being written, or that a
/// restored preferences file rolled back. `DeafDefaults` drops the change
/// before the read-back; this drops it after.
final class VolatileDefaults: UserDefaults {
    /// Changes since the last `persist()`; a removal is recorded as `nil`.
    private var unpersisted: [String: Any?] = [:]
    /// While set, the overrides below fall through to the store: Foundation
    /// routes one of `set` and `removeObject` through the other, and a
    /// `persist()` that went through the overrides would capture its own
    /// writes as unpersisted again.
    private var persisting = false

    override func object(forKey defaultName: String) -> Any? {
        if let change = unpersisted[defaultName] { return change }
        return super.object(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !persisting else { return super.set(value, forKey: defaultName) }
        unpersisted.updateValue(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        guard !persisting else { return super.removeObject(forKey: defaultName) }
        unpersisted.updateValue(nil, forKey: defaultName)
    }

    /// What a daemon that did write the plist would have left.
    func persist() {
        persisting = true
        defer { persisting = false }
        for (name, value) in unpersisted {
            if let value { super.set(value, forKey: name) } else { super.removeObject(forKey: name) }
        }
        unpersisted = [:]
    }

    /// What the next process sees when the plist was never written.
    func reopen() {
        unpersisted = [:]
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
