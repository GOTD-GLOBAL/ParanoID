// Native-first acceptance of the Apple catalogue adapters (RFC-0030 / draft
// ADR-0017; MR-02/06/07/14 prerequisites). Real temporary directory, real
// AES-GCM, injected in-memory SymmetricKey backends; never the application
// container or a live Keychain account. Activated on the Mac implementation
// branch from the checkpoint staged in PR #82 (a19a980).
import CryptoKit
import Foundation
import XCTest
@testable import ParanoidKit

final class CatalogueNativeAdapterTests: XCTestCase {
    func testRealCommitReopenBackupFlagAndOldReaderRefusal() throws {
        let f = try NativeCatalogueFixture()
        defer { f.cleanup() }
        let files = CatalogueAppleFileIO(fileSystem: f.disk)
        let crypto = CatalogueAppleCryptography(catalogue: f.keys, owner: f.owner, fi: f.fi, ru: f.ru)
        let store = CatalogueStore(directory: f.root, context: f.context, files: files, crypto: crypto)
        try store.inspectFresh()
        XCTAssertNil(try f.keys.load())
        try store.commit(f.context)
        let sealed = try f.disk.read(at: f.file, maximumBytes: f.cap)
        XCTAssertNotEqual(sealed, IdentityCatalogueCodec.encode(f.context))
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: f.file))
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("catalogue.write.pending")))
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("text-state.enc.tmp")))
        let key = try XCTUnwrap(f.keys.load())
        let decoded = try SnapshotCodec.open(key: key, value: sealed)
        XCTAssertEqual(Data(decoded.utf8), IdentityCatalogueCodec.encode(f.context))
        XCTAssertThrowsError(try Snapshot.open(decoded)) {
            XCTAssertEqual($0 as? SelfServiceError, .unsupportedSnapshot)
        }
        let reopened = CatalogueStore(directory: f.root, context: f.context, files: files, crypto: crypto)
        XCTAssertEqual(try reopened.loadRetained(), f.context)
        try reopened.commit(f.context)
        XCTAssertEqual(try f.keys.load(), key)
        XCTAssertEqual(f.keys.creations, 1)
        XCTAssertEqual(f.keys.deletions, 0)
    }

    func testAuthenticatedInvalidUTF8RemainsRawInsteadOfLegacyRepair() throws {
        let f = try NativeCatalogueFixture()
        defer { f.cleanup() }
        let key = try f.keys.create()
        let raw = Data([0xff])
        // Fixture uses the existing primitive/layout, not a fake CryptoKit module.
        let box = try AES.GCM.seal(raw, using: key, nonce: AES.GCM.Nonce(),
                                   authenticating: Data([SnapshotCodec.version]))
        var framed = Data([SnapshotCodec.version])
        framed.append(contentsOf: box.nonce)
        framed.append(box.ciphertext)
        framed.append(box.tag)
        let crypto = CatalogueAppleCryptography(catalogue: f.keys, owner: f.owner, fi: f.fi, ru: f.ru)
        XCTAssertEqual(try crypto.open(framed, with: key), raw)
        XCTAssertEqual(try SnapshotCodec.open(key: key, value: framed), "\u{fffd}")
        try f.disk.write(framed, to: f.file) // synthetic fixture only
        let store = CatalogueStore(directory: f.root, context: f.context,
                                   files: CatalogueAppleFileIO(fileSystem: f.disk), crypto: crypto)
        XCTAssertThrowsError(try store.loadRetained()) {
            XCTAssertEqual($0 as? CatalogueStoreError, .invalidCatalogue)
        }
        XCTAssertEqual(try f.disk.read(at: f.file, maximumBytes: f.cap), framed)
        XCTAssertEqual(f.keys.deletions, 0)
    }

    func testNativeV4BytesAreNeverMigratedOrOverwritten() throws {
        let f = try NativeCatalogueFixture()
        defer { f.cleanup() }
        let key = try f.keys.create()
        let v4 = #"{"version":4,"realm":"https://fi.example.invalid:38444","tls_pin":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"","state":{"version":3}}"#
        XCTAssertNoThrow(try Snapshot.open(v4))
        let sealed = try SnapshotCodec.seal(key: key, value: v4)
        try f.disk.write(sealed, to: f.file)
        let crypto = CatalogueAppleCryptography(catalogue: f.keys, owner: f.owner, fi: f.fi, ru: f.ru)
        let store = CatalogueStore(directory: f.root, context: f.context,
                                   files: CatalogueAppleFileIO(fileSystem: f.disk), crypto: crypto)
        XCTAssertThrowsError(try store.loadRetained())
        XCTAssertThrowsError(try store.commit(f.context))
        XCTAssertEqual(try f.disk.read(at: f.file, maximumBytes: f.cap), sealed)
        XCTAssertEqual(try f.keys.load(), key)
        XCTAssertEqual(f.keys.deletions, 0)
    }

    func testNativeInspectionExclusiveWriteAndBoundedRead() throws {
        let f = try NativeCatalogueFixture()
        defer { f.cleanup() }
        let files = CatalogueAppleFileIO(fileSystem: f.disk)
        XCTAssertEqual(try files.inspect(f.file), .absent)
        try files.writeExclusive(Data([1, 2, 3]), to: f.file)
        XCTAssertThrowsError(try files.writeExclusive(Data([9]), to: f.file))
        XCTAssertEqual(try files.read(f.file, maximumBytes: 3), Data([1, 2, 3]))
        XCTAssertThrowsError(try files.read(f.file, maximumBytes: 2))
        let link = f.root.appendingPathComponent("synthetic-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        XCTAssertEqual(try files.inspect(link), .other)
        XCTAssertThrowsError(try files.read(link, maximumBytes: 3))
        let childOfFile = f.file.appendingPathComponent("child")
        XCTAssertThrowsError(try files.inspect(childOfFile), "ENOTDIR is not ENOENT")
        let oversized = f.root.appendingPathComponent("oversized")
        try f.disk.write(Data(repeating: 0, count: f.cap + 1), to: oversized)
        XCTAssertThrowsError(try files.read(oversized, maximumBytes: f.cap))
    }
}

