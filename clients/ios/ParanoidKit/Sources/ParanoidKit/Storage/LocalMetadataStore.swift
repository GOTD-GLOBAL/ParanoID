import Foundation

/// A table this phone keeps for itself, in a container file that an OS backup
/// does not carry.
///
/// Two stores use it, and both hold the same kind of thing: relationship
/// metadata the messenger never sends to a peer or a server, but that says who
/// this phone talks to. The local contact names (`ContactNames`) are the names
/// typed on this device; the call log (`CallLog`) is the outcome, direction and
/// duration of every call it watched. Until this type both lived in standard
/// `UserDefaults`, which iCloud and an encrypted local backup both carry, so a
/// restore onto a second device reproduced the names and the call history there
/// — the limitation `docs/clients/ios/self-service.md` recorded and RFC-0024
/// proposes closing.
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
/// ## What a failure may and may not do
///
/// Nothing here throws into a screen. A table like this is a convenience: a
/// phone whose disk refuses the write must still open the chat, show the
/// messages the core committed, and place a call. But "convenience" is not
/// licence to destroy the table, and the rules below exist because the first
/// draft of this type did exactly that in three places (PR47 review):
///
/// - **A file that exists and will not open is not an empty table.** When the
///   read fails the store *seals*, whatever else is lying around: every later
///   write and the removal are refused, so a table that could not be read is
///   never replaced by the empty one its caller had to start from — and a
///   preference beside it, which may be *older* than the file, is never written
///   back over it either. A later load that succeeds unseals the instance, but
///   the application builds each store once, in an `AppModel` property
///   initializer, so in practice a seal lasts the process and the next launch
///   is the recovery.
/// - **A file that opens but does not parse is replaced, not sealed.** It is
///   unreadable to every build of this generation, so refusing to store names
///   for the rest of the run would trade a recoverable state for a permanent
///   one. Where a preference still stands behind it, that preference is used
///   and the file is rewritten from it.
/// - **Only a proven failure deletes.** Bytes that come back different, or a
///   backup flag that reads definitely false, are evidence the committed file
///   is wrong, and it goes. An operation that merely *throws* — a read the
///   device would not answer — proves nothing, and by then the rename has
///   already unlinked the copy it replaced, so the file stays.
/// - **A file that is committed, byte-exact and provably excluded is kept**,
///   even if the *directory* sync that follows fails. That sync makes the
///   rename durable; losing it is a reason to answer `false`, never a reason to
///   delete the only copy that is left.
/// - **The preference behind a file dies only against proof.** It is retired
///   after a full commit, or after a read that both parses for its caller and
///   proves the file excluded — never merely because some bytes came back.
///
/// The commit sequence is the snapshot's, with one addition. The backup flag
/// lives on the inode, so it is set before the rename and read back from the
/// committed name afterwards; here it is also set while the candidate is still
/// **empty**, so that no interruption between writing the table and flagging it
/// can leave these rows in a file a backup would take.
public final class LocalMetadataStore {
    /// The largest table read or written.
    ///
    /// The bound that matters is the call log's worst admissible case: core
    /// contact admission stops at 64 conversations
    /// (`clients/core/src/clean_service.rs:365`) and the log keeps 500 rows per
    /// conversation, which encodes to about 7.1 MiB. A ceiling below that would
    /// refuse a legal table — the pre-upgrade log would then never migrate and
    /// would stay in the backup-eligible preference for ever, which is the
    /// opposite of this type's purpose. 16 MiB clears that worst case with
    /// better than twice the room and still bounds what a corrupt file can ask
    /// this process to map.
    public static let maximumStoredBytes = 16 * 1024 * 1024

    /// The committed file.
    public let fileURL: URL
    /// The candidate, which carries the backup flag into the rename.
    public var temporaryFileURL: URL { fileURL.appendingPathExtension("tmp") }

    /// Whether this store has refused to hand over a file it could not read,
    /// and therefore refuses to overwrite or remove it. Cleared by any later
    /// load that succeeds.
    public private(set) var isSealed = false

    private let directory: URL
    private let legacyKey: String
    private let defaults: UserDefaults?
    private let fileSystem: FileSystem

    /// - Parameters:
    ///   - name: the file inside `directory`, versioned like the defaults key
    ///     it replaces so a later rule can be told apart from this one.
    ///   - legacyKey: the `UserDefaults` key this file replaces. It is read
    ///     once, to migrate, and retired only against proof.
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
    /// The file wins whenever it can be read **and** its caller can use it. A
    /// file the caller cannot parse is treated as absent rather than as an
    /// empty table, so a preference left by an interrupted migration is still
    /// the better copy and is used instead. A file that will not open at all,
    /// with no preference behind it, seals the store: see the type comment.
    ///
    /// - Parameters:
    ///   - legacy: reads the old preference value as the bytes this file should
    ///     hold. Each caller shapes its own, because the two old values are not
    ///     the same kind: one was a plist dictionary, the other was already
    ///     JSON.
    ///   - validate: whether these bytes are a table this caller can show. The
    ///     default accepts anything, for callers that keep no shape of their
    ///     own; both application callers decode here, so that a corrupt file is
    ///     never mistaken for an empty one.
    @discardableResult
    public func load(migrating legacy: (UserDefaults) -> Data?,
                     validate: (Data) -> Bool = { _ in true }) -> Data? {
        var readFailed = false
        if fileSystem.fileExists(at: fileURL) {
            do {
                let stored = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
                if validate(stored) {
                    isSealed = false
                    // The old copy's life ends only against a file this store
                    // can prove a backup will not take.
                    if ensureExcluded() { clearLegacy() }
                    return stored
                }
                // Present, readable, and not a table this caller can use. The
                // preference behind it, if an upgrade left one, is the better
                // copy — fall through to it rather than start empty.
            } catch {
                readFailed = true
            }
        }
        let carried = defaults.flatMap(legacy)
        if readFailed {
            // A file that exists and will not open is the only copy there is,
            // whatever else is lying around. The preference beside it may be
            // *older* than the file — a save whose durability could not be
            // proven keeps both — so writing it back would replace a newer
            // table with a stale one. Seal, show whatever the old copy holds,
            // and write nothing.
            isSealed = true
            return carried
        }
        guard let carried else {
            // Nothing this build would keep — but an old value must still stop
            // being carried into backups.
            clearLegacy()
            return nil
        }
        isSealed = false
        // `save` retires the preference itself, and only once the file is
        // committed, verified, provably excluded and durably named.
        save(carried)
        return carried
    }

