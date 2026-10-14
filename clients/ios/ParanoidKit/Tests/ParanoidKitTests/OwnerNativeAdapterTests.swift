// Native-first acceptance of the Apple owner-store adapters (RFC-0030 / draft
// ADR-0017; REQ-ID-002/003/004/006 prerequisites). Real temporary roots, real
// CryptoKit, injected in-memory SymmetricKey backends; never the application
// container or a live Keychain account. Activated on the Mac implementation
// branch from the checkpoint staged in PR #84 (2ed901dd). Existing
// CatalogueAppleFileIO / KeychainKey are NOT owner adapters: they hardcode
// messaging protection; the owner adapters below select the owner policy. See
// docs/clients/ios/owner-store-format.md §5 and the owner-store receipts.
import CryptoKit
import Foundation
import XCTest
@testable import ParanoidKit

@MainActor final class OwnerNativeAdapterTests: XCTestCase {
    /// Whole portable path on the real file system and real CryptoKit:
    /// retained bootstrap → reservation → new owner commit → reopen on a new
    /// coordinator with directory/key/file present and both realms unallocated.
    func testRealReservationOwnerCommitAndReopenWithOwnerArtifactsPresent() throws {
        let f = try NativeOwnerFixture()
        defer { f.cleanup() }
        let files = OwnerAppleFileIO(fileSystem: f.disk)
        let catalogueCrypto = CatalogueAppleCryptography(catalogue: f.catalogueKey, owner: f.ownerKey, fi: f.fi, ru: f.ru)
        let ownerCrypto = OwnerAppleCryptography(owner: f.ownerKey)   // typed owner policy, see below
        // Retained bootstrap written by the unchanged old store (same bytes the old reader accepts).
        let lease = OwnerNamespaceLease(root: f.root)
        let bootstrapHolder = try lease.acquire()
        let old = CatalogueStore(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: bootstrapHolder),
            crypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: bootstrapHolder))
        try old.inspectFresh(); try old.commit(f.context)
        lease.retire(bootstrapHolder) // old handles can never touch the namespace again
        XCTAssertThrowsError(try old.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
        let holder = try lease.acquire()
        let c = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: holder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder),
            ownerCrypto: LeasedCryptography(ownerCrypto, lease: lease, holder: holder), entropy: { Data(repeating: 0, count: 16) }) // public fixture entropy, never SecRandomCopyBytes here
        XCTAssertFalse(try c.loadRetained().catalogue.allocated)
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let value = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op)
        XCTAssertEqual(value.owner, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk") // public 16-byte vector, bridge/tests/devnet.rs
        let ownerFile = f.root.appendingPathComponent("owner/state.enc")
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: ownerFile))
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: f.root.appendingPathComponent("owner")))
        #if os(iOS)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: ownerFile.path)[.protectionKey] as? FileProtectionType, .complete)
        #endif
        var st = stat(); XCTAssertEqual(lstat(f.root.appendingPathComponent("owner").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("owner/write.pending")))
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("owner/state.enc.tmp")))
        XCTAssertEqual(f.ownerKey.creations, 1); XCTAssertEqual(f.catalogueKey.creations, 1)
        XCTAssertNotEqual(try XCTUnwrap(f.ownerKey.load()), try XCTUnwrap(f.catalogueKey.load()), "distinct opaque owner key")
        c.close()
        let reopenedHolder = try lease.acquire()
        let reopened = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: reopenedHolder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: reopenedHolder),
            ownerCrypto: LeasedCryptography(ownerCrypto, lease: lease, holder: reopenedHolder), entropy: { XCTFail("no entropy on reopen"); return Data() })
        let pair = try reopened.loadRetained()
        XCTAssertTrue(pair.catalogue.allocated); XCTAssertEqual(pair.owner, value)
        reopened.close()
        let legacyHolder = try lease.acquire()
        let legacy = CatalogueStore(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: legacyHolder),
            crypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: legacyHolder))
        XCTAssertThrowsError(try legacy.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .artifactsPresent) }
        lease.retire(legacyHolder)
        XCTAssertEqual(f.ownerKey.deletions, 0)
    }

    /// Real-policy evidence needs a Keychain, which an unsigned host test binary
    /// does not have: `SecItemAdd` fails with `errSecMissingEntitlement` before
    /// any policy is reached. The executable case is
    /// `KeychainStoreTests.testTheOwnerItemIsWhenUnlockedThisDeviceOnlyAndNotSynchronizable`
    /// in the application test bundle, run ad-hoc signed on the simulator the way
    /// `build.sh` runs the other Keychain cases; it inserts an `OwnerKeychainKey`
    /// item under a fresh test account and reads the accessibility and
    /// synchronizable attributes back. This host case records the skip, never
    /// a pass on memory-key constants.
    func testOwnerKeyPolicyIsWhenUnlockedThisDeviceOnlyAndNotSynchronizable() throws {
        throw XCTSkip("real owner Keychain insertion/readback runs ad-hoc signed on the simulator (KeychainStoreTests.testTheOwnerItemIsWhenUnlockedThisDeviceOnlyAndNotSynchronizable); the unsigned host has no Keychain, and memory-key policy descriptors are not evidence")
    }

    /// Create-only, no-follow owner directory: an existing inode (link or
    /// directory) is refused and left untouched; nothing is cleaned up.
    func testOwnerDirectoryCreationIsCreateOnlyNoFollowAndNeverCleansUp() throws {
        let f = try NativeOwnerFixture()
        defer { f.cleanup() }
        let files = OwnerAppleFileIO(fileSystem: f.disk)
        let owner = f.root.appendingPathComponent("owner")
        let target = f.root.appendingPathComponent("elsewhere")
        try f.disk.createDirectory(at: target)
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: target)
        XCTAssertThrowsError(try files.createOwnerDirectory(owner))
        XCTAssertEqual(try files.inspect(owner), .other, "link kept, never followed or replaced")
        XCTAssertThrowsError(try files.protectOwnerAndExclude(owner, policy: .ownerComplete), "no-follow protection")
        try FileManager.default.removeItem(at: owner) // fixture teardown only
        try files.createOwnerDirectory(owner)
        XCTAssertThrowsError(try files.createOwnerDirectory(owner), "second creation refused (EEXIST)")
        try files.protectOwnerAndExclude(owner, policy: .ownerComplete)
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: owner))
    }

    /// Only unregistered + backup-confirmed state and tampered-tag refusal.
    /// ownerSigned, assembled/sends, publication-pending/published and foreign-key
    /// boxes still need separate native cases; this blueprint does not cover them.
    func testUnregisteredBackupReopenWithRealBoxAndTamperedTagRefusal() throws {
        let f = try NativeOwnerFixture()
        defer { f.cleanup() }
        let files = OwnerAppleFileIO(fileSystem: f.disk)
        let catalogueCrypto = CatalogueAppleCryptography(catalogue: f.catalogueKey, owner: f.ownerKey, fi: f.fi, ru: f.ru)
        let ownerCrypto = OwnerAppleCryptography(owner: f.ownerKey)
        let lease = OwnerNamespaceLease(root: f.root)
        let bootstrapHolder = try lease.acquire()
        let old = CatalogueStore(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: bootstrapHolder),
            crypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: bootstrapHolder))
        try old.inspectFresh(); try old.commit(f.context)
        lease.retire(bootstrapHolder) // old handles can never touch the namespace again
        XCTAssertThrowsError(try old.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
        let holder = try lease.acquire()
        var calls: [String] = []
        let core = OwnerMaterialCore(observed: { calls.append($0) })
        let c = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: holder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder),
            ownerCrypto: LeasedCryptography(ownerCrypto, lease: lease, holder: holder), entropy: { Data(repeating: 0, count: 16) }, core: core)
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op); try c.finish(op)
        let ownerFile = f.root.appendingPathComponent("owner/state.enc")
        let sealed = try f.disk.read(at: ownerFile, maximumBytes: f.cap)
        calls = []
        c.close()
        let reopenedHolder = try lease.acquire()
        let reopened = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: reopenedHolder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: reopenedHolder),
            ownerCrypto: LeasedCryptography(ownerCrypto, lease: lease, holder: reopenedHolder), entropy: { Data() }, core: core)
        XCTAssertEqual(try reopened.loadRetained().owner?.wordsBackupConfirmed, true)
        XCTAssertEqual(Set(calls), ["identity"])
        reopened.close() // retire the reader before test-only fixture corruption
        var tampered = sealed; tampered[tampered.count - 1] ^= 0x01
        try FileManager.default.removeItem(at: ownerFile) // synthetic fixture only, never store behavior
        try f.disk.write(tampered, to: ownerFile)
        let tamperedHolder = try lease.acquire()
        let again = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(files, lease: lease, holder: tamperedHolder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: tamperedHolder),
            ownerCrypto: LeasedCryptography(ownerCrypto, lease: lease, holder: tamperedHolder), entropy: { Data() }, core: core)
        XCTAssertThrowsError(try again.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .authenticationFailed) }
        XCTAssertEqual(try f.disk.read(at: ownerFile, maximumBytes: f.cap), tampered, "no repair")
        XCTAssertEqual(f.ownerKey.deletions, 0); XCTAssertEqual(f.ownerKey.creations, 1)
    }
}

