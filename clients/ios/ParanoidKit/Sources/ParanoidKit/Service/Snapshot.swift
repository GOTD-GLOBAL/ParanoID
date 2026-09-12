import Foundation

/// Why one self-service operation failed.
///
/// The vocabulary is Android's, where the same conditions are `IOException`s
/// with fixed messages (`SelfServiceClient.java:9-11,35,44,48,66,71,76`); they
/// are separate cases here so that a caller can tell "this build cannot read
/// the retained data" from "the retained data is gone" without matching on
/// text. None of them ever leads to a fresh identity over an existing state
/// file.
public enum SelfServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The wrapper is not version 4, or the state inside it is neither the
    /// legacy schema 0 nor the clean schema 3, or the dry-run upgrade of a
    /// schema-0 state did not produce a schema-3 candidate. Android's
    /// `UnsupportedSnapshot`: "clean installation required; retained data
    /// unchanged". Nothing was written, so the retained bytes are exactly as
    /// they were.
    case unsupportedSnapshot
    /// The wrapper is not a JSON object with the members this format has.
    /// Nothing was written.
    case malformedSnapshot
    /// The `token` member is neither empty nor 64 lowercase hexadecimal digits
    /// (`SelfServiceClient.java:30`).
    case invalidLegacySnapshot
    /// The `realm` of the wrapper is not the realm the core state was created
    /// for (`SelfServiceClient.java:44`). The two must agree, or a saved
    /// identity would be offered to another server.
    case realmMismatch
    /// A fixture realm/pin was supplied beside a saved snapshot that names
    /// another pair (`SelfServiceClient.java:49-50`). Saved trust wins, and
    /// the disagreement is reported rather than resolved.
    case savedTrustWins
    /// There is no saved snapshot and no trust to start from: no fixture and,
    /// in a Debug build without `-paranoid-allow-hosted`, no compiled default
    /// either. No identity is created and nothing is dialled.
    case trustUnavailable
    /// The local commit failed. The client is frozen for the rest of the
    /// process: the candidate was not adopted and nothing derived from it may
    /// be sent (`SelfServiceClient.java:78`).
    case commitFailed
    /// The client is frozen — either by a failed commit or because it was
    /// opened frozen. Android's "local state frozen"
    /// (`SelfServiceClient.java:54`).
    case frozen
    /// A `receive_v2` reply carried no authenticated disposition
    /// (`SelfServiceClient.java:70-72`). The candidate is dropped.
    case missingAcceptance
    /// A server acceptance did not name the envelope it answers, or its
    /// sequence is below 1 (`SelfServiceClient.java:207`).
    case invalidAcceptance
    /// `send_call_v1` did not leave exactly one new envelope in the outbox
    /// (`SelfServiceClient.java:119-120`).
    case callEnqueueInvariant
    /// The operation needs an active enrollment
    /// (`SelfServiceClient.java:107,112,116`).
    case registrationRequired
    /// A reply did not carry the member this operation reads.
    case malformedReply(String)
    /// A request could not be encoded as JSON. Unreachable for the requests
    /// this file builds; it exists so that no encoder failure is ignored.
    case invalidRequest

    public var description: String {
        switch self {
        case .unsupportedSnapshot:
            return "unsupported snapshot; clean installation required; retained data unchanged"
        case .malformedSnapshot: return "malformed snapshot wrapper"
        case .invalidLegacySnapshot: return "invalid legacy snapshot"
        case .realmMismatch: return "realm mismatch"
        case .savedTrustWins: return "saved trust wins"
        case .trustUnavailable: return "no server trust configured"
        case .commitFailed: return "local commit failed"
        case .frozen: return "local state frozen"
        case .missingAcceptance: return "missing authenticated receive disposition"
        case .invalidAcceptance: return "invalid acceptance"
        case .callEnqueueInvariant: return "call enqueue invariant"
        case .registrationRequired: return "registration required"
        case .malformedReply(let member): return "reply without \(member)"
        case .invalidRequest: return "invalid request"
        }
    }
}

