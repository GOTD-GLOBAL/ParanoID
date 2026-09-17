import ParanoidKit
import SwiftUI

/// The `details` sheet: what is known about one contact, and the three things
/// that can be done about it (`MainActivity.contactDetails()`,
/// `MainActivity.java:563-575`).
///
/// The four rows are Android's four paragraphs, in the mock-up's layout: the
/// trust label, the full account — the whole 64 characters, because this is
/// the one place it is read out loud — what end-to-end encryption does and
/// does not prove **and where the contact's name is kept**, and what the two
/// ticks mean.
///
/// «Переименовать» is Android's positive button and stands first here as well
/// (`MainActivity.renameContact()`): it opens «Имя контакта», a field with the
/// current name in it, and the sentence that says what that name is — shown on
/// this phone only, cleared by leaving the field empty. Nothing about it
/// reaches the peer, the server or the stored state.
///
/// «Заблокировать контакт» asks first, in Android's words: blocking stops new
/// messages and delivery receipts for this contact and keeps the history on
/// the phone (`block_contact_v2`). Unblocking needs no confirmation, exactly
/// as on Android.
struct ContactDetailsSheet: View {
    let account: String
    let dialog: Dialog?
    /// What this contact is called here (`AppModel.title(for:)`).
    let title: String
    /// The local name alone, empty when there is none. It is what the rename
    /// field starts from, so «Сохранить» on an untouched field keeps it.
    let name: String
    /// «Сохранить» in «Имя контакта»; an empty text restores the default.
    let onRename: (String) -> Void
    /// Blocks or unblocks.
    let onBlock: (Bool) -> Void
    /// «Проверить QR» — the add-contact flow again, for a contact whose
    /// fingerprint has not been compared yet.
    let onVerify: () -> Void
    /// «Закрыть».
    let onClose: () -> Void

    @State private var confirmingBlock = false
    /// «Имя контакта» is open.
    @State private var renaming = false
    /// What is in its field. It is seeded from `name` at every opening, so a
    /// cancelled edit leaves nothing behind.
    @State private var draftName = ""

    private var isBlocked: Bool { dialog?.isBlocked == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.bottom, 16)
                card
                Button {
                    draftName = name
                    renaming = true
                } label: {
                    Text(Strings.Details.rename)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 16)
                .accessibilityIdentifier("details-rename")
                Button(action: onVerify) {
                    Text(Strings.Details.verifyQr)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
                .accessibilityIdentifier("details-verify")
                Button {
                    if isBlocked { onBlock(false) } else { confirmingBlock = true }
                } label: {
                    Text(isBlocked ? Strings.Details.unblock : Strings.Details.block)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isBlocked ? Color.accentColor : Color.red)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
                .accessibilityIdentifier("details-block")
                Button(Strings.Details.close, action: onClose)
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.top, 8)
                    .accessibilityIdentifier("details-close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("details")
        .alert(Strings.Details.blockTitle, isPresented: $confirmingBlock) {
            Button(Strings.Details.cancel, role: .cancel) {}
            Button(Strings.Details.blockConfirm, role: .destructive) { onBlock(true) }
        } message: {
            Text(Strings.Details.blockBody)
        }
        // «Имя контакта»: Android's `AlertDialog` with one single-line field,
        // its hint the dialog's own title, «Отмена» and «Сохранить»
        // (`MainActivity.java:576-582`). The field is bounded here as it is
        // there — `ContactNames.normalize` keeps at most
        // `ContactNames.maxLength` code points — and an empty one clears the
        // name instead of storing a blank.
        .alert(Strings.Rename.title, isPresented: $renaming) {
            TextField(Strings.Rename.title, text: $draftName)
                .accessibilityIdentifier("rename-field")
            Button(Strings.Rename.cancel, role: .cancel) {}
            Button(Strings.Rename.save) { onRename(draftName) }
        } message: {
            Text(Strings.Rename.body)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(Strings.Details.trust, DialogPolicy.trustLabel(dialog))
            Divider()
            row(Strings.Details.account, account, monospaced: true)
            Divider()
            row(Strings.Details.encryption, Strings.Details.encryptionBody)
            Divider()
            row(Strings.Details.receipts, Strings.Details.receiptsBody)
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
