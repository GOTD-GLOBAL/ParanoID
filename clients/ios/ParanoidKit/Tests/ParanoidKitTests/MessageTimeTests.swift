import XCTest
@testable import ParanoidKit

/// When a message happened, as the screens read it.
///
/// Every case pins its own calendar and time zone: the rule is the phone's own
/// zone, and a test that used the machine's would say something different in
/// another country.
final class MessageTimeTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    }

    private func instant(_ year: Int, _ month: Int, _ day: Int,
                         _ hour: Int = 12, _ minute: Int = 0) -> UInt64 {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return UInt64(calendar.date(from: parts)!.timeIntervalSince1970 * 1000)
    }

    func testTheTimeUnderABubbleIsTheDevicesOwnZone() {
        XCTAssertEqual(MessagePresentation.time(instant(2026, 9, 17, 14, 32), calendar: calendar), "14:32")
        XCTAssertEqual(MessagePresentation.time(instant(2026, 9, 17, 9, 5), calendar: calendar), "09:05")
        XCTAssertEqual(MessagePresentation.time(instant(2026, 9, 17, 0, 0), calendar: calendar), "00:00")
    }

    func testAMessageWithoutATimeIsShownWithoutOne() {
        // REQ-CLIENT-004: nothing invents a time for an entry that has none.
        XCTAssertEqual(MessagePresentation.time(0, calendar: calendar), "")
        XCTAssertEqual(MessagePresentation.listTime(0, now: instant(2026, 9, 17), calendar: calendar), "")
        XCTAssertEqual(MessagePresentation.daySeparator(0, now: instant(2026, 9, 17), calendar: calendar), "")
        XCTAssertFalse(MessagePresentation.startsNewDay(0, after: instant(2026, 9, 16), calendar: calendar))
    }

    func testASeparatorStandsWhereTheDayChanges() {
        let morning = instant(2026, 9, 17, 9, 0)
        let evening = instant(2026, 9, 17, 23, 59)
        let nextDay = instant(2026, 9, 18, 0, 1)
        XCTAssertTrue(MessagePresentation.startsNewDay(morning, after: 0, calendar: calendar),
                      "the first timed message opens a day of its own")
        XCTAssertFalse(MessagePresentation.startsNewDay(evening, after: morning, calendar: calendar))
        XCTAssertTrue(MessagePresentation.startsNewDay(nextDay, after: evening, calendar: calendar),
                      "one minute later is a different day when the clock passed midnight")
    }

    func testTheSeparatorNamesTheDayTheWayItIsSaid() {
        let today = instant(2026, 9, 17, 14, 0)
        XCTAssertEqual(MessagePresentation.daySeparator(today, now: today, calendar: calendar), "Сегодня")
        XCTAssertEqual(MessagePresentation.daySeparator(instant(2026, 9, 16, 23, 0), now: today, calendar: calendar),
                       "Вчера")
        XCTAssertEqual(MessagePresentation.daySeparator(instant(2026, 9, 12, 8, 0), now: today, calendar: calendar),
                       "12 сентября")
        XCTAssertEqual(MessagePresentation.daySeparator(instant(2025, 12, 31, 8, 0), now: today, calendar: calendar),
                       "31 декабря 2025", "another year is named, or two dates read alike")
    }

    func testAConversationRowSaysWhenItsLastEventWas() {
        let today = instant(2026, 9, 17, 16, 6)
        XCTAssertEqual(MessagePresentation.listTime(instant(2026, 9, 17, 10, 5), now: today, calendar: calendar),
                       "10:05")
        XCTAssertEqual(MessagePresentation.listTime(instant(2026, 9, 16, 21, 40), now: today, calendar: calendar),
                       "Вчера")
        XCTAssertEqual(MessagePresentation.listTime(instant(2026, 9, 12, 21, 40), now: today, calendar: calendar),
                       "12.09")
        XCTAssertEqual(MessagePresentation.listTime(instant(2025, 9, 12, 21, 40), now: today, calendar: calendar),
                       "12.09.2025")
    }

    func testTheCoreValueReachesTheDecodedMessageAndZeroMeansUnknown() {
        let timed = Message.decode(["id": "m1", "author": "a", "text": "t",
                                    "accepted": true, "delivered": true,
                                    "local_ms": NSNumber(value: 1_700_000_000_000 as UInt64)])
        XCTAssertEqual(timed?.localMilliseconds, 1_700_000_000_000)
        let untimed = Message.decode(["id": "m2", "author": "a", "text": "t",
                                      "accepted": true, "delivered": true])
        XCTAssertEqual(untimed?.localMilliseconds, 0, "an entry without a time decodes as unknown")
    }
}
