import Darwin

/// One reading of the monotonic timeline.
///
/// The origin is arbitrary and only differences between two instants mean
/// anything; an instant is never compared with a wall-clock date, because
/// "local wall-clock skew is not a reason to extend server authority"
/// (`docs/protocol/realtime-v1.md:181`).
public struct MonotonicInstant: Comparable, Hashable, Sendable {
    /// Nanoseconds since that origin.
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// The distance from `earlier` to this instant.
    ///
    /// A monotonic source never runs backwards, so the clamp to zero can only
    /// ever hide a caller that passed its two arguments the wrong way round;
    /// it exists so that no interval in this client can underflow into a
    /// 584-year wait.
    public func nanoseconds(since earlier: MonotonicInstant) -> UInt64 {
        nanoseconds >= earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
    }

    /// This instant moved forward, saturating rather than wrapping.
    public func advanced(byNanoseconds delta: UInt64) -> MonotonicInstant {
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        return MonotonicInstant(nanoseconds: overflow ? .max : sum)
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

/// The one clock every interval in this client is measured on:
/// `mach_continuous_time()`.
///
/// Three things are timed against it — the 600 ms spacing between two
/// challenges, the 60-second `/health` rediscovery and the 240/300-second
/// session renewal and lifetime (`docs/protocol/realtime-v1.md:33,179-181`) —
/// and all three are wrong if the reading stops. `mach_continuous_time()` is
/// the only Darwin source that keeps counting while the device is asleep; the
/// media time of the animation framework and the raw uptime clock of
/// `clock_gettime_nsec_np` both freeze on suspend, so a phone that slept for
/// ten minutes would come back believing its 300-second session were still
/// young and would sign requests against a context the server has already
/// dropped. They are therefore not used anywhere in this package, and
/// `ProofFlowTests` greps the sources to keep it that way. `Date` is not a
/// candidate either: it moves when the user or a time server moves it.
///
/// The reading is a closure and the timebase is stored, so a test drives the
/// same code over a fake source (`RealtimeLoopTests`, `StateOwnerTests`) and
/// the conversion is exercised for a timebase that is not 1/1 — on Apple
/// silicon `mach_timebase_info` reports 125/3, so ticks are not nanoseconds
/// and dividing them wrongly would scale every interval by 40.
public struct MonotonicClock: Sendable {
    public static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    private let source: @Sendable () -> UInt64
    private let numerator: UInt64
    private let denominator: UInt64

    /// - Parameters:
    ///   - numerator: `mach_timebase_info.numer`, or 1 for a source that
    ///     already counts nanoseconds (a fake one, for instance).
    ///   - denominator: `mach_timebase_info.denom`; zero is refused and read
    ///     as 1, because a division by it would trap.
    ///   - source: the raw tick reading.
    public init(numerator: UInt64 = 1,
                denominator: UInt64 = 1,
                source: @escaping @Sendable () -> UInt64) {
        self.numerator = max(numerator, 1)
        self.denominator = max(denominator, 1)
        self.source = source
    }

    /// The device clock: ticks that keep advancing across sleep, scaled by the
    /// timebase of this machine.
    public static let continuous: MonotonicClock = {
        var timebase = mach_timebase_info_data_t()
        let known = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0
        return MonotonicClock(numerator: known ? UInt64(timebase.numer) : 1,
                              denominator: known ? UInt64(timebase.denom) : 1) {
            mach_continuous_time()
        }
    }()

    /// The current reading.
    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: nanoseconds(fromTicks: source()))
    }

    /// `ticks * numerator / denominator`, without the intermediate overflow
    /// the obvious form has: the product of a tick count taken a year after
    /// boot and a numerator of 125 does not fit the range the naive
    /// multiplication needs, so the division is split into a whole part and a
    /// remainder, which is exact for every input.
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        guard numerator != denominator else { return ticks }
        let (whole, overflow) = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        guard !overflow else { return .max }
        let (total, carry) = whole.addingReportingOverflow(ticks % denominator * numerator / denominator)
        return carry ? .max : total
    }
}
