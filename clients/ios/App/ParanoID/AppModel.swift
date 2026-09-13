import AVFoundation
import Foundation
import Observation
import ParanoidKit
import UIKit
import WebRTC

/// Everything the screens read and every action they can take.
///
/// It is the iOS counterpart of `MainActivity` plus the part of `TextEngine`
/// that is not the state owner (`clients/android/src/org/paranoid/text`): the
/// screens hold no rule of their own, and this object holds no state of the
/// client. The one copy of that state lives behind `StateOwner`, and every
/// call into it is `await`ed from here — which is why this type is
/// `@MainActor` and none of its members block.
///
/// ## What it owns
///
/// One `Runtime`, built once at launch: the snapshot store over the Keychain
/// key, the `SelfServiceClient`, the state owner, the pinned transport, the
/// two realtime lanes and the lifecycle runner that starts and stops them.
/// Nothing here opens a connection itself; nothing here touches the core
/// except through `StateOwner.perform`.
///
/// ## The two guards
///
/// Both are synchronous, and both are the point of this file:
///
/// - **Sending.** A tap captures the text, clears the composer and marks the
///   send in flight before it awaits anything
///   (`MessagePresentation.Drafts.begin`), so a second tap in the same run
///   loop turn finds the composer empty and the guard closed. One tap, one
///   envelope. A failed send puts the text back.
/// - **«Создать ID».** `isCreating` is set on the tap and cleared only when
///   the owner has answered, so the button is disabled for the whole of
///   `create_identity` → `upgrade_v2` — two durable commits — and a second tap
///   cannot start a second identity (`MainActivity.java:139,343`).
@MainActor
@Observable
final class AppModel {
    /// What the whole application is showing.
    enum Stage: Equatable {
        /// Reading the stored state; the first frame.
        case opening
        /// The screens.
        case running
        /// The local state could not be opened, or a commit failed. Nothing
        /// is deleted and nothing is sent (the mock-up's `frozen`).
        case frozen
        /// A Debug launch with no stand and no `-paranoid-allow-hosted`:
        /// nothing on the device is touched, no identity is created and no
        /// connection is opened. The string says which argument is missing or
        /// malformed, never a value read off the command line.
        case noStand(String?)
    }

    /// The three tabs of the mock-up, which are Android's three navigation
    /// buttons (`MainActivity.java:240`).
    enum Tab: String, CaseIterable {
        case dialogs, contacts, identity
    }

    /// What is presented over the screens.
    enum Sheet: Identifiable, Equatable {
        case add, scan, paste, confirm, connection, about, share
        case details(String)

        var id: String {
            switch self {
            case .add: return "add"
            case .scan: return "scan"
            case .paste: return "paste"
            case .confirm: return "confirm"
            case .connection: return "connection"
            case .about: return "about"
            case .share: return "share"
            case .details(let account): return "details-\(account)"
            }
        }
    }

    /// «Позвонить собеседнику?» / «Видеозвонок собеседнику?»: the confirmation
    /// that carries the privacy sentence, and the only way into a call
    /// (`MainActivity.requestCall`, `MainActivity.java:375-383`).
    ///
    /// The sentence is the message of this alert, so it stands **before**
    /// «Позвонить» and before «Видеозвонок» — never after, and never on a
    /// screen the call has already reached.
    struct CallPrompt: Identifiable, Equatable {
        let account: String
        let video: Bool

        var id: String { "\(account)-\(video)" }
        var title: String { video ? Strings.Call.videoPrompt : Strings.Call.audioPrompt }
        /// `VIDEO_PRIVACY` for a call that also carries a camera,
        /// `VOICE_PRIVACY` otherwise (`MainActivity.java:381`).
        var privacy: String { video ? Strings.videoPrivacy : Strings.voicePrivacy }
        var confirm: String { video ? Strings.Call.videoConfirm : Strings.Call.audioConfirm }
    }

    /// A contact that has been read but not paired: the text exactly as it was
    /// scanned or pasted, and the two members `contact_text_v2` answered with.
    struct PendingContact: Equatable {
        let text: String
        let fingerprint: String
        let account: String
    }

    // MARK: - what the screens read

    private(set) var stage: Stage = .opening
    /// The decoded public view; empty until the first read.
    private(set) var view = ClientView()
    /// The last thing the lanes published (`RealtimeLoop.errorMessage`), or a
    /// local publication of this client.
    private(set) var lastStatus = Strings.Status.openingDetails
    /// The online flag, published without a debounce exactly as the lanes
    /// publish it (`RealtimeLoop.java:237,261-263,280`).
    private(set) var isConnected = false
    /// The local state is frozen: a commit failed, or it never opened.
    private(set) var isBroken = false
    /// The sentence the frozen screen shows under its title.
    private(set) var frozenDetail = Strings.Status.brokenDetails
    /// «Создать ID» is in flight (`MainActivity.java:343`).
    private(set) var isCreating = false
    /// How many envelopes are waiting in the outbox, for the connection sheet.
    private(set) var outboxCount = 0
    /// The contact read but not yet paired.
    private(set) var pendingContact: PendingContact?
    /// The bottom banner, or `nil`.
    private(set) var notice: String?
    /// The names typed for contacts **on this phone**
    /// (`ContactNames`, Android v22). It is a stored property so that a rename
    /// is published to the screens the same way every other change is; the
    /// table itself is read from and written to the application's own
    /// defaults, and it never reaches the snapshot, the core or the network.
    private(set) var contactNames = ContactNames()
    /// The last published call view, or `nil` while this run has never had a
    /// call. It carries no SDP, no ICE credential and neither nonce
    /// (`CallPresentation`).
    private(set) var call: CallPresentation?

