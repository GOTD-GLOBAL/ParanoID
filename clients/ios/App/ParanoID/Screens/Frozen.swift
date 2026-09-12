import SwiftUI

/// The `frozen` screen: the local state could not be opened, or a commit
/// failed.
///
/// It is the visible half of the rule the storage layer enforces: any failure
/// of the five durable steps freezes the client for the rest of the process,
/// nothing derived from the failed candidate is adopted or sent, and nothing
/// at all is deleted (`SnapshotStore.commit`, `TextEngine.java:226-237`,
/// `docs/clients/core/self-service.md:97-100`). The same screen answers the
/// two ways a launch can find a state it must not touch: a retained file
/// without its key (or a key without its file), and a snapshot from a build
/// this one cannot read.
///
/// The second line is the one users have to be told before they act: deleting
/// the application does not repair anything, it starts a new identity (D-004,
/// `docs/clients/ios/README.md`). Android says as much in its status line;
/// here it is a sentence of its own, from the mock-up's `frozen` screen.
///
/// «Повторить открытие» retries the *opening* only — a Keychain that was not
/// readable yet, a container still locked after a reboot. A client that froze
/// on a commit stays frozen, and the button leaves it exactly as it is.
struct FrozenScreen: View {
    /// The sentence under the title: the storage one, or the one for a
    /// snapshot of a previous test build (`MainActivity.java:607`).
    let detail: String
    /// «Повторить открытие».
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(Strings.Status.frozen)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .accessibilityIdentifier("status-line")
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
                .frame(width: 72, height: 72)
                .background(Color(.secondarySystemBackground), in: Circle())
                .accessibilityHidden(true)
            Text(Strings.Frozen.title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(Strings.Frozen.reinstall)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(Strings.Frozen.hint)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text(Strings.Frozen.retry)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("frozen-retry")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("frozen")
    }
}
