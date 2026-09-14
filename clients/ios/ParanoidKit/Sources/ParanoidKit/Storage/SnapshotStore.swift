import CryptoKit
import Foundation
import Security

public enum StorageError: Error, Equatable, Sendable {
    case broken
    case frozen
    case installMarkerUnavailable
    case readbackMismatch
    case keychain(OSStatus)
}

/// Sealed state, with a persistent wrapping key acquired only at first commit.
/// REQ-MSG-002/005; first-contact-v1 retained-state and commit boundaries.
///
/// Opening Welcome creates no key. The first commit creates the Keychain item
/// before writing the candidate, then performs write -> backup exclusion ->
/// F_FULLFSYNC(candidate) -> rename -> byte-exact readback -> F_FULLFSYNC(parent).
/// Keychain and the file are not one transaction: failure after key creation
/// can leave key-without-file. That state freezes on every later launch; the
/// store never removes the key to pretend the commit did not happen.
///
/// No pending-first-run UserDefaults value authorizes recovery. Existing
/// key/file bytes, account name, crypto format and install.v1 meaning remain
/// unchanged. Owners serialize this store on StateOwner (no concurrent calls).
public final class SnapshotStore {
    public static let fileName = "text-state.enc"
    public static let temporaryFileName = "text-state.enc.tmp"
    public static let maximumStoredBytes = 9 * 1024 * 1024
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }
    public var temporaryFileURL: URL {
        directory.appendingPathComponent(Self.temporaryFileName, isDirectory: false)
    }
    public private(set) var isBroken = false
    public private(set) var brokenCause: Error?

    private let fileSystem: FileSystem
    private let fixedKey: SymmetricKey?
    private let keyStore: (any WrappingKeyStore)?
    private var retainedKey: SymmetricKey?

    /// Explicit-key adapter for isolated tools and codec/file-system tests.
    /// It does not manage Keychain continuity. The application uses keyStore:.
    /// `marker` remains a source-compatible, ignored argument for existing
    /// tools; commits no longer read or mutate any UserDefaults bookkeeping.
    public init(directory: URL, key: SymmetricKey,
                fileSystem: FileSystem = DataProtectionFileSystem(),
                marker: InstallMarker? = nil) {
        self.directory = directory
        self.fixedKey = key
        self.keyStore = nil
        self.fileSystem = fileSystem
    }

    /// Application adapter. Construction and load never create a key.
    /// The injected store makes the real production ordering testable on a
    /// Mac host; KeychainKey is the production implementation.
    public init(directory: URL, keyStore: any WrappingKeyStore,
                fileSystem: FileSystem = DataProtectionFileSystem()) {
        self.directory = directory
        self.fixedKey = nil
        self.keyStore = keyStore
        self.fileSystem = fileSystem
    }

    public func snapshotExists() -> Bool {
        Self.snapshotExists(in: directory, fileSystem: fileSystem)
    }
    public static func snapshotExists(in directory: URL,
                                      fileSystem: FileSystem = DataProtectionFileSystem()) -> Bool {
        fileSystem.fileExists(at: directory.appendingPathComponent(fileName, isDirectory: false))
    }

    public func prepare() throws {
        if !fileSystem.fileExists(at: directory) {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.excludeFromBackup(at: directory)
        } else if try !fileSystem.isExcludedFromBackup(at: directory) {
            try fileSystem.excludeFromBackup(at: directory)
        }
    }

    /// Returns nil only for an empty store; the persistent adapter refuses a
    /// retained key without its file, even if defaults assert a pending run.
    public func load() throws -> String? {
        guard !isBroken else { throw StorageError.broken }
        do {
            try prepare()
            let present = snapshotExists()
            if let keyStore {
                let existing = try keyStore.load()
                guard present == (existing != nil) else { throw StorageError.frozen }
                guard let existing else {
                    guard retainedKey == nil else { throw StorageError.frozen }
                    return nil
                }
                try remember(existing)
                return try open(with: existing)
            }
            guard present, let fixedKey else { return nil }
            return try open(with: fixedKey)
        } catch { throw broke(on: error) }
    }

    private func open(with key: SymmetricKey) throws -> String {
        var stored = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
        defer { stored.resetBytes(in: stored.startIndex..<stored.endIndex) }
        return try SnapshotCodec.open(key: key, value: stored)
    }

    /// Only a commit can create a persistent key. An existing key is reusable
    /// only beside its file. Errors/inaccessible keys are never absence.
    private func commitKey() throws -> SymmetricKey {
        if let fixedKey { return fixedKey }
        guard let keyStore else { throw StorageError.frozen }
        let present = snapshotExists()
        if let existing = try keyStore.load() {
            guard present else { throw StorageError.frozen }
            try remember(existing)
            return existing
        }
        guard !present, retainedKey == nil else { throw StorageError.frozen }
        let created = try keyStore.create()
        try remember(created)
        return created
    }

    private func remember(_ key: SymmetricKey) throws {
        if let retainedKey, retainedKey != key { throw StorageError.frozen }
        retainedKey = key
    }

    /// Adoption and all network work derived from the candidate follow success.
    /// No failure, including a partial Keychain creation, triggers key deletion.
    public func commit(_ snapshot: String) throws {
        guard !isBroken else { throw StorageError.broken }
        do {
            try prepare()
            let key = try commitKey()
            let sealed = try SnapshotCodec.seal(key: key, value: snapshot)
            let temporary = temporaryFileURL
            do {
                try fileSystem.write(sealed, to: temporary)
                try fileSystem.excludeFromBackup(at: temporary)
                try fileSystem.fullSync(at: temporary, directory: false)
                try fileSystem.rename(from: temporary, to: fileURL)
                let readback = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
                guard readback == sealed else { throw StorageError.readbackMismatch }
                try fileSystem.fullSync(at: directory, directory: true)
            } catch {
                try? fileSystem.removeItem(at: temporary)
                throw error
            }
        } catch { throw broke(on: error) }
    }

    private func broke(on error: Error) -> StorageError {
        if !isBroken { isBroken = true; brokenCause = error }
        return .broken
    }
}
