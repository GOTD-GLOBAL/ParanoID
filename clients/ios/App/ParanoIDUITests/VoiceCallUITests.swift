import UIKit
import XCTest

/// One call between two simulators, both of them this application.
///
/// It is driven by `clients/ios/test_voice_sim.py` and by nothing else: the
/// stand's `-paranoid-realm` / `-paranoid-pin` pair, the side this process is
/// and the rendezvous directory all arrive in the environment, and the test
/// skips when they are absent, so a plain `xcodebuild test` of this scheme
/// never opens a connection and never creates an identity.
///
/// Two processes of this bundle run at once, one per simulator, and they meet
/// only through the harness: `publish`/`fetch` carry the two public facts each
/// side needs about the other — its account, its contact fingerprint and the
/// contact its own core wrote — and `sync` is a barrier both sides arrive at.
/// Nothing else crosses; neither process can see the other's screen, and the
/// only thing that connects the two applications is the unchanged server on
/// the local stand and the media they negotiate directly with each other.
///
/// What one run states, in order:
///
/// - both sides register on the stand and pair each other's contact by the
///   fingerprint that side's own core published;
/// - the `a` side calls, the `b` side answers, and **both** reach «Соединение
///   установлено», which is `PeerConnectionState.connected` and nothing
///   weaker: `CallController` publishes `.connected` only from the media
///   engine's own event (`CallCoordinator.media(_:from:)`);
/// - the call is then held for longer than the protocol's silence deadline
///   (`CallController.silenceMillis`, 30 s), so a call that survives it has
///   been receiving the peer's ten-second heartbeat all along
///   (`CallController.heartbeatMillis`);
/// - the media carried RTP in both directions — `packetsReceived` above zero
///   out of `RTCPeerConnection.statistics`, through the Debug-only
///   ``CallDiagnostics`` sink the harness reads;
/// - «Завершить» ends it on both sides;
/// - and then the same call in the other direction, `b` to `a`.
final class VoiceCallUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVoiceCallBetweenTwoSimulators() throws {
        let fixture = try VoiceFixture.fromEnvironment()
        let app = fixture.launch()

        // «Создать ID» — the only screen a device with no identity shows.
        let create = app.buttons["create-id"]
        XCTAssertTrue(create.waitForExistence(timeout: Timeout.launch),
                      "the welcome screen did not appear: " + Diagnosis.of(app))
        XCTAssertFalse(app.otherElements["no-stand"].exists,
                       "the stand arguments did not reach the application")
        try fixture.shot("01-welcome")
        create.tap()

