import AVFoundation
import Foundation
import ParanoidKit
import WebRTC

/// The media of one call: one `RTCPeerConnection`, one audio track and one
/// camera video track, both `sendrecv` from the first description to the last.
///
/// It is `WebRtcAudioEngine.java`
/// (`clients/android/src/org/paranoid/text/WebRtcAudioEngine.java:51-604`) in
/// Swift, with three deliberate differences:
///
/// - **The audio route is not here.** On Android the engine owns the
///   `AudioManager`, the focus request and the proximity wake lock; on iOS the
///   `AVAudioSession`, the speakerphone override and the proximity sensor
///   belong to the audio-session controller that the call coordinator owns.
///   This type only opens and closes tracks.
/// - **Nothing is reported as a string.** Android hands the listener a safe
///   English reason; here every outcome is a ``Failure`` case, so the
///   interface picks its own wording and no message can carry an address, a
///   host or a credential.
/// - **The description cap is this client's, not the core's.** The core
///   accepts 12288 bytes (`clients/core/src/voice_v1.rs:10`), but a `call`
///   control travels inside one frame2 envelope whose measured ceiling is
///   10040 bytes, so a description above ``SdpExtract/maxSdpBytes`` (9000) is
///   refused here and never sent.
///
/// ## What it never does
///
/// - It never rewrites a description. The offer libwebrtc produced is
///   published byte for byte and the peer's is applied byte for byte
///   (`docs/protocol/voice-v1.md`: the sender does not munge SDP). Everything
///   the core checks — two sections, one Opus mapping, H.264/VP8, `sendrecv`
///   everywhere — is decided in **configuration**: the transceiver codec
///   preferences below, and never by editing SDP text.
/// - It never trickles. There is exactly one local description per call and
///   exactly one publication of it (``PublicationGate``); an ICE candidate is
///   only a reason to re-evaluate that one publication.
/// - It never renegotiates. `a=sendrecv` stays on both sections for the whole
///   call, so camera on and off is a track flag plus a `media` control
///   (`docs/protocol/call-v2.md`, "Video direction is always sendrecv").
/// - It never opens the camera on its own. The video track exists from the
///   first offer and stays disabled, with no capture session at all, until an
///   explicit ``setVideo(_:)`` with the camera permission already granted.
///
/// ## Where it runs
///
/// Every mutable member is touched on ``queue`` and nowhere else. libwebrtc
/// calls its delegate on its own signaling thread and its completion handlers
/// on whichever thread finished the work, so each of those hops back onto the
/// queue before it reads or writes anything here. That is what ``Unchecked``
/// is for: libwebrtc's Objective-C objects are not `Sendable` and never will
/// be, and this is the one place that says so out loud.
///
/// ``events`` is called on that same queue. The call coordinator hops to the
/// state owner inside it, exactly as Android's `publish` hops to the main
/// looper (`WebRtcAudioEngine.java:150-152`).
final class WebRtcAudioEngine: NSObject, @unchecked Sendable {
    // MARK: - What the engine says

    /// Which of the two descriptions of a call this is. There is never a
    /// third: an offer is only valid at `seq 1` and there is no
    /// renegotiation (`docs/protocol/call-v2.md`).
    enum DescriptionKind: String, Sendable {
        case offer, answer

        var sdpType: RTCSdpType { self == .offer ? .offer : .answer }
    }

    /// Everything one engine can report. Each case is `Sendable`, so the
    /// coordinator can carry it to the state owner unchanged.
    enum Event: Sendable, Equatable {
        /// The gathered local description, published exactly once per call.
        case localDescription(kind: DescriptionKind, sdp: String)
        /// The transport is up; only this makes a call "connected"
        /// (`docs/protocol/voice-v1.md:107-108`).
        case connected
        /// The transport was lost; the controller's recovery window decides
        /// what happens next.
        case disconnected
        /// The engine is finished and has released everything.
        case failed(Failure)
        /// The camera could not run. The call continues, audio-only
        /// (`call-v2.md`: a camera failure never ends the call).
        case videoUnavailable(Failure)
    }

