import CryptoKit
import Foundation

/// Why one Apple catalogue adapter operation failed. Names the operation and
/// the POSIX/Foundation code only: never a path beyond its last component,
/// never file contents or key material.
public struct CatalogueAppleAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Operation: String, Equatable, Sendable {
        case inspect, create, write, protect, sync, rename, read, remove, seal, open, key
    }
    public let operation: Operation
    public let name: String
    public let code: Int
    public let reason: String

    public init(_ operation: Operation, _ url: URL?, code: Int, reason: String) {
        self.operation = operation
        self.name = url?.lastPathComponent ?? "-"
        self.code = code
        self.reason = reason
    }

    public var description: String {
        "catalogue \(operation.rawValue) of \(name) failed: \(reason) (\(code))"
    }
}

/// `CatalogueFileIO` over the real Apple file system. Proposed, non-adopted.
public struct CatalogueAppleFileIO: CatalogueFileIO {
    private let fileSystem: any FileSystem

    /// `fileSystem` supplies the already shipped Data Protection, backup
    /// exclusion, `F_FULLFSYNC` and `rename(2)` steps. No default argument:
    /// the caller names the backend, as it names the directory.
    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public func inspect(_ url: URL) throws -> CataloguePathKind {
        throw CatalogueAppleAdapterError(.inspect, url, code: Int(ENOSYS), reason: "not implemented")
    }
    public func writeExclusive(_ bytes: Data, to url: URL) throws {
        throw CatalogueAppleAdapterError(.create, url, code: Int(ENOSYS), reason: "not implemented")
    }
    public func protectAndExclude(_ url: URL) throws {
        throw CatalogueAppleAdapterError(.protect, url, code: Int(ENOSYS), reason: "not implemented")
    }
    public func fullSync(_ url: URL, directory: Bool) throws {
        throw CatalogueAppleAdapterError(.sync, url, code: Int(ENOSYS), reason: "not implemented")
    }
    public func rename(_ source: URL, to destination: URL) throws {
        throw CatalogueAppleAdapterError(.rename, destination, code: Int(ENOSYS), reason: "not implemented")
    }
    public func read(_ url: URL, maximumBytes: Int) throws -> Data {
        throw CatalogueAppleAdapterError(.read, url, code: Int(ENOSYS), reason: "not implemented")
    }
    public func removeIntent(_ url: URL) throws {
        throw CatalogueAppleAdapterError(.remove, url, code: Int(ENOSYS), reason: "not implemented")
    }
}

/// `CatalogueCryptography` over the shipped version-1 AES-GCM framing and the
/// existing opaque Keychain seams. Proposed, non-adopted.
public struct CatalogueAppleCryptography: CatalogueCryptography {
    public typealias Key = SymmetricKey

    private let catalogue: any WrappingKeyStore
    private let owner: any RetainedKey
    private let fi: any RetainedKey
    private let ru: any RetainedKey

    /// Explicit key namespaces only; no default account and no key export.
    public init(catalogue: any WrappingKeyStore, owner: any RetainedKey,
                fi: any RetainedKey, ru: any RetainedKey) {
        self.catalogue = catalogue
        self.owner = owner
        self.fi = fi
        self.ru = ru
    }

    /// Version byte, nonce and tag of the shipped framing; not a new format.
    public var framingOverhead: Int { SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }

    public func loadKey() throws -> SymmetricKey? {
        throw CatalogueAppleAdapterError(.key, nil, code: Int(ENOSYS), reason: "not implemented")
    }
    public func createKey() throws -> SymmetricKey {
        throw CatalogueAppleAdapterError(.key, nil, code: Int(ENOSYS), reason: "not implemented")
    }
    public func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool {
        throw CatalogueAppleAdapterError(.key, nil, code: Int(ENOSYS), reason: "not implemented")
    }
    public func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        throw CatalogueAppleAdapterError(.seal, nil, code: Int(ENOSYS), reason: "not implemented")
    }
    public func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        throw CatalogueAppleAdapterError(.open, nil, code: Int(ENOSYS), reason: "not implemented")
    }
}
