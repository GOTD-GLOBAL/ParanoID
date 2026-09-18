import Foundation
import XCTest
@testable import ParanoID

final class AudioPreparationReplyTests: XCTestCase {
    func testCancellationBeforeInstallResumesFalseExactlyOnce() async {
        let reply = AudioPreparationReply()
        reply.finish(false)
        let value = await withCheckedContinuation { continuation in
            XCTAssertFalse(reply.install(continuation))
        }
        reply.finish(true)
        XCTAssertFalse(value)
        XCTAssertFalse(reply.isPending)
    }
    func testTimeoutBeatsLateAudioSuccess() async {
        let reply = AudioPreparationReply()
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(reply.install(continuation))
            reply.finish(false)
            reply.finish(true)
        }
        XCTAssertFalse(value)
    }
    func testReadinessBeatsLateCancellationAndCancelsTimer() async {
        let reply = AudioPreparationReply(), timer = DispatchWorkItem {}
        reply.arm(timer)
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(reply.install(continuation))
            reply.finish(true)
            reply.finish(false)
        }
        XCTAssertTrue(value)
        XCTAssertTrue(timer.isCancelled)
    }
}