    /// The selected tab.
    var tab: Tab = .dialogs
    /// Whether the call screen is on top of everything (Android's
    /// `callDialog`, `MainActivity.java:443`). An ended call keeps it until
    /// «Закрыть», so that the reason can be read.
    var showsCall = false
    /// The confirmation that carries the privacy sentence, or `nil`.
    var callPrompt: CallPrompt?
    /// The microphone was refused. The alert says so and offers Настройки,
    /// which is the only place the answer can be changed
    /// (`MainActivity.java:534`).
    var microphoneRefused = false
    /// The open conversation, or `nil` for the tabs.
    var chatAccount: String?
    /// What is presented over the screens.
    var sheet: Sheet?
    /// The refusal shown inside the scanner or the paste sheet.
    var contactAlert: ContactFlowError?
    /// The composer's text. `Drafts` keeps one of these per conversation.
    var draft = ""

    // MARK: - what it owns

    private let drafts = MessagePresentation.Drafts()
    private var runtime: Runtime?
    private var reload: Task<Void, Never>?
    private var reloadAgain = false
    private var poll: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    /// The pending call intent: the permission, the audio session and the ten
    /// seconds of waiting, as one cancellable piece of work
    /// (`MainActivity.queueCallIntent` / `cancelCallIntent`,
    /// `MainActivity.java:396-441`).
    private var callIntent: Task<Void, Never>?
    /// Which intent the pending work belongs to
    /// (`MainActivity.callIntentGeneration`, `:392-441`). A cancelled task
    /// still runs to its next `await`, and the audio session it would give
    /// back is process-wide: without this token the cleanup of an abandoned
    /// intent would take the session from the intent that replaced it.
    private var callIntentGeneration: UInt64 = 0
    /// The identifier the call screen was last raised for, so that one call
    /// raises it once (`MainActivity.displayedCall`).
    private var shownCall = ""
    /// The camera was on when the application went to the background, so it
    /// comes back on when the application does (`MainActivity.java:700`).
    private var cameraPausedByBackground = false

    /// How long the bottom banner stays (the mock-up's `notice`).
    static let noticeDuration = Duration.seconds(3)
    /// How long an intent waits for a confirmed online lane before it gives
    /// up with «Нет подключения для звонка…» (`MainActivity.java:398,405`).
    static let callIntentWindow = Duration.seconds(10)
    /// How often that wait looks again (`MainActivity.java:417`).
    static let callIntentPoll = Duration.milliseconds(100)
    /// How often the screens re-read the committed state when nothing is
    /// published: Android's `poll` runnable (`MainActivity.java:74`). Every
    /// message, receipt and delivery mark also arrives through the listener,
    /// so this is a backstop rather than the path.
    static let pollInterval = Duration.seconds(3)

    // MARK: - opening the client

    /// Opens the stored state and builds the runtime, once.
    ///
    /// **The stand is decided first**, and it is decided from three things
    /// that have no side effect at all: the launch arguments, the compiled
    /// default and whether a state file is already there. A Debug launch that
    /// names no stand and carries no `-paranoid-allow-hosted` therefore leaves
    /// the device exactly as it found it — no Keychain item, no install
    /// marker, no directory — and says so on `NoStand`, instead of reporting a
    /// storage failure it never had. It is also the only order in which that
    /// screen is reachable at all on an unsigned simulator build, where the
    /// Keychain refuses this application before anything else can.
    ///
    /// Everything after it is the storage rule of
    /// `docs/clients/core/self-service.md`, in the order `StorageGuard`
    /// documents: whether a state file exists is read **before** any key is
    /// created, the install marker decides whether a Keychain item belongs to
    /// this installation, and only then is a key loaded or created. A launch
    /// that finds exactly one of the two freezes; it never starts a new
    /// identity over retained data.
    func start() {
        guard runtime == nil else { return }
        stage = .opening
        do {
            let fixture = try DebugFixture.trust()
            let directory = try DataProtectionFileSystem.applicationSupportDirectory()
            let snapshotExists = SnapshotStore.snapshotExists(in: directory)
            // Saved trust wins, so a container that already holds a state file
            // names its own realm and needs neither a fixture nor a default.
            guard snapshotExists || fixture != nil || ServiceTrust.hostedDefault() != nil else {
                stage = .noStand(nil)
                return
            }
            let continuity = try StorageGuard.start(snapshotExists: snapshotExists,
                                                    marker: InstallMarker())
            guard continuity != .frozen else { return freeze(Strings.Status.brokenDetails) }
            let key = try KeychainKey.standard.loadOrCreate(snapshotExists: snapshotExists)
            let store = SnapshotStore(directory: directory, key: key)
            let saved = try store.load()
            let client = try SelfServiceClient(saved: saved, sink: store, fixture: fixture)
            let built = try Runtime(client: client, model: self)
            runtime = built
            stage = .running
            // The call listeners are installed **before** the lanes start, so
            // that a control inside the first committed candidate cannot
            // arrive with nothing to hand it to.
            Task { [weak self] in
                await built.calls.attach()
                self?.resume()
            }
        } catch let problem as DebugFixtureProblem {
            stage = .noStand(problem.reason)
        } catch SelfServiceError.trustUnavailable {
            stage = .noStand(nil)
        } catch SelfServiceError.unsupportedSnapshot {
            // The retained bytes are left exactly as they are
            // (`SelfServiceClient.java:36-42`).
            freeze(Strings.Status.unsupportedSnapshot)
        } catch {
            freeze(Strings.Status.brokenDetails)
        }
    }

