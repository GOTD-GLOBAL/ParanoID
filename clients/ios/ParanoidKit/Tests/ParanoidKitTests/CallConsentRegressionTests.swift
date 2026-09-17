import ParanoidKit
import XCTest

/// REQ-CALL-002/003: permission results belong to the original incoming call.
final class CallConsentRegressionTests: XCTestCase {
    func testStaleGrantAndRefusalCannotAnswerOrEndReplacement() throws {
        for granted in [true, false] {
            let pair = CallPair()
            pair.ring()
            let old = pair.bob.presentation
            pair.alice.hangup()
            pair.deliver(to: pair.bob, from: CallPair.alice,
                         try XCTUnwrap(pair.alicePorts.take()))
            pair.ring()
            XCTAssertEqual(pair.bob.currentState, .incoming)
            let current = pair.bob.presentation
            let sent = pair.bobPorts.everySent.count
            pair.bob.answer(microphonePermission: granted, callId: old.callId,
                            generation: old.generation)
            XCTAssertEqual(pair.bob.currentState, .incoming)
            XCTAssertEqual(pair.bob.presentation.callId, current.callId)
            XCTAssertEqual(pair.bobPorts.answers, 0)
            XCTAssertEqual(pair.bobPorts.everySent.count, sent)
            // Both fields are required, not just one of them.
            pair.bob.answer(microphonePermission: granted, callId: current.callId,
                            generation: old.generation)
            pair.bob.answer(microphonePermission: granted, callId: old.callId,
                            generation: current.generation)
            XCTAssertEqual(pair.bob.currentState, .incoming)
            XCTAssertEqual(pair.bobPorts.answers, 0)
            pair.bob.answer(microphonePermission: granted, callId: current.callId,
                            generation: current.generation)
            XCTAssertEqual(pair.bob.currentState, granted ? .connecting : .ended)
            XCTAssertEqual(pair.bobPorts.answers, granted ? 1 : 0)
        }
    }
}
