import Foundation
import ParanoidKit
import XCTest
@testable import ParanoID

/// The composer's send path on the production `AppModel`, with the
/// new-message marks of the same chat read on the way.
///
/// `PresentationTests` holds the rule on `Drafts` alone: the core is given the
/// draft trimmed at its ends, and a failed send puts back the draft as it was
/// typed. Here the rule runs through the whole path a tap takes —
/// `AppModel.send`, the owner, the real Rust core — over a real registered
/// client with one verified contact, and the failure is a real one: the
/// snapshot cannot be written, so the core's candidate is never committed and
/// the client freezes (`SelfServiceClient.apply`). The reader's own messages,
/// sent or refused, never count as new and never draw «Новые сообщения».
///
/// An incoming message cannot be put into this model without a server — the
/// client is handed to its owner as `sending`, so nothing else can reach it —
/// so the peer's half of the same chat is `test_sim_text.py`'s: a reply typed
/// with blanks at its ends while scrolled up with «↓» on the screen.
final class ComposerSendTests: XCTestCase {
    /// A snapshot store that can be told to refuse every later write, the way
    /// a full disk would.
    private final class Store: SnapshotSink, @unchecked Sendable {
        private let lock = NSLock()
        private var refusing = false

        func refuse() {
            lock.withLock { refusing = true }
        }

        func save(_ snapshot: String) throws {
            if lock.withLock({ refusing }) { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    private static let trust = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    @MainActor
    func testTheCoreIsGivenTheTrimmedTextAndAFailedSendPutsTheTypedDraftBack() async throws {
        let store = Store()
        let (model, peer) = try await Self.modelWithOneContact(store: store)
        model.openChat(peer)
        XCTAssertNil(model.unreadDivider)

        // Sent: the composer empties on the tap, and the core holds the text
        // without the blanks it was typed with.
        model.draft = "  привет \n"
        model.draftChanged()
        model.send()
        XCTAssertEqual(model.draft, "", "the composer is emptied on the tap, before the core answers")
        try await Self.wait { model.view.dialog(peer)?.messages.count == 1 }
        XCTAssertEqual(model.view.dialog(peer)?.messages.map(\.text), ["привет"])
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.chatUnseenCount, 0, "the reader's own message counted as new")
        XCTAssertEqual(model.unseenCount(for: try XCTUnwrap(model.view.dialog(peer))), 0)
        XCTAssertNil(model.unreadDivider, "the reader's own message drew «Новые сообщения»")

        // Refused: the snapshot cannot be written, so nothing is committed,
        // and what comes back into the composer is what was typed — blanks
        // and all — not the trimmed text that was handed to the core.
        store.refuse()
        let typed = "  второе \n"
        model.draft = typed
        model.draftChanged()
        model.send()
        XCTAssertEqual(model.draft, "", "the composer is emptied on the tap, before the core answers")
        try await Self.wait { model.isBroken }
        XCTAssertEqual(model.draft, typed, "a failed send did not put back the draft as it was typed")
        XCTAssertEqual(model.view.dialog(peer)?.messages.map(\.text), ["привет"],
                       "a message the core never committed is shown")
        XCTAssertEqual(model.chatUnseenCount, 0)
        XCTAssertNil(model.unreadDivider)
    }

    // MARK: - fixture

    @MainActor
    private static func modelWithOneContact(store: Store) async throws -> (AppModel, String) {
        let peer = try SelfServiceClient(saved: nil, sink: Store(), fixture: trust)
        try peer.createIdentity()
        try peer.registrationResult(status: try activeStatus(peer))
        let text = try XCTUnwrap(try peer.contactText())
        let account = try XCTUnwrap(try peer.credential()["account"] as? String)
        let model = AppModel(openClient: {
            let client = try SelfServiceClient(saved: nil, sink: store, fixture: trust)
            try client.createIdentity()
            try client.registrationResult(status: try activeStatus(client))
            try client.pair(text, verified: true)
            return client
        }, loadLocalMetadata: { (ContactNames(store: nil), CallLog(store: nil)) })
        model.start()
        XCTAssertEqual(model.stage, .running)
        model.refresh()
        try await wait { model.view.dialogs.count == 1 }
        return (model, account)
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

    /// Waits up to twenty seconds, and throws past them.
    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
