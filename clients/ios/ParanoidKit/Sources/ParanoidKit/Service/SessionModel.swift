import Foundation

/// Why a `SessionV2` answer was refused before it was ever used.
public enum SessionFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The answer is not exactly the eight-member object of
    /// `docs/protocol/realtime-v1.md:29-31`: a member is missing, one is of
    /// the wrong type, `expires` is not a positive integer, or there is
    /// something else in it. The core's parser refuses unknown members too
    /// (`key-protocol/src/session_v2.rs:6-16`); refusing them here as well
    /// means nothing unexpected is ever carried into a signing request.
    case malformedSession
    /// The session names another origin or another server key than the one
    /// this client is pinned to. The session is "scoped to precisely its
    /// realm, TLS SPKI, account, device and credential fingerprint" and the
    /// client validates that against its saved trust before use
    /// (`docs/protocol/realtime-v1.md:38-41`).
    case foreignRealm

    public var description: String {
        switch self {
        case .malformedSession: return "malformed session context"
        case .foreignRealm: return "session issued for another realm"
        }
    }
}

/// One live session context and the monotonic instant it arrived at.
///
/// The eight members are public context, **not** bearer authority
/// (`docs/protocol/realtime-v1.md:38-42`): every operation still needs the
/// device-auth private key the core holds, so this object is safe to keep in
/// memory and is never persisted or logged as a credential. It is not written
/// to the snapshot at all — a restart drops sessions on both sides.
///
/// Lifetime is counted from `received`, never from `expires`: the server issues
/// 300 seconds of wall time (`:33`) and the client "clamps received session
/// lifetime by monotonic receipt time to at most 300 seconds and renews around
/// 240 seconds" (`:179-181`). A device that slept through its session therefore
/// wakes up knowing the session is gone, and a phone whose wall clock is
/// wrong — or is moved — cannot talk itself into a longer one.
///
/// The other half of the validation, binding the context to *this* identity,
/// is done by the core: `sign_session_v2` compares realm, pin, account, device
/// and credential fingerprint against the saved identity and answers
/// `session_context_mismatch` when any of them differs
/// (`clients/core/src/clean_service.rs:688-699`). `ProofFlow` therefore signs
/// one throw-away request before adopting a session, exactly as
/// `RealtimeLoop.java:211` does.
public struct SessionModel: Equatable, Sendable {
    /// The members the answer has, and no others.
    public static let members = ["id", "epoch", "expires", "realm", "pin",
                                 "account", "device", "credential"]
    /// The longest a received session is used, counted monotonically.
    public static let lifetime: UInt64 = 300 * MonotonicClock.nanosecondsPerSecond
    /// When renewal starts, using the second per-account session slot
    /// (`RealtimeLoop.java:44`).
    public static let renewal: UInt64 = 240 * MonotonicClock.nanosecondsPerSecond

    /// Canonical UUIDv4, the name of this session.
    public let id: String
    /// The server-process epoch this session belongs to; a restart changes it.
    public let epoch: String
    /// Issuance wall time plus 300 seconds, as the server sees it. It is
    /// carried because it is part of the signing transcript, and it is never
    /// compared with a local date.
    public let expires: Int64
    public let realm: String
    public let pin: String
    public let account: String
    public let device: String
    /// The credential fingerprint, not the credential object.
    public let credential: String
    /// When this answer arrived, on the monotonic clock.
    public let received: MonotonicInstant

    /// The eight members, rebuilt in the shape the core parses. Rebuilding
    /// rather than retaining the decoded answer is what guarantees that
    /// nothing the server added travels back into a signing request.
    public var context: [String: Any] {
        ["id": id, "epoch": epoch, "expires": expires, "realm": realm, "pin": pin,
         "account": account, "device": device, "credential": credential]
    }

    /// How long ago this session arrived.
    public func age(at now: MonotonicInstant) -> UInt64 {
        now.nanoseconds(since: received)
    }

    /// Whether a new session must be opened before the next operation
    /// (`RealtimeLoop.java:44`).
    public func needsRenewal(at now: MonotonicInstant) -> Bool {
        age(at: now) >= Self.renewal
    }

    /// Whether the clamped lifetime has run out. Renewal starts a full minute
    /// earlier, so reaching this means the renewal never got through.
    public func isExpired(at now: MonotonicInstant) -> Bool {
        age(at: now) >= Self.lifetime
    }

    /// Reads one `POST /v2/session` answer.
    ///
    /// - Parameters:
    ///   - reply: the answer, exactly as it arrived.
    ///   - received: the monotonic instant it arrived at; the whole lifetime
    ///     is measured from it.
    ///   - trust: the saved origin and pin this client is bound to.
    /// - Throws: `SessionFailure`.
    public static func open(_ reply: [String: Any],
                            received: MonotonicInstant,
                            trust: ServiceTrust) throws -> SessionModel {
        // Exactly these members and no others: the count settles the unknown
        // ones, each read below settles a missing one.
        guard reply.count == members.count else { throw SessionFailure.malformedSession }
        func text(_ member: String) throws -> String {
            guard let value = reply[member] as? String else { throw SessionFailure.malformedSession }
            return value
        }
        let realm = try text("realm")
        let pin = try text("pin")
        // `expires` is the one member that is not a string, and it is an
        // integer: a fractional number is not this format, and the core
        // refuses anything below 1 as a context mismatch
        // (`clean_service.rs:693`). The cast goes through `NSNumber` because
        // that is what a decoded JSON number is, and because a dynamic cast
        // from `Any` does not convert between integer widths.
        // A decoded JSON `true` is `__NSCFBoolean`, which satisfies both
        // `as? NSNumber` and `!CFNumberIsFloatType`, and would arrive here as
        // `1`. `realtime-v1.md:31` says this member is an integer, so the
        // boolean is refused by identity before the numeric tests run.
        guard let number = reply["expires"] as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber)
        else { throw SessionFailure.malformedSession }
        let expires = number.int64Value
        guard expires > 0 else { throw SessionFailure.malformedSession }
        guard realm == trust.realm, pin == trust.pin else { throw SessionFailure.foreignRealm }
        return SessionModel(id: try text("id"), epoch: try text("epoch"),
                            expires: expires, realm: realm, pin: pin,
                            account: try text("account"), device: try text("device"),
                            credential: try text("credential"), received: received)
    }
}
