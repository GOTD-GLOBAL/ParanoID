import AVFoundation
import ParanoidKit
import UIKit
import WebRTC
import XCTest

@testable import ParanoID

/// The audio session of a call, on the real platform.
///
/// `test_ui_contract.py` measures the *order* — that the session is started
/// after the microphone is granted and before the first `knock`, and that only
/// `connected` hands the audio unit to libwebrtc. This file measures what the
/// platform actually does when that order is followed: the session is
/// configured for a call, libwebrtc is in manual audio and silent while the
/// call is being set up, and the silent loop that holds the `audio` background
/// mode is a file the system will really play.
///
/// It opens no microphone. Every test runs in a simulator whose microphone
/// this application has not been granted, which is exactly the point: the
/// three things checked here are decided by this client, not by a permission,
/// so they are the same on a phone.
final class CallAudioSessionTests: XCTestCase {
    private var controller: AudioSessionController?

    override func tearDown() {
        controller?.end()
        controller = nil
        // The session is process-wide, so the next test bundle must not find
        // libwebrtc in manual audio because of this one.
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.useManualAudio = false
        super.tearDown()
    }

    /// Waits until `condition` holds, because the controller does its work on
    /// its own serial queue.
    private func settle(_ condition: @escaping () -> Bool,
                        _ message: String,
                        file: StaticString = #filePath,
                        line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - the silent loop

    /// The keep-alive is built in memory rather than shipped as a resource, so
    /// nothing but this test stands between a wrong header and a background
    /// mode that holds nothing.
    func testTheKeepAliveIsASilentWaveFileThePlatformWillPlay() throws {
        let wave = AudioSessionController.silence()
        let frames = Int(Double(AudioSessionController.keepAliveSampleRate)
                         * AudioSessionController.keepAliveSeconds)
        XCTAssertEqual(wave.count, 44 + frames * 2, "the header is 44 bytes and the samples 16-bit")
        XCTAssertEqual(Array(wave[0..<4]), Array("RIFF".utf8), "not a RIFF container")
        XCTAssertEqual(Array(wave[8..<12]), Array("WAVE".utf8), "not a WAVE file")
        XCTAssertEqual(Array(wave[12..<16]), Array("fmt ".utf8), "no format chunk")
        XCTAssertEqual(Array(wave[36..<40]), Array("data".utf8), "no data chunk")
        XCTAssertTrue(wave[44...].allSatisfy { $0 == 0 }, "the loop is not silence")

        // The platform parses it: a wrong header is a background mode that
        // holds nothing. `prepareToPlay()` is deliberately not called — it
        // reaches the audio server, which is why the controller keeps the
        // player on a queue of its own.
        let player = try AVAudioPlayer(data: Data(wave))
        XCTAssertEqual(player.numberOfChannels, 1, "the keep-alive is not mono")
        XCTAssertEqual(player.duration, AudioSessionController.keepAliveSeconds, accuracy: 0.05,
                       "the keep-alive is not half a second long")
    }

    // MARK: - manual audio

    /// `useManualAudio` with the audio unit off is what keeps a ringing call
    /// silent: libwebrtc may not open the microphone until this client says
    /// so, and this client says so only at `connected`
    /// (`docs/protocol/voice-v1.md:107-108`).
    func testLibwebrtcIsSilentUntilTheCallIsConnected() {
        let session = RTCAudioSession.sharedInstance()
        let controller = AudioSessionController { _ in }
        self.controller = controller

        controller.begin()
        settle({ session.useManualAudio }, "the session is not in manual audio")
        XCTAssertFalse(session.isAudioEnabled,
                       "libwebrtc has the audio unit before the call is connected")
        XCTAssertEqual(AudioSessionController.category, .playAndRecord)
        XCTAssertEqual(AudioSessionController.mode, .voiceChat)
        XCTAssertEqual(AudioSessionController.options, [.allowBluetoothHFP])

        controller.enableAudio()
        settle({ session.isAudioEnabled }, "a connected call did not get the audio unit")

        controller.end()
        settle({ !session.isAudioEnabled }, "the audio unit outlived the call")
    }

    /// Both halves are idempotent: a second Answer, or a terminal reason that
    /// arrives twice, must not leave the session held or take it away twice.
    func testBeginAndEndAreIdempotent() {
        let session = RTCAudioSession.sharedInstance()
        let controller = AudioSessionController { _ in }
        self.controller = controller

        controller.begin()
        controller.begin()
        settle({ session.useManualAudio }, "the session is not in manual audio")
        controller.enableAudio()
        settle({ session.isAudioEnabled }, "the audio unit was not handed over")
        controller.enableAudio()
        XCTAssertTrue(session.isAudioEnabled, "a second connected call turned the audio off")

        controller.end()
        controller.end()
        settle({ !session.isAudioEnabled }, "the audio unit outlived the call")
        // A session that was never begun is still safe to end.
        AudioSessionController { _ in }.end()
    }

    // MARK: - the screen

    /// The screen must not time out while video is on screen, and on a one-way
    /// call the camera that matters is the **peer's**: the stage is drawn for
    /// either one and Android binds `FLAG_KEEP_SCREEN_ON` to exactly that
    /// (`MainActivity.java:533-537`; `call-v2.md`, owner request 2026-09-12).
    ///
    /// The proximity sensor is deliberately not measured beside it: a
    /// simulator has no sensor to enable it with, so every assertion about it
    /// here would pass whatever the client did. What decides it —
    /// `held && audible && !video && !speaker && !isHeadsetRoute`, against
    /// Android's `!speaker && connected && !videoEnabled`
    /// (`WebRtcAudioEngine.java:399-401`): local-only, and never armed while a
    /// call is merely ringing. That comparison is made by
    /// `test_ui_contract.py`, which reads both lines.
    func testEitherCameraKeepsTheScreenAwake() {
        let controller = AudioSessionController { _ in }
        self.controller = controller

        controller.begin()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled,
                       "an audio-only call took the system screen timeout away")

        // The peer's camera alone: the ordinary one-way video call.
        controller.setRemoteVideo(true)
        settle({ UIApplication.shared.isIdleTimerDisabled },
               "the screen may time out while the peer's camera is on")
        // This device's camera alone.
        controller.setVideo(true)
        controller.setRemoteVideo(false)
        settle({ UIApplication.shared.isIdleTimerDisabled },
               "the screen may time out while the local camera is on")
        // Neither: an audio-only call keeps the system timeout.
        controller.setVideo(false)
        settle({ !UIApplication.shared.isIdleTimerDisabled },
               "a call with both cameras off still held the screen awake")

        // And the call itself gives it back, camera or no camera.
        controller.setRemoteVideo(true)
        settle({ UIApplication.shared.isIdleTimerDisabled }, "the screen was not held awake")
        controller.end()
        settle({ !UIApplication.shared.isIdleTimerDisabled },
               "the screen stayed awake after the call ended")
    }

    /// A call before any media exists never hands the audio unit over, however
    /// long it rings: only ``AudioSessionController/enableAudio()`` does that,
    /// and only `connected` calls it.
    func testARingingCallNeverGetsTheAudioUnitOnItsOwn() {
        let session = RTCAudioSession.sharedInstance()
        let controller = AudioSessionController { _ in }
        self.controller = controller

        controller.begin()
        controller.setSpeaker(true)
        controller.setVideo(true)
        controller.setVideo(false)
        controller.setSpeaker(false)
        settle({ session.useManualAudio }, "the session is not in manual audio")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(session.isAudioEnabled,
                       "the route and camera controls opened the microphone")
    }
}
