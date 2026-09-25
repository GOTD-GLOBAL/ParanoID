import ParanoidKit
import SwiftUI

/// The `chat` screen: the trust banner, the history and the composer
/// (`MainActivity.buildChat()` and `renderHistory()`,
/// `MainActivity.java:216-236,577-595`).
///
/// The history is exactly what the core committed: a bubble per entry, the
/// device's own on the right, and under each own bubble the mark of its state
/// — queued, stored by the server, delivered to the peer's device
/// (``ReceiptMark``). The words behind the three states — «В очереди»,
/// «Сохранено сервером», «Доставлено» — stay as the accessibility label, and
/// the first time a message of this user's reaches the second mark the chat
/// says once that two marks are not "read" (``ReceiptHintCard``). There is no
/// read receipt because the protocol has none. Under each bubble stands the
/// time the phone that wrote or received it saw — the core stores it and never
/// sends it — and a message written before this build, which has no time, is
/// shown without one rather than with a guess.
///
/// Between the bubbles stand the calls this phone has had with this contact
/// (``CallRowView``, ``ParanoidKit/ChatRow``). They are not messages and never
/// become any: the core writes no call history and the server is told nothing
/// about an outcome — each device keeps its own account of the calls it
/// watched, anchored to the message it followed.
///
/// The composer is where the double-tap guard is visible: the button is
/// disabled the instant a send starts, the text is captured and cleared in the
/// same turn of the run loop, and a failed send puts it back
/// (`AppModel.send()`, `MessagePresentation.Drafts.begin`). The byte counter
/// under it measures UTF-8, which is what the core measures
/// (`clean_service.rs:853`), so a message that is about to be refused says so
/// before it is sent rather than after.
struct ChatScreen: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the bottom of the history is on the screen (``bottomId``).
    @State private var isAtBottom = false
    /// Whether the first positioning — at the divider or at the bottom — is
    /// over. Until it is, the bottom may flash by under `defaultScrollAnchor`
    /// and must not count as seen.
    @State private var positioned = false

    /// The one-point view after the last row: when it is on the screen, so is
    /// the newest message. It stands before the receipt card, which may be read
    /// without being scrolled to.
    private static let bottomId = "bottom"

    private var dialog: Dialog? { model.chat }

    /// Everything «seen» depends on, compared as one value so that a change in
    /// any of them — a new message, a scroll, the scene, a call or a sheet over
    /// the chat — asks the question again.
    private struct SeenCondition: Equatable {
        let messages: Int
        let atBottom: Bool
        let positioned: Bool
        let active: Bool
        let covered: Bool

        var isSeen: Bool { atBottom && positioned && active && !covered }
    }

    private var seenCondition: SeenCondition {
        SeenCondition(messages: dialog?.messages.count ?? 0,
                      atBottom: isAtBottom,
                      positioned: positioned,
                      active: scenePhase == .active,
                      covered: model.showsCall || model.sheet != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            trust
            history
            composer
        }
        // SwiftUI propagates an accessibility modifier to every element under
        // the view it is applied to, so a bare `.accessibilityIdentifier` on
        // a screen's root would *replace* the identifier of every control
        // inside it — the composer, the send button and the trust banner
        // would all answer to "chat". `children: .contain` declares this view
        // an accessibility container instead, which is what a `ScrollView`
        // already is: the screen keeps its name and the controls keep theirs.
        // Every screen whose root is a stack does the same.
        .accessibilityElement(children: .contain)
        .navigationTitle(model.title(for: model.chatAccount ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The two ways into a call, in Android's order — audio, then video
            // (`MainActivity.java:143-144`). Neither opens anything: both open
            // the confirmation that carries the privacy sentence.
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.requestCall(video: false) } label: {
                    Image(systemName: "phone")
                }
                .disabled(!model.canCall)
                .accessibilityLabel(Strings.Call.audioAction)
                .accessibilityIdentifier("call-audio")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.requestCall(video: true) } label: {
                    Image(systemName: "video")
                }
                .disabled(!model.canCall)
                .accessibilityLabel(Strings.Call.videoAction)
                .accessibilityIdentifier("call-video")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.sheet = .details(model.chatAccount ?? "") } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Strings.Bar.contactDetails)
                .accessibilityIdentifier("contact-details")
            }
        }
        .accessibilityIdentifier("chat")
    }

    /// The banner over the history (`MainActivity.java:579`).
    private var trust: some View {
        Button { model.sheet = .details(model.chatAccount ?? "") } label: {
            Text(DialogPolicy.trustLabel(dialog) + " · "
                 + (dialog?.isBlocked == true ? Strings.Chat.blocked : Strings.Chat.details))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 20)
        }
        .background(Color(.secondarySystemBackground))
        .accessibilityIdentifier("chat-trust")
    }

    /// The bubbles (`MainActivity.java:584-593`).
    private var history: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.chatRows.isEmpty {
                        Text(Strings.Chat.empty)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 32)
                    }
                    ForEach(model.chatTimeline) { row in
                        switch row.kind {
                        case .day(let title):
                            DaySeparator(title: title)
                                .id(row.id)
                        case .unread:
                            UnreadDivider()
                                .id(row.id)
                        case .message(let message):
                            MessageBubble(message: message, isOwn: dialog?.isOwn(message) == true)
                                .id(message.id)
                        case .call(let record):
                            CallRowView(record: record) {
                                model.requestCall(video: record.video)
                            }
                            .id(record.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .accessibilityHidden(true)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                    if model.showsReceiptHint {
                        ReceiptHintCard { model.dismissReceiptHint() }
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && model.chatUnseenCount > 0 {
                    toNewButton(scroll)
                }
            }
            .onAppear { position(scroll) }
            // A new last message follows the reader down only when the reader
            // is already at the bottom or wrote it: someone scrolled up to read
            // is not pulled away, and the «↓» button says what came.
            .onChange(of: dialog?.messages.last?.id) { _, last in
                guard last != nil, positioned else { return }
                let own = dialog?.last.map { dialog?.isOwn($0) == true } ?? false
                guard own || isAtBottom else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    scroll.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onChange(of: seenCondition, initial: true) { _, condition in
                if condition.isSeen { model.markChatSeen() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.chatResumed() }
            }
        }
    }

    /// Opens the chat at its «Новые сообщения» divider, or at the bottom when
    /// there is none. The bottom counts as seen only after this is over.
    private func position(_ scroll: ScrollViewProxy) {
        positioned = false
        if let divider = model.unreadDivider {
            isAtBottom = false
            scroll.scrollTo(TimelineRow.unreadId(divider), anchor: .top)
        }
        // One layout pass for the scroll to land and for the bottom marker to
        // report where it ended up, before anything is taken as read.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            positioned = true
        }
    }

    /// «↓»: back down to the newest message, with the number of new ones.
    private func toNewButton(_ scroll: ScrollViewProxy) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .default) {
                scroll.scrollTo(Self.bottomId, anchor: .bottom)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground), in: Circle())
                    .shadow(radius: 2)
                Text(Strings.Unread.badge(model.chatUnseenCount))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel(Strings.Unread.toNew)
        .accessibilityValue(Strings.Unread.count(model.chatUnseenCount))
        .accessibilityIdentifier("scroll-to-new")
    }

    /// The composer (`MainActivity.java:227-235,341-352`).
    private var composer: some View {
        VStack(spacing: 0) {
            if !model.composerHint.isEmpty {
                Text(model.composerHint)
                    .font(.system(size: 12))
                    .foregroundStyle(model.isOverLimit ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("compose-hint")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(Strings.Chat.placeholder, text: $model.draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 22))
                    .disabled(model.isBroken || dialog?.isBlocked == true)
                    .accessibilityLabel(Strings.Chat.placeholder)
                    .accessibilityIdentifier("compose-field")
                    .onChange(of: model.draft) { _, _ in model.draftChanged() }
                Button(action: model.send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityLabel(Strings.Chat.sendAction)
                .accessibilityIdentifier("send")
            }
            Text(Strings.Chat.counter(bytes: MessagePresentation.byteCount(model.draft)))
                .font(.system(size: 12))
                .foregroundStyle(model.isOverLimit ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 4)
                .accessibilityIdentifier("compose-counter")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }
}

/// One message (`MainActivity.java:588-592`).
struct MessageBubble: View {
    let message: Message
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(isOwn ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    let time = MessagePresentation.time(message.localMilliseconds)
                    if !time.isEmpty {
                        Text(time)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(isOwn ? Color.white.opacity(0.75) : Color.secondary)
                    }
                    if isOwn {
                        ReceiptMark(mark: MessagePresentation.mark(message))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .accessibilityLabel(MessagePresentation.delivery(message))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(isOwn ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            if !isOwn { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
    }
}
