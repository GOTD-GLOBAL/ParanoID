import XCTest
@testable import ParanoID

/// The outbox line of «Подключение» agrees with its number the way Russian
/// does: one form after 1 (but not 11), another after 2-4 (but not 12-14),
/// and the third after everything else.
final class ConnectionCaptionTests: XCTestCase {
    func testTheOutboxLineAgreesWithItsNumber() {
        let expected: [(Int, String)] = [
            (0, "0 сообщений ожидают отправки"),
            (1, "1 сообщение ожидает отправки"),
            (2, "2 сообщения ожидают отправки"),
            (4, "4 сообщения ожидают отправки"),
            (5, "5 сообщений ожидают отправки"),
            (11, "11 сообщений ожидают отправки"),
            (12, "12 сообщений ожидают отправки"),
            (14, "14 сообщений ожидают отправки"),
            (21, "21 сообщение ожидает отправки"),
            (22, "22 сообщения ожидают отправки"),
            (25, "25 сообщений ожидают отправки"),
            (101, "101 сообщение ожидает отправки"),
            (111, "111 сообщений ожидают отправки"),
            (112, "112 сообщений ожидают отправки"),
        ]
        for (count, caption) in expected {
            XCTAssertEqual(Strings.Connection.queued(count), caption, "count \(count)")
        }
    }
}
