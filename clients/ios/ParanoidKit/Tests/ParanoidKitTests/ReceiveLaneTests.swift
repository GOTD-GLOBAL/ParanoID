import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the receive lane: which page it asks for, what it
/// refuses, and the one ordering the whole client exists for — a page reaches
/// the application only after every event in it is durable, one by one
/// (`docs/protocol/realtime-v1.md:97-99`,
/// `docs/protocol/first-contact-v1.md:165`).
///
/// The core is the real one (the macOS slice of `ParanoidCore.xcframework`)
/// over the in-memory device of `SelfServiceClientTests`; the server is
/// `StandServer` with the page routes answered by the test, and the clock and
/// the pacers are fakes. Nothing here opens a connection, and no account is
/// created on any server.
final class ReceiveLaneTests: XCTestCase {
    /// The local stand of a simulator run. Nothing in these tests may reach
    /// the hosted alpha.
    static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                         pin: String(repeating: "ab", count: 32))

    // MARK: - messages first, then events

    func testTheFirstPageOfAGenerationIsMessagesAndEveryLaterOneIsEvents() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        let first = try inbox.outgoing("[TEST ONLY] первое")
        inbox.pages.next = { _ in Inbox.page([first], cursor: 1) }

        let one = try await inbox.lane.cycle(under: run)

        // "A resumed empty inbox must confirm actual authenticated readiness
        // before waiting through a full long-poll timeout"
        // (`RealtimeLoop.java:252-254`): the first cycle reads, it does not
        // wait.
        XCTAssertEqual(one, .delivered(events: 1, polling: false))
        XCTAssertEqual(inbox.pagePaths, ["/v2/messages?after=0&limit=20"])

        // Every later cycle of the same run is the long poll, and the cursor
        // in the path is the one the core itself signed.
        inbox.pages.next = nil
        let two = try await inbox.lane.cycle(under: run)
        XCTAssertEqual(two, .delivered(events: 0, polling: false))
        XCTAssertEqual(inbox.pagePaths.last, "/v2/events?after=1&limit=20")

        // A pause and a resume start over with an immediate read: the run the
        // lane observed a page under is no longer the current one
        // (`RealtimeLoop.java:244,254,272`).
        await inbox.owner.stop()
        let resumed = await inbox.owner.start()
        _ = try await inbox.lane.cycle(under: resumed)
        XCTAssertEqual(inbox.pagePaths.last, "/v2/messages?after=1&limit=20")
        // A pause is not a reset: the session was reused, not reopened.
        XCTAssertEqual(inbox.server.issuedSessions, 1)
    }

    // MARK: - persist before publish

    func testTheApplicationHearsAboutAnEventOnlyAfterItIsDurable() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        let first = try inbox.outgoing("[TEST ONLY] один")
        let second = try inbox.outgoing("[TEST ONLY] два")
        inbox.pages.next = { _ in Inbox.page([first, second], cursor: 2) }
        let committed = inbox.receiver.commits

        let outcome = try await inbox.lane.cycle(under: run)

        XCTAssertEqual(outcome, .delivered(events: 2, polling: false))
        // One candidate and one commit per event: they are applied one by one,
        // never as a batch (`RealtimeLoop.java:264-269`).
        XCTAssertEqual(inbox.receiver.commits, committed + 2)
        let notifications = inbox.listener.notifications
        XCTAssertEqual(notifications.count, 3, "one before the page and one after each event")
        XCTAssertEqual(notifications.map(\.connected), [true, true, true])
        XCTAssertEqual(Set(notifications.map(\.status)), [RealtimeStatus.connected])
        // The counter of `clients/android/test/RealtimeBridge.java:33-52`: at
        // every notification, what the public view published and what the
        // sealed snapshot on the device held were the same thing. A UI that
        // has seen an event has an event that survives a power cut.
        XCTAssertEqual(notifications.map(\.durable), [0, 1, 2])
        XCTAssertEqual(notifications.map(\.published), [0, 1, 2])
        XCTAssertEqual(inbox.listener.problems, [])
        XCTAssertEqual(try inbox.receiver.client.receiveCursor(), 2)
    }

    // MARK: - the wait slot

    func testAWaiterBusyRejectionReadsTheInboxInsteadOfQueueingForTheSlot() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        // One page first, so that the next cycle is the long poll.
        _ = try await inbox.lane.cycle(under: run)
        let before = inbox.pagePaths.count
        let message = try inbox.outgoing("[TEST ONLY] занято")
        inbox.pages.next = { call in
            // "At most eight concurrent event waits globally and one per
            // account… Excess receives 429 without an unbounded permit queue"
            // (`docs/protocol/realtime-v1.md:102-103`).
            guard call.path.hasPrefix("/v2/events?") else { return Inbox.page([message], cursor: 1) }
            throw Rejected(status: 429, code: ReceiveLane.waiterBusy)
        }

        let outcome = try await inbox.lane.cycle(under: run)

        XCTAssertEqual(outcome, .delivered(events: 1, polling: true))
        XCTAssertEqual(Array(inbox.pagePaths.dropFirst(before)),
                       ["/v2/events?after=0&limit=20", "/v2/messages?after=0&limit=20"])
        // That cycle polled, and a short page means the inbox is empty: three
        // seconds before the next one (`RealtimeLoop.java:274`).
        XCTAssertEqual(inbox.lanePacer.waits, [ReceiveLane.pollPause])
        // A busy waiter says nothing about this device's authorization, so the
        // session stays exactly as it was.
        let held = await inbox.owner.session
        XCTAssertNotNil(held)
        XCTAssertEqual(inbox.server.issuedSessions, 1)
    }

    // MARK: - the page limit

    func testAPageOfMoreThanTwentyEventsIsRefusedBeforeAnythingIsWritten() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        // "Java sync pages at most 20 events"
        // (`docs/protocol/first-contact-v1.md:165`): the client asked for
        // twenty, so twenty-one is a server this client stops talking to for
        // this cycle. The entries never reach the core, so their content does
        // not matter.
        let events: [[String: Any]] = (1...21).map { sequence in
            ["id": UUID().uuidString.lowercased(), "ciphertext": "AAAA",
             "sender": "someone", "sequence": sequence]
        }
        inbox.pages.next = { _ in Inbox.page(events, cursor: 21) }
        let committed = inbox.receiver.commits

        await assertThrows({ try await inbox.lane.cycle(under: run) }, {
            XCTAssertEqual($0 as? ReceiveFailure, .pageLimit(21))
        })

        XCTAssertEqual(inbox.receiver.commits, committed)
        XCTAssertTrue(inbox.listener.notifications.isEmpty,
                      "a refused page is never announced, not even as a connection")
        XCTAssertEqual(try inbox.receiver.client.receiveCursor(), 0)
        XCTAssertEqual(ReceiveLane.pageLimit, 20)
    }

    // MARK: - the cursor is rechecked on the owner

    func testAPageThatArrivedAfterTheCursorMovedIsDroppedWholeAndRetried() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        let first = try inbox.outgoing("[TEST ONLY] первое")
        let second = try inbox.outgoing("[TEST ONLY] второе")
        inbox.pages.next = { _ in Inbox.page([second], cursor: 2) }
        // The cursor moves while the page is in flight, exactly as it would if
        // another cycle applied the same inbox first (`RealtimeLoop.java:260`).
        let drift = Box()
        inbox.transport.onCall = { call in
            guard Inbox.isPage(call.path) else { return }
            do { try inbox.receiver.client.received(message: first) } catch { drift.error = error }
        }
        let committed = inbox.receiver.commits

        await assertThrows({ try await inbox.lane.cycle(under: run) }, {
            XCTAssertEqual($0 as? ReceiveFailure, .stalePage)
        })

        XCTAssertNil(drift.error)
        // The one commit is the drift the test itself caused; the page was
        // dropped whole and nothing about it was published.
        XCTAssertEqual(inbox.receiver.commits, committed + 1)
        XCTAssertTrue(inbox.listener.notifications.isEmpty)

        // The retry starts from the cursor the device actually has, and it is
        // an immediate read again: no page was delivered under this run yet.
        inbox.transport.onCall = nil
        let outcome = try await inbox.lane.cycle(under: run)
        XCTAssertEqual(outcome, .delivered(events: 1, polling: false))
        XCTAssertEqual(inbox.pagePaths.last, "/v2/messages?after=1&limit=20")
        XCTAssertEqual(try inbox.receiver.client.receiveCursor(), 2)
        XCTAssertEqual(inbox.listener.problems, [])
    }

    // MARK: - no session at all

    func testWithoutASessionThePageIsFetchedThroughTheChallengeTransport() async throws {
        let inbox = try Inbox()
        // An older v2 server: no session route, so the retained challenge
        // transport carries the page (`docs/protocol/realtime-v1.md:177`).
        inbox.server.realtimeCapability = nil
        let run = await inbox.owner.start()
        let message = try inbox.outgoing("[TEST ONLY] без сессии")
        inbox.pages.next = { _ in Inbox.page([message], cursor: 1) }

        let outcome = try await inbox.lane.cycle(under: run)

        XCTAssertEqual(outcome, .delivered(events: 1, polling: true))
        XCTAssertEqual(inbox.pagePaths, ["/v2/messages?after=0&limit=20"])
        let page = try XCTUnwrap(inbox.transport.calls.last)
        XCTAssertTrue(page.authorized, "the page is authorized by a proof")
        XCTAssertEqual(inbox.transport.calls.dropLast().last?.path, ChallengeIntent.authChallengePath)
        // Every proof cycle polls, so a short page waits three seconds.
        XCTAssertEqual(inbox.lanePacer.waits, [ReceiveLane.pollPause])
        let held = await inbox.owner.session
        XCTAssertNil(held)
    }

    // MARK: - no identity

    func testADeviceWithoutAnIdentityDialsNothingAndWaitsHalfASecond() async throws {
        let inbox = try Inbox(paired: false)
        let run = await inbox.owner.start()

        let outcome = try await inbox.lane.cycle(under: run)

        XCTAssertEqual(outcome, .idle)
        XCTAssertTrue(inbox.transport.calls.isEmpty, "local identity creation is the user's")
        XCTAssertEqual(inbox.lanePacer.waits, [ReceiveLane.idlePause])
        XCTAssertTrue(inbox.listener.notifications.isEmpty)
    }

    // MARK: - the online flag carries no debounce

    func testEveryFailurePublishesOfflineAtOnceAndTheNextPagePublishesOnlineAgain() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        let message = try inbox.outgoing("[TEST ONLY] снова")
        let attempts = Counter()
        inbox.pages.next = { _ in
            guard attempts.next() > 2 else { throw Rejected(status: 503) }
            return Inbox.page([message], cursor: 1)
        }

        await inbox.lane.run(under: run, cycles: 3)

        // Android v15 publishes each transition as it happens
        // (`RealtimeLoop.java:237,261-263,268,280`); nothing here waits for a
        // flag to settle.
        let notifications = inbox.listener.notifications
        XCTAssertEqual(notifications.map(\.connected), [false, false, true, true])
        XCTAssertEqual(notifications[0].status, RealtimeStatus.offline)
        XCTAssertEqual(notifications[1].status, RealtimeStatus.offline)
        XCTAssertEqual(notifications[2].status, RealtimeStatus.connected)
        XCTAssertEqual(notifications.map(\.durable), [0, 0, 0, 1])
        // 0.5 s and then 1 s, and the count resets on the page that got
        // through (`Backoff`, `RealtimeLoop.java:281,285`).
        let waits = inbox.lanePacer.waits
        XCTAssertEqual(waits.count, 2)
        XCTAssertGreaterThanOrEqual(waits[0], Backoff.first)
        XCTAssertLessThan(waits[0], Backoff.first + Backoff.jitter)
        XCTAssertGreaterThanOrEqual(waits[1], 2 * Backoff.first)
        XCTAssertLessThan(waits[1], 2 * Backoff.first + Backoff.jitter)
        XCTAssertEqual(inbox.listener.losses, 0, "a 503 is not an authorization answer")
    }

    // MARK: - a session that stopped being usable

    func testASecondUnauthorizedAnswerRetiresTheSessionAndTellsTheApplication() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        inbox.pages.next = { _ in throw Rejected(status: 401) }

        await inbox.lane.run(under: run, cycles: 1)

        // The identical operation is signed again exactly once — a pooled
        // socket can lose the answer after the nonce was consumed
        // (`RealtimeLoop.java:203-205`) — and the second refusal retires the
        // session and the discovered capability.
        XCTAssertEqual(inbox.pagePaths, ["/v2/messages?after=0&limit=20",
                                         "/v2/messages?after=0&limit=20"])
        let held = await inbox.owner.session
        XCTAssertNil(held)
        let due = await inbox.owner.isDiscoveryDue()
        XCTAssertTrue(due)
        XCTAssertEqual(inbox.listener.losses, 1)
        XCTAssertEqual(inbox.listener.notifications.map(\.connected), [false])
        XCTAssertEqual(inbox.listener.notifications.first?.status, RealtimeStatus.unconfirmed)
    }

    // MARK: - a failed commit

    func testAFailedCommitStopsTheLaneAndSaysSoOnce() async throws {
        let inbox = try Inbox()
        let run = await inbox.owner.start()
        let message = try inbox.outgoing("[TEST ONLY] хранилище")
        inbox.pages.next = { _ in Inbox.page([message], cursor: 1) }
        inbox.receiver.fileSystem.failure = { [store = inbox.receiver.store] call in
            guard case .rename = call else { return nil }
            return FileSystemError(.rename, store.fileURL, errno: EIO)
        }

        await inbox.lane.run(under: run, cycles: 3)

        // "A failed or ambiguous save freezes the process and transmits
        // nothing from that candidate"
        // (`docs/protocol/first-contact-v1.md:173-178`,
        // `RealtimeLoop.java:74`).
        let frozen = await inbox.owner.isFrozen
        XCTAssertTrue(frozen)
        let current = await inbox.owner.current
        XCTAssertNil(current, "a client that cannot persist stops talking to the server")
        let notifications = inbox.listener.notifications
        XCTAssertEqual(notifications.map(\.connected), [true, false])
        XCTAssertEqual(notifications.last?.status, RealtimeStatus.storage)
        XCTAssertEqual(inbox.listener.losses, 1)
        XCTAssertEqual(try inbox.receiver.reopenStore().load().map { snapshot in
            try Snapshot.open(snapshot).stateVersion
        }, 3)
    }

    // MARK: - fixtures

    /// A paired sender and receiver, the owner over the receiver, the stand
    /// they talk to and the lane over all of it.
    ///
    /// `@unchecked Sendable` for the reason `Device` is: the fixture keeps the
    /// receiver's client so the test can read the state directly, which a lane
    /// may not do. The application hands the client to the owner in the
    /// expression that builds it and keeps nothing.
    final class Inbox: @unchecked Sendable {
        /// One synthetic page, in the shape `GET /v2/messages` and
        /// `GET /v2/events` answer with (`server/src/self_service_messages.rs:26`).
        static func page(_ events: [[String: Any]], cursor: Int64) -> [String: Any] {
            ["messages": events, "cursor": cursor]
        }

        /// One page, with nothing in it.
        static func emptyPage() -> [String: Any] {
            page([], cursor: 0)
        }

        let sender: Device
        let receiver: Device
        let server: StandServer
        let transport: FakeTransport
        let source: FakeMonotonicSource
        let flowPacer: RecordingPacer
        let lanePacer: RecordingPacer
        let pages: Pages
        let listener: RecordingListener
        let owner: StateOwner
        let flow: ProofFlow
        let lane: ReceiveLane
        /// The receiver's account, which is what the sender addresses.
        let peer: String

        private var sequence: Int64 = 0

        init(paired: Bool = true) throws {
            let source = FakeMonotonicSource()
            let flowPacer = RecordingPacer()
            let lanePacer = RecordingPacer()
            let pages = Pages()
            self.source = source
            self.flowPacer = flowPacer
            self.lanePacer = lanePacer
            self.pages = pages

            let sender: Device
            let receiver: Device
            if paired {
                // Two registered devices that have verified each other out of
                // band, which is the only way a message can be sent at all.
                let both = try SelfServiceClientTests.pairedDevices()
                sender = both.0
                receiver = both.1
            } else {
                sender = try Device(name: "unused", trust: ReceiveLaneTests.stand)
                receiver = try Device(name: "bare", trust: ReceiveLaneTests.stand)
            }
            self.sender = sender
            self.receiver = receiver
            let credential = (try? receiver.client.credential()) ?? [:]
            peer = (credential["account"] as? String) ?? ""

            let server = try StandServer(credential: credential)
            self.server = server
            let transport = FakeTransport(server: server)
            self.transport = transport
            let owner = StateOwner(client: receiver.client, clock: source.clock)
            self.owner = owner
            let flow = ProofFlow(owner: owner, transport: transport,
                                 clock: source.clock, pacer: flowPacer)
            self.flow = flow
            let listener = RecordingListener(device: receiver)
            self.listener = listener
            lane = ReceiveLane(owner: owner, flow: flow, transport: transport,
                               listener: listener, pacer: lanePacer)

            // The two page routes are the test's; everything else is the
            // stand's own answer.
            transport.answer = { call in
                guard call.method == "GET", Inbox.isPage(call.path) else { return nil }
                return try pages.next?(call) ?? Inbox.emptyPage()
            }
        }

        /// Whether one path is a page request.
        static func isPage(_ path: String) -> Bool {
            path.hasPrefix("/v2/messages?") || path.hasPrefix("/v2/events?")
        }

        /// Every page request this lane made, in order.
        var pagePaths: [String] {
            transport.calls.filter { $0.method == "GET" && Inbox.isPage($0.path) }.map(\.path)
        }

        /// One more message from the paired sender, at the next sequence, in
        /// the four-member shape the server hands back (`lib.rs:115-120`).
        func outgoing(_ text: String) throws -> [String: Any] {
            sequence += 1
            try sender.client.send(account: peer, text: text)
            let envelope = try XCTUnwrap(try sender.client.pending().last)
            return try SelfServiceClientTests.message(envelope,
                                                      from: try sender.account(),
                                                      sequence: sequence)
        }
    }

    /// What the stand answers the next page request with, if anything.
    final class Pages: @unchecked Sendable {
        var next: ((FakeTransport.Call) throws -> [String: Any])?
    }

    /// Somewhere for a fixture closure to leave the error it could not throw.
    final class Box: @unchecked Sendable {
        var error: (any Error)?
    }

    /// A counter the fixture closures share.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    /// The listener of `clients/android/test/RealtimeBridge.java:33-52`: every
    /// notification is checked against the encrypted snapshot on the device
    /// before it is recorded.
    ///
    /// It runs on the state owner — the lane invokes it inside
    /// `StateOwner.perform` — so reading the client and reopening the store is
    /// exactly what the Java fixture does on its own owner thread.
    final class RecordingListener: RealtimeListener, @unchecked Sendable {
        struct Notification {
            let connected: Bool
            let status: String
            /// Messages the public view carried when this was published.
            let published: Int
            /// Messages the committed snapshot held at that moment.
            let durable: Int
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
            var published = 0
            var durable = 0
            // A frozen client refuses to say anything about itself, which is
            // the state the storage notice is published in
            // (`RealtimeBridge.java:35`).
            if !device.client.isBroken {
                do {
                    published = Self.count(inDialogs: try device.client.publicView()["dialogs"]
                        as? [[String: Any]] ?? [])
                    durable = try Self.durableCount(of: device)
                    if published != durable {
                        lock.withLock {
                            failures.append("published \(published) with \(durable) durable")
                        }
                    }
                } catch {
                    lock.withLock { failures.append("\(error)") }
                }
            }
            lock.withLock {
                recorded.append(Notification(connected: connected, status: status,
                                             published: published, durable: durable))
            }
        }

        func authorizationLost() {
            lock.withLock { lost += 1 }
        }

        /// What the sealed file on the device says, decrypted and read through
        /// the core (`RealtimeBridge.java:37-40`).
        private static func durableCount(of device: Device) throws -> Int {
            guard let stored = try device.stored() else { return 0 }
            guard let state = JsonSpan.value(of: "state", in: stored) else { return 0 }
            let view = try CoreBridge.command(state: state, request: #"{"op":"view"}"#)
            return count(inDialogs: view.object["dialogs"] as? [[String: Any]] ?? [])
        }

        private static func count(inDialogs dialogs: [[String: Any]]) -> Int {
            dialogs.reduce(0) { $0 + (($1["messages"] as? [[String: Any]])?.count ?? 0) }
        }
    }
}
