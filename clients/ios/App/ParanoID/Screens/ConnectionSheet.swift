import SwiftUI

/// The `connection` sheet: what the status line means, opened by tapping it
/// (`MainActivity.connectionDetails()`, `MainActivity.java:517-520`).
///
/// Android puts two sentences in an alert. This client has a third to say, and
/// it is the difference the whole design turns on: there is no background
/// delivery, so incoming messages and calls arrive while the application is
/// open and only then. That paragraph is the mock-up's `connection` screen,
/// and the hint over «Чаты» leads here.
///
/// The three rows under it are facts of this device, not of the server: what
/// was last published, how many envelopes are waiting in the outbox, and how
/// many incoming events the core refused. None of them says whether a peer is
/// online — the sentence above them says as much in Android's words, because a
/// server status that looked like presence would be a promise this protocol
/// does not make.
struct ConnectionSheet: View {
    /// The status line itself, as the header.
    let status: String
    /// The last thing published (`MainActivity.java:607`).
    let lastStatus: String
    /// How many envelopes are waiting to go out.
    let outbox: Int
    /// How many incoming events the core refused.
    let rejected: Int64
    /// «Повторить подключение».
    let onRetry: () -> Void
    /// «Закрыть».
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.Connection.title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 12) {
                    Text(status)
                        .font(.system(size: 22, weight: .bold))
                    Text(Strings.Connection.foreground)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text(Strings.Connection.body)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 0) {
                    row(Strings.Connection.lastEvent, lastStatus)
                    Divider()
                    row(Strings.Connection.queue, Strings.Connection.queued(outbox))
                    Divider()
                    row(Strings.Connection.rejected,
                        rejected > 0 ? String(rejected) : Strings.Connection.none)
                }
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 20))
                .padding(.top, 12)
                Button(action: onRetry) {
                    Text(Strings.Connection.retry)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .padding(.top, 16)
                .accessibilityIdentifier("connection-retry")
                Button(Strings.Connection.close, action: onClose)
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.top, 8)
                    .accessibilityIdentifier("connection-close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("connection")
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
