import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the proof flow: the challenge intents, the 600 ms the
/// server's challenge meter demands between them, `/health` capability
/// discovery, and the session that is validated by the core before it is used.
///
/// The core is the real one (the macOS slice of `ParanoidCore.xcframework`)
/// over the in-memory device of `SelfServiceClientTests`; the server is
/// `StandServer`, which mints challenges and sessions that a real server would
/// mint, and the clock is a fake one driven by the test. Nothing here opens a
/// connection, and no account is created on any server.
final class ProofFlowTests: XCTestCase {
    /// The local stand of a simulator run. Nothing in these tests may reach
    /// the hosted alpha.
    private static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))
    /// SHA-256 of `{}`, the body digest every control challenge carries
    /// (`docs/protocol/self-service-v2.md`).
    private static let controlDigest =
        "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"

    private let second = MonotonicClock.nanosecondsPerSecond

    // MARK: - the order of one connection

    func testAConnectionRegistersDiscoversAndOpensASessionInThatOrder() async throws {
        let stand = try Stand()

        guard case .session(let session) = try await stand.flow.connect() else {
            return XCTFail("the stand offers the realtime capability")
        }

        // Challenge, then the request it authorizes; capability discovery
        // before a session is asked for; the session challenge on the
        // authenticated route, because this device is enrolled by then.
        XCTAssertEqual(stand.transport.calls.map(\.path),
                       ["/v2/registration/challenge", "/v2/registration/commit",
                        "/health",
                        "/v2/auth/challenge", "/v2/session"])
        XCTAssertEqual(stand.transport.calls.map(\.method), ["POST", "POST", "GET", "POST", "POST"])
        // Only the two authorized requests carry a header; a challenge and
        // `/health` are unauthenticated.
        XCTAssertEqual(stand.transport.calls.map(\.authorized), [false, true, false, false, true])
        // Both control bodies are exactly `{}`, and `/health` carries none.
        XCTAssertEqual(stand.transport.calls[1].body, "{}")
        XCTAssertEqual(stand.transport.calls[2].body, "")
        XCTAssertEqual(stand.transport.calls[4].body, "{}")
        XCTAssertTrue(try XCTUnwrap(stand.transport.calls[1].authorization).hasPrefix("ParanoidV2 "))
        XCTAssertTrue(try XCTUnwrap(stand.transport.calls[4].authorization).hasPrefix("ParanoidV2 "))

        // The registration answer is on the device, with the contact material
        // the core derives from it.
        XCTAssertTrue(try stand.device.client.registered())
        XCTAssertNotNil(try stand.device.client.contactText())
        XCTAssertEqual(session.account, try stand.device.client.credential()["account"] as? String)
        XCTAssertEqual(session.realm, Self.stand.realm)
        let realtime = await stand.owner.isRealtime
        XCTAssertTrue(realtime)
        let held = await stand.owner.session
        XCTAssertEqual(held?.id, session.id)
        XCTAssertEqual(stand.server.issuedSessions, 1)
    }

    func testEachChallengeIntentNamesExactlyTheRequestItAuthorizes() async throws {
        let stand = try Stand()

        _ = try await stand.flow.connect()

        // `register` carries the whole credential object; the account is not
        // known to the server yet (`SelfServiceClient.java:176`).
        let registration = try stand.intent(of: stand.transport.calls[0])
        XCTAssertEqual(registration["purpose"] as? String, "register")
        XCTAssertEqual(registration["method"] as? String, "POST")
        XCTAssertEqual(registration["path"] as? String, "/v2/registration/commit")
        XCTAssertEqual(registration["body"] as? String, Self.controlDigest)
        XCTAssertNotNil(registration["credential"] as? [String: Any])
        XCTAssertNil(registration["account"])

        // Afterwards the three enrollment strings are enough, and the
        // credential is the fingerprint rather than the object
        // (`SelfServiceClient.java:178-179`).
        let session = try stand.intent(of: stand.transport.calls[3])
        XCTAssertEqual(session["purpose"] as? String, "session")
        XCTAssertEqual(session["method"] as? String, "POST")
        XCTAssertEqual(session["path"] as? String, "/v2/session")
        XCTAssertEqual(session["body"] as? String, Self.controlDigest)
        XCTAssertEqual(session["account"] as? String,
                       try stand.device.client.credential()["account"] as? String)
        XCTAssertEqual(session["credential"] as? String, stand.server.fingerprint)
        XCTAssertNil(session["credential"] as? [String: Any])
        XCTAssertEqual(Set(session.keys), ["account", "device", "credential",
                                           "purpose", "method", "path", "body"])

        // The digest is of the body, not of its shape.
        XCTAssertEqual(ChallengeIntent.digest(of: "{}"), Self.controlDigest)
        XCTAssertEqual(ChallengeIntent.digest(of: ""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - the challenge meter

    func testTwoChallengesAreSpacedByAtLeastSixHundredMilliseconds() async throws {
        // The clock never moves on its own here, so the second challenge is as
        // early as it can possibly be.
        let stand = try Stand()
        var pathsWhenPaused: [String] = []
        stand.pacer.onWait = { [weak stand] _ in
            pathsWhenPaused = stand?.transport.calls.map(\.path) ?? []
        }

        _ = try await stand.flow.connect()

        // The server meters 2 challenges per account per second, so the client
        // spaces its own at 600 ms (`RealtimeLoop.java:170`).
        XCTAssertEqual(stand.pacer.waits, [600_000_000])
        // And it waits before the challenge, not after it.
        XCTAssertEqual(pathsWhenPaused,
                       ["/v2/registration/challenge", "/v2/registration/commit", "/health"])
    }

    func testNoWaitIsAskedForWhenTheSpacingHasAlreadyElapsed() async throws {
        let stand = try Stand()
        // Every request takes 700 ms of real time, so the meter is satisfied
        // by the flow's own latency and nothing sleeps.
        stand.transport.onCall = { [weak stand] _ in stand?.source.advance(700_000_000) }

        _ = try await stand.flow.connect()

        XCTAssertTrue(stand.pacer.waits.isEmpty)
    }

    func testThePartialSpacingIsWaitedOut() async throws {
        let stand = try Stand()
        stand.transport.onCall = { [weak stand] _ in stand?.source.advance(100_000_000) }

        _ = try await stand.flow.connect()

        // Three requests of 100 ms each stand between the two challenges.
        XCTAssertEqual(stand.pacer.waits, [300_000_000])
    }

    // MARK: - registration happens once

    func testASecondConnectionRegistersNothingAndCommitsNothing() async throws {
        let stand = try Stand()
        _ = try await stand.flow.connect()
        let commits = stand.device.commits
        let calls = stand.transport.calls.count
        stand.source.advance(second)

        guard case .session = try await stand.flow.connect() else { return XCTFail("session reused") }

        // Nothing was dialled: the enrollment is active, the capability is
        // still fresh and the session is younger than 240 seconds.
        XCTAssertEqual(stand.transport.calls.count, calls)
        XCTAssertEqual(stand.device.commits, commits)
        XCTAssertEqual(stand.server.issuedSessions, 1)
    }

    func testAnIdenticalRegistrationAnswerIsAppliedOnceAndCommitsNothingAgain() async throws {
        let stand = try Stand()
        _ = try await stand.flow.connect()
        let commits = stand.device.commits

        // "Fresh identical registration retries return the same mapping"
        // (`docs/protocol/self-service-v2.md`): applying that same mapping
        // again produces the same state text, so no candidate is written.
        try stand.device.client.registrationResult(status: stand.server.status)

        XCTAssertEqual(stand.device.commits, commits)
        XCTAssertTrue(try stand.device.client.registered())
        XCTAssertNotNil(try stand.device.client.contactText())
    }

    // MARK: - the session is the core's to accept

    func testASessionIssuedForAnotherAccountIsRefusedByTheCoreAndNotAdopted() async throws {
        let stand = try Stand()
        let other = try Device(name: "other", trust: Self.stand)
        try other.register()
        stand.server.sessionAccount = try XCTUnwrap(try other.client.credential()["account"] as? String)

        await assertThrows({ try await stand.flow.connect() }, { failure in
            // The context parses and is scoped to this realm, so only the
            // saved identity can tell it apart — and the identity lives in the
            // core (`clean_service.rs:688-699`).
            XCTAssertEqual(failure as? CoreError, .rejected("session_context_mismatch"))
        })

        let held = await stand.owner.session
        XCTAssertNil(held, "a session the core refuses is never held")
        XCTAssertEqual(stand.transport.calls.last?.path, "/v2/session")
        XCTAssertTrue(try stand.device.client.registered())
    }

    func testASessionIssuedForAnotherRealmIsRefusedBeforeTheCoreIsAsked() async throws {
        let stand = try Stand()
        stand.server.sessionRealm = "https://127.0.0.3:38443"

        await assertThrows({ try await stand.flow.connect() }, { failure in
            XCTAssertEqual(failure as? SessionFailure, .foreignRealm)
        })
        let held = await stand.owner.session
        XCTAssertNil(held)

        // The pin is the other half of the same scope.
        let pinned = try Stand()
        pinned.server.sessionPin = String(repeating: "cd", count: 32)
        await assertThrows({ try await pinned.flow.connect() }, { failure in
            XCTAssertEqual(failure as? SessionFailure, .foreignRealm)
        })
    }

    func testASessionAnswerThatIsNotTheStrictObjectIsRefused() throws {
        let received = MonotonicInstant(nanoseconds: 0)
        let valid: [String: Any] = ["id": "d5ba9f0e-2fb5-4c40-9a09-1f8bbcb9a3f8",
                                    "epoch": "7a2f4b86-0d69-4a5e-9f27-2e4a4e6a2c11",
                                    "expires": 1_800_000_000,
                                    "realm": Self.stand.realm, "pin": Self.stand.pin,
                                    "account": "account", "device": "device",
                                    "credential": String(repeating: "1f", count: 32)]
        XCTAssertEqual(try SessionModel.open(valid, received: received, trust: Self.stand).account,
                       "account")

        var broken: [[String: Any]] = []
        for member in SessionModel.members {
            var missing = valid
            missing[member] = nil
            broken.append(missing)
        }
        var extra = valid
        extra["token"] = "anything"
        broken.append(extra)
        var text = valid
        text["expires"] = "1800000000"
        broken.append(text)
        var zero = valid
        zero["expires"] = 0
        broken.append(zero)
        var fraction = valid
        fraction["expires"] = 1_800_000_000.5
        broken.append(fraction)
        var object = valid
        object["credential"] = ["root": "x"]
        broken.append(object)

        for reply in broken {
            XCTAssertThrowsError(try SessionModel.open(reply, received: received, trust: Self.stand)) {
                XCTAssertEqual($0 as? SessionFailure, .malformedSession, "\(reply.keys.sorted())")
            }
        }
    }

    // MARK: - lifetime on the monotonic clock

    func testASessionIsReusedUntilTwoHundredFortySecondsAndRenewedAfterThat() async throws {
        let stand = try Stand()
        guard case .session(let first) = try await stand.flow.connect() else {
            return XCTFail("session issued")
        }

        stand.source.advance(239 * second)
        guard case .session(let reused) = try await stand.flow.connect() else {
            return XCTFail("session reused")
        }
        XCTAssertEqual(reused.id, first.id)
        XCTAssertEqual(stand.server.issuedSessions, 1)

        stand.source.advance(second)
        guard case .session(let renewed) = try await stand.flow.connect() else {
            return XCTFail("session renewed")
        }
        XCTAssertNotEqual(renewed.id, first.id)
        XCTAssertEqual(stand.server.issuedSessions, 2)
        let held = await stand.owner.session
        XCTAssertEqual(held?.id, renewed.id)
    }

    func testTheClampedLifetimeIsThreeHundredSecondsFromTheMonotonicReceipt() throws {
        let received = MonotonicInstant(nanoseconds: 5 * second)
        let session = try SessionModel.open(Self.sessionAnswer(), received: received, trust: Self.stand)

        XCTAssertFalse(session.needsRenewal(at: received.advanced(byNanoseconds: 239 * second)))
        XCTAssertTrue(session.needsRenewal(at: received.advanced(byNanoseconds: 240 * second)))
        XCTAssertFalse(session.isExpired(at: received.advanced(byNanoseconds: 299 * second)))
        XCTAssertTrue(session.isExpired(at: received.advanced(byNanoseconds: 300 * second)))
        XCTAssertEqual(SessionModel.renewal, 240 * second)
        XCTAssertEqual(SessionModel.lifetime, 300 * second)
        // The server's own `expires` is carried for the signing transcript and
        // is never what the client counts down.
        XCTAssertEqual(session.expires, 1_800_000_000)
    }

    // MARK: - capability discovery

    func testDiscoveryRepeatsAfterSixtySecondsAndWheneverALaneInvalidatesIt() async throws {
        let stand = try Stand()
        _ = try await stand.flow.connect()
        XCTAssertEqual(stand.transport.calls.filter { $0.path == "/health" }.count, 1)

        stand.source.advance(30 * second)
        _ = try await stand.flow.connect()
        XCTAssertEqual(stand.transport.calls.filter { $0.path == "/health" }.count, 1)

        stand.source.advance(31 * second)
        _ = try await stand.flow.connect()
        XCTAssertEqual(stand.transport.calls.filter { $0.path == "/health" }.count, 2)

        // A 404 on a cached session route, or a failed renewal, rediscovers at
        // once (`docs/protocol/realtime-v1.md:172-177`).
        await stand.owner.invalidateDiscovery()
        _ = try await stand.flow.connect()
        XCTAssertEqual(stand.transport.calls.filter { $0.path == "/health" }.count, 3)
    }

    func testAServerWithoutTheRealtimeCapabilityKeepsTheChallengeTransport() async throws {
        let stand = try Stand()
        _ = try await stand.flow.connect()
        let issued = await stand.owner.session
        XCTAssertNotNil(issued)
        stand.server.realtimeCapability = nil
        await stand.owner.invalidateDiscovery()

        guard case .proof = try await stand.flow.connect() else {
            return XCTFail("an older v2 server selects the retained proof transport")
        }

        // The session went with the capability, and no new one was asked for.
        let held = await stand.owner.session
        XCTAssertNil(held)
        let realtime = await stand.owner.isRealtime
        XCTAssertFalse(realtime)
        XCTAssertEqual(stand.server.issuedSessions, 1)
        XCTAssertEqual(stand.transport.calls.last?.path, "/health")
    }

    func testAHealthReplyOfAnotherProtocolStopsTheConnection() async throws {
        let replies: [[String: Any]] = [["status": "ok", "protocol": "something-else"],
                                        ["status": "starting", "protocol": "paranoid-self-service-v2"],
                                        ["protocol": "paranoid-self-service-v2"],
                                        [:]]
        for reply in replies {
            let stand = try Stand()
            stand.server.health = reply
            await assertThrows({ try await stand.flow.connect() }, { failure in
                XCTAssertEqual(failure as? TransportError, .protocolMismatch, "\(reply)")
            })
            let held = await stand.owner.session
            XCTAssertNil(held)
            XCTAssertEqual(stand.transport.calls.last?.path, "/health",
                           "nothing is asked for after a server that is not this one")
        }
    }

    func testAHeldSessionRouteUsesTheChallengeTransportUntilTheHoldElapses() async throws {
        let stand = try Stand()
        _ = try await stand.flow.connect()
        // What a lane does with a 429 `session_capacity` on `/v2/session`
        // (`RealtimeLoop.java:209`).
        await stand.owner.dropSession()
        await stand.owner.holdSessions(for: 5 * second)

        stand.source.advance(4 * second)
        guard case .proof = try await stand.flow.connect() else { return XCTFail("the hold stands") }
        XCTAssertEqual(stand.server.issuedSessions, 1)

        stand.source.advance(2 * second)
        guard case .session = try await stand.flow.connect() else { return XCTFail("the hold elapsed") }
        XCTAssertEqual(stand.server.issuedSessions, 2)
    }

    // MARK: - nothing is dialled without an identity, or after a failed commit

    func testAClientWithoutAnIdentityDialsNothing() async throws {
        let device = try Device(name: "empty", trust: Self.stand)
        let stand = try Stand(device: device, createIdentity: false)

        guard case .idle = try await stand.flow.connect() else { return XCTFail("no identity yet") }

        XCTAssertTrue(stand.transport.calls.isEmpty)
    }

    func testAFrozenClientDialsNothing() async throws {
        let device = try Device(name: "frozen", trust: Self.stand)
        device.fileSystem.failure = { call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: ENOSPC)
        }
        XCTAssertThrowsError(try device.client.createIdentity())
        XCTAssertTrue(device.client.isBroken)
        let stand = try Stand(device: device, createIdentity: false)

        await assertThrows({ try await stand.flow.connect() }, { failure in
            XCTAssertEqual(failure as? SelfServiceError, .frozen)
        })

        XCTAssertTrue(stand.transport.calls.isEmpty)
    }

    // MARK: - the clock itself

    func testTheContinuousClockAdvancesAndIsScaledByTheTimebase() throws {
        let clock = MonotonicClock.continuous
        let first = clock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let second = clock.now()

        XCTAssertGreaterThanOrEqual(second, first)
        let elapsed = second.nanoseconds(since: first)
        XCTAssertGreaterThan(elapsed, 15_000_000, "20 ms of sleep must be at least 15 ms of clock")
        XCTAssertLessThan(elapsed, 5 * MonotonicClock.nanosecondsPerSecond)

        // Apple silicon reports 125/3: ticks are 1/24000000 s, not
        // nanoseconds, and a client that ignored the timebase would scale
        // every interval in it by 40.
        let scaled = MonotonicClock(numerator: 125, denominator: 3) { 0 }
        XCTAssertEqual(scaled.nanoseconds(fromTicks: 24_000_000), 1_000_000_000)
        XCTAssertEqual(scaled.nanoseconds(fromTicks: 0), 0)
        // Exact for a tick count a machine reaches after a year of uptime, and
        // for one no machine reaches at all.
        XCTAssertEqual(scaled.nanoseconds(fromTicks: 24_000_000 * 31_536_000), 31_536_000_000_000_000)
        XCTAssertEqual(scaled.nanoseconds(fromTicks: .max), .max)
        let plain = MonotonicClock { 7 }
        XCTAssertEqual(plain.now().nanoseconds, 7)

        // The interval arithmetic never underflows, and it saturates.
        XCTAssertEqual(MonotonicInstant(nanoseconds: 1).nanoseconds(since: MonotonicInstant(nanoseconds: 9)), 0)
        XCTAssertEqual(MonotonicInstant(nanoseconds: .max).advanced(byNanoseconds: 9).nanoseconds, .max)
    }

    func testNoSourceFileNamesAClockThatStopsWhileTheDeviceSleeps() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ParanoidKit", isDirectory: true)
        // The two Darwin readings that freeze on suspend. A session, a
        // rediscovery interval or a challenge spacing measured on either of
        // them would survive a sleeping phone and be wrong on waking.
        let forbidden = ["CACurrentMediaTime", "CLOCK_UPTIME_RAW"]
        var scanned = 0
        var continuous = false

        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        for case let name as String in files where name.hasSuffix(".swift") {
            let source = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            scanned += 1
            continuous = continuous || source.contains("mach_continuous_time")
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(name) must not read \(token)")
            }
        }

        XCTAssertGreaterThan(scanned, 5, "the scan found the sources")
        XCTAssertTrue(continuous, "the only clock of this client is mach_continuous_time()")
    }

    // MARK: - fixtures

    /// One valid `SessionV2` answer for the stand, for the checks that do not
    /// need a core.
    private static func sessionAnswer() -> [String: Any] {
        ["id": "d5ba9f0e-2fb5-4c40-9a09-1f8bbcb9a3f8",
         "epoch": "7a2f4b86-0d69-4a5e-9f27-2e4a4e6a2c11",
         "expires": 1_800_000_000,
         "realm": stand.realm, "pin": stand.pin,
         "account": "account", "device": "device",
         "credential": String(repeating: "1f", count: 32)]
    }

    /// One synthetic device, the owner over it, the server it talks to, the
    /// fake clock and the flow over all four.
    ///
    /// The device keeps its client so that these tests can read the state
    /// directly, which a lane may not do; everything the flow itself does goes
    /// through the owner.
    private final class Stand {
        let device: Device
        let server: StandServer
        let transport: FakeTransport
        let source: FakeMonotonicSource
        let pacer: RecordingPacer
        let owner: StateOwner
        let flow: ProofFlow

        init(device: Device? = nil, createIdentity: Bool = true) throws {
            self.device = try device ?? Device(name: "own", trust: ProofFlowTests.stand)
            if createIdentity { try self.device.client.createIdentity() }
            // Before registration the only identity there is is the
            // registration request; a device that has none still needs a
            // server object, so the credential is read leniently.
            server = try StandServer(credential: (try? self.device.client.credential()) ?? [:])
            transport = FakeTransport(server: server)
            source = FakeMonotonicSource()
            pacer = RecordingPacer()
            owner = StateOwner(client: self.device.client, clock: source.clock)
            flow = ProofFlow(owner: owner, transport: transport,
                             clock: source.clock, pacer: pacer)
        }

        /// The challenge intent one recorded request carried.
        func intent(of call: FakeTransport.Call) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        }
    }
}

