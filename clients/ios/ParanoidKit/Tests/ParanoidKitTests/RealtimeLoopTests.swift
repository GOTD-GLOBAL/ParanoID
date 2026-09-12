import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the send lane and the loop around it: what leaves the
/// outbox, in which order, what one rejection does to the session and to the
/// user, and what a pause costs (`docs/protocol/realtime-v1.md:127-130,150-151,167-181`,
/// `docs/protocol/self-service-v2.md:56-58,80-81`).
///
/// The core is the real one (the macOS slice of `ParanoidCore.xcframework`)
/// over the in-memory device of `SelfServiceClientTests`; the server is
/// `StandServer` with the message route answered by the test, and the clock
/// and the pacers are fakes the test moves by hand. Nothing here opens a
/// connection, and no account is created on any server.
final class RealtimeLoopTests: XCTestCase {
    /// The local stand of a simulator run. Nothing in these tests may reach
    /// the hosted alpha.
    static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                         pin: String(repeating: "ab", count: 32))

    private let second = MonotonicClock.nanosecondsPerSecond

    // MARK: - the outbox, in order, persisted before it is published

    func testTheOutboxGoesOutInOrderAndEveryAcceptanceIsDurableBeforeItIsPublished() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        let ids = try (1...3).map { try queue.enqueue("[TEST ONLY] сообщение \($0)") }
        // The session is opened first so that the test can sign the same three
        // operations itself and compare them byte for byte with what the lane
        // actually sent.
        guard case .session(let context) = try await queue.flow.connect(under: run) else {
            return XCTFail("the stand offers the realtime capability")
        }
        let expected = try ids.map { id in
            try SignedRequest(try queue.device.client.sessionRequest(session: context.context,
                                                                     operation: SendLane.sendOperation,
                                                                     id: id))
        }

        let outcome = try await queue.lane.cycle(under: run)

        XCTAssertEqual(outcome, .sent(accepted: 3))
        // "The immutable outbox remains the signing source"
        // (`clients/core/src/clean_service.rs:677`): the lane posts exactly the
        // method, the path and the body `sign_session_v2` handed back, in
        // outbox order, and composes nothing of its own.
        let posts = queue.posts
        XCTAssertEqual(posts.map(\.method), expected.map(\.method))
        XCTAssertEqual(posts.map(\.path), expected.map(\.path))
        XCTAssertEqual(posts.map(\.body), expected.map(\.body))
        XCTAssertEqual(posts.compactMap { Queue.identifier(in: $0.body) }, ids)
        for post in posts {
            XCTAssertTrue(post.authorization?.hasPrefix("ParanoidSessionV2 ") == true)
        }
        // The nonce is freshly signed for every request; nothing is replayed.
        XCTAssertEqual(Set(posts.compactMap(\.authorization)).count, 3)

        XCTAssertTrue(try queue.device.client.pending().isEmpty)
        let notifications = queue.listener.notifications
        XCTAssertEqual(notifications.count, 3, "one after each acceptance")
        XCTAssertEqual(notifications.map(\.connected), [true, true, true])
        XCTAssertEqual(Set(notifications.map(\.status)), [RealtimeStatus.connected])
        // At every notification the queue the application could read and the
        // queue in the sealed file were the same, and so were the delivery
        // marks: `accepted_v2` is durable before the mark it produces is
        // published (`docs/protocol/self-service-v2.md:56-58`).
        XCTAssertEqual(notifications.map(\.queued), [2, 1, 0])
        XCTAssertEqual(notifications.map(\.durableQueue), [2, 1, 0])
        XCTAssertEqual(notifications.map(\.marks), [1, 2, 3])
        XCTAssertEqual(notifications.map(\.durableMarks), [1, 2, 3])
        XCTAssertEqual(queue.listener.problems, [])
        XCTAssertEqual(queue.listener.losses, 0)
    }

    // MARK: - the one repeat a pooled socket needs

    func testAFirstUnauthorizedAnswerIsSignedAgainAndTheSecondRetiresTheSession() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        _ = try queue.enqueue("[TEST ONLY] один")
        queue.routes.messages = { _ in throw Rejected(status: 401) }

        await queue.lane.run(under: run, cycles: 1)

        // "A pooled connection can lose the response after nonce consumption.
        // One exact immutable retry with a newly signed nonce is safe"
        // (`RealtimeLoop.java:202-205`): exactly two attempts, each signed
        // again, and never a third.
        let posts = queue.posts
        XCTAssertEqual(posts.count, 2)
        let first = try XCTUnwrap(posts.first)
        let second = try XCTUnwrap(posts.dropFirst().first)
        XCTAssertEqual(first.body, second.body, "the same envelope, unchanged")
        XCTAssertNotEqual(first.authorization, second.authorization, "a fresh nonce")
        let held = await queue.owner.session
        XCTAssertNil(held)
        let due = await queue.owner.isDiscoveryDue()
        XCTAssertTrue(due, "a 401 sends the client back to /health")
        // The application is told it lost authorization once per failed pass,
        // and the message never claims anything was lost
        // (`RealtimeLoop.java:83-86,290`).
        XCTAssertEqual(queue.listener.losses, 1)
        XCTAssertEqual(queue.listener.notifications.map(\.connected), [false])
        XCTAssertEqual(queue.listener.notifications.first?.status, RealtimeStatus.unconfirmed)
        // Nothing left the queue.
        XCTAssertEqual(try queue.device.client.pending().count, 1)
    }

    func testANotFoundRetiresTheSessionAndRediscoversWithoutClaimingLostAuthorization() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        _ = try queue.enqueue("[TEST ONLY] нет маршрута")
        queue.routes.messages = { _ in throw Rejected(status: 404) }

        await queue.lane.run(under: run, cycles: 1)

        // A 404 is not repeated: it is not an ambiguous socket, it is a route
        // this server does not have (`RealtimeLoop.java:206-209`).
        XCTAssertEqual(queue.posts.count, 1)
        let held = await queue.owner.session
        XCTAssertNil(held)
        let due = await queue.owner.isDiscoveryDue()
        XCTAssertTrue(due)
        XCTAssertEqual(queue.listener.losses, 0, "a missing route is not an authorization answer")
        XCTAssertEqual(queue.listener.notifications.map(\.status), [RealtimeStatus.unsupported])
        XCTAssertEqual(try queue.device.client.pending().count, 1)
    }

    func testAnExhaustedSessionIsRetiredWithoutRediscoveringTheCapability() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        _ = try queue.enqueue("[TEST ONLY] израсходована")
        // 2048 consumed nonces (`server/src/self_service_http.rs:489`): the
        // session is spent, the server is not.
        queue.routes.messages = { _ in
            throw Rejected(status: 429, code: SessionCall.sessionExhausted)
        }

        await queue.lane.run(under: run, cycles: 1)

        XCTAssertEqual(queue.posts.count, 1)
        let held = await queue.owner.session
        XCTAssertNil(held)
        let due = await queue.owner.isDiscoveryDue()
        XCTAssertFalse(due, "the routes are where they were; only this session is gone")
        XCTAssertEqual(queue.listener.losses, 0)
        XCTAssertEqual(queue.listener.notifications.map(\.status), [RealtimeStatus.busy])
    }

    // MARK: - the five-second window on the session route

    func testACapacityRejectionOnTheSessionRouteSendsThroughTheChallengeTransport() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        _ = try queue.enqueue("[TEST ONLY] очередь")
        // "At most 64 live sessions globally and two per account; reject with
        // 429 at capacity" (`docs/protocol/realtime-v1.md:35`).
        queue.routes.session = { _ in throw Rejected(status: 429, code: "session_capacity") }

        let outcome = try await queue.lane.cycle(under: run)

        XCTAssertEqual(outcome, .sent(accepted: 1))
        XCTAssertEqual(ProofFlow.legacyWindow, 5 * second)
        let held = await queue.owner.session
        XCTAssertNil(held)
        // The envelope went out over the retained challenge transport of
        // self-service v2: a challenge, then the authorized POST
        // (`RealtimeLoop.java:192,226`).
        let post = try XCTUnwrap(queue.posts.last)
        XCTAssertTrue(post.authorization?.hasPrefix("ParanoidV2 ") == true)
        XCTAssertEqual(queue.transport.calls.dropLast().last?.path, ChallengeIntent.authChallengePath)
        XCTAssertEqual(queue.sessionRequests, 1)

        // Inside the window the route is left alone entirely.
        queue.source.advance(4 * second)
        _ = try queue.enqueue("[TEST ONLY] ещё")
        _ = try await queue.lane.cycle(under: run)
        XCTAssertEqual(queue.sessionRequests, 1)

        // Once it has elapsed the client asks again, and this time it is given
        // a session.
        queue.source.advance(2 * second)
        queue.routes.session = nil
        _ = try queue.enqueue("[TEST ONLY] третье")
        _ = try await queue.lane.cycle(under: run)
        XCTAssertEqual(queue.sessionRequests, 2)
        let reopened = await queue.owner.session
        XCTAssertNotNil(reopened)
        XCTAssertTrue(try queue.device.client.pending().isEmpty)
    }

    // MARK: - a pause is not a reset, and renewal is at 240 seconds

    func testThreePausesInsideTheWindowAskForOneSessionAndRenewalIsAtExactlyTwoHundredFortySeconds() async throws {
        let queue = try Queue()
        var run = await queue.loop.start()
        _ = try queue.enqueue("[TEST ONLY] первое")
        _ = try await queue.lane.cycle(under: run)
        XCTAssertEqual(queue.sessionRequests, 1)
        let opened = await queue.owner.session

        // Three pauses and resumes inside the session's life. The account has
        // two live-session slots (`server/src/self_service_http.rs:377-391`)
        // and renewal needs the second, so a pause must not spend one.
        for step in [80, 80, 79] {
            await queue.loop.stop()
            queue.source.advance(UInt64(step) * second)
            run = await queue.loop.start()
            _ = try queue.enqueue("[TEST ONLY] пауза \(step)")
            _ = try await queue.lane.cycle(under: run)
        }
        XCTAssertEqual(queue.sessionRequests, 1, "239 seconds is still the same session")
        let reused = await queue.owner.session
        XCTAssertEqual(reused?.id, opened?.id)

        // At 240 seconds of monotonic age it is renewed, and only then
        // (`docs/protocol/realtime-v1.md:179-181`).
        queue.source.advance(second)
        _ = try queue.enqueue("[TEST ONLY] обновление")
        _ = try await queue.lane.cycle(under: run)
        XCTAssertEqual(queue.sessionRequests, 2)
        let renewed = await queue.owner.session
        XCTAssertNotEqual(renewed?.id, opened?.id)

        // And the renewed one carries the rest of the five-minute window on
        // its own clock.
        queue.source.advance(60 * second)
        _ = try queue.enqueue("[TEST ONLY] после")
        _ = try await queue.lane.cycle(under: run)
        XCTAssertEqual(queue.sessionRequests, 2, "300 seconds, two sessions")
        XCTAssertTrue(try queue.device.client.pending().isEmpty)
        XCTAssertEqual(queue.listener.problems, [])
    }

    // MARK: - what one envelope's rejection does to the rest of the batch

    func testAConflictOrAFullMailboxDefersThatEnvelopeAndTheBatchStillFinishes() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        let ids = try (1...3).map { try queue.enqueue("[TEST ONLY] пачка \($0)") }
        queue.routes.messages = { call in
            guard let id = Queue.identifier(in: call.body) else { return nil }
            // "409 binding/idempotency conflict … 507 message quota"
            // (`docs/protocol/self-service-v2.md:80-81`).
            if id == ids[0] { throw Rejected(status: 409, code: "binding_conflict") }
            if id == ids[2] { throw Rejected(status: 507, code: "quota_exceeded") }
            return nil
        }

        await assertThrows({ try await queue.lane.cycle(under: run) }, { failure in
            // The last deferred rejection is what the pass ends with
            // (`RealtimeLoop.java:222,228,230`).
            XCTAssertEqual((failure as? Rejected)?.status, 507)
        })

        // All three were offered, in order, and the two the server refused are
        // still queued.
        XCTAssertEqual(queue.posts.compactMap { Queue.identifier(in: $0.body) }, ids)
        XCTAssertEqual(try queue.device.client.pending().compactMap { $0["id"] as? String },
                       [ids[0], ids[2]])
        XCTAssertEqual(queue.listener.notifications.map(\.connected), [true])
        XCTAssertEqual(queue.listener.notifications.map(\.marks), [1])
        XCTAssertEqual(queue.listener.losses, 0)
    }

    func testAnAcceptanceThatDoesNotNameTheEnvelopeIsRefusedAndNothingIsCommitted() async throws {
        // `{id, sequence}` with the identifier this device sent and a sequence
        // of at least one, or the answer is about nothing this device can mark
        // (`SelfServiceClient.java:205-210`,
        // `docs/protocol/self-service-v2.md:56-58`).
        let broken: [(String, (FakeTransport.Call) -> [String: Any])] = [
            ("another envelope", { _ in ["id": UUID().uuidString.lowercased(), "sequence": 1] }),
            ("no identifier", { _ in ["sequence": 1] }),
            ("sequence zero", { call in ["id": Queue.identifier(in: call.body) ?? "", "sequence": 0] }),
            ("no sequence", { call in ["id": Queue.identifier(in: call.body) ?? ""] }),
        ]
        for (name, answer) in broken {
            let queue = try Queue()
            let run = await queue.owner.start()
            _ = try queue.enqueue("[TEST ONLY] чужая расписка")
            queue.routes.messages = { call in answer(call) }
            let commits = queue.device.commits

            await assertThrows({ try await queue.lane.cycle(under: run) }, { failure in
                XCTAssertEqual(failure as? SelfServiceError, .invalidAcceptance, name)
            })

            XCTAssertEqual(try queue.device.client.pending().count, 1, name)
            XCTAssertTrue(queue.listener.notifications.isEmpty, name)
            XCTAssertEqual(queue.device.commits, commits, "nothing was written (\(name))")
        }
    }

    // MARK: - the wake seam

    func testAnIdleLaneWaitsForAWakeAndAFailedPassAsksForAnother() async throws {
        let queue = try Queue()
        // `start()` arms the signal, exactly as Android's `start()` ends with
        // `kick()` (`RealtimeLoop.java:53`).
        let run = await queue.loop.start()
        XCTAssertTrue(queue.signal.take())
        queue.signal.wake()
        queue.signal.wake()
        XCTAssertTrue(queue.signal.take(), "one permit, however many wakes")
        XCTAssertFalse(queue.signal.take())

        // With an empty outbox and no wake, the lane does nothing but wait.
        queue.loop.wake()
        await queue.lane.run(under: run, cycles: 3)
        XCTAssertEqual(queue.lanePacer.waits, [SendLane.wakePoll, SendLane.wakePoll])
        XCTAssertEqual(queue.posts.count, 0)

        // A failed pass re-arms the signal itself, so the queue that failed is
        // tried again after the backoff (`RealtimeLoop.java:238`).
        _ = try queue.enqueue("[TEST ONLY] снова")
        queue.routes.messages = { _ in throw Rejected(status: 503) }
        queue.lanePacer.reset()
        queue.loop.wake()
        await queue.lane.run(under: run, cycles: 2)
        XCTAssertEqual(queue.posts.count, 2, "two passes, because the first one re-armed")
        let waits = queue.lanePacer.waits
        XCTAssertEqual(waits.count, 2)
        XCTAssertGreaterThanOrEqual(waits[0], Backoff.first)
        XCTAssertLessThan(waits[0], Backoff.first + Backoff.jitter)
        XCTAssertGreaterThanOrEqual(waits[1], 2 * Backoff.first)
        XCTAssertLessThan(waits[1], 2 * Backoff.first + Backoff.jitter)
        XCTAssertEqual(queue.listener.notifications.map(\.status),
                       [RealtimeStatus.offline, RealtimeStatus.offline])
        XCTAssertEqual(queue.listener.losses, 0)
    }

    func testADeviceWithoutAnIdentityDialsNothingAndDoesNotPause() async throws {
        let queue = try Queue(registered: false)
        let run = await queue.owner.start()

        let outcome = try await queue.lane.cycle(under: run)

        XCTAssertEqual(outcome, .idle)
        XCTAssertTrue(queue.transport.calls.isEmpty, "local identity creation is the user's")
        // Unlike the receive lane, the send lane does not pause for an idle
        // device: it goes back to waiting for a wake
        // (`RealtimeLoop.java:232`).
        XCTAssertEqual(queue.lanePacer.waits, [])
        XCTAssertTrue(queue.listener.notifications.isEmpty)
    }

    // MARK: - a failed commit

    func testAFailedCommitStopsTheLaneAndSaysSoOnce() async throws {
        let queue = try Queue()
        let run = await queue.owner.start()
        _ = try queue.enqueue("[TEST ONLY] хранилище")
        queue.device.fileSystem.failure = { [store = queue.device.store] call in
            guard case .rename = call else { return nil }
            return FileSystemError(.rename, store.fileURL, errno: EIO)
        }

        await queue.lane.run(under: run, cycles: 3)

        // "A failed or ambiguous save freezes the process and transmits
        // nothing from that candidate"
        // (`docs/protocol/first-contact-v1.md:173-178`, `RealtimeLoop.java:74`).
        let frozen = await queue.owner.isFrozen
        XCTAssertTrue(frozen)
        let current = await queue.owner.current
        XCTAssertNil(current, "a client that cannot persist stops talking to the server")
        XCTAssertEqual(queue.listener.notifications.map(\.connected), [false])
        XCTAssertEqual(queue.listener.notifications.last?.status, RealtimeStatus.storage)
        XCTAssertEqual(queue.listener.losses, 1)
    }

    // MARK: - the texts

    func testTheStatusTextsAreTheLaneTextsOfAndroidPlusTheNotFoundOfTheUserPath() {
        // `RealtimeLoop.errorMessage` (`:286-294`).
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 507)), RealtimeStatus.serverFull)
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 401)), RealtimeStatus.unconfirmed)
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 409)), RealtimeStatus.unconfirmed)
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 429)), RealtimeStatus.busy)
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 503)), RealtimeStatus.offline)
        XCTAssertEqual(RealtimeStatus.message(for: TransportError.invalidReply), RealtimeStatus.offline)
        XCTAssertEqual(RealtimeStatus.message(for: SessionFailure.foreignRealm), RealtimeStatus.offline)
        // `TextEngine.userError` (`TextEngine.java:199`): Android's lanes call
        // a 404 "нет подключения", the user path calls it what it is.
        XCTAssertEqual(RealtimeStatus.message(for: Rejected(status: 404)), RealtimeStatus.unsupported)
        XCTAssertEqual(RealtimeStatus.serverFull,
                       "Хранилище сервера заполнено. Сообщения сохранены в очереди.")
        XCTAssertEqual(RealtimeStatus.unconfirmed,
                       "Не удалось подтвердить подключение. ID и сообщения сохранены.")
        XCTAssertEqual(RealtimeStatus.busy, "Сервер занят. Повторяем подключение.")
        XCTAssertEqual(RealtimeStatus.offline, "Нет подключения. Сообщения сохранены в очереди.")
        XCTAssertEqual(RealtimeStatus.unsupported,
                       "Сервер пока не поддерживает эту версию. Ваш ID, контакты и очередь сохранены.")
        XCTAssertEqual(RealtimeStatus.connected, "Подключено")
        XCTAssertEqual(RealtimeStatus.storage,
                       "Ошибка хранения. Данные сохранены; подключение остановлено.")
        XCTAssertEqual(SendLane.deferredStatuses, [409, 507])
        XCTAssertEqual(SendLane.messagesPath, "/v2/messages")
        XCTAssertEqual(SendLane.sendOperation, "send")
        XCTAssertEqual(SendLane.wakePoll, MonotonicClock.nanosecondsPerSecond)
    }

    // MARK: - fixtures

    /// A registered device with a paired peer, the owner over it, the loop and
    /// the stand they talk to.
    ///
    /// `@unchecked Sendable` for the reason `Device` is: the fixture keeps the
    /// client so the test can enqueue and read the outbox, which a lane may not
    /// do. The application hands the client to the owner in the expression that
    /// builds it and keeps nothing.
    final class Queue: @unchecked Sendable {
        let device: Device
        let server: StandServer
        let transport: FakeTransport
        let source: FakeMonotonicSource
        let flowPacer: RecordingPacer
        let lanePacer: RecordingPacer
        let routes: Routes
        let listener: RecordingSends
        let signal: WakeSignal
        let owner: StateOwner
        let flow: ProofFlow
        let loop: RealtimeLoop
        /// The peer every test message is addressed to.
        let peer: String

        var lane: SendLane { loop.send }

        init(registered: Bool = true) throws {
            let source = FakeMonotonicSource()
            let flowPacer = RecordingPacer()
            let lanePacer = RecordingPacer()
            let routes = Routes()
            let sequences = Sequences()
            self.source = source
            self.flowPacer = flowPacer
            self.lanePacer = lanePacer
            self.routes = routes

            if registered {
                // Two registered devices that verified each other out of band,
                // which is the only way a message can be enqueued at all.
                let both = try SelfServiceClientTests.pairedDevices()
                device = both.0
                peer = try both.1.account()
            } else {
                device = try Device(name: "bare", trust: RealtimeLoopTests.stand)
                peer = ""
            }

            let server = try StandServer(credential: (try? device.client.credential()) ?? [:])
            self.server = server
            let transport = FakeTransport(server: server)
            self.transport = transport
            let signal = WakeSignal()
            self.signal = signal
            let owner = StateOwner(client: device.client, clock: source.clock, hook: signal)
            self.owner = owner
            let flow = ProofFlow(owner: owner, transport: transport,
                                 clock: source.clock, pacer: flowPacer)
            self.flow = flow
            let listener = RecordingSends(device: device)
            self.listener = listener
            loop = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                                listener: listener, signal: signal, pacer: lanePacer)

            // The message route is the test's; the session route is the
            // test's only while it wants to refuse one. Everything else is the
            // stand's own answer.
            transport.answer = { call in
                if call.path == ChallengeIntent.sessionPath, let session = routes.session {
                    return try session(call)
                }
                guard call.method == "POST", call.path == SendLane.messagesPath else { return nil }
                if let reply = try routes.messages?(call) { return reply }
                return try Queue.acceptance(of: call, sequence: sequences.next())
            }
        }

        /// One more message in the outbox; the identifier the core gave it.
        @discardableResult
        func enqueue(_ text: String) throws -> String {
            let before = Set(try device.client.pending().compactMap { $0["id"] as? String })
            try device.client.send(account: peer, text: text)
            let after = try device.client.pending().compactMap { $0["id"] as? String }
            guard let id = after.first(where: { !before.contains($0) }) else {
                throw SelfServiceClientTests.FixtureError.missing("outbox identifier")
            }
            return id
        }

        /// Every envelope this lane posted, in order.
        var posts: [FakeTransport.Call] {
            transport.calls.filter { $0.method == "POST" && $0.path == SendLane.messagesPath }
        }

        /// How many times the session route was asked for a session.
        var sessionRequests: Int {
            transport.calls.filter { $0.path == ChallengeIntent.sessionPath }.count
        }

        /// What the server answers one accepted envelope with
        /// (`server/src/self_service_messages.rs:55,98`).
        static func acceptance(of call: FakeTransport.Call, sequence: Int64) throws -> [String: Any] {
            guard let id = identifier(in: call.body) else {
                throw SelfServiceClientTests.FixtureError.missing("id")
            }
            return ["id": id, "sequence": sequence]
        }

        /// The `id` member of one envelope body.
        static func identifier(in body: String) -> String? {
            let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            return object?["id"] as? String
        }
    }

    /// What the stand answers the next request on one of the two routes the
    /// tests take over, if anything.
    final class Routes: @unchecked Sendable {
        var messages: ((FakeTransport.Call) throws -> [String: Any]?)?
        var session: ((FakeTransport.Call) throws -> [String: Any]?)?
    }

    /// The server's message sequence.
    final class Sequences: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0

        func next() -> Int64 {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    /// The listener of `clients/android/test/RealtimeBridge.java:33-52`, for
    /// the outgoing half: every notification is checked against the encrypted
    /// snapshot on the device before it is recorded.
    ///
    /// It runs on the state owner — the lane invokes it inside
    /// `StateOwner.perform` — so reading the client and reopening the store is
    /// exactly what the Java fixture does on its own owner thread.
    final class RecordingSends: RealtimeListener, @unchecked Sendable {
        struct Notification {
            let connected: Bool
            let status: String
            /// Envelopes still queued when this was published.
            let queued: Int
            /// Envelopes the committed snapshot still held at that moment.
            let durableQueue: Int
            /// Delivery marks the public view carried.
            let marks: Int
            /// Delivery marks the committed snapshot held.
            let durableMarks: Int
        }

        private let device: Device
        private let lock = NSLock()
        private var recorded: [Notification] = []
        private var failures: [String] = []
        private var lost = 0

        init(device: Device) {
            self.device = device
        }

        var notifications: [Notification] { lock.withLock { recorded } }
        /// Every notification that published something the device did not hold.
        var problems: [String] { lock.withLock { failures } }
        var losses: Int { lock.withLock { lost } }

        func changed(connected: Bool, status: String) {
            var queued = 0
            var durableQueue = 0
            var marks = 0
            var durableMarks = 0
            // A frozen client refuses to say anything about itself, which is
            // the state the storage notice is published in
            // (`RealtimeBridge.java:35`).
            if !device.client.isBroken {
                do {
                    queued = try device.client.pending().count
                    marks = Self.marks(inDialogs: try device.client.publicView()["dialogs"]
                        as? [[String: Any]] ?? [])
                    let durable = try Self.durable(of: device)
                    durableQueue = durable.queued
                    durableMarks = durable.marks
                    if queued != durableQueue || marks != durableMarks {
                        lock.withLock {
                            failures.append("published \(queued)/\(marks) with \(durableQueue)/\(durableMarks) durable")
                        }
                    }
                } catch {
                    lock.withLock { failures.append("\(error)") }
                }
            }
            lock.withLock {
                recorded.append(Notification(connected: connected, status: status,
                                             queued: queued, durableQueue: durableQueue,
                                             marks: marks, durableMarks: durableMarks))
            }
        }

        func authorizationLost() {
            lock.withLock { lost += 1 }
        }

        /// What the sealed file on the device says, decrypted and read through
        /// the core (`RealtimeBridge.java:37-40`).
        private static func durable(of device: Device) throws -> (queued: Int, marks: Int) {
            guard let stored = try device.stored(),
                  let state = JsonSpan.value(of: "state", in: stored) else { return (0, 0) }
            let view = try CoreBridge.command(state: state, request: #"{"op":"view"}"#)
            return ((view.object["outbox"] as? [[String: Any]])?.count ?? 0,
                    marks(inDialogs: view.object["dialogs"] as? [[String: Any]] ?? []))
        }

        /// One check per message the server has accepted
        /// (`docs/protocol/first-contact-v1.md:122-127`).
        private static func marks(inDialogs dialogs: [[String: Any]]) -> Int {
            dialogs.reduce(0) { total, dialog in
                total + ((dialog["messages"] as? [[String: Any]])?
                    .filter { ($0["accepted"] as? Bool) == true }.count ?? 0)
            }
        }
    }
}
