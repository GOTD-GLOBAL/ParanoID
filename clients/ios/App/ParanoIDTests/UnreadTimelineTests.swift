import ParanoidKit
import XCTest
@testable import ParanoID

/// Where «Новые сообщения» stands in an open chat, and how its count is said.
final class UnreadTimelineTests: XCTestCase {
    private let own = "own-account"
    private let peer = "peer-account"
    /// 2026-09-25 12:00 UTC, and the same day an hour later.
    private let noon: UInt64 = 1_790_337_600_000
    private var later: UInt64 { noon + 3_600_000 }

    private func message(_ id: String, mine: Bool = false, at time: UInt64 = 0) -> Message {
        Message(id: id, author: mine ? own : peer, text: id, isAccepted: true,
                isDelivered: true, localMilliseconds: time)
    }

    private func call(_ id: String, after: String?) -> CallRecord {
        CallRecord(id: id, account: peer, kind: .missed, video: false,
                   durationSeconds: 0, afterMessageId: after)
    }

    /// The row identifiers in order, which is what the screen draws.
    private func ids(_ rows: [ChatRow], divider: Int?) -> [String] {
        AppModel.timeline(rows, now: later, dividerBefore: divider).map(\.id)
    }

    func testTheDividerStandsImmediatelyBeforeTheFirstNewMessage() {
        let rows = ChatRow.rows(messages: [message("a"), message("b", mine: true), message("c")],
                                calls: [])
        XCTAssertEqual(ids(rows, divider: 2), ["m:a", "m:b", TimelineRow.unreadId(2), "m:c"])
        XCTAssertEqual(ids(rows, divider: 0), [TimelineRow.unreadId(0), "m:a", "m:b", "m:c"])
    }

    func testWithoutADividerTheTimelineIsUnchanged() {
        let rows = ChatRow.rows(messages: [message("a"), message("b")], calls: [])
        XCTAssertEqual(ids(rows, divider: nil), ["m:a", "m:b"])
        XCTAssertTrue(ids(rows, divider: 1).contains(TimelineRow.unreadId(1)),
                      "a divider that is asked for is drawn")
    }

    func testACallAnchoredToTheLastSeenMessageStaysAboveTheDivider() {
        // The call happened after «a», which had been seen; «b» is new.
        let rows = ChatRow.rows(messages: [message("a"), message("b")],
                                calls: [call("x", after: "a")])
        XCTAssertEqual(ids(rows, divider: 1), ["m:a", "c:x", TimelineRow.unreadId(1), "m:b"])
    }

    func testTheDayPillStillOpensTheDayAboveTheDivider() {
        let rows = ChatRow.rows(messages: [message("a", at: noon), message("b", at: later + 86_400_000)],
                                calls: [])
        let timeline = AppModel.timeline(rows, now: later + 86_400_000, dividerBefore: 1)
        let order = timeline.map(\.id)
        guard let pill = order.firstIndex(of: "d:b"),
              let divider = order.firstIndex(of: TimelineRow.unreadId(1)),
              let first = order.firstIndex(of: "m:b")
        else { return XCTFail("missing a row: \(order)") }
        XCTAssertLessThan(pill, divider)
        XCTAssertEqual(divider + 1, first)
    }

    func testAPositionPastTheEndDrawsNoDivider() {
        let rows = ChatRow.rows(messages: [message("a")], calls: [])
        XCTAssertEqual(ids(rows, divider: 5), ["m:a"])
        XCTAssertEqual(ids(rows, divider: 0), [TimelineRow.unreadId(0), "m:a"])
    }

    func testTheCountIsSaidTheWayRussianSaysIt() {
        let expected: [(Int, String)] = [
            (1, "1 новое сообщение"), (2, "2 новых сообщения"), (4, "4 новых сообщения"),
            (5, "5 новых сообщений"), (11, "11 новых сообщений"), (12, "12 новых сообщений"),
            (14, "14 новых сообщений"), (21, "21 новое сообщение"), (22, "22 новых сообщения"),
            (25, "25 новых сообщений"), (101, "101 новое сообщение"), (111, "111 новых сообщений"),
        ]
        for (count, words) in expected {
            XCTAssertEqual(Strings.Unread.count(count), words, "count \(count)")
        }
        XCTAssertEqual(Strings.Unread.badge(7), "7")
        XCTAssertEqual(Strings.Unread.badge(99), "99")
        XCTAssertEqual(Strings.Unread.badge(100), "99+")
    }

    func testNoWordOfNewMessagesSaysRead() {
        for text in [Strings.Unread.divider, Strings.Unread.toNew,
                     Strings.Unread.count(1), Strings.Unread.count(3), Strings.Unread.count(5)] {
            XCTAssertFalse(text.lowercased().contains("прочит"), text)
        }
    }
}
