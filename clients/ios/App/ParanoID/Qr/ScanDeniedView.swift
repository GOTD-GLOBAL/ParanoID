import SwiftUI
import UIKit

/// The `scan-denied` screen: what the scanner becomes when the camera is not
/// this application's to open.
///
/// iOS asks for the camera once. After a refusal `authorizationStatus(for:)`
/// answers `.denied` for good — and `.restricted` when a policy on the device
/// decides it — so there is nothing left to request and no reason to show a
/// black preview. The screen says what happened and offers the two ways
/// forward: Настройки, the only place the answer can be changed, and the paste
/// field, which needs no camera at all.
///
/// Android's scanner says the same thing in one status line — "Камера не
/// разрешена. Отмена сохраняет вашу идентичность; можно вставить публичный
/// код." (`QrScanActivity.java:34`) — and the promise behind it holds here
/// too: leaving this screen changes nothing. No identity is created, no
/// contact is paired and no snapshot is written on the way out.
@MainActor
struct ScanDeniedView: View {
    /// "Вставить контакт" — the same paste sheet the add-contact sheet opens.
    let onPaste: () -> Void
    /// "Отмена".
    let onCancel: () -> Void

    /// The refusal, word for word from the mock-up's `scan-denied` screen.
    static let message = "Нет доступа к камере. Разрешите доступ в Настройках или вставьте контакт текстом."

    var body: some View {
        VStack(spacing: 0) {
            QrScannerBar(onCancel: onCancel)
            VStack(spacing: 0) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 72)
                    .background(Color(.secondarySystemBackground), in: Circle())
                    .accessibilityHidden(true)
                Text(Self.message)
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Button(action: openSettings) {
                    Text("Открыть Настройки")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
                Button(action: onPaste) {
                    Text("Вставить контакт")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
        }
        .accessibilityIdentifier("scan-denied")
    }

    /// The application's own page in Настройки, where the camera switch is.
    /// Nothing else is opened from this client: no web page, no store, no
    /// third-party scanner.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
