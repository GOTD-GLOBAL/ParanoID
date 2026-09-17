import AVFoundation
import Foundation
import ParanoidKit
import WebRTC

/// Everything a call needs that is not the state machine: the outbox, the
/// relay credential, the media engine, the audio session and the screen.
///
/// It is the call-shaped half of `TextEngine` — `CallController.Port`,
/// `openMedia`, `createMedia` and `MediaListener`
/// (`clients/android/src/org/paranoid/text/TextEngine.java:60-174`) — in one
/// place, and the rule it exists for is the one the Java class states in its
/// own comment: *the call controller, the interface and the SDK callbacks
/// share one thread*. Here that thread is the state owner's serial queue, so
/// every member of this type is touched there and nowhere else, exactly as
/// `CallController` itself is (`precondition(owner.isOnOwner)`).
///
/// ## What is on which side of it
///
/// - **Above it** is `AppModel`, on the main actor. It owns the two explicit
///   intents — the microphone permission, the confirmation that carries the
///   privacy sentence, the ten seconds of waiting for a confirmed online lane
///   — and it never touches the controller directly. That is Android's
///   `MainActivity.requestCall` / `requestMicrophone` / `completeCallIntent`
///   (`MainActivity.java:375-441`).
/// - **Below it** is `CallController`, which owns the protocol, and
///   `WebRtcAudioEngine`, which owns the media. Neither of them knows this
///   application exists.
///
/// ## The order a call is opened in
///
/// The audio session is running **before** the first `knock` leaves the
/// device (`AppModel.prepareAudio()` → ``prepareAudio()``): the `audio`
/// background mode holds nothing without a live session, and the process may
/// be suspended between a knock and its answer otherwise. Media authority
/// comes later and separately: `offer`/`answer` reach ``openMedia(_:remoteOffer:)``,
/// which asks `VoiceRelayLane` for one TURN credential and hands the verdict
/// to `CallController.mediaAuthorized(_:authorized:)`; only a granted verdict
/// creates a `WebRtcAudioEngine` (`TextEngine.java:132-147`). Nothing is
/// "connected" until the engine says so.
///
/// ## The camera
///
/// A denied camera is never a call failure and never changes a section's
/// direction. ``video(_:)`` throws ``CallMediaError/cameraDenied`` before it
/// reaches the engine, the controller keeps the call and stays audio-only, and
/// the peer learns the state from a `media` control — the video section stays
/// `a=sendrecv` from the first description to the last
/// (`docs/protocol/call-v2.md`, "Video direction is always sendrecv"). There
/// is no `a=recvonly` and no `a=inactive` anywhere in this client.
final class CallCoordinator: CallController.SendPort, CallController.MediaPort,
                             CallController.Observer, @unchecked Sendable {
    /// What a port can refuse with. Neither case names an account, a host or
    /// a credential, so both are safe in a log.
    enum PortFailure: String, Error, Sendable {
        /// The durable outbox already holds this client's ceiling of call
        /// envelopes (`voice-v1.md:147-149`).
        case outboxFull = "call outbox full"
        /// A camera action arrived with no media engine to carry it
        /// (`TextEngine.java:76`).
        case noEngine = "no media engine"
        /// A body that had just been serialised could not be read back. It
        /// cannot happen; it is here so that nothing has to pretend.
        case malformed = "call body unreadable"
    }

    /// How many call envelopes may be in flight before the port refuses:
    /// the core's own ceiling (`CallController.maximumPendingCallEnvelopes`).
    static let maximumPendingSends = CallController.maximumPendingCallEnvelopes

    private let owner: StateOwner
    private let loop: RealtimeLoop
    private let runner: LifecycleRunner
    private let relay: VoiceRelayLane
    private weak var model: AppModel?

    /// The audio session and the state machine. Both are written once, in
    /// `init`, and never again; both are declared implicitly unwrapped because
    /// each of them is built **from** this object — the session's interruption
    /// handler and all three of the controller's ports are `self` — and
    /// Swift's initializer cannot hand out `self` until every stored property
    /// has a value.
    private var audio: AudioSessionController!
    private var controller: CallController!

    private var engine: WebRtcAudioEngine?
    private var engineGeneration: CallGeneration?
    private var relayRequest: VoiceRelayLane.Request?
    /// How many engines are still closing. A new one is never created beside
    /// an old one (`TextEngine.java:134,84-88`).
    private var mediaClosing = 0
    private var pendingMedia: (@Sendable () -> Void)?

    /// One in-flight `send`, by ticket. The completion never leaves the owner,
    /// so it is kept here rather than carried into a task.
    private var sends: [UInt64: (Bool) -> Void] = [:]
    /// Envelope identifier -> ticket, for the acceptance that resolves it.
    private var envelopes: [String: UInt64] = [:]
    private var ticketCounter: UInt64 = 0
    private var ticker: Task<Void, Never>?
    private var lastState: CallController.State = .idle

    /// The Debug-only media summary of `clients/ios/test_voice_sim.py`, or
    /// `nil` — which is every build that was not launched with
    /// `-paranoid-call-diagnostics` and every Release build there is
    /// (``CallDiagnostics``).
    private let diagnostics = CallDiagnostics.sink()

    /// - Parameters:
    ///   - owner: the state owner. Every member of this type runs on it.
    ///   - loop: the realtime lanes, woken after a durable enqueue.
    ///   - runner: the lifecycle queue. A call is signalled over the very
    ///     lanes the foreground rule would otherwise stop, so every published
    ///     call state goes here (`LifecyclePolicy`, `TextEngine.java:99`).
    ///   - relay: the TURN lane. One request at a time, cancelled with the
    ///     call.
    ///   - model: the screens.
    init(owner: StateOwner, loop: RealtimeLoop, runner: LifecycleRunner,
         relay: VoiceRelayLane, model: AppModel) {
        self.owner = owner
        self.loop = loop
        self.runner = runner
        self.relay = relay
        self.model = model
        audio = AudioSessionController(events: { [weak self] interruption in
            guard let self else { return }
            Task { await owner.onOwner { self.interrupted(interruption) } }
        })
        controller = CallController(owner: owner, sender: self, media: self, observer: self)
    }

    // MARK: - Attaching to the client and to the clock

    /// Installs the two client listeners and starts the one-second tick.
    ///
    /// The listeners are the iOS halves of `SelfServiceClient.setCallListener`
    /// and `setAcceptedListener` (`TextEngine.java:113-115`): a call control
    /// reaches the controller only **after** the candidate that carried it is
    /// durable, and an acceptance resolves the send it belongs to.
    func attach() async {
        await owner.setFreezeHandler { [weak self] in self?.authorizationLost() }
        try? await owner.perform { client in
            client.callListener = { [weak self] event in
                guard let self else { return }
                guard let account = event["account"] as? String,
                      let body = event["body"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: body),
                      let json = String(data: data, encoding: .utf8)
                else { return }
                // A body this device cannot parse is dropped in silence: it
                // grants no interface and no media authority.
                self.controller.received(account: account, json: json)
            }
            client.acceptedListener = { [weak self] envelope in
                self?.accepted(envelope: envelope)
            }
        }
        startTicking()
    }

    /// One second of the call's life, forever, exactly as Android posts it on
    /// the main looper (`TextEngine.java:104`). Every deadline of the protocol
    /// is read from the clock inside `tick()`; this only decides how fresh the
    /// elapsed time on the screen is.
    ///
    /// There is nothing that stops it, because there is nothing that stops the
    /// runtime: this application builds one and keeps it for the life of the
    /// process. A tick with no live call purges the readiness and terminal
    /// tables and does nothing else.
    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(CallController.tickMillis))
                guard let self, !Task.isCancelled else { return }
                await owner.onOwner {
                    self.controller.tick()
                    self.sample()
                }
            }
        }
    }

    /// One reading of the media statistics for the Debug sink, taken on the
    /// same tick the protocol's deadlines are read on.
    ///
    /// It is nothing at all unless this launch asked for a sink, and it never
    /// touches the engine from anywhere but the owner: the reply arrives on
    /// the engine's own queue, where the sink takes it from.
    private func sample() {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard let diagnostics else { return }
        let state = lastState.rawValue
        guard let engine else {
            diagnostics.record(state: state)
            return
        }
        engine.statistics { report in diagnostics.record(state: state, statistics: report) }
    }

    // MARK: - What the interface asks for

    /// The explicit Call action, with the microphone already granted and the
    /// audio session already running (`voice-v1.md:100-101`).
    func start(account: String, video: Bool) async {
        await owner.onOwner { self.controller.start(account: account,
                                                    microphonePermission: true,
                                                    videoIntent: video) }
    }

    /// The explicit Answer action.
    ///
    /// - Parameter microphone: whether the microphone was granted. `false` is
    ///   a refusal the peer is told about — the controller ends the call as
    ///   `reject` — and it is how a denied microphone on an incoming call
    ///   reaches the other phone (`CallController.answer(microphonePermission:)`).
    func answer(microphone: Bool, callId: String, generation: CallGeneration) async {
        await owner.onOwner {
            self.controller.answer(microphonePermission: microphone,
                                   callId: callId, generation: generation)
        }
    }

    /// «Отклонить» while ringing, «Завершить» afterwards.
    func end(callId: String, generation: CallGeneration) async {
        await owner.onOwner { self.controller.end(callId: callId, generation: generation) }
    }

    func setMuted(_ muted: Bool, callId: String, generation: CallGeneration) async {
        await owner.onOwner { self.controller.mute(muted, callId: callId, generation: generation) }
    }

    func setSpeaker(_ speaker: Bool, callId: String, generation: CallGeneration) async {
        await owner.onOwner { self.controller.speaker(speaker, callId: callId, generation: generation) }
    }

    /// The explicit camera toggle. It is the only thing in this client that
    /// may open the camera during a call (`call-v2.md:62-64`).
    ///
    /// - Parameter generation: the call the user aimed it at, carried across
    ///   the hop onto the owner and checked there against the call that is
    ///   live when it lands (``CallController/video(_:generation:)``).
    func setVideo(_ enabled: Bool, generation: CallGeneration) async {
        await owner.onOwner { self.controller.video(enabled, generation: generation) }
    }

    /// The application is on the screen, or it is not (`call-v2.md:67-69`).
    ///
    /// Which camera comes back on is decided on the owner, where the live call
    /// is; nothing above this line remembers a camera across a background.
    ///
    /// - Parameter phase: which observation of the screen this is. It is
    ///   carried rather than trusted to arrive in order, because two of these
    ///   cross the same hop and nothing orders them
    ///   (``CallController/foreground(_:phase:)``).
    func setForeground(_ inForeground: Bool, phase: UInt64) async {
        await owner.onOwner { self.controller.foreground(inForeground, phase: phase) }
    }

    /// Front camera to back and back again. It is a property of the capturer,
    /// not of the call, so it never reaches the controller.
    ///
    /// - Parameter generation: the call the user aimed it at. It reaches the
    ///   engine only if that call is still the one the engine belongs to: a tap
    ///   that lands after its own call ended would otherwise turn the camera of
    ///   whichever call replaced it, which is the same crossing
    ///   ``CallController/video(_:generation:)`` refuses. It can open nothing
    ///   by itself — capture is started from `setVideo(_:generation:)` alone —
    ///   so what it saves is a stranger's picture flipping, not a camera.
    func switchCamera(generation: CallGeneration) async {
        await owner.onOwner {
            guard self.engineGeneration == generation else { return }
            self.engine?.switchCamera()
        }
    }

    /// A video surface on its way to the media engine.
    ///
    /// `RTCVideoRenderer` is a libwebrtc Objective-C protocol and will never
    /// be `Sendable`, and the view behind it is a UIKit object on the main
    /// actor. This is the one place that says so out loud; libwebrtc is the
    /// only thing that ever touches it, and no frame reaches this process by
    /// any other route.
    struct Surface: @unchecked Sendable {
        let renderer: (any RTCVideoRenderer)?

        init(_ renderer: (any RTCVideoRenderer)?) {
            self.renderer = renderer
        }
    }

    /// Where this device's own camera is drawn, or `nil` to detach.
    func setLocalSurface(_ surface: Surface) async {
        await owner.onOwner { self.engine?.setLocalRenderer(surface.renderer) }
    }

    /// Where the peer's camera is drawn, or `nil` to detach.
    func setRemoteSurface(_ surface: Surface) async {
        await owner.onOwner { self.engine?.setRemoteRenderer(surface.renderer) }
    }

    /// The realtime lane's online flag (`TextEngine.java:109`). It gates the
    /// two intents and nothing else.
    func connection(_ connected: Bool) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        controller.connection(connected)
    }

    /// A confirmed authorization failure or a frozen store: everything stops
    /// at once and the peer is not told (`voice-v1.md:111-112`).
    func authorizationLost() {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        controller.authorizationLost()
    }

    /// The peer was blocked.
    func block(account: String) async {
        await owner.onOwner { self.controller.block(account: account) }
    }

    // MARK: - The audio session, before anything is sent

    /// Activates the audio session for a call that is about to start.
    ///
    /// It is called from the explicit intent, after the microphone is granted
    /// and **before** the first `knock`, and from the arrival of an incoming
    /// ring. It opens no microphone: libwebrtc is in manual audio with its
    /// audio unit off until `connected`.
    func prepareAudio() {
        audio.begin()
    }

    /// Gives the session back when an intent was abandoned before it became a
    /// call — a refused microphone, ten seconds with no connection.
    ///
    /// It runs on the owner because only the owner knows whether a call has
    /// started meanwhile: an intent that was abandoned while an incoming call
    /// was ringing must not take that call's audio away.
    func releaseAudio() async {
        await owner.onOwner {
            guard !self.controller.isActive else { return }
            self.audio.end()
        }
    }

    /// The audio this call is made of was taken away. `voice-v1.md` has no
    /// paused call, so it ends (`CallController.MediaState.failed`).
    private func interrupted(_ interruption: AudioSessionController.Interruption) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        // Both interruptions mean the same thing — the audio this call is
        // made of is gone — so both end it the same way. A ringing call that
        // has no media yet ends on its own forty-five-second deadline.
        guard controller.isActive, let generation = engineGeneration else { return }
        controller.mediaState(generation, .failed)
    }

    // MARK: - CallController.SendPort

    /// One authenticated control into the durable outbox
    /// (`TextEngine.java:61-71`).
    ///
    /// There is deliberately no "not connected" gate: `send_call_v1` is a
    /// durable enqueue and the send lane delivers it once a transient failure
    /// clears. The call stays bounded by its own heartbeat and TTL deadlines.
    func send(account: String, body: CallBody, completion: @escaping (Bool) -> Void) throws {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard sends.count < Self.maximumPendingSends else { throw PortFailure.outboxFull }
        // The body crosses to the enqueue as text and is rebuilt there, which
        // is Android's immutable copy (`TextEngine.java:63`) and the only
        // form of it that is `Sendable`.
        let json = try body.encoded()
        ticketCounter += 1
        let ticket = ticketCounter
        sends[ticket] = completion
        Task { [weak self] in
            guard let self else { return }
            do {
                try await owner.perform { client in
                    guard let data = json.data(using: .utf8),
                          let members = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw PortFailure.malformed }
                    let envelope = try client.sendCall(account: account, body: members)
                    // Recorded on the owner, inside the same step that
                    // enqueued it, so an acceptance cannot arrive between the
                    // two and find nothing to resolve.
                    self.registered(ticket: ticket, envelope: envelope)
                }
                loop.wake()
            } catch {
                await owner.onOwner { self.settle(ticket: ticket, accepted: false) }
            }
        }
    }

    private func registered(ticket: UInt64, envelope: String) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard sends[ticket] != nil else { return }
        envelopes[envelope] = ticket
    }

    /// The server accepted an envelope and the acceptance is durable. Only
    /// then is a control "sent" (`voice-v1.md:137-139`).
    private func accepted(envelope: String) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard let ticket = envelopes.removeValue(forKey: envelope) else { return }
        settle(ticket: ticket, accepted: true)
    }

    private func settle(ticket: UInt64, accepted: Bool) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard let completion = sends.removeValue(forKey: ticket) else { return }
        envelopes = envelopes.filter { $0.value != ticket }
        completion(accepted)
    }

    // MARK: - CallController.MediaPort

    func offer(generation: CallGeneration) throws {
        openMedia(generation, remoteOffer: nil)
    }

    func answer(generation: CallGeneration, remoteSdp: String) throws {
        openMedia(generation, remoteOffer: remoteSdp)
    }

    func remoteAnswer(generation: CallGeneration, remoteSdp: String) throws {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard engineGeneration == generation else { return }
        engine?.setAnswer(remoteAnswer: remoteSdp)
    }

    func mute(_ muted: Bool) throws {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        engine?.setMuted(muted)
    }

    func speaker(_ speaker: Bool) throws {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        audio.setSpeaker(speaker)
    }

    /// Start or stop the local camera (`TextEngine.java:76-80`).
    ///
    /// Camera off with no engine is silently nothing; camera **on** with no
    /// engine is a bug on this side and ends the call. A camera that is not
    /// granted throws ``CallMediaError/cameraDenied``, which the controller
    /// answers by keeping the call and staying audio-only: the video section
    /// is not renegotiated, and no direction anywhere becomes `recvonly` or
    /// `inactive`.
    func video(_ enabled: Bool) throws {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard let engine else {
            if enabled { throw PortFailure.noEngine }
            return
        }
        guard !enabled || AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CallMediaError.cameraDenied
        }
        try engine.setVideo(enabled)
        audio.setVideo(enabled)
    }

    /// Everything this call owned, released (`TextEngine.java:81-91`).
    ///
    /// Cancellation belongs to the request created on this owner, not to the
    /// lane's current request. Its sticky flag is set before any actor hop;
    /// an older call's teardown can never cancel its replacement.
    func close() {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        pendingMedia = nil
        relayRequest?.cancel()
        relayRequest = nil
        let owned = engine
        engine = nil
        engineGeneration = nil
        if let owned {
            mediaClosing += 1
            owned.close { [weak self] in
                guard let self else { return }
                Task { await self.owner.onOwner { self.mediaClosed() } }
            }
        }
        audio.setVideo(false)
        audio.end()
        // A call that is over cannot resolve a send any more: the controller
        // is already terminal and a late completion would reach nothing.
        for (_, completion) in sends { completion(false) }
        sends.removeAll()
        envelopes.removeAll()
    }

    private func mediaClosed() {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        mediaClosing = max(0, mediaClosing - 1)
        guard mediaClosing == 0, let next = pendingMedia else { return }
        pendingMedia = nil
        next()
    }

    // MARK: - Opening the media of one call

    /// `TextEngine.openMedia` (`:132-147`): the relay credential first, the
    /// controller's verdict second, the engine only after both.
    private func openMedia(_ generation: CallGeneration, remoteOffer: String?) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard controller.isActive, controller.generation == generation else { return }
        // Creation waits for an older engine's asynchronous close rather than
        // running beside it.
        guard mediaClosing == 0 else {
            pendingMedia = { [weak self] in
                guard let self else { return }
                openMedia(generation, remoteOffer: remoteOffer)
            }
            return
        }
        guard Self.microphoneGranted else {
            // The permission was taken away between the intent and here. This
            // device can no longer speak for itself in this call.
            controller.authorizationLost()
            return
        }
        guard engine == nil else {
            controller.mediaAuthorized(generation, authorized: false)
            return
        }
        let request = VoiceRelayLane.Request()
        relayRequest = request
        Task { [weak self] in
            guard let self else { return }
            guard let run = await owner.current else {
                await owner.onOwner { self.controller.mediaAuthorized(generation, authorized: false) }
                return
            }
            await relay.request(under: run, request: request) { outcome in
                // Delivered on the owner by `StateOwner.deliverRelay`.
                self.authorized(generation, remoteOffer: remoteOffer, outcome: outcome)
            }
        }
    }

    /// The relay lane answered for this generation
    /// (`TextEngine.java:137-146`).
    private func authorized(_ generation: CallGeneration,
                            remoteOffer: String?,
                            outcome: VoiceRelayOutcome) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard controller.isActive, controller.generation == generation else { return }
        var allowed = outcome.authorized
        // The credential's remaining lifetime is re-checked here, immediately
        // before the engine is created, and never inside the engine
        // (`VoiceRelayConfig.usable`, `TextEngine.java:139`).
        if let config = outcome.config,
           !config.usable(wallMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
                          monotonicNanoseconds: Int64(MonotonicClock.continuous.now().nanoseconds)) {
            allowed = false
        }
        if !Self.microphoneGranted { allowed = false }
        guard controller.mediaAuthorized(generation, authorized: allowed) else { return }
        createMedia(generation, remoteOffer: remoteOffer, relay: outcome.config)
    }

    /// `TextEngine.createMedia` (`:148-161`).
    private func createMedia(_ generation: CallGeneration,
                             remoteOffer: String?,
                             relay config: VoiceRelayConfig?) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        let view = controller.presentation
        let created = WebRtcAudioEngine(relay: config, muted: view.muted) { [weak self] event in
            guard let self else { return }
            Task { await self.owner.onOwner { self.media(event, from: generation) } }
        }
        engine = created
        engineGeneration = generation
        // Creation may have waited for an older engine's asynchronous close,
        // so this generation's current intent is applied before capture can
        // start.
        created.setMuted(view.muted)
        audio.setSpeaker(view.speaker)
        if let remoteOffer { created.createAnswer(remoteOffer: remoteOffer) } else { created.createOffer() }
        controller.mediaReady(generation)
    }

    /// One engine event, on the owner (`TextEngine.MediaListener`, `:162-173`).
    private func media(_ event: WebRtcAudioEngine.Event, from generation: CallGeneration) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        guard engineGeneration == generation else { return }
        switch event {
        case .localDescription(_, let sdp):
            controller.localDescription(generation, sdp: sdp)
        case .connected:
            // Only here does libwebrtc get the audio unit: a signaling state
            // is never a connection (`voice-v1.md:107-108`).
            audio.enableAudio()
            controller.mediaState(generation, .connected)
        case .disconnected:
            controller.mediaState(generation, .disconnected)
        case .failed:
            controller.mediaState(generation, .failed)
        case .videoUnavailable:
            // A camera that cannot run downgrades the call to audio and tells
            // the peer; it never ends the call (`call-v2.md:69-71`).
            audio.setVideo(false)
            controller.videoUnavailable(generation)
            announce(Strings.Notice.cameraDenied)
        }
    }

    // MARK: - CallController.Observer

    /// The public view changed (`TextEngine.java:92-102`).
    func changed(_ presentation: CallPresentation) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        let previous = lastState
        lastState = presentation.state
        // The lanes this call is signalled over are the lanes the foreground
        // rule stops when the application leaves the screen, so the policy is
        // told about every call state — including `ended`, which opens its
        // ten-second teardown window (`LifecyclePolicy`, `TextEngine.java:99`).
        runner.post(.callChanged(CallActivity(rawValue: presentation.state.rawValue) ?? .idle))
        // An incoming ring gets its audio session when it is shown, not when
        // it is answered: the ring itself must survive the process being
        // pushed to the edge of the foreground.
        if presentation.state == .incoming, previous != .incoming { audio.begin() }
        if presentation.state == .connected { audio.enableAudio() }
        // The peer's camera decides the screen as much as this device's does
        // (`MainActivity.java:533-537`: the stage, and `FLAG_KEEP_SCREEN_ON`
        // with it, is bound to `localVideo || remoteVideo`), and this is the
        // only place the remote state is published. It is applied before
        // `end()`, which clears both cameras together with the session.
        audio.setRemoteVideo(presentation.remoteVideo)
        if presentation.state == .ended || presentation.state == .idle { audio.end() }
        let model = self.model
        Task { @MainActor in model?.callChanged(presentation) }
    }

    /// One call ended. The screens keep their own log of it; nothing here
    /// reaches the core, the snapshot or the peer.
    func finished(_ termination: CallTermination) {
        precondition(owner.isOnOwner, "the call coordinator runs on the state owner")
        let model = self.model
        Task { @MainActor in model?.callFinished(termination) }
    }

    private func announce(_ text: String) {
        let model = self.model
        Task { @MainActor in model?.showNotice(text) }
    }

    // MARK: - The two permissions, read and never asked for here

    /// Whether the microphone is granted right now. This type never requests
    /// it: the request belongs to the explicit intent, on the screen
    /// (`voice-v1.md:100-101`).
    static var microphoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Whether the camera is granted right now. Same rule, and a refusal is
    /// never a call failure.
    static var cameraGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
}

/// One step on the state owner's serial queue.
///
/// `CallController` and `CallCoordinator` are plain classes that live on that
/// queue — the same shape as Android's `TextEngine.worker` — so the way into
/// them from the main actor is an isolated member of the owner that runs the
/// step and returns. Nothing of the client's state crosses: the closure is
/// `@Sendable` and both types are reached by reference.
extension StateOwner {
    func onOwner(_ body: @Sendable () -> Void) {
        body()
    }
}
