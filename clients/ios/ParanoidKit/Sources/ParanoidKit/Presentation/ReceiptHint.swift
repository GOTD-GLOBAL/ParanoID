import Foundation

/// Whether this phone still owes its owner the sentence that two marks are not
/// "read".
///
/// The marks themselves say only what the protocol knows (REQ-MSG-003: one mark
/// is durable server acceptance, two are the peer's authenticated delivery
/// receipt), and the contact sheet has always spelled that out
/// (`MainActivity.java:567`). It was the one place that did, so a chat could be
/// read for weeks as if two marks meant the peer had read the message. This
/// shows the same sentence once, in the chat, the first time a message of this
/// user's actually reaches the second mark.
///
/// It is a presentation flag and nothing else: it lives in the application's
/// own defaults, never in the sealed snapshot, and it is never sent anywhere —
/// the same rule as ``ContactNames``.
public struct ReceiptHint: Equatable {
    /// The defaults key the flag lives under, versioned so a later rule can be
    /// told apart from this one.
    public static let defaultsKey = "paranoid.receipt-hint.v1"

    private var dismissed: Bool
    private let defaults: UserDefaults?

    /// - Parameter defaults: the standard suite in the application; the tests
    ///   pass a scratch suite so a run leaves nothing behind.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        dismissed = defaults?.bool(forKey: Self.defaultsKey) ?? false
    }

    /// Whether the sentence still has to be shown.
    public var isPending: Bool { !dismissed }

    /// «Понятно»: the sentence has been read and does not come back, including
    /// after a restart.
    public mutating func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        defaults?.set(true, forKey: Self.defaultsKey)
    }

    /// Whether this conversation has a message of this user's that reached the
    /// second mark — the moment the sentence is worth showing.
    public static func isEarned(_ dialog: Dialog?) -> Bool {
        guard let dialog else { return false }
        return dialog.messages.contains { dialog.isOwn($0) && $0.isDelivered }
    }

    /// Two flags are the same when they hold the same answer; which suite they
    /// were read from is not part of that.
    public static func == (left: ReceiptHint, right: ReceiptHint) -> Bool {
        left.dismissed == right.dismissed
    }
}
