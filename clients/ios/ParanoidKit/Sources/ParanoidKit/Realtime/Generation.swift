/// One run of the realtime lanes.
///
/// Android keeps the number as a `volatile long` on the loop and every lane
/// carries the one it started under (`RealtimeLoop.java:36-37,53-56`):
/// `start()` and `stop()` move it, and anything that comes back from the
/// network under an older number grants no authority at all. It is dropped
/// instead of being applied — "immutable requests and generation/cursor
/// revalidation when network results return"
/// (`docs/protocol/realtime-v1.md:127-130`).
///
/// It is a value and not a reference on purpose: a lane that captured one
/// cannot be handed a newer number behind its back, and `StateOwner` is the
/// only thing that mints them.
public struct Generation: Hashable, Sendable, CustomStringConvertible {
    /// The run number. It only ever grows.
    public let run: UInt64

    public init(run: UInt64) {
        self.run = run
    }

    /// The next run.
    ///
    /// The counter saturates instead of wrapping: a wrapped counter would make
    /// a lane that has been stopped for 2^64 runs current again, which is the
    /// one way a generation check can fail open.
    public var next: Generation {
        Generation(run: run == .max ? .max : run + 1)
    }

    public var description: String { "run \(run)" }
}

/// Why a lane stopped: the generation it was started under is no longer the
/// current one, or the loop was stopped or closed under it.
///
/// It is Android's `InterruptedException` from `guard(long)`
/// (`RealtimeLoop.java:67`) with the run it refers to kept, so a lane can say
/// which of its own results it threw away. A lane treats it as "this work no
/// longer belongs to anyone": it is never published, never committed and never
/// reported to the user as a failure.
public struct Superseded: Error, Equatable, Sendable, CustomStringConvertible {
    /// The run the caller believed it was in.
    public let run: UInt64

    public init(_ generation: Generation) {
        self.run = generation.run
    }

    public var description: String { "superseded generation (run \(run))" }
}
