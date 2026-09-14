import Foundation

/// What the container remembers about itself, which is what separates a first
/// launch of this installation from a first launch of this *device*.
///
/// It exists because of one iOS fact that Android does not have: deleting the
/// application removes the container — `Application Support/paranoid/` and the
/// user defaults with it — while a Keychain item survives. Without a marker
/// the first launch after a reinstall would find no state file and a perfectly
/// valid wrapping key, which `StorageGuard` must read as a broken retained
/// state and freeze. The marker turns that case back into what it is: a clean
/// install (D-004), whose stale key is deleted before anything else happens.
///
/// There are two facts, both in the standard user defaults, because each of
/// them has to disappear exactly when the container does, and neither holds a
/// secret. They are read in opposite directions, and that is the whole design:
///
/// - `paranoid.install.v1`: this container has been launched before. Its
///   *absence* is read as evidence — of a reinstall — and that reading is
///   safe only because a state file overrules it (`StorageGuard`): the one act
///   the absence licenses, deleting a key, is refused wherever a file could
///   still need that key.
/// - `paranoid.firstrun.pending.v1`: this container was opened and has not
///   committed a state file yet. Only its *presence* is evidence. It is the
///   fact behind the one row in which a key with no file opens the client
///   instead of freezing it, and it is deliberately a statement of innocence
///   rather than of guilt. Android never needs it, because it creates its
///   Keystore alias at the first commit and not before
///   (`TextEngine.java:265-273`, reached only from `persist`), so a key it
///   finds always belongs to a snapshot that once existed. This client creates
///   the Keychain item while opening, before the user has decided to create an
///   identity at all, so a key alone says nothing; what says something is the
///   container's own word, given before that key existed, that nothing has
///   been committed here.
///
/// The previous form of this rule kept the opposite fact — "a state file has
/// been committed here" — and read its absence as proof that none was. The
/// owner's reviewer showed in one sentence why that cannot hold: the fact is a
/// defaults write, the file it speaks of is an `F_FULLFSYNC`ed file, and the
/// two are lost by different accidents, so a write that never persisted, or a
/// preferences domain rolled back, left a container whose file had gone
/// missing indistinguishable from one that never had a file. The absence of a
/// record is not evidence that the event did not happen. Read the other way
/// round, every loss lands on the safe side: a pending fact that is missing —
/// never written, not persisted, restored from before the first launch, or
/// never written at all by a build that predates it — freezes a key with no
/// file, and only the fact's presence opens it.
///
/// The second fact is never trusted on a container whose first is gone:
/// whatever loses a whole defaults domain loses `paranoid.install.v1` with it,
/// and that is the branch which refuses to touch anything at all.
public struct InstallMarker {
    /// The defaults key. Versioned, so that a future marker rule can be told
    /// apart from this one instead of silently reinterpreting it.
    public static let key = "paranoid.install.v1"
    /// The defaults key of the second fact, versioned for the same reason.
    public static let pendingKey = "paranoid.firstrun.pending.v1"

    private let defaults: UserDefaults

    /// - Parameter defaults: the standard suite in the application; the tests
    ///   pass a scratch suite so that a run leaves nothing behind.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether this container has been launched before.
    ///
    /// Any stored value counts, not only `true`: the question is whether the
    /// key exists, exactly the `marker == nil` test of the startup rule.
    public var isPresent: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    /// Records the marker, and verifies it is readable.
    ///
    /// A marker that cannot be stored would make the next launch delete the
    /// key this launch is about to create and use, so the failure is reported
    /// rather than ignored.
    ///
    /// - Throws: `StorageError.installMarkerUnavailable`.
    public func record() throws {
        defaults.set(true, forKey: Self.key)
        guard defaults.object(forKey: Self.key) != nil else {
            throw StorageError.installMarkerUnavailable
        }
    }

    /// Whether this container has said, before its key existed, that it has
    /// committed nothing.
    public var isFirstRunPending: Bool {
        defaults.object(forKey: Self.pendingKey) != nil
    }

    /// Records that fact, and verifies it is readable.
    ///
    /// Called by the launch that finds the container holding neither a key
    /// nor a state file — the one moment at which "nothing has been committed
    /// here" is an observation rather than an assumption — and before that
    /// launch creates the key, so that no key is made for a container that
    /// could not say why it has one.
    ///
    /// A fact that cannot be stored is reported for the same reason
    /// `record()` reports its own: the launch after this one would find a
    /// key, no file and no explanation, and freeze a container that did
    /// nothing wrong. Throwing here costs the same freeze one launch earlier,
    /// before any key exists, and «Повторить открытие» simply tries again.
    ///
    /// - Throws: `StorageError.installMarkerUnavailable`.
    public func recordPendingFirstRun() throws {
        defaults.set(true, forKey: Self.pendingKey)
        guard defaults.object(forKey: Self.pendingKey) != nil else {
            throw StorageError.installMarkerUnavailable
        }
    }

    /// Withdraws it, and verifies it is gone.
    ///
    /// Called by the first commit at the last moment the fact is still
    /// certainly true — after the candidate is written and synced, before the
    /// rename that would make it false (`SnapshotStore.commit`) — and by every
    /// launch that opens a state file beside its key and finds the fact still
    /// standing, where it has outlived the commit that should have withdrawn
    /// it. A fact that is still readable after this is reported, because a
    /// container that goes on claiming it has committed nothing would open a
    /// fresh identity over a file that had gone missing. What each caller
    /// does with the report differs, and `StorageGuard.start(...)` says why:
    /// the commit breaks the store with nothing renamed, the launch that
    /// merely repairs goes on.
    ///
    /// - Throws: `StorageError.installMarkerUnavailable`.
    public func withdrawPendingFirstRun() throws {
        guard isFirstRunPending else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        guard defaults.object(forKey: Self.pendingKey) == nil else {
            throw StorageError.installMarkerUnavailable
        }
    }
}
