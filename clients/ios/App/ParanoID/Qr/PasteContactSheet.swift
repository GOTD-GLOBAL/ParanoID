import ParanoidKit
import SwiftUI

/// The `paste` screen: a contact that arrives as text rather than through the
/// camera, the port of `MainActivity.pasteContact()`
/// (`MainActivity.java:493-499`).
///
/// The field is wider than a QR on purpose. A QR payload stops at 2048 bytes,
/// but a contact may also be forwarded as a message, and both the core and
/// `docs/protocol/key-enrollment-v1.md:91-96` allow 4096 bytes for a text
/// import — `QrCodec.checkedImport` is that bound, and it hands back the very
/// string it was given.
///
/// What is typed here is not repaired. Leading and trailing whitespace is
/// dropped, because that is what a paste brings along and what Android drops
/// too (`MainActivity.java:498`, `String.trim()`), and JSON has never cared
/// about it; nothing else is touched. The text is not parsed, not re-encoded
/// and not inspected for members: it goes to the core exactly as it stands, so
/// that duplicate or unknown fields fail in Rust's strict typed parser instead
/// of being quietly collapsed on the way (`key-enrollment-v1.md:91-92`).
@MainActor
struct PasteContactSheet: View {
    /// The checked text, unchanged. The fingerprint sheet and
    /// `pair_contact_v2` follow from here.
    let onContinue: (String) -> Void
    /// "Отмена". Nothing has changed.
    let onCancel: () -> Void

    /// Word for word the mock-up's `paste` screen and
    /// `MainActivity.java:494`.
    static let explanation = "Вставьте контакт, которым собеседник поделился из раздела «Мой ID»."
    /// The empty-field error of `MainActivity.java:498`.
    static let empty = "Вставьте контакт собеседника"
    /// Above 4096 bytes this is not a contact at all. The same sentence
    /// answers the core's `invalid_contact`.
    static let refused = "Это не контакт ParanoID. Попросите собеседника показать QR из «Мой ID»."

    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Вставить контакт")
                .font(.system(size: 20, weight: .bold))
            Text(Self.explanation)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            field
            if let problem {
                Text(problem)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                    .accessibilityIdentifier("paste-error")
            }
            HStack {
                Button("Отмена", action: onCancel)
                    .font(.system(size: 17))
                Spacer()
                Button("Продолжить", action: submit)
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 20)
        }
        .padding(20)
        .accessibilityIdentifier("paste")
    }

    /// A multi-line field, no autocorrection and no capitalisation: a contact
    /// is base64 and hexadecimal, and a "helpful" substitution would change
    /// the bytes (`MainActivity.java:496`,
    /// `TYPE_TEXT_FLAG_NO_SUGGESTIONS`).
    private var field: some View {
        TextField(Self.placeholder, text: $text, axis: .vertical)
            .lineLimit(3...6)
            .font(.system(size: 16, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Self.placeholder)
            .accessibilityIdentifier("paste-field")
            .padding(.top, 16)
    }

    private static let placeholder = "Контакт ParanoID"

    /// Trim, measure, hand over. The three failures are told apart because
    /// they are three different mistakes: an empty field, a text that is too
    /// long to be a contact, and — later, in the core — a text that is not a
    /// contact.
    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = Self.empty
            return
        }
        guard let checked = try? QrCodec.checkedImport(trimmed) else {
            problem = Self.refused
            return
        }
        problem = nil
        onContinue(checked)
    }
}
