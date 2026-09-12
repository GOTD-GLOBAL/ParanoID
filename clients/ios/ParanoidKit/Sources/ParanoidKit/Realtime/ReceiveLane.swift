import Foundation

/// What the realtime lanes tell the application, and the one rule about when.
///
/// It is `RealtimeLoop.Listener` (`clients/android/src/org/paranoid/text/RealtimeLoop.java:11-14`)
/// with the same two members. Both are invoked **on the state owner** and
/// nowhere else, because the property they exist to carry is an ordering one:
/// "Renderer publication follows successful full native candidate persistence
/// and precedes receipt network completion"
/// (`docs/protocol/realtime-v1.md:97-99`). A listener that ran on its own
/// thread could observe a message the device has not stored, and the fixture
/// that proves it cannot (`clients/android/test/RealtimeBridge.java:33-52`)
/// works precisely because the notification and the commit share one owner.
///
/// The listener therefore must not block and must not call the network: it is
/// running where the ratchet lives. Reading the client's public view is what
/// it is for.
public protocol RealtimeListener: Sendable {
    /// The online flag and the text beside it, published without a debounce:
    /// Android v15 publishes every transition as it happens
    /// (`RealtimeLoop.java:237,261-263,268,280`), and a durable control is
    /// never gated behind a settling timer.
    func changed(connected: Bool, status: String)
    /// The server refused to authorize this device (a 401), or a commit
    /// failed and the client froze (`RealtimeLoop.java:74,85`).
    func authorizationLost()
}

extension RealtimeListener {
    public func authorizationLost() {}
}

/// The status texts the lanes publish beside the online flag.
///
/// They are `RealtimeLoop.errorMessage(Exception)` (`:286-294`) and the freeze
/// notice of `:74`, kept verbatim because they are shown to the user, plus the
/// 404 of `TextEngine.userError` (`TextEngine.java:198-207`), which Android's
/// lanes do not distinguish. Every one of them says the same thing in
/// different words — nothing was lost — and none of them ever names a server,
/// an account or a message.
///
/// This is the only Russian in the package: a quoted UI string.
public enum RealtimeStatus {
    /// `RealtimeLoop.java:175,227,263,268`.
    public static let connected = "Подключено"
    /// A commit failed, so the lanes stop (`RealtimeLoop.java:74`).
    public static let storage = "Ошибка хранения. Данные сохранены; подключение остановлено."
    /// 507 (`:289`).
    public static let serverFull = "Хранилище сервера заполнено. Сообщения сохранены в очереди."
    /// 401 and 409 (`:290`).
    public static let unconfirmed = "Не удалось подтвердить подключение. ID и сообщения сохранены."
    /// 429 (`:291`).
    public static let busy = "Сервер занят. Повторяем подключение."
    /// 404: a route this server does not have (`TextEngine.java:199`).
    public static let unsupported = "Сервер пока не поддерживает эту версию. Ваш ID, контакты и очередь сохранены."
    /// Everything else (`:293`).
    public static let offline = "Нет подключения. Сообщения сохранены в очереди."

    /// What one failed cycle is reported as (`RealtimeLoop.java:286-294`).
    ///
    /// Only an HTTP status is read; a transport failure, a refused pin, a
    /// timeout and a core rejection are all "no connection", because none of
    /// them is something the user can act on differently.
    ///
    /// The one addition to Android's lane texts is 404. `errorMessage` has no
    /// case for it and reports "нет подключения", while the same status on the
    /// same routes is "сервер пока не поддерживает эту версию" when a user
    /// operation meets it (`TextEngine.java:199`). A 404 here is a route this
    /// server does not have — it is what retires the session and rediscovers
    /// the capability (`docs/protocol/realtime-v1.md:172-177`) — so the
    /// accurate half of Android's own wording is the one that is published.
    public static func message(for error: any Error) -> String {
        guard let rejected = error as? Rejected else { return offline }
        switch rejected.status {
        case 507: return serverFull
        case 401, 409: return unconfirmed
        case 429: return busy
        case 404: return unsupported
        default: return offline
        }
    }
}

/// The four members `sign_session_v2` answers with
/// (`clients/core/src/clean_service.rs:713-728`).
///
/// The core decides the method, the path and the body of every session
/// operation; a lane sends exactly what it was handed and never composes a
/// route of its own, so the bytes that are signed and the bytes that are sent
/// cannot drift apart. The value is `Sendable`, which is what lets it leave
/// the state owner for the lane's own task.
public struct SignedRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: String
    public let authorization: String

    public init(method: String, path: String, body: String, authorization: String) {
        self.method = method
        self.path = path
        self.body = body
        self.authorization = authorization
    }

    /// Reads one `sign_session_v2` reply.
    ///
    /// - Throws: `SelfServiceError.malformedReply` when the core answered
    ///   something this lane cannot send.
    public init(_ reply: [String: Any]) throws {
        guard let method = reply["method"] as? String,
              let path = reply["path"] as? String,
              let body = reply["body"] as? String,
              let authorization = reply["authorization"] as? String
        else { throw SelfServiceError.malformedReply("sign_session_v2") }
        self.init(method: method, path: path, body: body, authorization: authorization)
    }
}

