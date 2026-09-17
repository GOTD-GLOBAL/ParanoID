import Foundation

/// UI-only formatting and in-memory drafts. No keys, wire or snapshot
/// mutations.
///
/// It is `clients/android/src/org/paranoid/text/MessagePresentation.java`,
/// rule for rule and string for string. Everything here is a pure function of
/// what the core already published: nothing formats a date the core does not
/// have, nothing shortens an account into something that could be mistaken for
/// a name, and nothing decides whether a message may be sent — that is
/// `DialogPolicy.canReply`, which this file only measures the text for.
public enum MessagePresentation {
    /// The largest message the core accepts, in UTF-8 bytes
    /// (`clean_service.rs:853`, `MessagePresentation.java:19`).
    public static let byteLimit = 2048

    /// The conversation title: a contact is named by the first six characters
    /// of its account, never by anything a peer chose
    /// (`MessagePresentation.java:11`).
    public static func title(_ account: String) -> String {
        "Контакт " + String(account.prefix(6))
    }

    /// An account shortened for a line that cannot hold 64 characters
    /// (`MessagePresentation.java:12`).
    public static func shortId(_ account: String) -> String {
        guard account.count > 16 else { return account }
        return String(account.prefix(8)) + "…" + String(account.suffix(8))
    }

    /// One line of preview for a conversation row
    /// (`MessagePresentation.java:13-17`).
    ///
    /// Every run of whitespace becomes one space and the ends are trimmed —
    /// `replaceAll("\\s+", " ").trim()` — and the result is cut at 80 code
    /// points, which is where Java counts too (`codePointCount`). Splitting on
    /// the scalar view does both: `split` drops the empty runs, so a leading
    /// or trailing run disappears with them.
    public static func preview(_ text: String) -> String {
        let words = text.unicodeScalars.split(whereSeparator: isJavaWhitespace)
        let line = words.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        guard line.unicodeScalars.count > 80 else { return line }
        return String(String.UnicodeScalarView(line.unicodeScalars.prefix(80))) + "…"
    }

    /// The size the core measures a message by
    /// (`MessagePresentation.java:18`).
    public static func byteCount(_ text: String) -> Int {
        text.utf8.count
    }

    /// Whether this text is one the core would take
    /// (`MessagePresentation.java:19`).
    ///
    /// Blank is refused and the limit is measured on the text **as typed**,
    /// not on a trimmed copy, because the untrimmed text is what is sent.
    public static func canSend(_ text: String) -> Bool {
        !isBlank(text) && byteCount(text) <= byteLimit
    }

    /// The delivery state in words, for the line under a bubble and for the
    /// accessibility label of a tick (`MessagePresentation.java:20-22`).
    public static func delivery(_ message: Message) -> String {
        if message.isDelivered { return "Доставлено" }
        return message.isAccepted ? "Сохранено сервером" : "В очереди"
    }

    /// The mark under an own bubble, as a state rather than a character
    /// (`MainActivity.java:569,592`, Android v23).
    ///
    /// The ladder itself is unchanged and stays the founder-confirmed one of
    /// REQ-MSG-003: queued, stored by the server, delivered to the peer's
    /// device, and nothing above it — this client has no read receipt to show.
    /// What changed is only the drawing: the screens paint a shape for each
    /// case instead of typing «…», «✓» and «✓✓» into the bubble, and the words
    /// of ``delivery(_:)`` stay as the accessibility label so VoiceOver still
    /// reads the state out loud.
    public enum Mark: String, Sendable, Equatable, CaseIterable {
        /// Not yet stored by the server.
        case queued
        /// One mark: durable server acceptance.
        case stored
        /// Two marks: the peer's device acknowledged it. Never "read".
        case delivered
    }

    /// The mark of one own message (`MainActivity.java:666`).
    public static func mark(_ message: Message) -> Mark {
        if message.isDelivered { return .delivered }
        return message.isAccepted ? .stored : .queued
    }

