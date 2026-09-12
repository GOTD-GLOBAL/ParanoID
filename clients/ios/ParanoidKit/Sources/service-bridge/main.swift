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
// view, exactly as the Java fixture does, and the process stays alive. One
// operation is the iOS fixture's own: `longpoll` runs both lanes for the
// number of seconds it is given, which is the only way to exercise the
// long-poll transport from a tool that otherwise answers one line per request.
//
// Everything below the protocol is the real client: `StateOwner` holds the
// `SelfServiceClient` and every bridge call runs on it, `SnapshotStore` commits
// through the five durable steps, `ProofFlow` runs the challenge/sign/request
// cycle and `RealtimeTransport` carries every byte over the pinned TLS stack.
// Nothing is mocked and nothing is re-implemented here. Two things are the
// fixture's own, because a command line tool has neither of them:
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
// `sync` is one foreground refresh over the shipped lanes: the connection
// cycle of `ProofFlow.connect()` — register if needed, discover the
// capability, issue and validate a session — and then `SendLane`, `ReceiveLane`
// and `SendLane` again, which is `SyncCycle.run(outbound, inbound, frozen)`
// (`clients/android/src/org/paranoid/text/SyncCycle.java:41-50`). `longpoll`
// is the same two lanes under one generation for a fixed time, which is
// `RealtimeLoop.run()` as the application drives it between `didBecomeActive`
// and `didEnterBackground`. Neither re-implements a protocol step: the lanes,
// the session and every commit are the shipped ones.
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

// MARK: - Small helpers

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
        throw FixtureError(code: "AssertionError", detail: "unencodable object")
    }
    return text
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
///
/// Both counters are read from the fixture's own task and written on the state
/// owner, so they are kept under a lock; the store behind them is only ever
/// used from the owner.
private final class CountingSink: SnapshotSink, @unchecked Sendable {
    private let store: SnapshotStore
    private let lock = NSLock()
    private var made = 0
    private var fault = false

    /// How many candidates reached the device.
    var commits: Int {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    var failNextCommit: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fault
        }
        set {
            lock.lock()
            fault = newValue
            lock.unlock()
        }
    }

    init(store: SnapshotStore) {
        self.store = store
    }

    /// Consumes the one-shot fault: it is armed from the fixture's task and
    /// disarmed on the owner, in one step, so it can fire only once.
    private func takeFault() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let armed = fault
        fault = false
        return armed
    }

    func save(_ snapshot: String) throws {
        if takeFault() {
            try requireIncomingCandidate(snapshot)
            FileHandle.standardError.write(Data(
                "INJECTED storage failure on incoming plaintext + receipt candidate before commit\n".utf8))
            throw FixtureError(code: "IOException", detail: "fixture commit fault")
        }
        try store.commit(snapshot)
        lock.lock()
        made += 1
        lock.unlock()
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

// MARK: - What the lanes published

/// Everything the shipped lanes told this fixture, counted.
///
/// It is a `RealtimeListener` and nothing more, so what it records is exactly
/// what a screen would render: the online flag and the status beside it, plus
/// the authorization notice. A page, an account and a message never reach it.
///
/// Both lanes publish on the state owner and the fixture reads the counters
/// from its own task, so they are kept under a lock. Zero offline
/// notifications over a long run is the statement a `longpoll` makes: the lane
/// publishes every failed cycle as it happens, without a debounce
/// (`RealtimeLoop.java:237,280`), so a single dropped connection that the
/// client did not absorb would show up here.
private final class Tally: RealtimeListener, @unchecked Sendable {
    private let lock = NSLock()
    private var online = 0
    private var offline = 0
    private var lost = 0
    private var statuses: [String] = []

    func changed(connected: Bool, status: String) {
        lock.lock()
        if connected {
            online += 1
        } else {
            offline += 1
            if !statuses.contains(status) { statuses.append(status) }
        }
        lock.unlock()
    }

    func authorizationLost() {
        lock.lock()
        lost += 1
        lock.unlock()
    }

    /// Starts counting again: one `longpoll` run is one measurement.
    func reset() {
        lock.lock()
        online = 0
        offline = 0
        lost = 0
        statuses = []
        lock.unlock()
    }

    /// The counts, and the distinct user-facing statuses of the failures.
    var report: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["online": online, "offline": offline, "authorization_lost": lost,
                "offline_statuses": statuses]
    }
}

// MARK: - One phone

