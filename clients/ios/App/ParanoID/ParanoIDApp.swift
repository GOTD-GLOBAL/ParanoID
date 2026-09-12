import SwiftUI

/// Application entry point of the ParanoID iOS client (RFC-0021).
///
/// The screens (`Создать ID`, `Чаты`, `Контакты`, `Мой ID`) arrive with their
/// own pull-request steps; this shell only proves that the project links
/// `ParanoidKit` and starts on the simulator so that `ParanoIDTests` can run
/// inside it.
@main
struct ParanoIDApp: App {
    var body: some Scene {
        WindowGroup {
            Text("ParanoID")
                .font(.title)
                .padding()
        }
    }
}
