import Foundation

/// One saved realm and pin, dialled over `URLSession`; at most two requests at
/// a time.
///
/// The port of `RealtimeTransport.java:14-73` and of the client half of
/// `docs/protocol/realtime-v1.md:135-151`. Everything the Java class decides
/// per connection is decided here per session and per request:
///
/// | Rule (`RealtimeTransport.java`)          | Here                                              |
/// |------------------------------------------|---------------------------------------------------|
/// | `Proxy.NO_PROXY` (`:33`)                 | `connectionProxyDictionary = [:]`                 |
/// | pinned socket factory (`:35`)            | `PinnedSessionDelegate` (nine checks)             |
/// | `setInstanceFollowRedirects(false)` (`:35`) | `willPerformHTTPRedirection` answers `nil`     |
/// | connect 8 s, read 30 s / 8 s (`:36`)     | `timeoutIntervalForRequest` and `timeoutInterval` |
/// | `Semaphore(2)` (`:18`, `:30`)            | `Gate` + `httpMaximumConnectionsPerHost = 2`      |
/// | `/health` or `/v2/…`, no `#`/CR/LF (`:26`) | the same test, before anything is opened        |
/// | GET or POST only (`:28-29`)              | the same test                                     |
/// | POST body ≤ 65536 B (`:41`)              | `requestLimit`, refused before the socket is used |
/// | 200 body ≤ 2 MiB (`:50-51`)              | `responseLimit`, the rest is never read           |
/// | error body ≤ 4096 B (`:50-51`)           | `errorLimit`, the rest is dropped, status kept    |
/// | `error` code `[a-z_]{1,40}` (`:56`)      | `Rejected.code(inErrorBody:)`                     |
/// | `Accept: application/json` (`:37`)       | the same header, and exactly one `Authorization`  |
/// | `disconnect()` on cancel (`:67-72`)      | `cancelActive()` / `close()`                      |
///
/// Two rules read differently on iOS and are written out where they differ:
///
/// - **Capacity.** Android fails a third concurrent call immediately
///   (`tryAcquire`, `:30`); here the third caller *waits* for one of the two
///   slots, because a Swift caller is an `async` task that costs nothing while
///   suspended, and a queued signed request is better than a lost one. The
///   ceiling is the same two sockets per realm
///   (`docs/protocol/realtime-v1.md:150-151`).
/// - **`Connection: close`.** Foundation reserves the `Connection` header and
///   drops it from a `URLRequest`, so a one-shot lane
///   (`KeyTransport.java:19-20`, `VoiceRelayTransport.java:37`) is expressed
///   the only way the URL loading system allows: `Lane.oneShot` runs each call
///   in its own session and invalidates it afterwards, so the socket is gone
///   when the call returns. `Lane.pooled` keeps its session, which is what
///   "normal request completion does not send `Connection: close` or
///   disconnect a healthy pooled transport" asks for
///   (`docs/protocol/realtime-v1.md:147-149`).
///
/// A pooled socket can die between two requests — the server closes idle
/// sockets promptly (`docs/protocol/realtime-v1.md:150-151`) and can drop a
/// connection in the middle of a long poll. `call` therefore repeats the
/// **identical** request exactly once, and only when the URL loading system
/// says the connection was lost. The request is immutable: the same bytes, the
/// same one-shot `Authorization`, so the server sees a replay it can refuse
/// with 401 rather than a second, different operation. Never twice: a second
/// failure is the caller's to handle (`RealtimeLoop.java:203-205` retries the
/// *signed* operation once for the same reason).
public final class RealtimeTransport: @unchecked Sendable {
    // MARK: - Limits and deadlines

