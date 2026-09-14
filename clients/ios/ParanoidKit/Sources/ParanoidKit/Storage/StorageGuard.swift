import Foundation

/// The rule that decides, before anything is opened, whether this launch may
/// continue, must start clean, or must freeze.
///
/// Android states it in two lines (`StorageGuard.java:7-8`): a retained
/// wrapping key without its snapshot is **not** a fresh installation, and
/// neither is a snapshot without its key; either way nothing is regenerated
/// and the process stops. That exclusive-or is `continuity(_:_:)` below, it is
/// the rule of `docs/clients/core/self-service.md:97-100`, and it is unchanged.
///
/// `start(...)` is the launch decision around it, and it answers two questions
/// the exclusive-or cannot, because on iOS the Keychain outlives the
/// application container while the state file does not.
///
/// **Is this container new?** `InstallMarker.isPresent` answers it, and a key
/// found under `paranoid-text-state-v0` in a container that has never been
/// launched belongs to a previous installation: it is deleted, the marker is
/// recorded, and only then is the exclusive-or evaluated — on a key that is
/// now certainly this installation's. That is the reinstall decision (D-004:
/// reinstalling is a clean install with a new identity), reported as a
/// documented platform difference, not as a change to the fail-closed rule.
///
/// A state file **disproves** that question, so it wins over the missing
/// marker. Uninstalling takes the whole container, defaults and
/// `Application Support/` together, so a file that is still there means the
/// marker was lost some other way — a restored, repaired or wiped preferences
/// domain, and the defaults are not even in the same protection class as the
/// file. Deleting the key on that evidence would leave a snapshot nobody can
/// ever decrypt again, while freezing leaves both halves where they are for a
/// person to investigate. So the launch freezes, having deleted nothing and
/// recorded nothing: refusing to proceed stays reproducible on every later
/// launch, instead of turning into an ordinary one.
///
/// **Has this container ever held a snapshot?** `InstallMarker`'s second fact
/// answers that, and it is why a key without a file is not one case but two.
/// Android creates its Keystore alias at the first commit and never before
/// (`TextEngine.java:265-273`), so over there the question cannot arise. This
/// client creates the Keychain item while opening, before the user has decided
/// anything, so a first run that closes the Welcome screen without «Создать
/// ID» leaves exactly a key and no file — an interrupted first run, not
/// evidence of tampering, and freezing it would be a permanent freeze reached
/// by doing nothing wrong. A key whose container *has* committed a snapshot is
/// the dangerous one: the file it belongs to has gone missing, and that still
/// freezes, so a state file can never be silently replaced by a new identity.
///
/// **Was this container keeping that record?** The question above is only
/// answerable where the answer was being written down, and a container
/// installed before this rule was not writing it: every installation that
/// exists today holds `paranoid.install.v1` and a committed state file and no
/// `paranoid.snapshot.v1`, because no build ever wrote one. Reading that
/// silence as "nothing was ever committed here" would hand the interrupted
/// first run's `.fresh` to a container whose state file has gone missing —
/// the one case the whole rule exists to refuse — in the window between
/// installing this build and its first launch. So the licence to read the
/// silence is `InstallMarker.recordsCommits`, written by the launch that
/// starts the record and not assumed of every container; without it a key
/// with no file keeps the stricter reading and freezes, exactly as it did
/// before this rule. An installation from an earlier build earns the licence
/// the first time it is seen holding neither a key nor a file — the one
/// moment at which "nothing has been committed here" is an observation.
///
/// The resulting matrix:
///
/// | marker | records commits | held a snapshot | key | file | outcome |
/// | --- | --- | --- | --- | --- | --- |
/// | absent | — | — | any | present | `.frozen`, nothing deleted, nothing recorded |
/// | absent | — | — | stale | absent | key deleted, marker recorded, `.fresh` |
/// | present | yes | no | present | absent | `.fresh`, the interrupted first run |
/// | present | yes | yes | present | absent | `.frozen` |
/// | present | no | — | present | absent | `.frozen`: an installation from a build
/// before this rule, whose silence is not evidence |
/// | present | any | any | absent | present | `.frozen` |
/// | present | any | any | absent | absent | `.fresh` (iCloud restore onto a new
/// iPhone: the defaults came back, the `ThisDeviceOnly` key and the excluded file
/// did not), the restored second fact is forgotten with them, and the record
/// starts here |
/// | present | any | any | present | present | `.retained`, the ordinary launch |
///
/// No row replaces an existing state file, hands the core a fresh identity
/// while a usable state exists, or deletes a key that any file could still
/// need.
public enum StorageGuard {
    /// The Keychain account the guard talks about, unchanged from
    /// `StorageGuard.java:5`.
    public static let account = KeychainKey.account

