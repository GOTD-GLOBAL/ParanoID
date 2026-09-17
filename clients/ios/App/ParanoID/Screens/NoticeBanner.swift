import SwiftUI

/// The bottom banner: the three confirmations Android shows as a `Toast`.
///
/// There is no toast on iOS, and a system alert for «Контакт скопирован»
/// would ask the user to dismiss something they already know. This is the
/// mock-up's `notice`: a line over the screen, gone after three seconds
/// (`AppModel.noticeDuration`), that nothing has to be pressed to leave.
///
/// Its three texts are Android's, word for word: the copy confirmation
/// (`MainActivity.java:177`), the call that has no connection to go out on
/// (`:394`) and the microphone that was refused (`:534`). The last two belong
/// to the call flow, which arrives with its own step; the banner that shows
/// them is here because it is the same banner.
///
/// It is announced to VoiceOver as a status rather than as an alert, because
/// it interrupts nothing and cannot be acted on.
struct NoticeBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color(.systemBackground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.label), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("notice")
    }
}
