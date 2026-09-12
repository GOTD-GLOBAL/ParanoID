// service-bridge: the stdin/stdout fixture that drives the shipped iOS client
// classes against a local stand.
//
// It is the iOS counterpart of
// `clients/android/test/CleanSelfServiceBridge.java` and it speaks the same
// line protocol, so the two harnesses stay comparable:
//
//     <phone>\t<op>\t<base64 value>            on stdin
//     <base64 of one JSON object>              on stdout, one line per request
//
// `<phone>` is one of the five synthetic names the fixture allows, `<op>` is
// one of `create`, `sync`, `pair`, `send`, `block`, `pending`,
// `fail_next_commit`, `post_without_accept` and `view`, and `<base64 value>`
// carries the operation's argument (a contact text, a small JSON object, or
// nothing). A refused request answers `{"error":…,"detail":…}` instead of a
// view, exactly as the Java fixture does, and the process stays alive.
//
// Everything below the protocol is the real client: `SelfServiceClient` owns
// the state, `SnapshotStore` commits it through the five durable steps,
// `ProofFlow` runs the challenge/sign/request cycle and `RealtimeTransport`
// carries every byte over the pinned TLS stack. Nothing is mocked and nothing
// is re-implemented here. Two things are the fixture's own, because a command
// line tool has neither of them:
//
// - the AES-256 wrapping key lives **in memory** for the life of this process
//   instead of in the Keychain (a signed application is what the Keychain
//   needs); `StorageGuard.requireContinuity` is still evaluated against it, so
//   a state file without its key freezes the phone exactly as it would on a
//   device;
// - the state file lives under the directory given as the first argument (the
//   harness puts it in a temporary directory) instead of
//   `Application Support/paranoid/`.
//
// The compiled hosted default is passed as `nil` when the client is built, so
// this tool can only ever dial the realm and pin it was given on the command
// line. It has no way to reach the hosted server.
//
// What is not here yet: `sync` performs the connection cycle of
// `ProofFlow.connect()` — register if needed, discover the capability, issue
// and validate a session — and **not** the outbox flush and inbox drain of
// `SelfServiceClient.java:207-216`, because the iOS sync cycle has not landed
// yet. The operations that need it (`send`, `pair`, `block`,
// `fail_next_commit`) enqueue and commit exactly as the client does, and
// `post_without_accept` signs and sends one envelope, but nothing flushes an
// outbox or drains an inbox until that step. The registration scenario of
// `clients/ios/test_clean_self_service.py --registration-only` is what this
// file is exercised by today.
//
// Output is public: the state text, the wrapping key and the snapshot bytes
// never leave this process, and nothing here logs one.
import CryptoKit
import Foundation
import ParanoidKit

// MARK: - Fixture failures

/// A refusal that belongs to the fixture rather than to the client.
private struct FixtureError: Error {
    let code: String
    let detail: String

    static func unsupported(_ operation: String) -> FixtureError {
        FixtureError(code: "UnsupportedOperation", detail: operation)
    }
}

/// The `error` member and its detail, as `CleanSelfServiceBridge.java:78-80`
/// builds them: an HTTP rejection keeps its status, everything else is named
/// by its type.
private func describe(_ error: any Error) -> (code: String, detail: String) {
    switch error {
    case let rejected as Rejected:
        return ("http_\(rejected.status)", rejected.code.isEmpty ? "rejected" : rejected.code)
    case let failure as FixtureError:
        return (failure.code, failure.detail)
    case let failure as SelfServiceError:
        return ("SelfServiceError", failure.description)
    case let failure as CoreError:
        switch failure {
        case .nativeFailure: return ("CoreError", "native_failure")
        case .rejected(let code): return ("CoreError", code)
        }
    case let failure as StorageError:
        return ("StorageError", String(describing: failure))
    case let failure as SnapshotCodecError:
        return ("SnapshotCodecError", String(describing: failure))
    case let failure as FileSystemError:
        return ("FileSystemError", failure.description)
    case let failure as PinnedTrustFailure:
        return ("PinnedTrustFailure", failure.description)
    case let failure as TransportError:
        return ("TransportError", String(describing: failure))
    case let failure as SessionFailure:
        return ("SessionFailure", failure.description)
    case let failure as URLError:
        // The domain and the code, never a URL or a host: a refused pinned
        // handshake arrives here as a cancelled request (`-999`), exactly as
        // `tls-smoke` reports one.
        return ("URLError", "\(URLError.errorDomain) \(failure.errorCode)")
    default:
        let error = error as NSError
        return (String(describing: type(of: error)), "\(error.domain) \(error.code)")
    }
}

// MARK: - The network, synchronously

/// One completed call, readable from the thread that waits for it.
private final class Waiting: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<RealtimeTransport.Reply, any Error>?

    func finish(_ value: Result<RealtimeTransport.Reply, any Error>) {
        lock.lock()
        if outcome == nil { outcome = value }
        lock.unlock()
    }

    func take() -> Result<RealtimeTransport.Reply, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

