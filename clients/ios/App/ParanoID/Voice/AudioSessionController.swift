import AVFoundation
import Foundation
import ParanoidKit
import UIKit
import WebRTC

/// Owns call/alert session configuration on one serial control queue.
/// CallTones consumes ordered authenticated presentations on that queue; all
/// player I/O (including the zero-volume keep-alive) uses QueuedCallToneOutput.
/// Incoming is foreground-only ambient: system silent-switch behavior applies,
/// no recording mode is acquired. Explicit Call/Answer prepares playAndRecord /
/// voiceChat and awaits activation before its first control. Only connected
/// media may enable libwebrtc; close requests capture revocation without waiting
/// for a player. A caller's terminal busy tail may retain an ALREADY-owned output
/// route for two seconds, with capture off, then stop-ACK precedes deactivation.
/// Route/video/proximity remain owned here. OS API failures are reported to the
/// policy as failures, not represented as confirmed physical audio behavior.
/// RTCAudioSession's pinned setActive(false) consumes a logical activation even
/// on failure; reset keeps activationCount. See RFC-0025 for that accounting.
final class AudioSessionController: @unchecked Sendable {
    /// What can take the audio away from a live call.
    enum Interruption: Sendable, Equatable {
        /// The system interrupted this session — a cellular call, Siri, an
        /// alarm. `voice-v1.md` has no "paused call": the call ends.
        case began
        /// The media server died and every session object of this process is
        /// invalid until it is rebuilt.
        case mediaServicesLost
    }

