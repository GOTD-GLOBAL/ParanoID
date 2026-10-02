import Foundation

/// The order of «Чаты»: by the time of each conversation's last message,
/// newest first.
///
/// The core publishes conversations by account identifier
/// (`clean_service.rs:321-326`, a `BTreeMap`), which is no order a person can
/// read. This client sorts them by the time stamped on each conversation's
/// last message — the instant this phone's clock showed when it wrote or
/// received it, which the core stores and never sends (RFC-0023) — newest
/// stamp first. That is the conversation with the newest message whenever
/// this phone's clock ran forward between messages; a clock set back between
/// two messages leaves the later one with the smaller stamp, and the list
/// follows the stamp, as the bubble does. Two things stay in the
/// core's order, after every timed conversation: a conversation with no
/// messages yet, and one whose last entry was written by a build that kept
/// no time (`Message.localMilliseconds == 0`); nothing invents a time for
/// them (REQ-CLIENT-004). Equal times keep the core's order too, so the sort
/// is stable and a re-read that changes nothing moves nothing.
///
/// A call moves no conversation. The call log keeps no wall-clock time
/// (`CallRecord`, RFC-0023 «Privacy»), so a conversation whose last event is a
/// call stands where its last message puts it, and a chat with a missed call
/// but an older message can stand below a chat with a newer message. Android
/// keeps the core's order (`MainActivity.renderLists`); the same request
/// stands for it.
public enum DialogOrder {
    public static func byRecency(_ dialogs: [Dialog]) -> [Dialog] {
        let indexed = Array(dialogs.enumerated())
        let timed = indexed
            .filter { key($0.element) > 0 }
            .sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka > kb : a.offset < b.offset
            }
        let untimed = indexed.filter { key($0.element) == 0 }
        return (timed + untimed).map(\.element)
    }

    /// The time of the last message, or `0` when there is none to sort by.
    private static func key(_ dialog: Dialog) -> UInt64 {
        dialog.last?.localMilliseconds ?? 0
    }
}
