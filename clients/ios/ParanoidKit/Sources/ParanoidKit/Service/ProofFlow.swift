import Foundation

/// The one thing a proof needs from the network: send one request, get one
/// 200 body back.
///
/// The implementation is `RealtimeTransport` (the pinned, proxy-free, capped
/// pool of `RealtimeTransport.java`), which conforms to this protocol as it
/// is; it is injected because nothing in `Service/` opens a connection — the
/// owner that holds the state must not be able to dial, and a test drives the
/// whole flow over a fake.
///
/// The call is `async` and answers a `Reply`, which is the transport's own
/// shape: the body as text plus its size. Nothing here decodes it, because a
/// decoded `[String: Any]` is not `Sendable` and must not travel between the
/// lane and the state owner; the owner decodes what it is about to use, on the
/// owner.
///
/// A non-200 answer is expected to be thrown as a `Rejected`, carrying the
/// status and the error code; nothing in this file inspects either except
/// `connect()`, which maps the `/v2/session` route's own rejections the way
/// `RealtimeLoop.connection(long)` does (`RealtimeLoop.java:190-194`) because
/// both lanes share that one connection. Mapping the rejection of a signed
/// **operation** to `invalidateDiscovery()` or `dropSession()` stays the
/// lane's job (`SessionCall`), because the same status means different things
/// in the send and receive lanes (`docs/protocol/realtime-v1.md:167-178`).
public protocol ProofTransport: Sendable {
    /// - Parameters:
    ///   - method: `GET` or `POST`, uppercase.
    ///   - path: `/health` or a `/v2/…` path with its exact query bytes.
    ///   - body: the exact bytes to send; empty for `GET`.
    ///   - authorization: the one `Authorization` header value, or `nil` for
    ///     the two unauthenticated routes (`/health` and a challenge).
    func call(method: String,
              path: String,
              body: String,
              authorization: String?) async throws -> RealtimeTransport.Reply

    /// Abandons whatever this transport has in flight, and changes nothing
    /// else about it.
    ///
    /// It is `RealtimeTransport.java:66-71` and the second half of
    /// `RealtimeLoop.restart()` (`RealtimeLoop.java:64-66`): when the default
    /// network changes, the request a lane is suspended on belongs to an
    /// interface that no longer exists, and nobody refuses it until its own
    /// 30-second read bound and the backoff after that. Cancelling it is what
    /// turns those 30 seconds into the next cycle.
    ///
    /// It is not `close()`: the session, its pin and its configuration stay,
    /// so the very next call goes out over the new interface with no new
    /// factory, no new pin and no new trust.
    func cancelActive() async
}

extension ProofTransport {
    /// Doing nothing is the right answer for a transport that has no socket to
    /// abandon, which is every double in the test suites: they answer from
    /// memory, nothing of theirs can be parked, and a seam that cannot be
    /// parked cannot be freed. It is also the safe direction to default in — a
    /// cancellation that a transport does not implement costs one cycle the
    /// time it would have saved, while a default that tore something down
    /// would take a working transport off the network on every path change.
    ///
    /// The real implementation is the shipped one,
    /// `RealtimeTransport.cancelActive()` (`Net/RealtimeTransport.swift:220`),
    /// which cancels every task in the pool and keeps the pinned session; a
    /// type's own member is the witness of a requirement it matches, so this
    /// default never stands in for it.
    public func cancelActive() async {}
}

/// The pinned transport is the shipped implementation; it needs nothing added.
extension RealtimeTransport: ProofTransport {}

/// How the flow waits out the spacing between two challenges.
///
/// It is a seam for the same reason Android waits on its lifecycle monitor
/// rather than sleeping (`RealtimeLoop.java:153-157,161`): a lane that is being
/// stopped must be able to abandon the wait instead of holding a thread for
/// 600 ms. The wait is `async`, so cancelling the lane's `Task` is what
/// abandons it, and throwing from `wait` abandons the proof before anything is
/// sent.
public protocol ProofPacer: Sendable {
    func wait(nanoseconds: UInt64) async throws
}