    /// The session a call runs on (`WebRtcAudioEngine.java:88-95`:
    /// `MODE_IN_COMMUNICATION` with Bluetooth SCO allowed).
    ///
    /// `.voiceChat` is the mode that gives the call the system's own echo
    /// canceller and the earpiece as the default output;
    /// `.allowBluetoothHFP` is the current spelling of `.allowBluetooth`
    /// (same option, renamed in iOS 26) and is what `.voiceChat` needs before
    /// a headset can carry the microphone.
    static let incomingCategory = AVAudioSession.Category.ambient
    static let category = AVAudioSession.Category.playAndRecord
    static let mode = AVAudioSession.Mode.voiceChat
    static let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]

    /// The ports that carry both directions of a call themselves, and for
    /// which the speakerphone is never forced (`call-v2.md`: "camera on routes
    /// audio to the speakerphone **unless** a wired or Bluetooth headset is
    /// the active route").
    static let headsetPorts: Set<AVAudioSession.Port> = [
        .headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE,
        .carAudio, .usbAudio,
    ]

    /// The silent loop that holds the `audio` background mode until media
    /// flows: 8 kHz mono, half a second of zeroes, repeated at volume 0.
    static let keepAliveSeconds = 0.5
    static let keepAliveSampleRate = 8_000

    private let queue = DispatchQueue(label: "global.paranoid.voice.audio")
    private let toneOutput = QueuedCallToneOutput()
    private var foreground = false
    private var incomingOnly = false
    private var presentedState: CallController.State = .idle
    private var presentedCallId = ""
    private lazy var toneDriver = CallTones(queue: queue, session: ToneSessionPort(self),
                                           output: toneOutput, foreground: foreground)
    private let events: @Sendable (Interruption) -> Void

    /// Whether this type activated the session and still holds it.
    private var held = false
    /// Whether libwebrtc's audio unit has been switched on (`connected`).
    ///
    /// It is also the proximity sensor's gate, which is what Android's
    /// `boolean earpiece = !speaker && connected && !videoEnabled;`
    /// (`WebRtcAudioEngine.java:401`) says: a call that is only **ringing**
    /// must never blank the screen. One difference from Android is deliberate
    /// and is not parity — Android calls `updateProximity()` from both
    /// transitions (`:513,:515`), so it releases the sensor for the length of
    /// a `disconnected` one, and this flag stays set through a reconnection,
    /// because a call that is recovering is a call the phone has not left the
    /// ear for.
    private var audible = false
    private var speaker = false
    /// This device's own camera. It decides the proximity sensor and, with
    /// ``remoteVideo``, the screen.
    private var video = false
    /// The peer's camera. Like local video, it keeps the stage visible and
    /// prevents proximity blanking; it does not change the audio route.
    private var remoteVideo = false
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter events: where an interruption goes. It is called on this
    ///   type's own queue, never on the main thread and never on the owner.
    init(events: @escaping @Sendable (Interruption) -> Void) {
        self.events = events
        subscribe()
        Task { @MainActor [weak self] in
            let active = UIApplication.shared.applicationState == .active
            self?.setForeground(active)
        }
    }

    private final class ToneSessionPort: CallToneSessionPort {
        private weak var owner: AudioSessionController?
        init(_ owner: AudioSessionController) { self.owner = owner }
        func activate(_ mode: CallTones.Mode) -> Bool { owner?.activateToneMode(mode) ?? false }
        func deactivate() -> Bool { owner?.deactivateToneMode() ?? false }
        func media(_ enabled: Bool) { owner?.setMediaForTones(enabled) }
    }

    private func setForeground(_ value: Bool) {
        queue.async { [self] in foreground = value; toneDriver.setForeground(value) }
    }

    /// Ordered on the same queue as session policy, not via an independent UI hop.
    func callChanged(_ presentation: CallPresentation) {
        queue.async { [self] in
            if presentation.state == .incoming,
               presentedState != .incoming || presentedCallId != presentation.callId { speaker = false }
            presentedState = presentation.state; presentedCallId = presentation.callId
            toneDriver.changed(state: presentation.state, callId: presentation.callId, reason: presentation.reason)
        }
    }

    func restoreIncoming() { queue.async { [self] in toneDriver.restoreIncoming() } }
    func quiesceMedia() {
        queue.async { [self] in
            video = false; remoteVideo = false
            toneDriver.quiesceMedia()
            applyRoute()
        }
    }


    // MARK: - The call's audio

    /// Fire-and-forget preparation retained for platform tests. The application
    /// uses prepareForCall() to await real readiness before sending controls.
    func begin() {
        queue.async { [self] in toneDriver.prepareCall() }
    }

    /// Call/Answer waits for real session readiness, not merely enqueuing begin().
    /// Timeout/cancellation never waits for a blocked player or platform operation.
    func prepareForCall(timeout: TimeInterval = 10) async -> Bool {
        let reply = AudioPreparationReply()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard reply.install(continuation) else { return }
                let timer = DispatchWorkItem { [weak reply] in reply?.finish(false) }
                reply.arm(timer)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                queue.async { [self] in
                    guard reply.isPending else { return }
                    toneDriver.prepareCall { value in reply.finish(value) }
                }
            }
        }, onCancel: { reply.finish(false) })
    }

    /// The call is actually connected: hand the audio unit to libwebrtc and
    /// stop the silent loop.
    ///
    /// Nothing before `connected` may do this. A signaling state is not a
    /// connection (`voice-v1.md:107-108`), and an audio unit started earlier
    /// would open the microphone before there is a call to carry it.
    func enableAudio() {
        queue.async { [self] in toneDriver.enableAudio() }
    }

    /// «Громкая связь» / «Телефонный динамик».
    ///
    /// A headset that is already carrying the call keeps it: the override is
    /// what the speakerphone button means, not a way to take audio off the
    /// user's headphones (`call-v2.md`, the camera-on route rule).
    func setSpeaker(_ enabled: Bool) {
        queue.async { [self] in
            speaker = enabled
            applyRoute()
        }
    }

    /// Whether **this device's** camera is on. It decides two things and no
    /// audio at all: the proximity sensor is off while the local camera is on,
    /// because the user is looking at the screen — Android's
    /// `!speaker && connected && !videoEnabled`
    /// (`WebRtcAudioEngine.java:399-401`), whose `connected` is ``audible``
    /// here, with the one documented difference recorded on that property —
    /// and, together with ``setRemoteVideo(_:)``, the screen stays awake while
    /// any video is on screen (`call-v2.md`, owner request 2026-09-12).
    func setVideo(_ enabled: Bool) {
        queue.async { [self] in
            video = enabled
            applyRoute()
        }
    }

    /// Whether the **peer's** camera is on. It keeps the screen awake and
    /// disables proximity blanking without changing the audio route.
    ///
    /// A call with the peer's camera on and this device's off is the ordinary
    /// one-way video call, and it is drawn with the same stage as a two-way
    /// one (`CallScreen.showsStage`, `MainActivity.java:533-537`:
    /// `showStage = live && (localVideo || remoteVideo)`, with
    /// `FLAG_KEEP_SCREEN_ON` bound to that flag). Either camera also disables
    /// proximity blanking: keeping the idle timer off alone cannot keep a
    /// remote-only video stage visible when the proximity sensor is covered.
    func setRemoteVideo(_ enabled: Bool) {
        queue.async { [self] in
            remoteVideo = enabled
            applyRoute()
        }
    }

    /// An interruption-end permits bounded output/session recovery, never
    /// automatic capture resumption. A connected call is ended by its owner.
    private func resume() {
        queue.async { [self] in toneDriver.setInterrupted(false) }
    }

    /// Releases the session and everything taken with it.
    ///
    /// Idempotent, and safe after a failed ``begin()``: the same members are
    /// cleared either way, so a call that never got its audio still gives the
    /// route back to whatever had it.
    func end() {
        queue.async { [self] in
            speaker = false; video = false; remoteVideo = false
            // Keep this adapter alive until queued player stop/session cleanup
            // has been attempted, including when a test drops its last reference.
            toneDriver.release { [self] in applyRoute() }
        }
    }

    private func activateToneMode(_ mode: CallTones.Mode) -> Bool {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        session.lockForConfiguration()
        do {
            try session.setCategory(mode == .incoming ? Self.incomingCategory : Self.category,
                                    mode: mode == .incoming ? .default : Self.mode,
                                    options: mode == .incoming ? [] : Self.options)
            try session.setActive(true)
            held = true; incomingOnly = mode == .incoming; audible = false
        } catch { session.unlockForConfiguration(); return false }
        session.unlockForConfiguration()
        applyRoute()
        return true
    }

    private func setMediaForTones(_ enabled: Bool) {
        guard !enabled || (held && !incomingOnly) else { return }
        RTCAudioSession.sharedInstance().isAudioEnabled = enabled
        audible = enabled
        applyRoute()
    }

    private func deactivateToneMode() -> Bool {
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false; audible = false
        if presentedState == .ended || presentedState == .idle { speaker = false }
        if held {
            session.lockForConfiguration()
            if !incomingOnly { try? session.overrideOutputAudioPort(.none) }
            do { try session.setActive(false) }
            catch {
                session.unlockForConfiguration()
                held = false // the SDK balances the lease even when setActive(false) throws
                incomingOnly = false
                applyRoute(); return false
            }
            session.unlockForConfiguration()
        }
        held = false; incomingOnly = false
        applyRoute()
        return true
    }

    /// Whether a wired or Bluetooth headset is carrying the call right now.
    var isHeadsetRoute: Bool {
        let outputs = RTCAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { Self.headsetPorts.contains($0.portType) }
    }

    // MARK: - The route, the proximity sensor and the screen

    /// Pure decision used by the route application and deterministic tests.
    /// Neither local nor remote video may be hidden by proximity blanking.
    static func screenPolicy(held: Bool, audible: Bool, video: Bool, remoteVideo: Bool,
                             speaker: Bool, headset: Bool) -> (proximity: Bool, awake: Bool) {
        let proximity = held && audible && !video && !remoteVideo && !speaker && !headset
        let awake = held && (video || remoteVideo)
        return (proximity, awake)
    }

    /// Applies routing and screen policy on ``queue``.
    private func applyRoute() {
        let session = RTCAudioSession.sharedInstance()
        if held && !incomingOnly {
            let wantsSpeaker = speaker && !isHeadsetRoute
            session.lockForConfiguration()
            try? session.overrideOutputAudioPort(wantsSpeaker ? .speaker : .none)
            session.unlockForConfiguration()
        }
        // Ringing never blanks the screen; either video direction must remain
        // visible. Audio-only earpiece behavior is unchanged.
        let policy = Self.screenPolicy(held: held, audible: audible, video: video,
                                       remoteVideo: remoteVideo, speaker: speaker,
                                       headset: isHeadsetRoute)
        Task { @MainActor in
            UIDevice.current.isProximityMonitoringEnabled = policy.proximity
            UIApplication.shared.isIdleTimerDisabled = policy.awake
        }
    }

    // MARK: - Silent keep-alive waveform (played only by QueuedCallToneOutput)

    /// A minimal 16-bit PCM WAVE file of silence, built here rather than
    /// shipped as a resource: an asset in the bundle would be one more file to
    /// keep in the notices and one more thing a build could lose.
    static func silence() -> [UInt8] {
        let frames = Int(Double(keepAliveSampleRate) * keepAliveSeconds)
        let dataBytes = frames * 2
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
        u32(keepAliveSampleRate)
        u32(keepAliveSampleRate * 2)              // bytes per second
        u16(2)                                    // block alignment
        u16(16)                                   // bits per sample
        ascii("data")
        u32(dataBytes)
        wave.append(contentsOf: [UInt8](repeating: 0, count: dataBytes))
        return wave
    }

    // MARK: - What the system says

    private func subscribe() {
        guard observers.isEmpty else { return }
        let centre = NotificationCenter.default
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true),
                               (UIApplication.willResignActiveNotification, false),
                               (UIApplication.didEnterBackgroundNotification, false)] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setForeground(active)
            })
        }
        observers.append(centre.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began: queue.async { self.toneDriver.setInterrupted(true); self.events(.began) }
            case .ended: resume()
            default: break
            }
        })
        observers.append(centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async {
                self.audible = false // SDK reset keeps activationCount; driver must balance the old lease
                self.toneDriver.mediaServicesReset()
                self.events(.mediaServicesLost)
            }
        })
        observers.append(centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            // Not a failure: a headset arriving or leaving only moves the
            // speakerphone decision and the proximity sensor with it.
            queue.async { self.applyRoute() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
