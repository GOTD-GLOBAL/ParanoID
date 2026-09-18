import AVFoundation
import Foundation
import ParanoidKit
import UIKit

/// Audible call progress, the counterpart of
/// `clients/android/src/org/paranoid/text/CallTones.java` (owner request
/// 2026-09-12, brought to this client 2026-09-18).
///
/// Android gives a call three sounds: the system ringtone with vibration while
/// a call is coming in, a ringback while the peer's phone is ringing, and a
/// short busy tone when an outgoing call ends unanswered. This client had none
/// of them, and a caller heard up to forty-five seconds of silence with only
/// «Вызываем…» on screen to say anything was happening.
///
/// ## What drives it
///
/// The same thing that drives Android: the authenticated `CallController`
/// view, applied on every transition and idempotent per `(state, callId)`. It
/// is fed from ``CallCoordinator/changed(_:)``, which is this client's
/// `TextEngine.java:92-102`, so a sound can only follow a state the controller
/// actually published — never a screen, a tap or a timer of the interface.
///
/// ## What it may not do
///
/// It opens no microphone, holds no authority and touches neither camera nor
/// media engine. It plays into the session ``AudioSessionController`` already
/// owns, so it follows the call's own route: earpiece, speaker or headset, as
/// the media engine chose. It plays nothing at all once the call is
/// `connected` — from there the only sound is the other person.
///
/// ## Two deliberate differences from Android
///
/// - **The ring is synthesised, not the system ringtone.** iOS exposes no API
///   that reads the user's chosen ringtone, and the system-sound API that
///   plays one is refused by `test_ui_contract.py` because it ignores the
///   call's audio route and the silent switch. The pattern below is the
///   familiar double-burst instead.
/// - **An incoming call can only ring while the application is open.** This
///   client has no push and no CallKit, so a call cannot reach a closed or
///   locked phone at all — the caption contract already tells the user so
///   (`clients/ios/test/captions.txt`). Android rings from a background
///   notification, which is the capability this client does not have, and that
///   difference is about delivery, not about sound.
@MainActor
final class CallTones {
    /// The longest an incoming ring may last, matching `MAX_RING_MS`.
    static let maximumRingSeconds: TimeInterval = 60
    /// How long the busy tone lasts, matching `BUSY_MS`.
    static let busySeconds: TimeInterval = 2
    /// Android plays its two call tones at seven tenths of the maximum.
    static let toneVolume: Float = 0.7
    /// 8 kHz mono, the rate the silent keep-alive already uses.
    static let sampleRate = 8_000

    /// One of the three sounds this type can make.
    enum Sound: String, CaseIterable, Sendable {
        case ring, ringback, busy
    }

    /// What is sounding right now. The tests read it, so that the state
    /// machine can be measured without listening to a simulator; nothing in
    /// the application reads it.
    var sounding: Set<Sound> {
        var live: Set<Sound> = []
        if ring != nil { live.insert(.ring) }
        if ringback != nil { live.insert(.ringback) }
        if busy != nil { live.insert(.busy) }
        return live
    }

    private var state: CallController.State = .idle
    private var callId = ""
    private var outgoing = false

    private var ring: AVAudioPlayer?
    private var ringback: AVAudioPlayer?
    private var busy: AVAudioPlayer?
    private var ringLimit: Task<Void, Never>?
    private var haptics: Task<Void, Never>?

    /// Applies one published call view, as the three facts a sound depends on.
    ///
    /// Idempotent per transition: the same state for the same call changes
    /// nothing, exactly as on Android. The arguments are taken apart at the
    /// call site rather than passed as `CallPresentation`, because that type
    /// has no public initializer and a sound rule that cannot be built in a
    /// test is a sound rule nobody can measure.
    func changed(state next: CallController.State, callId id: String, reason: CallBody.EndReason?) {
        guard next != state || id != callId else { return }
        let wasOutgoingRinging = state == .outgoing && outgoing
        if next == .starting { outgoing = true } else if next == .incoming { outgoing = false }
        state = next
        callId = id

        if next == .incoming { startRing() } else { stopRing() }
        if next == .outgoing, outgoing { startRingback() } else { stopRingback() }

        // A busy tone answers only an outgoing call that was still ringing:
        // the peer refused it, was already in a call, or never picked up.
        if next == .ended, wasOutgoingRinging,
           reason == .busy || reason == .reject || reason == .timeout {
            startBusy()
        } else if next != .ended {
            stopBusy()
        }
        if next == .idle || next == .ended { outgoing = false }
    }

