import Foundation

/// When to ask the pinned server what it can do, and what the last answer was.
///
/// `GET /health` is capability discovery and nothing else: it is not
/// authority, not a readiness claim about the database and never a reason to
/// change identity or trust (`docs/protocol/realtime-v1.md:158-161`). The
/// answer itself is read by `Health`, which is the one place the `status`,
/// `protocol` and `realtime` members are interpreted; what this type adds is
/// the cadence of `RealtimeLoop.java:195-200` — once at the start of a
/// connection, then every 60 seconds, and immediately whenever a lane
/// invalidates it.
///
/// Those invalidations are the 404/unknown-route and failed-renewal cases of
/// `docs/protocol/realtime-v1.md:172-177`; the mapping from a status code to
/// `invalidate()` belongs to the lane that sees the code, not here.
///
/// Timing is monotonic (`MonotonicClock`): a device that slept for an hour is
/// due for rediscovery the moment it wakes, not an hour later.
public struct HealthDiscovery: Sendable {
    /// The only unauthenticated route this client ever requests.
    public static let path = "/health"
    /// How long one answer is believed (`RealtimeLoop.java:195`).
    public static let interval: UInt64 = 60 * MonotonicClock.nanosecondsPerSecond

    /// Whether the last answer carried the realtime capability. `false` until
    /// a server has said so, so a client that has discovered nothing yet never
    /// assumes a session route exists.
    public private(set) var realtime = false
    /// Whether a lane asked for rediscovery before the interval elapsed.
    public private(set) var isInvalidated = true

    private var checkedAt = MonotonicInstant(nanoseconds: 0)

    public init() {}

    /// Marks the cached capability stale: the next connection rediscovers
    /// before it uses a session (`RealtimeLoop.java:188,207,215`).
    public mutating func invalidate() {
        isInvalidated = true
    }

    /// Whether `GET /health` must be sent before this connection continues.
    public func isDue(at now: MonotonicInstant) -> Bool {
        isInvalidated || now.nanoseconds(since: checkedAt) > Self.interval
    }

    /// Applies one `/health` reply and returns whether the session transport
    /// is available.
    ///
    /// - Throws: `TransportError.protocolMismatch` for a server that is not
    ///   this protocol or does not report itself ready. A rejected reply
    ///   leaves the previous verdict and the previous timestamp untouched, so
    ///   a server that starts answering something else does not silently
    ///   extend the life of the capability it used to have.
    @discardableResult
    public mutating func accept(_ reply: [String: Any], at now: MonotonicInstant) throws -> Bool {
        realtime = try Health.parse(reply).realtime
        isInvalidated = false
        checkedAt = now
        return realtime
    }
}