    /// «Повторить открытие» on the frozen screen.
    ///
    /// It retries the *opening*, which is the only thing that can succeed on a
    /// second attempt — a Keychain that was not readable yet, a container that
    /// was still locked. A client that froze because a commit failed stays
    /// frozen for the rest of the process, so this leaves it exactly as it is.
    func retryOpen() {
        guard runtime == nil else { return }
        start()
    }

    private func freeze(_ detail: String) {
        isBroken = true
        frozenDetail = detail
        stage = .frozen
    }

    // MARK: - the foreground

    /// The scene became active or stopped being active.
    ///
    /// It drives only the screens' own re-read. The lanes are started and
    /// stopped by `LifecyclePolicy` through `AppLifecycle`, which subscribes
    /// to the platform's own notifications: two sources for one decision would
    /// be one too many.
    func setForeground(_ active: Bool) {
        poll?.cancel()
        poll = nil
        guard active, stage == .running else { return }
        refresh()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Starts the lanes for the launch that is already in the foreground.
    ///
    /// `AppLifecycle` hears every later `didBecomeActive`, but not the one
    /// that happened before this object existed.
    private func resume() {
        guard let runtime, UIApplication.shared.applicationState != .background else { return }
        runtime.runner.post(.didBecomeActive)
    }

    // MARK: - what the lanes publish

    /// One publication of the realtime lanes, on the main actor.
    ///
    /// Every one of them is followed by a re-read, because the lanes publish
    /// *after* each incoming candidate is sealed, renamed and read back
    /// (`docs/protocol/realtime-v1.md:97-99`): what a screen shows has always
    /// been durable before it was shown.
    fileprivate func published(connected: Bool, status: String) {
        isConnected = connected
        lastStatus = status
        refresh()
    }

    // MARK: - the status line (`MainActivity.java:598-623`)

    /// The line under the title, in Android's order.
    ///
    /// Two of Android's branches have no source here and are therefore not
    /// written: «Сообщения обновлены» and «Подключаемся к серверу…» answer
    /// `TextEngine.sync()` publications («Синхронизация завершена», «Готово»),
    /// and this client has no blocking sync to publish them — its lanes
    /// publish «Подключено» and the failures of
    /// `RealtimeLoop.errorMessage`.
    var statusLine: String {
        var line: String
        if isBroken {
            line = Strings.Status.frozen
        } else if !view.hasIdentity {
            line = Strings.Status.alpha
        } else if !view.isActive {
            line = Strings.Status.registering
        } else if isConnected {
            line = Strings.Status.connected
        } else if lastStatus.hasPrefix("Сообщение сохранено") {
            line = Strings.Status.queued
        } else {
            line = Strings.Status.connecting
        }
        // Android applies this last, over everything else
        // (`MainActivity.java:609`).
        if view.rejectedCount > 0 { line = Strings.Status.rejected }
        return line
    }

    /// The conversation the chat screen is showing.
    var chat: Dialog? {
        guard let chatAccount else { return nil }
        return view.dialog(chatAccount)
    }

    /// What every screen calls this contact: the name typed on this phone if
    /// there is one, and the default label derived from the account if there
    /// is not (`ContactNames.title`, `MainActivity.java:278,566,639`).
    func title(for account: String) -> String {
        contactNames.title(for: account)
    }

    /// The local name alone, empty for a contact that has none. It is what the
    /// rename field starts from (`MainActivity.java:577`).
    func name(for account: String) -> String {
        contactNames.name(for: account)
    }

    /// Whether the composer may send right now (`DialogPolicy.canReply`).
    var canSend: Bool {
        DialogPolicy.canReply(chat, active: view.isActive, broken: isBroken,
                              sending: drafts.isSending) && MessagePresentation.canSend(draft)
    }

    /// The line above the composer (`MainActivity.java:350`).
    var composerHint: String {
        let bytes = MessagePresentation.byteCount(draft)
        if chat?.isBlocked == true { return Strings.Chat.blockedHint }
        if isBroken { return Strings.Chat.brokenHint }
        if bytes > MessagePresentation.byteLimit { return Strings.Chat.tooLong(bytes: bytes) }
        return drafts.isSending ? Strings.Chat.savingHint : ""
    }

    /// Whether the composer's hint is the over-limit one, which is the only
    /// one drawn in the danger colour (`MainActivity.java:351`).
    var isOverLimit: Bool {
        MessagePresentation.byteCount(draft) > MessagePresentation.byteLimit
    }

    // MARK: - actions

    /// «Создать ID» (`MainActivity.java:139`).
    ///
    /// The guard is `isCreating`: it is set synchronously on the tap and
    /// cleared only when the owner has answered, so the two commits of
    /// `create_identity` → `upgrade_v2` run once however many times the button
    /// is pressed.
    func createIdentity() {
        guard !isCreating, !isBroken, !view.hasIdentity, let runtime else { return }
        isCreating = true
        Task {
            do {
                try await runtime.owner.perform { try $0.createIdentity() }
            } catch {
                lastStatus = Strings.Status.unfinished
                await noteFreeze()
            }
            isCreating = false
            // The lanes register this identity on their next cycle
            // (`ProofFlow.connect`); the wake only makes it the next one.
            runtime.loop.wake()
            await reloadNow()
        }
    }

    /// The composer changed. Android does the same on every keystroke
    /// (`MainActivity.java:235`), which is what keeps a draft per conversation
    /// and what moves the revision a failed send is compared against.
    func draftChanged() {
        guard let chatAccount else { return }
        drafts.update(account: chatAccount, text: draft)
    }

    /// Opens a conversation and restores its draft
    /// (`MainActivity.java:323-326`).
    func openChat(_ account: String) {
        if let chatAccount { drafts.update(account: chatAccount, text: draft) }
        chatAccount = account
        draft = drafts.text(for: account)
    }

    /// Leaves the conversation, keeping what was typed in it.
    func closeChat() {
        if let chatAccount { drafts.update(account: chatAccount, text: draft) }
        chatAccount = nil
    }

    /// One tap on «Отправить» (`MainActivity.java:327-335`).
    func send() {
        guard let runtime, let account = chatAccount else { return }
        let allowed = DialogPolicy.canReply(view.dialog(account), active: view.isActive,
                                            broken: isBroken, sending: drafts.isSending)
        guard let ticket = drafts.begin(account: account, text: draft, canReply: allowed) else {
            return
        }
        // Synchronously, before the first `await`: the composer is empty and
        // the button is disabled from this instant.
        draft = ""
        Task {
            do {
                try await runtime.owner.perform { try $0.send(account: ticket.account,
                                                              text: ticket.text) }
                drafts.finished(ticket, committed: true)
                lastStatus = Strings.Status.messageQueued
                runtime.loop.wake()
            } catch {
                drafts.finished(ticket, committed: false)
                lastStatus = Strings.Status.sendUnfinished
                if chatAccount == ticket.account { draft = drafts.text(for: ticket.account) }
                await noteFreeze()
            }
            await reloadNow()
        }
    }

    /// A contact arrived from the scanner or the paste sheet.
    ///
    /// The text is handed on exactly as it came; nothing here repairs it. Two
    /// things can happen before the core sees it: it is recognised as this
    /// device's own contact, which the core cannot tell apart from a contact
    /// of another realm (`ContactFlowError.isOwnContact`), or it goes to
    /// `contact_text_v2` and comes back as a fingerprint to compare.
    func submitContact(_ text: String) {
        guard let runtime else { return }
        if ContactFlowError.isOwnContact(text, ownAccount: view.account, ownContact: view.contact) {
            contactAlert = .ownContact
            return
        }
        Task {
            do {
                let preview = try await runtime.owner.perform { client -> [String: String] in
                    let preview = try client.previewContact(text)
                    return ["fingerprint": preview["fingerprint"] as? String ?? "",
                            "account": preview["account"] as? String ?? ""]
                }
                pendingContact = PendingContact(text: text,
                                                fingerprint: preview["fingerprint"] ?? "",
                                                account: preview["account"] ?? "")
                sheet = .confirm
            } catch {
                contactAlert = ContactFlowError.classify(error)
                await noteFreeze()
            }
        }
    }

    /// «Отпечаток совпадает» (`MainActivity.java:503`): the fingerprint was
    /// compared somewhere else, so this pairing is the verified one.
    func pairPendingContact() {
        guard let runtime, let pending = pendingContact else { return }
        Task {
            do {
                try await runtime.owner.perform { try $0.pair(pending.text, verified: true) }
                pendingContact = nil
                sheet = nil
                tab = .contacts
                runtime.loop.wake()
            } catch {
                contactAlert = ContactFlowError.classify(error)
                await noteFreeze()
            }
            await reloadNow()
        }
    }

    /// «Отмена» anywhere in the contact flow. It changes nothing at all: no
    /// identity, no snapshot, no request.
    func cancelContact() {
        pendingContact = nil
        contactAlert = nil
        sheet = nil
    }

    /// «Заблокировать контакт» / «Разблокировать контакт»
    /// (`MainActivity.java:511-514`).
    func block(account: String, blocked: Bool) {
        guard let runtime else { return }
        Task {
            // A blocked peer loses its readiness slot and its call at once
            // (`TextEngine.java:233`), before the commit that records the
            // block: a call from someone the user has just blocked must not
            // outlive the tap.
            if blocked { await runtime.calls.block(account: account) }
            do {
                try await runtime.owner.perform { try $0.block(account: account,
                                                               blocked: blocked) }
            } catch {
                lastStatus = Strings.Status.unfinished
                await noteFreeze()
            }
            await reloadNow()
        }
    }

    /// «Сохранить» in «Имя контакта» (`MainActivity.java:581`).
    ///
    /// It is the one action of this client that reaches no core, no snapshot
    /// and no connection: the name is written to this application's own
    /// defaults and the screens re-read it from there. An empty or blank name
    /// clears it, and the default label comes back — «Оставьте пустым, чтобы
    /// вернуть имя по умолчанию.»
    func rename(account: String, to name: String) {
        contactNames.rename(name, for: account)
    }

    /// «Копировать контакт» (`MainActivity.java:177,521`).
    func copyContact() {
        guard let contact = view.contact, ContactPasteboard.copy(contact) else { return }
        showNotice(ContactPasteboard.confirmation)
    }

    /// «Повторить подключение» (`MainActivity.java:519`).
    func reconnect() {
        runtime?.loop.wake()
        refresh()
    }

    /// Shows the bottom banner for three seconds.
    func showNotice(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: AppModel.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - calls (`MainActivity.java:361-441,493-545`)

    /// The call machinery of this run, or `nil` before the runtime exists.
    private var calls: CallCoordinator? { runtime?.calls }

    /// Whether a call exists right now — ringing, negotiating or connected.
    var isCallActive: Bool {
        guard let call else { return false }
        return call.state != .idle && call.state != .ended
    }

    /// Whether «Позвонить» and «Видеозвонок» may be tapped
    /// (`MainActivity.buttons()`, `:366-367`). A live call keeps them enabled,
    /// because tapping one is then the way back to the call screen.
    var canCall: Bool {
        isCallActive || DialogPolicy.canReply(chat, active: view.isActive, broken: isBroken,
                                              sending: false)
    }

    /// The line under the name (`MainActivity.callLabel`, `:493-514`), branch
    /// for branch and in the same order.
    var callLabel: String {
        guard let call else { return Strings.Call.ended }
        if call.reconnecting { return Strings.Call.reconnecting }
        switch call.state {
        case .starting: return Strings.Call.starting
        case .authorizing: return Strings.Call.authorizing
        case .outgoing: return Strings.Call.outgoing
        case .incoming: return Strings.Call.incoming
        case .connecting: return Strings.Call.connecting
        case .connected:
            let kind = call.localVideo || call.remoteVideo
                ? Strings.Call.video : Strings.Call.connected
            return Strings.Call.elapsed(seconds: call.elapsedMillis / 1_000, kind: kind)
        case .idle, .ended: break
        }
        switch call.reason {
        case .busy: return Strings.Call.busy
        case .reject: return Strings.Call.rejected
        case .timeout: return Strings.Call.timeout
        case .failed, .unavailable: return Strings.Call.failed
        case .cancel: return Strings.Call.cancelled
        default: return Strings.Call.ended
        }
    }

    /// The trust line of the call screen (`MainActivity.java:522`): the peer's
    /// own label when there is a conversation with it, «Личность не проверена»
    /// when there is not.
    var callTrust: String {
        DialogPolicy.trustLabel(call.flatMap { view.dialog($0.account) })
    }

    /// «Позвонить» / «Видеозвонок» in the chat (`MainActivity.requestCall`).
    ///
    /// A call that already exists is shown rather than started; anything else
    /// opens the confirmation, whose message is the privacy sentence. Nothing
    /// is requested and nothing is sent from here.
    func requestCall(video: Bool) {
        guard let account = chatAccount else { return }
        if isCallActive {
            showsCall = true
            return
        }
        guard DialogPolicy.canReply(view.dialog(account), active: view.isActive,
                                    broken: isBroken, sending: false)
        else { return }
        callPrompt = CallPrompt(account: account, video: video)
    }

    /// «Позвонить» / «Видеозвонок» inside the confirmation: the point at which
    /// the microphone may be asked for (`voice-v1.md:106-108`).
    func confirmCall() {
        guard let prompt = callPrompt else { return }
        callPrompt = nil
        beginCallIntent(account: prompt.account, answer: false, callId: "", video: prompt.video)
    }

    /// «Отмена» in the confirmation. It changes nothing at all.
    func cancelCallPrompt() {
        callPrompt = nil
    }

    /// «Ответить» (`MainActivity.java:463`). It is the only thing that may
    /// create the callee's media, and it asks for the microphone first.
    func answerCall() {
        guard let call, call.state == .incoming else { return }
        beginCallIntent(account: call.account, answer: true, callId: call.callId, video: false)
    }

    /// «Отклонить» while ringing, «Завершить» during a call, «Закрыть» once it
    /// is over (`MainActivity.java:473`).
    func endCall() {
        cancelCallIntent()
        guard isCallActive else {
            showsCall = false
            return
        }
        Task { await calls?.end() }
    }

    /// «К переписке»: the call keeps running behind the conversation.
    func closeCallScreen() {
        showsCall = false
    }

    /// «Выключить микрофон» / «Включить микрофон» (`MainActivity.java:466`).
    func toggleMute() {
        guard let call else { return }
        Task { await calls?.setMuted(!call.muted) }
    }

    /// «Громкая связь» / «Телефонный динамик» (`MainActivity.java:467`).
    func toggleSpeaker() {
        guard let call else { return }
        Task { await calls?.setSpeaker(!call.speaker) }
    }

    /// «Включить камеру» / «Выключить камеру» (`MainActivity.toggleVideo`,
    /// `:385-392`).
    ///
    /// This is the only place the camera is ever requested: never on knock,
    /// never on ring, never on Answer (`call-v2.md:62-64`). A refusal keeps
    /// the call and says so; it changes no section's direction, because camera
    /// state travels as a `media` control and not as a renegotiation.
    func toggleCamera() {
        guard let call, call.state == .connecting || call.state == .connected else { return }
        let wanted = !call.localVideo
        guard wanted else {
            Task { await calls?.setVideo(false) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await AppModel.requestCamera() else {
                showNotice(Strings.Notice.cameraDenied)
                return
            }
            await calls?.setVideo(true)
        }
    }

    /// «Сменить камеру» (`MainActivity.java:470`).
    func switchCamera() {
        Task { await calls?.switchCamera() }
    }

    /// Where a call's video is drawn.
    ///
    /// The renderer crosses to the media engine as an opaque reference and is
    /// touched by libwebrtc alone; this process never sees a frame.
    func attachCallVideo(_ renderer: any RTCVideoRenderer, local: Bool) {
        let surface = CallCoordinator.Surface(renderer)
        Task { [weak self] in
            guard let calls = self?.calls else { return }
            if local { await calls.setLocalSurface(surface) }
            else { await calls.setRemoteSurface(surface) }
        }
    }

    /// The call screen went away: both surfaces are detached before the views
    /// behind them are released.
    func detachCallVideo() {
        Task { [weak self] in
            guard let calls = self?.calls else { return }
            await calls.setLocalSurface(CallCoordinator.Surface(nil))
            await calls.setRemoteSurface(CallCoordinator.Surface(nil))
        }
    }

    /// The application went to the background, or came back
    /// (`MainActivity.java:700,703`, and `call-v2.md`: "The app leaving the
    /// foreground disables the camera (audio continues) and re-enables it on
    /// return").
    ///
    /// It is driven by `.background` alone and never by `.inactive`, because a
    /// permission dialog is not leaving the foreground. The audio keeps
    /// running either way: only the camera stops.
    func setBackground(_ background: Bool) {
        if background {
            guard call?.localVideo == true else { return }
            cameraPausedByBackground = true
            Task { await calls?.setVideo(false) }
            return
        }
        guard cameraPausedByBackground else { return }
        cameraPausedByBackground = false
        guard isCallActive, CallCoordinator.cameraGranted else { return }
        Task { await calls?.setVideo(true) }
    }

    /// «Открыть Настройки» — the application's own page, where a refused
    /// microphone or camera can be given back. Nothing else is ever opened.
    func openSettings() {
        microphoneRefused = false
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// One intent, from the tap to the first control
    /// (`MainActivity.requestMicrophone` → `queueCallIntent` →
    /// `completeCallIntent`, `:396-441`).
    ///
    /// The order is the point of this method:
    ///
    /// 1. the microphone, asked for only here and only from an explicit Call
    ///    or Answer (`voice-v1.md:106-107`);
    /// 2. the camera, and only for a video-call intent — a refusal is never a
    ///    failure, the call simply starts as audio;
    /// 3. the **audio session**, before any control leaves the device;
    /// 4. up to ten seconds of waiting for a confirmed online lane, then
    ///    «Нет подключения для звонка…»;
    /// 5. `start` or `answer`.
    ///
    /// Any new intent cancels this one, and a cancelled intent sends nothing;
    /// it gives the audio session back only while it is still the session's
    /// owner (``ownsCallAudio(_:)``).
    private func beginCallIntent(account: String, answer: Bool, callId: String, video: Bool) {
        cancelCallIntent()
        let generation = callIntentGeneration
        callIntent = Task { [weak self] in
            guard let self else { return }
            guard await AppModel.requestMicrophone() else {
                // The peer is told, so that a refused Answer does not ring on
                // until the other side's own deadline
                // (`CallController.answer(microphonePermission:)`), and it is
                // told about **this** call: a permission dialog can outlive the
                // ring it was raised for — the original expires after 45 s and
                // the peer rings again — and a refusal that reached the newer
                // call would reject a ring the user has not seen yet. Android
                // re-checks the same identifier
                // (`MainActivity.java:600`: `…optString("call_id").equals(permissionCall)`).
                if answer, call?.callId == callId { await calls?.answer(microphone: false) }
                if ownsCallAudio(generation) { await calls?.releaseAudio() }
                guard !Task.isCancelled else { return }
                microphoneRefused = true
                return
            }
            guard !Task.isCancelled else { return }
            var camera = video
            if camera, !CallCoordinator.cameraGranted {
                camera = await AppModel.requestCamera()
                guard !Task.isCancelled else { return }
                if !camera { showNotice(Strings.Notice.cameraDenied) }
            }
            // Before the first `knock`, and before Answer: the `audio`
            // background mode holds nothing without a live session.
            calls?.prepareAudio()
            guard await waitForCallConnection() else {
                if ownsCallAudio(generation) { await calls?.releaseAudio() }
                guard !Task.isCancelled else { return }
                showNotice(Strings.Notice.callOffline)
                return
            }
            if answer {
                guard let call, call.state == .incoming, call.callId == callId else {
                    if ownsCallAudio(generation) { await calls?.releaseAudio() }
                    return
                }
                await calls?.answer(microphone: true)
            } else {
                guard !isCallActive else {
                    if ownsCallAudio(generation) { await calls?.releaseAudio() }
                    return
                }
                await calls?.start(account: account, video: camera)
            }
            showsCall = true
        }
    }

    /// Drops the pending intent, its deadline and its callback
    /// (`MainActivity.cancelCallIntent`, `:392-395`).
    private func cancelCallIntent() {
        callIntent?.cancel()
        callIntent = nil
        callIntentGeneration &+= 1
    }

    /// Whether the audio session an intent prepared is still that intent's to
    /// give back.
    ///
    /// Cancellation does not stop a task at the next line: an abandoned intent
    /// runs on to its cleanup, and `releaseAudio()` refuses only while a call
    /// is already **active** — which a newer intent's own ten seconds of
    /// waiting are not. Deactivating the session there would leave the call
    /// that follows silent for its whole life, because `enableAudio()` needs a
    /// held session and nothing re-arms one for an outgoing call. So the
    /// session goes back only to the intent that still owns it, which is
    /// Android's `intentGeneration == callIntentGeneration` re-check at every
    /// deferred step (`MainActivity.java:427,435`). An intent cancelled with
    /// no successor — «Отклонить», the screen going away — still gives it
    /// back: `callIntent` is `nil` then, and nobody else holds it.
    private func ownsCallAudio(_ generation: UInt64) -> Bool {
        callIntent == nil || generation == callIntentGeneration
    }

    /// Waits for the realtime lane to say it is connected, for at most
    /// ``callIntentWindow`` (`MainActivity.java:405,415-418`).
    private func waitForCallConnection() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: AppModel.callIntentWindow)
        while !isConnected {
            guard !Task.isCancelled, !isBroken, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: AppModel.callIntentPoll)
        }
        return !Task.isCancelled && !isBroken
    }

    /// The call view changed. It is published from the state owner and arrives
    /// here, on the main actor, as one immutable value.
    ///
    /// It is the only member of this type `CallCoordinator` calls, which is
    /// why it is not `fileprivate` like the lanes' own publication.
    func callChanged(_ presentation: CallPresentation) {
        call = presentation
        let live = presentation.state != .idle && presentation.state != .ended
        // One call raises the screen once; «К переписке» may then put it away
        // without it coming back (`MainActivity.java:519`).
        if live, presentation.callId != shownCall {
            shownCall = presentation.callId
            showsCall = true
        }
        if presentation.state == .idle { showsCall = false }
    }

    /// The microphone, asked for exactly once per answer iOS keeps
    /// (`AVAudioApplication`, iOS 17). A refusal is permanent until Настройки.
    static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// The camera, on the same terms. It is asked for only from an explicit
    /// video action and never blocks a call.
    static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - reading the committed state

    /// Re-reads the public view, coalescing the requests that arrive while one
    /// read is in flight.
    func refresh() {
        guard reload == nil else {
            reloadAgain = true
            return
        }
        reload = Task {
            await reloadNow()
            reload = nil
            if reloadAgain {
                reloadAgain = false
                refresh()
            }
        }
    }

    private func reloadNow() async {
        guard let runtime else { return }
        do {
            let state = try await runtime.owner.perform { client -> ClientState in
                ClientState(view: try ClientView.read(client), outbox: try client.pending().count)
            }
            view = state.view
            outboxCount = state.outbox
            if let chatAccount, view.dialog(chatAccount) == nil, !view.dialogs.isEmpty {
                // The conversation disappeared from under the chat screen.
                // Nothing in this client removes one, so this is only ever the
                // first read after a launch into a stale selection.
                self.chatAccount = nil
            }
        } catch {
            await noteFreeze()
        }
    }

    /// Records a freeze that happened behind an operation: a failed commit is
    /// terminal for the rest of the process, and it also takes the application
    /// off the network, because `updateTrust()` is its only source of a realm
    /// (`SelfServiceClient.java:78`).
    private func noteFreeze() async {
        guard let runtime, await runtime.owner.isFrozen else { return }
        lastStatus = Strings.Status.storageStopped
        freeze(Strings.Status.brokenDetails)
    }

    // MARK: - the runtime

    /// The objects built once at launch, in the order they depend on each
    /// other. It is the assembly of `clients/ios/README.md` — store, client,
    /// owner, transport, lanes, lifecycle — and the application holds exactly
    /// one.
    private final class Runtime {
        let owner: StateOwner
        let loop: RealtimeLoop
        let runner: LifecycleRunner
        /// Retained because it holds the three `NotificationCenter` tokens.
        let lifecycle: AppLifecycle
        /// The call machinery: the controller, the TURN lane, the media engine
        /// and the audio session, all on the owner.
        let calls: CallCoordinator

        /// - Parameters:
        ///   - client: the state adapter, handed over for good. It is
        ///     `sending` because `StateOwner` becomes its only caller: the
        ///     compiler refuses this call if anything else could still reach
        ///     the client afterwards, which is the one-way door the owner
        ///     documents.
        ///   - model: where the lanes publish.
        init(client: sending SelfServiceClient, model: AppModel) throws {
            let trust = try client.updateTrust()
            let transport = try RealtimeTransport(realm: trust.realm, pin: trust.pin)
            let signal = WakeSignal()
            let owner = StateOwner(client: client, hook: signal)
            let flow = ProofFlow(owner: owner, transport: transport)
            self.owner = owner
            // The listener is built first and told about the calls last: the
            // online flag it publishes is also the flag that gates the two
            // call intents (`TextEngine.java:109`), and nothing has started a
            // lane yet at this point.
            let listener = Listener(model: model)
            let lanes = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                                     listener: listener, signal: signal)
            loop = lanes
            // The voice lane is deliberately not one of the two text lanes: a
            // 404 on this optional route must not discard a working text
            // session (`voice-turn-v1.md`, `VoiceRelayLane`).
            let relay = VoiceRelayLane(owner: owner, flow: flow, listener: listener)
            let queue = LifecycleRunner(target: lanes)
            runner = queue
            // A live call keeps the lanes up: the policy has the rule and the
            // coordinator is what tells it the call's state.
            let coordinator = CallCoordinator(owner: owner, loop: lanes, runner: queue,
                                              relay: relay, model: model)
            listener.calls = coordinator
            calls = coordinator
            lifecycle = AppLifecycle(runner: queue)
        }
    }
}

