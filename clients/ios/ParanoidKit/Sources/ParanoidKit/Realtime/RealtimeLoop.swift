import Foundation

/// The wake seam of a running loop: Android's `outbound` semaphore
/// (`clients/android/src/org/paranoid/text/RealtimeLoop.java:34,54,219`).
///
/// It holds at most one permit, exactly as `kick()` does
/// (`if(outbound.availablePermits()==0)outbound.release()`): a hundred wakes
/// while the send lane is busy are one pass afterwards, never a hundred. The
/// permit carries nothing — no payload, no authority, no reason — so a wake is
/// only ever "look at the outbox now", and everything the client learns still
/// comes from the core over the authenticated transport.
///
/// It is the `PushHook` this client installs, which is what makes
/// `StateOwner.start()` and `StateOwner.wake()` the way in: the receive lane
/// wakes the send lane after a page, and the application wakes it when the
/// user enqueues a message.
///
/// A lane that has nothing to do **waits** on the signal rather than looking
/// at it again later, which is the other half of `tryAcquire(1, SECONDS)`: a
/// kick resumes the lane at once, so the message the user just wrote leaves
/// the device now and not at the end of a poll.
///
/// A wait is taken in two steps, the way `RealtimeTransport.Gate` takes a
/// slot: `enroll()` reserves a ticket **before** the caller suspends, and
/// `wait(ticket:)` suspends on it. A wake or an `endWait()` that arrives in
/// between releases the ticket, so `wait` returns at once instead of waiting
/// for a permit that has already been and gone — the one hazard a suspended
/// wait has. Every waiter is resumed exactly once, because its continuation is
/// taken out of the table under the lock before it is resumed.
public final class WakeSignal: PushHook, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    /// Tickets that have been taken and not released yet.
    private var pending: Set<UInt64> = []
    /// The continuation of every ticket whose caller is suspended right now.
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var issued: UInt64 = 0

    public init() {}

    /// Arms the signal and resumes whoever is waiting for it. It never blocks:
    /// it is called from the state owner.
    public func wake() {
        lock.lock()
        armed = true
        let waiting = releaseAll()
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// Consumes the permit, if there is one.
    ///
    /// - Returns: whether a pass was asked for since the last call.
    public func take() -> Bool {
        lock.withLock {
            let armed = self.armed
            self.armed = false
            return armed
        }
    }

    /// Reserves a place in the wait. It must be taken before the caller
    /// suspends, so that nothing that happens in between is lost.
    ///
    /// It is the lane's side of this seam, with `wait(ticket:)`: the two are
    /// how `SendLane` waits for a kick rather than looking again later.
    public func enroll() -> UInt64 {
        lock.withLock {
            issued += 1
            pending.insert(issued)
            return issued
        }
    }

    /// Suspends on `ticket` until it is released — by a wake, by the bound or
    /// by a lane that stopped — and returns at once if it already was, or if a
    /// permit is armed. The permit is not consumed here: `take()` consumes it.
    public func wait(ticket: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard pending.contains(ticket), !armed else {
                pending.remove(ticket)
                lock.unlock()
                continuation.resume()
                return
            }
            waiters[ticket] = continuation
            lock.unlock()
        }
    }

    /// Ends every wait that no permit arrived for: the bound elapsed, or the
    /// lane was stopped. Releasing nobody is a no-op, so it is safe to call
    /// whenever a wait may be over.
    public func endWait() {
        lock.lock()
        let waiting = releaseAll()
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// Releases every ticket and hands back the continuations to resume.
    /// The caller holds the lock and resumes them after unlocking, because a
    /// resumption must never run under it.
    private func releaseAll() -> [CheckedContinuation<Void, Never>] {
        pending.removeAll()
        let waiting = Array(waiters.values)
        waiters.removeAll()
        return waiting
    }
}

