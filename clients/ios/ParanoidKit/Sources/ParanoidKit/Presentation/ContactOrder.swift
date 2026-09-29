import Foundation

/// The order of «Контакты»: by the name this phone gave each contact, in
/// Russian alphabetical order, the named ones first.
///
/// The core publishes conversations by account identifier
/// (`clean_service.rs:321-326`), which is no order a person can read. This
/// client sorts the contacts by their local name (`ContactNames`) the way a
/// Russian phone book does — case and diacritics aside, numbers by value
/// («2» before «10»), in the order CLDR's Russian collation gives, which
/// puts Latin letters after the Cyrillic ones — and puts the contacts with
/// no name after them, by account, which is the core's own order. Equal names
/// keep the account order, so two «Сергей» stand in a stable order. The
/// names live on this phone only, so the order does too. Android keeps the
/// core's order (`MainActivity.renderLists`); the same request stands for it.
public enum ContactOrder {
    /// The collation: Russian, case-insensitive, diacritic-insensitive,
    /// numbers by value — what the phone's own contacts use.
    private static let locale = Locale(identifier: "ru_RU")
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .numeric]

    /// `dialogs` ordered as above; `name` answers this phone's name for an
    /// account, or the empty string for a contact with none.
    public static func alphabetical(_ dialogs: [Dialog], name: (String) -> String) -> [Dialog] {
        let named = dialogs.filter { !name($0.account).isEmpty }
            .sorted { a, b in
                let order = name(a.account).compare(name(b.account), options: options,
                                                    range: nil, locale: locale)
                return order == .orderedSame ? a.account < b.account : order == .orderedAscending
            }
        let unnamed = dialogs.filter { name($0.account).isEmpty }
            .sorted { $0.account < $1.account }
        return named + unnamed
    }
}
