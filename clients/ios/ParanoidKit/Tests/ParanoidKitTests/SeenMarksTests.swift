import XCTest
@testable import ParanoidKit

/// Which incoming messages this run of the application has not yet shown.
///
/// Every test pairs its "nothing is new" with a "this one is new", so a
/// counter that answers zero for everything fails all of them rather than half.
final class SeenMarksTests: XCTestCase {
    private let own = "own-account"
    private let peer = "peer-account"

    private func incoming(_ id: String) -> Message {
        Message(id: id, author: peer, text: "text " + id, isAccepted: true, isDelivered: true)
    }

    private func mine(_ id: String) -> Message {
        Message(id: id, author: own, text: "text " + id, isAccepted: true, isDelivered: false)
    }

    private func dialog(_ messages: [Message], account: String? = nil) -> Dialog {
        Dialog(account: account ?? peer, own: own, trust: "network_unverified",
               isBlocked: false, messages: messages)
    }

    func testWhatWasThereAtLaunchIsSeenAndWhatArrivesAfterIsNew() {
        let atLaunch = dialog([incoming("a"), mine("b")])
        let marks = SeenMarks(opening: [atLaunch])
        XCTAssertEqual(marks.unseenCount(atLaunch), 0)
        XCTAssertNil(marks.firstUnseenIndex(atLaunch))

        let later = dialog([incoming("a"), mine("b"), incoming("c")])
        XCTAssertEqual(marks.unseenCount(later), 1)
        XCTAssertEqual(marks.firstUnseenIndex(later), 2)
    }

    func testOwnMessagesAreNeverNew() {
        let marks = SeenMarks(opening: [dialog([])])
        XCTAssertEqual(marks.unseenCount(dialog([mine("a"), mine("b")])), 0)
        XCTAssertNil(marks.firstUnseenIndex(dialog([mine("a"), mine("b")])))

        let mixed = dialog([mine("a"), incoming("b"), mine("c")])
        XCTAssertEqual(marks.unseenCount(mixed), 1)
        XCTAssertEqual(marks.firstUnseenIndex(mixed), 1, "the first new one skips own messages")
    }

    func testAConversationThatAppearsAfterLaunchIsNewFromItsFirstMessage() {
        let marks = SeenMarks(opening: [dialog([incoming("x")], account: "someone-else")])
        let firstContact = dialog([incoming("a"), mine("b"), incoming("c")])
        XCTAssertEqual(marks.unseenCount(firstContact), 2)
        XCTAssertEqual(marks.firstUnseenIndex(firstContact), 0)
    }

    func testMarkingSeenClearsTheCountAndNewArrivalsCountAgain() {
        var marks = SeenMarks(opening: [dialog([])])
        let two = dialog([incoming("a"), incoming("b")])
        XCTAssertEqual(marks.unseenCount(two), 2)
        marks.markSeen(two)
        XCTAssertEqual(marks.unseenCount(two), 0)
        XCTAssertNil(marks.firstUnseenIndex(two))

        let three = dialog([incoming("a"), incoming("b"), incoming("c")])
        XCTAssertEqual(marks.unseenCount(three), 1)
        XCTAssertEqual(marks.firstUnseenIndex(three), 2)
    }

    func testTheMarkOnlyGrows() {
        var marks = SeenMarks(opening: [dialog([])])
        let three = dialog([incoming("a"), incoming("b"), incoming("c")])
        marks.markSeen(three)
        // A stale, shorter read of the same conversation cannot move it back.
        marks.markSeen(dialog([incoming("a")]))
        XCTAssertEqual(marks.unseenCount(three), 0)
        XCTAssertEqual(marks.unseenCount(dialog([incoming("a"), incoming("b"), incoming("c"),
                                                  incoming("d")])), 1)
    }

    func testAHistoryShorterThanTheMarkCountsNothingAndDoesNotTrap() {
        var marks = SeenMarks(opening: [dialog([])])
        marks.markSeen(dialog([incoming("a"), incoming("b"), incoming("c")]))
        let shorter = dialog([incoming("a")])
        XCTAssertEqual(marks.unseenCount(shorter), 0)
        XCTAssertNil(marks.firstUnseenIndex(shorter))
        let longer = dialog([incoming("a"), incoming("b"), incoming("c"), incoming("d")])
        XCTAssertEqual(marks.firstUnseenIndex(longer), 3)
    }

    func testWithoutABaselineNothingIsCountedButAnEmptyBaselineCounts() {
        let one = dialog([incoming("a")])
        XCTAssertEqual(SeenMarks().unseenCount(one), 0, "no baseline: no claim that anything is new")
        XCTAssertNil(SeenMarks().firstUnseenIndex(one))
        XCTAssertEqual(SeenMarks(opening: []).unseenCount(one), 1)
    }

    func testMarksArePerConversation() {
        var marks = SeenMarks(opening: [dialog([]), dialog([], account: "second")])
        let first = dialog([incoming("a")])
        let second = dialog([incoming("a")], account: "second")
        marks.markSeen(first)
        XCTAssertEqual(marks.unseenCount(first), 0)
        XCTAssertEqual(marks.unseenCount(second), 1)
    }

    func testAPeerReusingAnOwnIdentifierIsStillCountedByPosition() {
        // The sender chooses an incoming identifier; the core checks only its
        // form and the uniqueness of sender:id, so it may equal one of ours.
        let marks = SeenMarks(opening: [dialog([mine("same")])])
        let after = dialog([mine("same"), incoming("same")])
        XCTAssertEqual(marks.unseenCount(after), 1)
        XCTAssertEqual(marks.firstUnseenIndex(after), 1)
    }

    func testTwoDialogsWithOneAccountAtLaunchDoNotTrap() {
        let marks = SeenMarks(opening: [dialog([incoming("a")]), dialog([incoming("a"), incoming("b")])])
        XCTAssertEqual(marks.unseenCount(dialog([incoming("a"), incoming("b"), incoming("c")])), 1)
    }
}
