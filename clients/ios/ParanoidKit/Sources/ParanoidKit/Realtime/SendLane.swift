import Foundation

/// Why one send cycle refused an outbox entry or the answer to it.
///
/// Neither ever reaches the core: nothing is committed, the cycle ends and the
/// lane retries after its backoff. They describe a state that cannot happen
/// while this lane is the only thing that empties the outbox, and they exist so
/// that it fails loudly if it ever does.
public enum SendFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// An outbox entry without a usable `id` (`SelfServiceClient.java:211`,
    /// `RealtimeLoop.java:226`).
    case malformedEnvelope
    /// The acceptance names an envelope the outbox no longer holds, so there
    /// is nothing this answer could be about.
    case unknownEnvelope(String)

    public var description: String {
        switch self {
        case .malformedEnvelope: return "outbox entry without an identifier"
        case .unknownEnvelope: return "acceptance for an envelope the outbox no longer holds"
        }
    }
}

/// The lane that empties the outbox: the port of `RealtimeLoop.sendLoop()`
/// (`clients/android/src/org/paranoid/text/RealtimeLoop.java:214-241`).
///
/// One cycle is one pass over the outbox, oldest first, and the order inside
/// it is the specification:
///
/// 1. the connection is brought up to whatever this server offers — a session
///    when it advertises the capability, the retained challenge transport
///    otherwise (`docs/protocol/realtime-v1.md:177`);
/// 2. the outbox is read **on the owner**, and only the identifiers (and, for
///    a proof send, the envelope bytes) leave it. A decoded envelope never
///    travels to this lane;
/// 3. each entry is sent as the core described it: with a session,
///    `sign_session_v2 {operation:"send", id}` hands back the method, the path
///    and the exact envelope bytes and this lane posts precisely those
///    (`clients/core/src/clean_service.rs:700-711`); without one, the same
///    envelope is posted through a paced challenge proof;
/// 4. the answer — `{id, sequence}` with `sequence >= 1` and the identifier
///    this device sent — is committed through `accepted_v2` **before** the
///    delivery mark it produces is published
///    (`docs/protocol/self-service-v2.md:56-58`,
///    `docs/protocol/first-contact-v1.md:122-127`).
///
/// ## What one rejection does
///
/// A 409 (`binding_conflict`) and a 507 (`quota_exceeded`, the recipient's
/// mailbox is full) are **deferred**: that envelope stays in the outbox, the
/// rest of the batch is still offered, and the last deferred rejection is
/// thrown when the pass ends so the lane backs off and the user is told
/// (`docs/protocol/self-service-v2.md:80-81`, `RealtimeLoop.java:228`).
/// Everything else ends the pass at once, because a device that cannot
/// authorize one envelope cannot authorize the next either.
///
/// A first 401 on a signed session operation is repeated once with a freshly
/// signed nonce — a pooled socket can lose the answer after the server has
/// consumed the nonce (`RealtimeTransport.readTimeout` is 8 s and
/// `RealtimeTransport.resourceTimeout` 120 s, and the server closes idle
/// sockets promptly, `docs/protocol/realtime-v1.md:150-151`) — and a second
/// 401, a 404 or `session_exhausted` retires the session
/// (`SessionCall`, `RealtimeLoop.java:197-213`). A 429 on `/v2/session`
/// itself leaves that route alone for five seconds and this pass goes out
/// over the challenge transport (`ProofFlow.legacyWindow`,
/// `RealtimeLoop.java:192`).
///
/// ## What this lane is
///
/// It is an `actor` with no state of its own; it is driven by exactly one
/// `Task` and it awaits the network freely, because it is not the state
/// owner. Every core call and every commit happens inside
/// `StateOwner.perform`, which cannot suspend, and only `Sendable` values
/// cross: identifiers and envelope bytes out, a `Reply` in.
///
/// Unlike the receive lane it does not spin: a pass runs when the loop is
/// woken — by `start()`, by a page the receive lane has just delivered, or by
/// the user enqueueing a message — and otherwise the lane waits on the wake
/// signal, which is Android's `outbound` semaphore
/// (`RealtimeLoop.java:34,54,219`).
public actor SendLane {
    /// The session operation that posts one outbox envelope
    /// (`clients/core/src/clean_service.rs:701`).
    public static let sendOperation = "send"
    /// Where an envelope is posted (`docs/protocol/realtime-v1.md:64-66`).
    public static let messagesPath = "/v2/messages"
    /// The statuses that defer one envelope instead of ending the pass:
    /// 409 `binding_conflict` and 507 `quota_exceeded`
    /// (`docs/protocol/self-service-v2.md:80-81`, `RealtimeLoop.java:228`).
    public static let deferredStatuses: Set<Int> = [409, 507]
    /// How long an idle lane waits for a wake before it looks again
    /// (`RealtimeLoop.java:219`, `outbound.tryAcquire(1, SECONDS)`).
    public static let wakePoll: UInt64 = MonotonicClock.nanosecondsPerSecond

    /// What one pass ended up doing.
    public enum Outcome: Sendable, Equatable {
        /// There is no identity on this device yet, so nothing was dialled.
        /// The send lane does not pause for it, unlike the receive lane: it
        /// goes back to waiting for a wake (`RealtimeLoop.java:232`).
        case idle
        /// The whole outbox was offered: how many acceptances committed.
        /// A pass that deferred anything throws instead of returning.
        case sent(accepted: Int)
    }

    /// One outbox entry as it may leave the state owner: the identifier the
    /// core signs against and, for a send without a session, the exact bytes
    /// to post. Both are `Sendable`; the envelope itself is not and stays on
    /// the owner.
    private struct Outgoing: Sendable {
        let id: String
        let body: String
    }

    private let owner: StateOwner
    private let flow: ProofFlow
    private let calls: SessionCall
    private let listener: any RealtimeListener
    private let signal: WakeSignal
    private let pacer: any ProofPacer

    /// - Parameters:
    ///   - owner: the state owner; every core call and every commit runs on it
    ///     and nowhere else.
    ///   - flow: registration, discovery, session issuance and the paced
    ///     challenge proofs, awaited from this lane's own task.
    ///   - transport: the pinned network, for the session operations the core
    ///     signs.
    ///   - listener: where the online flag and the delivery marks go; invoked
    ///     on the owner only.
    ///   - signal: the wake seam this lane waits on; `StateOwner.wake()` and
    ///     the receive lane arm it.
    ///   - pacer: how the wake poll and the backoff are waited out.
    public init(owner: StateOwner,
                flow: ProofFlow,
                transport: any ProofTransport,
                listener: any RealtimeListener,
                signal: WakeSignal,
                pacer: any ProofPacer = SleepingPacer()) {
        self.owner = owner
        self.flow = flow
        self.calls = SessionCall(owner: owner, transport: transport)
        self.listener = listener
        self.signal = signal
        self.pacer = pacer
    }

    // MARK: - One pass over the outbox

    /// One connection and one pass over the outbox
    /// (`RealtimeLoop.java:219-231`).
    ///
    /// - Parameter generation: the run this pass belongs to. It is revalidated
    ///   on the owner before every core call and before every request, so a
    ///   result that returns under a superseded run grants no authority
    ///   (`docs/protocol/realtime-v1.md:127-130`).
    /// - Throws: the deferred 409/507 of the pass, or the rejection that ended
    ///   it, plus `Superseded`, `SendFailure`, `TransportError`,
    ///   `SelfServiceError`, `CoreError`, `SessionFailure` or the URL loading
    ///   system's own error. Every acceptance that committed before the throw
    ///   stays committed: the outbox is a queue, not a transaction.
    @discardableResult
    public func cycle(under generation: Generation) async throws -> Outcome {
        try await owner.check(generation)
        let context: SessionModel?
        switch try await flow.connect(under: generation) {
        case .idle:
            // Local identity creation is the user's, not a lane's
            // (`RealtimeLoop.java:232`).
            return .idle
        case .proof:
            context = nil
        case .session(let session):
            context = session
        }

        let queue = try await outbox(bodies: context == nil, under: generation)
        var accepted = 0
        var deferred: Rejected?
        for envelope in queue {
            try await owner.check(generation)
            do {
                let answer: RealtimeTransport.Reply
                if let context {
                    answer = try await calls.call(context, operation: Self.sendOperation,
                                                  id: envelope.id, under: generation)
                } else {
                    // The retained challenge transport of self-service v2:
                    // the same envelope, one paced proof
                    // (`RealtimeLoop.java:226`).
                    answer = try await flow.proof(purpose: ChallengeIntent.messagePurpose,
                                                  method: "POST",
                                                  path: Self.messagesPath,
                                                  body: envelope.body,
                                                  under: generation)
                }
                try await commit(answer, for: envelope.id, under: generation)
                accepted += 1
            } catch let rejected as Rejected where Self.deferredStatuses.contains(rejected.status) {
                // "409 binding/idempotency conflict … 507 message quota"
                // (`docs/protocol/self-service-v2.md:80-81`): this envelope is
                // the server's problem with one recipient, not with this
                // device, so the rest of the batch still goes out and the
                // entry stays in the queue (`RealtimeLoop.java:228,230`).
                deferred = rejected
            }
        }
        if let deferred { throw deferred }
        return .sent(accepted: accepted)
    }

    /// The loop around `cycle` (`RealtimeLoop.java:214-241`).
    ///
    /// It runs until its generation stops being the current one, its task is
    /// cancelled or the client freezes. A pass happens only when the lane has
    /// been woken; otherwise it waits, which is `outbound.tryAcquire(1 s)`
    /// (`:219`). A failure is published as it happens — the online flag
    /// carries no debounce, exactly as Android v15 (`:236-237`) — is followed by
    /// the shared backoff, and re-arms the signal so the same queue is tried
    /// again (`:238`, `kick()`).
    ///
    /// - Parameters:
    ///   - generation: the run this lane was started under. `stop()` moves the
    ///     counter and the loop leaves at its next guard.
    ///   - cycles: an upper bound on the iterations, for the tests that drive
    ///     a fixed number of them. The application passes none.
    public func run(under generation: Generation, cycles: Int = .max) async {
        var failures = 0
        var remaining = cycles
        while remaining > 0, await owner.isCurrent(generation) {
            remaining -= 1
            guard signal.take() else {
                // Nothing to do until something wakes this lane.
                do { try await pacer.wait(nanoseconds: Self.wakePoll) } catch { return }
                continue
            }
            do {
                _ = try await cycle(under: generation)
                failures = 0
            } catch is Superseded {
                return
            } catch is CancellationError {
                return
            } catch {
                // "A failed or ambiguous save freezes the process and
                // transmits nothing from that candidate"
                // (`docs/protocol/first-contact-v1.md:173-178`): the lanes
                // stop and the user is told once (`RealtimeLoop.java:74`).
                if await owner.isFrozen {
                    let listener = self.listener
                    await owner.announce(nil) {
                        listener.authorizationLost()
                        listener.changed(connected: false, status: RealtimeStatus.storage)
                    }
                    return
                }
                guard await owner.isCurrent(generation) else { return }
                await owner.report(error, to: listener, under: generation)
                do {
                    try await pacer.wait(nanoseconds: Backoff.delay(failures: failures))
                } catch {
                    return
                }
                failures += 1
                // `kick()` (`RealtimeLoop.java:238`): the queue that failed is
                // still a queue, so the next iteration is a pass and not a
                // wait.
                signal.wake()
            }
        }
    }

    // MARK: - The outbox

    /// The outbox, oldest first, reduced to what may leave the owner
    /// (`RealtimeLoop.java:221`).
    ///
    /// - Parameter bodies: whether the envelope bytes are needed, which they
    ///   are only without a session: with one, `sign_session_v2` hands back
    ///   the exact bytes to post and this lane never composes them.
    private func outbox(bodies: Bool, under generation: Generation) async throws -> [Outgoing] {
        try await owner.perform(generation) { client in
            try client.pending().map { envelope in
                guard let id = envelope["id"] as? String, !id.isEmpty else {
                    throw SendFailure.malformedEnvelope
                }
                return Outgoing(id: id, body: bodies ? try ProofFlow.encode(envelope) : "")
            }
        }
    }

    /// One acceptance, checked and committed, and only then published
    /// (`RealtimeLoop.java:227`).
    ///
    /// The answer arrives as text, which is `Sendable`, and is decoded inside
    /// the owner's closure. `accepted(envelope:response:)` refuses an answer
    /// that names another envelope or carries a sequence below 1, and commits
    /// `accepted_v2` before the delivery mark it produces can be read
    /// (`docs/protocol/self-service-v2.md:56-58`).
    private func commit(_ answer: RealtimeTransport.Reply,
                        for id: String,
                        under generation: Generation) async throws {
        let listener = self.listener
        try await owner.perform(generation) { client in
            let response = try answer.json()
            guard let envelope = try client.pending().first(where: { $0["id"] as? String == id })
            else { throw SendFailure.unknownEnvelope(id) }
            try client.accepted(envelope: envelope, response: response)
            listener.changed(connected: true, status: RealtimeStatus.connected)
        }
    }
}
