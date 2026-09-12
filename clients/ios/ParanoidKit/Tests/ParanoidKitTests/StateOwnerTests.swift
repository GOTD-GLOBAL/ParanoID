import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the state owner: who runs the core, which run a result
/// belongs to, what a pause does to a session, and how long a failed lane
/// waits.
///
/// The core is the real one (the macOS slice of `ParanoidCore.xcframework`)
/// over the in-memory device of `SelfServiceClientTests`; the server is
/// `StandServer` and the clock is a fake the test moves by hand. Nothing here
/// opens a connection, and no account is created on any server.
final class StateOwnerTests: XCTestCase {
    /// The local stand of a simulator run. Nothing in these tests may reach
    /// the hosted alpha.
    private static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    private let second = MonotonicClock.nanosecondsPerSecond

    // MARK: - who runs the core

    func testTheNetworkNeverRunsOnTheOwnerAndEveryCoreCallDoes() async throws {
        let owned = try Owned()
        let owner = owned.owner
        let watch = Watch()
        // Every call the flow makes records where it is running from. The
        // transport is the whole network of this client: if a request ever
        // observed itself on the owner, the owner would be suspended on a
        // socket while it held the ratchet.
        owned.transport.onCall = { _ in watch.record(owner.isOnOwner) }

        _ = try await owned.flow.connect()

        XCTAssertEqual(owned.transport.calls.count, 5, "register, commit, /health, challenge, session")
        XCTAssertEqual(watch.seen.count, owned.transport.calls.count)
        XCTAssertEqual(watch.seen.filter { $0 }, [], "no request ran on the state owner")
        // The other direction, on the same owner: work handed to `perform`
        // runs there, and it is real work — the registration answer and the
        // contact material derived from it are on the device by now.
        let (onOwner, registered) = try await owner.perform { client in
            (owner.isOnOwner, try client.registered())
        }
        XCTAssertTrue(onOwner)
        XCTAssertTrue(registered)
        XCTAssertGreaterThanOrEqual(owned.device.commits, 4,
                                    "create_identity, upgrade_v2 and the two registration candidates")
        // `perform` asserts the same thing on every call it makes, so the five
        // core calls of the connection above proved it as they ran.
        XCTAssertFalse(owner.isOnOwner, "the test itself is not the owner")
    }

    // MARK: - generations

    func testStartingAnAlreadyEnabledLoopMintsNoGeneration() async throws {
        let owned = try Owned()
        let owner = owned.owner

        let first = await owner.start()
        let again = await owner.start()

        XCTAssertEqual(again, first, "a second didBecomeActive restarts nothing")
        // Android kicks either way (`RealtimeLoop.java:53-54`): the loop that
        // is already running is asked to run a cycle, not to start over.
        XCTAssertEqual(owned.hook.wakes, 2)

        // A pause and a resume do mint one, and the paused run is not current
        // in between.
        await owner.stop()
        let stopped = await owner.current
        XCTAssertNil(stopped)
        let resumed = await owner.start()
        XCTAssertEqual(resumed.run, first.run + 2, "stop() moves the counter and so does start()")
        let current = await owner.current
        XCTAssertEqual(current, resumed)
        let stale = await owner.isCurrent(first)
        XCTAssertFalse(stale)

        // A closed owner starts nothing again.
        await owner.close()
        let afterClose = await owner.start()
        let none = await owner.current
        XCTAssertNil(none)
        let live = await owner.isCurrent(afterClose)
        XCTAssertFalse(live)
    }

    func testAResultThatReturnsUnderASupersededGenerationIsDiscarded() async throws {
        let owned = try Owned()
        let owner = owned.owner
        let run = await owner.start()
        guard case .session(let opened) = try await owned.flow.connect(under: run) else {
            return XCTFail("the stand offers the realtime capability")
        }

        // The loop is paused while the next answer is still in flight.
        await owner.stop()
        let late = try Self.reply(owned.server.session())

        await assertThrows({ try await owner.adoptSession(late, trust: Self.stand, under: run) }, {
            XCTAssertEqual($0 as? Superseded, Superseded(run))
        })

        // The answer never became the held session, and the one that was
        // opened under the live run is untouched.
        let held = await owner.session
        XCTAssertEqual(held?.id, opened.id)

        // A state operation under the superseded run does not reach the core
        // at all: the guard is in front of the closure, not inside it.
        let watch = Watch()
        await assertThrows({ try await owner.perform(run) { _ in watch.record(true) } }, {
            XCTAssertEqual($0 as? Superseded, Superseded(run))
        })
        XCTAssertEqual(watch.seen, [])

        // And so does a connection: nothing is dialled under a run that has
        // been superseded.
        let calls = owned.transport.calls.count
        await assertThrows({ try await owned.flow.connect(under: run) }, {
            XCTAssertEqual($0 as? Superseded, Superseded(run))
        })
        XCTAssertEqual(owned.transport.calls.count, calls)
    }