/// The two strings that decide where this client talks and which key it
/// accepts there: the HTTPS origin and the SHA-256 pin of the server's public
/// key.
///
/// They travel together because neither is usable alone, and they are checked
/// with the same rules the TLS layer uses (`PinnedTrustEvaluator.checkedRealm`
/// / `.checkedPin`, the port of `KeyClient.java:37-41` and
/// `PinnedTls.java:18-21`), so the pinned address and the dialled address
/// cannot drift apart. A saved pair always wins over a compiled one.
public struct ServiceTrust: Equatable, Sendable {
    /// The hosted alpha of the owner (`KeyClient.java:9`). It is the only
    /// realm a Release build starts from.
    public static let hostedRealm = "https://157.180.49.125:38443"
    /// The pin of that server (`KeyClient.java:10`), unchanged from Android.
    public static let hostedPin = "8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba"
    /// The launch argument that lets a Debug build use the hosted defaults.
    /// Without it a Debug build has no realm at all and refuses to start an
    /// identity, which is what keeps a simulator run on the local stand.
    public static let allowHostedArgument = "-paranoid-allow-hosted"

    /// Whether this code was compiled in the Debug configuration. It is a
    /// stored constant rather than an `#if` at every use site so that the rule
    /// can be tested in both directions from one build.
    public static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// The HTTPS origin, exactly as it is stored and compared
    /// (`docs/protocol/realtime-v1.md:39-41`).
    public let realm: String
    /// The pin as 64 lowercase hexadecimal digits.
    public let pin: String

    /// - Throws: `PinnedTrustFailure.realmFormat` or `.pinFormat`.
    public init(realm: String, pin: String) throws {
        self.realm = try PinnedTrustEvaluator.checkedRealm(realm)
        self.pin = try PinnedTrustEvaluator.checkedPin(pin)
    }

    /// The trust a build starts from when nothing is saved and no stand was
    /// named on the command line.
    ///
    /// A Release build is the owner's phone build and starts from the hosted
    /// alpha, like Android does. A Debug build — every simulator run and every
    /// host test — gets `nil`, so it cannot reach the hosted server by
    /// accident; `-paranoid-allow-hosted` is the deliberate exception, and the
    /// stand normally supplies its own realm and pin instead (step 30).
    ///
    /// - Parameters:
    ///   - arguments: the process arguments to read the opt-in from.
    ///   - isDebugBuild: the configuration to decide for; the default is this
    ///     build's own.
    public static func hostedDefault(arguments: [String] = ProcessInfo.processInfo.arguments,
                                     isDebugBuild: Bool = ServiceTrust.isDebugBuild) -> ServiceTrust? {
        if isDebugBuild, !arguments.contains(allowHostedArgument) { return nil }
        // The two constants are checked at the same time as any other pair, so
        // a typo in them fails here instead of at the first request.
        return try? ServiceTrust(realm: hostedRealm, pin: hostedPin)
    }
}

/// The stored form of everything this client keeps: the version-4 wrapper of
/// `SelfServiceClient.java:23-44,74-76`.
///
/// ```text
/// {"version":4,"realm":<origin>,"tls_pin":<64 hex>,"token":"","state":<core state>}
/// ```
///
/// `state` is the core's own snapshot text, kept **verbatim**: it is sliced out
/// of a reply by `JsonSpan` and written back without being re-encoded, so the
/// bytes the core produced are the bytes on the device and the "did this
/// operation change the state" comparison is a string comparison. `token` is
/// the legacy bearer token of the pre-v2 protocol; this client never mints one
/// and writes `""`, but a snapshot written by an older build may carry 64
/// hexadecimal digits and is read unchanged.
///
/// A wrapper holds private keys and plaintext inside `state`: never log one.
public struct Snapshot: Equatable, Sendable {
    /// The only wrapper version this build understands
    /// (`SelfServiceClient.java:26`).
    public static let version = 4
    /// The core schemas a wrapper may carry: the legacy one, which is upgraded
    /// on open, and the clean one (`SelfServiceClient.java:32`).
    public static let legacyStateVersion = 0
    /// The clean self-service schema (`clean_service.rs:766`).
    public static let cleanStateVersion = 3

