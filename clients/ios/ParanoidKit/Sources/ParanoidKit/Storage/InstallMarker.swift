import Foundation

/// Retains the existing install.v1 meaning: this application container has
/// been opened. A surviving snapshot overrules a missing marker and freezes
/// before key deletion. Same-process readback is not a durability guarantee.
/// No first-run/commit fact is used: a persistent key is created only at commit.
public struct InstallMarker {
    public static let key = "paranoid.install.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isPresent: Bool { defaults.object(forKey: Self.key) != nil }
    public func record() throws {
        defaults.set(true, forKey: Self.key)
        guard isPresent else { throw StorageError.installMarkerUnavailable }
    }
}
