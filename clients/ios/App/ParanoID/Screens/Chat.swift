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

    private var dialog: Dialog? { model.chat }

    var body: some View {
        VStack(spacing: 0) {
            trust
            history
                // The keyboard follows the finger down the history, as it
                // does in the system's own Messages.
                .scrollDismissesKeyboard(.interactively)
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
                    if model.showsReceiptHint {
                        ReceiptHintCard { model.dismissReceiptHint() }
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: dialog?.messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation { scroll.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    /// The composer (`MainActivity.java:252-260,372-384`).
    ///
    /// What is sent is the draft trimmed at its ends
    /// (`MessagePresentation.trimmed`), and the byte counter under the field
    /// measures that; it stands from 1800 bytes, when the limit is close
    /// enough to matter, and turns red over it. A short message is not told
    /// how short it is. Dragging the history down takes the keyboard with it.
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
            // The counter stands only near the limit: from 1800 bytes in a
            // warning colour, red over 2048 (`MessagePresentation.showsCounter`).
            if MessagePresentation.showsCounter(model.draft) {
                Text(Strings.Chat.counter(bytes: MessagePresentation.bytesToSend(model.draft)))
                    .font(.system(size: 12))
                    .foregroundStyle(model.isOverLimit ? Color.red : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 4)
                    .accessibilityIdentifier("compose-counter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }
}

/// One message (`MainActivity.java:704-717`).
///
/// The bubble is as wide as its text and no wider, up to the room the row
/// leaves it: Android wraps the bubble around its content with a 40 dp
/// margin on the far side (`:707`), and this row is the same — the spacer is
/// the margin, the outer frame is a cap, and the bubble inside it takes the
/// width its text needs. A bubble that stretched to the row made «ок» a
/// full-width plate. Inside, the text stands at the leading edge and the
/// footer — the time, and the delivery mark of an own message — at the
/// trailing edge, as in Android's column with its `END` footer row
/// (`:706-716`); ``BubbleLayout`` does that without a spacer, which would
/// take the row again.
struct MessageBubble: View {
    let message: Message
    let isOwn: Bool

    /// The cap on the bubble. Android caps the text at `dp(440)`
    /// (`MainActivity.java:708`), which the row's room reaches first on any
    /// phone; this cap is on the bubble with its padding, and the 160 dp
    /// floor of that rule is not reproduced.
    static let maxWidth: CGFloat = 440

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            bubble
                .frame(maxWidth: Self.maxWidth, alignment: isOwn ? .trailing : .leading)
            if !isOwn { Spacer(minLength: 40) }
        }
    }

    /// The bubble itself, one accessibility element carrying the text, the
    /// time and the delivery words, and the element whose frame is the
    /// bubble's — which is what the simulator flow measures.
    private var bubble: some View {
        BubbleLayout {
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(isOwn ? Color.white : Color.primary)
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
        .accessibilityElement(children: .combine)
    }
}

/// The two rows of a bubble — the text and its footer — as wide as the wider
/// of the two: the text at the leading edge, the footer at the trailing edge.
///
/// A stack cannot lay this out without a spacer, and a spacer takes all the
/// width the row proposes, which is the plate this layout exists to remove.
/// Here the text is measured at the proposed width, so a long one wraps
/// there, and the footer at its own size; the bubble is the wider of the two
/// and their heights, and nothing in it asks for more. Android's column does
/// the same with a wrap-content body and a full-width `END` footer row
/// (`MainActivity.java:706-716`).
struct BubbleLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (text, footer) = sizes(proposal.width, subviews)
        let gap = footer.height > 0 ? spacing : 0
        return CGSize(width: max(text.width, footer.width),
                      height: text.height + gap + footer.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (text, footer) = sizes(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(text))
        let gap = footer.height > 0 ? spacing : 0
        subviews[1].place(at: CGPoint(x: bounds.maxX - footer.width,
                                      y: bounds.minY + text.height + gap),
                          proposal: ProposedViewSize(footer))
    }

    /// The text at the proposed width (it wraps there) and the footer at its
    /// own size.
    private func sizes(_ width: CGFloat?, _ subviews: Subviews) -> (CGSize, CGSize) {
        guard subviews.count == 2 else { return (.zero, .zero) }
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let footer = subviews[1].sizeThatFits(.unspecified)
        return (text, footer)
    }
}