    // MARK: - the session belongs to the owner

    func testTheSessionSurvivesAPauseAndIsReusedByTheNextGeneration() async throws {
        let owned = try Owned()
        let owner = owned.owner
        let first = await owner.start()
        guard case .session(let opened) = try await owned.flow.connect(under: first) else {
            return XCTFail("session issued")
        }
        XCTAssertEqual(owned.server.issuedSessions, 1)

        await owner.stop()
        // Stopping is a pause: the session is not a generation's property.
        let paused = await owner.session
        XCTAssertEqual(paused?.id, opened.id)

        owned.source.advance(60 * second)
        let next = await owner.start()
        XCTAssertNotEqual(next, first)
        guard case .session(let reused) = try await owned.flow.connect(under: next) else {
            return XCTFail("session reused")
        }
        XCTAssertEqual(reused.id, opened.id)
        // The account has two live-session slots
        // (`server/src/self_service_http.rs:377-391`); a pause must not spend
        // one of them.
        XCTAssertEqual(owned.server.issuedSessions, 1)

        // At 240 seconds it is renewed through the second slot, and only then.
        owned.source.advance(179 * second)
        guard case .session(let stillReused) = try await owned.flow.connect(under: next) else {
            return XCTFail("session still young")
        }
        XCTAssertEqual(stillReused.id, opened.id)
        owned.source.advance(second)
        guard case .session(let renewed) = try await owned.flow.connect(under: next) else {
            return XCTFail("session renewed")
        }
        XCTAssertNotEqual(renewed.id, opened.id)
        XCTAssertEqual(owned.server.issuedSessions, 2)
    }

    func testTheSessionIsDroppedOnlyWhenItHasStoppedBeingUsable() async throws {
        let owned = try Owned()
        let owner = owned.owner
        _ = try await owned.flow.connect()
        let opened = await owner.session
        XCTAssertNotNil(opened)

        // Renewal: the object is still held, and it is no longer handed out.
        owned.source.advance(240 * second)
        let due = await owner.reusableSession()
        XCTAssertNil(due)
        let stillHeld = await owner.session
        XCTAssertEqual(stillHeld?.id, opened?.id)

        // Legacy: a server that no longer advertises the capability cannot be
        // talked to through a session, so it goes with the capability
        // (`RealtimeLoop.java:181`).
        let legacy = try Self.reply(["status": "ok", "protocol": Health.protocolName])
        let realtime = try await owner.applyHealth(legacy)
        XCTAssertFalse(realtime)
        let afterLegacy = await owner.session
        XCTAssertNil(afterLegacy)

        // The explicit drop is what a lane calls on a second 401, a 404 or
        // `session_exhausted` (`RealtimeLoop.java:191,207`). The stand
        // still advertises the capability, so rediscovering brings the session
        // route back.
        owned.source.advance(second)
        await owner.invalidateDiscovery()
        _ = try await owned.flow.connect()
        let reopened = await owner.session
        XCTAssertNotNil(reopened)
        await owner.dropSession()
        let dropped = await owner.session
        XCTAssertNil(dropped)
    }

    func testTheSessionRouteIsHeldOffAfterACapacityRejection() async throws {
        let owned = try Owned()
        let owner = owned.owner
        _ = try await owned.flow.connect()
        await owner.dropSession()
        // The 429 `session_capacity` answer of
        // `server/src/self_service_http.rs:377-391`: the account is at its two
        // live sessions, so the route is left alone for five seconds.
        await owner.holdSessions(for: 5 * second)

        owned.source.advance(4 * second)
        let held = await owner.sessionsAreHeld()
        XCTAssertTrue(held)
        guard case .proof = try await owned.flow.connect() else {
            return XCTFail("the hold selects the retained challenge transport")
        }
        XCTAssertEqual(owned.server.issuedSessions, 1)

        owned.source.advance(2 * second)
        let elapsed = await owner.sessionsAreHeld()
        XCTAssertFalse(elapsed)
        guard case .session = try await owned.flow.connect() else {
            return XCTFail("the hold elapsed")
        }
        XCTAssertEqual(owned.server.issuedSessions, 2)
    }

    // MARK: - a failed commit stops the lanes