    /// `\s` as `java.util.regex` defines it: the six ASCII characters, and no
    /// other space. Swift's `Character.isWhitespace` is a wider set, and a
    /// preview that collapsed a non-breaking space would differ from the
    /// Android one for the same message.
    private static func isJavaWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r": return true
        default: return false
        }
    }

    /// `String.trim().isEmpty()`: Java trims every character at or below
    /// U+0020, so the trimmed text is empty exactly when no character is
    /// above it.
    private static func isBlank(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value > 0x20 }
    }

    /// One tap on «Отправить», named so that the answer that comes back can be
    /// matched to it (`MessagePresentation.java:23-27`).
    ///
    /// `revision` is the draft counter at the instant the composer was
    /// cleared. A restore after a failure compares it: if the user has typed
    /// something else since, the counter has moved and the failed text is
    /// **not** put back over what they wrote.
    public struct Ticket: Equatable, Sendable {
        /// The conversation this text was written in.
        public let account: String
        /// The text, exactly as it was typed — untrimmed, because that is
        /// what the core is given.
        public let text: String
        /// The draft counter this ticket was minted at.
        public let revision: Int64

        fileprivate init(account: String, text: String, revision: Int64) {
            self.account = account
            self.text = text
            self.revision = revision
        }
    }

    /// The unsent text of every conversation, and the one send that may be in
    /// flight (`MessagePresentation.java:28-46`).
    ///
    /// This is the double-tap guard of the client, and it is a guard rather
    /// than a debounce: `begin` is synchronous, so the second of two taps in
    /// the same run loop turn finds `isSending` already true and returns `nil`
    /// — there is no interval in which two taps both pass. Android reaches the
    /// same place through `DialogPolicy.canReply(..., drafts.sending())` and
    /// `drafts.started(ticket)` (`MainActivity.java:327-333`).
    ///
    /// iOS differs from Android in one visible way, which is this client's
    /// rule (step 30): the composer is cleared at the instant of the tap
    /// rather than when the commit returns, and a failed send puts the text
    /// back. Android leaves the text in the field until the commit lands.
    /// Everything else — one pending send, the revision check before a
    /// restore, no text kept for an empty account — is unchanged.
    @MainActor
    public final class Drafts {
        private var texts: [String: String] = [:]
        private var revisions: [String: Int64] = [:]
        private var revision: Int64 = 0
        private var pending: Ticket?

        public init() {}

        /// Whether a send of this user's is in flight
        /// (`MessagePresentation.java:33`).
        public var isSending: Bool { pending != nil }

        /// The unsent text of `account`, or the empty string.
        public func text(for account: String) -> String {
            texts[account] ?? ""
        }

        /// Records what the user has typed (`MessagePresentation.java:37-40`).
        /// An empty account keeps nothing, and an unchanged text moves no
        /// counter.
        public func update(account: String, text: String) {
            guard !account.isEmpty, self.text(for: account) != text else { return }
            revision += 1
            texts[account] = text
            revisions[account] = revision
        }

        /// One tap on «Отправить».
        ///
        /// It captures the text, clears the composer and marks the send as
        /// pending — all three synchronously, before any `await` — and answers
        /// the ticket to send under. `nil` means the tap did nothing at all:
        /// the dialog refuses replies, a send is already in flight, or the
        /// text is blank or above 2048 bytes.
        public func begin(account: String, text: String, canReply: Bool) -> Ticket? {
            guard canReply, !isSending, MessagePresentation.canSend(text) else { return nil }
            update(account: account, text: text)
            clear(account)
            let ticket = Ticket(account: account, text: text, revision: revision)
            pending = ticket
            return ticket
        }

        /// The answer to `begin` (`MessagePresentation.java:35`).
        ///
        /// A committed send leaves the cleared composer alone. A failed one
        /// puts the text back, unless the user has typed something else into
        /// that conversation while it was in flight.
        public func finished(_ ticket: Ticket, committed: Bool) {
            guard pending == ticket else { return }
            pending = nil
            guard !committed, revisions[ticket.account] == ticket.revision else { return }
            revision += 1
            texts[ticket.account] = ticket.text
            revisions[ticket.account] = revision
        }

        private func clear(_ account: String) {
            revision += 1
            texts.removeValue(forKey: account)
            revisions[account] = revision
        }
    }
}
