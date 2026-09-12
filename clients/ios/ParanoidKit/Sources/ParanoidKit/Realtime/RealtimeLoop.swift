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
public final class WakeSignal: PushHook, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    public init() {}

    /// Arms the signal. It never blocks: it is called from the state owner.
    public func wake() {
        lock.withLock { armed = true }
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