    func testAFailedCommitFreezesTheOwnerAndStopsTheLanes() async throws {
        let owned = try Owned(createIdentity: false)
        let owner = owned.owner
        let run = await owner.start()
        owned.device.fileSystem.failure = { [device = owned.device] call in
            guard case .write = call else { return nil }
            return FileSystemError(.write, device.store.temporaryFileURL, errno: ENOSPC)
        }

        await assertThrows({ try await owner.perform(run) { try $0.createIdentity() } })

        let frozen = await owner.isFrozen
        XCTAssertTrue(frozen)
        // "Данные сохранены; подключение остановлено" (`RealtimeLoop.java:74`):
        // a client that cannot persist stops talking to the server.
        let current = await owner.current
        XCTAssertNil(current)
        await assertThrows({ try await owner.perform { try $0.hasIdentity() } }, {
            XCTAssertEqual($0 as? SelfServiceError, .frozen)
        })
        XCTAssertTrue(owned.transport.calls.isEmpty)
    }

    // MARK: - backoff

    func testTheBackoffDoublesToSixteenSecondsWithJitterUnderTwoHundredFiftyMilliseconds() {
        let expected: [UInt64] = [500, 1_000, 2_000, 4_000, 8_000, 16_000, 16_000]
        for (failures, milliseconds) in expected.enumerated() {
            XCTAssertEqual(Backoff.delay(failures: failures, jitter: 0),
                           milliseconds * 1_000_000, "failure \(failures)")
        }
        // Five doublings and no more: a server that has been down for an hour
        // is asked once every 16 seconds, not once an hour.
        XCTAssertEqual(Backoff.delay(failures: 50, jitter: 0), 16 * second)
        XCTAssertEqual(Backoff.delay(failures: -1, jitter: 0), Backoff.first)

        // The jitter is added, and it is always less than 250 ms.
        XCTAssertEqual(Backoff.delay(failures: 2, jitter: 1), 2 * second + 1)
        XCTAssertEqual(Backoff.delay(failures: 2, jitter: Backoff.jitter),
                       2 * second + Backoff.jitter - 1)
        for _ in 0..<500 {
            let delay = Backoff.delay(failures: 0)
            XCTAssertGreaterThanOrEqual(delay, Backoff.first)
            XCTAssertLessThan(delay, Backoff.first + Backoff.jitter)
        }
        XCTAssertEqual(Backoff.ceiling, 30 * second)
    }

    // MARK: - the wake seam

    func testTheWakeSeamIsTheOnlyWayIn() async throws {
        let owned = try Owned()
        XCTAssertEqual(owned.hook.wakes, 0)

        owned.owner.wake()
        XCTAssertEqual(owned.hook.wakes, 1)
        _ = await owned.owner.start()
        XCTAssertEqual(owned.hook.wakes, 2)

        // What the application installs does nothing at all: this client has
        // no push and no background delivery.
        NoPushHook().wake()
    }

    // MARK: - fixtures

    /// One answer in the shape the transport hands back.
    private static func reply(_ object: [String: Any]) throws -> RealtimeTransport.Reply {
        let data = try JSONSerialization.data(withJSONObject: object)
        return RealtimeTransport.Reply(text: try XCTUnwrap(String(data: data, encoding: .utf8)),
                                       bytes: data.count)
    }

    /// A device, the owner over it, the stand it talks to and the fake clock.
    ///
    /// `@unchecked Sendable` for the reason `Device` is: the fixture keeps the
    /// client so the test can read the state, which a lane may not do. The
    /// application hands the client to the owner in the expression that builds
    /// it and keeps nothing.
    private final class Owned: @unchecked Sendable {
        let device: Device
        let server: StandServer
        let transport: FakeTransport
        let source = FakeMonotonicSource()
        let pacer = RecordingPacer()
        let hook = CountingHook()
        let owner: StateOwner
        let flow: ProofFlow

        init(createIdentity: Bool = true) throws {
            device = try Device(name: "owned", trust: StateOwnerTests.stand)
            if createIdentity { try device.client.createIdentity() }
            server = try StandServer(credential: (try? device.client.credential()) ?? [:])
            transport = FakeTransport(server: server)
            owner = StateOwner(client: device.client, clock: source.clock, hook: hook)
            flow = ProofFlow(owner: owner, transport: transport, clock: source.clock, pacer: pacer)
        }
    }

    /// Counts the wakes the owner asks for.
    private final class CountingHook: PushHook, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var wakes: Int {
            lock.withLock { count }
        }

        func wake() {
            lock.withLock { count += 1 }
        }
    }

    /// What the fixture observed, from whichever task observed it.
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        var seen: [Bool] {
            lock.withLock { values }
        }

        func record(_ value: Bool) {
            lock.withLock { values.append(value) }
        }
    }
}
