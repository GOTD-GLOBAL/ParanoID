import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// «Чаты» as the model hands it to the screen: the conversation with the
/// newest message first, a missed call named in red when it is the row's
/// preview, and a call moving nothing.
///
/// The model is the production `AppModel` over a real registered client
/// with three verified contacts; the messages are real sends through the
/// core, which stamps each with the clock the client is given
/// (`SelfServiceClient.wallMillis`, RFC-0023) — here a counter, so the
/// stamps are what the test says and nothing waits on the wall clock — and
/// the calls are recorded as the controller reports them (`callFinished`).
final class ChatListTests: XCTestCase {
    private final class MemorySink: SnapshotSink {
        func save(_ snapshot: String) throws {}
    }

    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    /// The clock the client under test stamps messages with: one second per
    /// send, or the same second while held, or `0` — an unstamped entry.
    private final class Clock: @unchecked Sendable {
        var now: UInt64 = 1_700_000_000_000
        var hold = false
        var zero = false
        func next() -> UInt64 {
            if zero { return 0 }
            if !hold { now += 1_000 }
            return now
        }
    }

    @MainActor private static var clock = Clock()

    @MainActor
    func testTheNewestConversationIsFirstAndAnEmptyOneIsLast() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        let (first, second, silent) = (peers[0], peers[1], peers[2])
        // The core publishes by account id; the screen must not.
        XCTAssertEqual(model.view.dialogs.map(\.account), peers.sorted())

        try await Self.send(model, to: first, "раз")
        try await Self.send(model, to: second, "два")
        XCTAssertEqual(model.orderedDialogs.map(\.account), [second, first, silent])

        try await Self.send(model, to: first, "три")
        XCTAssertEqual(model.orderedDialogs.map(\.account), [first, second, silent])
    }

    /// The stamp is the rule, not the commit order: equal stamps keep the
    /// core's order, an unstamped message sorts with the empty
    /// conversations, and a stamp that went backwards is followed.
    @MainActor
    func testEqualAndMissingStampsFollowTheCoresOrder() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        let (first, second, silent) = (peers[0], peers[1], peers[2])
        let core = model.view.dialogs.map(\.account)

        Self.clock.hold = true
        try await Self.send(model, to: second, "раз")
        try await Self.send(model, to: first, "два")
        XCTAssertEqual(model.orderedDialogs.map(\.account),
                       core.filter { $0 != silent } + [silent], "equal stamps keep the core's order")

        Self.clock.hold = false
        Self.clock.zero = true
        try await Self.send(model, to: silent, "без времени")
        XCTAssertEqual(model.view.dialog(silent)?.last?.localMilliseconds, 0)
        XCTAssertEqual(model.orderedDialogs.map(\.account).last, silent,
                       "an unstamped message sorts with the empty conversations")

        Self.clock.zero = false
        try await Self.send(model, to: first, "три")
        XCTAssertEqual(model.orderedDialogs.map(\.account).first, first)
    }

    @MainActor
    func testAMissedCallIsNamedInRedAndMovesNothing() async throws {
        let (model, peers) = try await Self.modelWithThreeContacts()
        let (first, second, silent) = (peers[0], peers[1], peers[2])
        try await Self.send(model, to: first, "раз")
        try await Self.send(model, to: second, "два")

        model.callFinished(CallTermination(callId: "m1", account: first, outgoing: false,
                                            connected: false, video: false, durationSeconds: 0,
                                            reason: .timeout))
        let row = try XCTUnwrap(model.view.dialog(first))
        XCTAssertEqual(model.preview(for: row), Strings.CallRow.missed)
        XCTAssertTrue(model.isMissedCallPreview(for: row))
        XCTAssertEqual(model.listTime(for: row), "", "a call preview carries no time")
        // The call log keeps no time, so the call does not lift the chat
        // above the one with the newer message.
        XCTAssertEqual(model.orderedDialogs.map(\.account), [second, first, silent])

        // An answered call is not red; a call before any message is a preview too.
        model.callFinished(CallTermination(callId: "m2", account: second, outgoing: true,
                                            connected: true, video: false, durationSeconds: 151,
                                            reason: .hangup))
        let answered = try XCTUnwrap(model.view.dialog(second))
        XCTAssertEqual(model.preview(for: answered), Strings.CallRow.outgoing + " · 2:31")
        XCTAssertFalse(model.isMissedCallPreview(for: answered))
        model.callFinished(CallTermination(callId: "m3", account: silent, outgoing: false,
                                            connected: false, video: true, durationSeconds: 0,
                                            reason: .cancel))
        let empty = try XCTUnwrap(model.view.dialog(silent))
        XCTAssertEqual(model.preview(for: empty), Strings.CallRow.missedVideo)
        XCTAssertTrue(model.isMissedCallPreview(for: empty))

        // A message after the call takes the preview back, and the red with it.
        try await Self.send(model, to: first, "три")
        let again = try XCTUnwrap(model.view.dialog(first))
        XCTAssertNil(model.preview(for: again))
        XCTAssertFalse(model.isMissedCallPreview(for: again))
        XCTAssertEqual(model.orderedDialogs.map(\.account), [first, second, silent])
    }

    // MARK: - fixture

    @MainActor
    private static func modelWithThreeContacts() async throws -> (AppModel, [String]) {
        var texts: [String] = []
        var accounts: [String] = []
        for _ in 0..<3 {
            let peer = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
            try peer.createIdentity()
            try peer.registrationResult(status: try activeStatus(peer))
            texts.append(try XCTUnwrap(try peer.contactText()))
            accounts.append(try XCTUnwrap(try peer.credential()["account"] as? String))
        }
        let pairTexts = texts
        let clock = Clock()
        Self.clock = clock
        let model = AppModel(openClient: {
            let client = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
            client.wallMillis = { @Sendable in clock.next() }
            try client.createIdentity()
            try client.registrationResult(status: try activeStatus(client))
            for text in pairTexts { try client.pair(text, verified: true) }
            return client
        }, loadLocalMetadata: { (ContactNames(store: nil), CallLog(store: nil)) })
        model.start()
        XCTAssertEqual(model.stage, .running)
        model.refresh()
        try await wait { model.view.dialogs.count == 3 }
        return (model, accounts)
    }

    /// One send through the production path, waited for until the view shows
    /// it. The stamp comes from the test's clock.
    @MainActor
    private static func send(_ model: AppModel, to account: String, _ text: String) async throws {
        let before = model.view.dialog(account)?.messages.count ?? 0
        model.openChat(account)
        model.draft = text
        model.draftChanged()
        model.send()
        try await wait { (model.view.dialog(account)?.messages.count ?? 0) == before + 1 }
        model.closeChat()
    }

    private static func activeStatus(_ client: SelfServiceClient) throws -> [String: Any] {
        let credential = try client.credential()
        let request: [String: Any] = [
            "op": "validate_request",
            "descriptor": ["type": "paranoid-request-v1", "credential": credential],
        ]
        let validated = try CoreBridge.command(
            state: "",
            request: String(decoding: try JSONSerialization.data(withJSONObject: request),
                            as: UTF8.self))
        return ["mode": "active",
                "account": try XCTUnwrap(credential["account"] as? String),
                "device": try XCTUnwrap(credential["device"] as? String),
                "credential": try XCTUnwrap(validated.object["fingerprint"] as? String)]
    }

    private struct TimedOut: Error {}

    /// Waits up to twenty seconds, and throws past them, so that a stalled
    /// send ends the test there instead of cascading into order assertions.
    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
