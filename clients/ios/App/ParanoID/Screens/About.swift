import SwiftUI

/// «О приложении» (`MainActivity.showAbout()`, `MainActivity.java:280-286`).
///
/// Android reaches it through the overflow menu, which also holds «Проверить
/// обновления»; this client has no update check at all, so the entry lives on
/// «Мой ID» and the menu does not exist. The contents are Android's: the
/// version, the identity fingerprint — «появится после регистрации» until
/// there is one — and what a closed alpha means.
struct AboutSheet: View {
    /// The contact fingerprint, or empty before registration.
    let fingerprint: String
    /// «Закрыть».
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.About.title)
                    .font(.system(size: 20, weight: .bold))
                Text(Strings.About.version)
                    .font(.system(size: 17))
                    .padding(.top, 16)
                Text(Strings.About.fingerprintHeading)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                Text(fingerprint.isEmpty ? Strings.About.fingerprintPlaceholder : fingerprint)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 4)
                    .accessibilityIdentifier("about-fingerprint")
                Text(Strings.About.alpha)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                Button(Strings.About.close, action: onClose)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.top, 24)
                    .accessibilityIdentifier("about-close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("about-sheet")
    }
}
