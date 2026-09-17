import ParanoidKit
import SwiftUI

/// The `dialogs` screen: «Чаты», the list Android renders in
/// `renderLists()` (`MainActivity.java:545-575`).
///
/// A row is a conversation, and the three things on it come from the core and
/// from this phone alone: the contact's name — the one typed here through
/// «Переименовать», or else the first six characters of the account — the last
/// message as a preview, prefixed «Вы: » when this device wrote it, and either
/// a badge («Проверен», «Блок») or the delivery mark of the last own message.
/// Nothing on this screen is a name a peer chose, and nothing is a time the
/// core does not keep.
///
/// Under the status line stands the one line Android does not have: this
/// client has no background delivery, so «Входящие приходят, пока приложение
/// открыто» takes the place of Android's «Входящие в фоне отключены —
/// включить» banner (`MainActivity.java:150-153`) and opens the connection
/// sheet, which explains it in full.
struct DialogsScreen: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.view.dialogs.isEmpty {
                    EmptyStateCard(title: Strings.Dialogs.emptyTitle,
                                   message: Strings.Dialogs.emptyBody,
                                   action: { model.sheet = .add })
                } else {
                    HStack {
                        Text(Strings.Dialogs.section)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    ForEach(model.view.dialogs) { dialog in
                        ConversationRow(dialog: dialog,
                                        title: model.title(for: dialog.account),
                                        subtitle: model.preview(for: dialog) ?? Self.preview(dialog),
                                        trailing: Self.trailing(dialog))
                        .contentShape(Rectangle())
                        .onTapGesture { model.openChat(dialog.account) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("dialogs")
    }

    /// The preview line of a row (`MainActivity.java:555-556`), for a
    /// conversation whose last event is a message. A call that happened after
    /// it takes the line instead (`AppModel.preview(for:)`).
    static func preview(_ dialog: Dialog) -> String {
        guard let last = dialog.last else { return Strings.Dialogs.startConversation }
        let text = MessagePresentation.preview(last.text)
        return dialog.isOwn(last) ? Strings.Dialogs.ownPreviewPrefix + text : text
    }

    /// The badge or the tick at the end of a row
    /// (`MainActivity.java:567-569`).
    static func trailing(_ dialog: Dialog) -> ConversationRow.Trailing {
        if dialog.isBlocked { return .badge(Strings.Dialogs.blockedBadge) }
        if dialog.isVerified { return .badge(Strings.Dialogs.verifiedBadge) }
        guard let last = dialog.last, dialog.isOwn(last) else { return .none }
        return .receipt(MessagePresentation.mark(last), MessagePresentation.delivery(last))
    }
}

/// One row of «Чаты» or «Контакты» (`MainActivity.conversationRow`,
/// `:561-571`).
struct ConversationRow: View {
    /// What stands at the end of the row.
    enum Trailing: Equatable {
        case none
        /// «Проверен» or «Блок».
        case badge(String)
        /// The mark of the last own message and the words behind it, which is
        /// what VoiceOver reads (`ReceiptMark`).
        case receipt(MessagePresentation.Mark, String)
    }

    let dialog: Dialog
    /// What this contact is called here: the local name if one was typed, and
    /// otherwise the default label (`AppModel.title(for:)`).
    let title: String
    let subtitle: String
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(dialog.account.prefix(2).uppercased())
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            switch trailing {
            case .none:
                EmptyView()
            case .badge(let text):
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .receipt(let mark, let words):
                ReceiptMark(mark: mark, size: 13)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(words)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(minHeight: 74)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dialog-\(dialog.account)")
    }
}

/// The card an empty list shows (`MainActivity.empty`, `:572-576`).
struct EmptyStateCard: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 23, weight: .bold))
                .padding(.top, 20)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Button(action: action) {
                Text(Strings.Contacts.add)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        .padding(.vertical, 12)
    }
}
