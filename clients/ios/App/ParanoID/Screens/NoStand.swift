import SwiftUI

/// The stand guard: a Debug launch that names no server shows this and does
/// nothing else.
///
/// It is the visible half of `ServiceTrust.hostedDefault()`: a Debug build has
/// no compiled realm, so with neither `-paranoid-realm`/`-paranoid-pin` nor
/// `-paranoid-allow-hosted` there is nothing to dial and no identity is
/// created. That is deliberate and it is what keeps every simulator run on the
/// local stand (`clients/ios/local_stand.py --print-descriptor`) and off the
/// hosted alpha, which has exactly one account and no reserve.
///
/// A Release build never reaches this screen: it starts from the compiled
/// hosted default, exactly as the Android build does
/// (`KeyClient.java:9-10`).
///
/// The reason line names the argument that is missing or malformed. It never
/// echoes a value that was read from the command line.
struct NoStandScreen: View {
    /// What was wrong, when the launch named half a stand.
    let reason: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color(.secondarySystemBackground), in: Circle())
                .accessibilityHidden(true)
            Text(Strings.NoStand.title)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            #if DEBUG
            Text("\(DebugFixture.realmArgument) <https origin>\n\(DebugFixture.pinArgument) <64 hex>")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #endif
            if let reason {
                Text(reason)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("no-stand-reason")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A container keeps the identifiers inside it only when it is one
        // (`Screens/Chat.swift`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("no-stand")
    }
}
