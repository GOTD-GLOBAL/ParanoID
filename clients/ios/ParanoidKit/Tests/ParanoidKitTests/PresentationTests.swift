import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the presentation rules the screens are built on: the
/// two `DialogPolicy` rules, the `MessagePresentation` formatting, the
/// double-tap guard and the contact-flow refusals.
///
/// None of it opens a file, a connection or a core state: these are the rules
/// that turn what the core already published into what a screen shows, and
/// they are the same rules as
/// `clients/android/src/org/paranoid/text/{DialogPolicy,MessagePresentation}.java`.
final class PresentationTests: XCTestCase {
    // MARK: - DialogPolicy

    func testTrustLabelIsVerifiedOnlyForAnOutOfBandComparison() {
        XCTAssertEqual(DialogPolicy.trustLabel(Self.dialog(trust: "out_of_band_verified")),
                       "Личность проверена")
        XCTAssertEqual(DialogPolicy.trustLabel(Self.dialog(trust: "network_unverified")),
                       "Личность не проверена")
        // A value this build does not know is not "verified", and neither is
        // the absence of a dialog (`DialogPolicy.java:8-11`).
        XCTAssertEqual(DialogPolicy.trustLabel(Self.dialog(trust: "something_new")),
                       "Личность не проверена")
        XCTAssertEqual(DialogPolicy.trustLabel(nil), "Личность не проверена")
    }

    func testCanReplyNeedsADialogARegistrationAWorkingStoreAndNoSendInFlight() {
        let dialog = Self.dialog(trust: "network_unverified")
        XCTAssertTrue(DialogPolicy.canReply(dialog, active: true, broken: false, sending: false))
        // Trust is a label, not a gate: an unverified contact is answered.
        XCTAssertTrue(DialogPolicy.canReply(Self.dialog(trust: "out_of_band_verified"),
                                            active: true, broken: false, sending: false))
        XCTAssertFalse(DialogPolicy.canReply(nil, active: true, broken: false, sending: false))
        XCTAssertFalse(DialogPolicy.canReply(dialog, active: false, broken: false, sending: false))
        XCTAssertFalse(DialogPolicy.canReply(dialog, active: true, broken: true, sending: false))
        XCTAssertFalse(DialogPolicy.canReply(dialog, active: true, broken: false, sending: true))
        XCTAssertFalse(DialogPolicy.canReply(Self.dialog(trust: "network_unverified", blocked: true),
                                             active: true, broken: false, sending: false))
        XCTAssertFalse(DialogPolicy.canReply(Self.dialog(account: "", trust: "network_unverified"),
                                             active: true, broken: false, sending: false))
    }

    // MARK: - the decoded view

    func testAViewIsDecodedIntoTheValuesAScreenReads() {
        let raw: [String: Any] = [
            "identity": true,
            "active": true,
            "configured": true,
            "account": "7f3a9c1e04b7d2a8",
            "contact_fingerprint": String(repeating: "a", count: 64),
            "rejected_count": NSNumber(value: 2),
            "dialogs": [[
                "account": "b41d079a5c",
                "own": "7f3a9c1e04b7d2a8",
                "trust": "out_of_band_verified",
                "blocked": false,
                "messages": [
                    ["id": "m1", "author": "7f3a9c1e04b7d2a8", "text": "раз",
                     "accepted": true, "delivered": true],
                    ["id": "m2", "author": "b41d079a5c", "text": "два"],
                    // Not a message: no identifier, so nothing is shown for it.
                    ["author": "b41d079a5c", "text": "три"],
                ],
            ]],
        ]
        let view = ClientView.decode(raw, contact: "{\"type\":\"paranoid-contact-v2\"}")
        XCTAssertTrue(view.hasIdentity)
        XCTAssertTrue(view.isActive)
        XCTAssertEqual(view.account, "7f3a9c1e04b7d2a8")
        XCTAssertEqual(view.rejectedCount, 2)
        XCTAssertEqual(view.contact, "{\"type\":\"paranoid-contact-v2\"}")
        let dialog = try? XCTUnwrap(view.dialog("b41d079a5c"))
        XCTAssertEqual(dialog?.messages.count, 2)
        XCTAssertEqual(dialog?.isVerified, true)
        XCTAssertEqual(dialog?.last?.id, "m2")
        XCTAssertEqual(dialog?.isOwn(dialog!.messages[0]), true)
        XCTAssertEqual(dialog?.isOwn(dialog!.messages[1]), false)
        XCTAssertEqual(dialog?.messages[1].isAccepted, false)
        XCTAssertNil(view.dialog("nobody"))

        // An empty view is the state of a device with nothing on it.
        let empty = ClientView.decode([:])
        XCTAssertFalse(empty.hasIdentity)
        XCTAssertEqual(empty.dialogs, [])
        XCTAssertNil(empty.contact)
    }