        // «Мой ID»: the QR exists only once the core has contact material, so
        // waiting for it is waiting for the registration to have landed.
        let identity = app.buttons["tab-identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: Timeout.identity),
                      "«Создать ID» did not reach the three tabs: " + Diagnosis.of(app))
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["identity-qr"]
            .waitForExistence(timeout: Timeout.registration),
                      "no contact QR after registration: " + Diagnosis.of(app))
        let account = try fixture.hexadecimal(app.staticTexts["identity-account"], "account")
        let fingerprint = try fixture.hexadecimal(app.staticTexts["identity-fingerprint"],
                                                  "fingerprint")
        try fixture.shot("02-identity")
        try fixture.note("account", account)

        // «Копировать контакт», and then the harness reads the **device's**
        // pasteboard with `xcrun simctl pbpaste`. This process never reads it:
        // a pasteboard read by an application that did not write it raises the
        // system's paste permission alert, and a test runner is an application
        // like any other.
        app.buttons["copy-contact"].tap()
        let contact = try fixture.ask("copy")
        XCTAssertTrue(contact.hasPrefix("{") && contact.hasSuffix("}"),
                      "«Копировать контакт» put no contact on the pasteboard")
        try fixture.publish("account", account)
        try fixture.publish("fingerprint", fingerprint)
        try fixture.publish("contact", contact)

        // The other simulator's own three facts, as its core published them.
        let peerAccount = try fixture.fetch("account")
        let peerFingerprint = try fixture.fetch("fingerprint")
        let peerContact = try fixture.fetch("contact")
        XCTAssertNotEqual(peerAccount, account, "both simulators registered the same account")

        // «Вставить контакт» → «Отпечаток совпадает».
        app.buttons["bar-add-contact"].tap()
        let paste = app.buttons["add-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Timeout.screen),
                      "«Добавить контакт» did not open: " + Diagnosis.of(app))
        paste.tap()
        try fixture.fill(app, with: peerContact)
        app.buttons["Продолжить"].tap()
        let shown = app.staticTexts["confirm-fingerprint"]
        XCTAssertTrue(shown.waitForExistence(timeout: Timeout.screen),
                      "the contact was not read: " + Diagnosis.of(app))
        XCTAssertEqual(shown.label, peerFingerprint,
                       "the fingerprint on «Проверка контакта» is not the peer's own")
        try fixture.shot("03-confirm")
        app.buttons["confirm-pair"].tap()

        let row = app.descendants(matching: .any)["dialog-\(peerAccount)"]
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.commit),
                      "the paired contact did not appear: " + Diagnosis.of(app))
        XCTAssertTrue(row.label.contains("Проверен"), "the pairing is not verified: \(row.label)")
        try fixture.shot("04-contacts")

        // Neither side may call before the other has paired it: a knock to a
        // phone that has not paired this account is refused by that phone's
        // own core, and the call would never ring.
        try fixture.sync("paired")

        // And neither side may call before its own phone says the server is
        // connected. A call intent waits ten seconds for a confirmed online
        // lane and then refuses with «Нет подключения для звонка»
        // (`AppModel.waitForCallConnection`), and the receive lane confirms
        // itself online only when a page has come back — which, on a phone
        // with nothing to deliver, is the long poll's own timeout rather than
        // anything this run can hurry. So the screen is asked, exactly as a
        // user would read it before calling.
        let online = app.buttons["status-line"]
        XCTAssertTrue(fixture.wait(online, label: "Сервер подключён", timeout: Timeout.online),
                      "the phone never reported the server connected (\(online.label)): "
                      + Diagnosis.of(app))
        try fixture.shot("05-online")
        row.tap()
        XCTAssertTrue(app.buttons["chat-trust"].waitForExistence(timeout: Timeout.screen),
                      "the conversation did not open: " + Diagnosis.of(app))
        try fixture.sync("ready")

        try call(app, fixture, number: 1, placing: fixture.role == "a")
        try call(app, fixture, number: 2, placing: fixture.role == "b")
        try fixture.note("flow", "complete")
    }

    // MARK: - one call

    /// One whole call, from this side of it.
    ///
    /// - Parameters:
    ///   - number: which of the two calls of a run this is; it names the
    ///     screenshots and the statistics readings.
    ///   - placing: whether this side taps «Позвонить» or «Ответить».
    @MainActor
    private func call(_ app: XCUIApplication, _ fixture: VoiceFixture,
                      number: Int, placing: Bool) throws {
        let side = placing ? "caller" : "callee"
        let status = app.staticTexts["call-status"]
        if placing {
            let audio = app.buttons["call-audio"]
            XCTAssertTrue(audio.waitForExistence(timeout: Timeout.screen),
                          "«Аудиозвонок» is not on the conversation: " + Diagnosis.of(app))
            audio.tap()
            // The confirmation carries the privacy sentence, and it is the
            // only thing that may ask for the microphone.
            let confirm = app.alerts.buttons["Позвонить"]
            XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.screen),
                          "«Позвонить собеседнику?» did not open: " + Diagnosis.of(app))
            try fixture.shot("\(number)0-\(side)-prompt")
            confirm.tap()
            try fixture.grantMicrophone(shot: "\(number)05-\(side)-microphone")
            // An intent that refuses says so in the banner — no connection, no
            // microphone — and the banner is gone three seconds later. It is
            // watched for while the call screen is being waited for, so that a
            // failure here says why and not only that nothing appeared.
            let refusal = fixture.refusal(app, until: status)
            if !refusal.isEmpty { try fixture.note("call\(number)_refused", refusal) }
            XCTAssertTrue(status.waitForExistence(timeout: Timeout.call),
                          "the call screen did not appear (banner: «\(refusal)»): "
                          + Diagnosis.of(app))
            try fixture.shot("\(number)1-\(side)-outgoing")
        } else {
            // The ring raises the call screen on its own: an incoming call is
            // published from the state owner and `AppModel.callChanged` shows
            // it (`MainActivity.showCall()`).
            let answer = app.buttons["call-answer"]
            XCTAssertTrue(answer.waitForExistence(timeout: Timeout.ring),
                          "no incoming call arrived: " + Diagnosis.of(app))
            XCTAssertEqual(status.label, "Входящий звонок")
            XCTAssertTrue(app.staticTexts["call-privacy"].exists,
                          "the privacy sentence is not above «Ответить»")
            try fixture.shot("\(number)1-\(side)-incoming")
            answer.tap()
            try fixture.grantMicrophone(shot: "\(number)15-\(side)-microphone")
        }

        // «Соединение установлено» is published from the media engine's own
        // `connected` event and from nothing else, so reaching it is reaching
        // `RTCPeerConnectionState.connected`.
        XCTAssertTrue(fixture.connected(status, within: Timeout.connect),
                      "this side never connected (\(status.label)): " + Diagnosis.of(app))
        try fixture.shot("\(number)2-\(side)-connected")
        XCTAssertTrue(app.buttons["call-mute"].isEnabled, "the call controls are not live")
        let atConnect = try fixture.statistics("connect-\(number)")
        XCTAssertEqual(atConnect["state"], "connected",
                       "the media summary does not say connected: \(atConnect)")
        XCTAssertGreaterThan(fixture.number(atConnect, "pair_packets_received"), 0,
                             "no packet reached this side's candidate pair: \(atConnect)")

        // The call is now held past the protocol's silence deadline, which
        // only the peer's heartbeat can carry it over. The caller asks the
        // harness to do the waiting, because the harness is also the thing
        // that counts what the server stored while it went on; the callee
        // waits for the caller at the barrier below.
        if placing { try fixture.hold(seconds: VoiceFixture.holdSeconds) }
        try fixture.sync("held-\(number)")

        let elapsed = try fixture.elapsed(status)
        XCTAssertGreaterThan(elapsed, VoiceFixture.silenceSeconds,
                             "the call did not outlive the silence deadline: \(status.label)")
        try fixture.shot("\(number)3-\(side)-held")
        let held = try fixture.statistics("held-\(number)")
        XCTAssertEqual(held["state"], "connected", "the call is no longer connected: \(held)")
        XCTAssertGreaterThan(fixture.number(held, "audio_packets_received"), 0,
                             "no RTP audio packet reached this side: \(held)")
        XCTAssertGreaterThan(fixture.number(held, "audio_packets_sent"), 0,
                             "this side sent no RTP audio packet: \(held)")
        try fixture.note("call\(number)_\(side)_elapsed", "\(elapsed)")
        try fixture.note("call\(number)_\(side)_packets_received",
                         "\(fixture.number(held, "audio_packets_received"))")

        // «Завершить» on the caller; the callee learns it from the `end`
        // control the peer sent, and neither side is allowed to be left with
        // a call on the screen.
        if placing { app.buttons["call-end"].tap() }
        XCTAssertTrue(fixture.wait(status, label: "Звонок завершён", timeout: Timeout.screen),
                      "the call did not end on this side (\(status.label)): " + Diagnosis.of(app))
        try fixture.shot("\(number)4-\(side)-ended")
        // The red button is «Закрыть» once the call is over, and it is what
        // puts the screen away; a call that has already gone `idle` took the
        // screen with it (`AppModel.callChanged`), and then there is nothing
        // left to close.
        let close = app.buttons["call-end"]
        if close.exists { close.tap() }
        XCTAssertTrue(app.buttons["chat-trust"].waitForExistence(timeout: Timeout.screen),
                      "the call screen did not close: " + Diagnosis.of(app))
        try fixture.sync("ended-\(number)")
    }
}

