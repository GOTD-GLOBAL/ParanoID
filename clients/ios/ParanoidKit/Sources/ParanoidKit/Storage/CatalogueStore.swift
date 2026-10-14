import Foundation

public enum CataloguePathKind: Equatable, Sendable { case absent, regularFile, directory, other }
public enum CatalogueForeignStore: String, CaseIterable, Sendable { case owner, fi, ru }

/// Narrow transaction seam: throwing inspection, bounded reads, no cleanup API.
public protocol CatalogueFileIO {
    /// Must not follow symbolic links. Only genuine ENOENT is absent;
    /// permission/protection errors and ENOTDIR must throw.
    func inspect(_ url: URL) throws -> CataloguePathKind
    /// Create-only, never truncate/replace an existing path; errors may leave
    /// partial bytes and MUST NOT remove the inode as compensating cleanup.
    func writeExclusive(_ bytes: Data, to url: URL) throws
    func protectAndExclude(_ url: URL) throws
    func fullSync(_ url: URL, directory: Bool) throws
    func rename(_ source: URL, to destination: URL) throws
    /// Bound allocation/reading by maximumBytes before decoding, including a
    /// growing-file race. Native implementation must reject nonregular inodes.
    func read(_ url: URL, maximumBytes: Int) throws -> Data
    func removeIntent(_ url: URL) throws
}

/// Keys stay opaque to the transaction. No byte export or deletion operation.
public protocol CatalogueCryptography {
    associatedtype Key: Equatable
    /// Trusted fixed framing overhead; native adapter derives it from
    /// SnapshotCodec.headerBytes + SnapshotCodec.tagBytes (not a new format).
    var framingOverhead: Int { get }
    func loadKey() throws -> Key?
    /// Create-only persistent key; never replace a retained key on any error.
    func createKey() throws -> Key
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool
    func seal(_ plaintext: Data, with key: Key) throws -> Data
    /// Authenticate and return raw bytes, never repair malformed UTF-8.
    func open(_ sealed: Data, with key: Key) throws -> Data
}

public enum CatalogueStoreError: Error, Equatable, Sendable {
    case broken, authorityRequired, invalidDirectory, continuity, artifactsPresent
    case contextMismatch, invalidCatalogue, limitExceeded, keyMismatch, readbackMismatch, backendFailure
}

/// Non-adopted, isolated bootstrap proposal. Caller supplies and serializes the
/// exclusive root/key namespace. No app defaults, allocation, login or recovery.
public final class CatalogueStore<Crypto: CatalogueCryptography> {
    private enum Mode { case unchecked, fresh, writing, retained }
    private var mode = Mode.unchecked
    private var retainedKey: Crypto.Key?
    public private(set) var isBroken = false

