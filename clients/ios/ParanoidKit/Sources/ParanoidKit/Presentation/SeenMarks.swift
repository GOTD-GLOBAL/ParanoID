import Foundation

/// Which incoming messages this run of the application has not shown yet.
///
/// It is the whole of «Новые сообщения»: the count on a row of «Чаты», the
/// divider in the chat and the way back down to it. It lives **in memory
/// only**, like the composer's drafts (`MessagePresentation.Drafts`): nothing
/// here is written to a file, to defaults, to the snapshot or to the network,
/// and nothing about reading ever reaches the peer or the server — two marks
/// mean delivered, never read (REQ-MSG-003). What a relaunch loses is exactly
/// that: a message received in an earlier run and never opened is not counted
/// in the next one.
///
/// A mark is a **position** in a conversation's history, not an identifier.
/// The history only grows at its end (`clean_service.rs`), and an incoming
/// identifier is the sender's choice — the core checks its form and that
/// `sender:id` is new, so it may equal one of ours. A position has neither
/// problem.
///
/// The baseline is every conversation as the first read of this run found it:
/// what was there is not new, and what arrives after it is. A conversation that
/// appears later — a first contact — is new from its first message. Without a
/// baseline (``init()``) nothing is counted at all: an unknown is not a claim
/// that something is new.
public struct SeenMarks: Equatable, Sendable {
    /// For each conversation, how many history entries have been seen.
    private var seen: [String: Int]
    /// Whether a baseline was taken; without one nothing is counted.
    public let isActive: Bool

    /// No baseline yet: nothing is new.
    public init() {
        seen = [:]
        isActive = false
    }

    /// The baseline of this run: everything in `dialogs` has been seen.
    public init(opening dialogs: [Dialog]) {
        seen = Dictionary(dialogs.map { ($0.account, $0.messages.count) },
                          uniquingKeysWith: { max($0, $1) })
        isActive = true
    }

    /// How many messages of `dialog` written by the peer have not been seen.
    public func unseenCount(_ dialog: Dialog) -> Int {
        guard let start = start(dialog) else { return 0 }
        return dialog.messages[start...].reduce(0) { $0 + (dialog.isOwn($1) ? 0 : 1) }
    }

    /// The position of the first message written by the peer that has not
    /// been seen, or `nil` when there is none.
    public func firstUnseenIndex(_ dialog: Dialog) -> Int? {
        guard let start = start(dialog) else { return nil }
        return dialog.messages[start...].firstIndex { !dialog.isOwn($0) }
    }

    /// Everything `dialog` holds right now has been seen. The mark only moves
    /// forward, so a stale read cannot bring a message back.
    public mutating func markSeen(_ dialog: Dialog) {
        guard isActive else { return }
        seen[dialog.account] = max(seen[dialog.account] ?? 0, dialog.messages.count)
    }

    private func start(_ dialog: Dialog) -> Int? {
        guard isActive else { return nil }
        let start = seen[dialog.account] ?? 0
        return start < dialog.messages.count ? start : nil
    }
}