/// `RealtimeTransport` under the synchronous `ProofTransport` protocol.
///
/// `ProofFlow` is synchronous by design — it is driven from one lane — while
/// the transport is `async`, so the two are joined by a detached task and a
/// semaphore. The wait is bounded by the transport's own resource timeout
/// (`RealtimeTransport.resourceTimeout`) plus a margin; the fallback exists so
/// that a lost callback ends the request instead of the process.
///
/// Nothing is added to the request here: the path, the body and the
/// `Authorization` header are the ones `ProofFlow` built.
private final class BlockingTransport: ProofTransport {
    /// Longer than `RealtimeTransport.resourceTimeout`, so the transport's own
    /// bound is what normally ends a call.
    static let bound: TimeInterval = RealtimeTransport.resourceTimeout + 60

    private let transport: RealtimeTransport

    init(realm: String, pin: String) throws {
        transport = try RealtimeTransport(realm: realm, pin: pin)
    }

    func call(method: String, path: String, body: String, authorization: String?) throws -> [String: Any] {
        let waiting = Waiting()
        let done = DispatchSemaphore(value: 0)
        let transport = transport
        Task.detached {
            do {
                let reply = try await transport.call(method: method, path: path,
                                                     body: body, authorization: authorization)
                waiting.finish(.success(reply))
            } catch {
                waiting.finish(.failure(error))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.bound) == .success, let outcome = waiting.take() else {
            throw FixtureError(code: "TransportTimeout", detail: "\(method) \(path)")
        }
        // `Reply.json()` is the client's own decoder, including its refusal of
        // a body that is not one JSON object.
        return try outcome.get().json()
    }
}

// MARK: - The commit seam

/// `SnapshotStore` with the two things the fixture needs on top: it counts the
/// commits it made and it can fail exactly one of them.
///
/// The counter is what the harness reads to prove that a repeated operation
/// wrote nothing; the fault is `fail_next_commit`
/// (`CleanSelfServiceBridge.java:30-38`), and like the Java fixture it refuses
/// to fire on a candidate that is not the one the scenario means to lose: an
/// incoming text together with its durable receipt.
private final class CountingSink: SnapshotSink {
    private let store: SnapshotStore
    private(set) var commits = 0
    var failNextCommit = false

    init(store: SnapshotStore) {
        self.store = store
    }

    func save(_ snapshot: String) throws {
        if failNextCommit {
            failNextCommit = false
            try requireIncomingCandidate(snapshot)
            FileHandle.standardError.write(Data(
                "INJECTED storage failure on incoming plaintext + receipt candidate before commit\n".utf8))
            throw FixtureError(code: "IOException", detail: "fixture commit fault")
        }
        try store.commit(snapshot)
        commits += 1
    }

    /// The candidate must hold a queued receipt and a dialog, or the fault
    /// would prove nothing (`CleanSelfServiceBridge.java:32-36`).
    private func requireIncomingCandidate(_ snapshot: String) throws {
        guard let state = JsonSpan.value(of: "state", in: snapshot) else {
            throw FixtureError(code: "AssertionError", detail: "candidate without a state member")
        }
        let proposed = try CoreBridge.command(state: state, request: "{\"op\":\"view\"}")
        let outbox = proposed.object["outbox"] as? [[String: Any]] ?? []
        let dialogs = proposed.object["dialogs"] as? [[String: Any]] ?? []
        guard !outbox.isEmpty, !dialogs.isEmpty else {
            throw FixtureError(code: "AssertionError",
                               detail: "fault must target an incoming text plus durable receipt candidate")
        }
    }
}

// MARK: - One phone

/// Everything one synthetic phone owns: its directory, its in-memory key, the
/// real client over them and the flow that talks to the stand.
private final class Phone {
    let sink: CountingSink
    let client: SelfServiceClient
    let flow: ProofFlow
    /// What the last `sync` ended with: `none`, `idle`, `proof` or `session`.
    var connection = "none"

    init(directory: URL, key: SymmetricKey, trust: ServiceTrust) throws {
        let store = SnapshotStore(directory: directory, key: key)
        let saved = try store.load()
        sink = CountingSink(store: store)
        // `compiled: nil`: there is no built-in realm in this tool, so the
        // stand given on the command line is the only server it can reach.
        client = try SelfServiceClient(saved: saved, sink: sink, fixture: trust, compiled: nil)
        flow = ProofFlow(client: client,
                         transport: try BlockingTransport(realm: trust.realm, pin: trust.pin))
    }

