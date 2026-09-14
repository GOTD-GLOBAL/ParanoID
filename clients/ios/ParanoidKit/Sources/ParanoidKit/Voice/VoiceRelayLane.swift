import Foundation

/// What one TURN-credential request ended with.
///
/// It is the `(config, success)` pair of
/// `RealtimeLoop.VoiceRelayReply.done(VoiceRelayConfig, boolean)`
/// (`clients/android/src/org/paranoid/text/RealtimeLoop.java:19`) written as
/// the three answers that pair can actually carry, so that "no credentials"
/// and "no authority" cannot be confused with each other:
///
/// - `relay` is a validated issuer document; media may be created relay-only
///   with exactly those two URLs.
/// - `direct` is the **disclosed compatibility mode**: a valid authenticated
///   404 from the pinned origin, or a pre-session legacy server. It is
///   capability absence, not proof of anything about this account
///   (`docs/protocol/voice-turn-v1.md`, "Consent, transport and
///   compatibility").
/// - `failed` grants nothing. Every other status, a refused pin, a timeout, a
///   redirect, a malformed 200 and a busy capable server end here, and none of
///   them may be turned into `direct`: "Redirects, TLS mismatch, malformed
///   200, timeout, 429, 5xx or authorization failure never trigger this
///   fallback."
public enum VoiceRelayOutcome: Sendable {
    case relay(VoiceRelayConfig)
    case direct
    case failed

    /// Whether media authority was granted at all — Android's `success` flag.
    public var authorized: Bool {
        switch self {
        case .relay, .direct: return true
        case .failed: return false
        }
    }

    /// The credentials, when there are any. Never log or persist them.
    public var config: VoiceRelayConfig? {
        guard case .relay(let config) = self else { return nil }
        return config
    }

    /// The one word this outcome is recorded as. It names no server, no
    /// account and no credential, so it is safe in evidence.
    public var name: String {
        switch self {
        case .relay: return "relay"
        case .direct: return "direct"
        case .failed: return "failed"
        }
    }
}

/// Why one credential request was refused before, or instead of, an HTTP
/// answer.
///
/// Both are `IOException`s in `RealtimeLoop.runVoiceRequest`
/// (`RealtimeLoop.java:142,149`), named here so that a test can say which rule
/// refused rather than match on a message.
public enum VoiceRelayFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// There is no live session and this server is capable of one: a busy
    /// capable server is not a legacy-server downgrade signal
    /// (`RealtimeLoop.java:141-142`).
    case sessionUnavailable
    /// `sign_session_v2` answered something other than `GET`,
    /// `/v2/voice/turn` and an empty body. Nothing is sent
    /// (`RealtimeLoop.java:148-149`).
    case requestMismatch

    public var description: String {
        switch self {
        case .sessionUnavailable: return "voice session unavailable"
        case .requestMismatch: return "voice request mismatch"
        }
    }
}

extension StateOwner {
    /// Hands one relay outcome to the caller that asked for it, on the owner
    /// (`RealtimeLoop.deliverVoice`, `:125-134`).
    ///
    /// A superseded generation says nothing at all, exactly as `announce`
    /// does: a credential minted for a call that has already ended grants
    /// nothing and must not reach a controller that has moved on. A frozen
    /// client publishes the authorization notice and answers `failed`, because
    /// a client that cannot persist must not open media
    /// (`RealtimeLoop.java:132`).
    public func deliverRelay(_ outcome: VoiceRelayOutcome,
                             under generation: Generation,
                             to listener: (any RealtimeListener)?,
                             request: VoiceRelayLane.Request? = nil,
                             _ reply: @Sendable (VoiceRelayOutcome) -> Void) {
        guard request?.isCancelled != true else { return }
        guard isCurrent(generation) else { return }
        guard !isFrozen else {
            listener?.authorizationLost()
            reply(.failed)
            return
        }
        reply(outcome)
    }
}