/// A clock the test moves by hand.
///
/// `@unchecked Sendable`: the flow and the test run on the same thread, and
/// the reading closure the clock stores has to be `@Sendable` because the real
/// clock is a global constant.
final class FakeMonotonicSource: @unchecked Sendable {
    private var nanoseconds: UInt64 = 1_000_000_000

    /// A clock over this source whose ticks are already nanoseconds.
    var clock: MonotonicClock { MonotonicClock { self.nanoseconds } }

    func advance(_ delta: UInt64) {
        nanoseconds += delta
    }
}

/// Records every wait the flow asks for, and lets the test decide whether time
/// actually passes.
///
/// `@unchecked Sendable`: a pacer is reached from the lane's task, so the
/// protocol requires it; the recording is kept under a lock and the test reads
/// it only after the flow has returned.
final class RecordingPacer: ProofPacer, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []
    /// Runs instead of sleeping; the test uses it to let time pass, or not.
    var onWait: ((UInt64) -> Void)?

    var waits: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Forgets what was recorded, so that one test can measure two phases.
    func reset() {
        lock.withLock { recorded.removeAll() }
    }

    func wait(nanoseconds: UInt64) async throws {
        lock.withLock { recorded.append(nanoseconds) }
        onWait?(nanoseconds)
    }
}

