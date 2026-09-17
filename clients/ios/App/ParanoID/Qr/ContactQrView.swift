import CoreGraphics
import ParanoidKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The other direction of the same string: the contact of this device as a QR
/// code, and the two ways to hand it over as text.
///
/// Everything here starts from one value — the `contact` member of the core's
/// view, sliced out of the reply verbatim by
/// `SelfServiceClient.contactText()`. The QR carries those bytes, the share
/// sheet sends those bytes and the clipboard holds those bytes; nothing
/// re-encodes the JSON on the way. Android reaches the same place through
/// `org.json` (`MainActivity.java:612-614`), which happens to produce the
/// same text today but is a round trip this client does not need to take.
///
/// The code is public material: it proves nothing on its own, and the
/// fingerprint still has to be compared on the other phone
/// (`docs/protocol/first-contact-v1.md:90-91`). The screen around it says so
/// — that text and the banner belong to the `identity` screen.
@MainActor
struct ContactQrView: View {
    /// The exact contact text. A different string means a different code.
    let contact: String

    /// Android's content description of the same image
    /// (`MainActivity.java:170`).
    static let label = "QR моего контакта"

    @State private var rendered: RenderedQr?

    var body: some View {
        ZStack {
            // White behind the code, as Android sets on its `ImageView`
            // (`MainActivity.java:170`): a QR is read as dark on light.
            Color.white
            if let rendered, rendered.contact == contact {
                Image(decorative: rendered.image, scale: 1)
                    .resizable()
                    // Nearest neighbour to the last step as well: a module
                    // must stay a square with hard edges at any size.
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Self.label)
        .accessibilityIdentifier("identity-qr")
        // Regenerated only when the string itself changes, which is Android's
        // `displayedQr` guard (`MainActivity.java:613`).
        .task(id: contact) { rendered = Self.render(contact) }
    }

    private static func render(_ contact: String) -> RenderedQr? {
        // A `paranoid-contact-v2` text is around 900 bytes, so the 2048-byte
        // bound is never the reason this fails; the share and copy buttons
        // beside the card carry the same string if it ever does.
        guard let image = try? QrCodec.image(for: contact) else { return nil }
        return RenderedQr(contact: contact, image: image)
    }

    struct RenderedQr {
        let contact: String
        let image: CGImage
    }
}

/// "Поделиться контактом": the system share sheet with the contact as plain
/// text (`MainActivity.java:175`, `ACTION_SEND` with `text/plain`).
///
/// The item is the `String` itself, so every destination receives the same
/// bytes the QR carries. Nothing is attached beside it: no image of the code,
/// no fingerprint and no account, because a share sheet is the one place in
/// this application where data leaves for a destination the user picks. iOS
/// names the sheet itself, so Android's chooser title ("Поделиться контактом
/// ParanoID") has nothing to correspond to here.
@MainActor
struct ContactShareSheet: UIViewControllerRepresentable {
    let contact: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [contact], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Копировать контакт": the same string on the clipboard
/// (`MainActivity.java:521`, `ClipData.newPlainText`).
@MainActor
enum ContactPasteboard {
    /// The confirmation the banner shows afterwards, word for word Android's
    /// toast (`MainActivity.java:181`).
    static let confirmation = "Контакт скопирован. Сравните отпечаток отдельно."

    /// Puts `contact` on the clipboard as plain text and answers whether
    /// there was anything to copy (`MainActivity.java:521`: an empty value is
    /// ignored).
    ///
    /// `localOnly` keeps the item on this device: a contact is public
    /// material, but Universal Clipboard would copy it to every other device
    /// on the account, and nothing in this client asks for that.
    @discardableResult
    static func copy(_ contact: String) -> Bool {
        guard !contact.isEmpty else { return false }
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: contact]],
            options: [.localOnly: true]
        )
        return true
    }
}