    /// POST bodies larger than this are refused before anything is sent
    /// (`RealtimeTransport.java:41`).
    public static let requestLimit = 65536
    /// A 200 body larger than this fails the call (`RealtimeTransport.java:50`).
    public static let responseLimit = 2 * 1024 * 1024
    /// An error body is kept up to this size and truncated after it
    /// (`RealtimeTransport.java:50`).
    public static let errorLimit = 4096
    /// Connect and read bound of every request but a long poll
    /// (`RealtimeTransport.java:36`).
    public static let readTimeout: TimeInterval = 8
    /// Read bound of `/v2/events?…`, above the server's 25-second handler
    /// deadline (`docs/protocol/realtime-v1.md:140`, `:153-154`).
    public static let eventsReadTimeout: TimeInterval = 30
    /// The absolute bound of one request, the server's own socket lifetime
    /// (`docs/protocol/realtime-v1.md:144-145`).
    public static let resourceTimeout: TimeInterval = 120
    /// Requests in flight at once, per realm
    /// (`RealtimeTransport.java:18`, `docs/protocol/realtime-v1.md:150`).
    public static let capacity = 2
    /// The only path that gets the long-poll read bound
    /// (`RealtimeTransport.java:36`).
    public static let eventsPrefix = "/v2/events?"

    /// Which socket policy one transport follows.
    public enum Lane: Sendable {
        /// The realtime lane: one session, keep-alive, two sockets
        /// (`RealtimeTransport.java`).
        case pooled
        /// A negotiation-only lane that leaves no socket behind
        /// (`VoiceRelayTransport.java`, `KeyTransport.java`): one session per
        /// call, invalidated when the call returns, and one call at a time.
        case oneShot
    }

    /// One accepted answer: the 200 body, verbatim.
    ///
    /// The text is kept instead of a decoded object because a decoded
    /// `[String: Any]` is not `Sendable` and must not cross a task boundary;
    /// `json()` decodes it where it is used. Bodies carry ciphertext and
    /// session material: never log one.
    public struct Reply: Sendable {
        /// The body as the server sent it.
        public let text: String
        /// Its size in bytes, which is safe to record.
        public let bytes: Int

        public init(text: String, bytes: Int) {
            self.text = text
            self.bytes = bytes
        }

