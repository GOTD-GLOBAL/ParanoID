// voice-lane-probe: the host-side client of `clients/ios/test_voice_relay_lane.py`.
//
// It drives the shipped TURN lane — `VoiceRelayLane` over the real
// `VoiceRelayTransport`, the real pinned TLS stack, the real `StateOwner` and
// the real Rust core — against the pinned HTTPS stub of
// `clients/ios/test/turn_stub.py`, and prints one JSON report.
//
// The identity, the registration and the realtime session are synthetic, in
// exactly the way `clients/android/test/VoiceRelayLaneSmoke.java:70-86` makes
// them synthetic: the core creates a genuine identity and a genuine device key
// pair, the enrollment is committed locally with the credential fingerprint the
// core itself computes, and the session context is minted here rather than by
// a server. Everything the lane then does is real — the core signs each
// request over the whole session transcript, and the stub verifies that
// Ed25519 signature before it answers. No PostgreSQL issuer, no TURN server,
// no media and no hosted server are involved.
//
// Protocol:
//   stdin   one JSON object: {realm, pin, directory, identity, scenarios}
//   stdout  one JSON object: the report below
//   exit    0 the run finished, 2 it could not start
//
// Nothing it prints carries a credential: the TURN username and password are
// checked here and reported only as booleans, and the session and account
// identifiers never leave this process.
import CryptoKit
import Foundation
import ParanoidKit

// MARK: - Failures

