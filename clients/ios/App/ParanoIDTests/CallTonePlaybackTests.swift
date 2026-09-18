import Foundation
import XCTest
@testable import ParanoID

final class CallTonePlaybackTests: XCTestCase {
    private final class Player: CallTonePlayer, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let held: Bool
        let succeeds: Bool
        private let lock = NSLock()
        private var storedVolume: Float = 1
        private var loud = 0
        private var stopped = 0
        var numberOfLoops = 0 // accessed only on playback queue
        init(held: Bool = false, succeeds: Bool = true) { self.held = held; self.succeeds = succeeds }
        var volume: Float {
            get { lock.lock(); defer { lock.unlock() }; return storedVolume }
            set { lock.lock(); storedVolume = newValue; if newValue > 0 { loud += 1 }; lock.unlock() }
        }
        func play() -> Bool {
            entered.signal()
            if held, proceed.wait(timeout: .now() + 5) != .success { return false }
            return succeeds
        }
        func stop() { lock.lock(); stopped += 1; lock.unlock() }
        var observations: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (loud, stopped) }
    }
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testHeldPlayDoesNotBlockCancellationAndNeverUnmutesAfterCancellation() {
        let player = Player(held: true), result = Result()
        defer { player.proceed.signal() }
        let output = QueuedCallToneOutput(haptics: false, makePlayer: { _ in player })
        let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        output.stop(token: 1) { ready.signal() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        output.start(.ring, token: 1, deadline: nil) { value in result.set(value); finished.signal() }
        XCTAssertEqual(player.entered.wait(timeout: .now() + 2), .success)
        let cancelled = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.audio-control").async {
            output.stop(token: 2) { stopped.signal() }
            cancelled.signal()
        }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 2), .success, "cancel must not wait for blocked play()")
        player.proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.get(), false)
        XCTAssertEqual(player.observations.0, 0, "stale request was never made audible")
        XCTAssertGreaterThan(player.observations.1, 0)
    }

    func testFalsePlayIsReportedAndNotUnmuted() {
        let player = Player(succeeds: false), result = Result()
        let output = QueuedCallToneOutput(haptics: false, makePlayer: { _ in player })
        let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        output.stop(token: 1) { ready.signal() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        output.start(.busy, token: 1, deadline: nil) { value in result.set(value); finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.get(), false); XCTAssertEqual(player.observations.0, 0)
        XCTAssertGreaterThan(player.observations.1, 0)
    }

    func testExpiredRequestNeverCallsPlay() {
        let player = Player(), result = Result()
        let output = QueuedCallToneOutput(haptics: false, makePlayer: { _ in player })
        let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        output.stop(token: 1) { ready.signal() }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        output.start(.ring, token: 1, deadline: ProcessInfo.processInfo.systemUptime - 1) {
            value in result.set(value); finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.get(), false)
        XCTAssertEqual(player.entered.wait(timeout: .now()), .timedOut)
    }
}
