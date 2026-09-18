import Foundation
import ParanoidKit

/// Session operations run on the audio-control queue. Activation/deactivation
/// follow player-stop acknowledgement; media(false) may revoke immediately, and
/// an already-active call may enable media early only after a proven-silent fence.
protocol CallToneSessionPort: AnyObject {
    func activate(_ mode: CallTones.Mode) -> Bool
    /// Consumes the owned logical SDK lease even if physical deactivation fails.
    func deactivate() -> Bool
    func media(_ enabled: Bool)
}

protocol CallToneOutput: AnyObject, Sendable {
    var mayHaveAudiblePlayback: Bool { get }
    func stop(token: UInt64, completion: @escaping @Sendable () -> Void)
    func start(_ pattern: CallTones.Pattern, token: UInt64, deadline: TimeInterval?,
               completion: @escaping @Sendable (Bool) -> Void)
}

/// Queue-confined audio policy. No player/system calls execute on the UI or state owner.
/// `confirmedStart` means play() accepted the current request, NOT physical audibility.
/// Unchecked Sendable only permits callbacks to hop back onto `queue`; all mutable
/// policy/session state is accessed exclusively on that queue.
final class CallTones: @unchecked Sendable {
    enum Sound: String, Sendable { case ring, ringback, busy }
    enum Mode: Sendable, Equatable { case incoming, call }
    enum Pattern: Sendable, Equatable { case ring, ringback, busy, keepAlive }
    static let maximumRingSeconds: TimeInterval = 60
    static let busySeconds: TimeInterval = 2
    static let toneVolume: Float = 0.7
    static let sampleRate = 8_000

    private let queue: DispatchQueue
    private let session: any CallToneSessionPort
    private let output: any CallToneOutput
    private let now: @Sendable () -> TimeInterval
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var state: CallController.State = .idle
    private var callId = ""
    private var outgoing = false
    private var wantedMode: Mode?
    private var currentMode: Mode?
    private var needsSessionRefresh = false
    private var preparedReplies: [@Sendable (Bool) -> Void] = []
    private var wantedSound: Sound?
    private var capture = false
    private var terminal = false
    private var foreground: Bool
    private var interrupted = false
    private var deadline: TimeInterval?
    private var incomingDeadline: TimeInterval?
    private var epoch: UInt64 = 0
    private var appliedEpoch: UInt64?
    private var expiry: DispatchWorkItem?
    private var afterRelease: (() -> Void)?
    private(set) var confirmedStart: Sound?
    private(set) var lastFailure: String?

    init(queue: DispatchQueue, session: any CallToneSessionPort, output: any CallToneOutput,
         foreground: Bool = true,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: ((TimeInterval, DispatchWorkItem) -> Void)? = nil) {
        self.queue = queue; self.session = session; self.output = output
        self.foreground = foreground; self.now = now
        self.schedule = schedule ?? { delay, item in queue.asyncAfter(deadline: .now() + delay, execute: item) }
    }

    func prepareCall(onReady: (@Sendable (Bool) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let onReady { preparedReplies.append(onReady) }
        let recovering = interrupted
        interrupted = false // a fresh explicit intent may retry the OS
        if wantedMode == .call && !terminal && !recovering {
            if currentMode == .call && !needsSessionRefresh && appliedEpoch == epoch { resolvePrepared(true) }
            else { reconcile() }
            return
        }
        finishRelease()
        wantedMode = .call; capture = false; terminal = false
        wantedSound = nil; deadline = nil
        session.media(false)
        reconcile()
    }

    /// An abandoned Answer intent must not take an existing incoming call's audio away.
    func restoreIncoming() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .incoming else { return }
        wantedMode = .incoming; wantedSound = .ring; capture = false; terminal = false
        deadline = incomingDeadline
        reconcile()
    }

