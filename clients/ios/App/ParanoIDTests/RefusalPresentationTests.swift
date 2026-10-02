import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// A text the core refuses is refused **in the chat**, above the composer,
/// with the reason the core gave.
///
/// Before this, `AppModel.send()` caught every error the same way: the text
/// went back into the field without a word, and the one sentence written went
/// to the «Подключение» sheet, which the chat cannot open. The client here is
/// real — a registered identity, a verified contact and 400 envelopes the
/// server never accepted, all through the production `SelfServiceClient` and
/// core — so the refusal on the screen is the core's `outbox_full`
/// (`clean_service.rs:399-400`), not a stub. Its realm is a loopback address
/// nothing listens on, so nothing leaves the simulator.
final class RefusalPresentationTests: XCTestCase {
    private final class MemorySink: SnapshotSink {
        private(set) var last: String?
        func save(_ snapshot: String) throws { last = snapshot }
    }

    /// The committed wrapper of a client with a full outbox, and its peer.
    /// 400 real sends take most of a minute, so both chat tests open the same
    /// committed state instead of producing it twice.
    @MainActor private static var prepared: (snapshot: String, peer: String)?

    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    @MainActor
    func testARefusedTextIsNamedAboveTheComposerUntilTheTextIsEdited() async throws {
        let (model, peer) = try await Self.chatWithAFullOutbox()

        model.draft = "проверка"
        model.draftChanged()
        XCTAssertTrue(model.canSend)
        model.send()
        XCTAssertEqual(model.draft, "")
        try await Self.refused(model)

        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull)
        XCTAssertTrue(model.isRefusalShown)
        // The field's own echo of the text that came back is not an edit.
        model.draftChanged()
        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull)
        XCTAssertEqual(model.view.dialog(peer)?.account, peer)

        model.draft = "проверка!"
        model.draftChanged()
        XCTAssertEqual(model.composerHint, "")
        XCTAssertFalse(model.isRefusalShown)
    }

    /// The wire text is short, but the restored draft crosses the raw byte
    /// limit. Neither that padding nor the field's restoration echo hides or
    /// clears the refusal; only a real edit does.
    @MainActor
    func testPaddedDraftKeepsItsRefusalAfterRestorationAndReopening() async throws {
        let (model, peer) = try await Self.chatWithAFullOutbox()
        let raw = String(repeating: " ", count: 2050) + "проверка\n"
        model.draft = raw
        model.draftChanged()
        XCTAssertTrue(model.canSend)
        XCTAssertFalse(model.isOverLimit)
        XCTAssertEqual(model.composerHint, "")
        model.send()
        try await Self.wait { model.draft == raw && model.isRefusalShown }
        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull)
        model.draftChanged()
        XCTAssertTrue(model.isRefusalShown, "restoring raw draft is not an edit")
        model.closeChat()
        model.openChat(peer)
        XCTAssertEqual(model.draft, raw)
        model.draftChanged()
        XCTAssertTrue(model.isRefusalShown)
        model.draft = "проверка"
        model.draftChanged()
        XCTAssertFalse(model.isRefusalShown, "removing padding is a real edit")
    }

    /// A send that comes back after the user has left the chat is explained
    /// when they return, with the text it refused: leaving keeps the note, and
    /// so does a re-read that finds the outbox still full.
    @MainActor
    func testLeavingTheChatKeepsTheRefusalAndReturningShowsIt() async throws {
        let (model, peer) = try await Self.chatWithAFullOutbox()

        model.draft = "проверка"
        model.draftChanged()
        model.send()
        model.closeChat()
        try await Self.wait { model.lastStatus == Strings.Status.sendUnfinished }
        XCTAssertEqual(model.composerHint, "", "no chat, no hint")

        model.openChat(peer)
        XCTAssertEqual(model.draft, "проверка", "the refused text is back")
        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull)
        model.draftChanged()
        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull, "the echo is not an edit")

        // Only its own conversation shows it.
        model.closeChat()
        model.openChat("0000000000000000000000000000000000000000000000000000000000000000")
        XCTAssertEqual(model.composerHint, "")
        model.closeChat()
        model.openChat(peer)
        XCTAssertEqual(model.composerHint, Strings.Chat.Refusal.outboxFull)
    }

    /// Which notes a re-read of the state may retire, and which it never
    /// touches (`AppModel.staleRefusal`).
    func testARefusalIsForgottenExactlyWhenItsReasonIsGone() {
        let bound = SendRefusal.outboxBound
        XCTAssertTrue(AppModel.staleRefusal(.outboxFull, pending: bound - 1, active: true, blocked: false))
        XCTAssertFalse(AppModel.staleRefusal(.outboxFull, pending: bound, active: true, blocked: false))
        XCTAssertTrue(AppModel.staleRefusal(.notRegistered, pending: 0, active: true, blocked: false))
        XCTAssertFalse(AppModel.staleRefusal(.notRegistered, pending: 0, active: false, blocked: false))
        XCTAssertTrue(AppModel.staleRefusal(.blocked, pending: 0, active: true, blocked: false))
        XCTAssertFalse(AppModel.staleRefusal(.blocked, pending: 0, active: true, blocked: true))
        for reason in [.historyFull, .stateFull, .invalidText, .tooLarge, .unfinished] as [SendRefusal] {
            XCTAssertFalse(AppModel.staleRefusal(reason, pending: 0, active: true, blocked: false),
                           "\(reason) is never re-read")
        }
    }

    /// Every refusal has a caption, and the two that already had one keep it.
    func testEveryRefusalHasACaption() {
        let all: [SendRefusal] = [.historyFull, .outboxFull, .stateFull, .blocked, .invalidText,
                                  .tooLarge, .notRegistered, .unfinished]
        for refusal in all {
            XCTAssertFalse(Strings.Chat.refusal(refusal).isEmpty, "\(refusal)")
        }
        XCTAssertEqual(Strings.Chat.refusal(.blocked), Strings.Chat.blockedHint)
        XCTAssertEqual(Strings.Chat.refusal(.unfinished), Strings.Status.sendUnfinished)
        XCTAssertEqual(Set(all.map(Strings.Chat.refusal)).count, all.count,
                       "no two refusals share a sentence")
    }

    // MARK: - fixture

    /// A running model whose client has a verified contact and a full outbox
    /// to it, with that conversation open.
    @MainActor
    private static func chatWithAFullOutbox() async throws -> (AppModel, String) {
        let (snapshot, peer) = try fullOutbox()
        let model = AppModel(openClient: {
            try SelfServiceClient(saved: snapshot, sink: MemorySink(), fixture: trust)
        }, loadLocalMetadata: { (ContactNames(store: nil), CallLog(store: nil)) })
        model.start()
        XCTAssertEqual(model.stage, .running)
        model.refresh()
        try await wait { model.view.dialog(peer)?.messages.count == 400 }
        model.openChat(peer)
        return (model, peer)
    }

    @MainActor
    private static func fullOutbox() throws -> (snapshot: String, peer: String) {
        if let prepared { return prepared }
        let peerClient = try SelfServiceClient(saved: nil, sink: MemorySink(), fixture: trust)
        try peerClient.createIdentity()
        try peerClient.registrationResult(status: try activeStatus(peerClient))
        let peerText = try XCTUnwrap(try peerClient.contactText())
        let peer = try XCTUnwrap(try peerClient.credential()["account"] as? String)

        let sink = MemorySink()
        let client = try SelfServiceClient(saved: nil, sink: sink, fixture: trust)
        try client.createIdentity()
        try client.registrationResult(status: try activeStatus(client))
        try client.pair(peerText, verified: true)
        for index in 0..<400 {
            try client.send(account: peer, text: "очередь \(index)")
        }
        let built = (snapshot: try XCTUnwrap(sink.last), peer: peer)
        prepared = built
        return built
    }

    /// The `server_status_v2` a server would answer with; the fingerprint is
    /// the core's own (`validate_request`), as in `SdpCompatibilityTests`.
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

    /// Until the send has come back: the text is in the field again and the
    /// composer no longer says it is saving.
    @MainActor
    private static func refused(_ model: AppModel) async throws {
        try await wait { model.draft == "проверка" && model.composerHint != Strings.Chat.savingHint }
    }

    @MainActor
    private static func wait(_ condition: () -> Bool,
                             timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the condition did not hold within \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
