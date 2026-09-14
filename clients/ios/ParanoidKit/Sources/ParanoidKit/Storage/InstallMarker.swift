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
/// There are three facts, all in the standard user defaults, because each of
/// them has to disappear exactly when the container does, and none holds a
/// secret:
///
/// - `paranoid.install.v1`: this container has been launched before;
/// - `paranoid.snapshot.v1`: this container has committed a state file at
///   least once. Android never needs it, because it creates the Keystore alias
///   at the first commit and not before (`TextEngine.java:265-273`, reached
///   only from `persist`), so a key it finds always belongs to a snapshot that
///   once existed. This client creates the Keychain item while opening, before
///   the user has decided to create an identity at all, so a key alone says
///   nothing and this fact is what `StorageGuard` reads instead;
/// - `paranoid.install.v2`: this container has been keeping the fact above
///   since its own first launch. It exists because the absence of
///   `paranoid.snapshot.v1` has two possible meanings and only one of them is
///   safe. On a container this rule opened, absence means "nothing was ever
///   committed here". On a container that some earlier build opened, absence
///   means nothing at all — no build before this one wrote the key, so a
///   container that holds a state file and has held one for days still has no
///   such fact until a launch of this build sees the file. Reading that
///   silence as "nothing was ever committed" is exactly the reinterpretation
///   the version in `paranoid.install.v1` exists to prevent, so the licence to
///   read it is a fact of its own, written by the launch that starts the
///   container's record rather than assumed of every container.
///
/// The last two are never trusted on a container whose first is gone: whatever
/// loses a whole defaults domain loses `paranoid.install.v1` with it, and that
/// is the branch which refuses to touch anything at all.
public struct InstallMarker {
    /// The defaults key. Versioned, so that a future marker rule can be told
    /// apart from this one instead of silently reinterpreting it.
    public static let key = "paranoid.install.v1"
    /// The defaults key of the second fact, versioned for the same reason.
    public static let snapshotKey = "paranoid.snapshot.v1"
    /// The defaults key of the third. `v2` is deliberately a *second* install
    /// key rather than a replacement for `v1`: a container has to stay
    /// "launched before" across the upgrade, or the first launch of this build
    /// would read every existing installation as a reinstall and delete the
    /// wrapping key of its state file.
    public static let recordingKey = "paranoid.install.v2"

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

    /// Records the marker, and verifies it is readable. A container recorded
    /// here is one whose whole history this rule has seen, so it starts
    /// keeping the commit record too (``beginRecordingCommits()``).
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
        beginRecordingCommits()
    }

    /// Whether this container's commits have been recorded from its first
    /// launch onwards, which is what makes a missing
    /// `paranoid.snapshot.v1` mean "nothing was committed here" rather than
    /// "nobody was writing it down yet".
    public var recordsCommits: Bool {
        defaults.object(forKey: Self.recordingKey) != nil
    }

    /// Starts that record, on a launch that can see the container hold
    /// nothing: its very first, or one that finds neither a key nor a state
    /// file. Both are moments at which "nothing has been committed here" is an
    /// observation rather than an assumption.
    ///
    /// Nothing calls it on a container that already holds a state file, and
    /// that is the whole of the upgrade rule: an installation from an earlier
    /// build keeps the stricter reading — a key with no file freezes — until
    /// it has been through a launch with nothing left to protect.
    ///
    /// It cannot throw. A container that fails to keep it is read as an
    /// installation from before this rule, which is the fail-closed side: the
    /// cost is a freeze that a person can investigate, never a key deleted or
    /// a state file replaced.
    public func beginRecordingCommits() {
        defaults.set(true, forKey: Self.recordingKey)
    }

    /// Whether a state file has ever been committed in this container.
    public var hasCommittedSnapshot: Bool {
        defaults.object(forKey: Self.snapshotKey) != nil
    }

    /// Records that a state file exists, and verifies it is readable.
    ///
    /// Written by the commit that created the file and by every launch that
    /// finds one, so that a launch which later finds the file *gone* freezes
    /// instead of reading the leftover key as an interrupted first run. The
    /// failure is reported for the same reason `record()` reports its own: a
    /// fact about retained data that cannot be kept would be answered wrongly
    /// by the next launch. What each caller does with the report differs, and
    /// `StorageGuard.start(...)` says why: the commit that creates the fact
    /// breaks the store, while the launch that merely repeats it goes on.
    ///
    /// - Throws: `StorageError.installMarkerUnavailable`.
    public func recordCommittedSnapshot() throws {
        guard !hasCommittedSnapshot else { return }
        defaults.set(true, forKey: Self.snapshotKey)
        guard defaults.object(forKey: Self.snapshotKey) != nil else {
            throw StorageError.installMarkerUnavailable
        }
    }

    /// Forgets that fact, on a launch that holds neither a key nor a file.
    ///
    /// It is what makes an iCloud restore onto a new iPhone start cleanly: the
    /// defaults come back from the backup, the `ThisDeviceOnly` key and the
    /// excluded state file do not, and the restored fact would otherwise
    /// freeze the *next* launch of a container that has nothing left to
    /// protect. It cannot throw, because failing to forget only freezes a
    /// later launch — it deletes nothing.
    public func forgetCommittedSnapshot() {
        defaults.removeObject(forKey: Self.snapshotKey)
    }
}
