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
/// application container while the state file does not. Each is answered by
/// one fact the container keeps about itself (`InstallMarker`), and the two
/// facts are read in opposite directions on purpose: the first by its
/// absence, the second only by its presence.
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
/// **Is this key from a first run that has committed nothing?** The question
/// arises only here, because Android creates its Keystore alias at the first
/// commit and never before (`TextEngine.java:265-273`), while this client
/// creates the Keychain item while opening, before the user has decided
/// anything. A first run that closes the Welcome screen without «Создать ID»
/// therefore leaves exactly a key and no file — an interrupted first run, not
/// evidence of tampering, and freezing it would be a permanent freeze reached
/// by doing nothing wrong. But the same two observations describe the one
/// case this whole rule exists to refuse: a key whose file has gone missing.
/// The answer that opens the client — `.fresh` on the key that is already
/// there — is the one answer in this type that could put a new identity over
/// an old one, so it is never inferred from what the container does *not*
/// say. The previous form of this rule recorded "a state file has been
/// committed here" and read its absence as proof that none was; the owner's
/// reviewer showed the flaw in one sentence. That record was a defaults
/// write, the file it described was `F_FULLFSYNC`ed, and the two are lost by
/// different accidents: a record that never persisted, or a preferences domain
/// rolled back, leaves a container whose file has gone missing looking
/// exactly like one that never had a file. The absence of a record is not
/// evidence that the event did not happen.
///
/// So the fact is inverted. What the container records is
/// `paranoid.firstrun.pending.v1`, "this container was opened and has not
/// committed a state file yet": written by the launch that finds the
/// container holding neither a key nor a file, the one moment at which that
/// sentence is an observation, and written *before* that launch creates the
/// key, so no key is made for a container that could not say why it has one.
/// The first commit withdraws it at the last moment it is still certainly
/// true — after the candidate is written and synced, before the rename that
/// would make it false (`SnapshotStore.commit`) — because a positive fact is
/// only worth its strength if it is never on disk while false. A key with no
/// file is then read on the container's own word alone: the fact present is
/// the interrupted first run and opens on that key; the fact absent is a
/// history this container cannot vouch for, and it freezes with the key kept.
/// Every way of losing the fact — a write that never persisted, a domain
/// restored from before the first launch, an installation from a build that
/// never wrote it — lands in that same row and produces a freeze, which a
/// person can resolve, instead of an identity that nobody can undo. The
/// upgrade needs no rule of its own: a container from an earlier build holds
/// no such fact, so its key without a file freezes, which is what the previous
/// form promised it.
///
/// What is left, stated so that nobody has to rediscover it: the fact can also
/// be *stale* — still present after the commit that withdrew it, because the
/// withdrawal is a defaults write too, acknowledged in this process and
/// persisted by another. A stale fact beside a key whose file is then lost
/// would read as the interrupted first run. Withdrawing before the rename
/// keeps the fact off the disk while false, so what remains of that is a
/// withdrawal that was acknowledged and never persisted, exposed until the
/// next launch that opens the file withdraws it again — best effort there,
/// while a container whose defaults refuse the withdrawal at the commit
/// breaks the store with nothing renamed, so no identity is ever adopted by a
/// container that cannot stop claiming it has none. Closing that means a fact
/// that lives where the key lives, or a key that is not created until the
/// first commit as Android's is; both change more than this rule and are the
/// owner's call.
///
/// The fact also comes back with a preferences domain rolled back to a copy
/// taken between the first launch and the first commit. That interval is not
/// short — an interrupted first run lasts until the user returns to «Создать
/// ID», which can be days — and the platform's own copy of it is a backup
/// restored onto the device it was taken from, on any later day and by the
/// user's own hand: it brings the fact back, an encrypted backup brings the
/// `ThisDeviceOnly` key back with it, and the excluded file does not come
/// back at all. Nothing kept on the device tells that launch from the
/// interrupted first run, because the restore took every store this rule
/// reads back to the same moment, and neither design above refuses it
/// either: a fact on the Keychain item is restored with the item, and a key
/// created at the first commit is absent from the copy, which is the row
/// below that holds neither half. What the restore costs is the identity it
/// had already discarded with the file — the cost the accepted restore onto
/// a new iPhone carries too, with the key reused instead of new — and what
/// the launch after it lacks is the visible refusal.
///
/// The resulting matrix:
///
/// | marker | pending | key | file | outcome |
/// | --- | --- | --- | --- | --- |
/// | absent | — | any | present | `.frozen`, nothing deleted, nothing recorded |
/// | absent | — | stale | absent | key deleted, marker and pending fact recorded, `.fresh` |
/// | present | present | present | absent | `.fresh` on the key that is there: the interrupted first run, on the container's own word |
/// | present | absent | present | absent | `.frozen`, key kept: a container that committed a file, one whose fact was lost, and an installation from a build before this rule all land here, and none is told apart |
/// | present | any | absent | present | `.frozen`; nothing withdrawn, so the refusal is the same on every later launch |
/// | present | any | absent | absent | pending fact recorded, `.fresh` (iCloud restore onto a new iPhone: the defaults came back, the `ThisDeviceOnly` key and the excluded file did not) |
/// | present | any | present | present | `.retained`, the ordinary launch; a pending fact found beside the file is withdrawn, best effort |
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
        /// No state file, and either no key or a key the container vouches
        /// for as its own interrupted first run's: create the key where there
        /// is none, reuse it where there is, and register a new identity. It
        /// is the one answer in this type that can start an identity over a
        /// key, which is why `start(...)` never infers it from what the
        /// container does not say.
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
    /// 4. A file beside its key is opened, and a pending fact found beside
    ///    them is withdrawn; a file without its key freezes and touches
    ///    nothing; a container that holds neither half records that it holds
    ///    nothing, before the caller creates the key; and a key alone opens
    ///    only on that record.
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
            let outcome = continuity(snapshotExists: true, keyExists: keyExists)
            if outcome == .retained {
                // A state file is the commit itself, so a pending fact beside
                // it has outlived the withdrawal that was acknowledged and
                // never persisted. Best effort, unlike the same call inside a
                // commit: this launch holds both halves and regenerates
                // nothing, so refusing it would trade a usable client for the
                // frozen screen — whose only exit for a user is the reinstall
                // that destroys the identity being protected — over a repair
                // the next launch would attempt again. Where the withdrawal
                // has to be kept is the commit that ends the first run, and
                // there it breaks the store with nothing renamed. A file
                // without its key is `.frozen` and left untouched: that
                // freeze too is the same on every later launch, and nothing
                // reads the fact from that state anyway — the file decides
                // while it is there, and once it is gone the container holds
                // neither half and records the fact afresh.
                try? marker.withdrawPendingFirstRun()
            }
            return outcome
        }
        guard keyExists else {
            // Neither half: there is nothing left to protect and nothing left
            // to lose, and "nothing has been committed here" is an observation.
            // It is recorded before the caller creates the key, so that a key
            // never precedes the fact that explains it.
            try marker.recordPendingFirstRun()
            return .fresh
        }
        // A key on its own opens the client on the container's own word alone.
        // Every silence — a fact never written, not persisted, or written by
        // no build this container has seen — freezes, with the key kept and
        // nothing recorded, so the refusal is the same on every later launch.
        return marker.isFirstRunPending ? .fresh : .frozen
    }
}