    /// Why media stopped, or why it never started.
    ///
    /// The raw value is the whole message: it names no host, no address, no
    /// account and no credential, so it is safe in a log, in evidence and in
    /// a pull request.
    enum Failure: String, Error, Sendable {
        /// The microphone is not granted. This type never asks for it.
        case microphonePermission = "microphone permission"
        /// This libwebrtc build offers no Opus, so no description of this
        /// client could be accepted (`voice_v1.rs`: exactly one
        /// `opus/48000/2`).
        case opusUnavailable = "opus unavailable"
        /// Neither H.264 nor VP8 is available, so the mandatory video section
        /// could not be built (`call-v2.md`, "at least one of H.264 or VP8").
        case videoCodecUnavailable = "video codec unavailable"
        /// Creating or applying a description failed inside libwebrtc.
        case negotiation = "negotiation failed"
        /// ICE reported `failed`.
        case connection = "connection failed"
        /// The peer offered a data channel. A call carries audio and video
        /// and nothing else.
        case dataChannel = "unexpected media channel"
        /// The gathered description is above ``SdpExtract/maxSdpBytes``.
        case descriptionOversize = "description too large"
        /// The gathered description has no single transport context, so the
        /// three members the core cross-checks cannot be read out of it.
        case descriptionUnreadable = "description unreadable"
        /// The gathered description is not the call-v2 shape the core
        /// accepts. It is a configuration bug on this side, never a reason to
        /// edit the text.
        case descriptionShape = "description not call-v2"
        /// The camera permission is not granted at the moment of a toggle.
        case cameraPermission = "camera permission"
        /// There is no camera, or capture could not start.
        case cameraUnavailable = "camera unavailable"
        /// Anything else libwebrtc refused.
        case engine = "media engine failed"
    }

    // MARK: - The constants of the media

    /// The single stream both tracks belong to, as on Android
    /// (`WebRtcAudioEngine.java:262,272`).
    static let streamId = "voice"
    /// Track identifiers, in the order the two sections appear.
    static let audioTrackId = "voice"
    static let videoTrackId = "video"
    /// The capture format Android asks for (`WebRtcAudioEngine.java:73`). The
    /// source adapts to it, so a camera that only offers larger formats still
    /// sends this.
    static let videoWidth = 640
    static let videoHeight = 480
    static let videoFrameRate = 24

    // MARK: - What is held

    /// The one thread native work happens on, Android's
    /// `HandlerThread("ParanoID-voice-media")` (`:80`).
    private let queue = DispatchQueue(label: "global.paranoid.voice.media")
    private let events: @Sendable (Event) -> Void
    /// The validated relay credential, or `nil` for the disclosed direct
    /// mode. It decides both the ICE servers and the publication gate.
    private let relay: VoiceRelayConfig?
    /// Whether the microphone is granted. The engine reads it, never asks.
    private let microphoneGranted: @Sendable () -> Bool
    /// Whether the camera is granted. Same rule.
    private let cameraAuthorized: @Sendable () -> Bool
    private let gate: PublicationGate

    private var closed = false
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var localRenderer: (any RTCVideoRenderer)?
    private var remoteRenderer: (any RTCVideoRenderer)?
    private var pendingKind: DescriptionKind?
    private var localApplied = false
    private var muted = false
    private var videoEnabled = false
    private var frontCamera = true
    private var connected = false

    /// - Parameters:
    ///   - relay: the validated TURN credential. With one, the peer connection
    ///     is relay-only and carries exactly the two issued URLs; without one,
    ///     it carries **no** ICE server at all — this client has no STUN
    ///     server and asks no third party where it lives. Its remaining
    ///     lifetime is re-checked by whoever creates the engine, immediately
    ///     before doing so, exactly as `TextEngine.openMedia`
    ///     (`clients/android/src/org/paranoid/text/TextEngine.java:139`) does
    ///     it and not the engine itself.
    ///   - muted: whether the microphone starts muted.
    ///   - microphoneGranted: the permission probe. The default is the real
    ///     one; a test supplies its own because a simulator grants nothing.
    ///   - cameraAuthorized: the same for the camera.
    ///   - events: where every outcome goes, called on the engine's queue.
    init(relay: VoiceRelayConfig?,
         muted: Bool = false,
         microphoneGranted: @escaping @Sendable () -> Bool = {
             AVAudioApplication.shared.recordPermission == .granted
         },
         cameraAuthorized: @escaping @Sendable () -> Bool = {
             AVCaptureDevice.authorizationStatus(for: .video) == .authorized
         },
         events: @escaping @Sendable (Event) -> Void) {
        self.relay = relay
        self.muted = muted
        self.microphoneGranted = microphoneGranted
        self.cameraAuthorized = cameraAuthorized
        self.events = events
        self.gate = PublicationGate(relayOnly: relay != nil)
        super.init()
    }

