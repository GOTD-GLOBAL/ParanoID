/// How long a lane waits after a failure before it tries the same thing again.
///
/// `min(30 s, 0.5 s · 2^min(n, 5)) + rand(0…250 ms)`, which is
/// `RealtimeLoop.java:285` with its two halves named: the doubling step and
/// the jitter. The step reaches 0.5, 1, 2, 4, 8 and 16 seconds and then stays
/// at 16 seconds for every further failure, so a server that is down does not
/// see an accelerating client and a client that is wrong about the server does
/// not wait minutes before noticing that it is not.
///
/// The jitter is what keeps a fleet from retrying in lockstep after a shared
/// outage: every device adds up to 250 ms of its own. It is drawn from the
/// system random source and never from a seed derived from the identity, so it
/// carries nothing about the device.
///
/// The ceiling is stated because the formula says so; with five doublings the
/// step tops out at 16 seconds and never reaches it. The one difference from
/// Android is where the sequence starts: `RealtimeLoop.java:238,281` passes
/// `++failures`, so its first wait is 1 second, while the first wait here is
/// 0.5 second for `failures == 0`. A lane counts its own failures from zero
/// and hands the count in unchanged.
public enum Backoff {
    /// The wait after the first failure, and the unit every step doubles.
    public static let first: UInt64 = 500_000_000
    /// The ceiling of the doubling step (`RealtimeLoop.java:285`).
    public static let ceiling: UInt64 = 30 * MonotonicClock.nanosecondsPerSecond
    /// The exclusive bound of the random part.
    public static let jitter: UInt64 = 250_000_000
    /// How many times the step may double before it stops growing.
    public static let doublings = 5

    /// The delay for `failures` consecutive failures, with the jitter given.
    ///
    /// - Parameters:
    ///   - failures: how many times in a row this lane has failed, counted
    ///     from zero. A negative count is read as zero.
    ///   - jitter: the random part, in nanoseconds; anything at or above
    ///     `Backoff.jitter` is clamped just below it, so the result is always
    ///     less than one full jitter above the step.
    public static func delay(failures: Int, jitter: UInt64) -> UInt64 {
        let steps = min(max(failures, 0), doublings)
        let step = min(ceiling, first << UInt64(steps))
        return step + min(jitter, Self.jitter - 1)
    }

    /// The delay for `failures` consecutive failures, with a fresh random
    /// jitter from the system source.
    public static func delay(failures: Int) -> UInt64 {
        delay(failures: failures, jitter: UInt64.random(in: 0..<jitter))
    }
}