    /// Runs one operation of the line protocol.
    func perform(_ operation: String, _ value: String) throws {
        switch operation {
        case "create":
            try client.createIdentity()
        case "sync":
            switch try flow.connect() {
            case .idle: connection = "idle"
            case .proof: connection = "proof"
            case .session: connection = "session"
            }
        case "pair":
            // Android scans the contact through `QrCodec` first; there is no
            // QR codec in ParanoidKit yet, so the text is handed over as it
            // is. Everything the core checks is unchanged.
            _ = try client.previewContact(value)
            try client.pair(value, verified: true)
        case "send":
            let request = try object(value)
            try client.send(account: try string(request, "account"), text: try string(request, "text"))
        case "block":
            let request = try object(value)
            guard let blocked = request["blocked"] as? Bool else {
                throw FixtureError(code: "AssertionError", detail: "blocked must be a boolean")
            }
            try client.block(account: try string(request, "account"), blocked: blocked)
        case "fail_next_commit":
            sink.failNextCommit = true
        case "post_without_accept":
            // The server commits the envelope and the caller loses the answer
            // before the local acceptance (`CleanSelfServiceBridge.java:60-65`).
            guard let envelope = try client.pending().first else {
                throw FixtureError(code: "AssertionError", detail: "outbox is empty")
            }
            _ = try flow.proof(purpose: ChallengeIntent.messagePurpose, method: "POST",
                               path: "/v2/messages", body: try encode(envelope))
        case "pending", "view":
            break
        default:
            throw FixtureError(code: "IOException", detail: "unsupported fixture operation")
        }
    }

    /// The answer to one request: the client's own public view plus what the
    /// fixture knows about the connection and the commits it made. No state
    /// text, no key, no snapshot bytes.
    func view(after operation: String) throws -> [String: Any] {
        var out = try client.publicView()
        out["commits"] = sink.commits
        out["connection"] = connection
        out["realtime"] = flow.isRealtime
        out["session"] = flow.session != nil
        // `mode`, `account`, `device` and the credential fingerprint: the same
        // public identifiers `publicView` already carries.
        out["enrollment"] = try client.enrollment().map { $0 as Any } ?? NSNull()
        if operation == "pending" {
            out["pending"] = try client.pending()
        }
        return out
    }

    private func object(_ value: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw FixtureError(code: "AssertionError", detail: "expected one JSON object")
        }
        return object
    }

    private func string(_ object: [String: Any], _ member: String) throws -> String {
        guard let value = object[member] as? String else {
            throw FixtureError(code: "AssertionError", detail: "expected a string \(member)")
        }
        return value
    }

    private func encode(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            throw FixtureError(code: "AssertionError", detail: "unencodable envelope")
        }
        return text
    }
}

// MARK: - The run

private func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("service-bridge: \(message)\n".utf8))
    exit(status)
}

/// The five names the Java fixture allows, and no real telephone number
/// (`CleanSelfServiceBridge.java:19`).
private let synthetic: Set<String> = ["one", "two", "three", "four", "five"]

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: service-bridge <directory> <realm> <pin>", status: 2)
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let trust: ServiceTrust
do {
    trust = try ServiceTrust(realm: arguments[2], pin: arguments[3])
} catch {
    fail("refused realm/pin: \(describe(error).detail)", status: 2)
}
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: NSNumber(value: 0o700)])
} catch {
    fail("cannot create \(root.path)", status: 2)
}

/// The open phones and their wrapping keys.
///
/// The keys exist for this process only: closing the bridge loses them, which
/// is what makes a retained state file freeze the next one.
private final class Registry {
    private let root: URL
    private let trust: ServiceTrust
    private var keys: [String: SymmetricKey] = [:]
    private var phones: [String: Phone] = [:]

    init(root: URL, trust: ServiceTrust) {
        self.root = root
        self.trust = trust
    }

    /// Opens a phone the first time it is addressed, with the continuity rule
    /// of `StorageGuard.java:7-8` in front of it.
    func phone(_ name: String) throws -> Phone {
        if let open = phones[name] { return open }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let known = keys[name]
        try StorageGuard.requireContinuity(snapshotExists: SnapshotStore.snapshotExists(in: directory),
                                           keyExists: known != nil)
        let key = known ?? SymmetricKey(size: .bits256)
        keys[name] = key
        let open = try Phone(directory: directory, key: key, trust: trust)
        phones[name] = open
        return open
    }
}

private let registry = Registry(root: root, trust: trust)

while let line = readLine(strippingNewline: true) {
    var out: [String: Any]
    var operation = ""
    do {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw FixtureError(code: "IOException", detail: "expected <phone>\\t<op>\\t<base64>")
        }
        guard synthetic.contains(parts[0]) else {
            throw FixtureError(code: "IOException", detail: "synthetic phone required")
        }
        operation = parts[1]
        guard let decoded = Data(base64Encoded: parts[2]),
              let value = String(data: decoded, encoding: .utf8)
        else {
            throw FixtureError(code: "IOException", detail: "value is not base64 UTF-8")
        }
        let open = try registry.phone(parts[0])
        try open.perform(operation, value)
        out = try open.view(after: operation)
    } catch {
        let (code, detail) = describe(error)
        out = ["error": code, "detail": detail]
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else {
        fail("could not encode the reply", status: 2)
    }
    print(encoded.base64EncodedString())
    fflush(stdout)
}
