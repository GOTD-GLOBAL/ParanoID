import Foundation

/// One request to the TURN issuer, and the two answers it can give.
///
/// The lane is written against this protocol rather than against the class
/// below so that the decisions of `VoiceRelayLane` — which status downgrades,
/// which retries, which fails — can be driven without a socket, exactly as
/// `ProofTransport` lets `ProofFlow` be driven without one. The shipped
/// implementation is `VoiceRelayTransport`, and nothing else conforms to it in
/// the application.
public protocol VoiceRelayEndpoint: Sendable {
    /// `GET /v2/voice/turn` with one signed credential and no body.
    ///
    /// - Parameter authorization: the `ParanoidSessionV2 …` value the core
    ///   signed for exactly this method and path.
    /// - Returns: the 200 body, verbatim, at most
    ///   `VoiceRelayConfig.maximumMetadataBytes` bytes long.
    /// - Throws: `Rejected` for any other status, `TransportError` for a
    ///   request this client refuses to make or an answer it refuses to read,
    ///   and the `URLError` of the URL loading system for a handshake,
    ///   connection or timeout failure.
    func get(authorization: String) async throws -> [UInt8]

    /// Drops the connection, now. Every later `get` is refused.
    func close() async
}

/// One negotiation-only connection to the saved pinned origin: the port of
/// `clients/android/src/org/paranoid/text/VoiceRelayTransport.java`.
///
/// It shares no socket with the text lanes. "One cancellable, bounded voice
/// network lane is separate from text send/receive … this extension permits
/// one additional bounded voice HTTP connection during negotiation only.
/// Successful voice transport is closed after the response"
/// (`docs/protocol/voice-turn-v1.md`, "Consent, transport and compatibility"),
/// so this object opens its own `URLSession`, uses it for exactly one request
/// and invalidates it when that request returns.
///
/// | Rule (`VoiceRelayTransport.java`)         | Here                                            |
/// |-------------------------------------------|-------------------------------------------------|
/// | one fixed endpoint, built once (`:22`)    | `endpoint`, from the retained origin            |
/// | pinned socket factory (`:23`, `:34`)      | `PinnedSessionDelegate` (the nine leaf checks)  |
/// | `Proxy.NO_PROXY` (`:28`)                  | `connectionProxyDictionary = [:]`               |
/// | `setInstanceFollowRedirects(false)` (`:34`) | `willPerformHTTPRedirection` answers `nil`    |
/// | `setUseCaches(false)` (`:35`)             | no `URLCache`, `reloadIgnoringLocalAndRemoteCacheData` |
/// | connect 8 s, read 8 s (`:35`)             | `timeoutIntervalForRequest` and `timeoutInterval` |
/// | `GET`, one `Authorization` (`:36`)        | the same, and the header is counted             |
/// | `Accept: application/json` (`:37`)        | the same header                                 |
/// | `Cache-Control: no-store` (`:38`)         | the same header                                 |
/// | `Connection: close` (`:39`)               | one session per call, invalidated on return     |
/// | 200 body ≤ 2048 B, error ≤ 4096 B (`:45`) | `Exchange(successLimit:)` and `errorLimit`      |
/// | `error` code `[a-z_]{1,40}` (`:54-56`)    | `Rejected.code(inErrorBody:)`                   |
/// | one connection at a time (`:29-32`)       | `active`, under a lock                          |
/// | `close()` disconnects the active one (`:65-69`) | the same                                  |
///
/// `Connection: close` is the one rule that cannot be written as a header:
/// Foundation reserves that name and drops it from a `URLRequest`. A one-shot
/// session expresses it instead — the session is created for this call and
/// invalidated when the call returns, so the socket is gone by then — which is
/// the same seam `RealtimeTransport.Lane.oneShot` uses and names.
///
/// **This class never repeats a request.** `RealtimeTransport` repeats an
/// identical operation once when a pooled socket dies, because an idle
/// keep-alive connection can be closed under it. There is no pooled socket
/// here, and "no other implicit retry/remint occurs"
/// (`voice-turn-v1.md`): the single permitted repeat of this lane is the one
/// `VoiceRelayLane` makes after the first ambiguous 401, with a **freshly
/// signed** nonce, and it is a decision of the lane and not of the socket.
public final class VoiceRelayTransport: VoiceRelayEndpoint, @unchecked Sendable {
    /// The only route this transport can dial (`voice-turn-v1.md`,
    /// "Request and authority").
    public static let path = "/v2/voice/turn"
    /// Connect and read bound of the one request
    /// (`VoiceRelayTransport.java:35`).
    public static let timeout: TimeInterval = 8
    /// The prefix every signed session credential carries
    /// (`clean_service.rs:741`, `VoiceRelayTransport.java:26`).
    public static let credentialPrefix = "ParanoidSessionV2 "
    /// The longest credential this transport will send
    /// (`VoiceRelayTransport.java:27`).
    public static let credentialLimit = 4096

