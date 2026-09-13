import Foundation
import Security

/// The `URLSession` side of the pinned trust: everything numbered 9, and the
/// only place where a server trust turns into a credential.
///
/// `PinnedTrustEvaluator` owns the eight leaf checks of
/// `PinnedTls.java:54-70`; this type owns number 9 and the disposition. On
/// Android that number is two facts — the socket factory enables only TLS 1.2
/// and 1.3 (`PinnedTls.java:80-83`) and the trust manager throws on
/// `checkClientTrusted` (`PinnedTls.java:53`) — and both are here:
///
/// - `configuration()` pins `tlsMinimumSupportedProtocolVersion` to
///   `.TLSv12`, and `decision(host:authenticationMethod:trust:floor:)` refuses
///   a challenge that arrives with a lower floor;
/// - a client-certificate challenge is cancelled, never answered: this client
///   holds no certificate and authenticates with its device key inside the
///   session transcript instead (`docs/protocol/realtime-v1.md:39-41`).
///
/// Three further refusals also answer `9`, and they have no Android
/// counterpart: `authenticationMethod`, `host` and `missingTrust`. They exist
/// because the URL loading system hands the decision over as a challenge
/// object — with a method, a host and an optional trust — where Android's
/// socket factory sees only a chain. So "check 9" is a group of five rules,
/// not one rule, and `PinnedTrustFailure.check` says so.
///
/// A credential is offered only when the eight leaf checks and all five of
/// these hold. Every other outcome is `.cancelAuthenticationChallenge`: never
/// `.performDefaultHandling`, which would hand the decision to the system
/// trust store, and never `.rejectProtectionSpace`, which would let the URL
/// loading system retry the same space with another method.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    /// What the delegate does with one challenge.
    public enum Decision: Equatable, Sendable {
        /// Every check held: answer with a credential for this trust.
        case useCredential
        /// Cancel the challenge, and why.
        case cancel(PinnedTrustFailure)
    }

    /// Checks 1 to 8.
    public let evaluator: PinnedTrustEvaluator

    public init(evaluator: PinnedTrustEvaluator) {
        self.evaluator = evaluator
        super.init()
    }

    /// The configuration a pinned session must use (check 9).
    ///
    /// TLS 1.2 is the floor and TLS 1.3 the ceiling, as the enabled-protocol
    /// list of `PinnedTls.java:80-83`. The rest keeps the session from
    /// remembering anything: an ephemeral configuration has no on-disk cache,
    /// no cookie store and no credential store, which matches "nothing is
    /// persisted or logged as a reusable credential"
    /// (`docs/protocol/realtime-v1.md:41-42`).
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// A session that uses `configuration()` and this delegate.
    ///
    /// - Parameter delegateQueue: the queue the callbacks run on; `nil` lets
    ///   `URLSession` create a serial queue of its own.
    public func makeSession(delegateQueue: OperationQueue? = nil) -> URLSession {
        URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: delegateQueue)
    }

    /// The decision for one challenge, with every input passed explicitly so
    /// that it can be taken without a network stack.
    ///
    /// - Parameters:
    ///   - host: the host of the protection space.
    ///   - authenticationMethod: the method of the protection space.
    ///   - trust: the server trust, when the method is server trust.
    ///   - floor: `tlsMinimumSupportedProtocolVersion` of the session the
    ///     challenge arrived on.
    ///   - now: the moment check 3 is made against.
    public func decision(host: String,
                         authenticationMethod: String,
                         trust: SecTrust?,
                         floor: tls_protocol_version_t,
                         at now: Date = Date()) -> Decision {
        // Check 9, first: a session below TLS 1.2, or one asking this client
        // to authenticate with a certificate, is refused before the
        // certificate is even looked at.
        //
        // The floor guard cannot fire for any session this package builds.
        // `makeSession`, `RealtimeTransport.configuration(lane:)` and
        // `VoiceRelayTransport.configuration()` all start from
        // `configuration()` above and none of them lowers
        // `tlsMinimumSupportedProtocolVersion`, so `floor` is always `.TLSv12`
        // there. It is kept because `floor` is a parameter of this public
        // method: the rule would otherwise be lost the moment this delegate is
        // handed to a session configured somewhere else, and it is the only
        // statement of the TLS floor that a caller cannot bypass by building
        // its own `URLSessionConfiguration`. `PinnedTrustTests` reaches it
        // through this entry point, and `check-pinned-tls.py` reaches it over
        // a socket wherever the local OpenSSL still offers TLS 1.1.
        guard floor == .TLSv12 || floor == .TLSv13 else { return .cancel(.protocolFloor) }
        switch authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            break
        case NSURLAuthenticationMethodClientCertificate:
            return .cancel(.clientAuthentication)
        default:
            return .cancel(.authenticationMethod(authenticationMethod))
        }
        guard host == evaluator.host else { return .cancel(.host(host)) }
        guard let trust else { return .cancel(.missingTrust) }
        do {
            try evaluator.evaluate(trust, at: now)
        } catch let failure as PinnedTrustFailure {
            return .cancel(failure)
        } catch {
            return .cancel(.unreadableCertificate("\(error)"))
        }
        return .useCredential
    }

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let outcome = decision(host: space.host,
                               authenticationMethod: space.authenticationMethod,
                               trust: space.serverTrust,
                               floor: session.configuration.tlsMinimumSupportedProtocolVersion)
        switch outcome {
        case .useCredential:
            guard let trust = space.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .cancel:
            // The reason is deliberately not logged here: a refusal is
            // reported by the caller that owns the request, with no
            // certificate bytes in it.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
