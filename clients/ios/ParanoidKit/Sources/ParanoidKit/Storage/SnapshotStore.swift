import CryptoKit
import Foundation

/// The failures the storage layer reports.
///
/// `broken` and `frozen` are the two terminal states the protocol demands and
/// they are deliberately distinct: `frozen` is decided before anything is
/// opened (`StorageGuard`), `broken` is a save or a load that failed or is
/// ambiguous (`docs/protocol/first-contact-v1.md:173-178`,
/// `docs/clients/core/self-service.md:97-100`). Neither ever leads to a fresh
/// identity.
public enum StorageError: Error, Equatable, Sendable {
    /// A commit or a load failed. The store is unusable for the rest of the
    /// process and nothing derived from that candidate may be sent;
    /// `SnapshotStore.brokenCause` holds the first underlying error.
    case broken
    /// Exactly one of the state file and the wrapping key exists, or the key
    /// is missing while the file is there. Nothing is regenerated.
    case frozen
    /// The install marker could not be written, so the next launch would treat
    /// this container as a fresh install and delete a live key.
    case installMarkerUnavailable
    /// The bytes read back after the rename are not the bytes that were
    /// written.
    case readbackMismatch
    /// A Keychain call failed with this `OSStatus`.
    case keychain(OSStatus)
}

/// The encrypted state file: `Application Support/paranoid/text-state.enc`,
/// written the one way `docs/protocol/first-contact-v1.md:173-178` allows.
///
/// A commit is five durable steps in this order, the iOS counterpart of
/// `TextEngine.java:226-237` (`AtomicFile` plus `FileDescriptor.sync` plus the
/// read-back comparison plus the parent `fsync`):
///
/// 1. `write` the sealed candidate to `text-state.enc.tmp`, in the same
///    directory so that the rename stays inside one file system;
/// 2. `fullSync` that temporary file — `F_FULLFSYNC`, not `fsync`, because on
///    Darwin `fsync` may leave the bytes in the drive's write cache;
/// 3. `rename` it over `text-state.enc`, the atomic replacement;
/// 4. `read` the committed file and compare it byte for byte with what was
///    sealed;
/// 5. `fullSync` the directory, so that the new directory entry survives a
///    power loss too.
///
/// Between 1 and 2 the temporary file is excluded from backup. That is not a
/// durability step, but it has to happen there: the flag lives on the inode,
/// and after the rename the inode under `text-state.enc` is the one that was
/// created as the temporary file. Setting the flag on the committed name once
/// at creation would therefore protect only the first commit, and every later
/// one would enter the backup — an iCloud restore would then hand a *stale*
/// ratchet to a device whose Keychain key is still valid, which is exactly the
/// state the protocol forbids.
///
/// Any error in any step sets `isBroken` for the rest of the process: the
/// candidate is neither adopted nor sent, and the application must take itself
/// off the network. A snapshot holds private keys and plaintext, so nothing
/// here logs one, sealed or open.
public final class SnapshotStore {
    /// The committed name, Android's `text-state.enc`
    /// (`TextEngine.java:94`).
    public static let fileName = "text-state.enc"
    /// The candidate name, in the same directory as the committed one.
    public static let temporaryFileName = "text-state.enc.tmp"
    /// Largest stored file this store will read: 9 MiB, the ceiling of
    /// `TextEngine.java:102`. It is an outer bound on
    /// `SnapshotCodec.maximumSnapshotBytes` (8 MiB + 29), not a second
    /// format rule.
    public static let maximumStoredBytes = 9 * 1024 * 1024

    /// `Application Support/paranoid/`.
    public let directory: URL
    /// The committed state file.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }
    /// The candidate file, never read by anything but the commit that wrote it.
    public var temporaryFileURL: URL {
        directory.appendingPathComponent(Self.temporaryFileName, isDirectory: false)
    }

    /// Terminal once set: no later commit or load touches the file system.
    public private(set) var isBroken = false
    /// The first error that broke the store, kept for the operator-visible
    /// message. Never holds snapshot bytes.
    public private(set) var brokenCause: Error?

    private let fileSystem: FileSystem
    private let key: SymmetricKey