    // MARK: - MessagePresentation

    func testTitleAndShortIdNameAContactByItsAccountAndNothingElse() {
        let account = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertEqual(MessagePresentation.title(account), "Контакт 012345")
        XCTAssertEqual(MessagePresentation.title("ab"), "Контакт ab")
        XCTAssertEqual(MessagePresentation.shortId(account), "01234567…89abcdef")
        XCTAssertEqual(MessagePresentation.shortId("0123456789abcdef"), "0123456789abcdef")
    }

    func testPreviewCollapsesWhitespaceAndCutsAtEightyCodePoints() {
        XCTAssertEqual(MessagePresentation.preview("  две\n\tстроки  "), "две строки")
        XCTAssertEqual(MessagePresentation.preview("\n\n"), "")
        // A non-breaking space is not `\s` in Java and is not collapsed here.
        XCTAssertEqual(MessagePresentation.preview("a\u{00A0}b"), "a\u{00A0}b")
        let long = String(repeating: "я", count: 81)
        XCTAssertEqual(MessagePresentation.preview(long).unicodeScalars.count, 81)
        XCTAssertTrue(MessagePresentation.preview(long).hasSuffix("…"))
        let exact = String(repeating: "я", count: 80)
        XCTAssertEqual(MessagePresentation.preview(exact), exact)
    }

    func testTheComposerMeasuresBytesAndRefusesBlankOrOversizedText() {
        XCTAssertEqual(MessagePresentation.byteLimit, 2048)
        XCTAssertEqual(MessagePresentation.byteCount("привет"), 12)
        XCTAssertTrue(MessagePresentation.canSend("привет"))
        XCTAssertFalse(MessagePresentation.canSend(""))
        XCTAssertFalse(MessagePresentation.canSend("   \n\t "))
        let limit = String(repeating: "я", count: 1024)
        XCTAssertEqual(MessagePresentation.byteCount(limit), 2048)
        XCTAssertTrue(MessagePresentation.canSend(limit))
        XCTAssertFalse(MessagePresentation.canSend(limit + "я"))
        // The limit is measured on the text as typed, not on a trimmed copy:
        // the untrimmed text is what the core is given.
        XCTAssertFalse(MessagePresentation.canSend(limit + " "))
    }

    func testDeliveryAndMarkSayTheSameThreeThings() {
        let queued = Self.message(accepted: false, delivered: false)
        let stored = Self.message(accepted: true, delivered: false)
        let done = Self.message(accepted: true, delivered: true)
        XCTAssertEqual(MessagePresentation.delivery(queued), "В очереди")
        XCTAssertEqual(MessagePresentation.delivery(stored), "Сохранено сервером")
        XCTAssertEqual(MessagePresentation.delivery(done), "Доставлено")
        XCTAssertEqual(MessagePresentation.mark(queued), .queued)
        XCTAssertEqual(MessagePresentation.mark(stored), .stored)
        XCTAssertEqual(MessagePresentation.mark(done), .delivered)
        // REQ-MSG-003 has three states and no fourth: nothing this client can
        // draw or read out means the peer opened the conversation.
        XCTAssertEqual(MessagePresentation.Mark.allCases.count, 3)
        for mark in MessagePresentation.Mark.allCases {
            XCTAssertFalse(mark.rawValue.contains("read"))
        }
        for message in [queued, stored, done] {
            XCTAssertFalse(MessagePresentation.delivery(message).contains("рочитано"))
        }
    }

