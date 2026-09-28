import Foundation

/// Why a text the user sent did not become an envelope.
///
/// `send_v2` answers `{"error":"<code>"}` before it commits anything
/// (`clients/core/src/clean_service.rs:880-892`, `enqueue` at `:393-483`), so
/// a refused text is never in the conversation, never in the outbox and never
/// counted as a rejected incoming event. This type turns that code into the
/// situation the chat names above the composer; the words themselves are the
/// application's (`Strings.Chat.Refusal`), like every other caption.
///
/// Android publishes one sentence for all of them to its status line
/// (`TextEngine.java:285-294`), which the chat does not show. The refusals a
/// user can understand are named here; the rest keep Android's sentence
/// (`unfinished`).
public enum SendRefusal: Equatable, Sendable {
    /// 1000 texts have been sent in this conversation. The receipt commitment
    /// each one leaves is never removed, so no further text fits
    /// (`clean_service.rs:410-411,464`).
    case historyFull
    /// 400 envelopes to this contact wait for the server; each one leaves the
    /// outbox when the server accepts it (`clean_service.rs:399-400,913`).
    case outboxFull
    /// The sealed local state would pass its 8 MiB bound with this text in it
    /// (`clean_service.rs:311-317`, checked by `reply` at `:319`).
    case stateFull
    /// The contact is blocked (`clean_service.rs:396-397`).
    case blocked
    /// Empty or above 2048 bytes (`clean_service.rs:888-889`). The composer
    /// refuses both before the core is asked, so this is the core's own
    /// guard answering.
    case invalidText
    /// The text fits 2048 bytes but its sealed introduction does not fit one
    /// envelope (`intro_v2.rs:122-124`).
    case tooLarge
    /// This device is not registered yet (`clean_service.rs:885-886`,
    /// `SelfServiceClient.send`).
    case notRegistered
    /// Anything else: nothing the user can act on is known.
    case unfinished

    /// How many envelopes to one contact the outbox holds before `outbox_full`
    /// (`clean_service.rs:399-400`).
    public static let outboxBound = 400

    /// The refusal of one send, or `nil` when the local state froze: a failed
    /// commit replaces the whole screen, so the chat has nothing to add.
    public static func classify(_ error: any Error) -> SendRefusal? {
        if let service = error as? SelfServiceError {
            switch service {
            case .frozen, .commitFailed: return nil
            case .registrationRequired: return .notRegistered
            default: return .unfinished
            }
        }
        guard let core = error as? CoreError, case .rejected(let code) = core else {
            return .unfinished
        }
        switch code {
        case "local_history_full": return .historyFull
        case "outbox_full": return .outboxFull
        case "local_state_full": return .stateFull
        case "contact_blocked": return .blocked
        case "invalid_text": return .invalidText
        case "introduction_limit": return .tooLarge
        case "registration_required": return .notRegistered
        default: return .unfinished
        }
    }
}
