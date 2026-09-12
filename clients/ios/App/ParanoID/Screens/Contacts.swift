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
struct ContactsScreen: View {
    let model: AppModel

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
                    ForEach(model.view.dialogs) { dialog in
                        ConversationRow(dialog: dialog,
                                        subtitle: DialogPolicy.trustLabel(dialog),
                                        trailing: DialogsScreen.trailing(dialog))
                        .contentShape(Rectangle())
                        .onTapGesture { model.openChat(dialog.account) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("contacts")
    }
}