/// One signed session operation, with the one repeat a pooled socket needs:
/// the port of `RealtimeLoop.sessionCall(long, Session, String, String)`
/// (`RealtimeLoop.java:197-213`), shared by both lanes exactly as it is there.
///
/// The core decides everything about the request — `sign_session_v2` answers
/// with the method, the path, the body and the `Authorization` value
/// (`clients/core/src/clean_service.rs:700-728`) — and this type sends
/// precisely that, so the bytes that were signed and the bytes that go out
/// cannot drift apart.
///
/// The first 401 is repeated once with a **freshly signed** nonce, because the
/// server can consume a nonce and then lose the answer on a socket it closed
/// (`docs/protocol/realtime-v1.md:150-151`); the request is signed again
/// rather than replayed, so nothing about it is reused, and the repeat happens
/// once and never twice. A second 401, a 404 or `session_exhausted` means the
/// session has stopped being usable: it is dropped, and a 401 or a 404 also
/// rediscovers the capability before anything else is tried (`:172-177`).
/// `session_exhausted` does not: the session ran out of nonces
/// (`server/src/self_service_http.rs:489`), which says nothing about the
/// server's routes.
public struct SessionCall: Sendable {
    /// The code that retires a session for good: 2048 nonces consumed
    /// (`docs/protocol/realtime-v1.md:168`).
    public static let sessionExhausted = "session_exhausted"

    private let owner: StateOwner
    private let transport: any ProofTransport

    public init(owner: StateOwner, transport: any ProofTransport) {
        self.owner = owner
        self.transport = transport
    }

    /// - Parameters:
    ///   - context: the session to sign against.
    ///   - operation: `send`, `messages`, `events` or `turn`
    ///     (`docs/protocol/realtime-v1.md:64-69`).
    ///   - id: the outbox identifier a `send` names, `nil` otherwise.
    ///   - generation: the lane's run, revalidated on the owner before the
    ///     request is signed and again before it is sent.
    public func call(_ context: SessionModel,
                     operation: String,
                     id: String? = nil,
                     under generation: Generation) async throws -> RealtimeTransport.Reply {
        var retried = false
        while true {
            let signed = try await owner.perform(generation) { client in
                try SignedRequest(try client.sessionRequest(session: context.context,
                                                            operation: operation, id: id))
            }
            try await owner.check(generation)
            do {
                return try await transport.call(method: signed.method, path: signed.path,
                                                body: signed.body,
                                                authorization: signed.authorization)
            } catch let rejected as Rejected {
                if rejected.status == 401, !retried {
                    retried = true
                    continue
                }
                if rejected.status == 401 || rejected.status == 404
                    || rejected.code == Self.sessionExhausted {
                    await owner.dropSession(ifHeld: context)
                }
                if rejected.status == 401 || rejected.status == 404 {
                    await owner.invalidateDiscovery()
                }
                throw rejected
            }
        }
    }
}

extension StateOwner {
    /// What one failed cycle tells the application, in Android's order:
    /// `authorityFailure` and then `publish`
    /// (`RealtimeLoop.java:83-86,236-237,279-280`).
    ///
    /// A 401 is an authorization answer before it is a connection one, so the
    /// application hears `authorizationLost()` first and exactly once per
    /// failed cycle — the lane never reports the same rejection twice, because
    /// the one repeat inside `SessionCall` is not a failure until it has
    /// failed a second time. Every other status, every transport failure and
    /// every core rejection is a connection problem and nothing else.
    ///
    /// Both notifications run on the owner and a superseded run says nothing
    /// at all (`announce`).
    public func report(_ error: any Error,
                       to listener: any RealtimeListener,
                       under generation: Generation) {
        if let rejected = error as? Rejected, rejected.status == 401 {
            announce(generation) { listener.authorizationLost() }
        }
        let status = RealtimeStatus.message(for: error)
        #if DEBUG
        // A device build has no debugger attached and the client logs nothing
        // on purpose, so a lane failure on a phone is otherwise invisible. This
        // names the error type and its own description; it carries no snapshot,
        // credential, pin or body, and the Release build compiles it away.
        print("realtime: lane failed: \(type(of: error)): \(error)")
        #endif
        announce(generation) { listener.changed(connected: false, status: status) }
    }
}

