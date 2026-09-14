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
        // two live-session slots (`server/src/self_service_http.rs:398-409`)
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

    func testAWakeResumesAWaitingLaneAndTheBoundEndsTheWaitWithoutAPermit() async throws {
        // The seam an idle lane waits on: `outbound.tryAcquire(1, SECONDS)`
        // returns the instant `kick()` releases a permit
        // (`RealtimeLoop.java:219,54`), so the message a user has just written
        // leaves the device now and not at the end of an interval. Every wait
        // below would hang for ever if a wake could be missed, which is what
        // the ticket is for: it is taken before the caller suspends.
        let signal = WakeSignal()
        let early = signal.enroll()
        signal.wake()
        await signal.wait(ticket: early)
        XCTAssertTrue(signal.take(), "a wake before the wait is still a permit")

        let ticket = signal.enroll()
        let waiting = Task { await signal.wait(ticket: ticket) }
        signal.wake()
        await waiting.value
        XCTAssertTrue(signal.take())

        // The bound of the wait, and a lane that stopped, end a wait that no
        // permit arrived for — and arm nothing.
        let bounded = signal.enroll()
        let elapsing = Task { await signal.wait(ticket: bounded) }
        signal.endWait()
        await elapsing.value
        XCTAssertFalse(signal.take(), "ending a wait is not a permit")
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

    // MARK: - a network that changed under a running loop

    func testARestartKeepsTheQueuedOutboxAndTheSessionAndOnlyMovesTheGeneration() async throws {
        let queue = try Queue()
        let first = await queue.owner.start()
        let ids = try (1...3).map { try queue.enqueue("[TEST ONLY] сообщение \($0)") }
        guard case .session(let opened) = try await queue.flow.connect(under: first) else {
            return XCTFail("the stand offers the realtime capability")
        }

        await queue.loop.restart()

        // Only the run changed (`RealtimeLoop.java:61-62`): the lanes were
        // never disabled, so nothing has to start them again.
        let current = await queue.owner.current
        let next = try XCTUnwrap(current)
        XCTAssertEqual(next.run, first.run + 1)
        let stale = await queue.owner.isCurrent(first)
        XCTAssertFalse(stale)

        // The outbox is the core's and a restart never reaches the core: the
        // three envelopes are still queued, in the order they were written in,
        // and not one of them was sent twice or lost.
        XCTAssertEqual(try queue.device.client.pending().compactMap { $0["id"] as? String }, ids)
        XCTAssertEqual(queue.posts.count, 0)

        // The session is the owner's and outlives any number of generations
        // (`docs/protocol/realtime-v1.md:179-181`). The account has two live
        // slots (`server/src/self_service_http.rs:398-409`) and a change of
        // network must not spend one: it is reused, not reopened.
        let held = await queue.owner.session
        XCTAssertEqual(held?.id, opened.id)
        guard case .session(let reused) = try await queue.flow.connect(under: next) else {
            return XCTFail("the session was reused")
        }
        XCTAssertEqual(reused.id, opened.id)
        XCTAssertEqual(queue.server.issuedSessions, 1)

        // And the queue goes out under the new generation, in that same order.
        let outcome = try await queue.lane.cycle(under: next)
        XCTAssertEqual(outcome, .sent(accepted: 3))
        XCTAssertEqual(queue.posts.compactMap { Queue.identifier(in: $0.body) }, ids)
        XCTAssertEqual(try queue.device.client.pending().count, 0)
    }

    func testARestartFreesALaneParkedOnADeadPollAndTheLanesRunAgainUnderTheNewGeneration() async throws {
        let stalled = try Stalled()
        // Every long poll is held open and never answered, which is what
        // `GET /v2/events?…` over an interface that has gone looks like from
        // here: no bytes, no failure and nothing to report until the request's
        // own 30-second bound and the backoff after it
        // (`RealtimeTransport.eventsReadTimeout`).
        stalled.transport.parks = { $0.method == "GET" && $0.path.hasPrefix("/v2/events?") }
        let first = await stalled.loop.start()
        let returned = Done()
        let lanes = Task {
            await stalled.loop.run()
            returned.signal()
        }

        let parked = await stalled.transport.waitForParked(1)
        XCTAssertTrue(parked, "the receive lane is waiting on the long poll")
        // The immediate read of a new generation came back first and was
        // delivered, so the application has been told it is online; the poll
        // the lane is parked on now is the one the network change strands.
        XCTAssertEqual(stalled.pagePaths, ["/v2/messages?after=0&limit=20",
                                           "/v2/events?after=0&limit=20"])
        XCTAssertEqual(stalled.listener.notifications.map(\.connected), [true])

        await stalled.loop.restart()

        // The lane leaves at its next guard instead of at the timeout, so the
        // task `run()` was launched in returns — which is what makes a
        // relaunch both necessary and possible.
        let left = await returned.wait()
        if !left {
            // A lane that did not leave would park again for ever and hang the
            // suite instead of reporting. Take it down by hand so that the
            // assertion below is what ends this test.
            await stalled.loop.stop()
            stalled.loop.wake()
            stalled.transport.parks = nil
            await stalled.transport.cancelActive()
        }
        XCTAssertTrue(left, "the parked poll was abandoned, and run() returned with it")
        await lanes.value
        let cancelled = await stalled.transport.waitForCancellations(1)
        XCTAssertTrue(cancelled, "cancelActive() freed the parked request")
        XCTAssertEqual(stalled.transport.cancellations, 1, "once for one restart, and no more")
        let current = await stalled.owner.current
        let next = try XCTUnwrap(current)
        XCTAssertEqual(next.run, first.run + 1)
        let stale = await stalled.owner.isCurrent(first)
        XCTAssertFalse(stale)
        XCTAssertEqual(stalled.listener.losses, 0, "a restart is not an authorization failure")

        // What `LifecycleRunner` does on `.networkChanged`, by hand: the lanes
        // stayed enabled, so all they need is a task again.
        let resumed = Task { await stalled.loop.run() }

        let again = await stalled.transport.waitForParked(2)
        XCTAssertTrue(again)
        // The first cycle of the new generation is the immediate read and not
        // the long poll (`RealtimeLoop.java:254`). That page is the one that
        // was 25 seconds late in the owner's report of 2026-09-13, and the
        // online flag is published with it.
        XCTAssertEqual(Array(stalled.pagePaths.suffix(2)), ["/v2/messages?after=0&limit=20",
                                                            "/v2/events?after=0&limit=20"])
        XCTAssertEqual(stalled.listener.notifications.map(\.connected), [true, true])
        XCTAssertEqual(stalled.listener.problems, [], "nothing was published that the device did not hold")

        // Nothing is left suspended on a request that is not coming back.
        await stalled.loop.stop()
        stalled.loop.wake()
        await stalled.transport.cancelActive()
        await resumed.value
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

    /// A registered device whose long polls can be held open, and the whole
    /// loop over it.
    ///
    /// It is `Queue` with the two differences the check above is about: the
    /// page routes are answered the way the stand answers an empty inbox
    /// (`server/src/self_service_messages.rs:26`, `ReceiveLaneTests.Inbox`),
    /// and the transport in front of them can park a request. The lanes run in
    /// their own task here rather than a fixed number of cycles, so the pacer
    /// is the real one: a recording pacer returns at once, which would spin the
    /// send lane's wait instead of waiting it out.
    ///
    /// `@unchecked Sendable` for the reason `Device` is: the fixture keeps the
    /// client so the test can read the state, which a lane may not do.
    final class Stalled: @unchecked Sendable {
        let device: Device
        let server: StandServer
        let transport: ParkingTransport
        let source: FakeMonotonicSource
        let signal: WakeSignal
        let listener: RecordingSends
        let owner: StateOwner
        let flow: ProofFlow
        let loop: RealtimeLoop

        init() throws {
            let device = try Device(name: "stalled", trust: RealtimeLoopTests.stand)
            try device.client.createIdentity()
            self.device = device
            let server = try StandServer(credential: (try? device.client.credential()) ?? [:])
            self.server = server
            let inner = FakeTransport(server: server)
            // The two page routes are answered here; everything else is the
            // stand's own answer.
            inner.answer = { call in
                guard call.method == "GET", Stalled.isPage(call.path) else { return nil }
                return ["messages": [], "cursor": 0]
            }
            let transport = ParkingTransport(inner: inner)
            self.transport = transport
            let source = FakeMonotonicSource()
            self.source = source
            let signal = WakeSignal()
            self.signal = signal
            let owner = StateOwner(client: device.client, clock: source.clock, hook: signal)
            self.owner = owner
            let flow = ProofFlow(owner: owner, transport: transport,
                                 clock: source.clock, pacer: RecordingPacer())
            self.flow = flow
            let listener = RecordingSends(device: device)
            self.listener = listener
            loop = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                                listener: listener, signal: signal)
        }

        /// Whether one path is a page request.
        static func isPage(_ path: String) -> Bool {
            path.hasPrefix("/v2/messages?") || path.hasPrefix("/v2/events?")
        }

        /// Every page the receive lane asked for, in order, parked or not.
        var pagePaths: [String] {
            transport.calls.filter { $0.method == "GET" && Stalled.isPage($0.path) }.map(\.path)
        }
    }

    /// A flag one task raises and another waits for, so that a check about a
    /// task that should end does not hang the suite when it does not.
    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool { lock.withLock { raised } }

        func signal() {
            lock.withLock { raised = true }
        }

        /// Waits for the flag, for at most a second.
        func wait() async -> Bool {
            for _ in 0..<200 {
                if isRaised { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return isRaised
        }
    }

    /// A transport that can hold a request open the way a long poll over an
    /// interface that has gone does: no bytes, no failure, nothing at all
    /// until something cancels it.
    ///
    /// Whatever it does not park is the inner transport's own answer, so the
    /// stand's routes are untouched. `cancelActive()` is the seam
    /// `RealtimeLoop.restart()` reaches for (`RealtimeTransport.java:66-71`):
    /// every held request fails the way a cancelled `URLSessionTask` does, and
    /// nothing else about the transport changes — no pin, no session, no
    /// configuration.
    ///
    /// `@unchecked Sendable` like every fake in this target: it is reached from
    /// both lanes' tasks, and everything it records is kept under a lock.
    final class ParkingTransport: ProofTransport, @unchecked Sendable {
        /// Which calls are held instead of answered.
        var parks: (@Sendable (FakeTransport.Call) -> Bool)?

        private let inner: FakeTransport
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<RealtimeTransport.Reply, any Error>] = []
        private var recorded: [FakeTransport.Call] = []
        private var held = 0
        private var freed = 0

        init(inner: FakeTransport) {
            self.inner = inner
        }

        /// Every call this transport was asked to make, parked or not.
        var calls: [FakeTransport.Call] { lock.withLock { recorded } }
        /// How many calls have been parked since the beginning.
        var parked: Int { lock.withLock { held } }
        /// How many times `cancelActive()` has been called.
        var cancellations: Int { lock.withLock { freed } }

        func call(method: String, path: String, body: String,
                  authorization: String?) async throws -> RealtimeTransport.Reply {
            let call = FakeTransport.Call(method: method, path: path, body: body,
                                          authorization: authorization)
            lock.withLock { recorded.append(call) }
            guard parks?(call) == true else {
                return try await inner.call(method: method, path: path, body: body,
                                            authorization: authorization)
            }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting.append(continuation)
                    held += 1
                }
            }
        }

        func cancelActive() async {
            let abandoned: [CheckedContinuation<RealtimeTransport.Reply, any Error>] = lock.withLock {
                freed += 1
                let parked = waiting
                waiting.removeAll()
                return parked
            }
            // What the URL loading system answers a cancelled task with, and
            // therefore what the lane sees: one failed cycle, which its next
            // guard refuses because the generation has moved.
            for continuation in abandoned { continuation.resume(throwing: URLError(.cancelled)) }
        }

        /// Waits until `count` calls have been parked, for at most a second.
        func waitForParked(_ count: Int) async -> Bool {
            await wait { self.parked >= count }
        }

        /// Waits until `cancelActive()` has been called `count` times.
        func waitForCancellations(_ count: Int) async -> Bool {
            await wait { self.cancellations >= count }
        }

        private func wait(_ reached: () -> Bool) async -> Bool {
            for _ in 0..<200 {
                if reached() { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return reached()
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