    // MARK: - Negotiation

    /// The caller's side: create the media and produce one offer.
    func createOffer() {
        post {
            try self.create()
            self.pendingKind = .offer
            self.createDescription()
        }
    }

    /// The callee's side: create the media against the **authenticated**
    /// remote offer and produce one answer. The text is applied verbatim.
    func createAnswer(remoteOffer sdp: String) {
        post {
            try self.create()
            guard let peer = self.peer else { throw Failure.engine }
            peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
                guard let self else { return }
                let applied = error == nil
                self.post {
                    guard applied else { throw Failure.negotiation }
                    self.pendingKind = .answer
                    self.createDescription()
                }
            }
        }
    }

    /// The caller's side: apply the **authenticated** remote answer, verbatim.
    func setAnswer(remoteAnswer sdp: String) {
        post {
            guard let peer = self.peer, self.pendingKind == .offer else { throw Failure.engine }
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                // Only a refusal is news: the answer starts the connection,
                // and the connection reports itself.
                guard error != nil, let self else { return }
                self.post { throw Failure.negotiation }
            }
        }
    }

    // MARK: - Local controls

    /// Mute and unmute the local microphone.
    ///
    /// The track flag is the whole mechanism: iOS has no counterpart of
    /// Android's `setMicrophoneMute` on the default audio device module, and
    /// a disabled track sends silence rather than sending nothing, which is
    /// what keeps the transport alive while muted.
    func setMuted(_ value: Bool) {
        post {
            self.muted = value
            self.audioTrack?.isEnabled = !value
        }
    }

    /// Start or stop the local camera.
    ///
    /// - Throws: ``CallMediaError/cameraDenied`` when the camera is not
    ///   granted, which the controller answers by keeping the call and
    ///   staying audio-only (`call-v2.md`). The check is synchronous on
    ///   purpose: it is the caller's own decision, not an outcome of media.
    func setVideo(_ enabled: Bool) throws {
        if enabled, !cameraAuthorized() { throw CallMediaError.cameraDenied }
        post {
            self.videoEnabled = enabled
            self.applyVideoSafely()
        }
    }

    /// Front camera to back and back again. A running capture is restarted on
    /// the other device; a stopped one only remembers the choice.
    func switchCamera() {
        post {
            self.frontCamera.toggle()
            guard self.capturer != nil else { return }
            self.stopCapture()
            self.applyVideoSafely()
        }
    }

    /// Where the local preview is drawn. Detach with `nil` before the view
    /// goes away.
    func setLocalRenderer(_ renderer: (any RTCVideoRenderer)?) {
        let carried = Unchecked(renderer)
        post {
            if let previous = self.localRenderer { self.videoTrack?.remove(previous) }
            self.localRenderer = carried.value
            if let renderer = carried.value { self.videoTrack?.add(renderer) }
        }
    }

    /// Where the peer's camera is drawn.
    func setRemoteRenderer(_ renderer: (any RTCVideoRenderer)?) {
        let carried = Unchecked(renderer)
        post {
            if let previous = self.remoteRenderer { self.remoteVideoTrack?.remove(previous) }
            self.remoteRenderer = carried.value
            if let renderer = carried.value { self.remoteVideoTrack?.add(renderer) }
        }
    }

    /// The statistics report as JSON, for diagnostics only.
    ///
    /// It is `collectStats` (`WebRtcAudioEngine.java:520-538`): the whole v2
    /// report, one object per entry. It carries candidate addresses, so it is
    /// a debug surface and never evidence that travels.
    func statistics(_ handler: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            guard !closed, let peer else {
                handler("{}")
                return
            }
            peer.statistics { report in
                handler(Self.json(of: report))
            }
        }
    }

    /// Release everything this engine owns. Idempotent; `completion` runs on
    /// the queue after the release, as Android's does after `cleanup`
    /// (`WebRtcAudioEngine.java:548-554`).
    func close(_ completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if !closed {
                closed = true
                cleanup()
            }
            completion?()
        }
    }

    // MARK: - The queue

    private func post(_ work: @escaping @Sendable () throws -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                try work()
            } catch let failure as Failure {
                fail(failure)
            } catch {
                fail(.engine)
            }
        }
    }

    private func fail(_ failure: Failure) {
        guard !closed else { return }
        closed = true
        cleanup()
        events(.failed(failure))
    }

    // MARK: - Creation

    /// One-time process setup.
    ///
    /// `RTCAudioSession` is put in manual mode with audio disabled, so that
    /// creating a peer connection — which every incoming call does long
    /// before anyone has consented to anything — never starts the audio unit
    /// and never opens the microphone. The audio-session controller enables
    /// it when the call actually connects.
    private static let preparation: Bool = {
        _ = RTCInitializeSSL()
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        return true
    }()

    /// Run that setup, once per process. A test that builds a factory of its
    /// own prepares exactly the way the engine does.
    static func prepareProcess() {
        _ = preparation
    }

    /// `WebRtcAudioEngine.java:206-285`: the factory, the configuration, the
    /// two tracks and the codec preferences of both sections.
    private func create() throws {
        guard peer == nil else { throw Failure.engine }
        guard microphoneGranted() else { throw Failure.microphonePermission }
        Self.prepareProcess()

        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: RTCDefaultVideoDecoderFactory())
        self.factory = factory
        guard let peer = factory.peerConnection(with: Self.configuration(relay: relay),
                                                constraints: Self.constraints(),
                                                delegate: self) else {
            throw Failure.engine
        }
        self.peer = peer

        let audioSource = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true",
                                  "googAutoGainControl": "true",
                                  "googNoiseSuppression": "true"]))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: Self.audioTrackId)
        audioTrack.isEnabled = !muted
        self.audioSource = audioSource
        self.audioTrack = audioTrack
        guard peer.add(audioTrack, streamIds: [Self.streamId]) != nil else { throw Failure.engine }

        // The audio transceiver is the only one that exists at this point, so
        // this loop restricts exactly it (`WebRtcAudioEngine.java:263-267`).
        let opus = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
            .codecs.filter { $0.mimeType.lowercased() == "audio/opus" }
        guard !opus.isEmpty else { throw Failure.opusUnavailable }
        for transceiver in peer.transceivers {
            // `setCodecPreferences:error:` declares its out-parameter as
            // `NSError ** _Nullable`, so the importer keeps an empty `error:`
            // label beside the thrown error instead of dropping it.
            try transceiver.setCodecPreferences(opus, error: ())
        }

        // The pre-negotiated video section: the track exists from the first
        // description and carries no frames until a camera toggle, so camera
        // on and off is never a renegotiation.
        let videoSource = factory.videoSource()
        videoSource.adaptOutputFormat(toWidth: Int32(Self.videoWidth),
                                      height: Int32(Self.videoHeight),
                                      fps: Int32(Self.videoFrameRate))
        let videoTrack = factory.videoTrack(with: videoSource, trackId: Self.videoTrackId)
        videoTrack.isEnabled = false
        self.videoSource = videoSource
        self.videoTrack = videoTrack
        guard peer.add(videoTrack, streamIds: [Self.streamId]) != nil else { throw Failure.engine }
        if let localRenderer { videoTrack.add(localRenderer) }

        let video = try Self.videoPreferences(of: factory)
        for transceiver in peer.transceivers where transceiver.mediaType == .video {
            try transceiver.setCodecPreferences(video, error: ())
        }
        // A camera toggled before the media existed applies here, and only
        // here does it open anything.
        if videoEnabled { applyVideoSafely() }
    }

    /// `WebRtcAudioEngine.java:244-251` plus the relay lane.
    ///
    /// With a credential the connection is `iceTransportPolicy = .relay` and
    /// carries exactly the two issued `turn:` URLs; without one it carries an
    /// empty server list. There is no STUN server in either branch: this
    /// client never asks a third party for its own address.
    static func configuration(relay: VoiceRelayConfig?) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        if let relay {
            configuration.iceServers = [RTCIceServer(urlStrings: relay.urls,
                                                     username: relay.username,
                                                     credential: relay.password)]
            configuration.iceTransportPolicy = .relay
        } else {
            configuration.iceServers = []
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceCandidatePoolSize = 0
        return configuration
    }

    private static func constraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    /// `WebRtcAudioEngine.java:273-283`: H.264 first (hardware, owner decision
    /// 2026-09-11), VP8 as the mandatory fallback, then the helper formats.
    ///
    /// VP9, AV1 and everything else the core does not whitelist
    /// (`voice_v1.rs:11-18`) never enter a description, because they are never
    /// preferred — the list is a configuration, not a filter applied to
    /// finished text.
    static func videoPreferences(of factory: RTCPeerConnectionFactory) throws -> [RTCRtpCodecCapability] {
        var preferred: [RTCRtpCodecCapability] = []
        var fallback: [RTCRtpCodecCapability] = []
        var helpers: [RTCRtpCodecCapability] = []
        for codec in factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs {
            switch codec.mimeType.lowercased() {
            case "video/h264": preferred.append(codec)
            case "video/vp8": fallback.append(codec)
            case "video/rtx", "video/red", "video/ulpfec", "video/flexfec-03": helpers.append(codec)
            default: continue
            }
        }
        guard !preferred.isEmpty || !fallback.isEmpty else { throw Failure.videoCodecUnavailable }
        return preferred + fallback + helpers
    }

    // MARK: - The one description

    private func createDescription() {
        guard let peer, let kind = pendingKind else { return }
        let handler: @Sendable (RTCSessionDescription?, Error?) -> Void = { [weak self] description, error in
            guard let self else { return }
            let carried = Unchecked(description)
            let created = error == nil
            self.post {
                guard created, let description = carried.value else { throw Failure.negotiation }
                self.apply(local: description)
            }
        }
        switch kind {
        case .offer: peer.offer(for: Self.constraints(), completionHandler: handler)
        case .answer: peer.answer(for: Self.constraints(), completionHandler: handler)
        }
    }

    private func apply(local description: RTCSessionDescription) {
        guard let peer else { return }
        peer.setLocalDescription(description) { [weak self] error in
            guard let self else { return }
            let applied = error == nil
            self.post {
                guard applied else { throw Failure.negotiation }
                self.localApplied = true
                try self.publishIfReady()
            }
        }
    }

    /// `maybePublishDescription` (`WebRtcAudioEngine.java:409-435`): the gate
    /// decides, this reads what the gate decides about.
    private func publishIfReady() throws {
        guard let peer, let kind = pendingKind else { return }
        let local = peer.localDescription
        let ready = localApplied && local?.type == kind.sdpType
        switch gate.evaluate(sdp: local?.sdp, ready: ready,
                             gatheringComplete: peer.iceGatheringState == .complete) {
        case .wait:
            return
        case .coalesce:
            queue.asyncAfter(deadline: .now() + .milliseconds(PublicationGate.coalescingMillis)) { [self] in
                post {
                    self.gate.coalescingWindowElapsed()
                    try self.publishIfReady()
                }
            }
        case .publish(let sdp):
            events(.localDescription(kind: kind, sdp: sdp))
        case .refuse(let failure):
            throw failure
        }
    }

    // MARK: - The camera

    /// `applyVideoSafely` (`WebRtcAudioEngine.java:188-196`): a camera that
    /// cannot start turns the camera off and tells the interface; it never
    /// ends the call.
    private func applyVideoSafely() {
        do {
            try applyVideo()
        } catch {
            videoEnabled = false
            videoTrack?.isEnabled = false
            stopCapture()
            events(.videoUnavailable((error as? Failure) ?? .cameraUnavailable))
        }
    }

    private func applyVideo() throws {
        // Before ``create()`` there is no track and nothing to apply: the flag
        // is remembered and applied when the media exists, so a toggle that
        // arrives first is neither lost nor reported as a camera failure.
        guard let videoTrack, let videoSource else { return }
        guard videoEnabled else {
            videoTrack.isEnabled = false
            stopCapture()
            return
        }
        if capturer == nil {
            guard cameraAuthorized() else { throw Failure.cameraPermission }
            guard let device = Self.camera(front: frontCamera),
                  let format = Self.format(of: device) else {
                throw Failure.cameraUnavailable
            }
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            self.capturer = capturer
            capturer.startCapture(with: device, format: format, fps: Self.videoFrameRate) { [weak self] error in
                guard let self, error != nil else { return }
                self.post { self.cameraStopped() }
            }
        }
        videoTrack.isEnabled = true
    }

    /// Capture failed after it had been asked to start.
    private func cameraStopped() {
        guard videoEnabled else { return }
        videoEnabled = false
        videoTrack?.isEnabled = false
        stopCapture()
        events(.videoUnavailable(.cameraUnavailable))
    }

    private func stopCapture() {
        capturer?.stopCapture()
        capturer = nil
    }

    /// The camera on the requested side, or any camera at all. A simulator
    /// has none, which is why this is an `Optional` and not a precondition.
    private static func camera(front: Bool) -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wanted: AVCaptureDevice.Position = front ? .front : .back
        return devices.first { $0.position == wanted } ?? devices.first
    }

    /// The supported format closest to 640x480 that can reach 24 fps.
    private static func format(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestDistance = Int.max
        for format in RTCCameraVideoCapturer.supportedFormats(for: device) {
            guard format.videoSupportedFrameRateRanges
                .contains(where: { $0.maxFrameRate >= Double(videoFrameRate) }) else { continue }
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let distance = abs(Int(size.width) - videoWidth) + abs(Int(size.height) - videoHeight)
            if distance < bestDistance {
                bestDistance = distance
                best = format
            }
        }
        return best
    }

    // MARK: - The peer's tracks

    private func attach(remote track: RTCMediaStreamTrack?) {
        guard let video = track as? RTCVideoTrack, remoteVideoTrack == nil else { return }
        remoteVideoTrack = video
        video.isEnabled = true
        if let remoteRenderer { video.add(remoteRenderer) }
    }

    // MARK: - Release

    /// `cleanup` (`WebRtcAudioEngine.java:555-603`), in the same order: the
    /// tracks stop first, then the capture session, then the renderers, then
    /// the connection, then everything the factory made.
    private func cleanup() {
        audioTrack?.isEnabled = false
        videoTrack?.isEnabled = false
        stopCapture()
        if let localRenderer { videoTrack?.remove(localRenderer) }
        localRenderer = nil
        if let remoteRenderer { remoteVideoTrack?.remove(remoteRenderer) }
        remoteRenderer = nil
        remoteVideoTrack = nil
        peer?.close()
        peer = nil
        audioTrack = nil
        audioSource = nil
        videoTrack = nil
        videoSource = nil
        factory = nil
        connected = false
        videoEnabled = false
        localApplied = false
        pendingKind = nil
    }

    // MARK: - Statistics

    private static func json(of report: RTCStatisticsReport) -> String {
        var entries: [[String: Any]] = []
        for (identifier, statistics) in report.statistics {
            var entry: [String: Any] = ["id": identifier, "type": statistics.type]
            for (key, value) in statistics.values where JSONSerialization.isValidJSONObject([value]) {
                entry[key] = value
            }
            entries.append(entry)
        }
        let object: [String: Any] = ["stats": entries]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// One libwebrtc object handed from its own thread to the engine's queue.
    ///
    /// The Objective-C API is not `Sendable`, and the discipline that makes
    /// this safe is the one the whole type rests on: each of these objects is
    /// read and written on ``queue`` only. `Slot` in `SdpCompatibilityTests`
    /// is the same escape hatch for the same reason.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) { self.value = value }
    }
}