// MARK: - timeouts

/// Every wait in this file, named. They are ceilings on a failure, not
/// expected waits.
private enum Timeout {
    static let screen: TimeInterval = 20
    static let launch: TimeInterval = 60
    static let identity: TimeInterval = 90
    static let registration: TimeInterval = 180
    static let commit: TimeInterval = 60
    /// How long the call screen may take to appear after «Позвонить», and how
    /// long a ring may take to cross the stand.
    static let call: TimeInterval = 60
    static let ring: TimeInterval = 120
    /// ICE, DTLS and the first media packet, over loopback with no relay.
    static let connect: TimeInterval = 120
    /// How long the system's microphone alert may take to appear. It is short
    /// on purpose: on a simulator that was granted the permission before the
    /// run there is no alert at all, and this is then pure waiting.
    static let permission: TimeInterval = 6
    /// How long the phone may take to say «Сервер подключён». It is the
    /// receive lane's first page, which on an idle phone is the long poll's
    /// own timeout rather than anything a test can hurry.
    static let online: TimeInterval = 240
    /// How long the harness may take to answer one request. It is the ceiling
    /// on a barrier the other simulator has not reached yet, which is why it
    /// is minutes rather than seconds.
    static let answer: TimeInterval = 900
}

// MARK: - the fixture

