import Foundation
import ParanoidKit
import XCTest

/// The order of «Чаты» (`DialogOrder.byRecency`): newest message first,
/// untimed conversations after, in the core's order, and nothing invented.
final class DialogOrderTests: XCTestCase {
    func testTheNewestMessageComesFirst() {
        let ordered = DialogOrder.byRecency([
            dialog("a", lastAt: 1_000),
            dialog("b", lastAt: 3_000),
            dialog("c", lastAt: 2_000),
        ])
        XCTAssertEqual(ordered.map(\.account), ["b", "c", "a"])
    }

    func testUntimedConversationsFollowInTheCoresOrder() {
        let ordered = DialogOrder.byRecency([
            dialog("empty-1"),
            dialog("old", lastAt: 0),
            dialog("new", lastAt: 5_000),
            dialog("empty-2"),
            dialog("older", lastAt: 4_000),
        ])
        XCTAssertEqual(ordered.map(\.account), ["new", "older", "empty-1", "old", "empty-2"])
    }

    func testEqualTimesKeepTheCoresOrder() {
        let ordered = DialogOrder.byRecency([
            dialog("first", lastAt: 7_000),
            dialog("second", lastAt: 7_000),
            dialog("third", lastAt: 7_000),
        ])
        XCTAssertEqual(ordered.map(\.account), ["first", "second", "third"])
    }

    func testOnlyTheLastMessageCounts() {
        // An older last message after a newer earlier one: the history is in
        // commit order, and the row is about its last entry.
        let stale = Dialog(account: "stale", own: "me", trust: "network_unverified", isBlocked: false,
                           messages: [message("m1", at: 9_000), message("m2", at: 1_000)])
        let ordered = DialogOrder.byRecency([stale, dialog("fresh", lastAt: 2_000)])
        XCTAssertEqual(ordered.map(\.account), ["fresh", "stale"])
    }

    func testNothingToSortIsLeftAlone() {
        XCTAssertEqual(DialogOrder.byRecency([]), [])
        let untimed = [dialog("x"), dialog("y", lastAt: 0)]
        XCTAssertEqual(DialogOrder.byRecency(untimed), untimed)
    }

    // MARK: - fixtures

    private func dialog(_ account: String, lastAt: UInt64? = nil) -> Dialog {
        Dialog(account: account, own: "me", trust: "network_unverified", isBlocked: false,
               messages: lastAt.map { [message("m-\(account)", at: $0)] } ?? [])
    }

    private func message(_ id: String, at millis: UInt64) -> Message {
        Message(id: id, author: "peer", text: "…", isAccepted: true, isDelivered: false,
                localMilliseconds: millis)
    }
}