// MARK: - The publication gate

extension WebRtcAudioEngine {
    /// When the one local description of a call may be published, and the
    /// proof that it is published exactly once.
    ///
    /// It is `maybePublishDescription` and `hasUsableRelayCandidate`
    /// (`WebRtcAudioEngine.java:409-460`) with every libwebrtc type removed,
    /// so that a fake candidate feed can drive the whole decision — which is
    /// what `SdpPublishGatingTests` does.
    ///
    /// The two lanes differ in one rule:
    ///
    /// - **Direct**: publish once gathering is `complete`. There is no
    ///   trickle, so a description published earlier would carry fewer
    ///   candidates than the peer needs.
    /// - **Relay**: publish once the first *usable* relay candidate exists —
    ///   component 1, UDP, `typ relay`, a literal IPv4 address — after a
    ///   500 ms window in which the rest of the relay candidates can join it,
    ///   or immediately if gathering completes first. Without such a
    ///   candidate nothing is published **even when gathering completes**:
    ///   a relay-only description with no relay candidate cannot connect, and
    ///   the controller's 45-second window is what ends the attempt.
    ///
    /// Both lanes then require at least one `a=candidate:` line — libwebrtc
    /// can report an empty `complete` before it has found an interface — and
    /// a description that fits ``SdpExtract/maxSdpBytes`` and has the call-v2
    /// shape the core accepts. A description that fails either is refused and
    /// the gate is spent: it is a bug on this side, and the answer is a
    /// configuration change, never an edit of the text.
    final class PublicationGate {
        /// What the engine should do with the current local description.
        enum Outcome: Equatable {
            /// Nothing yet; a later candidate or gathering event decides.
            case wait
            /// Relay: start the 500 ms coalescing window. Returned once.
            case coalesce
            /// Publish exactly this text, unchanged.
            case publish(String)
            /// Never publish; this call is over.
            case refuse(Failure)
        }