    /// What a launch may do.
    public enum Continuity: Equatable, Sendable {
        /// Neither a state file nor a key: create a key, register a new
        /// identity.
        case fresh
        /// Both present: open the state file with the retained key.
        case retained
        /// Exactly one present: stop. Nothing is regenerated, nothing is
        /// deleted, nothing is sent.
        case frozen
    }

    /// The exclusive-or itself, with no side effects.
    public static func continuity(snapshotExists: Bool, keyExists: Bool) -> Continuity {
        guard snapshotExists == keyExists else { return .frozen }
        return snapshotExists ? .retained : .fresh
    }

    /// `StorageGuard.java:7-8` with the same shape: throws when the retained
    /// state is incomplete.
    ///
    /// - Throws: `StorageError.frozen`.
    public static func requireContinuity(snapshotExists: Bool, keyExists: Bool) throws {
        guard continuity(snapshotExists: snapshotExists, keyExists: keyExists) != .frozen else {
            throw StorageError.frozen
        }
    }

    /// The startup decision, in the one order that is safe.
    ///
    /// 1. No marker and a state file: the container is not new, whatever the
    ///    defaults say. Freeze at once — before the delete, which is the only
    ///    irreversible act in this type.
    /// 2. No marker and no state file: a key left over from a previous
    ///    installation is deleted first. A failed delete throws and the marker
    ///    is **not** recorded, so the next launch tries again instead of
    ///    treating the stale key as this installation's.
    /// 3. The marker is recorded, which also fixes the answer to steps 1 and 2
    ///    for every later launch of this container.
    /// 4. A file that is there is remembered, a container that holds neither a
    ///    key nor a file forgets what it remembered and starts its record
    ///    there, and the exclusive-or is evaluated against the Keychain as it
    ///    now stands — refined by that memory for the one row where a key
    ///    alone is ambiguous, and only where the memory was being kept.
    ///
    /// `snapshotExists` is read by the caller *before* this runs
    /// (`SnapshotStore.snapshotExists()`); the guard never touches the file.
    ///
    /// - Throws: `StorageError.keychain`,
    ///   `StorageError.installMarkerUnavailable`.
    public static func start<Key: RetainedKey>(snapshotExists: Bool,
                                               marker: InstallMarker,
                                               key: Key = KeychainKey.standard) throws -> Continuity {
        if !marker.isPresent {
            guard !snapshotExists else { return .frozen }
            try key.deleteRetained()
            try marker.record()
        }
        let keyExists = try key.exists()
        guard !snapshotExists else {
            // Best effort, unlike the same call inside a commit
            // (`SnapshotStore.commit`, step 6). This launch holds both halves
            // and regenerates nothing, so refusing it would trade a usable
            // client for the frozen screen — whose only exit for a user is the
            // reinstall that destroys the identity being protected — over a
            // fact the next launch would write again. Where the fact has to be
            // kept is a launch that *starts* something, and there the commit
            // itself refuses: a container that cannot record what it committed
            // breaks the store before any identity is adopted or sent.
            try? marker.recordCommittedSnapshot()
            return continuity(snapshotExists: true, keyExists: keyExists)
        }
        guard keyExists else {
            // Neither half: there is nothing left to protect and nothing left
            // to lose, so whatever this container remembered is void and its
            // record starts again here — which is also how an installation
            // from before this rule stops being read by the stricter one.
            marker.forgetCommittedSnapshot()
            marker.beginRecordingCommits()
            return .fresh
        }
        // A key on its own: dangerous if the file it wraps once existed, and
        // equally dangerous if this container was never in a position to say.
        guard marker.recordsCommits, !marker.hasCommittedSnapshot else { return .frozen }
        return .fresh
    }
}
