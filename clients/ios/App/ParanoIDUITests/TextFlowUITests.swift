import UIKit
import XCTest

/// The whole text flow of the client, on a simulator, against a local stand.
///
/// It is driven by `clients/ios/test_sim_text.py` and by nothing else: the
/// stand's `-paranoid-realm` / `-paranoid-pin` pair, the peer's contact and
/// the texts to send all arrive in the environment, and both tests skip when
/// they are absent, so a plain `xcodebuild test` of this scheme never opens a
/// connection and never creates an identity.
///
/// Two things make this a scenario rather than a screen check:
///
/// - **The peer is real.** The other side is a second `service-bridge` — the
///   same shipped Swift classes over the same Rust core — talking to the same
///   unchanged server. Nothing here is stubbed, so «Сохранено сервером» means
///   the server stored the envelope and «Доставлено» means that peer's core
///   acknowledged it. Those words are the accessibility label of the bubble —
///   the marks themselves are drawn (`ReceiptMark`) and carry no text, so what
///   this test reads is exactly what VoiceOver reads.
/// - **The two sides take turns.** The harness cannot guess when the screen
///   is the one to photograph or when the peer should answer, so the test asks
///   it, through the file rendezvous below, and waits for the answer. Every
///   screenshot is therefore of the screen the assertion was just made about.
///
/// `testReinstallStartsANewIdentity` is the second half of the same story and
/// runs after `xcrun simctl uninstall`: the container is gone and the
/// simulator's Keychain is not, which is exactly the reinstall
/// `StorageGuard` describes (D-004). The launch must find no identity, must
/// not freeze, and «Создать ID» must produce an account that is not the one
/// the first run recorded.
final class TextFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - the text flow

    @MainActor
    func testTextFlowOnTheLocalStand() throws {
        let fixture = try Fixture.fromEnvironment()
        let app = fixture.launch()

        // «Создать ID» — the only screen a device with no identity shows.
        let create = app.buttons["create-id"]
        XCTAssertTrue(create.waitForExistence(timeout: Timeout.launch),
                      "the welcome screen did not appear: " + Diagnosis.of(app))
        XCTAssertFalse(app.otherElements["no-stand"].exists,
                       "the stand arguments did not reach the application")
        try fixture.shot("01-welcome")
        create.tap()

        // «Мой ID»: the QR exists only once the core has contact material,
        // so waiting for it is waiting for the registration to have landed.
        let identity = app.buttons["tab-identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: Timeout.identity),
                      "«Создать ID» did not reach the three tabs: " + Diagnosis.of(app))
        identity.tap()
        let qr = app.descendants(matching: .any)["identity-qr"]
        XCTAssertTrue(qr.waitForExistence(timeout: Timeout.registration),
                      "no contact QR after registration: " + Diagnosis.of(app))
        XCTAssertEqual(qr.label, "QR моего контакта")
        let account = try fixture.hexadecimal(app.staticTexts["identity-account"], "account")
        _ = try fixture.hexadecimal(app.staticTexts["identity-fingerprint"], "fingerprint")
        try fixture.shot("02-identity")
        try fixture.note("account", account)

        // The two places whose captions stopped being true (`test_ui_contract.py`,
        // UNTRUE): «Приложение» at the foot of «Мой ID», and «Подключение»
        // behind the status line. The running screens carry the corrected ones.
        let alpha = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Восстановление ID пока недоступно")).firstMatch
        for _ in 0..<4 where !(alpha.exists && alpha.isHittable) { app.swipeUp() }
        XCTAssertTrue(alpha.exists && alpha.isHittable,
                      "«Приложение» is not on «Мой ID»: " + Diagnosis.of(app))
        XCTAssertFalse(alpha.label.contains("До 200"), alpha.label)
        try fixture.shot("02a-application")
        app.buttons["status-line"].tap()
        let foreground = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "в чате от него не останется следа")).firstMatch
        XCTAssertTrue(foreground.waitForExistence(timeout: Timeout.screen),
                      "«Подключение» does not say what happens to a call: " + Diagnosis.of(app))
        try fixture.shot("02b-connection")
        app.buttons["connection-close"].tap()

        // «Вставить контакт»: the peer's contact, exactly as its core wrote it.
        app.buttons["bar-add-contact"].tap()
        let paste = app.buttons["add-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Timeout.screen),
                      "«Добавить контакт» did not open: " + Diagnosis.of(app))
        try fixture.shot("03-add-contact")
        paste.tap()
        try fixture.fill(app, with: fixture.peerContact)
        try fixture.shot("04-paste")
        app.buttons["Продолжить"].tap()

        // «Отпечаток совпадает»: the fingerprint on the screen is the one the
        // peer's own core published, digit for digit.
        let fingerprint = app.staticTexts["confirm-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: Timeout.screen),
                      "the contact was not read: " + Diagnosis.of(app))
        XCTAssertEqual(fingerprint.label, fixture.peerFingerprint)
        try fixture.shot("05-confirm")
        app.buttons["confirm-pair"].tap()

        // «Контакты»: the paired contact, verified because the fingerprint
        // was compared.
        let row = app.descendants(matching: .any)["dialog-\(fixture.peerAccount)"]
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.commit),
                      "the paired contact did not appear: " + Diagnosis.of(app))
        XCTAssertTrue(row.label.contains("Проверен"), "the pairing is not verified: \(row.label)")
        try fixture.shot("06-contacts")
        row.tap()

        let trust = app.buttons["chat-trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: Timeout.screen),
                      "the conversation did not open: " + Diagnosis.of(app))
        XCTAssertEqual(trust.label, "Личность проверена · Подробнее")
        try fixture.shot("07-chat")

        // One tap on «Отправить»: one envelope, «Сохранено сервером» when the
        // server has stored it.
        try fixture.compose(app, fixture.firstText)
        let send = app.buttons["send"]
        XCTAssertTrue(send.isEnabled, "«Отправить» is disabled for a text that fits")
        send.tap()
        let sent = try fixture.bubble(app, fixture.firstText, marked: "Сохранено сервером",
                                      "the first message")
        // The bubble also carries the instant this phone wrote it, and the chat
        // names the day it belongs to (RFC-0023). Both are read here off the
        // accessibility tree, which is what a screen reader gets.
        XCTAssertNotNil(sent.label.range(of: "[0-9]{2}:[0-9]{2}", options: .regularExpression),
                        "the first message carries no time: «\(sent.label)»")
        let today = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Сегодня")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: Timeout.screen),
                      "the day this conversation started is not named: " + Diagnosis.of(app))
        // The peer has not been asked to run a cycle yet, so nothing can have
        // acknowledged this message: «Доставлено» here would be one the client
        // drew of its own accord.
        XCTAssertFalse(sent.label.contains("Доставлено"),
                       "the first message was double-checked before the peer acknowledged it")
        XCTAssertNotEqual(app.descendants(matching: .any)["compose-field"].value as? String,
                          fixture.firstText, "the composer was not cleared by the tap")
        try fixture.shot("08-sent")

        // The peer answers. `peer-expect` returns only once that phone's core
        // has the text in its own committed history.
        XCTAssertEqual(try fixture.ask("peer-expect", fixture.firstText), "1",
                       "the peer did not receive exactly one copy of the first message")
        try fixture.ask("peer-send", fixture.replyText)
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", fixture.replyText)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: Timeout.delivery),
                      "the peer's reply never arrived: " + Diagnosis.of(app))
        _ = try fixture.bubble(app, fixture.firstText, marked: "Доставлено", "the first message")
        try fixture.shot("09-delivered")

        // Two taps in one gesture: the guard is `Drafts.begin`, which is
        // synchronous, so the second tap finds the composer empty and the
        // send in flight.
        try fixture.compose(app, fixture.doubleText)
        send.doubleTap()
        let doubled = try fixture.bubble(app, fixture.doubleText, marked: "Сохранено сервером",
                                         "the double-tapped message")
        try fixture.exactlyOne(app, fixture.doubleText, "after the second tap")
        XCTAssertEqual(try fixture.ask("peer-expect", fixture.doubleText), "1",
                       "a double tap put more than one envelope on the server")
        _ = try fixture.bubble(app, fixture.doubleText, marked: "Доставлено", "the double-tapped message")
        XCTAssertEqual(doubled.label.components(separatedBy: "Доставлено").count - 1, 1,
                       "the double-tapped message carries more than one «Доставлено»")
        try fixture.exactlyOne(app, fixture.doubleText, "after the peer acknowledged it")
        try fixture.shot("10-double-tap")

        // «Заблокировать контакт» and back.
        app.buttons["contact-details"].tap()
        let block = app.buttons["details-block"]
        XCTAssertTrue(block.waitForExistence(timeout: Timeout.screen),
                      "the contact details did not open: " + Diagnosis.of(app))
        XCTAssertEqual(block.label, "Заблокировать контакт")
        try fixture.shot("11-details")
        block.tap()
        let confirm = app.alerts.buttons["Заблокировать"]
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.screen),
                      "blocking was not confirmed first: " + Diagnosis.of(app))
        confirm.tap()
        XCTAssertTrue(fixture.wait(trust, label: "Личность проверена · Заблокирован"),
                      "the conversation is not shown as blocked: \(trust.label)")
        XCTAssertEqual(app.staticTexts["compose-hint"].label,
                       "Контакт заблокирован. Откройте сведения, чтобы разблокировать.")
        XCTAssertFalse(app.buttons["send"].isEnabled, "a blocked contact can still be written to")
        try fixture.shot("12-blocked")

        app.buttons["contact-details"].tap()
        let unblock = app.buttons["details-block"]
        XCTAssertTrue(unblock.waitForExistence(timeout: Timeout.screen),
                      "the contact details did not open: " + Diagnosis.of(app))
        XCTAssertEqual(unblock.label, "Разблокировать контакт")
        unblock.tap()
        XCTAssertTrue(fixture.wait(trust, label: "Личность проверена · Подробнее"),
                      "the conversation is still blocked: \(trust.label)")
        XCTAssertFalse(app.staticTexts["compose-hint"].exists,
                       "the blocked hint outlived the block")
        try fixture.shot("13-unblocked")

        // «Переименовать»: a name typed on this phone stands where the default
        // label stood, and an empty field puts that label back
        // (`ContactNames`, Android v22). Nothing of this reaches the peer: the
        // only thing that changes is what this screen says.
        let defaultTitle = "Контакт " + String(fixture.peerAccount.prefix(6))
        XCTAssertTrue(fixture.titled(app, defaultTitle),
                      "the conversation is not titled by the account: " + Diagnosis.of(app))
        try fixture.rename(app, to: "Серёга")
        XCTAssertTrue(fixture.titled(app, "Серёга"),
                      "the chat kept the default title after «Сохранить»: " + Diagnosis.of(app))
        try fixture.shot("14-renamed")
        try fixture.rename(app, to: "")
        XCTAssertTrue(fixture.titled(app, defaultTitle),
                      "an empty name did not restore the default title: " + Diagnosis.of(app))
        try fixture.shot("15-default-name")
        try fixture.note("flow", "complete")
    }

    // MARK: - the reinstall

    @MainActor
    func testReinstallStartsANewIdentity() throws {
        let fixture = try Fixture.fromEnvironment()
        let previous = try XCTUnwrap(fixture.previousAccount,
                                     "PARANOID_SIM_PREVIOUS_ACCOUNT names the account of the run before")
        let app = fixture.launch()

        // The container was deleted and the Keychain was not. The launch must
        // read that as a clean install: no identity, and no freeze.
        let create = app.buttons["create-id"]
        XCTAssertTrue(create.waitForExistence(timeout: Timeout.launch),
                      "a reinstall did not reach «Создать ID»: " + Diagnosis.of(app))
        XCTAssertFalse(app.otherElements["frozen"].exists,
                       "a reinstall froze on the retained Keychain key")
        XCTAssertFalse(app.otherElements["no-stand"].exists,
                       "the stand arguments did not reach the application")
        try fixture.shot("20-reinstall-welcome")
        create.tap()

        let identity = app.buttons["tab-identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: Timeout.identity),
                      "«Создать ID» did not work after a reinstall: " + Diagnosis.of(app))
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["identity-qr"]
            .waitForExistence(timeout: Timeout.registration),
                      "the new identity did not register: " + Diagnosis.of(app))
        let account = try fixture.hexadecimal(app.staticTexts["identity-account"], "account")
        XCTAssertNotEqual(account, previous, "a reinstall kept the previous identity")
        try fixture.shot("21-reinstall-identity")
        try fixture.note("reinstall_account", account)
    }
}

