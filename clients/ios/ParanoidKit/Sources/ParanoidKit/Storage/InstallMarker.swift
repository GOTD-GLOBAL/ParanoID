import Foundation

/// The flag that separates a first launch of this installation from a first
/// launch of this *device*.
///
/// It exists because of one iOS fact that Android does not have: deleting the
/// application removes the container — `Application Support/paranoid/` and the
/// user defaults with it — while a Keychain item survives. Without a marker
/// the first launch after a reinstall would find no state file and a perfectly
/// valid wrapping key, which `StorageGuard` must read as a broken retained
/// state and freeze. The marker turns that case back into what it is: a clean
/// install (D-004), whose stale key is deleted before anything else happens.
///
/// The marker lives in the standard user defaults because it has to disappear
/// exactly when the container does, and it holds no secret: its presence says
/// only that this container has been launched once.
public struct InstallMarker {
    /// The defaults key. Versioned, so that a future marker rule can be told
    /// apart from this one instead of silently reinterpreting it.
    public static let key = "paranoid.install.v1"

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
}
