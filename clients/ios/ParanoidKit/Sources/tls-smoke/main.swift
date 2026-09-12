// tls-smoke: real loopback TLS handshakes through the shipped pinned trust.
//
// This is the iOS counterpart of `clients/android/test/TlsSmoke.java:36-46`.
// `PinnedTrustTests` feeds `PinnedTrustEvaluator` DER blobs; this tool instead
// makes `URLSession` and `Security.framework` carry out a real handshake
// against the OpenSSL 3 fixtures that `clients/ios/check-pinned-tls.py`
// generates and serves on loopback, so that the nine checks are exercised on
// the path the application actually uses: `PinnedSessionDelegate.configuration()`
// for the TLS floor, `PinnedSessionDelegate` for the challenge and
// `PinnedTrustEvaluator` for the leaf.
//
// The plan arrives as one JSON object on stdin:
//
//     {"cases":[{"name":"valid","host":"127.0.0.1",
//                "url":"https://127.0.0.1:54321/","pin":"<64 hex>",
//                "expect":"accept"}]}
//
// and one JSON object goes to stdout, with `ok` false and a non-zero exit
// status when any case did not do what it was expected to do:
//
//     {"empty_pin_rejected":true,"ok":true,
//      "results":[{"accepted":true,"check":null,"expect":"accept",
//                  "matched":true,"name":"valid","reason":null,"status":200}],
//      "tls_maximum":"TLSv13","tls_minimum":"TLSv12"}
//
// Whether a rejected peer ever saw an HTTP request is decided by the fixture
// server's own counter, in `check-pinned-tls.py`; this tool only sends the
// same synthetic `Authorization` header Android sends (`TlsSmoke.java:29`), so
// that a counted request on a rejected peer would be a demonstrated leak.
// Nothing here prints certificate bytes, keys or the pin.
import Foundation
import ParanoidKit

// MARK: - Plan and report

/// One handshake: where to dial, what to pin and what is supposed to happen.
private struct SmokeCase: Decodable {
    /// The fixture name, for the report only.
    let name: String
    /// The address the leaf must name (`PinnedTrustEvaluator.host`).
    let host: String
    /// The HTTPS URL of the fixture server.
    let url: String
    /// 64 hexadecimal digits, or something the constructor must refuse.
    let pin: String
    /// `accept` (HTTP 200 expected) or `reject`.
    let expect: String
}

private struct SmokePlan: Decodable {
    let cases: [SmokeCase]
}

/// What one handshake did.
private struct CaseReport: Encodable {
    let name: String
    let expect: String
    /// True only for an HTTP 200 answer, as `getResponseCode()==200` is.
    let accepted: Bool
    /// The HTTP status, when a response arrived at all.
    let status: Int?
    /// The `PinnedTrustFailure` that cancelled the challenge, or the transport
    /// error when the handshake failed before the challenge. Never certificate
    /// or key material.
    let reason: String?
    /// The number of the `PinnedTls.java:51-70` check that said no, when the
    /// refusal came from this client.
    let check: Int?
    /// `accepted` equals what `expect` asked for.
    let matched: Bool
}

private struct SmokeReport: Encodable {
    let results: [CaseReport]
    /// `PinnedTrustEvaluator(host:pin:)` refuses an empty pin
    /// (`TlsSmoke.java:43`).
    let emptyPinRejected: Bool
    /// `tlsMinimumSupportedProtocolVersion` of a pinned session
    /// (`TlsSmoke.java:44-45`).
    let tlsMinimum: String
    /// `tlsMaximumSupportedProtocolVersion` of a pinned session.
    let tlsMaximum: String
    /// Every case matched, and both session rules hold.
    let ok: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case emptyPinRejected = "empty_pin_rejected"
        case tlsMinimum = "tls_minimum"
        case tlsMaximum = "tls_maximum"
        case ok
    }
}

// MARK: - The session delegate under test

/// `PinnedSessionDelegate` with the refusal written down.
///
/// The delegate itself deliberately keeps no record of why it cancelled — a
/// refusal is reported by the caller that owns the request — so this tool asks
/// `decision(host:authenticationMethod:trust:floor:)` for the verdict, notes it
/// and then hands the very same challenge to the shipped delegate. The
/// disposition the session sees is therefore produced by
/// `PinnedSessionDelegate`, not by this file.
private final class RecordingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinned: PinnedSessionDelegate
    private let lock = NSLock()
    private var recorded: PinnedTrustFailure?

    init(pinned: PinnedSessionDelegate) {
        self.pinned = pinned
        super.init()
    }

    /// The first refusal, when the challenge was refused.
    var failure: PinnedTrustFailure? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let decision = pinned.decision(host: space.host,
                                       authenticationMethod: space.authenticationMethod,
                                       trust: space.serverTrust,
                                       floor: session.configuration.tlsMinimumSupportedProtocolVersion)
        if case .cancel(let failure) = decision {
            lock.lock()
            if recorded == nil { recorded = failure }
            lock.unlock()
        }
        pinned.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}