        /// The body as one JSON object (`RealtimeTransport.java:59`).
        public func json() throws -> [String: Any] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw TransportError.invalidReply
            }
            return object
        }
    }

    // MARK: - State

    /// The saved HTTPS origin, exactly as it is stored.
    public let realm: String
    /// Which socket policy this transport follows.
    public let lane: Lane
    /// Checks 1 to 9 of the pinned trust; the session delegate that owns them.
    public let pinned: PinnedSessionDelegate

    private let gate: Gate
    /// The session of a pooled lane; a one-shot lane makes one per call.
    private let pool: URLSession?

    /// - Parameters:
    ///   - realm: the saved HTTPS origin (`KeyClient.checkedRealm`).
    ///   - pin: the saved 64-hexadecimal-digit SPKI pin.
    ///   - lane: `.pooled` for the realtime lane, `.oneShot` for a
    ///     negotiation-only call.
    /// - Throws: `PinnedTrustFailure.realmFormat` or `.pinFormat`
    ///   (`RealtimeTransport.java:22-23`).
    public init(realm: String, pin: String, lane: Lane = .pooled) throws {
        let evaluator = try PinnedTrustEvaluator(realm: realm, pin: pin)
        self.realm = evaluator.realm ?? realm
        self.lane = lane
        self.pinned = PinnedSessionDelegate(evaluator: evaluator)
        self.gate = Gate(capacity: lane == .pooled ? Self.capacity : 1)
        self.pool = lane == .pooled ? Self.makeSession(pinned: pinned, lane: lane) : nil
    }

    /// The configuration every lane uses: the pinned one
    /// (`PinnedSessionDelegate.configuration()`, ephemeral, no cookies, no
    /// cache, TLS 1.2 floor) plus the transport policy of
    /// `RealtimeTransport.java:33-36`.
    public static func configuration(lane: Lane = .pooled) -> URLSessionConfiguration {
        let configuration = PinnedSessionDelegate.configuration()
        // `Proxy.NO_PROXY` (`RealtimeTransport.java:33`): an empty dictionary
        // is how the URL loading system is told to consult no proxy at all,
        // so a device profile cannot route a pinned request through a proxy.
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = lane == .pooled ? capacity : 1
        // iOS has one idle timer per request instead of Android's separate
        // connect and read bounds; this is the connect bound and the default
        // read bound, and `/v2/events?…` raises its own request's timer.
        configuration.timeoutIntervalForRequest = readTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    private static func makeSession(pinned: PinnedSessionDelegate, lane: Lane) -> URLSession {
        URLSession(configuration: configuration(lane: lane), delegate: pinned, delegateQueue: nil)
    }

    // MARK: - One call

    /// One request on this realm, as `RealtimeTransport.java:25-65`.
    ///
    /// - Parameters:
    ///   - method: `GET` or `POST`.
    ///   - path: `/health` or `/v2/…`, query included, without `#`, CR or LF.
    ///   - body: the POST body; must be empty for a GET.
    ///   - authorization: the signed one-shot credential, or `nil`.
    /// - Returns: the 200 body.
    /// - Throws: `TransportError` for a request this client refuses to make,
    ///   `Rejected` for any status but 200, and the `URLError` of the URL
    ///   loading system for a handshake, connection or timeout failure.
    public func call(method: String,
                     path: String,
                     body: String = "",
                     authorization: String? = nil) async throws -> Reply {
        // Every rule that can refuse the request is applied before a slot is
        // taken, exactly as `RealtimeTransport.java:26-30` does.
        let request = try makeRequest(method: method, path: path, body: body, authorization: authorization)
        // A caller that is cancelled while it waits for a slot must not wait
        // for ever: the ticket lets the cancellation reach exactly this waiter
        // and nobody else.
        let ticket = await gate.ticket()
        try await withTaskCancellationHandler {
            try await gate.acquire(ticket: ticket)
        } onCancel: {
            Task { await gate.cancel(ticket: ticket) }
        }
        do {
            let reply = try await send(request)
            await gate.release(ticket: ticket)
            return reply
        } catch {
            await gate.release(ticket: ticket)
            throw error
        }
    }

    /// `GET /health`, decoded (`RealtimeLoop.java:178-181`).
    public func health() async throws -> Health {
        let reply = try await call(method: "GET", path: "/health")
        return try Health.parse(reply.text)
    }

    /// Cancels whatever is in flight without replacing the saved trust
    /// (`RealtimeTransport.java:66-71`): the session, its pin and its
    /// configuration stay, so the next call needs no new factory.
    public func cancelActive() async {
        guard let pool else { return }
        for task in await pool.allTasks { task.cancel() }
    }

    /// Refuses further calls and drops every socket
    /// (`RealtimeTransport.java:72`). Callers waiting for a slot fail with
    /// `TransportError.closed`.
    public func close() async {
        await gate.close()
        pool?.invalidateAndCancel()
    }

    // MARK: - Request

    private func makeRequest(method: String,
                             path: String,
                             body: String,
                             authorization: String?) throws -> URLRequest {
        guard path == "/health" || path.hasPrefix("/v2/"),
              !path.contains("#"), !path.contains("\r"), !path.contains("\n") else {
            throw TransportError.invalidPath(path)
        }
        guard method == "GET" || method == "POST" else { throw TransportError.invalidMethod(method) }
        if method == "GET", !body.isEmpty { throw TransportError.bodyOnGet }
        guard let url = URL(string: realm + path) else { throw TransportError.invalidRealm }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The long-poll lane is the only one that may wait past the eight
        // seconds every other route is bounded by
        // (`RealtimeTransport.java:36`).
        request.timeoutInterval = path.hasPrefix(Self.eventsPrefix) ? Self.eventsReadTimeout : Self.readTimeout
        if let authorization {
            guard !authorization.isEmpty, authorization.utf8.count <= 4096,
                  !authorization.contains("\r"), !authorization.contains("\n") else {
                throw TransportError.invalidAuthorization
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if method == "POST" {
            let bytes = Data(body.utf8)
            guard bytes.count <= Self.requestLimit else { throw TransportError.requestLimit(bytes.count) }
            request.httpBody = bytes
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // One credential per request, never two: `setValue` replaces where
        // `addValue` would append, and this is the check that says so out loud.
        let credentials = (request.allHTTPHeaderFields ?? [:]).keys.filter { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        guard credentials.count == (authorization == nil ? 0 : 1) else { throw TransportError.invalidAuthorization }
        return request
    }

    // MARK: - Exchange

    /// The identical request, at most twice.
    private func send(_ request: URLRequest) async throws -> Reply {
        do {
            return try await attempt(request)
        } catch {
            guard Self.isConnectionLoss(error), !(await gate.isClosed) else { throw error }
            // The one repeat. Nothing about the request changes, so the server
            // either never saw the first attempt or refuses this one as a
            // replay; a second loss is reported to the caller.
            return try await attempt(request)
        }
    }

    /// True for the errors that mean "this socket died", and for nothing else.
    ///
    /// A timeout, a refused pin, a DNS failure or a cancelled task are all
    /// answers about the request itself and are never repeated; a lost
    /// connection says nothing about the request and is what a promptly closed
    /// idle socket or a dropped long poll looks like
    /// (`docs/protocol/realtime-v1.md:147-151`).
    public static func isConnectionLoss(_ error: Error) -> Bool {
        guard let failure = error as? URLError else { return false }
        switch failure.code {
        case .networkConnectionLost, .cannotParseResponse: return true
        default: return false
        }
    }

    private func attempt(_ request: URLRequest) async throws -> Reply {
        if await gate.isClosed { throw TransportError.closed }
        let session = pool ?? Self.makeSession(pinned: pinned, lane: lane)
        defer { if pool == nil { session.finishTasksAndInvalidate() } }
        let outcome = try await Exchange(pinned: pinned).perform(session: session, request: request)
        guard outcome.status == 200 else {
            throw Rejected(status: outcome.status,
                           code: Rejected.code(inErrorBody: outcome.body),
                           bytes: outcome.body.count,
                           truncated: outcome.truncated)
        }
        guard let text = String(data: outcome.body, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: outcome.body),
              object is [String: Any] else {
            throw TransportError.invalidReply
        }
        return Reply(text: text, bytes: outcome.body.count)
    }

    // MARK: - Capacity

    /// `Semaphore(2)` of `RealtimeTransport.java:18`, with the third caller
    /// suspended instead of refused.
    ///
    /// Every caller takes a ticket first, so a cancellation or a `close()`
    /// can reach one waiting caller (or all of them) and resume it with an
    /// error instead of leaving the task suspended for ever — the one hazard
    /// that waiting introduces and Android's `tryAcquire` does not have.
    private actor Gate {
        /// Why a waiting caller was woken up.
        private enum Grant: Sendable {
            case slot
            case closed
            case cancelled
        }

        private let capacity: Int
        private var inFlight = 0
        private var waiters: [(ticket: UInt64, continuation: CheckedContinuation<Grant, Never>)] = []
        /// Tickets of the calls that are running or waiting right now; nothing
        /// is remembered about a call that has ended.
        private var pending: Set<UInt64> = []
        /// Tickets cancelled before, or while, their caller waits.
        private var abandoned: Set<UInt64> = []
        private var issued: UInt64 = 0
        private(set) var isClosed = false

        init(capacity: Int) {
            self.capacity = capacity
        }

        /// One ticket per call, in the order the calls arrive.
        func ticket() -> UInt64 {
            issued += 1
            pending.insert(issued)
            return issued
        }

        func acquire(ticket: UInt64) async throws {
            if isClosed {
                forget(ticket)
                throw TransportError.closed
            }
            if abandoned.contains(ticket) {
                forget(ticket)
                throw CancellationError()
            }
            if inFlight < capacity {
                inFlight += 1
                return
            }
            let grant = await withCheckedContinuation { (continuation: CheckedContinuation<Grant, Never>) in
                waiters.append((ticket, continuation))
            }
            switch grant {
            case .closed:
                forget(ticket)
                throw TransportError.closed
            case .cancelled:
                forget(ticket)
                throw CancellationError()
            case .slot:
                if isClosed {
                    release(ticket: ticket)
                    throw TransportError.closed
                }
            }
        }

        /// Hands the slot to the next waiter, or gives it back.
        func release(ticket: UInt64) {
            forget(ticket)
            if waiters.isEmpty {
                inFlight -= 1
                return
            }
            waiters.removeFirst().continuation.resume(returning: .slot)
        }

        /// Wakes one waiting caller with `CancellationError`, or remembers the
        /// cancellation for a caller that has not started waiting yet. A
        /// cancellation that arrives after its call ended is dropped, so
        /// neither set can grow past the calls in flight.
        func cancel(ticket: UInt64) {
            if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
                waiters.remove(at: index).continuation.resume(returning: .cancelled)
                return
            }
            if pending.contains(ticket) { abandoned.insert(ticket) }
        }

        private func forget(_ ticket: UInt64) {
            pending.remove(ticket)
            abandoned.remove(ticket)
        }

        func close() {
            isClosed = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.continuation.resume(returning: .closed) }
        }
    }
}

// MARK: - One HTTP exchange

/// One request, with the response read under a limit that depends on the
/// status, and with redirects refused.
///
/// A data-task delegate is what replaces `getInputStream()` /
/// `getErrorStream()` of `RealtimeTransport.java:47-52`: chunks are counted as
/// they arrive, so an oversized 200 body is abandoned instead of being
/// buffered whole, and an oversized error body is cut at `errorLimit` while
/// its status survives. The object lives for exactly one attempt.
///
/// The 200 ceiling is a parameter because the two lanes do not share it:
/// the text lane keeps 2 MiB (`RealtimeTransport.java:50`) and the
/// negotiation-only voice lane keeps 2048 (`VoiceRelayTransport.java:45`,
/// `docs/protocol/voice-turn-v1.md:52`). The error ceiling is 4096 in both
/// (`VoiceRelayTransport.java:45`), so it stays the shared constant.
final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        let status: Int
        let body: Data
        /// The error body was longer than `errorLimit` and was cut.
        let truncated: Bool
    }

    private let pinned: PinnedSessionDelegate
    /// How much of a 200 body this exchange keeps before it abandons the call.
    private let successLimit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var settled = false
    private var status = 0
    private var body = Data()
    private var truncated = false
    private var overflow = false

    init(pinned: PinnedSessionDelegate,
         successLimit: Int = RealtimeTransport.responseLimit) {
        self.pinned = pinned
        self.successLimit = successLimit
        super.init()
    }

    func perform(session: URLSession, request: URLRequest) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.delegate = self
                task.resume()
            }
        } onCancel: {
            // A cancelled caller drops its socket now instead of waiting out
            // the read bound (`RealtimeTransport.java:67-70`).
            cancel()
        }
    }

    /// Cancels the request in flight, if there is one.
    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func settle(_ result: Result<Outcome, Error>) {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    // A redirect is never followed (`RealtimeTransport.java:35`): the answer is
    // the 3xx itself, which the caller sees as `Rejected(status:)`.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // The task-level challenge is answered by the pinned session delegate, so
    // the nine checks decide here exactly as they do for a session-level one.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pinned.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settle(.failure(TransportError.invalidReply))
            return
        }
        lock.lock()
        status = http.statusCode
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let limit = status == 200 ? successLimit : RealtimeTransport.errorLimit
        guard body.count + data.count > limit else {
            body.append(data)
            lock.unlock()
            return
        }
        if status == 200 {
            // Nothing above the ceiling is kept and the rest is never read.
            overflow = true
        } else {
            truncated = true
            body.append(data.prefix(limit - body.count))
        }
        lock.unlock()
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let overflow = self.overflow
        let truncated = self.truncated
        var status = self.status
        let body = self.body
        lock.unlock()
        if overflow {
            settle(.failure(TransportError.responseLimit))
            return
        }
        // A refused redirect can complete without ever reaching
        // `didReceive response`; the 3xx is then on the task itself.
        if status == 0, let http = task.response as? HTTPURLResponse { status = http.statusCode }
        if let error, !truncated {
            settle(.failure(error))
            return
        }
        guard status != 0 else {
            settle(.failure(TransportError.invalidReply))
            return
        }
        settle(.success(Outcome(status: status, body: body, truncated: truncated)))
    }
}
