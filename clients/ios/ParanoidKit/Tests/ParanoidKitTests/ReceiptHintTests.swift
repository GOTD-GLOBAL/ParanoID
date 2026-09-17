import XCTest
@testable import ParanoidKit

/// The sentence that two marks are not "read" is shown once and then never
/// again, and it is earned by a real delivered message of this user's.
final class ReceiptHintTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "paranoid.tests.receipt-hint." + UUID().uuidString
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    func testPendingUntilDismissedAndThenNeverAgain() {
        var hint = ReceiptHint(defaults: suite)
        XCTAssertTrue(hint.isPending)
        hint.dismiss()
        XCTAssertFalse(hint.isPending)
        // A second read of the same suite is what a relaunch does.
        XCTAssertFalse(ReceiptHint(defaults: suite).isPending)
    }

    func testDismissingTwiceIsTheSameAsOnce() {
        var hint = ReceiptHint(defaults: suite)
        hint.dismiss()
        hint.dismiss()
        XCTAssertEqual(hint, ReceiptHint(defaults: suite))
    }

    func testNothingIsStoredBeforeTheSentenceIsRead() {
        _ = ReceiptHint(defaults: suite)
        XCTAssertNil(suite.object(forKey: ReceiptHint.defaultsKey))
    }

    func testOnlyAnOwnDeliveredMessageEarnsIt() {
        let own = "own"
        let peer = "peer"
        func message(_ author: String, delivered: Bool) -> Message {
            Message(id: UUID().uuidString, author: author, text: "t",
                    isAccepted: true, isDelivered: delivered)
        }
        func dialog(_ messages: [Message]) -> Dialog {
            Dialog(account: peer, own: own, trust: "", isBlocked: false, messages: messages)
        }
        XCTAssertFalse(ReceiptHint.isEarned(nil))
        XCTAssertFalse(ReceiptHint.isEarned(dialog([])))
        XCTAssertFalse(ReceiptHint.isEarned(dialog([message(own, delivered: false)])))
        // A peer's message is delivered by definition; it explains nothing
        // about this user's own marks.
        XCTAssertFalse(ReceiptHint.isEarned(dialog([message(peer, delivered: true)])))
        XCTAssertTrue(ReceiptHint.isEarned(dialog([message(own, delivered: true)])))
    }
}
