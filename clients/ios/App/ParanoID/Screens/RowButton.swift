import SwiftUI

/// A list row that is a real button: it shows a grey fill while the finger
/// is on it and answers to one tap, the way Android's rows do with their
/// ripple (`MainActivity.conversationRow`, `:656`,
/// `ripple(colors.canvas,18)`). A row that only listened for a tap gave no
/// sign that the tap had landed, and on a slow open the user could not tell
/// whether it had.
///
/// The button carries the row's accessibility identifier, so a UI test finds
/// one element under `dialog-<account>` — the tappable one — and reads the
/// row's combined label off it.
struct RowButton: ViewModifier {
    let identifier: String
    let action: () -> Void

    func body(content: Content) -> some View {
        Button(action: action) { content }
            .buttonStyle(RowButtonStyle())
            .accessibilityIdentifier(identifier)
    }
}

/// The pressed look of a row: the system's grey (`systemGray5`, darker than
/// the page in light mode and lighter than it in dark) with Android's corner
/// radius while pressed, nothing otherwise. The label keeps its own colours
/// — a custom style is not tinted the way the default one is.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray5) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18))
    }
}

extension View {
    /// Makes this row a button (`RowButton`).
    func rowButton(_ identifier: String, action: @escaping () -> Void) -> some View {
        modifier(RowButton(identifier: identifier, action: action))
    }
}
