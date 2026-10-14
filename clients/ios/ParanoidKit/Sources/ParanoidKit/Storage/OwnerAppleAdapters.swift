import CryptoKit
import Foundation

/// `OwnerFileIO` over the real Apple file system. Proposed, non-adopted
/// (RFC-0030 / draft ADR-0017). Stub: every operation refuses until the
/// native behaviour exists.
struct OwnerAppleFileIO: OwnerFileIO {
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    private func unimplemented(_ operation: CatalogueAppleAdapterError.Operation, _ url: URL?) -> CatalogueAppleAdapterError {
        CatalogueAppleAdapterError(operation, url, code: Int(ENOSYS), reason: "not implemented")
    }
    func inspect(_ url: URL) throws -> CataloguePathKind { throw unimplemented(.inspect, url) }
    func writeExclusive(_ bytes: Data, to url: URL) throws { throw unimplemented(.create, url) }
    func protectAndExclude(_ url: URL) throws { throw unimplemented(.protect, url) }
    func fullSync(_ url: URL, directory: Bool) throws { throw unimplemented(.sync, url) }
    func rename(_ source: URL, to destination: URL) throws { throw unimplemented(.rename, destination) }
    func read(_ url: URL, maximumBytes: Int) throws -> Data { throw unimplemented(.read, url) }
    func removeIntent(_ url: URL) throws { throw unimplemented(.remove, url) }
    func createOwnerDirectory(_ url: URL) throws { throw unimplemented(.create, url) }
    func protectOwnerAndExclude(_ url: URL, policy: OwnerProtection) throws { throw unimplemented(.protect, url) }
}

/// `OwnerCryptography` over the shipped version-1 AES-GCM framing and an
/// explicit opaque owner key namespace. Stub: refuses until implemented.
struct OwnerAppleCryptography: OwnerCryptography {
    typealias Key = SymmetricKey
    private let owner: any WrappingKeyStore

    init(owner: any WrappingKeyStore) {
        self.owner = owner
    }

    private func unimplemented(_ operation: CatalogueAppleAdapterError.Operation) -> CatalogueAppleAdapterError {
        CatalogueAppleAdapterError(operation, nil, code: Int(ENOSYS), reason: "not implemented")
    }
    var framingOverhead: Int { SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    func loadKey() throws -> SymmetricKey? { throw unimplemented(.open) }
    func createKey() throws -> SymmetricKey { throw unimplemented(.seal) }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { throw unimplemented(.open) }
    func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data { throw unimplemented(.seal) }
    func open(_ sealed: Data, with key: SymmetricKey) throws -> Data { throw unimplemented(.open) }
}
