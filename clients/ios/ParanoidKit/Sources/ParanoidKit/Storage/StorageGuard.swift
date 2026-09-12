import Foundation

/// The rule that decides, before anything is opened, whether this launch may
/// continue, must start clean, or must freeze.
///
/// Android states it in two lines (`StorageGuard.java:7-8`): a retained
/// wrapping key without its snapshot is **not** a fresh installation, and
/// neither is a snapshot without its key; either way nothing is regenerated
/// and the process stops. The exclusive-or is the whole rule, and it holds
/// here unchanged.
///
/// iOS adds one step in front of it, because the Keychain outlives the
/// application container while the state file does not. On a launch with no
/// `InstallMarker` the container is new, so any key found under
/// `paranoid-text-state-v0` belongs to a previous installation: it is deleted,
/// the marker is recorded, and only then is the exclusive-or evaluated — on a
/// key that is now certainly this installation's. That is the reinstall
/// decision (D-004: reinstalling is a clean install with a new identity) and
/// it is reported as a documented platform difference from
/// `docs/clients/core/self-service.md:97-100`, not as a change to the
/// fail-closed rule: no path here ever replaces an existing state file or
/// hands the core a fresh identity while a usable state exists.
///
/// The resulting matrix, for the four launches that occur in practice:
///
/// | marker | key | file | outcome |
/// | --- | --- | --- | --- |
/// | absent | stale | absent | key deleted, marker recorded, `.fresh` |
/// | present | present | absent | `.frozen` |
/// | present | absent | present | `.frozen` |
/// | present | absent | absent | `.fresh` (iCloud restore onto a new iPhone: the
/// defaults came back, the `ThisDeviceOnly` key and the excluded file did not) |
/// | present | present | present | `.retained`, the ordinary launch |
///
/// One row is anomalous rather than practical: an absent marker with **both**
/// a key and a file, which cannot happen while the defaults and the file share
/// one container. The order above handles it fail-closed — the key is deleted,
/// so the exclusive-or is broken and the launch freezes. It never starts a new
/// identity over an existing state file.
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
    /// 1. No marker means a new container, so a key left over from a previous
    ///    installation is deleted first. A failed delete throws and the marker
    ///    is **not** recorded, so the next launch tries again instead of
    ///    treating the stale key as this installation's.
    /// 2. The marker is recorded, which also fixes the answer to step 1 for
    ///    every later launch of this container.
    /// 3. The exclusive-or is evaluated against the Keychain as it now stands.
    ///
    /// `snapshotExists` is read by the caller *before* this runs
    /// (`SnapshotStore.snapshotExists()`); the guard never touches the file.
    ///
    /// - Throws: `StorageError.keychain`,
    ///   `StorageError.installMarkerUnavailable`.
    public static func start(snapshotExists: Bool,
                             marker: InstallMarker,
                             key: KeychainKey = .standard) throws -> Continuity {
        if !marker.isPresent {
            try key.deleteRetained()
            try marker.record()
        }
        return continuity(snapshotExists: snapshotExists, keyExists: try key.exists())
    }
}