    /// Stops everything. Called when the coordinator closes, so a torn-down
    /// call can never leave a sound behind.
    func release() {
        stopRing()
        stopRingback()
        stopBusy()
    }

    // MARK: - the incoming ring

    private func startRing() {
        guard ring == nil else { return }
        ring = play(Self.ringPattern(), loops: -1)
        startHaptics()
        ringLimit?.cancel()
        ringLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumRingSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRing()
        }
    }

    private func stopRing() {
        ringLimit?.cancel()
        ringLimit = nil
        ring?.stop()
        ring = nil
        haptics?.cancel()
        haptics = nil
    }

    /// The vibration Android gets from `VibrationEffect`. `UIImpactFeedback`
    /// is the only vibration this client may raise: it respects the silent
    /// switch and the accessibility setting, and it is not the system-sound
    /// API the source contract refuses.
    private func startHaptics() {
        haptics?.cancel()
        haptics = Task { [weak self] in
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            while !Task.isCancelled {
                guard self?.ring != nil else { return }
                generator.impactOccurred()
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                generator.impactOccurred()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    // MARK: - the outgoing ringback and the busy tone

    private func startRingback() {
        guard ringback == nil else { return }
        ringback = play(Self.ringbackPattern(), loops: -1)
    }

    private func stopRingback() {
        ringback?.stop()
        ringback = nil
    }

    private func startBusy() {
        stopBusy()
        busy = play(Self.busyPattern(), loops: 0)
    }

    private func stopBusy() {
        busy?.stop()
        busy = nil
    }

    private func play(_ wave: [UInt8], loops: Int) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: Data(wave)) else { return nil }
        player.numberOfLoops = loops
        player.volume = Self.toneVolume
        player.play()
        return player
    }

    // MARK: - the waves themselves

    /// The ringback of a Russian line: 425 Hz, one second on and four off,
    /// looped. It is built here rather than shipped as a sound file, for the
    /// reason the silent keep-alive is
    /// (`AudioSessionController.silence()`): an asset would be one more file
    /// in the third-party notices and one more thing a build could lose.
    static func ringbackPattern() -> [UInt8] {
        wave(segments: [(425, 1.0), (0, 4.0)])
    }

    /// The busy signal: 425 Hz in bursts of 0.35 s, for two seconds.
    static func busyPattern() -> [UInt8] {
        wave(segments: Array(repeating: [(425, 0.35), (0, 0.35)], count: 3).flatMap { $0 })
    }

    /// The incoming ring: the familiar double burst, then silence, looped.
    static func ringPattern() -> [UInt8] {
        wave(segments: [(440, 0.4), (0, 0.2), (480, 0.4), (0, 3.0)])
    }

    /// A 16-bit PCM WAVE of the given tone segments, each a frequency in hertz
    /// (zero for silence) and a duration in seconds.
    static func wave(segments: [(Int, Double)]) -> [UInt8] {
        var samples: [Int16] = []
        for (frequency, seconds) in segments {
            let frames = Int(Double(sampleRate) * seconds)
            guard frequency > 0 else {
                samples.append(contentsOf: [Int16](repeating: 0, count: frames))
                continue
            }
            let step = 2 * Double.pi * Double(frequency) / Double(sampleRate)
            for frame in 0..<frames {
                // A short fade at each edge, so a burst starts and ends without
                // the click a square cut leaves.
                let edge = min(Double(frame), Double(frames - frame)) / Double(sampleRate)
                let gain = min(1.0, edge / 0.005)
                samples.append(Int16(sin(step * Double(frame)) * gain * 22_000))
            }
        }
        return container(samples)
    }

    private static func container(_ samples: [Int16]) -> [UInt8] {
        let dataBytes = samples.count * 2
        var wave: [UInt8] = []
        func ascii(_ text: String) { wave.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) {
            let number = UInt32(value)
            wave.append(contentsOf: (0..<4).map { UInt8((number >> (8 * $0)) & 0xff) })
        }
        func u16(_ value: Int) {
            let number = UInt16(value)
            wave.append(contentsOf: (0..<2).map { UInt8((number >> (8 * $0)) & 0xff) })
        }
        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                                   // PCM header length
        u16(1)                                    // PCM
        u16(1)                                    // one channel
        u32(sampleRate)
        u32(sampleRate * 2)                       // bytes per second
        u16(2)                                    // block alignment
        u16(16)                                   // bits per sample
        ascii("data")
        u32(dataBytes)
        for sample in samples {
            let number = UInt16(bitPattern: sample)
            wave.append(contentsOf: (0..<2).map { UInt8((number >> (8 * $0)) & 0xff) })
        }
        return wave
    }
}