    private func checked<T>(_ body: () throws -> T) throws -> T {
        guard !isBroken else { throw CatalogueStoreError.broken }
        do { return try body() }
        catch {
            isBroken = true
            throw (error as? CatalogueStoreError) ?? .backendFailure
        }
    }
    private let directory: URL
    private let context: IdentityCatalogue
    private let files: any CatalogueFileIO
    private let crypto: Crypto
    public init(directory: URL, context: IdentityCatalogue, files: any CatalogueFileIO, crypto: Crypto) {
        self.directory = directory
        self.context = context
        self.files = files
        self.crypto = crypto
    }
    /// Explicit caller classification, not a restart heuristic. Read-only.
    /// Never derive this authority from install.v1 or an intent marker.
    public func inspectFresh() throws {
        try checked {
            guard mode == .unchecked else { throw CatalogueStoreError.authorityRequired }
            _ = try inspect(retained: false)
            mode = .fresh
        }
    }
    private func inspect(retained: Bool) throws -> Crypto.Key? {
        guard directory.isFileURL, try files.inspect(directory) == .directory else {
            throw CatalogueStoreError.invalidDirectory
        }
        let fileKind = try files.inspect(file)
        let forbidden = ["text-state.enc.tmp", "catalogue.write.pending", "owner", "realms", "realms/fi", "realms/ru"]
            + ["owner", "realms/fi", "realms/ru"].flatMap { dir in
                ["state.enc", "state.enc.tmp", "write.pending"].map { dir + "/" + $0 }
            }
        // Ancestors precede descendants. Stop at a surviving parent rather
        // than inspecting through a foreign directory or symbolic link.
        for path in forbidden {
            guard try files.inspect(directory.appendingPathComponent(path)) == .absent else {
                throw CatalogueStoreError.artifactsPresent
            }
        }
        let foreignKeys = try CatalogueForeignStore.allCases.map { try crypto.foreignKeyExists($0) }
        let key = try crypto.loadKey()
        guard !foreignKeys.contains(true) else { throw CatalogueStoreError.artifactsPresent }
        guard retained ? (fileKind == .regularFile && key != nil) : (fileKind == .absent && key == nil) else {
            throw CatalogueStoreError.continuity
        }
        if let retainedKey, key != retainedKey { throw CatalogueStoreError.keyMismatch }
        return key
    }
    private var maximumStoredBytes: Int { 65_536 + crypto.framingOverhead }
    private var file: URL { directory.appendingPathComponent("text-state.enc") }
    /// Read-only; both missing is loss, not a fresh-store result.
    public func loadRetained() throws -> IdentityCatalogue {
        try checked {
            guard mode == .unchecked || mode == .retained else { throw CatalogueStoreError.authorityRequired }
            guard let key = try inspect(retained: true) else { throw CatalogueStoreError.continuity }
            let value = try readCatalogue(key: key)
            retainedKey = key
            mode = .retained
            return value
        }
    }
    private func readCatalogue(key: Crypto.Key) throws -> IdentityCatalogue {
        let sealed = try files.read(file, maximumBytes: maximumStoredBytes)
        let plaintext = try crypto.open(sealed, with: key)
        let value: IdentityCatalogue
        do {
            value = try IdentityCatalogueCodec.decode(plaintext, expectedInstallID: context.installID,
                                                       expectedRealms: context.realms)
        } catch IdentityCatalogueError.contextMismatch { throw CatalogueStoreError.contextMismatch }
        catch IdentityCatalogueError.limitExceeded { throw CatalogueStoreError.limitExceeded }
        catch { throw CatalogueStoreError.invalidCatalogue }
        guard value == context else { throw CatalogueStoreError.contextMismatch }
        return value
    }
    public func commit(_ value: IdentityCatalogue) throws {
        try checked {
            guard mode == .fresh || mode == .retained else { throw CatalogueStoreError.authorityRequired }
            guard value == context else { throw CatalogueStoreError.contextMismatch }
            if let existing = try inspect(retained: mode == .retained) {
                _ = try readCatalogue(key: existing)
            }
            // First-write authority is consumed before the first effect, not
            // reconstructed from a marker or a nil key after failure.
            mode = .writing
            let intent = directory.appendingPathComponent("catalogue.write.pending")
            try files.writeExclusive(Data("catalogue-write-v1\n".utf8), to: intent)
            try files.fullSync(intent, directory: false)
            try files.fullSync(directory, directory: true)
            let key = try retainedKey ?? crypto.createKey()
            guard let readKey = try crypto.loadKey(), readKey == key else {
                throw CatalogueStoreError.keyMismatch
            }
            let sealed = try crypto.seal(IdentityCatalogueCodec.encode(value), with: key)
            guard sealed.count <= maximumStoredBytes else { throw CatalogueStoreError.limitExceeded }
            let temporary = directory.appendingPathComponent("text-state.enc.tmp")
            try files.writeExclusive(sealed, to: temporary)
            try files.protectAndExclude(temporary)
            try files.fullSync(temporary, directory: false)
            try files.rename(temporary, to: file)
            let readback = try files.read(file, maximumBytes: maximumStoredBytes)
            guard readback == sealed else { throw CatalogueStoreError.readbackMismatch }
            try files.fullSync(directory, directory: true)
            try files.removeIntent(intent)
            try files.fullSync(directory, directory: true)
            guard !isBroken else { throw CatalogueStoreError.broken }
            retainedKey = key
            mode = .retained
        }
    }
}