    /// Replaces the stored table.
    ///
    /// `false` means the table is not known to be both committed and durable.
    /// It does **not** mean the file was removed: a file is removed only when
    /// it could not be verified or could not be proven excluded from backup,
    /// which are the two states this build promised never to leave behind.
    @discardableResult
    public func save(_ data: Data) -> Bool {
        guard !isSealed, data.count <= Self.maximumStoredBytes else { return false }
        let temporary = temporaryFileURL
        do {
            try fileSystem.prepareExcludedDirectory(at: directory)
            // A candidate left behind by an interrupted run may predate its own
            // exclusion, so it goes before a new one is made.
            try fileSystem.removeItem(at: temporary)
            // The flag goes on the inode while it is still empty. The rename
            // moves that inode, so the table never exists in an unflagged file,
            // not even between two lines of this method.
            try fileSystem.write(Data(), to: temporary)
            try fileSystem.excludeFromBackup(at: temporary)
            try fileSystem.write(data, to: temporary)
            try fileSystem.fullSync(at: temporary, directory: false)
            try fileSystem.rename(from: temporary, to: fileURL)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            return false
        }
        do {
            let readback = try fileSystem.read(at: fileURL, maximumBytes: Self.maximumStoredBytes)
            let excluded = try fileSystem.isExcludedFromBackup(at: fileURL)
            guard readback == data, excluded else {
                // Proven wrong, not merely unproven: the device handed back
                // other bytes, or the committed name is definitely not
                // excluded. Both leave metadata this build promised to
                // withhold, so the file goes.
                try? fileSystem.removeItem(at: fileURL)
                return false
            }
        } catch {
            // Inconclusive, and that is a different thing. The candidate's
            // inode carried the flag before the rename, so the committed name
            // is excluded by construction; an answer the device would not give
            // is proof of nothing. Meanwhile the rename has already unlinked
            // the copy this one replaced, so deleting here would destroy the
            // only table there is — the mistake the directory sync above was
            // already corrected for.
            return false
        }
        do {
            try fileSystem.fullSync(at: directory, directory: true)
        } catch {
            // The bytes are committed, verified and excluded; only the rename's
            // durability is unproven. Keep the file — it is now the only copy —
            // and keep the preference behind it, which is the copy that would
            // survive a power loss here.
            return false
        }
        clearLegacy()
        return true
    }

    /// Forgets the table: the file, any candidate beside it, and the preference
    /// behind it. This is how an emptied table is stored, which is what the
    /// preferences did by removing their key.
    ///
    /// A sealed store refuses: an emptied in-memory table is exactly what a
    /// failed read produces, and that must not become a deletion.
    @discardableResult
    public func clear() -> Bool {
        guard !isSealed else { return false }
        // The preference goes first, and unconditionally. It is the copy an OS
        // backup carries, and it is the copy a later launch would resurrect the
        // emptied table from: leaving it alive while the file is already gone
        // is both the disclosure this type exists to stop and a table the owner
        // deleted coming back.
        clearLegacy()
        do {
            try fileSystem.removeItem(at: fileURL)
            try fileSystem.removeItem(at: temporaryFileURL)
            if fileSystem.fileExists(at: directory) {
                // An emptied table that comes back after a power loss is the
                // same disclosure as never having emptied it.
                try fileSystem.fullSync(at: directory, directory: true)
            }
        } catch {
            return false
        }
        return true
    }

    /// Whether an OS backup would carry the committed file. The tests assert on
    /// it; nothing in the application reads it.
    public func isExcludedFromBackup() -> Bool {
        (try? fileSystem.isExcludedFromBackup(at: fileURL)) ?? false
    }

    /// The flag on the committed name, set if it is missing. Answers whether it
    /// is now known to be there — never that it probably is.
    private func ensureExcluded() -> Bool {
        do {
            if try fileSystem.isExcludedFromBackup(at: fileURL) { return true }
            try fileSystem.excludeFromBackup(at: fileURL)
            return try fileSystem.isExcludedFromBackup(at: fileURL)
        } catch {
            return false
        }
    }

    private func clearLegacy() {
        defaults?.removeObject(forKey: legacyKey)
    }
}