/// The default pacer: it suspends the calling task.
///
/// No thread is held while it waits and a cancelled task leaves it at once
/// with `CancellationError`, which is exactly what a stopped lane needs.
public struct SleepingPacer: ProofPacer {
    public init() {}

    public func wait(nanoseconds: UInt64) async throws {
        guard nanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// What a connection attempt ended up with.
public enum ProofConnection: Sendable {
    /// There is no identity on this device yet. The user creates one; nothing
    /// is dialled until then (`RealtimeLoop.java:171,232,275`).
    case idle
    /// No session: either the pinned server has no realtime capability, or the
    /// session route is being held off after a capacity rejection. The lanes
    /// use the retained challenge transport of self-service v2
    /// (`docs/protocol/realtime-v1.md:177`).
    case proof
    /// A session that is validated, fresh and bound to this identity.
    case session(SessionModel)
}

/// Registration, capability discovery and session issuance: the port of
/// `RealtimeLoop.connection(long)` and `RealtimeLoop.proof(...)`
/// (`RealtimeLoop.java:158-196`).
///
/// One proof is always the same three steps and never fewer:
///
/// 1. ask the core to describe the intent (`ChallengeIntent`),
/// 2. `POST` it to the challenge route and get a 60-second challenge back,
/// 3. ask the core to sign that challenge for exactly this method, path and
///    body, and send the request with the resulting `Authorization` header.
///
/// The challenge is minted by the server, consumed once, and bound to one
/// request; the private key never leaves the core, so nothing here can sign
/// anything on its own. Consecutive challenges are spaced by at least 600 ms
/// because the server meters 2 challenges per account per second
/// (`docs/protocol/self-service-v2.md`) and a client that trips its own rate
/// limit is a client that cannot register.
///
/// **This object holds no state and touches none.** Steps 1 and 3 run on
/// `StateOwner`, which is the only thing that may call the core; step 2 and
/// the request itself run in the lane's own task, off the owner, so the owner
/// is never suspended on a socket. What crosses between them is a `Sendable`
/// value each way and nothing else: a signed request going out, a `Reply`
/// coming back. The two gates below are what serialize the lanes against each
/// other, and neither is ever held by a thread — they are actors, so a lane
/// that is waiting for one is suspended rather than blocking.
///
/// A frozen client refuses to hand out its trust, so a frozen client never
/// reaches step 2 of anything.
public final class ProofFlow: Sendable {
    /// The floor between two challenge requests (`RealtimeLoop.java:160`).
    public static let challengeSpacing: UInt64 = 600_000_000
    /// How long the session route is left alone after a 429
    /// (`RealtimeLoop.java:192`). The account is at its two live sessions
    /// (`server/src/self_service_http.rs:398-409`) or the challenge route is
    /// metered; either way, hammering it would only keep it there, and the
    /// retained challenge transport carries everything meanwhile.
    public static let legacyWindow: UInt64 = 5 * MonotonicClock.nanosecondsPerSecond

    private let owner: StateOwner
    private let transport: any ProofTransport
    private let clock: MonotonicClock
    private let pacer: any ProofPacer
    // Android's `proofGate` and `sessionGate` (`RealtimeLoop.java:33`): two
    // lanes share one flow, and neither the challenge spacing nor the "is
    // there a session yet" decision survives being run twice at once. A
    // connection takes the session gate and then the proof gate, in that
    // order and never the other way round.
    private let proofGate = Gate()
    private let sessionGate = Gate()
    private let meter = ChallengeMeter()

    /// - Parameters:
    ///   - owner: the state owner; every core call below is made on it.
    ///   - transport: the network, awaited from the caller's task.
    ///   - clock: the clock the 600 ms challenge spacing is measured on. It is
    ///     the same continuous clock the owner measures the session on, and a
    ///     test that drives one by hand passes that one to both.
    ///   - pacer: how the spacing is waited out.
    public init(owner: StateOwner,
                transport: any ProofTransport,
                clock: MonotonicClock = .continuous,
                pacer: any ProofPacer = SleepingPacer()) {
        self.owner = owner
        self.transport = transport
        self.clock = clock
        self.pacer = pacer
    }

    /// One paced challenge-and-request pair, and the answer to the request.
    ///
    /// - Parameters:
    ///   - purpose: `register`, `session`, `message` or `status`.
    ///   - method: the method of the authorized request, uppercase.
    ///   - path: its path, with the exact query bytes.
    ///   - body: its exact body; empty for `GET`, `{}` for a control.
    ///   - generation: the lane's run, revalidated on the owner before each of
    ///     the two core calls; `nil` outside a lane.
    /// - Throws: whatever the transport throws, `CoreError.rejected` when the
    ///   core refuses to sign the challenge it was handed (a server that
    ///   answers a challenge for another account, another realm or another
    ///   request gets `proof_context_mismatch` and nothing is sent),
    ///   `SelfServiceError.frozen`, or `Superseded`.
    @discardableResult
    public func proof(purpose: String,
                      method: String,
                      path: String,
                      body: String,
                      under generation: Generation? = nil) async throws -> RealtimeTransport.Reply {
        await proofGate.acquire()
        do {
            let reply = try await metered(purpose: purpose, method: method, path: path,
                                          body: body, under: generation)
            await proofGate.release()
            return reply
        } catch {
            await proofGate.release()
            throw error
        }
    }

    private func metered(purpose: String,
                         method: String,
                         path: String,
                         body: String,
                         under generation: Generation?) async throws -> RealtimeTransport.Reply {
        // A lane that was cancelled while it waited for the gate stops here,
        // with the gate released and nothing sent.
        try Task.checkCancellation()
        let due = await meter.due(at: clock.now(), spacing: Self.challengeSpacing)
        if due > 0 { try await pacer.wait(nanoseconds: due) }
        // The intent is built before the clock is read, so a slow core call
        // shortens nothing, and it is built from the state, so a frozen client
        // stops here with nothing sent.
        let intent = try await owner.perform(generation) { client in
            let intent = try ChallengeIntent.make(purpose: purpose, method: method,
                                                  path: path, body: body, from: client)
            return ChallengeRequest(path: intent.challengePath,
                                    body: try ProofFlow.encode(intent.json))
        }
        await meter.mark(clock.now())
        let challenge = try await transport.call(method: "POST", path: intent.path,
                                                 body: intent.body, authorization: nil)
        let authorization = try await owner.perform(generation) { client in
            try client.requestProof(challenge: try challenge.json(), method: method,
                                    path: path, body: body)
        }
        return try await transport.call(method: method, path: path, body: body,
                                        authorization: authorization)
    }

    /// Brings the connection up to the best transport this server offers.
    ///
    /// The order is Android's (`RealtimeLoop.java:171-189`) and each step is a
    /// precondition of the next: an identity exists, this device is enrolled,
    /// the capability is known, and only then is a session opened. A session
    /// younger than 240 seconds is reused, and both the session and the
    /// capability belong to `StateOwner`, so they survive a pause and a new
    /// generation (`docs/protocol/realtime-v1.md:179-181`).
    ///
    /// A rejection of the session route itself is answered here and nowhere
    /// else (`RealtimeLoop.java:190-194`): a 401 or a 404 drops the held
    /// session, rediscovers the capability and is rethrown, while a 429 leaves
    /// that route alone for `legacyWindow` and selects `.proof`, so the cycle
    /// that asked still has a transport.
    ///
    /// - Throws: the transport's rejections unchanged — the caller maps what
    ///   it signed itself — plus `TransportError.protocolMismatch` for a
    ///   server that is not this protocol, `SessionFailure`, `CoreError`,
    ///   `SelfServiceError` and `Superseded`.
    public func connect(under generation: Generation? = nil) async throws -> ProofConnection {
        await sessionGate.acquire()
        do {
            let connection = try await connection(under: generation)
            await sessionGate.release()
            return connection
        } catch {
            await sessionGate.release()
            throw error
        }
    }

    private func connection(under generation: Generation?) async throws -> ProofConnection {
        try Task.checkCancellation()
        // The gate in front of every request: a client whose commit failed
        // refuses to say where the server is, and therefore nothing below
        // dials anything at all.
        let trust = try await owner.perform(generation) { try $0.updateTrust() }
        guard try await owner.perform(generation, { try $0.hasIdentity() }) else { return .idle }
        // Finish valid local checkpoints before any request, including when an
        // active enrollment would otherwise skip the registration branch.
        try await owner.perform(generation) { try $0.resumeOnboarding() }
        if try await owner.perform(generation, { try !$0.registered() }) {
            let status = try await proof(purpose: ChallengeIntent.registerPurpose,
                                         method: "POST",
                                         path: ChallengeIntent.registrationCommitPath,
                                         body: ChallengeIntent.controlBody,
                                         under: generation)
            // Two candidates, both durable before this returns: the server's
            // answer and the contact material derived from it.
            try await owner.perform(generation) { try $0.registrationResult(status: try status.json()) }
        }
        if await owner.isDiscoveryDue() {
            let reply = try await transport.call(method: "GET", path: HealthDiscovery.path,
                                                 body: "", authorization: nil)
            try await owner.applyHealth(reply, under: generation)
        }
        guard await owner.isRealtime else { return .proof }
        if await owner.sessionsAreHeld() { return .proof }
        if let existing = await owner.reusableSession() { return .session(existing) }
        do {
            let reply = try await proof(purpose: ChallengeIntent.sessionPurpose,
                                        method: "POST",
                                        path: ChallengeIntent.sessionPath,
                                        body: ChallengeIntent.controlBody,
                                        under: generation)
            return .session(try await owner.adoptSession(reply, trust: trust, under: generation))
        } catch let rejected as Rejected {
            // `RealtimeLoop.java:190-194`, and the reason it lives here rather
            // than in a lane: this is the connection both lanes share, so the
            // answer to "there is no session route" or "the account has no
            // slot left" must be the same for both of them.
            if rejected.status == 401 || rejected.status == 404 {
                // A 404 on the session or the challenge route means this
                // server does not have it; a 401 here means the device is not
                // authorized to open one. Either way the held session is gone
                // and the capability is asked for again — "a 401 never weakens
                // authorization" (`docs/protocol/realtime-v1.md:172-178`), it
                // only sends the client back to `/health`.
                await owner.dropSession()
                await owner.invalidateDiscovery()
                throw rejected
            }
            if rejected.status == 429 {
                // Capacity, not authorization: the route is left alone for
                // five seconds and this cycle goes out over the retained
                // challenge transport instead of queueing for a slot.
                await owner.holdSessions(for: Self.legacyWindow)
                return .proof
            }
            throw rejected
        }
    }

    static func encode(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { throw SelfServiceError.invalidRequest }
        return text
    }

    /// Where one challenge is posted and what its body is: the only two things
    /// a challenge intent is outside the owner, and both are `Sendable`.
    private struct ChallengeRequest: Sendable {
        let path: String
        let body: String
    }

    /// When the last challenge was asked for.
    ///
    /// It is read and written under `proofGate`, so it needs no exclusion of
    /// its own; it is an actor because the value has to be reachable from
    /// whichever lane holds the gate.
    private actor ChallengeMeter {
        private var last: MonotonicInstant?

        /// How long is still owed before the next challenge may be sent.
        func due(at now: MonotonicInstant, spacing: UInt64) -> UInt64 {
            guard let last else { return 0 }
            let elapsed = now.nanoseconds(since: last)
            return elapsed < spacing ? spacing - elapsed : 0
        }

        func mark(_ now: MonotonicInstant) {
            last = now
        }
    }

    /// One waiter at a time, FIFO, without a thread.
    ///
    /// It replaces the `synchronized` blocks of `RealtimeLoop.java:34`, which
    /// are held across the network call they guard. A lock cannot be held
    /// across an `await` — the task that resumes may be on another thread —
    /// so the exclusion is expressed as an actor that hands out permission:
    /// the waiting lane is suspended, and the thread it was on goes back to
    /// doing something else.
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard busy else {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            guard !waiters.isEmpty else {
                busy = false
                return
            }
            waiters.removeFirst().resume()
        }
    }
}
