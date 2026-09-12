import SwiftUI

/// The `welcome` screen: the only thing a device with no identity shows.
///
/// It is `MainActivity.buildWelcome()` (`MainActivity.java:134-142`) with the
/// same four texts and the same single action. «Создать ID» is disabled while
/// it runs — the label becomes «Создаём ID…» — because the two commits behind
/// it (`create_identity`, then `upgrade_v2`) must happen once, however many
/// times the button is pressed (`MainActivity.java:343`).
///
/// Nothing here asks for a phone number, an email or a password, and nothing
/// here is optional: the sentences under the button say where the keys stay
/// and what a closed alpha means, and they are Android's, word for word.
struct WelcomeScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 88, height: 88)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 26))
                        .accessibilityHidden(true)
                    Text(Strings.Welcome.title)
                        .font(.system(size: 34, weight: .bold))
                        .padding(.top, 28)
                    Text(Strings.Welcome.body)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.top, 16)
                    Button(action: model.createIdentity) {
                        Text(model.isCreating ? Strings.Welcome.creating : Strings.Welcome.create)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCreating || model.isBroken || model.view.hasIdentity)
                    .padding(.top, 28)
                    .accessibilityIdentifier("create-id")
                    Text(Strings.Welcome.keys)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                    Text(Strings.Welcome.alpha)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            Text(model.statusLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
                .accessibilityIdentifier("status-line")
        }
        // A container keeps the identifiers inside it only when it is one
        // (`Screens/Chat.swift`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
    }
}