        /// How long the relay lane waits for the remaining relay candidates
        /// after the first usable one (`WebRtcAudioEngine.java:420`).
        static let coalescingMillis = 500
        /// The core refuses more than sixteen candidate lines and more than
        /// 512 lines (`voice_v1.rs:130-133,226-229`).
        static let maximumCandidates = 16
        static let maximumLines = 512
        /// The only transport a call-v2 section may name.
        static let transport = "UDP/TLS/RTP/SAVPF"
        /// The video codecs the core whitelists (`voice_v1.rs:11-18`),
        /// lowercased exactly as it compares them.
        static let videoCodecs: Set<String> = [
            "h264/90000", "vp8/90000", "rtx/90000", "red/90000", "ulpfec/90000", "flexfec-03/90000",
        ]

        /// Whether this call may only use the relay.
        let relayOnly: Bool
        /// How many descriptions this gate has published. It is never more
        /// than one.
        private(set) var publications = 0
        /// Whether the gate has published or refused; either way it is spent.
        private(set) var settled = false
        /// Whether the coalescing window has already been asked for.
        private(set) var coalescing = false
        private var coalesced = false

        init(relayOnly: Bool) {
            self.relayOnly = relayOnly
        }

        /// The 500 ms window asked for by ``Outcome/coalesce`` has elapsed.
        func coalescingWindowElapsed() {
            coalesced = true
        }

