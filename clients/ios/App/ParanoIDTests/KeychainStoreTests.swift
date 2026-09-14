import CryptoKit
import Foundation
import ParanoidKit
import Security
import XCTest

/// The half of the storage rules that needs a real platform: the Keychain item
/// under `paranoid-text-state-v0`, the install-marker matrix of
/// `StorageGuard`, and one commit driven through `open`/`F_FULLFSYNC`/
/// `rename(2)` on a real file system.
///
/// `SnapshotStoreTests` covers the commit ordering and the injected failures
/// on the host; nothing there can answer whether `SecItemAdd` stores what this
/// client asked for, whether a stale key really disappears, or whether
/// `isExcludedFromBackup` survives a rename. These tests run inside the
/// `ParanoID` application process on the simulator, which is also the only
/// place where the application's own Keychain access applies.
///
/// They use the real account, because that account *is* the subject. That makes
/// them destructive to whatever installation shares the simulator, so they
/// borrow rather than clear it: `setUp` lifts any existing key out of the
/// account and `tearDown` puts the original bytes back, after which the
/// application on that simulator opens its state exactly as before. Without
/// that, a run here would delete the key of an installed client and leave it
/// frozen with a state file it can no longer open — which is what happened once
/// before this was added. They also drop the scratch defaults suite and remove
/// the temporary directory. The state file
/// they write goes to a temporary directory, never to the application's own
/// `Application Support/paranoid/`. No snapshot is ever printed.
final class KeychainStoreTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)
    private static let createIdentity =
        #"{"op":"create_identity","realm":"\#(realm)","pin":"\#(pin)"}"#
    private static let upgradeV2 = #"{"op":"upgrade_v2"}"#
    /// Synthetic, and the only plaintext these tests seal besides a real
    /// freshly created identity.
    private static let probeText = "[TEST ONLY] previous installation"

    private let key = KeychainKey.standard
    private var suiteName = ""
    /// Both are given their value by `setUpWithError` and have none before it:
    /// inside this application `UserDefaults.standard` is the container's own,
    /// so it is not a safe stand-in for a scratch suite even as a placeholder
    /// no test is meant to reach.
    private var defaults: UserDefaults!
    private var marker: InstallMarker!
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let fileSystem = DataProtectionFileSystem()
    /// The key that was in the account before this run, if any.
    private var borrowed: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        borrowed = Self.rawKey()
        try key.deleteRetained()
        // One name for every case and every run: a removed domain still leaves
        // its (empty) file behind in this application's own preferences, and a
        // name minted per case left one more of them in the container on every
        // run of this class.
        suiteName = "global.paranoid.messenger.tests.storage"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        marker = InstallMarker(defaults: defaults)
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("paranoid-storage-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("paranoid", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try key.deleteRetained()
        if let borrowed { Self.restore(borrowed) }
        borrowed = nil
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    // MARK: - the key itself

    func testTheKeyIsCreatedOnceAndNeverRegenerated() throws {
        XCTAssertEqual(KeychainKey.account, "paranoid-text-state-v0")
        XCTAssertFalse(try key.exists(), "setUp must leave the account empty")

        let created = try key.loadOrCreate(snapshotExists: false)
        XCTAssertTrue(try key.exists())
        let sealed = try SnapshotCodec.seal(key: created, value: Self.probeText)

        // Every later call returns the same key, both before and after a state
        // file exists; the only proof that matters is that it opens the box.
        for snapshotExists in [false, true, false] {
            let again = try key.loadOrCreate(snapshotExists: snapshotExists)
            XCTAssertEqual(try SnapshotCodec.open(key: again, value: sealed), Self.probeText)
        }
        XCTAssertEqual(try key.load().map { try SnapshotCodec.open(key: $0, value: sealed) }, Self.probeText)

        // A second item under the same account would make every committed
        // snapshot unreadable, so the Keychain refusal is not swallowed.
        XCTAssertThrowsError(try key.create()) { error in
            XCTAssertEqual(error as? StorageError, .keychain(errSecDuplicateItem))
        }
    }

    func testAMissingKeyIsNeverRegeneratedOverAnExistingStateFile() throws {
        XCTAssertThrowsError(try key.loadOrCreate(snapshotExists: true)) { error in
            XCTAssertEqual(error as? StorageError, .frozen)
        }
        XCTAssertFalse(try key.exists(), "a frozen launch must not leave a new key behind")
    }

    func testTheItemIsAfterFirstUnlockThisDeviceOnlyAndNotSynchronizable() throws {
        _ = try key.create()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])

        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual((attributes[kSecValueData as String] as? Data)?.count, KeychainKey.keyBytes)
        XCTAssertEqual(KeychainKey.keyBytes, 32)
    }

    // MARK: - the install-marker matrix (StorageGuard)

    func testStaleKeyWithoutTheMarkerIsWipedAndANewIdentityIsCreated() throws {
        // A reinstall: the container is gone (no marker, no state file), the
        // Keychain still holds the key of the previous installation.
        let stale = try key.create()
        let previous = try SnapshotCodec.seal(key: stale, value: Self.probeText)
        XCTAssertFalse(marker.isPresent)
        XCTAssertFalse(SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem))

        let continuity = try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key)

        XCTAssertEqual(continuity, .fresh)
        XCTAssertTrue(marker.isPresent, "the marker is recorded once the stale key is gone")
        XCTAssertFalse(try key.exists(), "the stale key must be deleted, not reused")
        XCTAssertTrue(marker.isFirstRunPending,
                      "and the new installation's first run is on record before its key exists")

        // A clean install: a new key, a new identity, a real commit and a real
        // reopen. The old box must no longer open — the key really is new.
        let fresh = try key.loadOrCreate(snapshotExists: false)
        XCTAssertThrowsError(try SnapshotCodec.open(key: fresh, value: previous)) { error in
            XCTAssertEqual(error as? SnapshotCodecError, .authenticationFailure)
        }

        let created = try CoreBridge.command(state: "", request: Self.createIdentity)
        let upgraded = try CoreBridge.command(state: try XCTUnwrap(created.state), request: Self.upgradeV2)
        XCTAssertEqual(upgraded.stateVersion, 3)
        let state = try XCTUnwrap(upgraded.state)

        let store = SnapshotStore(directory: directory, key: fresh, fileSystem: fileSystem, marker: marker)
        try store.commit(state)
        XCTAssertFalse(store.isBroken)
        XCTAssertTrue(store.snapshotExists())
        XCTAssertEqual(try store.load(), state)
        XCTAssertFalse(marker.isFirstRunPending, "the commit withdrew the container's word")

        // The next launch of this installation is an ordinary one.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .retained)
    }

    func testMarkerWithAKeyAndNoStateFileFreezesUnlessTheContainerVouchesForIt() throws {
        try marker.record()
        _ = try key.create()
        // A key without a file, and no word from the container that it has
        // committed nothing: a snapshot that has gone missing, a word that was
        // lost, or a build that never gave one — none is told apart, all
        // freeze. (`testAKeyFromAnInterruptedFirstRunIsNotAFreeze` below is
        // the other reading of the same two observations, and the word is the
        // only thing that separates them.)
        XCTAssertFalse(marker.isFirstRunPending)

        let continuity = try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key)

        XCTAssertEqual(continuity, .frozen)
        XCTAssertTrue(try key.exists(), "a freeze deletes nothing")
        XCTAssertThrowsError(try StorageGuard.requireContinuity(snapshotExists: false, keyExists: true)) { error in
            XCTAssertEqual(error as? StorageError, .frozen)
        }
    }

    /// A first run that showed Welcome and was closed without «Создать ID»:
    /// the launch created the Keychain item, nothing committed a state file,
    /// and the launch after it must open normally. The same two observations
    /// as the test above — a key, no file — and the container's own word,
    /// given before the key existed, is the only thing that tells them apart.
    func testAKeyFromAnInterruptedFirstRunIsNotAFreeze() throws {
        // Launch 1: an empty container and an empty account.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        let created = try key.loadOrCreate(snapshotExists: false)
        let sealed = try SnapshotCodec.seal(key: created, value: Self.probeText)

        // Launch 2: the key is still there, the state file never was, and the
        // container said so before the key existed.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        XCTAssertTrue(marker.isFirstRunPending)

        // It is the same key, so a first commit on this launch is readable by
        // the launch after it — the item is created once, never regenerated.
        let reused = try key.loadOrCreate(snapshotExists: false)
        XCTAssertEqual(try SnapshotCodec.open(key: reused, value: sealed), Self.probeText)

        // And once a state file exists, the ordinary rule is back: the
        // container remembers it, and the same pair without the file freezes.
        let store = SnapshotStore(directory: directory, key: reused, fileSystem: fileSystem, marker: marker)
        try store.commit(#"{"version":4,"note":"[TEST ONLY] first identity"}"#)
        XCTAssertFalse(marker.isFirstRunPending, "the commit withdraws it, not the next launch")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .retained)
        try fileSystem.removeItem(at: store.fileURL)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .frozen)
        XCTAssertTrue(try key.exists(), "and the key of the missing file is kept")
    }

    /// The installation that exists today, upgraded to the build that added
    /// the rule above: `paranoid.install.v1` in its defaults, a real Keychain
    /// item, a state file it committed under an earlier build — and no word
    /// about its first run, because no build before this one wrote one.
    ///
    /// The container on the contributor's iPhone is exactly that
    /// (`docs/project/current-state.md`). If the state file is missing by the
    /// first launch of the new build — the window an update installed in the
    /// background leaves open — the launch must freeze for the same reason a
    /// key without a file freezes anywhere, and the identity of that phone
    /// must not be replaced by a new one.
    func testAnInstallationFromAnEarlierBuildKeepsFreezingOverItsMissingFile() throws {
        // The upgraded container: the old marker and the old key, no word.
        defaults.set(true, forKey: InstallMarker.key)
        let retained = try key.create()
        let sealed = try SnapshotCodec.seal(key: retained, value: Self.probeText)
        XCTAssertFalse(marker.isFirstRunPending, "no build before this one wrote the container's word")

        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .frozen)
        XCTAssertTrue(try key.exists(), "the wrapping key of the missing file is kept")
        XCTAssertEqual(try SnapshotCodec.open(key: try XCTUnwrap(try key.load()), value: sealed),
                       Self.probeText,
                       "and it is still the key that opens what that installation sealed")

        // The same container on the ordinary upgrade — the file is where it
        // was — is the ordinary launch, and records nothing a later launch
        // could open on.
        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(sealed, to: directory.appendingPathComponent(SnapshotStore.fileName))
        XCTAssertEqual(try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key), .retained)
        XCTAssertFalse(marker.isFirstRunPending)
    }

    /// The owner reviewer's scenario on the real Keychain (pull request #36,
    /// the second review of 67af672): an identity committed on this
    /// installation, the commit's bookkeeping lost while the install markers
    /// survive, the state file lost before any launch — and the key still in
    /// the account. The launch must freeze, keep the key, and the key must
    /// still be the one that opens what this installation sealed.
    func testALostCommitRecordAndALostFileFreezeWithTheKeyKept() throws {
        XCTAssertEqual(try StorageGuard.start(snapshotExists: false, marker: marker, key: key), .fresh)
        let created = try key.loadOrCreate(snapshotExists: false)
        let sealed = try SnapshotCodec.seal(key: created, value: Self.probeText)
        let store = SnapshotStore(directory: directory, key: created, fileSystem: fileSystem, marker: marker)
        try store.commit(#"{"version":4,"note":"[TEST ONLY] committed identity"}"#)
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .retained)

        // Every fact but the install markers is lost. Under this rule there is
        // nothing else to lose — the assertion says so — and under the
        // previous one this removed `paranoid.snapshot.v1`.
        let installMarkers: Set<String> = [InstallMarker.key, "paranoid.install.v2"]
        let facts = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("paranoid.") })
        XCTAssertEqual(facts, [InstallMarker.key],
                       "after a commit the container holds nothing whose loss could open the client")
        for fact in facts.subtracting(installMarkers) {
            defaults.removeObject(forKey: fact)
        }
        try fileSystem.removeItem(at: store.fileURL)

        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .frozen)
        XCTAssertTrue(try key.exists(), "the key of the lost file is kept")
        XCTAssertFalse(marker.isFirstRunPending, "and the refusal records nothing")
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .frozen,
                       "reproducible on the next launch")
        XCTAssertEqual(try SnapshotCodec.open(key: try XCTUnwrap(try key.load()), value: sealed),
                       Self.probeText,
                       "and it is still the key that opens what this installation sealed")
    }

    /// The install marker lives in `UserDefaults` and the state file does not,
    /// so the two are lost by different accidents. A missing marker beside a
    /// state file is not a reinstall — a reinstall takes the container and the
    /// file with it — and deleting the key on that evidence would leave a
    /// snapshot nobody can ever decrypt again. A freeze is recoverable by a
    /// person; a deleted wrapping key is not.
    func testAMissingMarkerBesideAStateFileKeepsTheKeyAndTheFile() throws {
        let retained = try key.create()
        let sealed = try SnapshotCodec.seal(key: retained, value: Self.probeText)
        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(sealed, to: directory.appendingPathComponent(SnapshotStore.fileName))
        XCTAssertFalse(marker.isPresent)

        let continuity = try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key)

        XCTAssertEqual(continuity, .frozen)
        XCTAssertTrue(try key.exists(), "the key of a retained state file is never deleted")
        XCTAssertFalse(marker.isPresent, "and the refusal stays reproducible on the next launch")
        // The point of keeping it: the retained state is still openable, which
        // is exactly what a deleted key would have ended.
        let store = SnapshotStore(directory: directory,
                                  key: try XCTUnwrap(try key.load()),
                                  fileSystem: fileSystem,
                                  marker: marker)
        XCTAssertEqual(try store.load(), Self.probeText)
    }

    func testMarkerWithAStateFileAndNoKeyFreezes() throws {
        try marker.record()
        // A stale first-run fact beside the file, the kind a lost withdrawal
        // leaves: a freeze withdraws it no more than it deletes anything.
        try marker.recordPendingFirstRun()
        try fileSystem.createDirectory(at: directory)
        try fileSystem.write(Data(repeating: 0x01, count: 64),
                             to: directory.appendingPathComponent(SnapshotStore.fileName))
        XCTAssertFalse(try key.exists())

        let continuity = try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key)

        XCTAssertEqual(continuity, .frozen)
        XCTAssertFalse(try key.exists(), "a frozen launch must not regenerate the key")
        XCTAssertTrue(marker.isFirstRunPending,
                      "and withdraws nothing, so the refusal is the same on every later launch")
    }

    func testMarkerWithNeitherIsAFreshInstall() throws {
        // An iCloud restore onto a new iPhone: the defaults came back, so the
        // marker is there, but the `ThisDeviceOnly` key and the
        // excluded-from-backup state file did not.
        try marker.record()
        XCTAssertFalse(try key.exists())

        let continuity = try StorageGuard.start(
            snapshotExists: SnapshotStore.snapshotExists(in: directory, fileSystem: fileSystem),
            marker: marker,
            key: key)

        XCTAssertEqual(continuity, .fresh)
        XCTAssertTrue(marker.isFirstRunPending, "recorded before the key this launch goes on to create")
    }

    // MARK: - the real file system

    func testEveryCommitLeavesTheStateFileExcludedFromBackupAndProtected() throws {
        let store = SnapshotStore(directory: directory,
                                  key: try key.loadOrCreate(snapshotExists: false),
                                  fileSystem: fileSystem,
                                  marker: marker)

        try store.commit(#"{"version":4,"note":"[TEST ONLY] first"}"#)
        try store.commit(#"{"version":4,"note":"[TEST ONLY] second"}"#)

        // The second commit renamed a new inode over `text-state.enc`; the
        // flag has to have travelled with it.
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: store.fileURL))
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: store.directory))
        XCTAssertEqual(try store.load(), #"{"version":4,"note":"[TEST ONLY] second"}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryFileURL.path))

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let protection = fileAttributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // The simulator has no Data Protection: it stores the file happily and
        // reports no class at all. What this run does prove is that asking for
        // `completeUntilFirstUserAuthentication` is not itself an error. The
        // class on disk can only be observed on a device, and that run is a
        // live action that waits for the owner's "go".
        XCTAssertTrue(protection == nil || protection == .completeUntilFirstUserAuthentication,
                      "unexpected protection class \(String(describing: protection))")
        #else
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        #endif
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    /// The raw bytes under the account, so a pre-existing installation can be
    /// put back exactly as it was.
    private static func rawKey() -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Writes borrowed bytes back under the account with the class the client
    /// uses, so the installation that owned them opens its state again.
    private static func restore(_ data: Data) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainKey.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }

}
