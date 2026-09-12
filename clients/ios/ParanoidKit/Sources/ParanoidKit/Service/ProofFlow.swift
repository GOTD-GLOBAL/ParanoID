import Foundation

/// The one thing a proof needs from the network: send one request, get one
/// JSON object back.
///
/// The implementation is `RealtimeTransport` (the pinned, proxy-free, capped
/// pool of `RealtimeTransport.java`); it is injected because nothing in
/// `Service/` opens a connection — the adapter that owns the state must not be
/// able to dial, and a test drives the whole flow over a fake.
///
/// A non-200 answer is expected to be thrown as a `Rejected`, carrying the
/// status and the error code; `ProofFlow` never inspects either. Mapping a
/// rejection to `invalidate()`, `dropSession()` or `holdSessions(for:)` is the
/// lane's job, because the same status means different things in the send and
/// receive lanes (`docs/protocol/realtime-v1.md:167-178`).
public protocol ProofTransport: AnyObject {
    /// - Parameters:
    ///   - method: `GET` or `POST`, uppercase.
    ///   - path: `/health` or a `/v2/…` path with its exact query bytes.
    ///   - body: the exact bytes to send; empty for `GET`.
    ///   - authorization: the one `Authorization` header value, or `nil` for
    ///     the two unauthenticated routes (`/health` and a challenge).
    func call(method: String, path: String, body: String, authorization: String?) throws -> [String: Any]
}

/// How the flow waits out the spacing between two challenges.
///
/// It is a seam for the same reason Android waits on its lifecycle monitor
/// rather than sleeping (`RealtimeLoop.java:169-172`): a lane that is being
/// stopped must be able to abandon the wait instead of holding the thread for
/// 600 ms. Throwing from `wait` abandons the proof before anything is sent.
public protocol ProofPacer: AnyObject {
    func wait(nanoseconds: UInt64) throws
}

/// The default pacer: it blocks the calling thread.
///
/// The lanes of the realtime loop replace it with a generation-aware one; this
/// one is enough for a single-threaded caller such as the registration tool.
public final class SleepingPacer: ProofPacer {
    public init() {}

    public func wait(nanoseconds: UInt64) throws {
        guard nanoseconds > 0 else { return }
        Thread.sleep(forTimeInterval: Double(nanoseconds) / Double(MonotonicClock.nanosecondsPerSecond))
    }
}

/// What a connection attempt ended up with.
public enum ProofConnection {
    /// There is no identity on this device yet. The user creates one; nothing
    /// is dialled until then (`RealtimeLoop.java:184,247`).
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
/// (`RealtimeLoop.java:174-215`), without the generation bookkeeping that
/// belongs to the lanes.
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
/// Everything is synchronous: this object is driven from a lane, exactly as
/// Android drives it from a network thread, and it never touches the state
/// except through `SelfServiceClient`, which is where every commit happens.
/// A frozen client refuses to hand out its trust, so a frozen client never
/// reaches step 2 of anything.
public final class ProofFlow {
    /// The floor between two challenge requests (`RealtimeLoop.java:170`).
    public static let challengeSpacing: UInt64 = 600_000_000

    private let client: SelfServiceClient
    private let transport: ProofTransport
    private let clock: MonotonicClock
    private let pacer: ProofPacer
    // Android's `proofGate` and `sessionGate` (`RealtimeLoop.java:34`): two
    // lanes share one flow, and neither the challenge spacing nor the "is
    // there a session yet" decision survives being run twice at once.
    private let proofGate = NSLock()
    private let sessionGate = NSLock()

    private var lastChallenge: MonotonicInstant?
    private var discovery = HealthDiscovery()
    private var current: SessionModel?
    private var sessionsHeldUntil: MonotonicInstant?

    public init(client: SelfServiceClient,
                transport: ProofTransport,
                clock: MonotonicClock = .continuous,
                pacer: ProofPacer = SleepingPacer()) {
        self.client = client
        self.transport = transport
        self.clock = clock
        self.pacer = pacer
    }

    /// Whether the last `/health` answer carried the realtime capability.
    public var isRealtime: Bool { discovery.realtime }

    /// The session currently held, if any.
    public var session: SessionModel? { current }

    /// Rediscover the capability before the next connection: the answer to a
    /// 404 on a cached session route and to a failed renewal
    /// (`docs/protocol/realtime-v1.md:172-177`).
    public func invalidateDiscovery() {
        sessionGate.lock()
        defer { sessionGate.unlock() }
        discovery.invalidate()
    }

    /// Forget the held session. A lane calls this on the rejections that mean
    /// the server no longer has it (`RealtimeLoop.java:206-207,220-223`).
    public func dropSession() {
        sessionGate.lock()
        defer { sessionGate.unlock() }
        current = nil
    }

