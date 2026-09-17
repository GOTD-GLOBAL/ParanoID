import Foundation

/// What the user is told when a scanned or pasted contact is refused.
///
/// The refusal itself always comes from the core: `contact_text_v2` reads the
/// text and `pair_contact_v2` pairs with it
/// (`clients/core/src/clean_service.rs:830-848`), and both answer
/// `{"error":"<code>"}` for anything they will not take — a text that is not a
/// contact, a contact bound to another realm, a peer key that is not canonical
/// (`contact_v2.rs:43-71`), a conversation limit. This type is the one place
/// those codes become a sentence, and it is deliberately small: three
/// situations a user can do something about, and one honest fallback that
/// names the code instead of guessing.
///
/// Android shows one status line for every one of them
/// (`TextEngine.userError`, `MainActivity.java:499-504`, through
/// `TextEngine.java:198-207`). This client shows a modal alert **inside** the
/// scanner or the paste sheet instead, because the sheet covers the status
/// line and a refusal the user never sees is a refusal that gets scanned
/// again. The sheet stays open until «Понятно»; nothing about the identity,
/// the snapshot or the network changes on the way through — a refused contact
/// was never paired, and cancelling pairs nothing either.
public enum ContactFlowError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The text is not a ParanoID contact at all.
    case notAContact
    /// It is this device's own contact.
    case ownContact
    /// This peer is already in the contact list under different material.
    case alreadyAdded
    /// Anything else the core refused, named by its code.
    case refused(String)

    /// The alert's title. It is the title of the sheet the refusal happened
    /// in, so nothing new is invented for it (`MainActivity.java:487`).
    public static let title = "Добавить контакт"
    /// The one button. The sheet stays open until it is pressed.
    public static let dismiss = "Понятно"

    /// The sentence shown under the title.
    public var message: String {
        switch self {
        case .notAContact:
            return "Это не контакт ParanoID. Попросите собеседника показать QR из «Мой ID»."
        case .ownContact:
            return "Это ваш собственный контакт."
        case .alreadyAdded:
            return "Контакт уже добавлен."
        case .refused(let code):
            return "Не удалось добавить контакт (\(code))."
        }
    }

    public var description: String { message }

    /// The codes that mean "this is not a contact": the text did not parse,
    /// it was longer than a contact may be, it is a QR of another kind, or the
    /// material inside it is not well-formed key material
    /// (`clean_service.rs:830-848`, `contact_v2.rs:61-70`,
    /// `key-protocol/src/lib.rs:52,118,125,153`).
    private static let notContactCodes: Set<String> = [
        "invalid_contact", "qr_limit", "wrong_qr_type", "invalid_credential",
        "invalid_key", "invalid_peer_key", "noncanonical_key",
        "noncanonical_signature", "invalid_signature",
    ]

    /// The code of `add_peer` for a known account whose material changed
    /// (`clean_service.rs:349-352`).
    private static let alreadyAddedCode = "peer_already_pinned"

    /// Maps one refusal of the contact flow.
    ///
    /// A `CoreError.rejected(code)` is classified by that code; anything else
    /// — a frozen client, a bridge failure — keeps its own description, so a
    /// failure that is not the contact's fault is never reported as a bad QR.
    public static func classify(_ error: any Error) -> ContactFlowError {
        if let flow = error as? ContactFlowError { return flow }
        guard let core = error as? CoreError, case .rejected(let code) = core else {
            return .refused(label(error))
        }
        if notContactCodes.contains(code) { return .notAContact }
        if code == alreadyAddedCode { return .alreadyAdded }
        return .refused(code)
    }

    /// A short, non-secret name for a failure that is not a core rejection.
    /// `SelfServiceError`, `StorageError` and `CoreError` all describe
    /// themselves in one lower-case phrase and none of them carries a
    /// snapshot, an account or a key.
    private static func label(_ error: any Error) -> String {
        if let core = error as? CoreError, core == .nativeFailure { return "native_failure" }
        if let described = error as? any CustomStringConvertible { return described.description }
        return String(describing: error)
    }

    /// Whether this text is this device's own contact, decided before the core
    /// is asked.
    ///
    /// The core cannot answer it: a contact of one's own fails
    /// `ContactV2::verify` as `contact_binding_mismatch`
    /// (`contact_v2.rs:50-60`), which is the same code a contact from another
    /// realm gets. Both checks here are read-only and neither changes the text
    /// that is handed on: the first compares it with the string this device
    /// publishes, and the second reads the account out of a copy, so a contact
    /// that was re-encoded on the way — shared as text, pasted back — is still
    /// recognised. Whatever this answers, the bytes the core is given are the
    /// bytes that were scanned.
    public static func isOwnContact(_ text: String,
                                    ownAccount: String,
                                    ownContact: String?) -> Bool {
        if let ownContact, !ownContact.isEmpty, text == ownContact { return true }
        guard !ownAccount.isEmpty,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = object["credential"] as? [String: Any],
              let account = credential["account"] as? String
        else { return false }
        return account == ownAccount
    }
}
