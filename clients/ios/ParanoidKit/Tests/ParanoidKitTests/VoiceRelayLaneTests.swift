import Foundation
import ParanoidKit
import XCTest

/// What the TURN lane decides, over the real core and without a socket.
///
/// The client is the shipped one: `Device` holds the real
/// `SelfServiceClient` over the macOS slice of `ParanoidCore.xcframework`,
/// `StateOwner` owns it, and `ProofFlow` brings the connection up against
/// `StandServer` exactly as the text lanes do. The one seam is
/// `VoiceRelayEndpoint`: `Relay` answers a script instead of opening a
/// connection, so every rule about *which status means what* can be stated
/// here, and the rules about the socket itself stay with
/// `clients/ios/test_voice_relay_lane.py`, which uses the real
/// `VoiceRelayTransport` against a real pinned TLS server.
///
/// The source is `docs/protocol/voice-turn-v1.md` and the port is
/// `clients/android/src/org/paranoid/text/RealtimeLoop.java:105-168`, whose
/// own smoke (`clients/android/test/VoiceRelayLaneSmoke.java`) runs the same
/// stories.
final class VoiceRelayLaneTests: XCTestCase {
    /// A local stand. Nothing in these tests may reach the hosted alpha.
    static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                         pin: String(repeating: "ab", count: 32))
    /// The wall clock every document below is minted against.
    static let wallMilliseconds: Int64 = 1_800_000_000_000

    // MARK: - the answer that grants relay authority

    func testAValidDocumentGrantsRelayAuthorityAndNeverReachesTheDevice() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.body(Lane.document())]

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "relay")
        let config = try XCTUnwrap(outcome.config)
        XCTAssertEqual(config.urls, ["turn:127.0.0.2:34781?transport=udp",
                                     "turn:127.0.0.2:34781?transport=tcp"])
        XCTAssertTrue(config.usable(wallMilliseconds: Self.wallMilliseconds,
                                    monotonicNanoseconds: Int64(bitPattern: lane.source.clock.now().nanoseconds)))
        // "Credentials are volatile: no state snapshot, history, E2EE control,
        // saved configuration, URL query, error/log, screenshot or evidence
        // export includes them" (`voice-turn-v1.md`).
        let stored = try XCTUnwrap(try lane.device.stored())
        XCTAssertFalse(stored.contains(config.username))
        XCTAssertFalse(stored.contains(config.password))
        XCTAssertEqual(String(describing: config), "VoiceRelayConfig[redacted]")
        // The connection is closed when the request returns
        // (`VoiceRelayTransport.java:62`, `RealtimeLoop.java:166`).
        XCTAssertEqual(lane.relay.closes, 1)
    }

    func testTheSignedRequestIsExactlyTheFixedOperationWithOneCredentialAndNoBody() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.body(Lane.document())]

        _ = try await lane.request()

        XCTAssertEqual(lane.relay.credentials.count, 1)
        let credential = try XCTUnwrap(lane.relay.credentials.first)
        XCTAssertTrue(credential.hasPrefix(VoiceRelayTransport.credentialPrefix))
        // The core is the only thing that composes this request; the lane
        // refuses anything that is not `GET /v2/voice/turn` with an empty body
        // (`RealtimeLoop.java:148-149`).
        let session = await lane.owner.session
        let held = try XCTUnwrap(session)
        let signed = try SignedRequest(try lane.device.client.sessionRequest(
            session: held.context, operation: VoiceRelayLane.operation))
        XCTAssertEqual(signed.method, "GET")
        XCTAssertEqual(signed.path, VoiceRelayTransport.path)
        XCTAssertEqual(signed.body, "")
        // The voice route never goes through the text transport.
        XCTAssertFalse(lane.transport.calls.contains { $0.path == VoiceRelayTransport.path })
    }

    // MARK: - the one permitted repeat

    func testTheFirstUnauthorizedAnswerIsSignedAgainExactlyOnce() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.rejected(Rejected(status: 401)), .body(Lane.document())]

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "relay")
        // "The existing first ambiguous 401 may retry once with a freshly
        // signed nonce" (`voice-turn-v1.md`): two attempts, two credentials,
        // never a replay of the first.
        XCTAssertEqual(lane.relay.credentials.count, 2)
        XCTAssertNotEqual(lane.relay.credentials[0], lane.relay.credentials[1])
    }

    func testASecondUnauthorizedAnswerFailsAndLeavesTheTextSessionAlone() async throws {
        let lane = try await Lane.make()
        let session = await lane.owner.session
        let held = try XCTUnwrap(session)
        lane.relay.script = [.rejected(Rejected(status: 401)), .rejected(Rejected(status: 401))]

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "failed")
        XCTAssertEqual(lane.relay.credentials.count, 2, "no second retry")
        // "A 404 for this optional route does not discard an otherwise valid
        // text session or force legacy text rediscovery" — and neither does a
        // 401 here: `authorityFailure` is not on this path at all
        // (`RealtimeLoop.java:100-104,164-167`).
        let after = await lane.owner.session
        XCTAssertEqual(after?.id, held.id)
        let due = await lane.owner.isDiscoveryDue()
        XCTAssertFalse(due)
        XCTAssertEqual(lane.listener.losses, 0)
        XCTAssertEqual(lane.listener.notifications, 0)
    }

    // MARK: - the only downgrade there is

    func testAnAuthenticatedNotFoundPermitsTheDisclosedDirectMode() async throws {
        let lane = try await Lane.make()
        let session = await lane.owner.session
        let held = try XCTUnwrap(session)
        lane.relay.script = [.rejected(Rejected(status: 404, code: "turn_disabled"))]

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "direct")
        XCTAssertNil(outcome.config)
        XCTAssertTrue(outcome.authorized)
        XCTAssertEqual(lane.relay.credentials.count, 1, "a 404 is never repeated")
        let after = await lane.owner.session
        XCTAssertEqual(after?.id, held.id, "the optional route keeps the text session")
        let due = await lane.owner.isDiscoveryDue()
        XCTAssertFalse(due, "and does not force legacy text rediscovery")
    }

    func testAPreSessionServerStaysInTheDisclosedCompatibilityModeWithoutDialling() async throws {
        // An older v2 server that never advertised the capability.
        let lane = try await Lane.make(realtime: false)

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "direct")
        XCTAssertEqual(lane.relay.credentials.count, 0, "nothing was asked for")
    }

    // MARK: - everything that is not a downgrade

    func testNoOtherAnswerEverBecomesDirectMode() async throws {
        // "Redirects, TLS mismatch, malformed 200, timeout, 429, 5xx or
        // authorization failure never trigger this fallback"
        // (`voice-turn-v1.md`).
        let answers: [(String, Relay.Answer)] = [
            ("302", .rejected(Rejected(status: 302))),
            ("429", .rejected(Rejected(status: 429))),
            ("500", .rejected(Rejected(status: 500))),
            ("503", .rejected(Rejected(status: 503))),
            ("malformed 200", .body(Array("{\"v\":1}".utf8))),
            ("empty 200", .body([])),
            ("oversized 200", .body(Array(repeating: UInt8(ascii: " "),
                                          count: VoiceRelayConfig.maximumMetadataBytes + 1))),
            ("timeout", .failure(URLError(.timedOut))),
            ("refused pin", .failure(URLError(.cancelled))),
            ("response limit", .failure(TransportError.responseLimit)),
        ]
        for (name, answer) in answers {
            let lane = try await Lane.make()
            lane.relay.script = [answer]

            let outcome = try await lane.request()

            XCTAssertEqual(outcome.name, "failed", "\(name) must not grant authority")
            XCTAssertFalse(outcome.authorized, "\(name)")
            XCTAssertEqual(lane.relay.credentials.count, 1, "\(name) is never repeated")
            XCTAssertEqual(lane.listener.losses, 0, "\(name)")
        }
    }

    func testACredentialOutsideItsLifetimeWindowIsRefused() async throws {
        // 1200 s is the only ttl, and the remaining lifetime must land inside
        // 1 000 000..1 205 000 ms on receipt (`VoiceRelayConfig.java:17-18`).
        let stale = Lane.document(expires: Self.wallMilliseconds / 1000 + 900)
        let forged = Lane.document(expires: Self.wallMilliseconds / 1000 + 3600)
        for document in [stale, forged] {
            let lane = try await Lane.make()
            lane.relay.script = [.body(document)]

            let outcome = try await lane.request()

            XCTAssertEqual(outcome.name, "failed")
        }
    }

    func testACapableServerWithoutASessionFailsInsteadOfDowngrading() async throws {
        let lane = try await Lane.make()
        // The account is at its two-session cap: `ProofFlow` holds the route
        // for five seconds and hands the cycle the challenge transport
        // instead. "A busy capable server is not a legacy-server downgrade
        // signal" (`RealtimeLoop.java:141-142`).
        await lane.owner.dropSession()
        lane.transport.answer = { call in
            guard call.path == ChallengeIntent.sessionPath else { return nil }
            throw Rejected(status: 429, code: "session_capacity")
        }

        let outcome = try await lane.request()

        XCTAssertEqual(outcome.name, "failed")
        XCTAssertEqual(lane.relay.credentials.count, 0)
    }

    // MARK: - what a cancelled or superseded request is worth

    func testACancelledRequestIsNeverDeliveredAndItsConnectionIsDropped() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.body(Lane.document())]
        lane.relay.hold = true

        let waiter = Waiter()
        await lane.lane.request(under: lane.run) { waiter.deliver($0) }
        try await lane.relay.waitUntilHeld()
        await lane.lane.cancel()
        lane.relay.release()
        try await lane.quiesce()

        // "Cancel/terminal/auth-loss closes only the voice connection, drops
        // credentials/pending work and never captures audio from a delayed
        // callback" (`voice-turn-v1.md`).
        XCTAssertFalse(waiter.delivered)
        XCTAssertGreaterThanOrEqual(lane.relay.closes, 1)
    }

    func testAReplacementCancelsTheRequestItReplacesAndOnlyTheLatestIsDelivered() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.body(Lane.document()), .body(Lane.document())]
        lane.relay.hold = true

        let first = Waiter()
        let second = Waiter()
        await lane.lane.request(under: lane.run) { first.deliver($0) }
        try await lane.relay.waitUntilHeld()
        await lane.lane.request(under: lane.run) { second.deliver($0) }
        lane.relay.release()
        try await lane.quiesce()

        XCTAssertFalse(first.delivered, "a superseded callback is never delivered")
        XCTAssertEqual(second.outcome?.name, "relay")
        // One body at a time: the replacement waited for the first to return
        // rather than opening a second connection beside it
        // (`RealtimeLoop.java:20-21`).
        XCTAssertLessThanOrEqual(lane.relay.concurrent, 1)
    }

    func testASupersededGenerationIsNeverDelivered() async throws {
        let lane = try await Lane.make()
        lane.relay.script = [.body(Lane.document())]
        let stale = lane.run
        await lane.owner.stop()

        let waiter = Waiter()
        await lane.lane.request(under: stale) { waiter.deliver($0) }
        try await lane.quiesce()

        XCTAssertFalse(waiter.delivered)
    }

    // MARK: - the fixture

    /// One registered device, the connection both text lanes share, and the
    /// voice lane above them.
    final class Lane: @unchecked Sendable {
        let device: Device
        let server: StandServer
        let transport: FakeTransport
        let source: FakeMonotonicSource
        let owner: StateOwner
        let flow: ProofFlow
        let listener: Counting
        let relay = Relay()
        let lane: VoiceRelayLane
        /// The realtime run every request below is made under.
        var run = Generation(run: 0)

        /// One fixture whose connection is already up: the lane requires a
        /// live session and opens none of its own.
        static func make(realtime: Bool = true) async throws -> Lane {
            let lane = try Lane(realtime: realtime)
            lane.run = await lane.owner.start()
            guard realtime else { return lane }
            guard case .session = try await lane.flow.connect(under: lane.run) else {
                throw SetupFailure.noSession
            }
            return lane
        }

        private init(realtime: Bool) throws {
            device = try Device(name: "voice-relay", trust: VoiceRelayLaneTests.stand)
            try device.register()
            server = try StandServer(credential: try device.client.credential())
            if !realtime { server.realtimeCapability = nil }
            transport = FakeTransport(server: server)
            source = FakeMonotonicSource()
            let owner = StateOwner(client: device.client, clock: source.clock)
            self.owner = owner
            flow = ProofFlow(owner: owner, transport: transport,
                             clock: source.clock, pacer: RecordingPacer())
            listener = Counting()
            let relay = self.relay
            lane = VoiceRelayLane(owner: owner, flow: flow, listener: listener,
                                  clock: source.clock,
                                  wall: { VoiceRelayLaneTests.wallMilliseconds },
                                  endpoint: { _ in relay })
        }

        /// One request, awaited.
        func request() async throws -> VoiceRelayOutcome {
            let waiter = Waiter()
            await lane.request(under: run) { waiter.deliver($0) }
            return try await waiter.wait()
        }

        /// Waits until the lane holds nothing.
        func quiesce() async throws {
            for _ in 0..<2000 {
                let pending = await lane.isPending
                if !pending { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            // A cancelled body still has to run out; give it room to.
            for _ in 0..<200 { await Task.yield() }
        }

        /// One valid issuer document for this stand.
        static func document(expires: Int64 = VoiceRelayLaneTests.wallMilliseconds / 1000 + 1200,
                             host: String = "127.0.0.2") -> [UInt8] {
            let username = "\(expires):" + String(repeating: "0123456789abcdef", count: 2)
            let credential = Data(count: 20).base64EncodedString()
            let document = """
                {"v":1,\
                "urls":["turn:\(host):34781?transport=udp","turn:\(host):34781?transport=tcp"],\
                "username":"\(username)","credential":"\(credential)",\
                "expires":\(expires),"ttl":1200}
                """
            return Array(document.utf8)
        }

        enum SetupFailure: Error { case noSession }
    }

    /// The endpoint seam: a script instead of a socket.
    ///
    /// `@unchecked Sendable` like every fake in this target — it is reached
    /// from the lane's own task and its state is kept under a lock.
    final class Relay: VoiceRelayEndpoint, @unchecked Sendable {
        enum Answer {
            case body([UInt8])
            case rejected(Rejected)
            case failure(any Error)
        }

        private let lock = NSLock()
        private var answers: [Answer] = []
        private var seen: [String] = []
        private var closed = 0
        private var held = false
        private var inFlight = 0
        private var peak = 0
        /// Holds every answer until `release()`, so a test can replace or
        /// cancel a request while one is in flight.
        var hold = false

        var script: [Answer] {
            get { lock.withLock { answers } }
            set { lock.withLock { answers = newValue } }
        }

        /// The `Authorization` value of every attempt, in order.
        var credentials: [String] { lock.withLock { seen } }
        var closes: Int { lock.withLock { closed } }
        /// The most connections this endpoint ever had open at once.
        var concurrent: Int { lock.withLock { peak } }

        func get(authorization: String) async throws -> [UInt8] {
            let answer: Answer? = lock.withLock {
                seen.append(authorization)
                inFlight += 1
                peak = max(peak, inFlight)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
            defer { lock.withLock { inFlight -= 1 } }
            if lock.withLock({ hold }) {
                lock.withLock { held = true }
                while lock.withLock({ hold }) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            switch answer {
            case .body(let bytes): return bytes
            case .rejected(let rejected): throw rejected
            case .failure(let error): throw error
            case nil: throw URLError(.unknown)
            }
        }

        func close() async {
            lock.withLock { closed += 1 }
        }

        /// Blocks the test until one request is parked inside `get`.
        func waitUntilHeld() async throws {
            for _ in 0..<5000 {
                if lock.withLock({ held }) { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw URLError(.timedOut)
        }

        func release() {
            lock.withLock {
                hold = false
                held = false
            }
        }
    }

    /// The one callback, and whether it ever arrived.
    final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: VoiceRelayOutcome?
        private var continuation: CheckedContinuation<VoiceRelayOutcome, Never>?

        var delivered: Bool { lock.withLock { value != nil } }
        var outcome: VoiceRelayOutcome? { lock.withLock { value } }

        func deliver(_ outcome: VoiceRelayOutcome) {
            let waiting = lock.withLock { () -> CheckedContinuation<VoiceRelayOutcome, Never>? in
                value = outcome
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.resume(returning: outcome)
        }

        func wait() async throws -> VoiceRelayOutcome {
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

    /// What the lane told the application. It must stay silent: a voice
    /// failure publishes no status and never claims lost authorization
    /// (`RealtimeLoop.java:164-167`).
    final class Counting: RealtimeListener, @unchecked Sendable {
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
}