// MARK: - timeouts

/// Every wait in this file, named. They are ceilings on a failure, not
/// expected waits: the server notifies its waiters on every committed POST
/// (`docs/protocol/realtime-v1.md:105-108`).
private enum Timeout {
    static let screen: TimeInterval = 20
    static let launch: TimeInterval = 60
    static let identity: TimeInterval = 90
    static let registration: TimeInterval = 180
    static let commit: TimeInterval = 60
    static let delivery: TimeInterval = 120
    static let answer: TimeInterval = 300
}

// MARK: - the fixture

/// What `clients/ios/test_sim_text.py` hands this test, and the rendezvous
/// back to it.
///
/// Every member is read from the environment, which `xcodebuild` fills from
/// the harness's `TEST_RUNNER_`-prefixed variables. A missing rendezvous
/// directory skips the test instead of failing it, so the plain
/// `xcodebuild test` of this scheme — which has no stand — stays green and
/// stays offline.
private struct Fixture {
    let rendezvous: Rendezvous
    let realm: String
    let pin: String
    let peerContact: String
    let peerAccount: String
    let peerFingerprint: String
    let firstText: String
    let replyText: String
    let doubleText: String
    let previousAccount: String?

    static func fromEnvironment() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let found = environment[name], !found.isEmpty else { return nil }
            return found
        }
        guard let directory = value("PARANOID_SIM_RENDEZVOUS") else {
            throw XCTSkip("""
                          This scenario needs a local stand and a peer bridge; \
                          run python3 clients/ios/test_sim_text.py.
                          """)
        }
        return Fixture(
            rendezvous: Rendezvous(directory: URL(fileURLWithPath: directory, isDirectory: true)),
            realm: try XCTUnwrap(value("PARANOID_SIM_REALM")),
            pin: try XCTUnwrap(value("PARANOID_SIM_PIN")),
            peerContact: try decoded(XCTUnwrap(value("PARANOID_SIM_PEER_CONTACT"))),
            peerAccount: try XCTUnwrap(value("PARANOID_SIM_PEER_ACCOUNT")),
            peerFingerprint: try XCTUnwrap(value("PARANOID_SIM_PEER_FINGERPRINT")),
            firstText: try XCTUnwrap(value("PARANOID_SIM_FIRST_TEXT")),
            replyText: try XCTUnwrap(value("PARANOID_SIM_REPLY_TEXT")),
            doubleText: try XCTUnwrap(value("PARANOID_SIM_DOUBLE_TEXT")),
            previousAccount: value("PARANOID_SIM_PREVIOUS_ACCOUNT"))
    }

    /// The peer's contact travels as base64 because it is one line of JSON and
    /// an environment variable is not a place to quote one.
    private static func decoded(_ value: String) throws -> String {
        let data = try XCTUnwrap(Data(base64Encoded: value), "PARANOID_SIM_PEER_CONTACT is not base64")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// The application under test, with the stand the harness started and no
    /// other argument at all.
    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-paranoid-realm", realm, "-paranoid-pin", pin]
        app.launch()
        return app
    }

    // MARK: asking the harness

    @discardableResult
    func ask(_ verb: String, _ argument: String = "") throws -> String {
        try rendezvous.ask(verb, argument, timeout: Timeout.answer)
    }

    /// `xcrun simctl io <udid> screenshot`, taken by the harness while this
    /// test waits on the answer.
    func shot(_ name: String) throws {
        try ask("shot", name)
    }

    /// One fact for the evidence file.
    func note(_ key: String, _ value: String) throws {
        try ask("note", key + " " + value)
    }

    // MARK: reading the screen

    /// The label of `element`, once it is 64 lowercase hexadecimal digits.
    @MainActor
    func hexadecimal(_ element: XCUIElement, _ what: String) throws -> String {
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.screen), "no \(what) on «Мой ID»")
        let value = element.label
        XCTAssertEqual(value.count, 64, "the \(what) is not 64 characters: \(value.count)")
        XCTAssertTrue(value.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "the \(what) is not lowercase hexadecimal")
        return value
    }

    /// Waits until `element` carries exactly `label`.
    @MainActor
    func wait(_ element: XCUIElement, label: String, timeout: TimeInterval = Timeout.commit) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// The bubbles this device wrote that say `text`.
    ///
    /// A message is two accessibility elements, not one: `MessageBubble`
    /// combines its children, which gives the bubble — «<текст>, Сохранено
    /// сервером» — and the selectable `Text` inside it stays an element of
    /// its own, whose label is the message and nothing else. Counting the
    /// first of the two is counting bubbles; counting both would count every
    /// message twice. A bubble of the peer's carries no tick, so it is
    /// indistinguishable from its own inner text and is looked for by
    /// existence rather than by count.
    @MainActor
    func bubbles(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", text, text))
    }

    /// Asserts that the conversation is showing this message once and once
    /// only, and says what it is showing instead when it is not.
    @MainActor
    func exactlyOne(_ app: XCUIApplication, _ text: String, _ when: String) throws {
        let found = bubbles(app, text).allElementsBoundByIndex
        XCTAssertEqual(found.count, 1,
                       "\(found.count) bubbles carry this message \(when): "
                       + found.map { "\($0.elementType.rawValue)/«\($0.label)»" }
                           .joined(separator: " | ")
                       + "\n" + Diagnosis.of(app))
    }

    /// The bubble of `text`, once it carries `mark`.
    ///
    /// `BEGINSWITH` names the bubble and nothing else: a conversation row
    /// carries the same text, but after a title and a «Вы: » prefix.
    @MainActor
    @discardableResult
    func bubble(_ app: XCUIApplication, _ text: String, marked mark: String,
                _ what: String) throws -> XCUIElement {
        let query = bubbles(app, text)
        let deadline = Date().addingTimeInterval(Timeout.delivery)
        while Date() < deadline {
            let element = query.firstMatch
            if element.exists, element.label.contains(mark) { return element }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(what) never reached \(mark): " + Diagnosis.of(app))
        return query.firstMatch
    }

    // MARK: writing on the screen

    /// Whether the conversation on screen is called `title`.
    ///
    /// An inline navigation title is a static text of the bar on some runtimes
    /// and the bar's own identifier on others, so both are accepted; what is
    /// being measured is the name, not which element carries it.
    @MainActor
    func titled(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = Timeout.screen) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.navigationBars.staticTexts[title].exists || app.navigationBars[title].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// «Сведения о контакте» → «Переименовать» → the field → «Сохранить».
    ///
    /// An empty `name` is the reset: the field is cleared and saved, which is
    /// «Оставьте пустым, чтобы вернуть имя по умолчанию.». The sheet is closed
    /// afterwards, so the assertion that follows is about the screen behind it.
    @MainActor
    func rename(_ app: XCUIApplication, to name: String) throws {
        app.buttons["contact-details"].tap()
        let entry = app.buttons["details-rename"]
        XCTAssertTrue(entry.waitForExistence(timeout: Timeout.screen),
                      "the contact details did not open: " + Diagnosis.of(app))
        entry.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: Timeout.screen),
                      "«Имя контакта» did not open: " + Diagnosis.of(app))
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !name.isEmpty { field.typeText(name) }
        app.alerts.buttons["Сохранить"].tap()
        let close = app.buttons["details-close"]
        XCTAssertTrue(close.waitForExistence(timeout: Timeout.screen),
                      "«Имя контакта» did not close: " + Diagnosis.of(app))
        close.tap()
    }

    /// Types `text` into the composer and leaves the keyboard where it is.
    @MainActor
    func compose(_ app: XCUIApplication, _ text: String) throws {
        let field = app.descendants(matching: .any)["compose-field"]
        XCTAssertTrue(field.waitForExistence(timeout: Timeout.screen),
                      "no composer: " + Diagnosis.of(app))
        field.tap()
        app.typeText(text)
        XCTAssertEqual(field.value as? String, text, "the composer did not take the text")
    }

    /// Puts the peer's contact into the paste sheet.
    ///
    /// A contact is around 900 bytes of JSON, so it is pasted rather than
    /// typed: the pasteboard is set from this process and the paste itself is
    /// the user's — a hardware `⌘V`, then the edit menu, then, if a simulator
    /// refuses both, the keyboard. Only the last of the three is slow, and all
    /// three end with the same assertion: the field holds the contact byte for
    /// byte, because a repaired contact is a different contact.
    @MainActor
    func fill(_ app: XCUIApplication, with contact: String) throws {
        let field = app.descendants(matching: .any)["paste-field"]
        XCTAssertTrue(field.waitForExistence(timeout: Timeout.screen),
                      "«Вставить контакт» did not open: " + Diagnosis.of(app))
        UIPasteboard.general.string = contact
        field.tap()
        app.typeKey("v", modifierFlags: .command)
        if !holds(field, contact) {
            field.press(forDuration: 1.2)
            for title in ["Paste", "Вставить"] where app.menuItems[title].waitForExistence(timeout: 2) {
                app.menuItems[title].tap()
                break
            }
        }
        if !holds(field, contact) {
            field.tap()
            app.typeText(contact)
        }
        XCTAssertEqual(field.value as? String, contact,
                       "the contact did not reach the field: " + Diagnosis.of(app))
    }

    @MainActor
    private func holds(_ field: XCUIElement, _ text: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if field.value as? String == text { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
