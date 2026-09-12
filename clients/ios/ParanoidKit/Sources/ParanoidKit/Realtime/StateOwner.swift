import Dispatch

/// The single owner of the client state: the port of `TextEngine.worker`
/// (`clients/android/src/org/paranoid/text/TextEngine.java:33`), which is one
/// thread and one thread only.
///
/// Everything that reads or moves the core state text runs here, and nothing
/// else does: every `paranoid_core_command` call, every commit through
/// `SnapshotSink`, the realtime session and the capability the server
/// advertised. "Ratchets retain one owner; networking has separate send/wait
/// lanes and bounded handoff, with immutable requests and generation/cursor
/// revalidation when network results return"
/// (`docs/protocol/realtime-v1.md:127-130`) is the rule this type exists for,
/// and it is enforced two ways:
///
/// - **No method of this actor is `async`.** The owner therefore cannot await
///   a network call: a lane hands it a finished answer, the owner applies it
///   without suspending, and the next lane's work starts on a state that is
///   already durable. The compiler checks this — an `await` inside the actor
///   would need an `async` member to hold it.
/// - **The executor is a named serial queue**, so "am I on the owner?" is a
///   question with an answer at runtime (`isOnOwner`). `perform` asserts it,
///   and a test asserts the other direction: no network call ever observes
///   itself running here.
///
/// A lane is a `Task`. It never waits inside this actor, and this actor never
/// waits for a lane: the two meet only at `perform`, which runs one closure
/// against the client and returns.
///
/// ## Generations
///
/// `start()` and `stop()` move a run counter (`RealtimeLoop.java:36-37,53-56`)
/// and every lane carries the `Generation` it started under. A result that
/// returns from the network under a superseded run is refused by `check(_:)`
/// and `perform(_:_:)` with `Superseded` before it can touch the state, which
/// is the revalidation the protocol asks for. `start()` on a loop that is
/// already enabled is a no-op: it mints no generation, so a second
/// `didBecomeActive` does not restart lanes that are already running.
///
/// ## The session belongs here, not to a generation
///
/// A realtime session is scoped to the account, device, realm, pin and
/// credential (`docs/protocol/realtime-v1.md:38-41`), it lives 300 seconds
/// from its monotonic receipt and it is renewed at 240 seconds
/// (`:179-181`), and the server allows **two** live sessions per account
/// (`server/src/self_service_http.rs:377-391`). Those two slots are what
/// renewal uses, so a client that dropped its session on every pause would
/// spend them on nothing and meet `session_capacity` instead of talking. The
/// session is therefore owned by this object and survives `stop()`, `start()`
/// and any number of generations; a new generation reuses one that is younger
/// than 240 seconds. It is dropped only when it has actually stopped being
/// usable: a second 401, a 404, `session_exhausted`, a server that no longer
/// advertises the capability, or renewal — the mapping from a rejection to
/// `dropSession()` is the lane's, because the same status means different
/// things in the send and the receive lane (`RealtimeLoop.java:181,191,207`).
/// The server rechecks the whole binding — account, device, auth key,
/// fingerprint and credential — before every operation and answers a generic
/// 401 for any changed binding or revoked account
/// (`docs/protocol/realtime-v1.md:83-91`), which is why a repeated 401 means
/// the session is gone and never means that anything may be relaxed.
///
/// The session context itself is public material, not a bearer credential
/// (`:38-42`): every operation still has to be signed by the key the core
/// holds. It is kept in memory only and never written to the snapshot, so a
/// restart drops it on both sides.
public actor StateOwner {
    // MARK: - The owner's own executor

    /// The key that answers "is this thread the owner's?": one token for the
    /// whole process, created once and only ever compared.
    private static let key = DispatchSpecificKey<UInt64>()

    /// The one serial queue every isolated member of this actor runs on: the
    /// counterpart of `Executors.newSingleThreadExecutor()`.
    private nonisolated let queue: DispatchSerialQueue
    /// This owner's mark on that queue. Two owners in one process (the host
    /// fixture opens five) must not answer `isOnOwner` for each other.
    private nonisolated let mark: UInt64

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Whether the caller is running on this owner right now.
    ///
    /// True inside every isolated member, false everywhere else — including in
    /// a lane that is awaiting the network, which is what makes "the network
    /// never calls the core" checkable rather than merely intended.
    public nonisolated var isOnOwner: Bool {
        DispatchQueue.getSpecific(key: Self.key) == mark
    }

    // MARK: - What is owned

    /// The state adapter, reached from nowhere but the isolated members below.
    ///
    /// `SelfServiceClient` is a plain class and is not `Sendable`, which is
    /// what makes this a one-way door: the client has to be handed over in the
    /// expression that builds it, because a caller that kept a reference could
    /// not pass it here at all. That is exactly the rule this type exists for.
    private let client: SelfServiceClient
    private let clock: MonotonicClock
    private let hook: any PushHook

    private var enabled = false
    private var closed = false
    private var run = Generation(run: 0)
    private var held: SessionModel?
    private var discovery = HealthDiscovery()
    private var sessionsHeldUntil: MonotonicInstant?

    /// - Parameters:
    ///   - client: the state adapter. This object becomes its only caller:
    ///     nothing outside may keep a reference and use it, because the
    ///     serialization this actor provides is the only thing between two
    ///     lanes and one ratchet.
    ///   - clock: the monotonic clock every interval is measured on.
    ///   - hook: the wake seam; `NoPushHook` in the shipped client.
    public init(client: SelfServiceClient,
                clock: MonotonicClock = .continuous,
                hook: any PushHook = NoPushHook()) {
        let mark = UInt64.random(in: 1...UInt64.max)
        let queue = DispatchSerialQueue(label: "global.paranoid.state-owner")
        queue.setSpecific(key: Self.key, value: mark)
        self.queue = queue
        self.mark = mark
        self.client = client
        self.clock = clock
        self.hook = hook
    }

    // MARK: - Lifecycle and generations

    /// The generation a lane may act under, or `nil` when the loop is stopped
    /// or closed (`RealtimeLoop.current(long)`, `:66`).
    public var current: Generation? {
        enabled && !closed ? run : nil
    }

    /// Starts the lanes, minting a new generation only if they were stopped
    /// (`RealtimeLoop.java:53`).
    ///
    /// The wake seam is signalled whether or not a generation was minted,
    /// exactly as Android's `start()` ends with `kick()`: a loop that is
    /// already running is asked to run a cycle now rather than to restart. A
    /// closed owner does neither.
    ///
    /// - Returns: the generation in force after the call.
    @discardableResult
    public func start() -> Generation {
        guard !closed else { return run }
        if !enabled {
            enabled = true
            run = run.next
        }
        hook.wake()
        return run
    }

    /// Pauses the lanes (`RealtimeLoop.java:55-56`).
    ///
    /// The generation moves, so every result still in flight is refused when
    /// it comes back. The session, the discovered capability and the state
    /// stay exactly as they are: stopping is a pause, not a reset.
    public func stop() {
        guard !closed else { return }
        enabled = false
        run = run.next
    }

    /// Ends this loop for good (`RealtimeLoop.close()`, `:295`). Nothing can
    /// be started again on this owner.
    public func close() {
        guard !closed else { return }
        closed = true
        enabled = false
        run = run.next
    }

    /// Whether `generation` is still the one the lanes are running.
    public func isCurrent(_ generation: Generation) -> Bool {
        enabled && !closed && run == generation
    }

    /// `RealtimeLoop.guard(long)` (`:67`): refuses to let a superseded lane
    /// continue.
    public func check(_ generation: Generation) throws {
        guard isCurrent(generation) else { throw Superseded(generation) }
    }

    /// Asks the wake seam to run a cycle now (`RealtimeLoop.kick()`, `:54`).
    public nonisolated func wake() {
        hook.wake()
    }

    // MARK: - Every bridge call and every commit

    /// Whether the last commit failed. A frozen client is terminal for the
    /// rest of the process (`SelfServiceClient.isBroken`).
    public var isFrozen: Bool { client.isBroken }

    /// Runs one operation against the client, on the owner.
    ///
    /// It is `RealtimeLoop.state(long, Callable)` (`:68-77`) with the same
    /// three rules in the same order: the generation is checked before the
    /// work starts, a frozen client refuses to do anything at all, and a
    /// failure that froze the client also stops the lanes, because a client
    /// that cannot persist must not keep talking to a server.
    ///
    /// `T` is `Sendable` and the closure is `sending`, which is what keeps the
    /// state itself inside: a lane can carry out a decision, a count or a
    /// signed request, and it can never carry out the client, a decoded core
    /// reply or anything else that two tasks could then race on.
    ///
    /// - Parameters:
    ///   - generation: the run this work belongs to; `nil` for work that does
    ///     not belong to a lane, such as the user creating an identity.
    ///   - body: the operation, run on the owner.
    /// - Throws: `Superseded`, `SelfServiceError.frozen`, or whatever the
    ///   operation throws.
    @discardableResult
    public func perform<T: Sendable>(_ generation: Generation? = nil,
                                     _ body: sending (SelfServiceClient) throws -> T) throws -> T {
        precondition(isOnOwner, "every bridge call runs on the state owner")
        if let generation { try check(generation) }
        guard !client.isBroken else { throw SelfServiceError.frozen }
        do {
            return try body(client)
        } catch {
            // "Any failure sets isBroken for the rest of the process, so
            // nothing derived from that candidate is adopted or sent"
            // (`TextEngine.java:226-237`): the lanes stop here, and the
            // application is off the network because `updateTrust()` is the
            // only source of a realm and a pin.
            if client.isBroken { enabled = false }
            throw error
        }
    }

    // MARK: - The session and the capability

    /// The held session, whatever its age.
    public var session: SessionModel? { held }

    /// Whether the last `/health` answer carried the realtime capability
    /// (`docs/protocol/realtime-v1.md:159-162`).
    public var isRealtime: Bool { discovery.realtime }

    /// The held session when it may still be used, `nil` when there is none or
    /// it is due for renewal.
    ///
    /// A new generation reuses whatever is younger than 240 seconds on the
    /// monotonic clock; the wall clock is never consulted
    /// (`docs/protocol/realtime-v1.md:179-181`).
    public func reusableSession() -> SessionModel? {
        guard let held, !held.needsRenewal(at: clock.now()) else { return nil }
        return held
    }

    /// Forgets the held session: the second 401, a 404, `session_exhausted`
    /// (`RealtimeLoop.java:191,207`).
    public func dropSession() {
        held = nil
    }

    /// Rediscover the capability before the next connection: the answer to a
    /// 404 on a cached session route and to a failed renewal
    /// (`docs/protocol/realtime-v1.md:172-177`).
    public func invalidateDiscovery() {
        discovery.invalidate()
    }

    /// Whether `GET /health` is due before this connection continues.
    public func isDiscoveryDue() -> Bool {
        discovery.isDue(at: clock.now())
    }

    /// Applies one `/health` answer.
    ///
    /// A server that no longer advertises the capability cannot be talked to
    /// through a session any more, so the held one goes with it — the
    /// "legacy" reset (`RealtimeLoop.java:181`).
    ///
    /// - Returns: whether the session transport is available.
    /// - Throws: `Superseded`, `TransportError.invalidReply` or
    ///   `TransportError.protocolMismatch`; a refused answer leaves the
    ///   previous verdict and its timestamp untouched.
    @discardableResult
    public func applyHealth(_ reply: RealtimeTransport.Reply,
                            under generation: Generation? = nil) throws -> Bool {
        if let generation { try check(generation) }
        let realtime = try discovery.accept(try reply.json(), at: clock.now())
        if !realtime { held = nil }
        return realtime
    }

    /// Stops asking for sessions for a while and uses the challenge transport
    /// meanwhile: the answer to a 429 `session_capacity` on `/v2/session`
    /// (`RealtimeLoop.java:192`). The account is at its two-session cap
    /// (`server/src/self_service_http.rs:377-391`) and hammering the route
    /// would only keep it there.
    public func holdSessions(for nanoseconds: UInt64) {
        sessionsHeldUntil = clock.now().advanced(byNanoseconds: nanoseconds)
    }

    /// Whether the session route is being held off right now. The hold is
    /// forgotten once it has elapsed.
    public func sessionsAreHeld() -> Bool {
        guard let until = sessionsHeldUntil else { return false }
        guard clock.now() < until else {
            sessionsHeldUntil = nil
            return false
        }
        return true
    }

    /// Reads one `POST /v2/session` answer, has the core accept it, and only
    /// then adopts it (`RealtimeLoop.java:186-189`).
    ///
    /// The order is the point. `SessionModel.open` refuses anything that is
    /// not the exact eight-member context of this realm and pin; the core then
    /// compares account, device and credential against the saved identity and
    /// answers `session_context_mismatch` if the context is not this device's
    /// (`clients/core/src/clean_service.rs:688-699`). A session that fails
    /// either check is never held, so nothing is ever signed against it.
    ///
    /// - Throws: `Superseded`, `SessionFailure`, `CoreError` or
    ///   `SelfServiceError`.
    @discardableResult
    public func adoptSession(_ reply: RealtimeTransport.Reply,
                             trust: ServiceTrust,
                             under generation: Generation? = nil) throws -> SessionModel {
        if let generation { try check(generation) }
        let candidate = try SessionModel.open(try reply.json(), received: clock.now(), trust: trust)
        // The signature is discarded on purpose: what is wanted is the core's
        // refusal, not the request.
        try perform(generation) { client in
            _ = try client.sessionRequest(session: candidate.context, operation: "messages")
        }
        held = candidate
        return candidate
    }
}
