import Foundation

/// One HTTP answer the server refused to make a 200 out of.
///
/// The port of `SyncCycle.Rejected` (`SyncCycle.java:9-14`): the status and,
/// when the body carried a usable one, the machine-readable error code. The
/// code is the only thing read out of an error body, and only when it matches
/// `[a-z_]{1,40}` (`RealtimeTransport.java:56`); anything else — a longer
/// string, mixed case, a number, an unparsable or truncated body — leaves it
/// empty. Callers branch on `status` and on well-known codes
/// (`session_exhausted`, `waiter_busy`, `turn_disabled`), never on free text.
///
/// `bytes` is how much of the error body this client kept. Android throws
/// `response limit` at 4096 bytes and loses the status
/// (`RealtimeTransport.java:50-51`); this client keeps the first 4096 bytes,
/// drops the rest and still reports the status, because a status is the part
/// the retry rules need. It is never a body, only its size, so it is safe in
/// evidence and logs.
public struct Rejected: Error, Equatable, Sendable {
    /// The HTTP status; never 200.
    public let status: Int
    /// The `error` member of the body when it matched `[a-z_]{1,40}`, `""`
    /// otherwise.
    public let code: String
    /// Error-body bytes kept, at most `RealtimeTransport.errorLimit`.
    public let bytes: Int
    /// True when the error body was longer than `RealtimeTransport.errorLimit`
    /// and the rest was dropped unread.
    public let truncated: Bool

    public init(status: Int, code: String = "", bytes: Int = 0, truncated: Bool = false) {
        self.status = status
        self.code = code
        self.bytes = bytes
        self.truncated = truncated
    }

    /// The `error` member of one error body, `""` when there is nothing usable.
    ///
    /// `JSONSerialization` replaces `new JSONObject(...)` and the
    /// `String.matches` call of `RealtimeTransport.java:56`; a body that is not
    /// one JSON object, an `error` member that is not a string and a string
    /// outside `[a-z_]{1,40}` all yield `""` instead of throwing, exactly as
    /// the Java `catch(Exception ignored)` does.
    public static func code(inErrorBody data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidate = object["error"] as? String,
              isErrorCode(candidate) else { return "" }
        return candidate
    }

    /// `candidate.matches("[a-z_]{1,40}")`, without a regular expression.
    public static func isErrorCode(_ candidate: String) -> Bool {
        let scalars = candidate.unicodeScalars
        guard (1...40).contains(scalars.count) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }
}

/// Why a request never became an HTTP exchange, or why an answer was unusable.
///
/// These are the `IOException`s of `RealtimeTransport.java:26-30`,
/// `:41` and `:51` with a case each, so that a caller (and a test) can name the
/// rule that said no without matching on a message. Anything that happens on
/// the wire — a refused pin, a lost connection, a timeout — stays a `URLError`
/// and is not wrapped: the URL loading system's code is more precise than a
/// case of this enum would be.
public enum TransportError: Error, Equatable, Sendable {
    /// The path is neither `/health` nor `/v2/…`, or it carries `#`, CR or LF
    /// (`RealtimeTransport.java:26-27`).
    case invalidPath(String)
    /// A method other than GET or POST (`RealtimeTransport.java:28`).
    case invalidMethod(String)
    /// A GET with a body (`RealtimeTransport.java:29`).
    case bodyOnGet
    /// The POST body is larger than `RealtimeTransport.requestLimit`; the
    /// number is the size that was refused. Nothing was sent
    /// (`RealtimeTransport.java:41`).
    case requestLimit(Int)
    /// A 200 body larger than `RealtimeTransport.responseLimit`; the rest was
    /// never read (`RealtimeTransport.java:50-51`).
    case responseLimit
    /// `close()` was called on this transport (`RealtimeTransport.java:34`).
    case closed
    /// The realm URL cannot be joined with this path.
    case invalidRealm
    /// An `Authorization` value that cannot be sent as exactly one header:
    /// empty, longer than 4096 bytes or carrying CR/LF
    /// (`VoiceRelayTransport.java:27-28`).
    case invalidAuthorization
    /// The answer was not an HTTP response, or its 200 body is not one JSON
    /// object (`RealtimeTransport.java:59`).
    case invalidReply
    /// `/health` answered something other than
    /// `status: ok` + `protocol: paranoid-self-service-v2`
    /// (`RealtimeLoop.java:179`).
    case protocolMismatch
}