private struct ProbeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The domain and the code of a failure, never a URL, a host or a body.
private func describe(_ error: any Error) -> String {
    switch error {
    case let rejected as Rejected: return "http_\(rejected.status)"
    case let failure as ProbeError: return failure.description
    case let failure as TransportError: return "TransportError.\(failure)"
    case let failure as VoiceRelayError: return "VoiceRelayError.\(failure)"
    case let failure as VoiceRelayFailure: return "VoiceRelayFailure.\(failure)"
    case let failure as PinnedTrustFailure: return "PinnedTrustFailure.\(failure.description)"
    case let failure as SelfServiceError: return "SelfServiceError.\(failure.description)"
    case let failure as URLError: return "URLError \(failure.errorCode)"
    default:
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

// MARK: - Small helpers

private func encode(_ object: [String: Any]) throws -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { throw ProbeError("unencodable report") }
    return text
}

private func string(_ object: [String: Any], _ member: String) throws -> String {
    guard let value = object[member] as? String else {
        throw ProbeError("expected a string \(member)")
    }
    return value
}

private func hexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `paranoid_key_protocol::transcript`: each field as big-endian length plus
/// its UTF-8 bytes (`key-protocol/src/lib.rs:14-21`).
private func transcript(_ fields: [String]) -> Data {
    var bytes = Data()
    for field in fields {
        let value = Data(field.utf8)
        withUnsafeBytes(of: UInt32(value.count).bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(value)
    }
    return bytes
}

/// The credential fingerprint the core knows this device by
/// (`Credential::fingerprint`, `key-protocol/src/lib.rs:57-71`).
private func fingerprint(of credential: [String: Any]) throws -> String {
    var fields = ["paranoid-credential-v1"]
    for name in ["root", "account", "device", "auth", "realm", "pin", "olm"] {
        fields.append(try string(credential, name))
    }
    return hexDigest(transcript(fields))
}

/// The four public members this probe needs out of the core's credential.
///
/// They are read on the state owner and carried out of it as one `Sendable`
/// value, because a decoded `[String: Any]` is not `Sendable` and must never
/// cross that boundary.
private struct Identity: Sendable {
    let account: String
    let device: String
    /// The device's public Ed25519 key, base64. The stub verifies with it.
    let auth: String
    /// The credential fingerprint the core knows this device by.
    let fingerprint: String
}

/// One callback, awaited, with a bound.
private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: VoiceRelayOutcome?
    private var continuation: CheckedContinuation<VoiceRelayOutcome, Never>?

    func deliver(_ outcome: VoiceRelayOutcome) {
        let waiting = lock.withLock { () -> CheckedContinuation<VoiceRelayOutcome, Never>? in
            guard value == nil else { return nil }
            value = outcome
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: outcome)
    }

    func wait() async -> VoiceRelayOutcome {
        await withCheckedContinuation { (resume: CheckedContinuation<VoiceRelayOutcome, Never>) in
            let ready = lock.withLock { () -> VoiceRelayOutcome? in
                if let value { return value }
                continuation = resume
                return nil
            }
            if let ready { resume.resume(returning: ready) }
        }
    }
}

/// What the lane published. It must stay silent on every scenario.
private final class Silence: RealtimeListener, @unchecked Sendable {
    private let lock = NSLock()
    private var published = 0
    private var lost = 0

    var notifications: Int { lock.withLock { published } }
    var losses: Int { lock.withLock { lost } }

    func changed(connected: Bool, status: String) {
        lock.withLock { published += 1 }
    }

    func authorizationLost() {
        lock.withLock { lost += 1 }
    }
}

// MARK: - The run

@MainActor
private func run(_ plan: [String: Any]) async throws -> [String: Any] {
    let realm = try string(plan, "realm")
    let pin = try string(plan, "pin")
    let directory = URL(fileURLWithPath: try string(plan, "directory"), isDirectory: true)
    let identityPath = URL(fileURLWithPath: try string(plan, "identity"))
    guard let scenarios = plan["scenarios"] as? [String], !scenarios.isEmpty else {
        throw ProbeError("expected a non-empty scenarios array")
    }
    let trust = try ServiceTrust(realm: realm, pin: pin)

    // The device: a real store, a key that lives only in this process, the
    // real client over the real core. `compiled: nil` — this tool has no
    // built-in realm and can dial nothing but the stub it was given.
    let key = SymmetricKey(size: .bits256)
    // The client, its store and its sink are built and given away in one
    // expression, exactly as the application builds them: the owner becomes
    // their only caller, and nothing here can keep a reference and race the
    // lane against it. The compiler is what enforces that.
    //
    // `marker: nil` on every one of them: a command line tool has no
    // application container, and its `UserDefaults.standard` is the build Mac
    // user's own, so the commit's sixth step has nothing true to say here.
    let saved = try SnapshotStore(directory: directory, key: key, marker: nil).load()
    let owner = StateOwner(client: try SelfServiceClient(
        saved: saved,
        sink: SnapshotStore(directory: directory, key: key, marker: nil),
        fixture: trust, compiled: nil))
    // A second store over the same bytes and the same key, which is what the
    // next launch would open: it is how this probe reads what actually
    // reached the device without touching the store the client commits
    // through (`Device.reopenStore`).
    let reader = SnapshotStore(directory: directory, key: key, marker: nil)
    let transport = try RealtimeTransport(realm: trust.realm, pin: trust.pin)
    let flow = ProofFlow(owner: owner, transport: transport)
    let listener = Silence()
    let lane = VoiceRelayLane(owner: owner, flow: flow, listener: listener)

    let generation = await owner.start()
    try await owner.perform(generation) { try $0.createIdentity() }
    // The decoded credential never leaves the owner: `perform` hands back only
    // `Sendable` values, which is the rule this client is built on.
    let identity = try await owner.perform(generation) { held -> Identity in
        let credential = try held.credential()
        return Identity(account: try string(credential, "account"),
                        device: try string(credential, "device"),
                        auth: try string(credential, "auth"),
                        fingerprint: try fingerprint(of: credential))
    }
    try await owner.perform(generation) { held in
        try held.registrationResult(status: ["mode": "active",
                                               "account": identity.account,
                                               "device": identity.device,
                                               "credential": identity.fingerprint])
    }

    // The session context, minted here exactly as `VoiceRelayLaneSmoke.java:80`
    // mints it. The core validates it against the saved identity before it
    // signs anything against it, and `adoptSession` is what makes it do so.
    let expires = Int64(Date().timeIntervalSince1970) + 300
    let context: [String: Any] = ["id": UUID().uuidString.lowercased(),
                                  "epoch": UUID().uuidString.lowercased(),
                                  "expires": expires,
                                  "realm": trust.realm, "pin": trust.pin,
                                  "account": identity.account,
                                  "device": identity.device,
                                  "credential": identity.fingerprint]
    // What the stub needs to verify a signature: the public session context
    // and the device's public Ed25519 key. No secret is written.
    try Data(try encode(["session": context, "auth": identity.auth]).utf8)
        .write(to: identityPath, options: [.atomic])
    let adopted = try await owner.adoptSession(
        RealtimeTransport.Reply(text: try encode(context),
                                bytes: try encode(context).utf8.count),
        trust: trust)

    var report: [[String: Any]] = []
    for (index, name) in scenarios.enumerated() {
        // One unauthenticated marker per scenario, so that the stub's record
        // says which requests belonged to which story and the harness can
        // count the attempts of each one.
        _ = try? await transport.call(method: "GET", path: "/v2/marker?scenario=\(index)")
        let waiter = Waiter()
        let started = DispatchTime.now().uptimeNanoseconds
        await lane.request(under: generation) { waiter.deliver($0) }
        let outcome = await waiter.wait()
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        var entry: [String: Any] = ["name": name, "outcome": outcome.name,
                                    "authorized": outcome.authorized, "ms": Int(elapsed)]
        if let config = outcome.config {
            let host = trust.realm.dropFirst("https://".count)
                .split(separator: ":").first.map(String.init) ?? ""
            entry["detail"] = [
                "urls": config.urls.count,
                // The two exact forms, recomputed here from the retained
                // origin: never the literal values, which name this machine.
                "urls_bound_to_realm": config.urls == [
                    "turn:\(host):\(VoiceRelayConfig.relayPort)?transport=udp",
                    "turn:\(host):\(VoiceRelayConfig.relayPort)?transport=tcp",
                ],
                "username_binds_expires": config.username.contains(":"),
                "credential_characters": config.password.count,
                // The second reading, the one that runs immediately before an
                // `RTCPeerConnection` would be created.
                "usable_before_media": config.usable(
                    wallMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
                    monotonicNanoseconds: Int64(bitPattern: MonotonicClock.continuous.now().nanoseconds)),
                // "Credentials are volatile": nothing of them is on the device.
                "absent_from_snapshot": !((try? reader.load()) ?? "")
                    .contains(config.username)
                    && !((try? reader.load()) ?? "").contains(config.password),
            ]
        }
        report.append(entry)
    }

    // The optional route disturbed neither the text session nor the discovery
    // timestamp (`docs/protocol/voice-turn-v1.md`, last paragraph).
    let held = await owner.session
    let due = await owner.isDiscoveryDue()
    return ["scenarios": report,
            "session_kept": held?.id == adopted.id,
            "discovery_due": due,
            "notifications": listener.notifications,
            "authorization_losses": listener.losses]
}

// MARK: - Entry point

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let plan = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    FileHandle.standardError.write(Data("voice-lane-probe: expected one JSON plan on stdin\n".utf8))
    exit(2)
}
do {
    let report = try await run(plan)
    print(try encode(report))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("voice-lane-probe: \(describe(error))\n".utf8))
    exit(2)
}
