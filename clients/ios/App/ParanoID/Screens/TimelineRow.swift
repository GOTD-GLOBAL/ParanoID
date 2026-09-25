import ParanoidKit
import SwiftUI

/// One line of the open conversation: a message, a call this phone watched, or
/// the pill that says which day the messages under it belong to.
///
/// The day is not a row the core knows about. It is drawn from the times the
/// messages themselves carry, which is why a conversation written before this
/// build — where no entry has a time — shows no pills at all rather than a
/// guess (`AppModel.chatTimeline`).
struct TimelineRow: Identifiable {
    enum Kind {
        case day(String)
        /// «Новые сообщения»: the first message under it arrived after this
        /// run last showed the conversation (`SeenMarks`).
        case unread
        case message(Message)
        case call(CallRecord)

        init(_ row: ChatRow) {
            switch row {
            case .message(let message): self = .message(message)
            case .call(let record): self = .call(record)
            }
        }
    }

    let id: String
    let kind: Kind

    /// The identity of the «Новые сообщения» divider before the message at
    /// `position`. It is also what the chat scrolls to.
    static func unreadId(_ position: Int) -> String { "u:\(position)" }

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    init(id: String, kind row: ChatRow) {
        self.id = id
        self.kind = Kind(row)
    }
}

/// «Новые сообщения»: a thin line with the words in the middle, over the first
/// message this run had not shown when the chat was opened.
struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
            Text(Strings.Unread.divider)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.4)).frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("unread-divider")
    }
}

/// The pill between two days («Сегодня», «Вчера», «12 сентября»).
struct DaySeparator: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}