/// Everything one synthetic phone owns: its directory, its in-memory key, the
/// state owner over them, the flow that talks to the stand and the two lanes
/// above both.
///
/// The owner is the only thing that holds the client: every operation below
/// runs one closure on it and gets back a value, exactly as a lane does in the
/// application (`StateOwner.perform`). The fixture's own task never touches the
/// core, so the two halves of this file are the two halves of the client — the
/// state owner and the network — and nothing joins them but `await`.
@MainActor
private final class Phone {
    let sink: CountingSink
    let owner: StateOwner
    let flow: ProofFlow
    /// The shipped lanes, in the object the application holds.
    let loop: RealtimeLoop
    /// What those lanes published, for the `longpoll` measurement.
    let tally: Tally
    /// What the last `sync` ended with: `none`, `idle`, `proof` or `session`.
    var connection = "none"
    /// What the last `longpoll` run measured; empty until one has run.
    var poll: [String: Any] = [:]

    init(directory: URL, key: SymmetricKey, trust: ServiceTrust) throws {
        let store = SnapshotStore(directory: directory, key: key)
        let saved = try store.load()
        sink = CountingSink(store: store)
        // `compiled: nil`: there is no built-in realm in this tool, so the
        // stand given on the command line is the only server it can reach.
        let client = try SelfServiceClient(saved: saved, sink: sink, fixture: trust, compiled: nil)
        let transport = try RealtimeTransport(realm: trust.realm, pin: trust.pin)
        // The wake seam has to be the one object the owner signals and the send
        // lane waits on, so it is built here and shared, exactly as the
        // application builds it (`RealtimeLoop`).
        let signal = WakeSignal()
        let owner = StateOwner(client: client, hook: signal)
        let flow = ProofFlow(owner: owner, transport: transport)
        let tally = Tally()
        self.owner = owner
        self.flow = flow
        self.tally = tally
        loop = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                            listener: tally, signal: signal)
    }

    /// Runs one operation of the line protocol.
    func perform(_ operation: String, _ value: String) async throws {
        switch operation {
        case "create":
            try await owner.perform { try $0.createIdentity() }
        case "sync":
            try await syncCycle()
        case "longpoll":
            let request = try object(value)
            guard let seconds = (request["seconds"] as? NSNumber)?.doubleValue,
                  seconds >= 0, seconds <= 1800
            else {
                throw FixtureError(code: "AssertionError", detail: "seconds must be 0...1800")
            }
            try await longPoll(seconds: seconds)
        case "pair":
            // Android scans the contact through `QrCodec` first; there is no
            // QR codec in ParanoidKit yet, so the text is handed over as it
            // is. Everything the core checks is unchanged.
            try await owner.perform { client in
                _ = try client.previewContact(value)
                try client.pair(value, verified: true)
            }
        case "send":
            let request = try object(value)
            let account = try string(request, "account")
            let text = try string(request, "text")
            try await owner.perform { try $0.send(account: account, text: text) }
        case "block":
            let request = try object(value)
            let account = try string(request, "account")
            guard let blocked = request["blocked"] as? Bool else {
                throw FixtureError(code: "AssertionError", detail: "blocked must be a boolean")
            }
            try await owner.perform { try $0.block(account: account, blocked: blocked) }
        case "fail_next_commit":
            sink.failNextCommit = true
        case "post_without_accept":
            // The server commits the envelope and the caller loses the answer
            // before the local acceptance (`CleanSelfServiceBridge.java:60-65`).
            let envelope = try await owner.perform { client -> String? in
                try client.pending().first.map(encode)
            }
            guard let envelope else {
                throw FixtureError(code: "AssertionError", detail: "outbox is empty")
            }
            _ = try await flow.proof(purpose: ChallengeIntent.messagePurpose, method: "POST",
                                     path: "/v2/messages", body: envelope)
        case "pending", "view":
            break
        default:
            throw FixtureError(code: "IOException", detail: "unsupported fixture operation")
        }
    }

    // MARK: - One foreground refresh

    /// `sync`: the connection, one pass over the outbox, one page, and the pass
    /// that carries the receipts the page queued.
    ///
    /// It is `SelfServiceClient.sync()` driven through
    /// `SyncCycle.run(outbound, inbound, frozen)` (`SyncCycle.java:41-50`) with
    /// the shipped lanes in place of that class's two closures: a first
    /// outbound failure is remembered rather than reported, because "receive
    /// does not depend on a successful outbound batch"
    /// (`SelfServiceClient.java:135`) and the pass after the page is the one
    /// whose failure the caller hears; an ambiguous local commit is never
    /// treated as a network failure and ends the cycle where it happened
    /// (`SyncCycle.java:34-37`).
    ///
    /// The generation is minted per call, which is exactly what
    /// `didBecomeActive` does in the application (`LifecyclePolicy`): the first
    /// cycle of a generation reads `messages` instead of waiting on `events`,
    /// so one `sync` is one immediate page and never a twenty-second long poll.
    /// The session belongs to the owner and survives that restart, so nothing
    /// here spends one of the account's two slots
    /// (`docs/protocol/realtime-v1.md:179-181`).
    private func syncCycle() async throws {
        let generation = await restart()
        switch try await flow.connect(under: generation) {
        case .idle: connection = "idle"
        case .proof: connection = "proof"
        case .session: connection = "session"
        }
        do {
            try await loop.send.cycle(under: generation)
        } catch {
            if await owner.isFrozen { throw error }
        }
        try await loop.receive.cycle(under: generation)
        try await loop.send.cycle(under: generation)
        await loop.stop()
    }

    /// `longpoll`: both lanes, under one generation, for `seconds`.
    ///
    /// This is `RealtimeLoop.run()` as the application runs it between
    /// `didBecomeActive` and `didEnterBackground`, and nothing else: the
    /// receive lane waits on `GET /v2/events` — at most twenty seconds per
    /// wait on this server (`docs/protocol/realtime-v1.md:97-99`) — across the
    /// server's eight-second idle header timeout and its 120-second absolute
    /// socket lifetime (`:148-151`), and the session is renewed at 240 seconds
    /// out of the second account slot (`:179-181`). What the run reports is
    /// what the lanes published.
    ///
    /// The generation is superseded **before** the lane task is cancelled, so
    /// a request the deadline cuts off publishes nothing: `announce` is silent
    /// under a superseded run, and the measurement therefore counts only
    /// failures that happened while the lanes were meant to be running.
    private func longPoll(seconds: Double) async throws {
        let generation = await restart()
        tally.reset()
        let clock = MonotonicClock.continuous
        let started = clock.now()
        let before = await owner.session?.id
        let lanes = Task.detached { [loop] in await loop.run() }
        try? await Task.sleep(nanoseconds: UInt64(seconds * Double(MonotonicClock.nanosecondsPerSecond)))
        await loop.stop()
        lanes.cancel()
        await lanes.value
        let elapsed = Double(clock.now().nanoseconds(since: started))
            / Double(MonotonicClock.nanosecondsPerSecond)
        let after = await owner.session?.id
        var report = tally.report
        report["seconds"] = (elapsed * 10).rounded() / 10
        report["superseded"] = !(await owner.isCurrent(generation))
        report["session_held"] = after != nil
        report["session_renewed"] = before != nil && after != nil && before != after
        poll = report
    }

    /// A fresh generation for the operation that follows
    /// (`StateOwner.start()` mints one only on stopped lanes, so the stop is
    /// what makes it new).
    private func restart() async -> Generation {
        await loop.stop()
        return await loop.start()
    }

    /// The answer to one request: the client's own public view plus what the
    /// fixture knows about the connection and the commits it made. No state
    /// text, no key, no snapshot bytes.
    ///
    /// The view is built and encoded on the owner, because a decoded core
    /// reply is exactly the kind of value that may not leave it; what comes
    /// back is one JSON text, which the fixture then adds its own counters to.
    func view(after operation: String) async throws -> [String: Any] {
        let text = try await owner.perform { client -> String in
            var out = try client.publicView()
            // `mode`, `account`, `device` and the credential fingerprint: the
            // same public identifiers `publicView` already carries.
            out["enrollment"] = try client.enrollment().map { $0 as Any } ?? NSNull()
            if operation == "pending" {
                out["pending"] = try client.pending()
            }
            return try encode(out)
        }
        var out = try object(text)
        out["commits"] = sink.commits
        out["connection"] = connection
        out["realtime"] = await owner.isRealtime
        out["session"] = await owner.session != nil
        if operation == "longpoll" { out["longpoll"] = poll }
        return out
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
@MainActor
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
        // The one place this fixture waits for the network. `ProofFlow` is
        // asynchronous from end to end — the lanes of the application await it
        // from their own tasks — so the command-line tool that has no lanes
        // awaits it here, at the top level, and needs no adapter of its own.
        try await open.perform(operation, value)
        out = try await open.view(after: operation)
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