    // MARK: - the double-tap guard

    @MainActor
    func testTwoInstantTapsProduceOneTicketAndOneActorCall() async {
        let drafts = MessagePresentation.Drafts()
        let dialog = Self.dialog(trust: "network_unverified")
        drafts.update(account: dialog.account, text: "раз")
        let counter = SendCounter()

        // Two taps in one turn of the run loop, with nothing awaited between
        // them — the case a debounce would let through.
        var sends: [Task<Void, Never>] = []
        for _ in 0..<2 {
            let allowed = DialogPolicy.canReply(dialog, active: true, broken: false,
                                                sending: drafts.isSending)
            let text = drafts.text(for: dialog.account)
            guard let ticket = drafts.begin(account: dialog.account, text: text,
                                            canReply: allowed)
            else { continue }
            sends.append(Task { await counter.send(ticket.text) })
        }

        XCTAssertEqual(sends.count, 1, "the second tap must not reach the state owner")
        // The composer is empty from the instant of the tap, and the button is
        // disabled because a send is in flight.
        XCTAssertEqual(drafts.text(for: dialog.account), "")
        XCTAssertTrue(drafts.isSending)
        for send in sends { await send.value }
        let calls = await counter.calls
        XCTAssertEqual(calls, ["раз"])
    }

    @MainActor
    func testAFailedSendPutsTheTextBackAndASucceededOneDoesNot() {
        let drafts = MessagePresentation.Drafts()
        let dialog = Self.dialog(trust: "network_unverified")

        drafts.update(account: dialog.account, text: "первое")
        let failed = drafts.begin(account: dialog.account, text: "первое", canReply: true)
        drafts.finished(try! XCTUnwrap(failed), committed: false)
        XCTAssertEqual(drafts.text(for: dialog.account), "первое")
        XCTAssertFalse(drafts.isSending)

        let committed = drafts.begin(account: dialog.account, text: "первое", canReply: true)
        drafts.finished(try! XCTUnwrap(committed), committed: true)
        XCTAssertEqual(drafts.text(for: dialog.account), "")

        // A failure that comes back after the user has typed something else
        // does not overwrite what they wrote (`MessagePresentation.java:42-45`).
        drafts.update(account: dialog.account, text: "второе")
        let pending = try! XCTUnwrap(drafts.begin(account: dialog.account, text: "второе",
                                                  canReply: true))
        drafts.update(account: dialog.account, text: "третье")
        drafts.finished(pending, committed: false)
        XCTAssertEqual(drafts.text(for: dialog.account), "третье")
    }

    @MainActor
    func testATapIsRefusedWhenTheDialogRefusesRepliesOrTheTextIsUnsendable() {
        let drafts = MessagePresentation.Drafts()
        XCTAssertNil(drafts.begin(account: "b41d07", text: "раз", canReply: false))
        XCTAssertNil(drafts.begin(account: "b41d07", text: "   ", canReply: true))
        XCTAssertNil(drafts.begin(account: "b41d07",
                                  text: String(repeating: "я", count: 1025),
                                  canReply: true))
        XCTAssertFalse(drafts.isSending)
        XCTAssertEqual(drafts.text(for: "b41d07"), "")
    }

    @MainActor
    func testDraftsAreKeptPerConversationAndNotForAnEmptyAccount() {
        let drafts = MessagePresentation.Drafts()
        drafts.update(account: "aaa", text: "первому")
        drafts.update(account: "bbb", text: "второму")
        drafts.update(account: "", text: "никому")
        XCTAssertEqual(drafts.text(for: "aaa"), "первому")
        XCTAssertEqual(drafts.text(for: "bbb"), "второму")
        XCTAssertEqual(drafts.text(for: ""), "")
    }

    // MARK: - ContactFlowError

