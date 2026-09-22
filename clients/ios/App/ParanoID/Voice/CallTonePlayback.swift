import AVFoundation
import Foundation
import UIKit

/// Player objects never leave the playback queue. Injectable for held/failed-play tests.
protocol CallTonePlayer: AnyObject {
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    func play() -> Bool
    func stop()
}
private final class PlatformCallTonePlayer: CallTonePlayer {
    private let player: AVAudioPlayer
    init(_ wave: [UInt8]) throws { player = try AVAudioPlayer(data: Data(wave)) }
    var volume: Float { get { player.volume } set { player.volume = newValue } }
    var numberOfLoops: Int { get { player.numberOfLoops } set { player.numberOfLoops = newValue } }
    func play() -> Bool { player.play() }
    func stop() { player.stop() }
}

/// The lock holds only desired-generation metadata, never player or session I/O.
/// All player construction/play/stop work stays on a separate serial executor.
final class QueuedCallToneOutput: CallToneOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "global.paranoid.voice.tones.playback")
    private let lock = NSLock()
    private var wanted: UInt64 = 0
    private var playing: UInt64?
    private var audibleWork = false
    private var player: (any CallTonePlayer)? // playback queue only
    private let makePlayer: @Sendable (CallTones.Pattern) -> (any CallTonePlayer)?
    private let haptics: Bool
    private let now: @Sendable () -> TimeInterval

    init(haptics: Bool = true,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makePlayer: (@Sendable (CallTones.Pattern) -> (any CallTonePlayer)?)? = nil) {
        self.makePlayer = makePlayer ?? { pattern in Self.platformPlayer(pattern) }; self.haptics = haptics; self.now = now
    }

    private static let ringWave = CallTones.ringPattern()
    private static let ringbackWave = CallTones.ringbackPattern()
    private static let busyWave = CallTones.busyPattern()
    private static let keepAliveWave = AudioSessionController.silence()

    private static func platformPlayer(_ pattern: CallTones.Pattern) -> (any CallTonePlayer)? {
        let wave: [UInt8]
        switch pattern {
        case .ring: wave = ringWave
        case .ringback: wave = ringbackWave
        case .busy: wave = busyWave
        case .keepAlive: wave = keepAliveWave
        }
        return try? PlatformCallTonePlayer(wave)
    }

    var mayHaveAudiblePlayback: Bool {
        lock.lock(); defer { lock.unlock() }; return audibleWork
    }
    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return wanted == token
    }
    private func isPlaying(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return wanted == token && playing == token
    }
    func stop(token: UInt64, completion: @escaping @Sendable () -> Void) {
        lock.lock(); wanted = token; playing = nil; lock.unlock()
        queue.async { [self] in
            player?.stop(); player = nil
            lock.lock(); audibleWork = false; lock.unlock()
            completion()
        }
    }
    func start(_ pattern: CallTones.Pattern, token: UInt64, deadline: TimeInterval?,
               completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard isCurrent(token), deadline.map({ now() < $0 }) ?? true,
                  let candidate = makePlayer(pattern) else { completion(false); return }
            candidate.numberOfLoops = pattern == .busy ? 0 : -1
            // A slow play() can return after cancellation. It must never make
            // that obsolete request audible before we can inspect its result.
            candidate.volume = 0
            guard isCurrent(token), deadline.map({ now() < $0 }) ?? true else { candidate.stop(); completion(false); return }
            let started = candidate.play()
            guard started, isCurrent(token), deadline.map({ now() < $0 }) ?? true else {
                candidate.stop(); completion(false); return
            }
            lock.lock()
            let current = wanted == token
            if current { audibleWork = pattern != .keepAlive; playing = token }
            lock.unlock()
            guard current else { candidate.stop(); completion(false); return }
            candidate.volume = pattern == .keepAlive ? 0 : CallTones.toneVolume
            guard isCurrent(token), deadline.map({ now() < $0 }) ?? true else {
                candidate.volume = 0; candidate.stop()
                lock.lock(); audibleWork = false; playing = nil; lock.unlock()
                completion(false); return
            }
            player = candidate
            if pattern == .ring, haptics { startHaptics(token: token) }
            completion(true)
        }
    }

    /// OS feedback policy controls haptics; this is NOT a silent-switch detector.
    private func startHaptics(token: UInt64) {
        Task { @MainActor [weak self] in
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            while !Task.isCancelled {
                guard self?.isPlaying(token) == true, UIApplication.shared.applicationState == .active else { return }
                generator.prepare(); generator.impactOccurred()
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, self?.isPlaying(token) == true,
                      UIApplication.shared.applicationState == .active else { return }
                generator.impactOccurred()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }
}
