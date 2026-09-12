import SwiftUI

/// The `add` sheet: the two ways a contact can arrive
/// (`MainActivity.addContact()`, `MainActivity.java:485-491`).
///
/// Both lead to the same place — a text that goes to `contact_text_v2`
/// unchanged — and neither of them changes anything on its own: «Отмена» here,
/// in the scanner or in the paste field leaves the identity, the snapshot and
/// the network exactly as they were.
struct AddContactSheet: View {
    /// «Сканировать QR».
    let onScan: () -> Void
    /// «Вставить контакт».
    let onPaste: () -> Void
    /// «Отмена».
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(Strings.AddContact.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
            Divider()
            Button(action: onScan) {
                Text(Strings.AddContact.scan)
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .accessibilityIdentifier("add-scan")
            Divider()
            Button(action: onPaste) {
                Text(Strings.AddContact.paste)
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .accessibilityIdentifier("add-paste")
            Divider()
            Button(action: onCancel) {
                Text(Strings.AddContact.cancel)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .accessibilityIdentifier("add-cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .accessibilityIdentifier("add")
        .presentationDetents([.height(280)])
    }
}