/// What `clients/ios/test_voice_sim.py` hands this test, and the rendezvous
/// back to it.
private struct VoiceFixture {
    let rendezvous: Rendezvous
    let realm: String
    let pin: String
    /// `a` or `b`: which simulator this process drives. It decides who calls
    /// first and nothing else — both sides run the same test.
    let role: String
    /// Where the application writes its Debug media summary
    /// (``CallDiagnostics``). It is a path on the Mac, and the harness reads
    /// the file rather than this process.
    let diagnostics: String

    /// How long a connected call is held before it is ended. It is above
    /// ``silenceSeconds``, so a call that is still up afterwards has been
    /// receiving the peer's heartbeat every ten seconds.
    static let holdSeconds = 40
    /// `CallController.silenceMillis`: how long a call may hear nothing from
    /// the peer before it ends itself.
    static let silenceSeconds = 30

    static func fromEnvironment() throws -> VoiceFixture {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let found = environment[name], !found.isEmpty else { return nil }
            return found
        }
        guard let directory = value("PARANOID_SIM_RENDEZVOUS") else {
            throw XCTSkip("""
                          This scenario needs two simulators and a local stand; \
                          run python3 clients/ios/test_voice_sim.py.
                          """)
        }
        return VoiceFixture(
            rendezvous: Rendezvous(directory: URL(fileURLWithPath: directory, isDirectory: true)),
            realm: try XCTUnwrap(value("PARANOID_SIM_REALM")),
            pin: try XCTUnwrap(value("PARANOID_SIM_PIN")),
            role: try XCTUnwrap(value("PARANOID_SIM_ROLE")),
            diagnostics: try XCTUnwrap(value("PARANOID_SIM_DIAGNOSTICS")))
    }

    /// The application under test, with the stand the harness started and the
    /// Debug diagnostics sink, and no other argument at all.
    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-paranoid-realm", realm, "-paranoid-pin", pin,
                               "-paranoid-call-diagnostics", diagnostics]
        app.launch()
        return app
    }

    // MARK: asking the harness

    @discardableResult
    func ask(_ verb: String, _ argument: String = "") throws -> String {
        try rendezvous.ask(verb, argument, timeout: Timeout.answer)
    }

    /// `xcrun simctl io <udid> screenshot` of **this** side's simulator.
    func shot(_ name: String) throws {
        try ask("shot", name)
    }

    /// One fact for the evidence file.
    func note(_ key: String, _ value: String) throws {
        try ask("note", key + " " + value)
    }

    /// One public fact of this side, for the other one to read.
    func publish(_ key: String, _ value: String) throws {
        try ask("publish", key + " " + value)
    }

    /// The other side's `key`, once it has published it.
    func fetch(_ key: String) throws -> String {
        try ask("fetch", key)
    }

    /// A barrier both sides arrive at. It returns when the second one does.
    func sync(_ name: String) throws {
        try ask("sync", name)
    }

    /// Keeps the call up for `seconds` while the harness counts what the
    /// server stored and photographs both screens.
    func hold(seconds: Int) throws {
        try ask("hold", "\(seconds)")
    }

    /// This side's media summary, as the application wrote it.
    func statistics(_ label: String) throws -> [String: String] {
        let reply = try ask("stats", label)
        var members: [String: String] = [:]
        for field in reply.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { members[String(parts[0])] = String(parts[1]) }
        }
        return members
    }

    /// One counter of that summary, or zero when the report never carried it.
    func number(_ summary: [String: String], _ name: String) -> Int {
        Int(summary[name] ?? "") ?? 0
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
    func wait(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Waits until the call screen says a connected call's elapsed time.
    ///
    /// The line is `"%02d:%02d · %@"` (`Strings.Call.elapsed`), and its right
    /// half is «Соединение установлено» for a call with no camera on it, so
    /// the suffix is what is waited for and the digits are read afterwards.
    @MainActor
    func connected(_ status: XCUIElement, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.exists, status.label.hasSuffix(" · Соединение установлено") { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Answers the system's microphone alert, if this simulator raises one.
    ///
    /// `xcrun simctl privacy … grant microphone` is issued before the run, and
    /// on one of the two simulators it is enough; on the other iOS still asks
    /// the first time an intent reaches `AVAudioApplication`. The alert
    /// belongs to Springboard rather than to the application, so it is
    /// answered where it lives — and answering it is what a user does at
    /// exactly this point: the microphone is granted from an explicit Call or
    /// Answer and from nowhere else (`voice-v1.md`).
    ///
    /// - Parameter shot: the name to photograph the alert under. Nothing is
    ///   photographed when no alert appeared.
    @MainActor
    func grantMicrophone(shot name: String) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: Timeout.permission) else { return }
        try shot(name)
        for title in ["Разрешить", "Allow", "OK"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
        XCTFail("the microphone alert has no «Разрешить»: \(alert.label)")
    }

    /// What the bottom banner said while `arrival` was being waited for, or
    /// the empty string when it said nothing.
    ///
    /// It is the refusal of a call intent — no connection, no microphone — and
    /// it lives three seconds, so it cannot be read after a wait has failed.
    @MainActor
    func refusal(_ app: XCUIApplication, until arrival: XCUIElement) -> String {
        let banner = app.staticTexts["notice"]
        let deadline = Date().addingTimeInterval(Timeout.call)
        while Date() < deadline {
            if arrival.exists { return "" }
            if banner.exists { return banner.label }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ""
    }

    /// How many seconds the connected call on the screen has lasted.
    @MainActor
    func elapsed(_ status: XCUIElement) throws -> Int {
        let label = status.label
        let head = label.prefix(while: { $0 != " " })
        let parts = head.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else {
            XCTFail("«\(label)» is not a connected call's line")
            return 0
        }
        return minutes * 60 + seconds
    }

    // MARK: writing on the screen

    /// Puts the peer's contact into the paste sheet.
    ///
    /// A contact is around 900 bytes of JSON, so it is pasted rather than
    /// typed: the pasteboard is set from this process — a **write**, which
    /// raises no permission alert — and the paste itself is the user's, a
    /// hardware `⌘V`, then the edit menu, then, if a simulator refuses both,
    /// the keyboard. It is `TextFlowUITests.fill`, for the same reason and
    /// with the same assertion: the field holds the contact byte for byte,
    /// because a repaired contact is a different contact.
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