/// `XCTAssertThrowsError` for an expression that has to be awaited.
///
/// XCTest's own assertion takes an autoclosure, which cannot be `async`, so the
/// expression is passed as a closure and the error is handed to the same kind
/// of handler.
func assertThrows<T>(_ expression: () async throws -> T,
                     _ handler: (any Error) -> Void = { _ in },
                     file: StaticString = #filePath,
                     line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

/// What a self-service v2 server answers, without a server.
///
/// The challenges it mints are exactly what the core accepts: the account,
/// device, realm, pin and credential fingerprint of the identity that asked,
/// canonical UUIDv4 identifiers and a 32-byte base64 nonce
/// (`clients/core/src/self_service.rs:264-281`). Everything else is the shape
/// of `docs/protocol/self-service-v2.md` and
/// `docs/protocol/realtime-v1.md:29-31`.
final class StandServer {
    let credential: [String: Any]
    /// The `POST /v2/registration/commit` answer: `{mode,account,device,credential}`.
    let status: [String: Any]
    /// The `GET /health` answer; `realtime` is added when the capability is on.
    var health: [String: Any]?
    /// `nil` for an older v2 server that has no session route.
    var realtimeCapability: String? = Health.realtimeName
    /// Overrides for the sessions this server issues.
    var sessionAccount: String?
    var sessionRealm: String?
    var sessionPin: String?
    private(set) var issuedSessions = 0

    /// The credential fingerprint the server knows this device by.
    var fingerprint: String { (status["credential"] as? String) ?? "" }

    init(credential: [String: Any]) throws {
        self.credential = credential
        self.status = credential.isEmpty
            ? [:]
            : try SelfServiceClientTests.activeStatus(for: credential)
    }

    func healthReply() -> [String: Any] {
        if let health { return health }
        var reply: [String: Any] = ["status": "ok", "protocol": Health.protocolName]
        if let realtimeCapability { reply["realtime"] = realtimeCapability }
        return reply
    }

    func challenge(for intent: [String: Any]) -> [String: Any] {
        ["id": Self.uuid(), "epoch": Self.uuid(), "nonce": Self.nonce(),
         "expires": 1_800_000_060,
         "realm": credential["realm"] ?? "", "pin": credential["pin"] ?? "",
         "account": credential["account"] ?? "", "device": credential["device"] ?? "",
         "credential": fingerprint,
         "purpose": intent["purpose"] ?? "", "method": intent["method"] ?? "",
         "path": intent["path"] ?? "", "body": intent["body"] ?? ""]
    }

    func session() -> [String: Any] {
        issuedSessions += 1
        return ["id": Self.uuid(), "epoch": Self.uuid(), "expires": 1_800_000_300,
                "realm": sessionRealm ?? credential["realm"] ?? "",
                "pin": sessionPin ?? credential["pin"] ?? "",
                "account": sessionAccount ?? credential["account"] ?? "",
                "device": credential["device"] ?? "",
                "credential": fingerprint]
    }

    /// Canonical, which for the core means lowercase (`Uuid::to_string`).
    private static func uuid() -> String { UUID().uuidString.lowercased() }

    /// 32 OS-CSPRNG bytes in standard padded base64.
    private static func nonce() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...UInt8.max) }).base64EncodedString()
    }
}