/// The two lanes and the lifecycle around them: the port of `RealtimeLoop`
/// itself (`RealtimeLoop.java:9-56,295`).
///
/// It owns nothing that the state owner owns. `StateOwner` holds the client,
/// the session, the discovered capability and the run counter; this type holds
/// the two lanes, the wake signal and the task group they run in, and it is
/// the one place the application talks to:
///
/// - `start()` mints a generation only if the lanes were stopped
///   (`RealtimeLoop.java:53`) and arms the signal, so the first pass of the
///   send lane happens at once;
/// - `stop()` moves the counter, which is what makes every answer still in
///   flight worthless; the session, the capability and the state stay exactly
///   as they are, because a pause is not a reset
///   (`docs/protocol/realtime-v1.md:179-181`, and the account has two
///   live-session slots, `server/src/self_service_http.rs:377-391`);
/// - `run()` runs both lanes until the generation they started under is
///   superseded, and returns.
///
/// The application therefore does `await loop.start()` and then
/// `Task { await loop.run() }`; `didEnterBackground` calls `stop()`, which
/// ends that task. There is no push and no background delivery in this client
/// (`docs/clients/ios/README.md`), so nothing else starts a lane.
public final class RealtimeLoop: Sendable {
    /// The state owner the lanes share.
    public let owner: StateOwner
    /// The lane that reads the inbox.
    public let receive: ReceiveLane
    /// The lane that empties the outbox.
    public let send: SendLane

    private let signal: WakeSignal

    /// - Parameters:
    ///   - owner: the state owner. It must have been built with `signal` as
    ///     its `PushHook`, so that `StateOwner.wake()` reaches the send lane.
    ///   - flow: registration, discovery, session issuance and the paced
    ///     challenge proofs.
    ///   - transport: the pinned network.
    ///   - listener: where the online flag, the pages and the delivery marks
    ///     go; invoked on the owner only.
    ///   - signal: the wake seam, shared with the owner.
    ///   - pacer: how both lanes wait.
    public init(owner: StateOwner,
                flow: ProofFlow,
                transport: any ProofTransport,
                listener: any RealtimeListener,
                signal: WakeSignal,
                pacer: any ProofPacer = SleepingPacer()) {
        self.owner = owner
        self.signal = signal
        receive = ReceiveLane(owner: owner, flow: flow, transport: transport,
                              listener: listener, pacer: pacer)
        send = SendLane(owner: owner, flow: flow, transport: transport,
                        listener: listener, signal: signal, pacer: pacer)
    }

    /// Starts the lanes, minting a generation only if they were stopped.
    ///
    /// - Returns: the generation in force after the call.
    @discardableResult
    public func start() async -> Generation {
        await owner.start()
    }

    /// Pauses the lanes. Every result still in flight is refused when it comes
    /// back, and `run()` returns.
    public func stop() async {
        await owner.stop()
    }

    /// Ends this loop for good (`RealtimeLoop.close()`, `:295`).
    public func close() async {
        await owner.close()
    }

    /// Asks the send lane to run a pass now (`RealtimeLoop.kick()`, `:54`):
    /// the user enqueued a message, or a page has just been delivered.
    public func wake() {
        signal.wake()
    }

    /// Runs both lanes under the current generation until it is superseded.
    ///
    /// The two are separate tasks on purpose: "networking has separate
    /// send/wait lanes and bounded handoff"
    /// (`docs/protocol/realtime-v1.md:127-128`), so a receive lane parked on a
    /// twenty-second long poll never delays an outgoing message, and neither
    /// of them ever runs on the state owner. A stopped or closed loop runs
    /// nothing and returns at once.
    public func run() async {
        guard let generation = await owner.current else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [receive] in await receive.run(under: generation) }
            group.addTask { [send] in await send.run(under: generation) }
        }
    }
}