    /// The retained HTTPS origin, exactly as it is saved.
    public let realm: String
    /// The nine leaf checks; the session delegate that owns them.
    public let pinned: PinnedSessionDelegate

    private let endpoint: URL
    private let lock = NSLock()
    private var active: URLSession?
    private var closed = false

    /// - Parameters:
    ///   - realm: the saved HTTPS origin (`KeyClient.checkedRealm`).
    ///   - pin: the saved 64-hexadecimal-digit SPKI pin.
    /// - Throws: `PinnedTrustFailure.realmFormat` or `.pinFormat`
    ///   (`VoiceRelayTransport.java:21-23`), or `TransportError.invalidRealm`.
    public init(realm: String, pin: String) throws {
        let evaluator = try PinnedTrustEvaluator(realm: realm, pin: pin)
        let origin = evaluator.realm ?? realm
        guard let endpoint = URL(string: origin + Self.path) else {
            throw TransportError.invalidRealm
        }
        self.realm = origin
        self.endpoint = endpoint
        self.pinned = PinnedSessionDelegate(evaluator: evaluator)
    }

    // MARK: - The one request

    public func get(authorization: String) async throws -> [UInt8] {
        // Every rule that can refuse the request is applied before a socket
        // exists (`VoiceRelayTransport.java:26-32`).
        let request = try makeRequest(authorization: authorization)
        let session = URLSession(configuration: Self.configuration(),
                                 delegate: pinned, delegateQueue: nil)
        // "voice transport unavailable" (`VoiceRelayTransport.java:30`): one
        // connection at a time, and none at all after `close()`.
        let admitted = lock.withLock { () -> Bool in
            guard !closed, active == nil else { return false }
            active = session
            return true
        }
        guard admitted else {
            session.invalidateAndCancel()
            throw TransportError.closed
        }
        defer {
            lock.withLock { if active === session { active = nil } }
            // The socket is gone when this call returns: `Connection: close`
            // (`VoiceRelayTransport.java:39,62`).
            session.invalidateAndCancel()
        }
        let outcome = try await Exchange(pinned: pinned,
                                         successLimit: VoiceRelayConfig.maximumMetadataBytes)
            .perform(session: session, request: request)
        guard outcome.status == 200 else {
            throw Rejected(status: outcome.status,
                           code: Rejected.code(inErrorBody: outcome.body),
                           bytes: outcome.body.count,
                           truncated: outcome.truncated)
        }
        return [UInt8](outcome.body)
    }

    /// Refuses further calls and drops the connection in flight
    /// (`VoiceRelayTransport.java:65-69`). It is safe to call twice and from
    /// anywhere: it never waits for the request it cancels.
    public func close() async {
        let session = lock.withLock { () -> URLSession? in
            closed = true
            let session = active
            active = nil
            return session
        }
        session?.invalidateAndCancel()
    }

    // MARK: - Request and configuration

    /// The transport policy of `VoiceRelayTransport.java:28-35`, on top of the
    /// pinned, ephemeral, cookie-free and cache-free configuration every lane
    /// of this client uses.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = PinnedSessionDelegate.configuration()
        configuration.connectionProxyDictionary = [:]
        // One connection, used once (`:29-32`, `:39`).
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    private func makeRequest(authorization: String) throws -> URLRequest {
        // "voice authorization unavailable" (`VoiceRelayTransport.java:26-27`),
        // with the CR/LF test every credential of this client passes.
        guard authorization.hasPrefix(Self.credentialPrefix),
              authorization.utf8.count <= Self.credentialLimit,
              !authorization.contains("\r"), !authorization.contains("\n") else {
            throw TransportError.invalidAuthorization
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Self.timeout
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // One credential per request, never two.
        let credentials = (request.allHTTPHeaderFields ?? [:]).keys
            .filter { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        guard credentials.count == 1 else { throw TransportError.invalidAuthorization }
        return request
    }
}
