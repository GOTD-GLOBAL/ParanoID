import XCTest
@testable import ParanoID

/// REQ-CALL-003: either video direction must remain visible, regardless of route.
final class CallScreenPolicyRegressionTests: XCTestCase {
    func testRemoteOnlyVideoStaysAwakeWithoutProximity() {
        let policy = AudioSessionController.screenPolicy(
            held: true, audible: true, video: false, remoteVideo: true,
            speaker: false, headset: false)
        XCTAssertTrue(policy.awake)
        XCTAssertFalse(policy.proximity)
    }

    func testAudioOnlyEarpieceAndOtherRoutesAreUnchanged() {
        for audible in [true, false] {
            for speaker in [true, false] {
                for headset in [true, false] {
                    let policy = AudioSessionController.screenPolicy(
                        held: true, audible: audible, video: false, remoteVideo: false,
                        speaker: speaker, headset: headset)
                    XCTAssertFalse(policy.awake)
                    XCTAssertEqual(policy.proximity, audible && !speaker && !headset)
                }
            }
        }
    }

    func testLocalVideoAndEndedCallReleaseProximity() {
        let local = AudioSessionController.screenPolicy(
            held: true, audible: true, video: true, remoteVideo: false,
            speaker: false, headset: false)
        XCTAssertTrue(local.awake)
        XCTAssertFalse(local.proximity)
        let ended = AudioSessionController.screenPolicy(
            held: false, audible: true, video: true, remoteVideo: true,
            speaker: false, headset: false)
        XCTAssertFalse(ended.awake)
        XCTAssertFalse(ended.proximity)
    }
}
