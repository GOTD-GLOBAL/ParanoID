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
    private var defaults = UserDefaults.standard
    private var marker = InstallMarker()
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let fileSystem = DataProtectionFileSystem()
    /// The key that was in the account before this run, if any.
    private var borrowed: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        borrowed = Self.rawKey()
        try key.deleteRetained()
        suiteName = "global.paranoid.messenger.tests.storage.\(UUID().uuidString)"
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
        defaults.removePersistentDomain(forName: suiteName)
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

        let store = SnapshotStore(directory: directory, key: fresh, fileSystem: fileSystem)
        try store.commit(state)
        XCTAssertFalse(store.isBroken)
        XCTAssertTrue(store.snapshotExists())
        XCTAssertEqual(try store.load(), state)

        // The next launch of this installation is an ordinary one.
        XCTAssertEqual(try StorageGuard.start(snapshotExists: store.snapshotExists(),
                                              marker: marker,
                                              key: key), .retained)
    }

    func testMarkerWithAKeyAndNoStateFileFreezes() throws {
        try marker.record()
        _ = try key.create()

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

    func testMarkerWithAStateFileAndNoKeyFreezes() throws {
        try marker.record()
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
    }

    // MARK: - the real file system

    func testEveryCommitLeavesTheStateFileExcludedFromBackupAndProtected() throws {
        let store = SnapshotStore(directory: directory,
                                  key: try key.loadOrCreate(snapshotExists: false),
                                  fileSystem: fileSystem)

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