/// The one bounded, cancellable voice lane: the port of
/// `RealtimeLoop.requestVoiceRelay` / `cancelVoiceRelay` / `runVoiceRequest`
/// (`clients/android/src/org/paranoid/text/RealtimeLoop.java:105-168`).
///
/// It is a third lane beside send and receive, and it is deliberately not
/// built out of `SessionCall`. Both sign with the same core and both send over
/// the same pinned trust, but the text lanes answer a 401 or a 404 by dropping
/// the session and rediscovering the capability
/// (`docs/protocol/realtime-v1.md:172-177`), and this route must not:
/// "A 404 for this optional route does not discard an otherwise valid text
/// session or force legacy text rediscovery" (`voice-turn-v1.md`). A voice
/// failure therefore belongs to the request that made it and to nothing else —
/// it publishes no status, it never reports `authorizationLost`, and it leaves
/// the session and the discovery timestamp exactly as it found them.
///
/// ## What has to be true before a credential is asked for
///
/// "Only the existing explicit outgoing intent plus matching fresh ready, or
/// explicit Answer plus microphone permission, may start a credential request.
/// Incoming knock, ringing or background notification cannot mint credentials
/// or open media." That consent lives in `CallController`; this lane is what
/// the controller calls once it holds it, and the lane adds the second half:
/// a **live session**. Without one there are only two answers —
///
/// - the server never advertised the realtime capability, so it is a
///   pre-session legacy server and the disclosed direct-ICE mode applies
///   (`.direct`);
/// - the server is capable but has no session right now (the account is at its
///   two-session cap, or there is no identity yet), which is a failure and
///   never a downgrade (`RealtimeLoop.java:141-142`).
///
/// ## One request, one replacement, one socket
///
/// `request(under:then:)` cancels whatever was pending before it, so at most
/// one request is live. `serial` is the single-threaded executor of
/// `RealtimeLoop.java:20-21`: a replacement waits for the previous body to
/// return instead of opening a second connection beside it, and a replacement
/// that is itself superseded while it waits never dials at all. The endpoint
/// is created per request and closed when the request returns, by the same
/// task that opened it, so no socket outlives a call
/// (`VoiceRelayTransport.close()`).
///
/// A cancelled request is never delivered. That is not a convenience: a
/// callback that arrived after the user hung up would hand media authority to
/// a call that no longer exists, and the smoke that proves it cannot is
/// `VoiceRelayLaneSmoke.staleFailure`.
public actor VoiceRelayLane {
    /// What the core is asked to sign (`clean_service.rs:718`).
    public static let operation = "turn"

    /// The callback one request answers on. It runs on the state owner.
    public typealias Reply = @Sendable (VoiceRelayOutcome) -> Void

    /// How a transport for one request is made. The shipped value builds a
    /// `VoiceRelayTransport`; a test substitutes an endpoint that never opens
    /// a socket.
    public typealias EndpointFactory = @Sendable (ServiceTrust) throws -> any VoiceRelayEndpoint

    private let owner: StateOwner
    private let flow: ProofFlow
    private let listener: (any RealtimeListener)?
    private let clock: MonotonicClock
    private let endpoint: EndpointFactory
    private let wall: @Sendable () -> Int64
    private let serial = Serial()

    private var issued: UInt64 = 0
    private var current: Pending?

    /// - Parameters:
    ///   - owner: the state owner; every core call runs on it and nowhere
    ///     else.
    ///   - flow: the shared connection — registration, discovery and the
    ///     session both text lanes use. This lane opens none of its own.
    ///   - listener: where the freeze notice goes; `nil` when the caller does
    ///     not want one.
    ///   - clock: the monotonic clock the credential's admission budget is
    ///     measured from.
    ///   - wall: Unix milliseconds at receipt. It is a seam only so that a
    ///     test can hand the parser a clock it chose; the application passes
    ///     the system clock.
    ///   - endpoint: how the one-shot transport of a request is built.
    public init(owner: StateOwner,
                flow: ProofFlow,
                listener: (any RealtimeListener)? = nil,
                clock: MonotonicClock = .continuous,
                wall: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                endpoint: @escaping EndpointFactory = { trust in
                    try VoiceRelayTransport(realm: trust.realm, pin: trust.pin)
                }) {
        self.owner = owner
        self.flow = flow
        self.listener = listener
        self.clock = clock
        self.wall = wall
        self.endpoint = endpoint
    }

    // MARK: - The two operations

    /// Asks for one TURN credential, replacing whatever was pending
    /// (`RealtimeLoop.requestVoiceRelay`, `:105-112`).
    ///
    /// - Parameters:
    ///   - generation: the realtime run this request belongs to. The answer is
    ///     delivered only while it is still current.
    ///   - reply: invoked at most once, on the state owner. A cancelled or
    ///     superseded request never invokes it.
    public func request(under generation: Generation, request: Request = Request(),
                        then reply: @escaping Reply) {
        guard !request.isCancelled else { return }
        cancelCurrent()
        issued += 1
        let pending = Pending(ticket: issued, generation: generation, request: request, reply: reply)
        current = pending
        pending.task = Task { [weak self] in
            guard let self else { return }
            await self.run(pending)
        }
    }

    /// Drops the pending request, its connection and its callback
    /// (`RealtimeLoop.cancelVoiceRelay`, `:113`).
    public func cancel() {
        cancelCurrent()
    }

    /// Whether a request is pending right now.
    public var isPending: Bool { current != nil }

    private func cancelCurrent() {
        guard let pending = current else { return }
        current = nil
        pending.cancel()
    }

    /// `voiceRequest != request || request.cancelled` of
    /// `RealtimeLoop.java:128`, decided in one isolated step so that nothing
    /// can replace the request between the test and the delivery.
    private func claim(_ pending: Pending) -> Bool {
        guard current === pending else { return false }
        current = nil
        return !pending.isCancelled
    }

    // MARK: - One request

    private nonisolated func run(_ pending: Pending) async {
        // The single-threaded executor of `RealtimeLoop.java:20-21`: a
        // replacement never dials beside the request it replaced. Android
        // removes a superseded body from the one-slot queue; here it reaches
        // the gate, fails its first cancellation check and gives the gate
        // straight back, so it dials nothing either way.
        await serial.acquire()
        let outcome: VoiceRelayOutcome
        do {
            try pending.check()
            outcome = try await issue(pending)
        } catch {
            // "Failure belongs only to this request and call generation"
            // (`RealtimeLoop.java:165`): nothing is published, no session is
            // dropped and no discovery is invalidated.
            outcome = .failed
        }
        await serial.release()
        await deliver(pending, outcome)
    }

    private nonisolated func issue(_ pending: Pending) async throws -> VoiceRelayOutcome {
        try await owner.check(pending.generation)
        let connection = try await flow.connect(under: pending.generation)
        try pending.check()
        try await owner.check(pending.generation)
        switch connection {
        case .idle:
            // No identity is not a legacy server: Android throws `Idle` here
            // (`RealtimeLoop.java:188`) and the request fails.
            throw VoiceRelayFailure.sessionUnavailable
        case .proof:
            // A capable server without a session right now is a failure; a
            // server that never advertised the capability is the disclosed
            // compatibility mode (`RealtimeLoop.java:140-143`).
            let capable = await owner.isRealtime
            guard !capable else { throw VoiceRelayFailure.sessionUnavailable }
            return .direct
        case .session(let context):
            return try await mint(pending, context: context)
        }
    }

    private nonisolated func mint(_ pending: Pending,
                                  context: SessionModel) async throws -> VoiceRelayOutcome {
        let trust = try await owner.perform(pending.generation) { try $0.updateTrust() }
        let lane = try endpoint(trust)
        guard pending.adopt(lane) else {
            await lane.close()
            throw CancellationError()
        }
        do {
            let outcome = try await exchange(pending, context: context, trust: trust, over: lane)
            await pending.release()
            return outcome
        } catch {
            await pending.release()
            throw error
        }
    }

    /// The signed request, its one permitted repeat, and the answer
    /// (`RealtimeLoop.java:147-161`).
    private nonisolated func exchange(_ pending: Pending,
                                      context: SessionModel,
                                      trust: ServiceTrust,
                                      over lane: any VoiceRelayEndpoint) async throws -> VoiceRelayOutcome {
        var retried = false
        while true {
            try pending.check()
            // The core decides the method, the path and the body; this lane
            // sends exactly that and checks that it is the fixed operation it
            // asked for, so a core that answered anything else sends nothing
            // (`RealtimeLoop.java:148-149`).
            let signed = try await owner.perform(pending.generation) { client in
                try SignedRequest(try client.sessionRequest(session: context.context,
                                                            operation: Self.operation))
            }
            guard signed.method == "GET",
                  signed.path == VoiceRelayTransport.path,
                  signed.body.isEmpty else { throw VoiceRelayFailure.requestMismatch }
            try pending.check()
            try await owner.check(pending.generation)
            do {
                let body = try await lane.get(authorization: signed.authorization)
                try pending.check()
                try await owner.check(pending.generation)
                // Both clocks are read here, at receipt, and the monotonic one
                // is what `usable(wallMilliseconds:monotonicNanoseconds:)`
                // measures the admission budget against before media is
                // created.
                return .relay(try VoiceRelayConfig.parse(body, realm: trust.realm,
                                                         wallMilliseconds: wall(),
                                                         monotonicNanoseconds: monotonic()))
            } catch let rejected as Rejected {
                try pending.check()
                try await owner.check(pending.generation)
                // "The existing first ambiguous 401 may retry once with a
                // freshly signed nonce; a second 401 terminates local call
                // authority" (`voice-turn-v1.md`). The request is signed
                // again, never replayed.
                if rejected.status == 401, !retried {
                    retried = true
                    continue
                }
                // "A valid pinned-origin 404 permits the retained direct-ICE
                // compatibility mode, disclosed before user consent."
                if rejected.status == 404 { return .direct }
                throw rejected
            }
        }
    }

    private nonisolated func monotonic() -> Int64 {
        Int64(bitPattern: clock.now().nanoseconds)
    }

    private nonisolated func deliver(_ pending: Pending,
                                     _ outcome: VoiceRelayOutcome) async {
        guard await claim(pending) else { return }
        await owner.deliverRelay(outcome, under: pending.generation,
                                 to: listener, request: pending.request) { result in
            guard !pending.isCancelled else { return }
            pending.reply(result)
        }
    }

    // MARK: - One pending request

    /// `RealtimeLoop.VoiceRequest` (`:26-32`): the run it belongs to, its
    /// callback, the connection it opened and the one flag that stops it.
    ///
    /// The flag and the connection are read from the request's own task and
    /// written from the lane, which is why they are under a lock rather than
    /// isolated — exactly the `volatile` pair of the Java field list.
    private final class Pending: @unchecked Sendable {
        let ticket: UInt64
        let generation: Generation
        let reply: Reply
        /// Set once, from the lane, before anything can read it.
        var task: Task<Void, Never>?

        let request: Request

        init(ticket: UInt64, generation: Generation, request: Request, reply: @escaping Reply) {
            self.ticket = ticket
            self.generation = generation
            self.request = request
            self.reply = reply
        }

        var isCancelled: Bool { request.isCancelled }
        func check() throws { try request.check() }
        func adopt(_ lane: any VoiceRelayEndpoint) -> Bool { request.adopt(lane) }
        func release() async { await request.release() }
        func cancel() {
            request.cancel()
            task?.cancel()
        }
    }

    /// One call's cancellation authority, created on the call owner before
    /// crossing to this actor. Cancellation is sticky and synchronous; only
    /// endpoint disposal is asynchronous. A cancelled late request cannot
    /// supersede a newer call, and a late teardown cannot cancel that call.
    public final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var lane: (any VoiceRelayEndpoint)?

        public init() {}

        public var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        /// `guardVoice` (`RealtimeLoop.java:122-124`), the cancellation half.
        func check() throws {
            if isCancelled { throw CancellationError() }
        }

        /// Takes ownership of the connection, unless this request is already
        /// over.
        func adopt(_ lane: any VoiceRelayEndpoint) -> Bool {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return false
            }
            self.lane = lane
            lock.unlock()
            return true
        }

        /// Closes and forgets the connection (`RealtimeLoop.java:166`).
        func release() async {
            let lane = lock.withLock { () -> (any VoiceRelayEndpoint)? in
                let lane = self.lane
                self.lane = nil
                return lane
            }
            await lane?.close()
        }

        /// Stops this request and drops its socket now
        /// (`RealtimeLoop.cancelVoiceLocked`, `:114-121`).
        ///
        /// The close runs in its own task, off the caller, because Android
        /// keeps `disconnect()` off both the state owner and the UI thread
        /// for the same reason.
        public func cancel() {
            lock.lock()
            cancelled = true
            let lane = self.lane
            self.lane = nil
            lock.unlock()
            if let lane {
                Task { await lane.close() }
            }
        }
    }

    /// One body at a time, FIFO, without a thread: the
    /// `ThreadPoolExecutor(1, 1, …, ArrayBlockingQueue(1))` of
    /// `RealtimeLoop.java:20-21`, with the waiting request suspended instead
    /// of holding a thread.
    private actor Serial {
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
