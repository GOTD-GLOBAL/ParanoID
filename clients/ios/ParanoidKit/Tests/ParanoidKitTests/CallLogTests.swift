import XCTest
@testable import ParanoidKit

/// The local call log: what one terminal transition means, where the row
/// stands in a conversation, and what the store does and does not keep.
final class CallLogTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    /// The container this case writes its log into. The log lives in a file
    /// that no OS backup carries, so a case needs a directory of its own as
    /// well as the scratch suite the migration reads.
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "paranoid.tests.call-log." + UUID().uuidString
        suite = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-call-log-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        suite = nil
        suiteName = nil
        directory = nil
        super.tearDown()
    }

    /// The log's own backup-excluded file, plus the preference an older build
    /// would have left behind for it to migrate.
    private func store() -> LocalMetadataStore {
        LocalMetadataStore(name: CallLog.fileName, legacyKey: CallLog.defaultsKey,
                           directory: directory, defaults: suite)
    }

    // MARK: - what a terminal transition means

    func testTheSameReasonMeansDifferentThingsOnTheTwoSides() {
        // A refusal: the device that pressed «Отклонить» and the one that heard
        // it both see `reject`, and the chat must not say the same thing.
        XCTAssertEqual(CallRecord.kind(outgoing: false, connected: false, reason: .reject), .declined)
        XCTAssertEqual(CallRecord.kind(outgoing: true, connected: false, reason: .reject), .rejected)
        // A caller giving up is a missed call for the callee.
        XCTAssertEqual(CallRecord.kind(outgoing: true, connected: false, reason: .cancel), .cancelled)
        XCTAssertEqual(CallRecord.kind(outgoing: false, connected: false, reason: .cancel), .missed)
        // A ring nobody answered.
        XCTAssertEqual(CallRecord.kind(outgoing: true, connected: false, reason: .timeout), .unanswered)
        XCTAssertEqual(CallRecord.kind(outgoing: false, connected: false, reason: .timeout), .missed)
        XCTAssertEqual(CallRecord.kind(outgoing: true, connected: false, reason: .busy), .busy)
        XCTAssertEqual(CallRecord.kind(outgoing: false, connected: false, reason: .busy), .missed)
        for reason in [CallBody.EndReason.failed, .unavailable] {
            XCTAssertEqual(CallRecord.kind(outgoing: true, connected: false, reason: reason), .failed)
            XCTAssertEqual(CallRecord.kind(outgoing: false, connected: false, reason: reason), .failed)
        }
    }

    func testAnAnsweredCallIsAnsweredWhateverEndedIt() {
        for reason in CallBody.EndReason.allCases {
            XCTAssertEqual(CallRecord.kind(outgoing: true, connected: true, reason: reason), .outgoing)
            XCTAssertEqual(CallRecord.kind(outgoing: false, connected: true, reason: reason), .incoming)
        }
    }

    func testOnlyAnUnansweredInboundCallIsMissed() {
        let missed = CallRecord.Kind.allCases.filter(\.isMissed)
        XCTAssertEqual(missed, [.missed])
    }

    func testTerminationCarriesTheDurationTheViewCannot() {
        let termination = CallTermination(callId: "c1", account: "peer", outgoing: false,
                                          connected: true, video: true, durationSeconds: 192,
                                          reason: .hangup)
        let record = termination.record(afterMessageId: "m2")
        XCTAssertEqual(record.kind, .incoming)
        XCTAssertEqual(record.durationSeconds, 192)
        XCTAssertEqual(record.video, true)
        XCTAssertEqual(record.afterMessageId, "m2")
        XCTAssertEqual(record.id, "c1")
    }

    // MARK: - the store

    func testOneCallIsOneRowHoweverOftenItIsRecorded() {
        var log = CallLog(store: store())
        let record = Self.record(id: "c1", account: "peer", kind: .missed)
        XCTAssertTrue(log.record(record))
        XCTAssertFalse(log.record(record))
        XCTAssertFalse(log.record(Self.record(id: "c1", account: "peer", kind: .incoming)))
        XCTAssertEqual(log.records(for: "peer").count, 1)
        XCTAssertEqual(log.records(for: "peer").first?.kind, .missed)
    }

    func testRowsSurviveARelaunchAndStayPerConversation() {
        var log = CallLog(store: store())
        log.record(Self.record(id: "c1", account: "peer", kind: .outgoing))
        log.record(Self.record(id: "c2", account: "other", kind: .missed))
        let reopened = CallLog(store: store())
        XCTAssertEqual(reopened.records(for: "peer").map(\.id), ["c1"])
        XCTAssertEqual(reopened.records(for: "other").map(\.id), ["c2"])
        XCTAssertEqual(reopened.records(for: "nobody"), [])
        XCTAssertEqual(reopened, log)
    }

    func testForgettingAConversationLeavesTheOthers() {
        var log = CallLog(store: store())
        log.record(Self.record(id: "c1", account: "peer", kind: .outgoing))
        log.record(Self.record(id: "c2", account: "other", kind: .missed))
        log.forget(account: "peer")
        XCTAssertEqual(log.records(for: "peer"), [])
        XCTAssertEqual(CallLog(store: store()).records(for: "other").map(\.id), ["c2"])
    }

    func testAnEmptyAccountOrIdentifierIsNotRecorded() {
        var log = CallLog(store: store())
        XCTAssertFalse(log.record(Self.record(id: "", account: "peer", kind: .missed)))
        XCTAssertFalse(log.record(Self.record(id: "c1", account: "", kind: .missed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().fileURL.path))
    }

    func testAnOlderBuildsCallsMoveOutOfTheBackupOnFirstLaunch() throws {
        // What an installation of the previous build left behind: the same
        // JSON, in preferences an iCloud or encrypted local backup carries.
        suite.set(try JSONEncoder().encode(["peer": [Self.record(id: "c1", account: "peer", kind: .missed)]]),
                  forKey: CallLog.defaultsKey)

        let log = CallLog(store: store())
        XCTAssertEqual(log.records(for: "peer").map(\.id), ["c1"], "the calls survive the move")
        XCTAssertNil(suite.object(forKey: CallLog.defaultsKey),
                     "and the copy a backup carried does not stay behind")
        XCTAssertTrue(store().isExcludedFromBackup())
        XCTAssertEqual(CallLog(store: store()), log)
    }

    func testTheLogIsBoundedPerConversation() {
        var log = CallLog(store: store())
        for n in 0...CallLog.perAccountLimit {
            log.record(Self.record(id: "c\(n)", account: "peer", kind: .outgoing))
        }
        let rows = log.records(for: "peer")
        XCTAssertEqual(rows.count, CallLog.perAccountLimit)
        // The oldest row is the one that goes.
        XCTAssertEqual(rows.first?.id, "c1")
        XCTAssertEqual(rows.last?.id, "c\(CallLog.perAccountLimit)")
    }

    // MARK: - where a row stands in the conversation

    func testCallsStandAfterTheMessageTheyFollowed() {
        let messages = [Self.message("m1"), Self.message("m2")]
        let calls = [Self.record(id: "c1", account: "peer", kind: .missed, after: "m1"),
                     Self.record(id: "c2", account: "peer", kind: .outgoing, after: "m2")]
        XCTAssertEqual(ChatRow.rows(messages: messages, calls: calls).map(\.id),
                       ["m:m1", "c:c1", "m:m2", "c:c2"])
    }

    func testACallBeforeAnyMessageOpensTheChat() {
        let rows = ChatRow.rows(messages: [Self.message("m1")],
                                calls: [Self.record(id: "c1", account: "peer", kind: .missed, after: nil)])
        XCTAssertEqual(rows.map(\.id), ["c:c1", "m:m1"])
    }

    func testACallWhoseAnchorIsGoneStandsAtTheEndRatherThanDisappearing() {
        let rows = ChatRow.rows(messages: [Self.message("m1")],
                                calls: [Self.record(id: "c1", account: "peer", kind: .missed, after: "lost")])
        XCTAssertEqual(rows.map(\.id), ["m:m1", "c:c1"])
    }

    func testUnavailableHistoryAnchorSurvivesReloadAndStandsAtTheEnd() {
        let anchor = CallLog.anchor(messages: nil)
        XCTAssertEqual(anchor, "unavailable")
        var log = CallLog(store: store())
        log.record(Self.record(id: "c1", account: "peer", kind: .missed, after: anchor))
        let calls = CallLog(store: store()).records(for: "peer")
        XCTAssertEqual(calls.first?.afterMessageId, "unavailable")
        XCTAssertEqual(ChatRow.rows(messages: [Self.message("m1")], calls: calls).map(\.id),
                       ["m:m1", "c:c1"])
    }

    func testObservedEmptyHistoryAnchorStillOpensTheChat() {
        let anchor = CallLog.anchor(messages: [])
        XCTAssertNil(anchor)
        let calls = [Self.record(id: "c1", account: "peer", kind: .missed, after: anchor)]
        XCTAssertEqual(ChatRow.rows(messages: [Self.message("m1")], calls: calls).map(\.id),
                       ["c:c1", "m:m1"])
    }

    func testAvailableHistoryAnchorUsesTheLastMessage() {
        XCTAssertEqual(CallLog.anchor(messages: [Self.message("m1"), Self.message("m2")]), "m2")
    }

    func testAConversationWithoutCallsIsItsMessagesUnchanged() {
        let messages = [Self.message("m1"), Self.message("m2")]
        XCTAssertEqual(ChatRow.rows(messages: messages, calls: []).map(\.id), ["m:m1", "m:m2"])
    }

    // MARK: - fixtures

    private static func record(id: String, account: String, kind: CallRecord.Kind,
                               after: String? = nil) -> CallRecord {
        CallRecord(id: id, account: account, kind: kind, video: false,
                   durationSeconds: 0, afterMessageId: after)
    }

    private static func message(_ id: String) -> Message {
        Message(id: id, author: "peer", text: "t", isAccepted: true, isDelivered: true)
    }
}