/// Why one receive cycle refused the page it was handed.
///
/// None of these ever reaches the core: the page is dropped whole, nothing is
/// committed and nothing is published, and the lane retries after its backoff.
public enum ReceiveFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The 200 body carried no `messages` array (`RealtimeLoop.java:257`).
    case malformedPage
    /// More than twenty events in one page: the client asked for twenty and
    /// "Java sync pages at most 20 events"
    /// (`docs/protocol/first-contact-v1.md:165`, `RealtimeLoop.java:258`).
    /// The number is what arrived.
    case pageLimit(Int)
    /// The receive cursor moved between the request and the delivery, so this
    /// page names events another cycle may already have applied
    /// (`RealtimeLoop.java:260`).
    case stalePage

    public var description: String {
        switch self {
        case .malformedPage: return "page without a messages array"
        case .pageLimit(let count): return "page of \(count) events above the 20-event limit"
        case .stalePage: return "stale receive page"
        }
    }
}

extension StateOwner {
    /// Says something to a listener, on the owner (`RealtimeLoop.publish`,
    /// `:79-82`).
    ///
    /// A superseded run says nothing at all, which is what keeps a lane that
    /// was paused from writing "нет подключения" over the state a live
    /// generation is publishing. `nil` is the freeze notice of `:74`: by then
    /// the lanes are already disabled, so no run is current, and the one thing
    /// a frozen client still has to say is that it froze. Unlike `perform`,
    /// this never touches the client, so a frozen one cannot silence it.
    public func announce(_ generation: Generation?, _ body: @Sendable () -> Void) {
        if let generation, !isCurrent(generation) { return }
        body()
    }

    /// Forgets `session`, but only while it is still the held one
    /// (`RealtimeLoop.java:207`, `if(session==context)session=null`).
    ///
    /// A rejection belongs to the session the lane signed against. If the
    /// other lane has renewed in the meantime, dropping would throw away a
    /// session nothing is wrong with and spend one of the account's two slots
    /// (`server/src/self_service_http.rs:377-391`) reopening it. The
    /// comparison and the drop are one isolated step, so nothing can renew
    /// between them.
    public func dropSession(ifHeld session: SessionModel) {
        guard self.session?.id == session.id else { return }
        dropSession()
    }
}