    /// - Parameters:
    ///   - directory: `Application Support/paranoid/`; use
    ///     `DataProtectionFileSystem.applicationSupportDirectory()`.
    ///   - key: the AES-256 wrapping key from `KeychainKey`. The store never
    ///     creates or replaces a key.
    ///   - fileSystem: the real file system by default; the host tests inject
    ///     one that fails a chosen step.
    public init(directory: URL, key: SymmetricKey, fileSystem: FileSystem = DataProtectionFileSystem()) {
        self.directory = directory
        self.key = key
        self.fileSystem = fileSystem
    }

    /// Whether a committed state file is present. This is the `snapshotExists`
    /// argument of `StorageGuard`, and it is read before any key is created.
    public func snapshotExists() -> Bool {
        Self.snapshotExists(in: directory, fileSystem: fileSystem)
    }

    /// The same question, asked before there is a key to build a store with.
    ///
    /// The startup order needs it: `StorageGuard.start(...)` decides whether a
    /// key may be created at all, and that decision depends on whether the
    /// state file is there.
    public static func snapshotExists(in directory: URL,
                                      fileSystem: FileSystem = DataProtectionFileSystem()) -> Bool {
        fileSystem.fileExists(at: directory.appendingPathComponent(fileName, isDirectory: false))
    }

    /// Creates the directory if it is missing and makes sure it is excluded
    /// from backup. Idempotent; `commit` and `load` call it themselves.
    public func prepare() throws {
        if !fileSystem.fileExists(at: directory) {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.excludeFromBackup(at: directory)
        } else if try !fileSystem.isExcludedFromBackup(at: directory) {
            try fileSystem.excludeFromBackup(at: directory)
        }
    }

    /// Opens the committed state file, or returns `nil` when there is none.
    ///
    /// A file that is present but too large, unreadable or refused by the
    /// codec breaks the store: a corrupt or incompatible state gives a visible
    /// error, never a fresh identity
    /// (`docs/clients/core/self-service.md:99-100`).
    ///
    /// - Throws: `StorageError.broken`.
    public func load() throws -> String? {
        guard !isBroken else { throw StorageError.broken }
        do {
            try prepare()
            guard fileSystem.fileExists(at: fileURL) else { return nil }
            var stored = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
            defer { stored.resetBytes(in: stored.startIndex..<stored.endIndex) }
            return try SnapshotCodec.open(key: key, value: stored)
        } catch {
            throw broke(on: error)
        }
    }

    /// Commits `snapshot` through the five steps above.
    ///
    /// The caller must not adopt the candidate in the user interface, and must
    /// not send anything that depends on it, until this returns.
    ///
    /// - Throws: `StorageError.broken` for every failure, including a store
    ///   that was already broken.
    public func commit(_ snapshot: String) throws {
        guard !isBroken else { throw StorageError.broken }
        do {
            try prepare()
            let sealed = try SnapshotCodec.seal(key: key, value: snapshot)
            let temporary = temporaryFileURL
            do {
                try fileSystem.write(sealed, to: temporary)                 // 1
                // Inode-bound, so it belongs to the candidate, not to the
                // committed name; see the type documentation.
                try fileSystem.excludeFromBackup(at: temporary)
                try fileSystem.fullSync(at: temporary, directory: false)    // 2
                try fileSystem.rename(from: temporary, to: fileURL)         // 3
                let readback = try fileSystem.read(at: fileURL,             // 4
                                                   maximumBytes: Self.maximumStoredBytes)
                guard readback == sealed else { throw StorageError.readbackMismatch }
                try fileSystem.fullSync(at: directory, directory: true)     // 5
            } catch {
                // Best effort: a candidate that never became the state must
                // not stay behind. A failure here cannot make the outcome any
                // worse and must not replace the real cause.
                try? fileSystem.removeItem(at: temporary)
                throw error
            }
        } catch {
            throw broke(on: error)
        }
    }

    /// Records the first cause and returns the error every caller sees.
    private func broke(on error: Error) -> StorageError {
        if !isBroken {
            isBroken = true
            brokenCause = error
        }
        return .broken
    }
}
