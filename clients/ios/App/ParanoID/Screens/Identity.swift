import SwiftUI

/// The `identity` screen: «Мой ID», the port of
/// `MainActivity.buildIdentity()` (`MainActivity.java:165-190`).
///
/// One value stands behind everything on it: the `contact` member of the
/// core's view, sliced out of the reply byte for byte
/// (`SelfServiceClient.contactText()`). The QR carries those bytes, the share
/// sheet sends those bytes and the clipboard holds those bytes — the code a
/// peer scans and the text a peer pastes are the same string, and it is the
/// one the peer's core verifies.
///
/// The account under the code and the fingerprint below it are public
/// material, and neither of them proves anything on its own: the fingerprint
/// has to be compared on the other phone, which is what the explanation says
/// and what «Отпечаток совпадает» asks about on the other side of the flow
/// (`docs/protocol/first-contact-v1.md:90-91`).
///
/// Two blocks of the Android screen are missing here, and their absence is the
/// iOS difference: there is no update check — builds are installed by hand
/// and no TestFlight build exists yet — and no «Получать в фоне», because this
/// client has no background delivery at all. The note at the bottom says so.
struct IdentityScreen: View {
    let model: AppModel

    /// `share.setEnabled(active && !displayedQr.isEmpty && !broken)`
    /// (`MainActivity.java:344`).
    private var canShare: Bool {
        model.view.isActive && !(model.view.contact ?? "").isEmpty && !model.isBroken
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.Identity.heading)
                    .font(.system(size: 24, weight: .bold))
                Text(Strings.Identity.explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                card
                    .padding(.top, 20)
                Button { model.sheet = .share } label: {
                    Text(Strings.Identity.share)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canShare)
                .padding(.top, 16)
                .accessibilityIdentifier("share-contact")
                Button(action: model.copyContact) {
                    Text(Strings.Identity.copy)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .disabled(!canShare)
                .padding(.top, 8)
                .accessibilityIdentifier("copy-contact")
                fingerprint
                application
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("identity")
    }

    /// The QR card: the code, the caption and the account
    /// (`MainActivity.java:169-172`).
    private var card: some View {
        VStack(spacing: 8) {
            if let contact = model.view.contact, !contact.isEmpty {
                ContactQrView(contact: contact)
                    .frame(maxWidth: 280)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 280)
                    .accessibilityHidden(true)
            }
            Text(Strings.Identity.caption)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text(model.view.account.isEmpty ? Strings.Identity.placeholder : model.view.account)
                .font(.system(size: 14, design: .monospaced))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityIdentifier("identity-account")
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    /// «Отпечаток контакта» (`MainActivity.java:178-179`).
    private var fingerprint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Identity.fingerprint)
                .font(.system(size: 17, weight: .semibold))
            Text(model.view.fingerprint.isEmpty
                 ? Strings.Identity.fingerprintPlaceholder
                 : model.view.fingerprint)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(model.view.fingerprint.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("identity-fingerprint")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    /// «Приложение» (`MainActivity.java:180-183`), without the update block.
    private var application: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Identity.application)
                .font(.system(size: 17, weight: .semibold))
            Text(Strings.Identity.alpha)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button { model.sheet = .about } label: {
                HStack {
                    Text(Strings.Identity.about)
                        .font(.system(size: 17))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("about")
            Text(Strings.Identity.platform)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }
}
