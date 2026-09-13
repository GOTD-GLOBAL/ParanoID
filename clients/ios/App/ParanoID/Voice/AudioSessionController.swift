import AVFoundation
import Foundation
import UIKit
import WebRTC

/// The audio session of one call: the part of Android's `WebRtcAudioEngine`
/// that iOS keeps outside the media engine.
///
/// On Android the engine owns the `AudioManager`, the focus request, the
/// speakerphone and the proximity wake lock
/// (`clients/android/src/org/paranoid/text/WebRtcAudioEngine.java:86-140`). On
/// iOS none of that belongs to libwebrtc: the process has exactly one
/// `AVAudioSession`, the route is a property of that session rather than of a
/// peer connection, and the session has to be **running before there is any
/// media at all** — otherwise the `audio` background mode holds nothing and
/// the system may suspend the process while the call is still ringing. So this
/// type owns it, and `WebRtcAudioEngine` owns only tracks.
///
/// ## The order it exists for
///
/// 1. The microphone is granted (the coordinator asks; this type never does).
/// 2. ``begin()`` — **before** the first `knock`, `ready` or Answer — puts
///    libwebrtc into manual audio (`useManualAudio`), leaves its audio unit
///    switched off (`isAudioEnabled = false`), configures the session
///    `.playAndRecord` / `.voiceChat` / Bluetooth HFP and activates it, and
///    starts one silent looping player so that the `audio` background mode has
///    something to hold while the call is still being set up. There is no
///    ringtone: Android rings only from a background notification, and this
///    client has no background (`docs/clients/ios/README.md`, the foreground
///    rule).
/// 3. ``enableAudio()`` at `connected` — and only there — switches the
///    libwebrtc audio unit on, stops the silent player and arms the proximity
///    sensor, because from that instant the call itself is what keeps the
///    session alive (`voice-v1.md:107-108`: only an actual connection is
///    "connected").
/// 4. ``end()`` releases everything and hands the route back to whatever had
///    it before.
///
/// ## What it reports
///
/// An interruption that begins (a cellular call, Siri) and a media-services
/// reset are both the loss of the audio this call is made of, so they are
/// reported and the coordinator ends the call as `failed` — **if** there is
/// media to lose. A call that is still ringing has none, so the coordinator
/// leaves it to its own forty-five-second deadline, and the session the system
/// deactivated is put back by ``resume()`` when the interruption ends;
/// otherwise Answer would hand libwebrtc the audio unit of a session that is
/// no longer running. A route change is not a failure either: it only moves
/// the earpiece/speaker decision, and with it the proximity sensor.
///
/// ## Where it runs
///
/// Every mutable member is touched on ``queue``. `AVAudioSession` and
/// `RTCAudioSession` are process-wide singletons with their own locking, so
/// they are reached from that queue directly; `UIDevice` and `UIApplication`
/// are main-actor and are reached through one hop. Nothing here calls back
/// into the call controller: it hands the coordinator an ``Interruption`` and
/// the coordinator decides.
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
    /// The silent loop runs on a queue of its own, because `AVAudioPlayer`
    /// reaches the audio server: `play()` can take a very long time when that
    /// server is busy or absent (minutes, measured in the simulator), and the
    /// queue above carries the audio unit hand-over and the route. A call must
    /// not wait for the thing that only keeps the background mode alive.
    private let keepAliveQueue = DispatchQueue(label: "global.paranoid.voice.keepalive")
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
    /// The peer's camera. It decides the screen and nothing else.
    private var remoteVideo = false
    /// Both are touched on ``keepAliveQueue`` and nowhere else.
    private var keepAlive: AVAudioPlayer?
    private var keepAliveWanted = false
    private var observers: [any NSObjectProtocol] = []

    /// - Parameter events: where an interruption goes. It is called on this
    ///   type's own queue, never on the main thread and never on the owner.
    init(events: @escaping @Sendable (Interruption) -> Void) {
        self.events = events
    }

    // MARK: - The call's audio

    /// Activates the session for a call that is about to start.
    ///
    /// It is called from the explicit Call and Answer actions, with the
    /// microphone already granted, and **before** the first control leaves
    /// this device: the `audio` background mode is only worth anything while
    /// a session is running, and a knock that goes out first would leave a
    /// window in which the process can be suspended with a call pending.
    ///
    /// Idempotent: a second call while the session is already held does
    /// nothing at all.
    func begin() {
        queue.async { [self] in
            guard !held else { return }
            held = true
            let session = RTCAudioSession.sharedInstance()
            // Manual audio: libwebrtc will not touch the audio unit until this
            // type says so, which is what keeps a ringing call silent
            // (`call-v2.md`: the microphone of an incoming call is off until
            // Answer).
            session.useManualAudio = true
            session.isAudioEnabled = false
            audible = false
            session.lockForConfiguration()
            do {
                try session.setCategory(Self.category, mode: Self.mode, options: Self.options)
                try session.setActive(true)
            } catch {
                // A session that will not activate is not a reason to stop:
                // the call fails on its own deadlines, and `end()` still
                // balances everything this method did.
            }
            session.unlockForConfiguration()
            subscribe()
            startKeepAlive()
            applyRoute()
        }
    }

    /// The call is actually connected: hand the audio unit to libwebrtc and
    /// stop the silent loop.
    ///
    /// Nothing before `connected` may do this. A signaling state is not a
    /// connection (`voice-v1.md:107-108`), and an audio unit started earlier
    /// would open the microphone before there is a call to carry it.
    func enableAudio() {
        queue.async { [self] in
            guard held, !audible else { return }
            audible = true
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            stopKeepAlive()
            // `connected` is also what arms the proximity sensor, so the route
            // is re-applied here and not only from the controls.
            applyRoute()
        }
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

    /// Whether the **peer's** camera is on. It decides the screen and nothing
    /// else.
    ///
    /// A call with the peer's camera on and this device's off is the ordinary
    /// one-way video call, and it is drawn with the same stage as a two-way
    /// one (`CallScreen.showsStage`, `MainActivity.java:533-537`:
    /// `showStage = live && (localVideo || remoteVideo)`, with
    /// `FLAG_KEEP_SCREEN_ON` bound to that flag). The proximity sensor stays
    /// local-only, exactly as on Android (`WebRtcAudioEngine.java:401`): the
    /// peer's camera says nothing about this device being against a face.
    func setRemoteVideo(_ enabled: Bool) {
        queue.async { [self] in
            remoteVideo = enabled
            applyRoute()
        }
    }

    /// The interruption is over and the session has to come back.
    ///
    /// The system deactivates the session it interrupts, and nothing else in
    /// this type ever re-activates one: ``begin()`` returns at once while
    /// ``held`` is set, and ``enableAudio()`` hands libwebrtc the audio unit of
    /// a session it assumes is still running. A call that was **ringing** when
    /// a cellular call, Siri or an alarm arrived is exactly that case — it has
    /// no media yet, so the coordinator does not end it — and without this it
    /// would be answered into a session the system had already taken away. The
    /// silent loop comes back with it while there is still no media.
    ///
    /// A call that already had media never reaches here: the coordinator ends
    /// it on ``Interruption/began`` and ``end()`` clears ``held``.
    private func resume() {
        queue.async { [self] in
            guard held else { return }
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            do {
                try session.setCategory(Self.category, mode: Self.mode, options: Self.options)
                try session.setActive(true)
            } catch {
                // Same rule as `begin()`: a session that will not come back is
                // not a reason to stop, and the call fails on its own
                // deadlines.
            }
            session.unlockForConfiguration()
            if !audible { resumeKeepAlive() }
            applyRoute()
        }
    }

    /// Releases the session and everything taken with it.
    ///
    /// Idempotent, and safe after a failed ``begin()``: the same members are
    /// cleared either way, so a call that never got its audio still gives the
    /// route back to whatever had it.
    func end() {
        queue.async { [self] in
            stopKeepAlive()
            unsubscribe()
            let session = RTCAudioSession.sharedInstance()
            session.isAudioEnabled = false
            audible = false
            if held {
                session.lockForConfiguration()
                // The route goes back before the session does: a speakerphone
                // override is a property of the session this call activated,
                // and whatever had the audio before must not inherit it.
                try? session.overrideOutputAudioPort(.none)
                // `RTCAudioSession` counts activations, so this is the one
                // that balances `begin()`; deactivating notifies whatever was
                // playing before the call that it may resume.
                try? session.setActive(false)
                session.unlockForConfiguration()
            }
            held = false
            speaker = false
            video = false
            remoteVideo = false
            applyRoute()
        }
    }

    /// Whether a wired or Bluetooth headset is carrying the call right now.
    var isHeadsetRoute: Bool {
        let outputs = RTCAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { Self.headsetPorts.contains($0.portType) }
    }

    // MARK: - The route, the proximity sensor and the screen

    /// Applies the speakerphone decision and the two screen behaviours that
    /// follow from it. Called on ``queue``.
    private func applyRoute() {
        let session = RTCAudioSession.sharedInstance()
        if held {
            let wantsSpeaker = speaker && !isHeadsetRoute
            session.lockForConfiguration()
            try? session.overrideOutputAudioPort(wantsSpeaker ? .speaker : .none)
            session.unlockForConfiguration()
        }
        // The earpiece is the only route a face can be against, and the local
        // camera is the one thing that must not be blanked. `audible` is
        // Android's `connected`: a call that is only ringing must never blank
        // the screen, or a phone lying face down would hide «Ответить» from
        // the person it is ringing for (`WebRtcAudioEngine.java:401`).
        let proximity = held && audible && !video && !speaker && !isHeadsetRoute
        // Either camera keeps the screen awake, because the stage is drawn for
        // either one: a one-way video call must not dim halfway through.
        let awake = held && (video || remoteVideo)
        Task { @MainActor in
            UIDevice.current.isProximityMonitoringEnabled = proximity
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    // MARK: - The silent loop

    /// Starts the zero-volume loop that gives the `audio` background mode
    /// something to hold before media exists.
    ///
    /// Everything here happens on ``keepAliveQueue``, so a slow audio server
    /// delays the loop and nothing else. If the call reached `connected` while
    /// `play()` was still returning, the player is stopped the moment it does:
    /// a keep-alive that starts after the media is up would be holding the
    /// session against the call rather than for it.
    private func startKeepAlive() {
        keepAliveQueue.async { [self] in
            keepAliveWanted = true
            guard keepAlive == nil,
                  let player = try? AVAudioPlayer(data: Data(Self.silence()))
            else { return }
            player.numberOfLoops = -1
            player.volume = 0
            keepAlive = player
            player.play()
            if !keepAliveWanted {
                player.stop()
                keepAlive = nil
            }
        }
    }

    /// Plays the loop again after an interruption stopped it.
    ///
    /// It never builds a player: a call that has no keep-alive any more is one
    /// that reached `connected`, and starting a loop there would hold the
    /// session against the call rather than for it.
    private func resumeKeepAlive() {
        keepAliveQueue.async { [self] in
            guard keepAliveWanted, let player = keepAlive, !player.isPlaying else { return }
            player.play()
        }
    }

    private func stopKeepAlive() {
        keepAliveQueue.async { [self] in
            keepAliveWanted = false
            keepAlive?.stop()
            keepAlive = nil
        }
    }

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
        observers.append(centre.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began: queue.async { self.events(.began) }
            case .ended: resume()
            default: break
            }
        })
        observers.append(centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.events(.mediaServicesLost) }
        })
        observers.append(centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            // Not a failure: a headset arriving or leaving only moves the
            // speakerphone decision and the proximity sensor with it.
            queue.async { self.applyRoute() }
        })
    }

    private func unsubscribe() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
