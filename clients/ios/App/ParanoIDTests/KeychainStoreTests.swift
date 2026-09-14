import CryptoKit
import Foundation
import ParanoidKit
import Security
import XCTest

/// Real Keychain and filesystem integration, on a signed simulator/device.
/// Every case owns a unique TEST account. Never borrow/delete the application's
/// standard item: an interrupted runner must not destroy an installed identity.
final class KeychainStoreTests: XCTestCase {
    private var key: KeychainKey!
    private var defaults: UserDefaults!
    private var marker: InstallMarker!
    private var directory: URL!
    private var suiteName = ""
    private let fileSystem = DataProtectionFileSystem()
    private static let probeText = "[TEST ONLY] storage continuity"

    override func setUpWithError() throws {
        try super.setUpWithError()
        key = KeychainKey(account: "paranoid-test-lazy-\(UUID().uuidString)")
        suiteName = "global.paranoid.messenger.tests.lazy-storage"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        marker = InstallMarker(defaults: defaults)
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("paranoid-storage-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("paranoid", isDirectory: true)
    }

    override func tearDownWithError() throws {
        defer { defaults?.removePersistentDomain(forName: suiteName) }
        defer { if let directory { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) } }
        if let key { try key.deleteRetained() }
        try super.tearDownWithError()
    }

    private func startup() throws -> StorageGuard.Continuity {
        try StorageGuard.start(snapshotExists: SnapshotStore.snapshotExists(in: directory),
                               marker: marker, key: key!)
    }
    private func store() -> SnapshotStore {
        SnapshotStore(directory: directory, keyStore: key!, fileSystem: fileSystem)
    }
    private func seedLegacyPending() {
        defaults.set(true, forKey: "paranoid.firstrun.pending.v1")
        defaults.set(true, forKey: "paranoid.install.v2")
        defaults.set(true, forKey: "paranoid.snapshot.v1")
    }

    func testTheKeyIsCreatedOnceAndNeverRegenerated() throws {
        XCTAssertEqual(KeychainKey.account, "paranoid-text-state-v0")
        XCTAssertNotEqual(key.account, KeychainKey.account)
        XCTAssertFalse(try key.exists())
        let created = try key.create()
        let sealed = try SnapshotCodec.seal(key: created, value: Self.probeText)
        let loaded = try XCTUnwrap(key.load())
        XCTAssertEqual(try SnapshotCodec.open(key: loaded, value: sealed), Self.probeText)
        XCTAssertThrowsError(try key.create()) { error in
            XCTAssertEqual(error as? StorageError, .keychain(errSecDuplicateItem))
        }
    }

    func testAMissingKeyIsNeverRegeneratedOverAnExistingStateFile() throws {
        XCTAssertEqual(try startup(), .fresh)
        let prior = store()
        try prior.commit(Self.probeText)
        let before = try fileSystem.read(at: prior.fileURL, maximumBytes: SnapshotStore.maximumStoredBytes)
        try key.deleteRetained() // isolated test account only
        let direct = store()
        XCTAssertThrowsError(try direct.commit(Self.probeText)) { error in
            XCTAssertEqual(error as? StorageError, .broken)
        }
        XCTAssertEqual(direct.brokenCause as? StorageError, .frozen)
        XCTAssertFalse(try key.exists())
        XCTAssertEqual(try fileSystem.read(at: prior.fileURL, maximumBytes: SnapshotStore.maximumStoredBytes), before)
    }

    func testTheItemIsAfterFirstUnlockThisDeviceOnlyAndNotSynchronizable() throws {
        _ = try key.create()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.account,
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
    }

    func testWelcomeRelaunchDoesNotCreateKeyAndFirstCommitDoes() throws {
        for _ in 0..<2 {
            XCTAssertEqual(try startup(), .fresh)
            XCTAssertNil(try store().load())
            XCTAssertFalse(try key.exists())
        }
        let first = store()
        try first.commit(Self.probeText)
        XCTAssertTrue(try key.exists())
        XCTAssertEqual(try startup(), .retained)
        XCTAssertEqual(try store().load(), Self.probeText)
    }

