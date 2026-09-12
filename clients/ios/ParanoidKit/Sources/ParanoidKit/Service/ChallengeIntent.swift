import CryptoKit
import Foundation

/// The body of one challenge request: what this device asks a server to let it
/// prove, before it proves anything.
///
/// It is the port of `SelfServiceClient.java:171-182` and it carries exactly
/// what `docs/protocol/self-service-v2.md` lets the two challenge endpoints
/// accept:
///
/// - `POST /v2/registration/challenge` takes
///   `{credential, purpose:"register", method:"POST",
///   path:"/v2/registration/commit", body: SHA256("{}")}`;
/// - `POST /v2/auth/challenge` takes `{account, device, credential, purpose,
///   method, path, body}`, all strings, with `credential` the fingerprint
///   rather than the object.
///
/// `body` is never the body itself: it is the lowercase SHA-256 hex of the
/// exact bytes that will be sent, empty string included, so the challenge the
/// server mints is bound to one request and not to a shape of request. Control
/// bodies are exactly `{}` and a GET body is empty; the path carries the exact
/// cursor query bytes.
///
/// The intent is built from the state the core owns — the registration
/// credential before enrollment, the enrollment afterwards — and it is only a
/// description: nothing here signs, stores or sends anything.
public struct ChallengeIntent {
    /// `purpose` for `POST /v2/registration/commit`.
    public static let registerPurpose = "register"
    /// `purpose` for `POST /v2/session` (`docs/protocol/realtime-v1.md:23`).
    public static let sessionPurpose = "session"
    /// `purpose` for the message routes.
    public static let messagePurpose = "message"
    /// `purpose` for `POST /v2/auth/verify`.
    public static let statusPurpose = "status"

    /// The challenge route of an unregistered device.
    public static let registrationChallengePath = "/v2/registration/challenge"
    /// The challenge route of every other purpose.
    public static let authChallengePath = "/v2/auth/challenge"
    /// The route a `register` challenge authorizes.
    public static let registrationCommitPath = "/v2/registration/commit"
    /// The route a `session` challenge authorizes.
    public static let sessionPath = "/v2/session"
    /// Every control body is exactly this (`self-service-v2.md`).
    public static let controlBody = "{}"

    /// What this proof is for.
    public let purpose: String
    /// The method of the request the proof will authorize, uppercase.
    public let method: String
    /// The path of that request, with its exact query bytes.
    public let path: String
    /// SHA-256 of that request's body, 64 lowercase hexadecimal digits.
    public let bodyDigest: String
    /// The identity members: `credential` as an object for `register`, the
    /// three enrollment strings otherwise.
    public let subject: [String: Any]

    /// Where this intent is posted: the registration route only for
    /// `register`, the authenticated route for everything else
    /// (`RealtimeLoop.java:174`).
    public var challengePath: String {
        purpose == Self.registerPurpose ? Self.registrationChallengePath : Self.authChallengePath
    }

    /// The request body, as the server parses it. Both endpoints reject
    /// unknown and duplicate members, so nothing beyond these is ever added.
    public var json: [String: Any] {
        var intent = subject
        intent["purpose"] = purpose
        intent["method"] = method
        intent["path"] = path
        intent["body"] = bodyDigest
        return intent
    }

    /// - Parameter body: the request body itself; it is hashed here and never
    ///   kept.
    public init(purpose: String, method: String, path: String, body: String, subject: [String: Any]) {
        self.purpose = purpose
        self.method = method
        self.path = path
        self.bodyDigest = Self.digest(of: body)
        self.subject = subject
    }

    /// The lowercase hexadecimal SHA-256 of `body`
    /// (`SelfServiceClient.java:173-174`).
    public static func digest(of body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the identity members out of `client` and describes one proof.
    ///
    /// Before registration the only identity there is is the registration
    /// request, so the whole credential object travels; afterwards the server
    /// knows it and the three enrollment strings are enough
    /// (`SelfServiceClient.java:176-180`).
    ///
    /// - Throws: `SelfServiceError.frozen` for a client whose last commit
    ///   failed — which is what keeps a frozen client from asking for a
    ///   challenge at all — or `.malformedReply` when the state carries no
    ///   enrollment to name.
    public static func make(purpose: String,
                            method: String,
                            path: String,
                            body: String,
                            from client: SelfServiceClient) throws -> ChallengeIntent {
        let subject: [String: Any]
        if purpose == registerPurpose {
            subject = ["credential": try client.credential()]
        } else {
            guard let enrollment = try client.enrollment(),
                  let account = enrollment["account"] as? String,
                  let device = enrollment["device"] as? String,
                  let credential = enrollment["credential"] as? String
            else { throw SelfServiceError.malformedReply("enrollment") }
            subject = ["account": account, "device": device, "credential": credential]
        }
        return ChallengeIntent(purpose: purpose, method: method, path: path,
                               body: body, subject: subject)
    }
}