private final class NativeCatalogueFixture {
    let disk = DataProtectionFileSystem()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalogue-native-synthetic-" + UUID().uuidString, isDirectory: true)
    let keys = NativeCatalogueMemoryKey(byte: 0x31)
    let owner = NativeCatalogueMemoryKey(byte: 0x42)
    let fi = NativeCatalogueMemoryKey(byte: 0x53)
    let ru = NativeCatalogueMemoryKey(byte: 0x64)
    let context: IdentityCatalogue
    var file: URL { root.appendingPathComponent("text-state.enc") }
    var cap: Int { 65_536 + SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    init() throws {
        context = try IdentityCatalogue(installID: "11111111-1111-4111-8111-111111111111",
            ownerRef: "22222222-2222-4222-8222-222222222222",
            realms: .init(fi: .init(origin: "https://fi.example.invalid:38444", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3"),
                          ru: .init(origin: "https://ru.example.invalid:38444", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")))
        try disk.createDirectory(at: root)
        try disk.excludeFromBackup(at: root)
    }
    // Fixture teardown is not store recovery. The root belongs only to this test.
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class NativeCatalogueMemoryKey: WrappingKeyStore {
    private let byte: UInt8
    private var value: SymmetricKey?
    private(set) var creations = 0
    private(set) var deletions = 0
    init(byte: UInt8) { self.byte = byte }
    func exists() throws -> Bool { value != nil }
    func load() throws -> SymmetricKey? { value }
    func create() throws -> SymmetricKey {
        guard value == nil else { throw CatalogueStoreError.continuity }
        let key = SymmetricKey(data: Data(repeating: byte, count: 32))
        value = key
        creations += 1
        return key
    }
    func deleteRetained() throws {
        deletions += 1
        XCTFail("Catalogue must never delete retained keys")
        throw CatalogueStoreError.backendFailure
    }
}
