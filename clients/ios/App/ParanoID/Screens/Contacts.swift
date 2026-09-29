import ParanoidKit
import SwiftUI

/// The `contacts` screen: «Контакты», the second list of `renderLists()`
/// (`MainActivity.java:158-163,550,558`).
///
/// It is the same rows as «Чаты» with the trust line in place of the preview,
/// which is the whole difference between the two screens on Android as well: a
/// contact is a conversation that may have no messages yet, and the line under
/// its name is «Личность проверена» or «Личность не проверена» — a label, not
/// a permission (`DialogPolicy.trustLabel`).
///
/// The explanation under the button is Android's, and it says the one thing a
/// first-time user needs to know: an incoming message does not have to be
/// invited (`docs/protocol/first-contact-v1.md`), so nothing has to be added
/// before a peer can write.
///
/// Two things Android's list does not do: the rows stand in the order of the
/// names this phone gave them (`AppModel.orderedContacts`), and the blocked
/// contacts stand in their own folded section at the bottom, each with
/// «Разблокировать контакт» at hand (`AppModel.blockedContacts`). Android
/// keeps the core's order and a «Блок» badge among the others
/// (`MainActivity.java:640-652,664`); the same request stands for it.
struct ContactsScreen: View {
    let model: AppModel

    /// Whether the blocked section is unfolded. It folds again with the screen.
    @State private var showsBlocked = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button { model.sheet = .add } label: {
                    Text(Strings.Contacts.add)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.view.hasIdentity || model.isBroken)
                .accessibilityIdentifier("add-contact")
                Text(Strings.Contacts.explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                if model.view.dialogs.isEmpty {
                    EmptyStateCard(title: Strings.Contacts.emptyTitle,
                                   message: Strings.Contacts.emptyBody,
                                   action: { model.sheet = .add })
                } else {
                    ForEach(model.orderedContacts) { dialog in
                        row(dialog)
                    }
                    if !model.blockedContacts.isEmpty { blocked }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("contacts")
    }

    /// One row of either list. It is the one place a contact is named here,
    /// so the blocked section names it the same way.
    private func row(_ dialog: Dialog) -> some View {
        ConversationRow(dialog: dialog,
                        title: model.title(for: dialog.account),
                        subtitle: DialogPolicy.trustLabel(dialog),
                        trailing: DialogsScreen.trailing(dialog))
        .contentShape(Rectangle())
        .rowButton("dialog-\(dialog.account)") { model.openChat(dialog.account) }
    }

    /// «Заблокированные (N)», folded until tapped, with «Разблокировать
    /// контакт» under each row — the same action the contact's sheet has.
    private var blocked: some View {
        DisclosureGroup(isExpanded: $showsBlocked) {
            ForEach(model.blockedContacts) { dialog in
                row(dialog)
                Button {
                    model.block(account: dialog.account, blocked: false)
                } label: {
                    Text(Strings.Details.unblock)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 8)
                .accessibilityIdentifier("unblock-\(dialog.account)")
            }
        } label: {
            Text(Strings.Contacts.blocked(count: model.blockedContacts.count))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .padding(.top, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocked-section")
    }
}