/// The network seam of the proof flow, recorded and answered locally.
///
/// `@unchecked Sendable` like every fake in this target: `ProofTransport` is
/// reached from a lane's task, the recording is kept under a lock, and the
/// hooks the tests install run on whichever task made the call — which is
/// never the state owner, and `StateOwnerTests` is what proves it.
final class FakeTransport: ProofTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let path: String
        let body: String
        let authorization: String?

        var authorized: Bool { authorization != nil }
    }

    enum Failure: Error, Equatable {
        case unexpectedRoute(String)
        case unencodableReply
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Runs before every answer; the test uses it to let time pass.
    var onCall: ((Call) -> Void)?
    /// Answers a call itself when it returns something.
    var answer: ((Call) throws -> [String: Any]?)?

    private let server: StandServer

    init(server: StandServer) {
        self.server = server
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func call(method: String, path: String, body: String,
              authorization: String?) async throws -> RealtimeTransport.Reply {
        let call = Call(method: method, path: path, body: body, authorization: authorization)
        lock.withLock { recorded.append(call) }
        onCall?(call)
        if let reply = try answer?(call) { return try Self.reply(reply) }
        switch path {
        case ChallengeIntent.registrationChallengePath, ChallengeIntent.authChallengePath:
            let intent = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            return try Self.reply(server.challenge(for: intent ?? [:]))
        case ChallengeIntent.registrationCommitPath:
            return try Self.reply(server.status)
        case HealthDiscovery.path:
            return try Self.reply(server.healthReply())
        case ChallengeIntent.sessionPath:
            return try Self.reply(server.session())
        default:
            throw Failure.unexpectedRoute(path)
        }
    }

    /// One answer in the shape the real transport hands back: the body as
    /// text, which the state owner decodes on the owner.
    private static func reply(_ object: [String: Any]) throws -> RealtimeTransport.Reply {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { throw Failure.unencodableReply }
        return RealtimeTransport.Reply(text: text, bytes: data.count)
    }
}