/// The completion of one data task, readable from the thread that waits.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    private var transport: String?

    func finish(status: Int?, transport: String?) {
        lock.lock()
        self.status = status
        self.transport = transport
        lock.unlock()
    }

    func read() -> (status: Int?, transport: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (status, transport)
    }
}

// MARK: - One handshake

/// The domain and code of a transport error, without a URL or a host in it.
private func describe(_ error: Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
}

private func report(_ item: SmokeCase,
                    accepted: Bool,
                    status: Int?,
                    reason: String?,
                    check: Int?) -> CaseReport {
    CaseReport(name: item.name,
               expect: item.expect,
               accepted: accepted,
               status: status,
               reason: reason,
               check: check,
               matched: accepted == (item.expect == "accept"))
}

/// Dials one fixture server through a pinned session and reports what happened.
private func run(_ item: SmokeCase) -> CaseReport {
    let evaluator: PinnedTrustEvaluator
    do {
        evaluator = try PinnedTrustEvaluator(host: item.host, pin: item.pin)
    } catch let failure as PinnedTrustFailure {
        return report(item, accepted: false, status: nil, reason: failure.description, check: failure.check)
    } catch {
        return report(item, accepted: false, status: nil, reason: describe(error), check: nil)
    }
    guard let url = URL(string: item.url) else {
        return report(item, accepted: false, status: nil, reason: "unusable url", check: nil)
    }

    let configuration = PinnedSessionDelegate.configuration()
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 10
    let delegate = RecordingDelegate(pinned: PinnedSessionDelegate(evaluator: evaluator))
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    // The synthetic credential of `TlsSmoke.java:29`: nothing real, and the
    // fixture server counts every request that carries it.
    request.setValue("Bearer synthetic-fixture", forHTTPHeaderField: "Authorization")

    let outcome = Outcome()
    let waiter = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { _, response, error in
        outcome.finish(status: (response as? HTTPURLResponse)?.statusCode,
                       transport: error.map(describe))
        waiter.signal()
    }
    task.resume()
    if waiter.wait(timeout: .now() + 30) == .timedOut {
        task.cancel()
        return report(item, accepted: false, status: nil, reason: "timed out", check: nil)
    }
    let (status, transport) = outcome.read()
    let failure = delegate.failure
    return report(item,
                  accepted: status == 200,
                  status: status,
                  reason: failure?.description ?? transport,
                  check: failure?.check)
}

/// The name of a TLS version, for the report.
private func name(of version: tls_protocol_version_t) -> String {
    switch version {
    case .TLSv10: return "TLSv10"
    case .TLSv11: return "TLSv11"
    case .TLSv12: return "TLSv12"
    case .TLSv13: return "TLSv13"
    case .DTLSv10: return "DTLSv10"
    case .DTLSv12: return "DTLSv12"
    @unknown default: return "unknown"
    }
}

private func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("tls-smoke: \(message)\n".utf8))
    exit(status)
}

// MARK: - The run

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let plan = try? JSONDecoder().decode(SmokePlan.self, from: input), !plan.cases.isEmpty else {
    fail("expected a JSON plan with at least one case on stdin", status: 2)
}

// `TlsSmoke.java:43`: a pin that is not 64 hexadecimal digits is refused by the
// constructor, so no session can ever be built without one.
var emptyPinRejected = false
do {
    _ = try PinnedTrustEvaluator(host: "127.0.0.1", pin: "")
} catch PinnedTrustFailure.pinFormat {
    emptyPinRejected = true
} catch {
    emptyPinRejected = false
}

// `TlsSmoke.java:44-45`: the session offers TLS 1.2 and 1.3 and nothing else.
let pinnedConfiguration = PinnedSessionDelegate.configuration()
let minimum = name(of: pinnedConfiguration.tlsMinimumSupportedProtocolVersion)
let maximum = name(of: pinnedConfiguration.tlsMaximumSupportedProtocolVersion)

private let results = plan.cases.map(run)
let ok = emptyPinRejected && minimum == "TLSv12" && maximum == "TLSv13"
    && results.allSatisfy { $0.matched }

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
guard let encoded = try? encoder.encode(SmokeReport(results: results,
                                                    emptyPinRejected: emptyPinRejected,
                                                    tlsMinimum: minimum,
                                                    tlsMaximum: maximum,
                                                    ok: ok)) else {
    fail("could not encode the report", status: 2)
}
print(String(decoding: encoded, as: UTF8.self))
exit(ok ? 0 : 1)
