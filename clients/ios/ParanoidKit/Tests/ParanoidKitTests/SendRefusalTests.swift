import Foundation
import ParanoidKit
import XCTest

/// The refusals of «Отправить» and of «Отпечаток совпадает», produced by the
/// real core rather than typed in.
///
/// Each test drives `SelfServiceClient` or the bridge into the situation a
/// user can actually reach and classifies the error the core answers with, so
/// a sentence on the screen is tied to a refusal that exists
/// (`clients/core/src/clean_service.rs`, `docs/product/self-service-messenger.md`
/// «Errors must be understandable»; REQ-CLIENT-004).
final class SendRefusalTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "ab", count: 32)

    // MARK: - send_v2

    func testEveryCodeOfTheSendPathHasItsOwnCaseAndTheRestFallBack() {
        let named: [String: SendRefusal] = [
            "local_history_full": .historyFull,
            "outbox_full": .outboxFull,
            "local_state_full": .stateFull,
            "contact_blocked": .blocked,
            "invalid_text": .invalidText,
            "introduction_limit": .tooLarge,
            "registration_required": .notRegistered,
        ]
        for (code, refusal) in named {
            XCTAssertEqual(SendRefusal.classify(CoreError.rejected(code)), refusal, code)
        }
        // The rest of `send_v2`'s refusals name nothing a user can act on
        // (`clean_service.rs:395,421,445,456`, `intro_v2.rs:94-100`).
        for code in ["verify_peer_first", "session_error", "encryption_failed",
                     "prepare_contact_first", "contact_binding_mismatch",
                     "introduction_context_mismatch", "invalid_state", "state_error"] {
            XCTAssertEqual(SendRefusal.classify(CoreError.rejected(code)), .unfinished, code)
        }
        XCTAssertEqual(SendRefusal.classify(CoreError.nativeFailure), .unfinished)
        XCTAssertEqual(SendRefusal.classify(SelfServiceError.registrationRequired), .notRegistered)
    }

    func testAFrozenClientHasNoSendCaptionBecauseTheFrozenScreenSpeaks() {
        XCTAssertNil(SendRefusal.classify(SelfServiceError.frozen))
        XCTAssertNil(SendRefusal.classify(SelfServiceError.commitFailed))
    }

    /// 400 envelopes to one contact that the server never accepted are the
    /// most a conversation may hold (`clean_service.rs:399-400`); the next
    /// text is refused before anything is committed.
    func testTheFourHundredAndFirstQueuedTextIsRefusedAsAFullOutbox() throws {
        let (first, second) = try SelfServiceClientTests.pairedDevices()
        let peer = try second.account()
        for index in 0..<400 {
            try first.client.send(account: peer, text: "очередь \(index)")
        }
        XCTAssertEqual(try first.client.pending().count, 400)
        let commits = first.commits

        XCTAssertThrowsError(try first.client.send(account: peer, text: "ещё одно")) { error in
            XCTAssertEqual(error as? CoreError, .rejected("outbox_full"))
            XCTAssertEqual(SendRefusal.classify(error), .outboxFull)
        }
        XCTAssertEqual(first.commits, commits, "a refused text commits nothing")
        XCTAssertEqual(try first.client.pending().count, 400)
    }

    func testABlockedContactIsRefusedByTheCoreAsBlocked() throws {
        let (first, second) = try SelfServiceClientTests.pairedDevices()
        let peer = try second.account()
        try first.client.block(account: peer, blocked: true)
        XCTAssertThrowsError(try first.client.send(account: peer, text: "привет")) { error in
            XCTAssertEqual(error as? CoreError, .rejected("contact_blocked"))
            XCTAssertEqual(SendRefusal.classify(error), .blocked)
        }
    }

    func testAClientWithoutRegistrationIsRefusedAsNotRegistered() throws {
        let device = try Device(name: "unregistered",
                                trust: try ServiceTrust(realm: Self.realm, pin: Self.pin))
        try device.client.createIdentity()
        XCTAssertThrowsError(try device.client.send(account: String(repeating: "1a", count: 32),
                                                    text: "привет")) { error in
            XCTAssertEqual(SendRefusal.classify(error), .notRegistered)
        }
    }

    // MARK: - pair_contact_v2

    /// `peer_already_pinned` is a contact of an account that is already in
    /// the list, carrying **other keys**: the same identity prepared twice
    /// gives two contacts that differ only in the device's fallback key
    /// (`clean_service.rs:841-855`). The first pairing stands, the second is
    /// refused before anything changes (`clean_service.rs:353-358`), and the
    /// same QR scanned again is not refused at all.
    func testAnotherContactOfAnAlreadyPairedAccountIsReportedAsOtherKeys() throws {
        let (original, replacement, account) = try Self.twoContactsOfOneAccount()
        XCTAssertNotEqual(original, replacement)
        let device = try Device(name: "pairing",
                                trust: try ServiceTrust(realm: Self.realm, pin: Self.pin))
        try device.register()
        try device.client.pair(original, verified: true)
        let stored = try device.stored()

        XCTAssertNoThrow(try device.client.pair(original, verified: true),
                         "the same QR again is not a refusal")
        XCTAssertThrowsError(try device.client.pair(replacement, verified: true)) { error in
            XCTAssertEqual(error as? CoreError, .rejected("peer_already_pinned"))
            XCTAssertEqual(ContactFlowError.classify(error), .otherKeys)
        }
        XCTAssertEqual(try device.stored(), stored, "the saved contact is not changed")
        XCTAssertEqual(try ClientView.read(device.client).dialogs.map(\.account), [account])
    }

    /// One identity, registered once, whose `prepare_contact_v2` is run on two
    /// copies of the same state.
    private static func twoContactsOfOneAccount() throws -> (String, String, String) {
        let created = try CoreBridge.command(
            state: "", request: try json(["op": "create_identity", "realm": realm, "pin": pin]))
        let upgraded = try CoreBridge.command(state: try XCTUnwrap(created.state),
                                              request: #"{"op":"upgrade_v2"}"#)
        let credential = try XCTUnwrap(
            (upgraded.object["request"] as? [String: Any])?["credential"] as? [String: Any])
        let active = try CoreBridge.command(
            state: try XCTUnwrap(upgraded.state),
            request: try json(["op": "server_status_v2",
                               "status": try SelfServiceClientTests.activeStatus(for: credential)]))
        let registered = try XCTUnwrap(active.state)
        func contact() throws -> String {
            let prepared = try CoreBridge.command(state: registered,
                                                  request: #"{"op":"prepare_contact_v2"}"#)
            return try XCTUnwrap(JsonSpan.value(of: "contact", in: prepared.text))
        }
        return (try contact(), try contact(), try XCTUnwrap(credential["account"] as? String))
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