    /// Stop asking for sessions for a while, and use the challenge transport
    /// meanwhile. It is the answer to a 429 on `/v2/session`: the account is
    /// at its two-session cap, and hammering the route would only keep it
    /// there (`RealtimeLoop.java:209`).
    public func holdSessions(for nanoseconds: UInt64) {
        sessionGate.lock()
        defer { sessionGate.unlock() }
        sessionsHeldUntil = clock.now().advanced(byNanoseconds: nanoseconds)
    }

    /// One paced challenge-and-request pair, and the answer to the request.
    ///
    /// - Parameters:
    ///   - purpose: `register`, `session`, `message` or `status`.
    ///   - method: the method of the authorized request, uppercase.
    ///   - path: its path, with the exact query bytes.
    ///   - body: its exact body; empty for `GET`, `{}` for a control.
    /// - Throws: whatever the transport throws, `CoreError.rejected` when the
    ///   core refuses to sign the challenge it was handed (a server that
    ///   answers a challenge for another account, another realm or another
    ///   request gets `proof_context_mismatch` and nothing is sent), or
    ///   `SelfServiceError.frozen`.
    @discardableResult
    public func proof(purpose: String,
                      method: String,
                      path: String,
                      body: String) throws -> [String: Any] {
        proofGate.lock()
        defer { proofGate.unlock() }
        if let last = lastChallenge {
            let elapsed = clock.now().nanoseconds(since: last)
            if elapsed < Self.challengeSpacing {
                try pacer.wait(nanoseconds: Self.challengeSpacing - elapsed)
            }
        }
        // The intent is built before the clock is read, so a slow core call
        // shortens nothing, and it is built from the state, so a frozen client
        // stops here with nothing sent.
        let intent = try ChallengeIntent.make(purpose: purpose, method: method,
                                              path: path, body: body, from: client)
        lastChallenge = clock.now()
        let challenge = try transport.call(method: "POST", path: intent.challengePath,
                                           body: Self.encode(intent.json), authorization: nil)
        let authorization = try client.requestProof(challenge: challenge, method: method,
                                                    path: path, body: body)
        return try transport.call(method: method, path: path, body: body,
                                  authorization: authorization)
    }

    /// Brings the connection up to the best transport this server offers.
    ///
    /// The order is Android's (`RealtimeLoop.java:183-214`) and each step is a
    /// precondition of the next: an identity exists, this device is enrolled,
    /// the capability is known, and only then is a session opened. A session
    /// younger than 240 seconds is reused; an older one is replaced through
    /// the second per-account slot (`docs/protocol/realtime-v1.md:179-181`).
    ///
    /// A freshly issued session is validated before it is adopted: one
    /// `sign_session_v2` for `messages` is signed and thrown away, which makes
    /// the core compare the context against the saved identity and answer
    /// `session_context_mismatch` if it is not this device's
    /// (`clean_service.rs:688-699`). Only then does the session become the
    /// one this flow hands out.
    ///
    /// - Throws: the transport's rejections unchanged — the caller maps them —
    ///   plus `TransportError.protocolMismatch` for a server that is not this
    ///   protocol, `SessionFailure`, `CoreError` and `SelfServiceError`.
    public func connect() throws -> ProofConnection {
        sessionGate.lock()
        defer { sessionGate.unlock() }
        // The gate in front of every request: a client whose commit failed
        // refuses to say where the server is, and therefore nothing below
        // dials anything at all.
        let trust = try client.updateTrust()
        guard try client.hasIdentity() else { return .idle }
        if try !client.registered() {
            let status = try proof(purpose: ChallengeIntent.registerPurpose,
                                   method: "POST",
                                   path: ChallengeIntent.registrationCommitPath,
                                   body: ChallengeIntent.controlBody)
            // Two candidates, both durable before this returns: the server's
            // answer and the contact material derived from it.
            try client.registrationResult(status: status)
        }
        if discovery.isDue(at: clock.now()) {
            let reply = try transport.call(method: "GET", path: HealthDiscovery.path,
                                           body: "", authorization: nil)
            // A server that lost the capability cannot be talked to through a
            // session any more, so the one being held goes with it.
            if try !discovery.accept(reply, at: clock.now()) { current = nil }
        }
        guard discovery.realtime else { return .proof }
        if let held = sessionsHeldUntil {
            guard clock.now() >= held else { return .proof }
            sessionsHeldUntil = nil
        }
        if let existing = current, !existing.needsRenewal(at: clock.now()) {
            return .session(existing)
        }
        let reply = try proof(purpose: ChallengeIntent.sessionPurpose,
                              method: "POST",
                              path: ChallengeIntent.sessionPath,
                              body: ChallengeIntent.controlBody)
        let candidate = try SessionModel.open(reply, received: clock.now(), trust: trust)
        // The result is discarded on purpose: what is wanted is the core's
        // refusal, not the signature.
        _ = try client.sessionRequest(session: candidate.context, operation: "messages")
        current = candidate
        return .session(candidate)
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { throw SelfServiceError.invalidRequest }
        return text
    }
}
