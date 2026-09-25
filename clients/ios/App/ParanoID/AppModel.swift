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
    /// table itself is read from and written to a backup-excluded file of the
    /// application's own, and it never reaches the snapshot, the core or the
    /// network. Before successful bootstrap it has no persistent store.
    private(set) var contactNames = ContactNames(store: nil)
    /// Whether this phone still owes its owner the sentence that two marks are
    /// not "read" (`ReceiptHint`). Unlike the metadata tables, it lives in the
    /// application's own defaults and reaches neither the snapshot nor the
    /// network.
    private(set) var receiptHint = ReceiptHint()
    /// Which incoming messages this run has not shown yet (`SeenMarks`). It is
    /// in memory only: no file, no defaults, no snapshot, no request, and the
    /// peer is never told anything about reading (REQ-MSG-003).
    private(set) var seenMarks = SeenMarks()
    /// Where the open chat draws «Новые сообщения»: the position of its first
    /// new message when it was opened, kept while it stays open so that the
    /// line does not vanish the moment it is read.
    private(set) var unreadDivider: Int?
    /// The calls this phone has had (`CallLog`). Like the names it lives in a
    /// backup-excluded file of the application's own: the core keeps no call
    /// history and the server is told nothing about an outcome.
    private(set) var callLog = CallLog(store: nil)
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
    ///
    /// Every way into a chat writes this — `openChat`, and the navigation
    /// binding directly — so this is where the chat's «Новые сообщения»
    /// divider is fixed: once, when the conversation changes, and not when
    /// the screen reappears from under the call screen or a sheet.
    var chatAccount: String? {
        didSet {
            guard chatAccount != oldValue else { return }
            unreadDivider = chat.flatMap { seenMarks.firstUnseenIndex($0) }
        }
    }
    /// What is presented over the screens.
    var sheet: Sheet?
    /// The refusal shown inside the scanner or the paste sheet.
    var contactAlert: ContactFlowError?
    /// The composer's text. `Drafts` keeps one of these per conversation.
    var draft = ""

    // MARK: - what it owns

    /// Bootstrap seam for isolated app tests; nil keeps the device storage path.
    private let openClient: (() throws -> sending SelfServiceClient)?

    /// Stored as a factory, never invoked by construction or screen reads.
    /// Tests inject private suites/directories without touching the app container.
    private let loadLocalMetadata: () -> (ContactNames, CallLog)
    private var localMetadataLoaded = false

    init(openClient: (() throws -> sending SelfServiceClient)? = nil,
         loadLocalMetadata: @escaping () -> (ContactNames, CallLog) = { (ContactNames(), CallLog()) }) {
        self.openClient = openClient
        self.loadLocalMetadata = loadLocalMetadata
    }

    private func loadLocalMetadataOnce() {
        guard !localMetadataLoaded else { return }
        let (names, calls) = loadLocalMetadata()
        contactNames = names
        callLog = calls
        localMetadataLoaded = true
    }

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
    /// How many times the scene has been reported as on the screen or off it.
    /// It only grows, and it is what lets the state owner apply those reports
    /// in the order they were taken (``setBackground(_:)``).
    private var screenPhase: UInt64 = 0

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
    /// this installation. The store loads a retained key only beside its file;
    /// a new key is deferred until first commit, never created on Welcome.
    /// A launch that finds exactly one half freezes, including old eager-key
    /// installs; it never starts a new identity over lost retained state.
    func start() {
        guard runtime == nil else { return }
        stage = .opening
        do {
            let client: SelfServiceClient
            if let openClient {
                client = try openClient()
            } else {
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
                let store = SnapshotStore(directory: directory, keyStore: KeychainKey.standard)
                let saved = try store.load()
                client = try SelfServiceClient(saved: saved, sink: store, fixture: fixture)
            }
            let built = try Runtime(client: client, model: self)
            seenMarks = built.seenBaseline.map { SeenMarks(opening: $0) } ?? SeenMarks()
            // No migration until stand, continuity and runtime construction succeeded.
            // Every noStand/frozen early exit leaves both stores in-memory only.
            loadLocalMetadataOnce()
            runtime = built
            // Only a successfully rebuilt initial runtime clears a bootstrap
            // failure. A failed commit retains its runtime and cannot get here.
            isBroken = false
            isConnected = false
            frozenDetail = Strings.Status.brokenDetails
            lastStatus = Strings.Status.openingDetails
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
        cancelCallIntent()
        isConnected = false
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
    ///
    /// It is `internal` rather than `fileprivate` only so that the tests can
    /// publish the way the lanes do — a green status line is a state no
    /// screen can put this object into, and it is the state a reconnect has to
    /// leave.
    func published(connected: Bool, status: String) {
        guard !isBroken else { return }
        isConnected = connected
        lastStatus = status
        refresh()
    }

    /// The lanes were asked to connect again, and nothing has come back yet.
    ///
    /// The lanes publish only what they have actually seen: a delivered page
    /// (`ReceiveLane.swift:444`) or an accepted envelope (`SendLane.swift:349`).
    /// A start and a restart are neither, so without this the status line
    /// would keep whatever it last said — «Сервер подключён» for a connection
    /// that ended while the application was away, or the «Нет подключения»
    /// of a lane that failed over an interface the device no longer has — until
    /// the next page came back, which is the 25 seconds of the owner's report
    /// of 2026-09-13. Android says the same thing in the same situation and
    /// calls it «Подключаемся…» — when a screen starts listening and at the
    /// end of every operation that is not connected (`TextEngine.java:196,221`).
    ///
    /// It publishes no green state of its own, because there is none to
    /// publish: `isConnected` is what «Сервер подключён» is drawn from, and
    /// only a page or an envelope may set it. This says the honest thing
    /// instead — the client is connecting — and `statusLine` turns that into
    /// the caption the mock-up gives it.
    ///
    /// - Parameter resumed: whether the lanes had been **stopped** until now.
    ///   Android's split, exactly: `stopConnection()` clears `connected` and
    ///   tells the call machinery (`TextEngine.java:198`), while `publish(…)`
    ///   and `restart()` leave it alone, so «Сервер подключён» stands across a
    ///   change of network until the new generation's first page either
    ///   confirms it or fails. Keeping a restart out of that flag is what this
    ///   parameter is for: it is not only the status line but the gate
    ///   ``waitForCallConnection()`` spins on for the whole `callIntentWindow`,
    ///   and it is the one view of the connection `CallController` is *not*
    ///   told about here — only `Listener.changed` reaches both at once. A
    ///   client whose route changed twice in a row would otherwise refuse an
    ///   outgoing call while its pages were arriving normally.
    func publishConnecting(resumed: Bool) {
        guard !isBroken else { return }
        if resumed { isConnected = false }
        lastStatus = Strings.Status.connecting
    }

    // MARK: - the status line (`MainActivity.java:681-684`)

    /// The line under the title, in Android's order.
    ///
    /// Two of Android's branches have no source here and are therefore not
    /// written: «Сообщения обновлены» and «Подключаемся к серверу…» answer
    /// `TextEngine.sync()` publications («Синхронизация завершена», «Готово»),
    /// and this client has no blocking sync to publish them — its lanes
    /// publish «Подключено» and the failures of
    /// `RealtimeLoop.errorMessage`.
    var statusLine: String {
        AppModel.statusLine(broken: isBroken, view: view, connected: isConnected,
                            lastStatus: lastStatus)
    }

    /// The same rule over its four inputs alone.
    ///
    /// It is a function of them and of nothing else, which is what `static`
    /// and `nonisolated` say here: the caption a user is left looking at after
    /// a pause or a change of network is a table a test can drive, without a
    /// core, a store and a socket behind it — the reason `DialogPolicy` and
    /// `LifecyclePolicy` are values too.
    nonisolated static func statusLine(broken: Bool, view: ClientView, connected: Bool,
                                       lastStatus: String) -> String {
        var line: String
        if broken {
            line = Strings.Status.frozen
        } else if !view.hasIdentity {
            line = Strings.Status.alpha
        } else if !view.isActive {
            line = Strings.Status.registering
        } else if connected {
            line = Strings.Status.connected
        } else if lastStatus.hasPrefix("Сообщение сохранено") {
            line = Strings.Status.queued
        } else {
            line = Strings.Status.connecting
        }
        // Android applies this last, over everything else
        // (`MainActivity.java:683`).
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
    /// backup-excluded file and the screens re-read it from there. An empty or blank name
    /// clears it, and the default label comes back — «Оставьте пустым, чтобы
    /// вернуть имя по умолчанию.»
    func rename(account: String, to name: String) {
        contactNames.rename(name, for: account)
    }

    /// One finished call, from the call controller's terminal transition.
    ///
    /// The row is anchored to the last message the conversation has right now,
    /// which preserves its position without inventing a call timestamp
    /// (`ChatRow.rows(messages:calls:)`).
    func callFinished(_ termination: CallTermination) {
        let anchor = CallLog.anchor(messages: isBroken ? nil : view.dialog(termination.account)?.messages)
        callLog.record(termination.record(afterMessageId: anchor))
    }

    /// The open conversation as the chat draws it: the core's messages with
    /// this phone's calls standing where they happened.
    var chatRows: [ChatRow] {
        ChatRow.rows(messages: chat?.messages ?? [],
                     calls: callLog.records(for: chatAccount ?? ""))
    }

    /// The same rows with a day pill before every message that opens a day the
    /// one before it did not.
    ///
    /// Only messages carry a time, so only a message opens a day; a call row
    /// stands where its anchor put it and never moves a separator. A message
    /// written by a build that kept no time opens nothing either — there is no
    /// day to name for it (`MessagePresentation.startsNewDay`).
    var chatTimeline: [TimelineRow] {
        Self.timeline(chatRows, now: UInt64(max(0, Date().timeIntervalSince1970 * 1000)),
                      dividerBefore: unreadDivider)
    }

    /// The rows of a conversation with its day pills and, when there is one,
    /// the «Новые сообщения» divider.
    ///
    /// The divider stands immediately before the message at position
    /// `dividerBefore` in the history — after the calls anchored to the message
    /// before it, and after that message's day pill, so the pill still opens
    /// the day and the line still points at the first new message. Its identity
    /// is its position (`TimelineRow.unreadId`), never a message identifier,
    /// which the sender chooses.
    nonisolated static func timeline(_ rows: [ChatRow], now: UInt64,
                                     dividerBefore: Int?) -> [TimelineRow] {
        var timeline: [TimelineRow] = []
        var previous: UInt64 = 0
        var position = 0
        for row in rows {
            if case .message(let message) = row {
                if MessagePresentation.startsNewDay(message.localMilliseconds, after: previous) {
                    let title = MessagePresentation.daySeparator(message.localMilliseconds, now: now)
                    if !title.isEmpty { timeline.append(TimelineRow(id: "d:" + message.id, kind: .day(title))) }
                }
                if message.localMilliseconds > 0 { previous = message.localMilliseconds }
                if position == dividerBefore {
                    timeline.append(TimelineRow(id: TimelineRow.unreadId(position), kind: .unread))
                }
                position += 1
            }
            timeline.append(TimelineRow(id: row.id, kind: row))
        }
        return timeline
    }

    // MARK: - new messages

    /// How many messages of `dialog`'s peer this run has not shown yet — the
    /// count on its row of «Чаты».
    func unseenCount(for dialog: Dialog) -> Int {
        seenMarks.unseenCount(dialog)
    }

    /// The same for the open chat, for its «↓» button.
    var chatUnseenCount: Int {
        chat.map { seenMarks.unseenCount($0) } ?? 0
    }

    /// The bottom of the open chat was on the screen, with the application
    /// active and nothing over the chat: everything it holds has been seen.
    ///
    /// It is the one mutation of «Новые сообщения», and it reaches no core, no
    /// snapshot, no connection and no peer — only this object's memory.
    func markChatSeen() {
        guard let chat else { return }
        seenMarks.markSeen(chat)
    }

    /// The application came back while a chat was open. A chat that had no
    /// divider gets one if something new arrived in the meantime; one that
    /// had a divider keeps it where it was.
    func chatResumed() {
        guard unreadDivider == nil, let chat else { return }
        unreadDivider = seenMarks.firstUnseenIndex(chat)
    }

    /// When the last message of a conversation happened, as its row says it:
    /// the time today, «Вчера» yesterday, the date before that, and nothing at
    /// all for untimed history or a row whose preview is an untimed call.
    func listTime(for dialog: Dialog) -> String {
        guard let last = dialog.last else { return "" }
        return MessagePresentation.listTime(last.localMilliseconds,
                                            now: UInt64(max(0, Date().timeIntervalSince1970 * 1000)),
                                            isCallPreview: preview(for: dialog) != nil)
    }

    /// The preview of one conversation row: the last call when it is newer than
    /// the last message, and the last message otherwise.
    func preview(for dialog: Dialog) -> String? {
        guard let call = callLog.records(for: dialog.account).last else { return nil }
        // A call recorded after the newest message is what the row should say;
        // an older one stays in the chat and out of the list.
        guard call.afterMessageId == dialog.last?.id else { return nil }
        return Strings.CallRow.line(kind: call.kind, video: call.video,
                                    seconds: call.durationSeconds)
    }

    /// Whether the open conversation shows the sentence about the second mark.
    ///
    /// It is earned rather than scheduled: the chat says it the first time a
    /// message of this user's is actually acknowledged by the peer's device, so
    /// the marks it explains are on the screen while it is read.
    var showsReceiptHint: Bool {
        receiptHint.isPending && ReceiptHint.isEarned(chat)
    }

    /// «Понятно» under that sentence. It does not come back, including after a
    /// relaunch.
    func dismissReceiptHint() {
        receiptHint.dismiss()
    }

    /// «Копировать контакт» (`MainActivity.java:177,521`).
    func copyContact() {
        guard let contact = view.contact, ContactPasteboard.copy(contact) else { return }
        showNotice(ContactPasteboard.confirmation)
    }

    /// «Повторить подключение» (`MainActivity.java:586`).
    ///
    /// Android's retry is `TextEngine.sync()` → `startConnection()` →
    /// `realtime.start()` + `kick()` (`TextEngine.java:249-251,199`), and on a
    /// thread-based loop that is a reconnection: `start()` ends in
    /// `lifecycle.notifyAll()` (`RealtimeLoop.java:57`), so a receive lane
    /// parked in `lifecycle.wait()` leaves its backoff at once, and `kick()`
    /// releases the send gate.
    ///
    /// The same user intent needs a different mechanism here, because the
    /// concurrency model differs. A wake arms the send lane's signal and
    /// nothing else; it cannot free a receive lane suspended in a `URLSession`
    /// long poll or in `Backoff`'s sleep, and with an empty outbox a
    /// successful send pass publishes nothing at all — so the button used to
    /// change nothing a user could see. Only a new generation plus
    /// `transport.cancelActive()` ends those two waits, which is
    /// `RealtimeLoop.restart()` (`RealtimeLoop.java:59-67`).
    ///
    /// That is a sharper instrument than Android's button, so it carries
    /// Android's own gate for it. `restart()` "bumps the generation and
    /// abandons an in-flight voice relay request/long-poll, which froze call
    /// setup in v20/v21 (owner report 2026-09-12)", and `pushWake()` therefore
    /// refuses it whenever `callActive||callDraining||connected`
    /// (`TextEngine.java:184-187`). A tap during call setup is exactly when
    /// that matters: the credential reply is dropped by
    /// `StateOwner.deliverRelay`'s generation guard, nothing re-requests it,
    /// and the call ends at the 45-second timeout. So a call that exists, or a
    /// connection that is working, gets Android's harmless half — the kick —
    /// and everything else gets the restart the user is asking for. A path
    /// monitor reporting that the route really changed is not gated, on either
    /// platform: `onAvailable` restarts a live loop with a call on it.
    ///
    /// The restart is asked for through the runner and never of the loop
    /// directly: the lanes' task returns once its generation is superseded, and
    /// the runner is what owns that task and relaunches it, so a restart taken
    /// behind its back would leave the lanes enabled with nothing running them.
    /// The runner has one event for "these running lanes are dialling over
    /// something that no longer works", and a user pressing this button is
    /// asserting exactly that about a path the monitor cannot see is broken —
    /// the row is `isRunning → .restart`, so a frozen or paused client is
    /// still left alone.
    func reconnect() {
        if isCallActive || isConnected {
            runtime?.loop.wake()
        } else {
            runtime?.runner.post(.networkChanged)
        }
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
    ///
    /// The confirmation hands in the prompt it was built from rather than
    /// leaving this to read ``callPrompt`` back: `.alert(item:)` clears its
    /// own binding as the alert is dismissed and runs the button's action
    /// afterwards, so a confirmation that read the model would find nothing
    /// there and the call would never be placed — which is what two
    /// simulators found (`clients/ios/test_voice_sim.py`). It is also the
    /// stricter rule for a consent screen: the call that is placed is the call
    /// whose privacy sentence was on the screen, and not whatever the model
    /// holds a moment later.
    func confirmCall(_ prompt: CallPrompt) {
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
        guard let call, isCallActive else {
            showsCall = false
            return
        }
        Task { await calls?.end(callId: call.callId, generation: call.generation) }
    }

    /// «К переписке»: the call keeps running behind the conversation.
    func closeCallScreen() {
        showsCall = false
    }

    /// «Выключить микрофон» / «Включить микрофон» (`MainActivity.java:466`).
    func toggleMute() {
        guard let call else { return }
        Task { await calls?.setMuted(!call.muted, callId: call.callId, generation: call.generation) }
    }

    /// «Громкая связь» / «Телефонный динамик» (`MainActivity.java:467`).
    func toggleSpeaker() {
        guard let call else { return }
        Task { await calls?.setSpeaker(!call.speaker, callId: call.callId, generation: call.generation) }
    }

    /// «Включить камеру» / «Выключить камеру» (`MainActivity.toggleVideo`,
    /// `:385-392`).
    ///
    /// This is the only place the camera is ever requested: never on knock,
    /// never on ring, never on Answer (`call-v2.md:62-64`). A refusal keeps
    /// the call and says so; it changes no section's direction, because camera
    /// state travels as a `media` control and not as a renegotiation.
    ///
    /// The action carries the call it was taken in, and every line below is
    /// why: a permission dialog can be answered minutes later, the hop onto
    /// the state owner is another suspension, and this call may be over and
    /// replaced by a call with a different peer before either completes.
    /// Granting the camera permission is the user letting this application see
    /// a camera at all; it is not the user turning a camera on in whichever
    /// call happens to be live when the answer arrives. The owner re-checks
    /// the generation with the live call in hand
    /// (``CallController/video(_:generation:)``).
    func toggleCamera() {
        guard let call, call.state == .connecting || call.state == .connected else { return }
        let generation = call.generation
        let wanted = !call.localVideo
        guard wanted else {
            Task { await calls?.setVideo(false, generation: generation) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await AppModel.requestCamera() else {
                showNotice(Strings.Notice.cameraDenied)
                return
            }
            await calls?.setVideo(true, generation: generation)
        }
    }

    /// «Сменить камеру» (`MainActivity.java:470`).
    ///
    /// It names its call for the same reason the toggle above does: the hop
    /// onto the state owner is a suspension, and the invariant is that every
    /// camera action carries the call it was taken in — including the one that
    /// cannot open a camera, so there is no action left that a later call can
    /// inherit.
    func switchCamera() {
        guard let generation = call?.generation else { return }
        Task { await calls?.switchCamera(generation: generation) }
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
    /// (`MainActivity.java:700,703`, and `call-v2.md:67-69`: "The app leaving
    /// the foreground disables the camera (audio continues) and re-enables it
    /// on return if the user had it on").
    ///
    /// It is driven by `.background` alone and never by `.inactive`, because a
    /// permission dialog is not leaving the foreground. The audio keeps
    /// running either way: only the camera stops.
    ///
    /// No camera is remembered here, and that is the point. "The user had it
    /// on" is a fact about one particular call, and the call it was true of can
    /// end while the application is away — the peer hangs up, the ring times
    /// out, another call takes its place. A flag on this object could only
    /// record *that* a camera was on, never whose, and a return to the screen
    /// would hand it to whatever call was live by then. The intent therefore
    /// lives on the call itself, on the state owner
    /// (``CallController/foreground(_:phase:)``).
    ///
    /// What *is* kept here is which report this is. Whether the application is
    /// on the screen is durable state rather than a one-shot command, and the
    /// four reports of one trip to the background reach the owner through
    /// unstructured tasks that the language does not order against each other,
    /// so the number is what the owner sorts them by. It is minted on this
    /// actor, before the first suspension, exactly as `toggleCamera` reads its
    /// generation there.
    func setBackground(_ background: Bool) {
        screenPhase += 1
        let phase = screenPhase
        Task { await calls?.setForeground(!background, phase: phase) }
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
        // Capture consent on this main-actor turn, before permission/network
        // waits. The controller revalidates both values on its final owner hop.
        let answerGeneration = answer && call?.callId == callId ? call?.generation : nil
        guard !answer || answerGeneration != nil else { return }
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
                if answer, let answerGeneration, call?.callId == callId,
                   call?.generation == answerGeneration {
                    await calls?.answer(microphone: false, callId: callId, generation: answerGeneration)
                }
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
            let deadline = ContinuousClock.now.advanced(by: Self.callIntentWindow)
            guard await calls?.prepareAudio() == true else {
                if ownsCallAudio(generation) { await calls?.releaseAudio() }
                guard !Task.isCancelled else { return }
                showNotice(Strings.Notice.audioUnavailable)
                return
            }
            guard await waitForCallConnection(until: deadline) else {
                if ownsCallAudio(generation) { await calls?.releaseAudio() }
                guard !Task.isCancelled else { return }
                showNotice(Strings.Notice.callOffline)
                return
            }
            if answer {
                guard let call, let answerGeneration, call.state == .incoming,
                      call.callId == callId, call.generation == answerGeneration else {
                    if ownsCallAudio(generation) { await calls?.releaseAudio() }
                    return
                }
                await calls?.answer(microphone: true, callId: callId, generation: answerGeneration)
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
    private func waitForCallConnection(until deadline: ContinuousClock.Instant) async -> Bool {
        while !isConnected {
            guard !Task.isCancelled, !isBroken, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: AppModel.callIntentPoll)
        }
        return !Task.isCancelled && !isBroken && ContinuousClock.now < deadline
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
        /// The conversations as the state stood before anything started, or
        /// `nil` when they could not be read (`SeenMarks`).
        let seenBaseline: [Dialog]?

        /// - Parameters:
        ///   - client: the state adapter, handed over for good. It is
        ///     `sending` because `StateOwner` becomes its only caller: the
        ///     compiler refuses this call if anything else could still reach
        ///     the client afterwards, which is the one-way door the owner
        ///     documents.
        ///   - model: where the lanes publish.
        init(client: sending SelfServiceClient, model: AppModel) throws {
            let trust = try client.updateTrust()
            // What «Новые сообщения» counts from: every conversation as this
            // run found it. It is read here, while the client still has one
            // caller and before a lane or a lifecycle notification can exist,
            // so nothing a lane fetches can slip into the baseline and be taken
            // for seen. Only the dialogs are read: `contactText()` throws on a
            // device with no identity yet, and a fresh install must still count
            // what arrives after it registers. A failed read leaves no baseline,
            // which counts nothing.
            seenBaseline = (try? client.publicView()).map { ClientView.decode($0).dialogs }
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
            // The runner drives the lanes through `AnnouncedLanes`, so that a
            // start and a restart say so on screen; everything else here holds
            // the loop itself, which is the thing that sends and receives.
            let queue = LifecycleRunner(target: AnnouncedLanes(lanes: lanes, model: model))
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

/// The lanes, with the one thing they cannot say about themselves said for
/// them.
///
/// `RealtimeLoop` publishes through its listener, and it publishes only what
/// it has seen: a delivered page (`ReceiveLane.swift:444`) or an accepted
/// envelope (`SendLane.swift:349`). Being started and being restarted are
/// neither — nothing has been sent or received yet — so they publish nothing,
/// and the status line and the connection sheet keep whatever they last said.
/// After a pause that is «Сервер подключён» for a connection that no longer
/// exists; after a walk out of Wi-Fi it is the «Нет подключения» of a lane
/// that failed over an interface the device has given up. Both are read by a
/// user as the client's opinion of *now*.
///
/// This is where that is answered, and it is answered where the decision is
/// actually taken rather than where an event is posted: `LifecycleRunner`
/// calls `start()` and `restart()` exactly when `LifecyclePolicy` has decided
/// on one, so a network change that finds the lanes stopped — the background,
/// a frozen client — announces nothing, because nothing is being connected.
///
/// It wraps rather than replaces: every member forwards, and `stop()` and
/// `run(under:)` are handed over untouched. Android publishes from the two
/// places that ask for a connection and from no other — `listen()` and the end
/// of every `submit()` (`TextEngine.java:196,221`), both of them
/// «Подключаемся…» — and it clears the online flag in one place that is
/// neither of them, `stopConnection()` (`:198`). The two announcements here
/// keep that split: only the one that follows a pause touches the flag.
final class AnnouncedLanes: LifecycleTarget, @unchecked Sendable {
    private let lanes: any LifecycleTarget
    /// Weak for the reason `Listener` is: the lanes outlive a scene, and
    /// nothing in them should keep the screens' model alive.
    private weak var model: AppModel?

    init(lanes: any LifecycleTarget, model: AppModel) {
        self.lanes = lanes
        self.model = model
    }

    func start() async -> Generation {
        // The lanes were stopped until now, which on Android is where
        // `connected` was cleared (`stopConnection()`, `TextEngine.java:198`);
        // this is the first moment a foreground-only client can say so.
        await announce(resumed: true)
        return await lanes.start()
    }

    func stop() async {
        await lanes.stop()
    }

    @discardableResult
    func restart() async -> Generation? {
        await announce(resumed: false)
        return await lanes.restart()
    }

    func run(under generation: Generation) async {
        await lanes.run(under: generation)
    }

    /// Says that the client is connecting, before the lanes are asked to.
    ///
    /// It is awaited rather than left to a `Task` of its own, and that is the
    /// whole reason it is `async`. The lanes publish from a second,
    /// independent hop (`Listener.changed`), and two unstructured tasks have
    /// no order on the main actor: a page delivered immediately after a
    /// restart could be overwritten by an announcement created before it, and
    /// the sheet would read «Подключение» for a client that is connected until
    /// the next long poll returned. Finishing here means every publication the
    /// lanes make afterwards is, by construction, afterwards.
    private func announce(resumed: Bool) async {
        let model = self.model
        await MainActor.run { model?.publishConnecting(resumed: resumed) }
    }
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