        /// One decision about the current local description.
        ///
        /// - Parameters:
        ///   - sdp: the local description, or `nil` while there is none.
        ///   - ready: whether that description has been applied locally and is
        ///     the kind this side is producing.
        ///   - gatheringComplete: libwebrtc's gathering state.
        func evaluate(sdp: String?, ready: Bool, gatheringComplete: Bool) -> Outcome {
            guard !settled, ready, let sdp, !sdp.isEmpty else { return .wait }
            if relayOnly {
                guard Self.hasUsableRelayCandidate(sdp) else { return .wait }
                if !gatheringComplete, !coalesced {
                    guard !coalescing else { return .wait }
                    coalescing = true
                    return .coalesce
                }
            } else if !gatheringComplete {
                return .wait
            }
            guard sdp.contains("a=candidate:") else { return .wait }
            guard sdp.utf8.count <= SdpExtract.maxSdpBytes else {
                settled = true
                return .refuse(.descriptionOversize)
            }
            guard let extract = SdpExtract(sdp: sdp) else {
                settled = true
                return .refuse(.descriptionUnreadable)
            }
            guard Self.isCallV2(extract) else {
                settled = true
                return .refuse(.descriptionShape)
            }
            settled = true
            publications += 1
            return .publish(sdp)
        }

        /// Every rule of `voice_v1.rs:236-256` this client can break on its
        /// own, checked before the description is handed to the core.
        static func isCallV2(_ extract: SdpExtract) -> Bool {
            guard extract.mediaKinds == ["audio", "video"],
                  extract.cryptoCount == 0,
                  extract.blockedDirectionCount == 0,
                  extract.candidateCount <= maximumCandidates,
                  extract.lineCount <= maximumLines
            else {
                return false
            }
            let audio = extract.sections[0], video = extract.sections[1]
            guard audio.transport == transport, video.transport == transport,
                  audio.sendrecvCount == 1, video.sendrecvCount == 1,
                  audio.declaresEveryMapping, video.declaresEveryMapping,
                  audio.rtcpMuxCount == 1, video.rtcpMuxCount <= 1,
                  (audio.port ?? 0) > 0, video.port != nil,
                  audio.codecs.filter({ $0 == "opus/48000/2" }).count == 1,
                  video.codecs.allSatisfy(videoCodecs.contains),
                  video.codecs.contains(where: { $0 == "h264/90000" || $0 == "vp8/90000" })
            else {
                return false
            }
            return true
        }