    func enableAudio() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard wantedMode == .call, !interrupted, !terminal else { return }
        capture = true; wantedSound = nil; deadline = nil
        reconcile()
    }

    /// Capture is revoked immediately, even while an old player's I/O is held.
    func quiesceMedia() {
        dispatchPrecondition(condition: .onQueue(queue))
        capture = false
        session.media(false)
    }

    func changed(state next: CallController.State, callId id: String, reason: CallBody.EndReason?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard next != state || id != callId else { return }
        let wasOutgoingRinging = state == .outgoing && outgoing && id == callId
        if next == .starting { outgoing = true } else if next == .incoming { outgoing = false }
        state = next; callId = id; wantedSound = nil; deadline = nil; terminal = false
        switch next {
        case .incoming:
            wantedMode = .incoming; capture = false; wantedSound = .ring
            incomingDeadline = now() + Self.maximumRingSeconds; deadline = incomingDeadline
        case .starting, .authorizing, .connecting:
            wantedMode = .call; capture = false
        case .outgoing:
            wantedMode = .call; capture = false
            if outgoing { wantedSound = .ringback }
        case .connected:
            wantedMode = .call; capture = !interrupted
        case .ended:
            capture = false; terminal = true; wantedMode = nil
            // A terminal sound may retain an existing caller output session;
            // it can never acquire an input-capable session just to play busy.
            if wasOutgoingRinging, currentMode == .call,
               reason == .busy || reason == .reject || reason == .timeout {
                wantedSound = .busy; wantedMode = .call; deadline = now() + Self.busySeconds
            }
        case .idle:
            wantedMode = nil; capture = false
        }
        if next == .idle || next == .ended { outgoing = false }
        if !capture { session.media(false) }
        reconcile()
    }

    func setForeground(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let recovering = value && interrupted
        if recovering { interrupted = false; capture = false }
        let changed = foreground != value
        foreground = value
        if (changed && wantedMode == .incoming) || recovering { reconcile() }
    }

    /// Inactive permission alerts only pause incoming output; actual background
    /// also abandons a pre-call preparation that has no live call behind it.
    func cancelPreparationForBackground() {
        dispatchPrecondition(condition: .onQueue(queue))
        if state == .incoming && wantedMode == .call && !capture {
            resolvePrepared(false); restoreIncoming()
        } else if (state == .idle || state == .ended) && !terminal {
            wantedMode = nil; wantedSound = nil; deadline = nil; capture = false
            resolvePrepared(false); session.media(false); reconcile()
        }
    }

    func setInterrupted(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        interrupted = value
        // An interruption never grants capture again on resume.
        if value {
            needsSessionRefresh = true // survive an ended/foreground event that supersedes the stop ACK
            capture = false; session.media(false); resolvePrepared(false)
        }
        reconcile()
    }

    func mediaServicesReset() {
        dispatchPrecondition(condition: .onQueue(queue))
        needsSessionRefresh = true; interrupted = false; capture = false
        session.media(false)
        reconcile()
    }

    func release(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        afterRelease = completion
        interrupted = false
        resolvePrepared(false)
        state = .idle; callId = ""; outgoing = false; terminal = false
        wantedMode = nil; wantedSound = nil; capture = false; deadline = nil; incomingDeadline = nil
        session.media(false)
        reconcile()
    }

    private func resolvePrepared(_ result: Bool) {
        let replies = preparedReplies; preparedReplies.removeAll()
        for reply in replies { reply(result) }
    }

    private func finishRelease() {
        let completion = afterRelease; afterRelease = nil; completion?()
    }

    private func expireIfDue() {
        if let deadline, now() >= deadline {
            wantedSound = nil; wantedMode = nil; capture = false; self.deadline = nil
        }
    }

    private func reconcile() {
        expireIfDue()
        epoch &+= 1
        let token = epoch
        expiry?.cancel(); expiry = nil; confirmedStart = nil
        if let deadline {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.epoch == token else { return }
                self.reconcile()
            }
            expiry = work
            schedule(max(0, deadline - now()), work)
        }
        // stop() invalidates in-flight player work synchronously, but never waits
        // for that work here. Session changes happen only after its acknowledgement.
        output.stop(token: token) { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.epoch == token else { return }
                self.apply(token: token)
            }
        }
        // Preserve the old silent-keepalive fast path: a stalled zero-volume
        // player must not hold up connected media. stop() has already revoked
        // its token; the backend conservatively marks audible work BEFORE any
        // volume increase, so false here excludes a later stale unmute.
        if capture, currentMode == .call, wantedMode == .call, !interrupted, !terminal, !needsSessionRefresh,
           !output.mayHaveAudiblePlayback { session.media(true) }
    }

    private func apply(token: UInt64) {
        if let deadline, now() >= deadline { reconcile(); return }
        let mode: Mode? = interrupted || (wantedMode == .incoming && !foreground) ? nil : wantedMode
        if currentMode != mode || needsSessionRefresh {
            session.media(false)
            if currentMode != nil {
                let released = session.deactivate()
                currentMode = nil // RTCAudioSession consumes its activation count even on failure
                needsSessionRefresh = false
                guard released else { lastFailure = "deactivate_failed"; finishRelease(); resolvePrepared(false); return }
            }
            if let mode {
                // Busy is retention only. An interruption/reset may have
                // consumed the old lease; a terminal sound cannot acquire it anew.
                guard !terminal else {
                    wantedMode = nil; wantedSound = nil; deadline = nil
                    expiry?.cancel(); expiry = nil
                    finishRelease(); resolvePrepared(false); return
                }
                guard session.activate(mode) else { lastFailure = "activate_failed"; finishRelease(); resolvePrepared(false); return }
                currentMode = mode
                needsSessionRefresh = false
            }
        }
        guard let mode else { finishRelease(); resolvePrepared(false); return }
        session.media(capture && mode == .call && !terminal && !interrupted)
        finishRelease()
        appliedEpoch = token
        resolvePrepared(mode == .call && !terminal && !interrupted)
        guard !capture else { return }
        let pattern: Pattern
        switch wantedSound {
        case .ring: pattern = .ring
        case .ringback: pattern = .ringback
        case .busy: pattern = .busy
        case nil:
            guard mode == .call, !terminal else { return }
            pattern = .keepAlive
        }
        let sound = wantedSound
        output.start(pattern, token: token, deadline: deadline) { [weak self] started in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.epoch == token else { return }
                if started {
                    self.confirmedStart = sound; self.lastFailure = nil
                } else {
                    self.confirmedStart = nil; self.lastFailure = "play_failed"
                    // Do not retry in a loop. A real later transition/resume may
                    // try again. A failed incoming/terminal alert needs no session.
                    if self.wantedMode == .incoming || self.terminal {
                        self.wantedMode = nil; self.wantedSound = nil; self.deadline = nil
                        self.reconcile()
                    }
                }
            }
        }
    }

    static func ringbackPattern() -> [UInt8] { wave(segments: [(425, 1), (0, 4)]) }
    static func busyPattern() -> [UInt8] {
        wave(segments: [(425, 0.35), (0, 0.35), (425, 0.35), (0, 0.35), (425, 0.35), (0, 0.25)])
    }
    static func ringPattern() -> [UInt8] { wave(segments: [(440, 0.4), (0, 0.2), (480, 0.4), (0, 3)]) }

    static func wave(segments: [(Int, Double)]) -> [UInt8] {
        var samples: [Int16] = []
        for (frequency, seconds) in segments {
            let frames = Int((Double(sampleRate) * seconds).rounded())
            guard frequency > 0 else { samples.append(contentsOf: repeatElement(Int16(0), count: frames)); continue }
            let step = 2 * Double.pi * Double(frequency) / Double(sampleRate)
            for frame in 0..<frames {
                let edge = min(Double(frame), Double(frames - frame)) / Double(sampleRate)
                samples.append(Int16(sin(step * Double(frame)) * min(1, edge / 0.005) * 22_000))
            }
        }
        return container(samples)
    }
    private static func container(_ samples: [Int16]) -> [UInt8] {
        var wave: [UInt8] = []
        func ascii(_ text: String) { wave.append(contentsOf: text.utf8) }
        func u32(_ value: Int) {
            let n = UInt32(value); wave.append(contentsOf: (0..<4).map { UInt8((n >> (8 * $0)) & 0xff) })
        }
        func u16(_ value: Int) {
            let n = UInt16(value); wave.append(contentsOf: (0..<2).map { UInt8((n >> (8 * $0)) & 0xff) })
        }
        ascii("RIFF"); u32(36 + samples.count * 2); ascii("WAVE"); ascii("fmt ")
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(samples.count * 2)
        for sample in samples {
            let n = UInt16(bitPattern: sample)
            wave.append(contentsOf: (0..<2).map { UInt8((n >> (8 * $0)) & 0xff) })
        }
        return wave
    }
}
