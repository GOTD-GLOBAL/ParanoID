import Foundation
import Observation
import ParanoidKit
import UIKit

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

    /// The selected tab.
    var tab: Tab = .dialogs
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

    /// How long the bottom banner stays (the mock-up's `notice`).
    static let noticeDuration = Duration.seconds(3)
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
            runtime = try Runtime(client: client, model: self)
            stage = .running
            resume()
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
            loop = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                                listener: Listener(model: model), signal: signal)
            runner = LifecycleRunner(target: loop)
            lifecycle = AppLifecycle(runner: runner)
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
/// `authorizationLost()` is deliberately not overridden: it is always followed
/// by a `changed(false, …)` carrying the sentence the user is shown
/// (`RealtimeLoop.java:83-86,279-280`).
private struct Listener: RealtimeListener {
    weak var model: AppModel?

    func changed(connected: Bool, status: String) {
        let model = self.model
        Task { @MainActor in model?.published(connected: connected, status: status) }
    }
}
