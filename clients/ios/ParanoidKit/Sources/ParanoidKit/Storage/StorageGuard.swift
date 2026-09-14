import Foundation

/// Marker-present continuity is strict key/file XOR. The application does not
/// persist a wrapping key on Welcome, so an ordinary untouched first run has
/// neither half. No defaults entry can excuse a retained key without its file.
///
/// The original install.v1 reinstall distinction remains proposed in ADR-0014:
/// absent marker + absent snapshot removes a stale reinstall key; absent marker
/// + present snapshot freezes before any mutation. Combined loss of the entire
/// container remains indistinguishable from reinstall; no recovery is promised.
public enum StorageGuard {
    public static let account = KeychainKey.account
    public enum Continuity: Equatable, Sendable { case fresh, retained, frozen }

    public static func continuity(snapshotExists: Bool, keyExists: Bool) -> Continuity {
        guard snapshotExists == keyExists else { return .frozen }
        return snapshotExists ? .retained : .fresh
    }
    public static func requireContinuity(snapshotExists: Bool, keyExists: Bool) throws {
        guard continuity(snapshotExists: snapshotExists, keyExists: keyExists) != .frozen else {
            throw StorageError.frozen
        }
    }

    /// Never creates a key. Old pending/install.v2/snapshot.v1 values are ignored.
    /// A partial first commit (key created, no committed file) deliberately
    /// freezes just like lost retained state; no automatic reset or key cleanup.
    public static func start<Key: RetainedKey>(snapshotExists: Bool,
                                               marker: InstallMarker,
                                               key: Key = KeychainKey.standard) throws -> Continuity {
        if !marker.isPresent {
            guard !snapshotExists else { return .frozen }
            try key.deleteRetained()
            try marker.record()
        }
        return continuity(snapshotExists: snapshotExists, keyExists: try key.exists())
    }
}
