import Foundation

/// What the user is told when a scanned or pasted contact is refused.
///
/// The refusal itself always comes from the core: `contact_text_v2` reads the
/// text and `pair_contact_v2` pairs with it
/// (`clients/core/src/clean_service.rs:830-848`), and both answer
/// `{"error":"<code>"}` for anything they will not take — a text that is not a
/// contact, a contact bound to another realm, a peer key that is not canonical
/// (`contact_v2.rs:43-71`), a conversation limit. This type is the one place
/// those codes become a sentence: every refusal a user can understand is
/// named, and one honest fallback names the code instead of guessing.
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
    /// The account is already in the contact list with **other keys**
    /// (`peer_already_pinned`, `clean_service.rs:353-358`). The same QR
    /// scanned again is not refused at all — it only raises the trust of the
    /// saved contact (`:359-362`) — so this is never "already added": it is a
    /// second, different contact for one account, and the saved one is left
    /// exactly as it was.
    case otherKeys
    /// 64 contacts are the most one device keeps (`clean_service.rs:364-365`).
    case contactLimit
    /// The sealed local state would pass its 8 MiB bound
    /// (`clean_service.rs:311-316`).
    case stateFull
    /// This device's registration has not finished. `pair_contact_v2` is
    /// always sent verified, so its `peer_not_verified` means the enrollment
    /// is missing (`clean_service.rs:870-871`); `prepare_contact_first` means
    /// the contact of this device has not been prepared yet (`:183-187`).
    case notRegistered
    /// The contact names another realm or pin, or its keys do not fit
    /// together (`contact_v2.rs:50-59`). This device's own contact fails the
    /// same check and is recognised before the core is asked
    /// (``isOwnContact(_:ownAccount:ownContact:)``).
    case otherServer
    /// The native bridge failed; nothing about the contact is known.
    case internalFailure
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
        case .otherKeys:
            return "Этот аккаунт уже есть в контактах с другими ключами. Сохранённый контакт не изменён: сообщения по-прежнему шифруются для прежних ключей."
        case .contactLimit:
            return "Контакт не добавлен: на этом телефоне достигнут предел числа контактов."
        case .stateFull:
            return "Контакт не добавлен: данные ParanoID на этом телефоне достигли предельного размера."
        case .notRegistered:
            return "Контакт не добавлен: регистрация ID на сервере ещё не завершена. Повторите позже."
        case .otherServer:
            return "Контакт не добавлен: он создан для другого сервера ParanoID или повреждён."
        case .internalFailure:
            return "Контакт не добавлен из-за внутренней ошибки приложения."
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

    /// The refusals that have a sentence of their own.
    private static let namedCodes: [String: ContactFlowError] = [
        "peer_already_pinned": .otherKeys,
        "contact_limit": .contactLimit,
        "local_state_full": .stateFull,
        "peer_not_verified": .notRegistered,
        "prepare_contact_first": .notRegistered,
        "registration_required": .notRegistered,
        "contact_binding_mismatch": .otherServer,
    ]

    /// Maps one refusal of the contact flow.
    ///
    /// A `CoreError.rejected(code)` is classified by that code; anything else
    /// — a frozen client, a bridge failure — keeps its own description, so a
    /// failure that is not the contact's fault is never reported as a bad QR.
    public static func classify(_ error: any Error) -> ContactFlowError {
        if let flow = error as? ContactFlowError { return flow }
        if let core = error as? CoreError, core == .nativeFailure { return .internalFailure }
        guard let core = error as? CoreError, case .rejected(let code) = core else {
            return .refused(label(error))
        }
        if notContactCodes.contains(code) { return .notAContact }
        return namedCodes[code] ?? .refused(code)
    }

    /// A short, non-secret name for a failure that is not a core rejection.
    /// `SelfServiceError`, `StorageError` and `CoreError` all describe
    /// themselves in one lower-case phrase and none of them carries a
    /// snapshot, an account or a key.
    private static func label(_ error: any Error) -> String {
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