private final class NativeOwnerFixture {
    let disk = DataProtectionFileSystem()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("owner-native-synthetic-" + UUID().uuidString, isDirectory: true)
    let catalogueKey = NativeOwnerMemoryKey(byte: 0x31)
    let ownerKey = NativeOwnerMemoryKey(byte: 0x42)
    let fi = NativeOwnerMemoryKey(byte: 0x53)
    let ru = NativeOwnerMemoryKey(byte: 0x64)
    let context: IdentityCatalogue
    var cap: Int { 65_536 + SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    init() throws {
        context = try IdentityCatalogue(installID: "11111111-1111-4111-8111-111111111111",
            ownerRef: "22222222-2222-4222-8222-222222222222",
            realms: .init(fi: .init(origin: "https://fi.example.invalid:38444", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3"),
                          ru: .init(origin: "https://ru.example.invalid:38444", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")))
        try disk.createDirectory(at: root)
        try disk.excludeFromBackup(at: root)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// In-memory opaque key double: real `SymmetricKey` values for real CryptoKit
/// boxes, but NOT a Keychain and NOT the owner accessibility policy.
private final class NativeOwnerMemoryKey: OwnerKeyBackend {
    /// FIXTURE-ONLY descriptor: a memory key cannot enforce a Keychain policy;
    /// it only reports the canonical one so the adapter admits it on the host.
    func storedPolicy() throws -> OwnerKeyPolicy? { try load() == nil ? nil : .whenUnlockedThisDeviceOnly }
    private let byte: UInt8
    private var value: SymmetricKey?
    private(set) var creations = 0
    private(set) var deletions = 0
    init(byte: UInt8) { self.byte = byte }
    func exists() throws -> Bool { value != nil }
    func load() throws -> SymmetricKey? { value }
    func create() throws -> SymmetricKey {
        guard value == nil else { throw OwnerStoreError.continuity }
        let key = SymmetricKey(data: Data(repeating: byte, count: 32)); value = key; creations += 1; return key
    }
    func deleteRetained() throws { deletions += 1; XCTFail("owner store must never delete retained keys"); throw OwnerStoreError.backendFailure }
}
