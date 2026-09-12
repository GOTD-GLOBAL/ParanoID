import SwiftUI

/// The `confirm` sheet: the fingerprint of a contact that has been read but
/// not paired (`MainActivity.confirmContact()`,
/// `MainActivity.java:499-504`).
///
/// This is the one screen where the trust decision is actually taken. The core
/// has already read the text — `contact_text_v2` verified the signature and
/// the binding and answered with a fingerprint and an account — and nothing
/// has been written yet: «Отмена» leaves the device exactly as it was, and
/// «Отпечаток совпадает» is what makes the pairing a verified one
/// (`pair_contact_v2` with `verified: true`).
///
/// The sentence above the digits is Android's and it is the point of the
/// screen: a QR that arrived through a chat proves nothing, because whoever
/// forwarded it could have made it. The comparison has to happen somewhere
/// this application cannot reach — in person, or over a channel that is
/// already trusted (`docs/protocol/first-contact-v1.md:90-91`).
struct ConfirmContactSheet: View {
    /// The fingerprint of the contact, as the core computed it.
    let fingerprint: String
    /// «Отпечаток совпадает».
    let onConfirm: () -> Void
    /// «Отмена».
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.AddContact.confirmTitle)
                .font(.system(size: 20, weight: .bold))
            Text(Strings.AddContact.confirmBody)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Text(fingerprint)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 16)
                .accessibilityIdentifier("confirm-fingerprint")
            HStack {
                Button(Strings.AddContact.cancel, action: onCancel)
                    .font(.system(size: 17))
                    .accessibilityIdentifier("confirm-cancel")
                Spacer()
                Button(Strings.AddContact.confirm, action: onConfirm)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityIdentifier("confirm-pair")
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .accessibilityIdentifier("confirm")
    }
}