        /// `hasUsableRelayCandidate` (`WebRtcAudioEngine.java:438-460`).
        ///
        /// Readiness is read out of this side's own gathered description and
        /// nothing else; it says only that a relay allocation exists, never
        /// that the peer is reachable. A `raddr`/`rport` of zero is
        /// legitimate, so neither is looked at.
        static func hasUsableRelayCandidate(_ sdp: String) -> Bool {
            for line in SdpExtract.lines(of: sdp) {
                guard line.hasPrefix("a=candidate:"), line.utf8.count <= 512 else { continue }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 8, fields[0].utf8.count > 12, fields[1] == "1",
                      fields[2].lowercased() == "udp", fields[6] == "typ", fields[7] == "relay",
                      isRelayAddress(fields[4])
                else {
                    continue
                }
                guard let priority = number(fields[3], digits: 10),
                      let port = number(fields[5], digits: 5)
                else {
                    continue
                }
                if priority <= 0xffff_ffff, port > 0, port <= 65535 { return true }
            }
            return false
        }

        /// The validated issuer configuration names one canonical IPv4 relay,
        /// so an IPv6 or a named candidate is not this call's relay.
        static func isRelayAddress(_ address: String) -> Bool {
            let octets = address.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, address != "0.0.0.0" else { return false }
            for octet in octets {
                guard octet.count == 1 || !octet.hasPrefix("0"),
                      let value = number(String(octet), digits: 3), value <= 255
                else {
                    return false
                }
            }
            return true
        }

        /// A decimal field of at most `digits` digits, as the Java patterns
        /// `[0-9]{1,10}` and `[0-9]{1,5}` read one.
        private static func number(_ text: String, digits: Int) -> Int64? {
            guard !text.isEmpty, text.count <= digits,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(text)
        }
    }
}

// MARK: - libwebrtc's callbacks

extension WebRtcAudioEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    /// There is no renegotiation in a call, so there is nothing to do here.
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        post { try self.publishIfReady() }
    }

    /// A gathered candidate is never sent on its own: it is only a reason to
    /// look at the one description again.
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        post { try self.publishIfReady() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    /// A call carries audio and video. A data channel is not part of this
    /// protocol, and an offered one ends the call
    /// (`WebRtcAudioEngine.java:506`).
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        post { throw Failure.dataChannel }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        post {
            switch newState {
            case .connected where !self.connected:
                self.connected = true
                self.events(.connected)
            case .disconnected:
                self.connected = false
                self.events(.disconnected)
            case .failed:
                throw Failure.connection
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didStartReceivingOn transceiver: RTCRtpTransceiver) {
        let carried = Unchecked(transceiver.receiver.track)
        post { self.attach(remote: carried.value) }
    }
}