    func testEveryRefusalOfTheContactFlowBecomesANonEmptySentence() {
        // Every code `contact_text_v2` / `pair_contact_v2` and the material
        // they verify can answer with (`clean_service.rs:830-848`,
        // `contact_v2.rs:43-71`, `key-protocol/src/lib.rs:52,118,125,153`).
        let codes = ["invalid_contact", "qr_limit", "wrong_qr_type", "invalid_credential",
                     "invalid_key", "invalid_peer_key", "noncanonical_key",
                     "noncanonical_signature", "invalid_signature",
                     "contact_binding_mismatch", "peer_already_pinned", "peer_not_verified",
                     "contact_limit", "unverified_contact_limit", "registration_required",
                     "create_identity_first", "invalid_state", "channel_error"]
        for code in codes {
            let mapped = ContactFlowError.classify(CoreError.rejected(code))
            XCTAssertFalse(mapped.message.isEmpty, "\(code) has no message")
            // Nothing in a user-facing sentence may be a bare code without the
            // sentence around it.
            XCTAssertTrue(mapped.message.hasSuffix(".") || mapped.message.hasSuffix("»."),
                          "\(code): \(mapped.message)")
        }

        XCTAssertEqual(ContactFlowError.classify(CoreError.rejected("invalid_contact")),
                       .notAContact)
        XCTAssertEqual(ContactFlowError.classify(CoreError.rejected("qr_limit")), .notAContact)
        XCTAssertEqual(ContactFlowError.classify(CoreError.rejected("peer_already_pinned")),
                       .alreadyAdded)
        XCTAssertEqual(ContactFlowError.classify(CoreError.rejected("contact_limit")),
                       .refused("contact_limit"))
        XCTAssertEqual(ContactFlowError.classify(ContactFlowError.ownContact), .ownContact)

        XCTAssertEqual(ContactFlowError.notAContact.message,
                       "Это не контакт ParanoID. Попросите собеседника показать QR из «Мой ID».")
        XCTAssertEqual(ContactFlowError.ownContact.message, "Это ваш собственный контакт.")
        XCTAssertEqual(ContactFlowError.alreadyAdded.message, "Контакт уже добавлен.")
        XCTAssertEqual(ContactFlowError.refused("contact_limit").message,
                       "Не удалось добавить контакт (contact_limit).")
    }

    func testAFailureThatIsNotTheContactsFaultIsNotReportedAsABadQr() {
        XCTAssertEqual(ContactFlowError.classify(CoreError.nativeFailure),
                       .refused("native_failure"))
        XCTAssertEqual(ContactFlowError.classify(SelfServiceError.frozen),
                       .refused("local state frozen"))
    }

    func testOwnContactIsRecognisedByItsTextAndByItsAccount() {
        let account = String(repeating: "1a", count: 32)
        let own = "{\"type\":\"paranoid-contact-v2\",\"credential\":{\"account\":\"\(account)\"}}"
        // The very string this device publishes.
        XCTAssertTrue(ContactFlowError.isOwnContact(own, ownAccount: account, ownContact: own))
        // The same contact after a round trip through a message: a different
        // string, the same account.
        let spaced = "{ \"credential\" : { \"account\" : \"\(account)\" } }"
        XCTAssertTrue(ContactFlowError.isOwnContact(spaced, ownAccount: account, ownContact: own))
        // Somebody else's contact, and a text that is not JSON at all.
        let other = "{\"credential\":{\"account\":\"\(String(repeating: "2b", count: 32))\"}}"
        XCTAssertFalse(ContactFlowError.isOwnContact(other, ownAccount: account, ownContact: own))
        XCTAssertFalse(ContactFlowError.isOwnContact("не json", ownAccount: account,
                                                     ownContact: own))
        // A device with no identity has nothing of its own to recognise.
        XCTAssertFalse(ContactFlowError.isOwnContact(own, ownAccount: "", ownContact: nil))
    }

    // MARK: - fixtures

    /// Counts what reached "the state owner" in the double-tap check.
    private actor SendCounter {
        private(set) var calls: [String] = []
        func send(_ text: String) { calls.append(text) }
    }

    private static func dialog(account: String = "b41d079a5c",
                               trust: String,
                               blocked: Bool = false) -> Dialog {
        Dialog(account: account, own: "7f3a9c", trust: trust, isBlocked: blocked, messages: [])
    }

    private static func message(accepted: Bool, delivered: Bool) -> Message {
        Message(id: "m", author: "a", text: "t", isAccepted: accepted, isDelivered: delivered)
    }
}