/// One read of the committed state, as one `Sendable` value.
///
/// It is what crosses from the state owner to the main actor: a decoded view
/// and a count, never a core reply and never the state text.
private struct ClientState: Sendable {
    let view: ClientView
    let outbox: Int
}

/// The seam between the lanes and the screens.
///
/// A publication happens on the state owner, so it hops to the main actor
/// here and nowhere else. The reference is weak because the lanes outlive a
/// scene and nothing in them should keep the screens' model alive.
///
/// The call machinery is on the other side of it and does **not** hop: the
/// online flag and the loss of authority are already on the owner, which is
/// where `CallController` lives, so they are handed over synchronously —
/// `TextEngine.java:109,111` does the same on Android's main looper. Both are
/// still published to the screens afterwards, so a user sees what a call sees.
/// For the text path `authorizationLost()` remains silent, because it is
/// always followed by a `changed(false, …)` carrying the sentence
/// (`RealtimeLoop.java:83-86,279-280`).
private final class Listener: RealtimeListener, @unchecked Sendable {
    weak var model: AppModel?
    /// Written once, on the main actor, while the runtime is being built and
    /// before any lane exists; read only on the owner afterwards.
    var calls: CallCoordinator?

    init(model: AppModel) {
        self.model = model
    }

    func changed(connected: Bool, status: String) {
        calls?.connection(connected)
        let model = self.model
        Task { @MainActor in model?.published(connected: connected, status: status) }
    }

    func authorizationLost() {
        calls?.authorizationLost()
    }
}