/// The lane that reads the inbox: the port of `RealtimeLoop.receiveLoop()`
/// (`clients/android/src/org/paranoid/text/RealtimeLoop.java:242-283`).
///
/// One cycle is one page, and the page is the point. Everything below exists
/// to make a single sentence true — "Renderer publication follows successful
/// full native candidate persistence and precedes receipt network completion"
/// (`docs/protocol/realtime-v1.md:97-99`) — so the order inside `deliver` is
/// the specification and not an implementation detail:
///
/// 1. the page is refused if it carries more than twenty events
///    (`docs/protocol/first-contact-v1.md:165`);
/// 2. the cursor is read again **on the owner** and must still be the one the
///    request was signed with, or the page is dropped whole;
/// 3. `changed(true, "Подключено")` is published *before* the page is
///    delivered, so call signalling sees an online client when a `call`
///    control arrives inside it (`RealtimeLoop.java:261-263`,
///    `docs/clients/core/voice-calls.md:54-58`);
/// 4. every event is handed to `receive_v2` **one by one**, and each one is
///    durable — sealed, renamed, read back — before the notification that
///    follows it. A UI that has seen an event has an event the device would
///    still have after a power cut;
/// 5. only then is the send lane woken, so a receipt leaves this device after
///    the message it acknowledges has been published, never before
///    (`RealtimeLoop.java:264-273`).
///
/// ## Which operation, and when
///
/// The first cycle of a generation asks for `messages` and every later one for
/// `events` (`RealtimeLoop.java:254`): a resumed client must find out whether
/// its inbox is empty *now* rather than discover it after a twenty-second
/// long poll. A 429 `waiter_busy` — the account's one wait slot, or the
/// server's eight, is taken (`docs/protocol/realtime-v1.md:102-103`) — is
/// answered by reading the inbox straight away instead of queueing for the
/// slot, and that cycle counts as polling. Without a session at all the same
/// page is fetched through the retained challenge transport
/// (`GET /v2/messages?after=…&limit=20`), which is polling too; a polling
/// cycle that came back short waits three seconds so that it does not spin
/// (`RealtimeLoop.java:274`).
///
/// ## What this lane is
///
/// It is an `actor` with one field of its own — which generation last
/// delivered a page — and it is driven by exactly one `Task`. It awaits the
/// network freely, because it is not the state owner: every core call and
/// every commit it needs happens inside `StateOwner.perform`, which cannot
/// suspend. Nothing but `Sendable` values crosses between the two: a signed
/// request and a `Reply` out and in, an event count back. The decoded page is
/// built on the owner, in the same closure that commits it, so a decoded core
/// value never travels.
public actor ReceiveLane {
    /// The most events one page may carry
    /// (`docs/protocol/first-contact-v1.md:165`).
    public static let pageLimit = 20
    /// How long a polling cycle that came back short waits
    /// (`RealtimeLoop.java:274`).
    public static let pollPause: UInt64 = 3 * MonotonicClock.nanosecondsPerSecond
    /// How long the lane waits while there is no identity to talk about
    /// (`RealtimeLoop.java:275`).
    public static let idlePause: UInt64 = 500_000_000
    /// The long-poll operation (`GET /v2/events?after=…&limit=20`).
    public static let eventsOperation = "events"
    /// The immediate-read operation (`GET /v2/messages?after=…&limit=20`).
    public static let messagesOperation = "messages"
    /// The 429 code that means "the wait slot is taken"
    /// (`server/src/self_service_http.rs:606`).
    public static let waiterBusy = "waiter_busy"

    /// What one cycle ended up doing.
    public enum Outcome: Sendable, Equatable {
        /// There is no identity on this device yet, so nothing was dialled
        /// (`RealtimeLoop.java:171,275`).
        case idle
        /// One page was delivered: how many events it carried, and whether
        /// this cycle was polling rather than waiting.
        case delivered(events: Int, polling: Bool)
    }

    private let owner: StateOwner
    private let flow: ProofFlow
    private let calls: SessionCall
    private let listener: any RealtimeListener
    private let pacer: any ProofPacer

    /// The generation that last delivered a page, and therefore the one that
    /// may wait on `events` (`RealtimeLoop.java:244,272`).
    private var observed: Generation?

    /// - Parameters:
    ///   - owner: the state owner; every core call and every commit runs on
    ///     it and nowhere else.
    ///   - flow: registration, discovery and session issuance, awaited from
    ///     this lane's own task.
    ///   - transport: the pinned network, for the session operations the core
    ///     signs.
    ///   - listener: where the online flag and the page go; invoked on the
    ///     owner only.
    ///   - pacer: how the three-second polling pause, the idle pause and the
    ///     backoff are waited out.
    public init(owner: StateOwner,
                flow: ProofFlow,
                transport: any ProofTransport,
                listener: any RealtimeListener,
                pacer: any ProofPacer = SleepingPacer()) {
        self.owner = owner
        self.flow = flow
        self.calls = SessionCall(owner: owner, transport: transport)
        self.listener = listener
        self.pacer = pacer
    }

    // MARK: - One cycle

    /// One connection, one page and its delivery
    /// (`RealtimeLoop.java:247-274`).
    ///
    /// - Parameter generation: the run this cycle belongs to. It is
    ///   revalidated on the owner before every core call and before the
    ///   request goes out, so a result that returns under a superseded run
    ///   grants no authority (`docs/protocol/realtime-v1.md:127-130`).
    /// - Throws: `Superseded`, `ReceiveFailure`, `Rejected`, `TransportError`,
    ///   `SelfServiceError`, `CoreError`, `SessionFailure` or the URL loading
    ///   system's own error. Nothing is committed and nothing is published
    ///   when it throws.
    @discardableResult
    public func cycle(under generation: Generation) async throws -> Outcome {
        try await owner.check(generation)
        let context: SessionModel?
        switch try await flow.connect(under: generation) {
        case .idle:
            // Local identity creation is the user's, not a lane's
            // (`RealtimeLoop.java:275`).
            try await pause(Self.idlePause, under: generation)
            return .idle
        case .proof:
            context = nil
        case .session(let session):
            context = session
        }

        let after = try await owner.perform(generation) { try $0.receiveCursor() }
        var polling = context == nil
        let page: RealtimeTransport.Reply
        if let context {
            let operation = observed == generation ? Self.eventsOperation : Self.messagesOperation
            do {
                page = try await sessionPage(context, operation: operation, under: generation)
            } catch let busy as Rejected where busy.status == 429 && busy.code == Self.waiterBusy {
                // "At most eight concurrent event waits globally and one per
                // account… Excess receives 429 without an unbounded permit
                // queue" (`docs/protocol/realtime-v1.md:102-103`). Queueing for
                // the slot would be the one thing the server asked the client
                // not to do, so this cycle reads the inbox instead of waiting
                // for it, and pauses afterwards like any other poll
                // (`RealtimeLoop.java:255`).
                page = try await sessionPage(context, operation: Self.messagesOperation,
                                             under: generation)
                polling = true
            }
        } else {
            // No session: the retained challenge transport of self-service v2
            // (`docs/protocol/realtime-v1.md:177`, `RealtimeLoop.java:250`).
            page = try await flow.proof(purpose: ChallengeIntent.messagePurpose,
                                        method: "GET",
                                        path: "/v2/messages?after=\(after)&limit=\(Self.pageLimit)",
                                        body: "",
                                        under: generation)
        }

        let delivered = try await deliver(page, after: after, under: generation)
        observed = generation
        // The receipts the core queued inside those candidates may go now, and
        // not before: they acknowledge messages the UI has already seen
        // (`RealtimeLoop.java:273`).
        owner.wake()
        if polling, delivered < Self.pageLimit {
            try await pause(Self.pollPause, under: generation)
        }
        return .delivered(events: delivered, polling: polling)
    }

    /// The loop around `cycle` (`RealtimeLoop.java:242-283`).
    ///
    /// It runs until its generation stops being the current one, its task is
    /// cancelled or the client freezes. A failure is published as it happens —
    /// the online flag carries no debounce, exactly as Android v15
    /// (`RealtimeLoop.java:237,280`) — and is followed by the shared backoff.
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
                // (`docs/protocol/first-contact-v1.md:173-178`): the lanes stop
                // and the user is told once (`RealtimeLoop.java:74`).
                if await owner.isFrozen {
                    let listener = self.listener
                    await owner.announce(nil) {
                        listener.authorizationLost()
                        listener.changed(connected: false, status: RealtimeStatus.storage)
                    }
                    return
                }
                guard await owner.isCurrent(generation) else { return }
                await report(error, under: generation)
                do {
                    try await pacer.wait(nanoseconds: Backoff.delay(failures: failures))
                } catch {
                    return
                }
                failures += 1
            }
        }
    }

    // MARK: - The page

    /// One page through the session transport: `SessionCall` is the shared
    /// `RealtimeLoop.sessionCall` (`:197-213`), so the one repeat after a 401
    /// and the rules that retire a session are the same in both lanes.
    private func sessionPage(_ context: SessionModel,
                             operation: String,
                             under generation: Generation) async throws -> RealtimeTransport.Reply {
        try await calls.call(context, operation: operation, under: generation)
    }

    /// The page, decoded, checked and applied — all of it on the owner
    /// (`RealtimeLoop.java:257-271`).
    ///
    /// The body arrives as text, which is `Sendable`, and is decoded inside
    /// the owner's closure: a decoded `[String: Any]` is exactly the kind of
    /// value that must not travel between a lane and the state. What comes
    /// back out is the number of events, which is safe anywhere.
    ///
    /// - Returns: how many events the page carried.
    private func deliver(_ reply: RealtimeTransport.Reply,
                         after: Int64,
                         under generation: Generation) async throws -> Int {
        let listener = self.listener
        let limit = Self.pageLimit
        return try await owner.perform(generation) { client -> Int in
            let body = try reply.json()
            guard let events = body["messages"] as? [[String: Any]] else {
                throw ReceiveFailure.malformedPage
            }
            guard events.count <= limit else { throw ReceiveFailure.pageLimit(events.count) }
            // The cursor is rechecked here, on the owner, against the value the
            // request was signed with: another cycle may have applied these
            // very events while this page was in flight, and "new below-cursor
            // events are refused" is a rule the core would then enforce by
            // rejecting the whole candidate (`RealtimeLoop.java:260`).
            guard try client.receiveCursor() == after else { throw ReceiveFailure.stalePage }
            // Before the page, so that a `call` control inside it is observed
            // by an application that already knows it is online
            // (`RealtimeLoop.java:261-263`).
            listener.changed(connected: true, status: RealtimeStatus.connected)
            for event in events {
                // `received` returns only once the whole candidate — the
                // plaintext, the history and the receipt the core queued with
                // it — is sealed, renamed and read back.
                try client.received(message: event)
                listener.changed(connected: true, status: RealtimeStatus.connected)
            }
            return events.count
        }
    }

    // MARK: - Waiting and reporting

    /// `RealtimeLoop.pause(long,long)` (`:153-157`): the wait is abandoned by
    /// cancelling this lane's task, and the run is revalidated afterwards so
    /// that a lane that was paused through does not carry on.
    private func pause(_ nanoseconds: UInt64, under generation: Generation) async throws {
        try await pacer.wait(nanoseconds: nanoseconds)
        try await owner.check(generation)
    }

    /// `RealtimeLoop.authorityFailure` and `publish` (`:83-86,279-280`), in
    /// that order: a 401 is an authorization answer before it is a connection
    /// one. Both lanes report through the same member of the owner.
    private func report(_ error: any Error, under generation: Generation) async {
        await owner.report(error, to: listener, under: generation)
    }
}