    func testStaleKeyWithoutTheMarkerIsWipedAndReplacedOnlyAtCommit() throws {
        let old = try key.create()
        let oldSealed = try SnapshotCodec.seal(key: old, value: Self.probeText)
        XCTAssertEqual(try startup(), .fresh)
        XCTAssertFalse(try key.exists())
        XCTAssertNil(try store().load())
        let created = try CoreBridge.command(state: "", request:
            #"{"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#)
        let upgraded = try CoreBridge.command(state: XCTUnwrap(created.state),
                                             request: #"{"op":"upgrade_v2"}"#)
        XCTAssertEqual(upgraded.stateVersion, 3)
        let state = try XCTUnwrap(upgraded.state)
        let current = store()
        try current.commit(state)
        let fresh = try XCTUnwrap(key.load())
        XCTAssertThrowsError(try SnapshotCodec.open(key: fresh, value: oldSealed))
        XCTAssertEqual(try store().load(), state)
    }

    func testAMissingMarkerBesideAStateFileKeepsTheKeyAndTheFile() throws {
        XCTAssertEqual(try startup(), .fresh)
        let current = store()
        try current.commit(Self.probeText)
        defaults.removeObject(forKey: InstallMarker.key)
        XCTAssertEqual(try startup(), .frozen)
        XCTAssertFalse(marker.isPresent)
        let retained = try XCTUnwrap(key.load())
        let bytes = try fileSystem.read(at: current.fileURL, maximumBytes: SnapshotStore.maximumStoredBytes)
        XCTAssertEqual(try SnapshotCodec.open(key: retained, value: bytes), Self.probeText)
        XCTAssertEqual(try startup(), .frozen)
    }

    func testStalePendingFactAndLostFileFreezeWithRealKeyKept() throws {
        XCTAssertEqual(try startup(), .fresh)
        let current = store()
        try current.commit(Self.probeText)
        seedLegacyPending()
        try fileSystem.removeItem(at: current.fileURL)
        XCTAssertEqual(try startup(), .frozen)
        XCTAssertTrue(try key.exists())
        XCTAssertThrowsError(try store().load())
        XCTAssertEqual(try startup(), .frozen)
    }

    func testAnInstallationFromAnEarlierBuildKeepsFreezingOverItsMissingFile() throws {
        try marker.record()
        _ = try key.create() // legacy eager-key/partial-commit fixture
        for pending in [false, true] {
            if pending { seedLegacyPending() }
            XCTAssertEqual(try startup(), .frozen)
            XCTAssertTrue(try key.exists())
        }
    }

    func testAFileWithoutItsKeyFreezesWithoutRegeneration() throws {
        XCTAssertEqual(try startup(), .fresh)
        let current = store()
        try current.commit(Self.probeText)
        try key.deleteRetained() // only this case's isolated synthetic account
        XCTAssertEqual(try startup(), .frozen)
        XCTAssertThrowsError(try store().load())
        XCTAssertFalse(try key.exists())
        XCTAssertTrue(current.snapshotExists())
    }

    func testRestoredDefaultsWithNeitherHalfDoNotCreateAKey() throws {
        try marker.record()
        seedLegacyPending()
        XCTAssertEqual(try startup(), .fresh)
        XCTAssertNil(try store().load())
        XCTAssertFalse(try key.exists())
    }

    func testEveryCommitLeavesTheStateFileExcludedFromBackupAndProtected() throws {
        XCTAssertEqual(try startup(), .fresh)
        let current = store()
        try current.commit(Self.probeText)
        try current.commit(Self.probeText + " second")
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: current.fileURL))
        XCTAssertTrue(try fileSystem.isExcludedFromBackup(at: directory))
        XCTAssertEqual(try store().load(), Self.probeText + " second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.temporaryFileURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: current.fileURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        XCTAssertTrue(protection == nil || protection == .completeUntilFirstUserAuthentication)
        #else
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        #endif
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }
}