    /// Where this identity belongs and which server key it accepts.
    public let trust: ServiceTrust
    /// The legacy bearer token: `""` for everything this build writes.
    public let token: String
    /// The core snapshot, verbatim.
    public let state: String
    /// `state.version`, already checked to be 0 or 3. It is carried beside the
    /// text because every caller that builds a wrapper has just read it out of
    /// a reply, and re-parsing 8 MiB to learn one integer is waste.
    public let stateVersion: Int

    public init(trust: ServiceTrust, token: String, state: String, stateVersion: Int) {
        self.trust = trust
        self.token = token
        self.state = state
        self.stateVersion = stateVersion
    }

    /// Reads a stored wrapper.
    ///
    /// Nothing is written, in any outcome: a wrapper this build cannot read
    /// leaves the retained bytes exactly where they are, which is what makes
    /// `unsupportedSnapshot` a demand for a clean installation rather than a
    /// silent reset.
    ///
    /// - Throws: `SelfServiceError.unsupportedSnapshot` for a wrapper version
    ///   other than 4 or a core schema other than 0 or 3,
    ///   `.invalidLegacySnapshot` for a token that is neither empty nor 64
    ///   hexadecimal digits, `.malformedSnapshot` for anything that is not this
    ///   object, and `PinnedTrustFailure` for a realm or pin that does not
    ///   pass the same checks the TLS layer applies.
    public static func open(_ text: String) throws -> Snapshot {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SelfServiceError.malformedSnapshot
        }
        // `optInt("version",0)` on Android: a missing or non-numeric version is
        // 0, and every value but 4 means "not this format".
        guard (object["version"] as? NSNumber)?.intValue == version else {
            throw SelfServiceError.unsupportedSnapshot
        }
        guard let realm = object["realm"] as? String,
              let pin = object["tls_pin"] as? String,
              let token = object["token"] as? String,
              let retained = object["state"] as? [String: Any]
        else { throw SelfServiceError.malformedSnapshot }
        let trust = try ServiceTrust(realm: realm, pin: pin)
        guard token.isEmpty || isLegacyToken(token) else {
            throw SelfServiceError.invalidLegacySnapshot
        }
        guard let stateVersion = (retained["version"] as? NSNumber)?.intValue else {
            throw SelfServiceError.malformedSnapshot
        }
        guard stateVersion == legacyStateVersion || stateVersion == cleanStateVersion else {
            throw SelfServiceError.unsupportedSnapshot
        }
        // The decoded copy above is only read; what is kept is the text the
        // core wrote, byte for byte.
        guard let state = JsonSpan.value(of: "state", in: text) else {
            throw SelfServiceError.malformedSnapshot
        }
        return Snapshot(trust: trust, token: token, state: state, stateVersion: stateVersion)
    }

    /// The wrapper as it is stored: the five members in the order Android
    /// writes them (`SelfServiceClient.java:76`), with `state` inlined
    /// verbatim.
    public var text: String {
        let members = [
            "\"version\":\(Self.version)",
            "\"realm\":\(Self.quoted(trust.realm))",
            "\"tls_pin\":\(Self.quoted(trust.pin))",
            "\"token\":\(Self.quoted(token))",
            "\"state\":\(state)",
        ]
        return "{\(members.joined(separator: ","))}"
    }

    /// 64 lowercase hexadecimal digits, the shape of a legacy bearer token
    /// (`SelfServiceClient.java:30`).
    public static func isLegacyToken(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A JSON string literal. The three members that go through it are an
    /// origin, a hexadecimal pin and a hexadecimal token, but the escaping is
    /// complete rather than sufficient, because a wrapper that cannot be read
    /// back is a lost identity.
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
