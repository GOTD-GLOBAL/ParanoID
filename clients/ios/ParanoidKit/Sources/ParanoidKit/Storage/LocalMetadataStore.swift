import Foundation

/// A table this phone keeps for itself, in a container file that an OS backup
/// does not carry.
///
/// Two stores use it, and both hold the same kind of thing: relationship
/// metadata the messenger never sends to a peer or a server, but that says who
/// this phone talks to. The local contact names
/// (`ContactNames`) are the names typed on this device; the call log
/// (`CallLog`) is the outcome, direction and duration of every call it
/// watched. Until this type both lived in standard `UserDefaults`, which
/// iCloud and an encrypted local backup both carry, so a restore onto a second
/// device reproduced the names and the call history there — the limitation
/// `docs/clients/ios/self-service.md` recorded and RFC-0024 proposes closing.
///
/// What this is **not** is application-level encryption. The bytes are plain
/// JSON, protected by the application container and the
/// `completeUntilFirstUserAuthentication` class, exactly as the preferences
/// were: what changes is that a backup no longer takes them. The snapshot's
/// wrapping key is deliberately not borrowed — it is created by the first
/// commit and a frozen key would then stop a chat from drawing its own
/// contact's name, a worse failure than the one being fixed. Sealing these two
/// files is a separate decision and RFC-0024 states it as one.
///
/// The commit sequence is the snapshot's, for the same reason it exists there:
/// the backup flag lives on the inode, so it is set on the temporary file
/// **before** the rename, and read back from the committed name afterwards. A
/// file that cannot be proven excluded is removed rather than left for the
/// next backup to take.
///
/// Nothing here throws into a screen. A table like this is a convenience: a
/// phone whose disk refuses the write must still open the chat, show the
/// messages the core committed, and place a call. Failure is answered as
/// `false` and the value stays in memory for the rest of the run.
public struct LocalMetadataStore {
    /// The largest table read or written. Well above what the two callers can
    /// produce — the call log keeps at most 500 rows per conversation and core
    /// contact admission bounds the conversations — and well below the
    /// snapshot's own ceiling.
    public static let maximumStoredBytes = 4 * 1024 * 1024

    /// The committed file.
    public let fileURL: URL
    /// The candidate, which carries the backup flag into the rename.
    public var temporaryFileURL: URL { fileURL.appendingPathExtension("tmp") }

    private let directory: URL
    private let legacyKey: String
    private let defaults: UserDefaults?
    private let fileSystem: FileSystem

    /// - Parameters:
    ///   - name: the file inside `directory`, versioned like the defaults key
    ///     it replaces so a later rule can be told apart from this one.
    ///   - legacyKey: the `UserDefaults` key this file replaces. It is read
    ///     once, to migrate, and cleared only after the file it produced has
    ///     been read back and proven excluded from backup.
    ///   - defaults: the suite holding `legacyKey`, or `nil` for a store with
    ///     nothing to migrate.
    public init(name: String,
                legacyKey: String,
                directory: URL,
                defaults: UserDefaults?,
                fileSystem: FileSystem = DataProtectionFileSystem()) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(name, isDirectory: false)
        self.legacyKey = legacyKey
        self.defaults = defaults
        self.fileSystem = fileSystem
    }

    /// The application's store: the same `Application Support/paranoid/` the
    /// state file lives in, so one directory carries one backup exclusion.
    ///
    /// `nil` when the container has no Application Support directory to name,
    /// which leaves its caller an in-memory table rather than a broken launch.
    public static func applicationSupport(name: String,
                                          legacyKey: String,
                                          defaults: UserDefaults? = .standard,
                                          fileSystem: FileSystem = DataProtectionFileSystem())
        -> LocalMetadataStore? {
        guard let directory = try? DataProtectionFileSystem.applicationSupportDirectory() else {
            return nil
        }
        return LocalMetadataStore(name: name, legacyKey: legacyKey, directory: directory,
                                  defaults: defaults, fileSystem: fileSystem)
    }

    /// What was stored, or `nil` for a store that has nothing readable.
    ///
    /// The file wins whenever it can be read: it is the only copy a backup
    /// does not carry, and a defaults value beside it is a leftover of a
    /// migration whose last step did not run, so it is cleared here too. A
    /// file that is absent, or that the device refuses to hand back, falls
    /// back to the defaults value, which is then migrated — an interrupted
    /// migration therefore repeats instead of losing the table.
    ///
    /// "Readable" here is this store's question, not its caller's: the bytes
    /// are not parsed at this level, so a file that its caller then fails to
    /// decode still counts as the one live copy.
    ///
    /// - Parameter legacy: reads the old preference value as the bytes this
    ///   file should hold. Each caller shapes its own, because the two old
    ///   values are not the same kind: one was a plist dictionary, the other
    ///   was already JSON.
    public func load(migrating legacy: (UserDefaults) -> Data?) -> Data? {
        if let stored = try? fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes) {
            clearLegacy()
            return stored
        }
        guard let defaults else { return nil }
        guard let carried = legacy(defaults) else {
            // The old value holds nothing this build would keep — but it must
            // still stop being carried into backups.
            clearLegacy()
            return nil
        }
        // Only a committed, readback-verified, provably excluded file may end
        // the old value's life.
        if save(carried) { clearLegacy() }
        return carried
    }

    /// Replaces the stored table. `false` means nothing durable happened, or
    /// that a file which could not be proven excluded from backup was removed.
    @discardableResult
    public func save(_ data: Data) -> Bool {
        guard data.count <= Self.maximumStoredBytes else { return false }
        let temporary = temporaryFileURL
        do {
            try fileSystem.prepareExcludedDirectory(at: directory)
            try fileSystem.write(data, to: temporary)
            // Before the rename: the flag belongs to the inode the rename moves.
            try fileSystem.excludeFromBackup(at: temporary)
            try fileSystem.fullSync(at: temporary, directory: false)
            try fileSystem.rename(from: temporary, to: fileURL)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            return false
        }
        do {
            let readback = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
            guard readback == data, try fileSystem.isExcludedFromBackup(at: fileURL) else {
                // Either the device did not keep what it was handed, or the
                // committed name is not excluded. Both leave metadata this
                // build promised to withhold, so the file goes.
                try? fileSystem.removeItem(at: fileURL)
                return false
            }
            try fileSystem.fullSync(at: directory, directory: true)
            return true
        } catch {
            try? fileSystem.removeItem(at: fileURL)
            return false
        }
    }

    /// Forgets the table: the file and any legacy value behind it. This is how
    /// an emptied table is stored, which is what the preferences did by
    /// removing their key.
    @discardableResult
    public func clear() -> Bool {
        clearLegacy()
        do {
            try fileSystem.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Whether an OS backup would carry the committed file. The tests assert
    /// on it; nothing in the application reads it.
    public func isExcludedFromBackup() -> Bool {
        (try? fileSystem.isExcludedFromBackup(at: fileURL)) ?? false
    }

    private func clearLegacy() {
        defaults?.removeObject(forKey: legacyKey)
    }
}
