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

    /// The container these tests commit into: a commit records in it that a
    /// state file now exists. One scratch suite for the whole run, emptied
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

    /// The commit's sixth step is about *a container*, and the command-line
    /// tools of this package have none: their wrapping key lives in process
    /// memory, they never run the launch rule, and their
    /// `UserDefaults.standard` is the preferences of whoever ran them — a
    /// bundle-less process writes `~/Library/Preferences/<process>.plist`,
    /// which no launch of this client will ever read. So they commit with no
    /// marker at all, and this is both halves of that: the store does nothing
    /// when it has no container, and the two tools ask for none.
    func testAStoreWithNoContainerRecordsNothingAnywhere() throws {
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: FakeFileSystem(), marker: nil)
        try store.commit(Self.text)

        XCTAssertTrue(store.snapshotExists(), "the file itself is committed exactly as ever")
        XCTAssertNil(UserDefaults.standard.object(forKey: InstallMarker.snapshotKey),
                     "a container fact reached the defaults of the process running these tests, "
                     + "which is where a tool would put it on the build Mac")

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

        // The second fact is independent of the first and disappears with the
        // same container.
        XCTAssertFalse(marker.hasCommittedSnapshot)
        try marker.recordCommittedSnapshot()
        XCTAssertTrue(InstallMarker(defaults: defaults).hasCommittedSnapshot)
        XCTAssertEqual(InstallMarker.snapshotKey, "paranoid.snapshot.v1")
        marker.forgetCommittedSnapshot()
        XCTAssertFalse(marker.hasCommittedSnapshot)
        XCTAssertTrue(marker.isPresent, "forgetting the file is not forgetting the install")

        // The third is what a container recorded by this rule carries and one
        // recorded by an earlier build does not, so `record()` writes it and
        // it is the licence to read the second fact's absence as evidence.
        XCTAssertTrue(marker.recordsCommits, "the marker of a first launch under this rule")
        XCTAssertEqual(InstallMarker.recordingKey, "paranoid.install.v2")
        XCTAssertNotEqual(InstallMarker.recordingKey, InstallMarker.key,
                          "the meaning of paranoid.install.v1 is never reinterpreted in place")

        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(InstallMarker(defaults: defaults).isPresent,
                       "the marker must disappear with the container")
        XCTAssertFalse(InstallMarker(defaults: defaults).recordsCommits,
                       "and so must the rest of what it remembered")
    }

    // MARK: - the startup rule (StorageGuard.start)

    /// What every installation of every build shipped before this rule holds:
    /// `paranoid.install.v1`, a committed state file and a Keychain key, and
    /// no `paranoid.snapshot.v1`, because nothing ever wrote one. The launch
    /// that installs this build therefore cannot read that silence as "nothing
    /// was ever committed here" — on the container of the owner's own iPhone
    /// it would be false — so a key without a file there must keep freezing
    /// until the container has been through a launch that could see what it
    /// holds.
    func testAContainerFromABuildBeforeThisRuleIsNotReadAsHavingCommittedNothing() throws {
        // The upgraded container, stated exactly: the old marker, nothing else.
        defaults.set(true, forKey: InstallMarker.key)
        XCTAssertTrue(marker.isPresent)
        XCTAssertFalse(marker.recordsCommits)
        XCTAssertFalse(marker.hasCommittedSnapshot)
        let key = FakeRetainedKey(present: true)

        // The state file is gone by the first launch of this build — the
        // window a background update leaves open, and the accident the rule
        // exists for.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
        XCTAssertTrue(key.present, "the wrapping key of the missing file is kept for a person")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen,
                       "and the refusal is reproducible, not a one-off")

        // The ordinary upgrade — the file is still there — adopts the fact on
        // the first launch that sees it, and from then on the same pair
        // freezes for the reason it is written down rather than for the reason
        // it is not.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)
        XCTAssertTrue(marker.hasCommittedSnapshot)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
    }

    /// The one relief an installation from before this rule does get, and the
    /// moment it earns it: a launch that finds neither a key nor a state file
    /// can *see* that the container holds nothing, so from there its record is
    /// this rule's and an interrupted first run after it opens normally.
    func testAnUpgradedContainerStartsItsRecordOnceItHoldsNeitherHalf() throws {
        defaults.set(true, forKey: InstallMarker.key)
        let key = FakeRetainedKey(present: false)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.recordsCommits, "observed, not assumed: the container is empty")

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
    /// back.
    func testAKeyFromAFirstRunThatCommittedNothingIsNotAFreeze() throws {
        let key = FakeRetainedKey(present: false)

        // Launch 1: an empty container. The application creates the key right
        // after this answer, before the user has decided anything.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true

        // Launch 2, after Welcome was closed: the same key, still no file.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertEqual(key.destroyed, 0, "the key of this installation is not a stale one")
        XCTAssertTrue(key.present, "and it is the key every later commit is sealed with")

        // The user creates the identity on that launch; from the next one on
        // this is the ordinary retained launch.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)

        // And the dangerous half of the same row is unchanged: a container
        // that has held a state file freezes when the file is gone, so nothing
        // ever starts a second identity over a snapshot that was there.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0, "a freeze deletes nothing")
    }

    /// The same protection without a launch in between: the commit itself
    /// records that the container now holds a state file, so a file removed
    /// during the first session — before any later launch could notice it —
    /// still freezes the next one.
    func testACommitRecordsThatTheContainerHoldsAStateFile() throws {
        let key = FakeRetainedKey(present: false)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        key.present = true

        try store(FakeFileSystem(), key: newKey()).commit(Self.text)

        XCTAssertTrue(marker.hasCommittedSnapshot)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
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
        XCTAssertFalse(marker.hasCommittedSnapshot, "a refusal records nothing either")

        // Still frozen on every later launch, and still holding both halves.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .frozen)
        XCTAssertEqual(key.destroyed, 0)
    }

    /// A reinstall is the case the marker exists for, and it is unchanged: the
    /// container is gone, so no state file can be there, and the key of the
    /// previous installation is deleted rather than reused (D-004).
    func testAMissingMarkerWithNoStateFileIsStillAReinstall() throws {
        let key = FakeRetainedKey(present: true)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)

        XCTAssertEqual(key.destroyed, 1)
        XCTAssertFalse(key.present, "a stale key is never reused to recover anything")
        XCTAssertTrue(marker.isPresent)
    }

    /// A container that cannot keep the fact does not lose its client over it.
    ///
    /// The launch that records a state file it can see is repairing
    /// bookkeeping, not deciding anything: it holds both halves, it
    /// regenerates nothing, and it opens the retained state either way.
    /// Failing it closed would turn the ordinary launch of a healthy
    /// installation into the frozen screen, whose only way out for a user is a
    /// reinstall — which destroys the very identity the freeze was protecting.
    ///
    /// The commit's own sixth step is the opposite choice, deliberately, and
    /// it is what makes the soft one safe. Where the fact matters is a launch
    /// that would *start* something: there the container has to write, and a
    /// container that cannot is broken before an identity is adopted and
    /// before anything is sent (`SelfServiceClient.apply` commits before it
    /// adopts). So the client of a container whose preferences have stopped
    /// answering ends on the frozen screen either way; what this rule decides
    /// is only whether a launch with its state file intact is spent there too.
    func testALaunchIsNotFrozenByAContainerThatCannotRecordWhatItHolds() throws {
        let deaf = try XCTUnwrap(DeafDefaults(suiteName: Self.suiteName))
        let marker = InstallMarker(defaults: deaf)
        try marker.record()
        let key = FakeRetainedKey(present: true)
        deaf.accepts = false

        XCTAssertEqual(try StorageGuard.start(snapshotExists: true, marker: marker, key: key), .retained)
        XCTAssertFalse(marker.hasCommittedSnapshot, "the write really was refused")

        // And the identity such a container would try to create instead, if
        // its state file were gone too, never reaches a peer: the store breaks
        // on the step that records the commit, before the state is adopted.
        let store = SnapshotStore(directory: Self.directory, key: newKey(),
                                  fileSystem: FakeFileSystem(), marker: marker)
        XCTAssertThrowsError(try store.commit(Self.text))
        XCTAssertTrue(store.isBroken)
    }

    /// An iCloud restore onto a new iPhone brings the defaults back, including
    /// what this container remembered about its state file, while the
    /// `ThisDeviceOnly` key and the excluded file stay behind. The launch has
    /// nothing to protect, so it starts clean — and must forget the restored
    /// fact, or the first run on the new phone would freeze exactly like the
    /// interrupted one above.
    func testARestoredContainerWithNeitherHalfForgetsWhatItHeld() throws {
        let key = FakeRetainedKey(present: false)
        try marker.record()
        try marker.recordCommittedSnapshot()

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertFalse(marker.hasCommittedSnapshot)

        key.present = true
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
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

/// A preferences domain that stops accepting writes, which is the one failure
/// `InstallMarker` is written to report and the one a real `UserDefaults`
/// cannot be made to produce: its read-back is served from the same in-process
/// cache the write went into, so the check never fires there. Dropping the
/// write is what a domain that cannot be persisted looks like from inside.
final class DeafDefaults: UserDefaults {
    /// Writes go through until this is cleared; reads always do, so a fixture
    /// can put a container into a known state first.
    var accepts = true

    override func set(_ value: Any?, forKey defaultName: String) {
        guard accepts else { return }
        super.set(value, forKey: defaultName)
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
