import Darwin
import Foundation

/// The volatile call authority: who may ring, who may capture, and what each
/// side is told.
///
/// It is `CallController.java`
/// (`clients/android/src/org/paranoid/text/CallController.java:19-379`) in
/// Swift, written from the same protocol: [voice-v1](../../../../../../docs/protocol/voice-v1.md)
/// with the [call-v2 deltas](../../../../../../docs/protocol/call-v2.md). Two
/// properties matter more than any other:
///
/// - **Nothing here is durable.** No call authority is loaded from storage and
///   none is written to it. A restart destroys readiness slots, nonces and
///   live calls, so an old offer cannot ring even if the clock moves backwards
///   (`voice-v1.md:88-93`).
/// - **Nothing here captures anything.** A knock, a ready, a ring and an
///   authenticated offer all happen with the microphone and the camera shut.
///   Media is created only from an explicit local intent — Call or Answer —
///   with permission already granted, and only once the relay lane has
///   answered (`voice-v1.md:100-104`, `call-v2.md:60-62`).
///
/// ## Where it runs
///
/// On the state owner and nowhere else, exactly as the Java controller runs on
/// one handler thread (`CallController.java:77`). Every method and every port
/// completion asserts it. That is what makes the state machine safe without a
/// lock: an authenticated control, a media callback and a user action can
/// never interleave halfway through a transition.
///
/// ## The one flag that must not decide anything durable
///
/// `connection(_:)` carries the realtime lane's online flag, and that flag
/// flickers: every server-forced reconnect publishes `false` and then `true`
/// again (`RealtimeLoop.java:237,280`, `docs/project/current-state.md:19-22`,
/// issue #19). A control this client sends goes through the durable outbox and
/// carries its own 45-second expiry, so gating one on that flag drops call
/// signaling for no gain — which is exactly the defect the Android fix
/// decoupled `knock` admission from (`CallController.java:196-198`).
///
/// This client therefore reads the flag in three places, and each one is a
/// place where sending while the lane is down would buy nothing. Two are the
/// intents the user expresses in the interface, Call
/// (``start(account:microphonePermission:videoIntent:)``) and Answer
/// (``answer(microphonePermission:)``), which need a live lane to reach the
/// relay authority before they may capture. The third is the periodic
/// heartbeat in ``tick()``: a heartbeat is a liveness claim about *now* and
/// nothing else, so one enqueued into a down lane is stale before it flushes
/// and only spends part of the sixteen-envelope call allowance
/// (``maximumPendingCallEnvelopes``) that the terminal `end` may still need —
/// "No backlog of heartbeats is created offline" (`voice-v1.md:150`).
///
/// Everything durable — `ready`, the terminal `end`, the detached `end busy` —
/// is enqueued whatever the flag says; an authenticated offer rings whether or
/// not the flag is up at that instant, because ringing costs nothing and
/// creates nothing; and a validated relay credential grants media authority
/// even if the flag dropped between the issuer's answer and its delivery,
/// because the issuer's answer is the authority and the flag is not. The Java
/// controller still gates all four (`:214,:238,:299,:306`); that is a
/// deliberate divergence, not an omission.
///
/// ## What decides time here
///
/// Only what has already expired. This type holds every deadline — the
/// 45-second readiness and negotiation window, the 15-minute call ceiling, the
/// 10-second ICE recovery, the 30 seconds of peer silence, the 10-second
/// heartbeat spacing — but it owns no timer: ``tick()`` is called from outside
/// once a second and is the single place where an expired deadline becomes a
/// terminal `end`. Between two ticks nothing here decides that time has
/// passed, which is what makes the whole state machine reproducible from a
/// fake clock.
///
/// Every deadline is monotonic. The wall clock is read for one purpose only —
/// dating the bodies — and ``checkClock()`` watches the two against each
/// other: a wall clock that moves more than
/// ``clockSkewMillis`` away from the monotonic reading between two entries is a
/// clock change, and a clock change ends the negotiation instead of extending
/// it (`voice-v1.md:130-131`).
public final class CallController {
    // MARK: - The state machine

    /// `idle -> starting -> authorizing -> outgoing | incoming -> connecting
    /// -> connected -> ended`.
    ///
    /// `authorizing` is the relay-credential wait that both sides pass through
    /// with media disabled (`voice-v1.md:155-162`): the caller enters it when
    /// its peer answers `ready`, the callee when the user presses Answer.
    /// `connected` is never a signaling conclusion — only the media engine
    /// reporting an actual connection moves the call there
    /// (`voice-v1.md:107-108`).
    public enum State: String, Sendable {
        case idle, starting, authorizing, outgoing, incoming, connecting, connected, ended
    }

    /// What the media engine reports back (`CallController.java:262-273`).
    public enum MediaState: String, Sendable {
        case connected, disconnected, failed, closed
    }

    // MARK: - Ports

    /// The durable outbox: one authenticated control for one peer.
    ///
    /// The completion means both halves of "sent" — the local durable commit
    /// **and** the server's validated acceptance (`voice-v1.md:137-139`) — and
    /// it is invoked on the state owner. `false` terminates the call: "Any
    /// enqueue failure terminates locally."
    public protocol SendPort: AnyObject {
        func send(account: String, body: CallBody, completion: @escaping (Bool) -> Void) throws
    }

    /// The media engine, which this type may command but never inspect.
    ///
    /// Every method may throw, and a throw ends the call as `failed` — with
    /// one exception: ``video(_:)`` throwing ``CallMediaError/cameraDenied``
    /// leaves the call running and audio-only, because a refused camera
    /// permission is not a call failure (`call-v2.md:69-71`).
    public protocol MediaPort: AnyObject {
        /// Create the caller's media and produce a local offer for this
        /// generation. Called only after `ready` and only with permission.
        func offer(generation: CallGeneration) throws
        /// Create the callee's media for this generation against the
        /// authenticated remote offer. Called only from an explicit Answer.
        func answer(generation: CallGeneration, remoteSdp: String) throws
        /// Apply the authenticated remote answer to the caller's engine.
        func remoteAnswer(generation: CallGeneration, remoteSdp: String) throws
        func mute(_ muted: Bool) throws
        func speaker(_ speaker: Bool) throws
        /// Start or stop the local camera. Never called except from an
        /// explicit local video action.
        func video(_ enabled: Bool) throws
        /// Tear everything down: tracks, engine, audio session, camera.
        func close()
    }

    /// Where the interface reads the call from.
    public protocol Observer: AnyObject {
        /// The public view changed. Invoked on the state owner.
        func changed(_ presentation: CallPresentation)
    }

    // MARK: - What is held

    private let clock: CallClock
    private let entropy: CallEntropy
    private unowned let owner: any CallOwner
    private let sender: any SendPort
    private let media: any MediaPort
    private weak var observer: (any Observer)?

    /// Readiness slots: at most eight, one per peer, each with its own
    /// monotonic deadline (`voice-v1.md:85-87`). Keyed by peer and call
    /// identifier, like the Java map (`CallController.java:378`).
    private var readiness: [String: Readiness] = [:]
    /// Calls that have already ended, so a retried control cannot reopen one.
    private var terminals: [String: MonotonicInstant] = [:]
    private var live: LiveCall?
    private var generationCounter: UInt64 = 0
    private var online = false
    private var state: State = .idle
    /// Whether the application is on the screen. The camera runs only while it
    /// is (`call-v2.md:67-69`), and it starts `true` because no call can begin
    /// from an application nobody is looking at.
    private var inForeground = true
    /// Which observation of the screen that is. Reports are numbered where
    /// they are taken and applied in that order here, never in the order they
    /// happen to arrive; `0` is the assumption above, which any report beats.
    private var screenPhase: UInt64 = 0
    private var endReason: CallBody.EndReason?
    private var lastAccount = ""
    private var lastCallId = ""
    /// When every knock this peer sent was admitted, newest last. Only the last
    /// minute is kept (``purge()``).
    private var peerKnocks: [String: [MonotonicInstant]] = [:]
    /// The same across every peer.
    private var globalKnocks: [MonotonicInstant] = []
    /// While the terminal table is full, every new call is refused until this
    /// instant, rather than forgetting an identifier that a retry could still
    /// name (`CallController.java:355-359`).
    private var terminalOverflowUntil = MonotonicInstant(nanoseconds: 0)
    /// The two readings ``checkClock()`` compares the next pair against.
    private var lastWallMillis: Int64
    private var lastMonotonic: MonotonicInstant

    // MARK: - The constants of the runtime

    /// `TTL`: the ring and negotiation window, the life of a readiness slot and
    /// how long an ended call is remembered (`voice-v1.md:113,86`).
    public static let ttlMillis: Int64 = 45_000
    /// `HEARTBEAT`: how often each endpoint proves it is still there
    /// (`voice-v1.md:115-116`).
    public static let heartbeatMillis: Int64 = 10_000
    /// `SILENCE`: no valid peer control for this long terminates the media
    /// (`voice-v1.md:116-117`).
    public static let silenceMillis: Int64 = 30_000
    /// `DISCONNECTED`: how long a lost ICE connection may try to come back
    /// before the call fails (`voice-v1.md:114-115`).
    public static let disconnectedMillis: Int64 = 10_000
    /// `MAX_CALL`: fifteen minutes, then the call terminates visibly
    /// (`voice-v1.md:133`).
    public static let maximumCallMillis: Int64 = 900_000
    /// `CLOCK_SKEW`: how far the wall clock may drift from the monotonic one
    /// between two entries, and how far ahead of this device a control may be
    /// dated (`voice-v1.md:130-131`).
    public static let clockSkewMillis: Int64 = 5_000
    /// How often ``tick()`` is expected to run. Nothing here depends on the
    /// spacing being exact — every deadline is read from the clock — but the
    /// elapsed time the interface shows is only as fresh as this.
    public static let tickMillis: Int64 = 1_000
    /// At most eight peers may hold a readiness slot at once
    /// (`voice-v1.md:85-86`).
    public static let maximumReadiness = 8
    /// `MAX_TERMINALS`: how many ended calls are remembered at once. A full
    /// table refuses new calls rather than forgetting one, because a forgotten
    /// identifier is one a retried control could reopen (`voice-v1.md:96-98`).
    public static let maximumTerminals = 64
    /// At most six knocks per peer per minute and twenty-four in total, on
    /// monotonic time (`voice-v1.md:96-97`).
    public static let knocksPerPeerPerMinute = 6
    public static let knocksPerMinute = 24
    /// The window both knock ceilings are counted over.
    public static let knockWindowMillis: Int64 = 60_000
    /// How many peers may hold a knock history at once; a peer beyond it is
    /// simply not admitted (`CallController.java:368`).
    private static let maximumKnockPeers = 64
    /// The core refuses a call control once the peer's outbox already holds
    /// sixteen envelopes — `call_outbox_full`, which keeps the remaining
    /// ordinary 400-envelope capacity for text (`clean_service.rs:396-400`,
    /// `voice-v1.md:147-149`). That refusal reaches this type as a ``SendPort``
    /// failure like any other, and it ends the call locally.
    public static let maximumPendingCallEnvelopes = 16

    /// - Parameters:
    ///   - clock: the wall clock the bodies are dated on and the monotonic
    ///     clock every deadline is measured on.
    ///   - owner: the state owner every call into this type must be on.
    ///   - sender: the durable outbox.
    ///   - media: the media engine.
    ///   - observer: the interface; held weakly, because it is the thing that
    ///     owns the screen and not the other way round.
    ///   - entropy: where call identifiers and nonces come from.
    public init(clock: CallClock = .system,
                owner: any CallOwner,
                sender: any SendPort,
                media: any MediaPort,
                observer: (any Observer)? = nil,
                entropy: CallEntropy = .system) {
        self.clock = clock
        self.owner = owner
        self.sender = sender
        self.media = media
        self.observer = observer
        self.entropy = entropy
        lastWallMillis = clock.wallMillis()
        lastMonotonic = clock.now()
    }

    // MARK: - The public view

    /// Whether a call exists at all (ringing, negotiating or connected).
    public var isActive: Bool {
        own()
        return live != nil
    }

    /// The current state.
    public var currentState: State {
        own()
        return state
    }

    /// Whether the realtime lane last said it was connected.
    public var isOnline: Bool {
        own()
        return online
    }

    /// What the interface may show: no SDP, no ICE credentials, no nonces —
    /// nothing that could grant a call capability if it leaked into a log or a
    /// screenshot (`CallController.java:80-90`).
    public var presentation: CallPresentation {
        own()
        let elapsed: Int64
        if let live, let connectedAt = live.connectedAt {
            elapsed = Int64(clock.now().nanoseconds(since: connectedAt) / 1_000_000)
        } else {
            elapsed = 0
        }
        return CallPresentation(
            state: state,
            account: live?.account ?? lastAccount,
            callId: live?.identity.callId ?? lastCallId,
            generation: CallGeneration(number: generationCounter),
            muted: live?.muted ?? false,
            speaker: live?.speaker ?? false,
            reconnecting: live?.disconnectedAt != nil,
            reason: endReason,
            mediaActive: live?.media ?? false,
            elapsedMillis: elapsed,
            localVideo: live?.localVideo ?? false,
            remoteVideo: live?.remoteVideo ?? false)
    }

    /// The generation the media engine callbacks of the live call must carry.
    public var generation: CallGeneration {
        own()
        return CallGeneration(number: generationCounter)
    }

    // MARK: - The lane's flag

    /// The realtime lane's online flag (`TextEngine.java:109`).
    ///
    /// It gates the two user intents and nothing else; see the note on the
    /// type.
    public func connection(_ connected: Bool) {
        own()
        online = connected
    }

    // MARK: - Local intents

    /// The explicit Call action.
    ///
    /// It mints the call identifier and the caller nonce, sends `knock` and
    /// leaves the microphone shut: "The caller requests RECORD_AUDIO only from
    /// explicit call intent … knock cannot create media"
    /// (`voice-v1.md:100-101`).
    ///
    /// - Parameters:
    ///   - account: the peer, 64 lowercase hexadecimal digits.
    ///   - microphonePermission: whether the microphone is already granted;
    ///     this type never asks for it.
    ///   - videoIntent: an explicit "video call" start. It opens no camera
    ///     here: it is applied once the media engine for this call exists, the
    ///     application is on the screen and the camera permission is granted
    ///     (`call-v2.md:73-75`).
    public func start(account: String, microphonePermission: Bool, videoIntent: Bool = false) {
        own()
        guard checkClock() else { return }
        purge()
        guard live == nil else { return }
        // A call whose identifier could not be remembered afterwards is a call
        // that a retried control could reopen, so a full terminal table refuses
        // the intent rather than taking it (`voice-v1.md:97-98`).
        guard microphonePermission, online, CallBody.isHex32(account), terminalRoom() else {
            // A refused intent is terminal and visible, and it sends nothing.
            lastAccount = account
            lastCallId = ""
            state = .ended
            endReason = microphonePermission ? .unavailable : .reject
            publish()
            return
        }
        generationCounter += 1
        let identity = CallIdentity(callId: entropy.callId(), callerNonce: entropy.nonce())
        let call = LiveCall(account: account,
                            identity: identity,
                            deadline: clock.now().advanced(byNanoseconds: Self.ttlNanoseconds),
                            outgoing: true,
                            generation: CallGeneration(number: generationCounter),
                            started: clock.now())
        call.pendingCamera = videoIntent
        live = call
        state = .starting
        endReason = nil
        publish()
        sendActive(CallBody.knock(identity, sentMillis: clock.wallMillis()))
    }

    /// The explicit Answer action: the only thing that may create the callee's
    /// media (`voice-v1.md:103-104`).
    public func answer(microphonePermission: Bool, callId: String, generation: CallGeneration) {
        own()
        guard let call = live, state == .incoming,
              call.identity.callId == callId, call.generation == generation else { return }
        answer(microphonePermission: microphonePermission)
    }

    /// Synchronous owner-local action. Cross-executor permission results must
    /// use the call-ID/generation overload, including denied permission.
    public func answer(microphonePermission: Bool) {
        own()
        guard checkClock() else { return }
        guard let call = live, state == .incoming else { return }
        guard microphonePermission, online else {
            finish(microphonePermission ? .unavailable : .reject, tellPeer: true)
            return
        }
        guard !expired(call) else {
            finish(.timeout, tellPeer: true)
            return
        }
        state = .authorizing
        publish()
        do {
            try media.answer(generation: call.generation, remoteSdp: call.remoteSdp)
            try applyRoutes(call)
        } catch {
            finish(.failed, tellPeer: true)
        }
    }

    /// Refuse a ringing call.
    public func reject() {
        own()
        guard live != nil else { return }
        finish(.reject, tellPeer: true)
    }

    /// End the call from this side: `cancel` while the peer has not answered
    /// yet, `hangup` afterwards.
    public func hangup() {
        own()
        guard let call = live else { return }
        finish(call.outgoing && !call.answerKnown ? .cancel : .hangup, tellPeer: true)
    }

    /// Local authority is gone — a confirmed 401 or a frozen store
    /// (`voice-v1.md:111-112`). Everything stops at once and the peer is not
    /// told, because this device may no longer speak for itself.
    public func authorizationLost() {
        own()
        online = false
        readiness.removeAll()
        if live != nil { finish(.unavailable, tellPeer: false) }
    }

    /// The peer was blocked: drop its readiness slot and end its call.
    public func block(account: String) {
        own()
        readiness = readiness.filter { $0.value.account != account }
        if live?.account == account { finish(.unavailable, tellPeer: false) }
    }

    /// Mute or unmute the microphone. It reaches the engine only once media
    /// exists, so a toggle during `authorizing` is remembered and applied
    /// when authority arrives (`CallController.java:122-125`).
    public func mute(_ muted: Bool) {
        own()
        guard let call = live else { return }
        call.muted = muted
        do {
            if call.media { try media.mute(muted) }
            publish()
        } catch {
            finish(.failed, tellPeer: true)
        }
    }

    /// Route to the speakerphone or back.
    public func speaker(_ speaker: Bool) {
        own()
        guard let call = live else { return }
        call.speaker = speaker
        do {
            if call.media { try media.speaker(speaker) }
            publish()
        } catch {
            finish(.failed, tellPeer: true)
        }
    }

    /// The explicit camera toggle.
    ///
    /// Camera on routes audio to the speakerphone unless a headset is the
    /// active route, and camera off restores the previous route (owner
    /// decision, `call-v2.md:63-64`); the port resolves the headset. The peer
    /// learns about it through a `media` control, never through a
    /// renegotiation — the video section stays `sendrecv` for the whole call
    /// (`call-v2.md:56-58`).
    ///
    /// - Parameter generation: the call the action was taken in. A camera
    ///   action does not arrive here in the moment it is taken — it crosses
    ///   the platform's permission dialog and at least one hop onto this
    ///   thread — and the call that was on the screen when the user tapped may
    ///   have ended and been replaced by another one in between. A platform
    ///   permission grants this process access to a camera; it never says
    ///   which call the user meant. So the call is stated, and it is checked
    ///   here, with the live call in hand, rather than wherever the action
    ///   started: nothing read before a suspension is still true after it. An
    ///   action aimed at a call that is over captures nothing and announces
    ///   nothing to the peer of the call that replaced it.
    public func video(_ enabled: Bool, generation: CallGeneration) {
        own()
        guard let call = live, call.generation == generation, call.media else { return }
        guard inForeground else {
            // What the user asked for is kept with the call it was asked of,
            // and the capture waits for a screen to show it on
            // (`call-v2.md:67-69`).
            call.pendingCamera = enabled
            return
        }
        // An explicit action settles what this call is owed: a camera switched
        // off is not handed back by the next return to the foreground.
        call.pendingCamera = false
        apply(video: enabled, to: call)
    }

    /// The camera itself, once the call it belongs to has been settled.
    ///
    /// The explicit toggle, the engine becoming ready and the return to the
    /// screen all end here, and each of them answers *which call* before it
    /// arrives — which is the whole of the difference between turning a camera
    /// on and turning this camera on.
    private func apply(video enabled: Bool, to call: LiveCall) {
        guard call.media, call.localVideo != enabled else { return }
        do {
            try media.video(enabled)
        } catch CallMediaError.cameraDenied {
            // No camera permission: the call stays, audio-only.
            publish()
            return
        } catch {
            finish(.failed, tellPeer: true)
            return
        }
        do {
            if enabled {
                call.speakerBeforeVideo = call.speaker
                call.speaker = true
            } else {
                call.speaker = call.speakerBeforeVideo
            }
            call.localVideo = enabled
            try media.speaker(call.speaker)
            announceCamera(call)
            publish()
        } catch {
            finish(.failed, tellPeer: true)
        }
    }

    /// The media engine for this generation exists: a camera this call is owed
    /// may now be opened (`call-v2.md:73-75`).
    public func mediaReady(_ generation: CallGeneration) {
        own()
        guard let call = live, call.generation == generation, call.media, call.pendingCamera
        else { return }
        // An engine that becomes ready while the application is away leaves
        // the intent standing rather than starting a capture nobody can see:
        // the debt belongs to this call and is paid when the screen returns
        // (`call-v2.md:67-69`).
        guard inForeground else { return }
        call.pendingCamera = false
        apply(video: true, to: call)
    }

    /// The application left the screen, or came back to it
    /// (`call-v2.md:67-69`: "The app leaving the foreground disables the
    /// camera (audio continues) and re-enables it on return if the user had it
    /// on"). Audio is untouched either way: only the camera stops.
    ///
    /// Android keeps this in its activity (`MainActivity.java:700,703`); here
    /// it is the controller's, and that divergence is the whole point. What
    /// has to survive a background is an *intent* — the camera the user had on
    /// — and an intent kept outside the call it was expressed in has no
    /// subject: on the way back it would be restored into whatever call
    /// happened to be live, which is a peer seeing a camera nobody turned on
    /// for it. Here it is a member of the live call, so it dies with that call
    /// and the call that replaces it inherits nothing.
    ///
    /// - Parameter phase: which observation of the screen this is, counted up
    ///   by whoever watches the scene. One trip to the background and back
    ///   produces four of these — the platform passes through *inactive* in
    ///   each direction — and each of them crosses the same two suspensions a
    ///   camera action does before it lands here, where nothing in the
    ///   language orders two unstructured tasks against each other. This flag
    ///   is state rather than a one-shot command, so a pair delivered the
    ///   wrong way round would not merely be late: `inForeground` would settle
    ///   at the older answer and stay there, leaving the camera button
    ///   recording intents that open nothing until the next trip to the
    ///   background — or, the other way round, leaving the way clear for a
    ///   capture with the application off the screen. Numbering them makes the
    ///   arrival order irrelevant: a report older than the one already applied
    ///   describes a screen that has since been superseded and is dropped, the
    ///   same rule the call generation states for a camera action.
    public func foreground(_ inForeground: Bool, phase: UInt64) {
        own()
        guard phase > screenPhase else { return }
        screenPhase = phase
        guard self.inForeground != inForeground else { return }
        self.inForeground = inForeground
        guard let call = live else { return }
        if !inForeground {
            guard call.localVideo else { return }
            call.pendingCamera = true
            apply(video: false, to: call)
            return
        }
        // The camera is owed back only once there is an engine to open it
        // with; until then the debt stands and `mediaReady` pays it.
        guard call.pendingCamera, call.media else { return }
        call.pendingCamera = false
        apply(video: true, to: call)
    }

    /// The engine reported that the camera cannot run — no permission, no
    /// device, a capture error. The call is downgraded to audio and the peer
    /// is told; the call itself never ends for it (`call-v2.md:69-71`).
    public func videoUnavailable(_ generation: CallGeneration) {
        own()
        guard let call = live, call.generation == generation, call.localVideo else { return }
        call.localVideo = false
        call.speaker = call.speakerBeforeVideo
        // The engine has already stopped capture and the route restore is best
        // effort: neither may turn a camera failure into a call failure.
        try? media.video(false)
        try? media.speaker(call.speaker)
        announceCamera(call)
        publish()
    }

    // MARK: - Media callbacks

    /// The relay-credential lane answered for this call generation.
    ///
    /// "Only a current validated issuer result (or disclosed legacy
    /// capability) grants media authority" (`voice-v1.md:157-159`). A stale
    /// generation grants nothing and terminates nothing.
    ///
    /// - Returns: whether media authority was granted.
    @discardableResult
    public func mediaAuthorized(_ generation: CallGeneration, authorized: Bool) -> Bool {
        own()
        guard checkClock() else { return false }
        guard let call = live, call.generation == generation, state == .authorizing else { return false }
        guard authorized, !expired(call) else {
            finish(expired(call) ? .timeout : .failed, tellPeer: true)
            return false
        }
        call.media = true
        state = call.outgoing ? .outgoing : .connecting
        // Both heartbeat deadlines start from the moment media authority
        // exists: before it there is nothing to keep alive.
        call.heartbeatReceived = clock.now()
        call.heartbeatSent = clock.now()
        do {
            try applyRoutes(call)
            publish()
            return true
        } catch {
            finish(.failed, tellPeer: true)
            return false
        }
    }

    /// The gathered local description of this generation: the caller's offer
    /// or the callee's answer.
    ///
    /// The fingerprint and the ICE credentials are read out of the description
    /// itself (``CallDescription``), so the three members the core
    /// cross-checks against the SDP text can never disagree with it. A
    /// description the core would refuse, or one over the frame budget, ends
    /// the call rather than travelling: it is a bug on this side, and the
    /// SDP is never rewritten to fit (`voice-v1.md:63-67`).
    public func localDescription(_ generation: CallGeneration, sdp: String) {
        own()
        guard checkClock() else { return }
        guard let call = live, call.generation == generation, !call.descriptionSent else { return }
        guard !expired(call) else {
            finish(.timeout, tellPeer: true)
            return
        }
        guard let description = CallDescription(sdp: sdp) else {
            finish(.failed, tellPeer: true)
            return
        }
        let wall = clock.wallMillis()
        let body: CallBody
        if call.outgoing, state == .outgoing {
            body = CallBody.offer(call.identity, description: description, sentMillis: wall)
            call.identity.offerDigest = body.offerDigest
        } else if !call.outgoing, state == .connecting {
            call.answerKnown = true
            body = CallBody.answer(call.identity, description: description, sentMillis: wall)
        } else {
            return
        }
        call.descriptionSent = true
        sendActive(body)
        // A camera the callee turned on while answering is announced only
        // after its own answer, never before (`call-v2.md:72-74`).
        if body.kind == .answer, call.localVideo { announceCamera(call) }
        publish()
    }

    /// What the media engine says about the actual connection. Signaling alone
    /// never displays "connected" (`voice-v1.md:107-108`).
    public func mediaState(_ generation: CallGeneration, _ mediaState: MediaState) {
        own()
        guard checkClock() else { return }
        guard let call = live, call.generation == generation, call.media else { return }
        switch mediaState {
        case .connected:
            // Nothing is "connected" before this side knows the answer, and
            // for the callee not before its own answer has been sent
            // (`CallController.java:267-268`).
            guard call.answerKnown, call.outgoing || call.descriptionSent,
                  state == .connecting || state == .connected
            else { return }
            call.disconnectedAt = nil
            if call.connectedAt == nil { call.connectedAt = clock.now() }
            state = .connected
            publish()
        case .disconnected:
            if call.disconnectedAt == nil { call.disconnectedAt = clock.now() }
            publish()
        case .failed, .closed:
            finish(.failed, tellPeer: true)
        }
    }

    // MARK: - The clock the deadlines are read by

    /// One second of the call's life, called from outside once every
    /// ``tickMillis``.
    ///
    /// It is the only place a deadline becomes an outcome, and the order below
    /// is the order of the protocol: the two ceilings that bound the call at
    /// all (fifteen minutes of duration, forty-five seconds of ringing or
    /// negotiating) come before the ICE recovery window, which comes before the
    /// peer's silence, which comes before this side's own heartbeat. Each of
    /// the four ends the call with its own reason, and the first one that has
    /// expired is the one that decides — a call that is both over its duration
    /// and silent ends as `timeout`, not as two different things depending on
    /// which branch ran first (`CallController.java:274-287`).
    ///
    /// A tick also refreshes the public view, which is how the elapsed time on
    /// the screen advances.
    public func tick() {
        own()
        guard checkClock() else { return }
        purge()
        guard let call = live else { return }
        let now = clock.now()
        // Fifteen minutes of call, or forty-five seconds of anything that is
        // not a connected call (`voice-v1.md:113,133`).
        guard millis(from: call.started, to: now) < Self.maximumCallMillis,
              state == .connected || !expired(call)
        else {
            finish(.timeout, tellPeer: true)
            return
        }
        // A lost ICE connection has ten seconds to come back
        // (`voice-v1.md:114-115`).
        if let disconnectedAt = call.disconnectedAt,
           millis(from: disconnectedAt, to: now) >= Self.disconnectedMillis {
            finish(.failed, tellPeer: true)
            return
        }
        if state == .connecting || state == .connected {
            // Thirty seconds without any valid control from the peer — a
            // heartbeat, a `media`, anything — is the end of the media
            // (`voice-v1.md:116-117`).
            guard millis(from: call.heartbeatReceived, to: now) < Self.silenceMillis else {
                finish(.timeout, tellPeer: true)
                return
            }
            // One heartbeat every ten seconds, and never a second one while the
            // first is still waiting for the server to accept it
            // (`voice-v1.md:143-145`).
            if online, !call.heartbeatPending,
               millis(from: call.heartbeatSent, to: now) >= Self.heartbeatMillis {
                call.heartbeatSent = now
                call.heartbeatPending = true
                let body = CallBody.heartbeat(call.identity, seq: call.nextSequence,
                                              sentMillis: clock.wallMillis())
                call.nextSequence += 1
                sendActive(body, heartbeat: true)
            }
        }
        // `finish` has already published; a call that survived the tick
        // publishes its new elapsed time here.
        if live != nil { publish() }
    }

    /// Whether the two clocks still agree, and the end of the negotiation when
    /// they do not.
    ///
    /// The monotonic clock is the reference: between two entries into this type
    /// it measures how much time actually passed, and the wall clock must have
    /// moved by the same amount give or take ``clockSkewMillis``. A larger
    /// divergence is the user, a time server or a broken RTC moving the clock,
    /// and "wall-clock jumps terminate active negotiations rather than extend
    /// consent" (`voice-v1.md:92-93`): every readiness slot is dropped and a
    /// live call ends as `failed` — without telling the peer, because a body
    /// dated from a clock this device has just stopped trusting is one the peer
    /// would refuse anyway.
    ///
    /// A monotonic reading that went backwards is the same verdict: the one
    /// clock that cannot lie just did.
    private func checkClock() -> Bool {
        let now = clock.now()
        let wall = clock.wallMillis()
        let backwards = now < lastMonotonic
        let monotonicElapsed = Int64(min(now.nanoseconds(since: lastMonotonic) / 1_000_000,
                                         UInt64(Int64.max)))
        let (wallElapsed, wallOverflow) = wall.subtractingReportingOverflow(lastWallMillis)
        let (divergence, divergenceOverflow) = wallElapsed.subtractingReportingOverflow(monotonicElapsed)
        lastMonotonic = now
        lastWallMillis = wall
        guard !backwards, wall > 0, !wallOverflow, !divergenceOverflow,
              divergence <= Self.clockSkewMillis, divergence >= -Self.clockSkewMillis
        else {
            readiness.removeAll()
            if live != nil { finish(.failed, tellPeer: false) }
            return false
        }
        return true
    }

    /// The distance between two monotonic instants in milliseconds, saturating
    /// rather than wrapping.
    private func millis(from earlier: MonotonicInstant, to later: MonotonicInstant) -> Int64 {
        Int64(min(later.nanoseconds(since: earlier) / 1_000_000, UInt64(Int64.max)))
    }

    // MARK: - Authenticated input

    /// One authenticated, committed call control as it arrived from the core
    /// (`call_event`: `{account, channel, body}`, `clean_service.rs:157-161`).
    ///
    /// The body text is decoded, checked against the kind table and against
    /// this device's clock before anything at all happens; an invalid control
    /// cannot grant interface or media authority, and it is dropped in
    /// silence.
    public func received(account: String, json: String) {
        own()
        guard let body = try? CallBody.accept(json, wallMillis: clock.wallMillis()) else { return }
        received(account: account, body: body)
    }

    /// The same, for a body that has already been decoded and validated.
    public func received(account: String, body: CallBody) {
        own()
        guard checkClock() else { return }
        purge()
        guard CallBody.isHex32(account) else { return }
        guard (try? body.validate()) != nil, (try? body.check(wallMillis: clock.wallMillis())) != nil
        else { return }
        // A call that has already ended never reopens, whatever is retried —
        // and while the terminal table has overflowed, nothing at all is
        // admitted, because this device can no longer prove that an identifier
        // is new (`CallController.java:165`).
        guard terminals[Self.key(account, body.callId)] == nil,
              clock.now() >= terminalOverflowUntil
        else { return }

        // A knock and an offer are admitted against the readiness table, not
        // against a live call, and an end may be the cancellation of a
        // readiness slot rather than of anything live.
        if body.kind == .knock {
            knock(account: account, body: body)
            return
        }
        if body.kind == .offer {
            offer(account: account, body: body)
            return
        }
        if body.kind == .end, releaseReadiness(account: account, body: body) { return }

        guard let call = live, call.account == account,
              call.identity.callId == body.callId,
              call.identity.callerNonce == body.callerNonce
        else { return }

        if body.kind == .ready {
            guard call.outgoing, state == .starting, body.seq == 0,
                  call.identity.calleeNonce.isEmpty, !expired(call)
            else { return }
            call.identity.calleeNonce = body.calleeNonce
            call.remoteSequence = 0
            state = .authorizing
            publish()
            do {
                try media.offer(generation: call.generation)
                try applyRoutes(call)
            } catch {
                finish(.failed, tellPeer: true)
            }
            return
        }

        // Everything from here on belongs to one exact call context: both
        // nonces, the exact offer digest and a sequence above the last one
        // this sender used (`voice-v1.md:105-107`).
        guard call.identity.calleeNonce == body.calleeNonce, body.seq > call.remoteSequence,
              call.identity.offerDigest == body.offerDigest
        else { return }

        switch body.kind {
        case .end:
            call.remoteSequence = body.seq
            finish(body.endReason ?? .failed, tellPeer: false)
        case .answer:
            guard call.outgoing, state == .outgoing, call.descriptionSent,
                  !call.identity.offerDigest.isEmpty, body.seq == 1, !expired(call)
            else { return }
            call.remoteSequence = body.seq
            call.answerKnown = true
            state = .connecting
            call.heartbeatReceived = clock.now()
            publish()
            do {
                try media.remoteAnswer(generation: call.generation, remoteSdp: body.sdp)
            } catch {
                finish(.failed, tellPeer: true)
                return
            }
            // The caller may already have had its camera on from a video-call
            // intent; the peer learns it now that there is a call to announce
            // it in.
            if call.localVideo { announceCamera(call) }
        case .heartbeat:
            guard state == .connecting || state == .connected, body.seq >= 2 else { return }
            call.remoteSequence = body.seq
            call.heartbeatReceived = clock.now()
        case .media:
            guard state == .connecting || state == .connected, body.seq >= 2 else { return }
            // Informative only: this says what the peer claims, and actual
            // frames come from the authenticated transport alone. A forged
            // `media` cannot open a camera (`call-v2.md:30-32`).
            call.remoteSequence = body.seq
            call.heartbeatReceived = clock.now()
            call.remoteVideo = body.video
            publish()
        case .knock, .ready, .offer:
            return
        }
    }

    // MARK: - Receiving side

    /// An authenticated knock: answer `ready` from a fresh in-memory nonce,
    /// with no microphone and no PeerConnection (`voice-v1.md:85-87`).
    private func knock(account: String, body: CallBody) {
        // The two ceilings come before anything else, the detached busy
        // included: a peer that has run out of knocks gets no answer at all,
        // or the answer would be the amplification the ceiling exists to stop
        // (`CallController.java:199`).
        guard allowKnock(account: account), terminalRoom() else { return }
        // An occupied client is honest about it at once (`voice-v1.md:94-95`).
        guard live == nil else {
            sendDetached(account: account, body: body, calleeNonce: "", offerDigest: "", reason: .busy)
            return
        }
        // One slot per peer, at most eight in total.
        guard !readiness.values.contains(where: { $0.account == account }),
              readiness.count < Self.maximumReadiness
        else { return }
        let key = Self.key(account, body.callId)
        var identity = body.identity
        identity.calleeNonce = entropy.nonce()
        let slot = Readiness(account: account, identity: identity, deadline: deadline(of: body))
        readiness[key] = slot
        let ready = CallBody.ready(identity, sentMillis: clock.wallMillis())
        do {
            try sender.send(account: account, body: ready) { [weak self] accepted in
                guard let self else { return }
                own()
                // A readiness slot whose answer never reached the server is
                // not a slot: it is released, and the peer may knock again.
                if !accepted, readiness[key]?.identity.calleeNonce == identity.calleeNonce {
                    readiness.removeValue(forKey: key)
                }
            }
        } catch {
            readiness.removeValue(forKey: key)
        }
    }

    /// An authenticated offer: it is useful only for this peer's exact
    /// unexpired readiness slot and both nonces, and it consumes that slot
    /// (`voice-v1.md:87-88`).
    private func offer(account: String, body: CallBody) {
        let key = Self.key(account, body.callId)
        guard let slot = readiness[key], !expired(slot.deadline),
              slot.account == account,
              slot.identity.callId == body.callId,
              slot.identity.callerNonce == body.callerNonce,
              slot.identity.calleeNonce == body.calleeNonce,
              body.seq == 1,
              CallBody.digest(of: body.sdp) == body.offerDigest
        else { return }
        readiness.removeValue(forKey: key)
        guard live == nil, terminalRoom() else {
            sendDetached(account: account, body: body, calleeNonce: slot.identity.calleeNonce,
                         offerDigest: body.offerDigest, reason: .busy)
            remember(account: account, callId: body.callId)
            return
        }
        generationCounter += 1
        var identity = slot.identity
        identity.offerDigest = body.offerDigest
        let call = LiveCall(account: account,
                            identity: identity,
                            deadline: min(slot.deadline, deadline(of: body)),
                            outgoing: false,
                            generation: CallGeneration(number: generationCounter),
                            started: clock.now())
        call.remoteSdp = body.sdp
        call.remoteSequence = 1
        live = call
        state = .incoming
        endReason = nil
        // Ringing creates nothing: no microphone, no camera, no engine
        // (`voice-v1.md:102-103`, `call-v2.md:60-61`).
        publish()
    }

    /// A pre-offer `end` that matches a readiness slot releases it.
    ///
    /// The caller may cancel while our `ready` is still in flight, which is
    /// why an empty callee nonce is accepted *here* and nowhere else: this
    /// releases a readiness slot only, and never touches a ringing or
    /// connected call (`voice-v1.md:56-60`).
    ///
    /// - Returns: whether the control was consumed by a readiness slot.
    private func releaseReadiness(account: String, body: CallBody) -> Bool {
        let key = Self.key(account, body.callId)
        guard let slot = readiness[key], body.offerDigest.isEmpty,
              slot.account == account,
              slot.identity.callId == body.callId,
              slot.identity.callerNonce == body.callerNonce,
              body.calleeNonce.isEmpty || slot.identity.calleeNonce == body.calleeNonce
        else { return false }
        readiness.removeValue(forKey: key)
        remember(account: account, callId: body.callId)
        return true
    }

    // MARK: - Sending

    /// One control of the live call.
    ///
    /// The completion means both halves of "sent" — the durable local commit
    /// **and** the server's validated acceptance — and anything less terminates
    /// the call locally: "Any enqueue failure terminates locally"
    /// (`voice-v1.md:145-147`). The refusal the core raises once the peer's
    /// outbox already holds ``maximumPendingCallEnvelopes`` call envelopes
    /// arrives the same way, as a throw or a `false`.
    ///
    /// - Parameter heartbeat: whether an acceptance releases the one heartbeat
    ///   that may be outstanding at a time.
    private func sendActive(_ body: CallBody, heartbeat: Bool = false) {
        guard let call = live else { return }
        let generation = call.generation
        do {
            try sender.send(account: call.account, body: body) { [weak self] accepted in
                guard let self else { return }
                own()
                // A completion that comes back under a superseded call belongs
                // to nothing: it neither terminates nor revives anything.
                guard let current = live, current.generation == generation else { return }
                guard accepted else {
                    finish(.failed, tellPeer: false)
                    return
                }
                if heartbeat { current.heartbeatPending = false }
            }
        } catch {
            if live?.generation == generation { finish(.failed, tellPeer: false) }
        }
    }

    /// An `end` that belongs to no live call: the `busy` this client owes a
    /// peer it cannot talk to (`voice-v1.md:94-95`).
    ///
    /// It creates no local media authority and no state of any kind, and it is
    /// enqueued whatever the online flag says — it is a durable control like
    /// any other.
    private func sendDetached(account: String,
                              body: CallBody,
                              calleeNonce: String,
                              offerDigest: String,
                              reason: CallBody.EndReason) {
        let identity = CallIdentity(callId: body.callId, callerNonce: body.callerNonce,
                                    calleeNonce: calleeNonce, offerDigest: offerDigest)
        let end = CallBody.end(identity, seq: 2, reason: reason, sentMillis: clock.wallMillis())
        try? sender.send(account: account, body: end) { [weak self] _ in self?.own() }
    }

    /// Tell the peer this camera went on or off, if there is a call to say it
    /// in: a `media` control exists only after this sender's own offer or
    /// answer, and only while the call is negotiating or up
    /// (`call-v2.md:72-74`).
    private func announceCamera(_ call: LiveCall) {
        guard call.descriptionSent, state == .connecting || state == .connected else { return }
        let body = CallBody.media(call.identity, seq: call.nextSequence, cameraOn: call.localVideo,
                                  sentMillis: clock.wallMillis())
        call.nextSequence += 1
        sendActive(body)
    }

    /// Every terminal path: the peer is told (unless this device has lost the
    /// right to speak), the media is disposed, the call identifier is
    /// remembered so nothing reopens it, and the view is published.
    private func finish(_ reason: CallBody.EndReason, tellPeer: Bool) {
        guard let call = live else { return }
        var end: CallBody?
        if tellPeer {
            end = CallBody.end(call.identity, seq: call.nextSequence, reason: reason,
                               sentMillis: clock.wallMillis())
            call.nextSequence += 1
        }
        live = nil
        generationCounter += 1
        lastAccount = call.account
        lastCallId = call.identity.callId
        state = .ended
        endReason = reason
        remember(account: call.account, callId: call.identity.callId)
        media.close()
        publish()
        if let end {
            // The call is already terminal here: the completion of this last
            // control can neither revive it nor end it again.
            try? sender.send(account: call.account, body: end) { [weak self] _ in self?.own() }
        }
    }

    private func applyRoutes(_ call: LiveCall) throws {
        try media.mute(call.muted)
        try media.speaker(call.speaker)
    }

    private func publish() {
        observer?.changed(presentation)
    }

    // MARK: - Deadlines and terminal memory

    /// ``ttlMillis`` as the nanoseconds every monotonic deadline is built from.
    private static let ttlNanoseconds = UInt64(ttlMillis) * 1_000_000

    /// The monotonic deadline a received control asks for, clamped to the
    /// 45-second window: a peer's clock never extends this device's consent
    /// (`CallController.java:353`).
    private func deadline(of body: CallBody) -> MonotonicInstant {
        let remaining = max(0, min(Self.ttlMillis, body.expiresMillis - clock.wallMillis()))
        return clock.now().advanced(byNanoseconds: UInt64(remaining) * 1_000_000)
    }

    private func expired(_ call: LiveCall) -> Bool { expired(call.deadline) }

    private func expired(_ deadline: MonotonicInstant) -> Bool { clock.now() >= deadline }

    /// Remember one ended call for as long as a control of it could still
    /// arrive.
    ///
    /// The table is bounded at ``maximumTerminals``, and a full one is never
    /// made room in by forgetting an identifier — a forgotten call is a call a
    /// retried control reopens. Instead the whole device stops taking new calls
    /// for one TTL, by which time the oldest entries have expired on their own
    /// (`voice-v1.md:97-98`, `CallController.java:356-359`).
    private func remember(account: String, callId: String) {
        let key = Self.key(account, callId)
        guard terminals.count < Self.maximumTerminals || terminals[key] != nil else {
            terminalOverflowUntil = clock.now().advanced(byNanoseconds: Self.ttlNanoseconds)
            return
        }
        terminals[key] = clock.now().advanced(byNanoseconds: Self.ttlNanoseconds)
    }

    /// Whether one more ended call could be remembered if this one were taken.
    private func terminalRoom() -> Bool {
        terminals.count < Self.maximumTerminals && clock.now() >= terminalOverflowUntil
    }

    /// Whether this peer may knock again, and the record that it did.
    ///
    /// Six knocks per peer per minute and twenty-four across every peer, all on
    /// monotonic time so that moving the wall clock cannot buy a knock
    /// (`voice-v1.md:96-97`). The number of peers that may hold a history at
    /// once is bounded too, so that unknown senders cannot grow this table.
    private func allowKnock(account: String) -> Bool {
        let now = clock.now()
        if peerKnocks[account] == nil {
            guard peerKnocks.count < Self.maximumKnockPeers else { return false }
            peerKnocks[account] = []
        }
        var forPeer = Self.recent(peerKnocks[account] ?? [], now: now)
        globalKnocks = Self.recent(globalKnocks, now: now)
        guard forPeer.count < Self.knocksPerPeerPerMinute,
              globalKnocks.count < Self.knocksPerMinute
        else {
            peerKnocks[account] = forPeer
            return false
        }
        forPeer.append(now)
        peerKnocks[account] = forPeer
        globalKnocks.append(now)
        return true
    }

    /// Drop what has expired: readiness slots no offer can use any more,
    /// terminal identifiers no control can name any more, and knocks that are
    /// older than the minute the two ceilings are counted over.
    private func purge() {
        let now = clock.now()
        readiness = readiness.filter { $0.value.deadline > now }
        terminals = terminals.filter { $0.value > now }
        globalKnocks = Self.recent(globalKnocks, now: now)
        peerKnocks = peerKnocks.compactMapValues { history in
            let recent = Self.recent(history, now: now)
            return recent.isEmpty ? nil : recent
        }
    }

    /// The entries of a knock history that are still inside the window.
    private static func recent(_ history: [MonotonicInstant],
                               now: MonotonicInstant) -> [MonotonicInstant] {
        let window = UInt64(knockWindowMillis) * 1_000_000
        return history.filter { now.nanoseconds(since: $0) < window }
    }

    private static func key(_ account: String, _ callId: String) -> String {
        "\(account):\(callId)"
    }

    /// Every method of this type and every port completion runs on the state
    /// owner (`CallController.java:77`).
    private func own() {
        precondition(owner.isOnOwner, "the call controller runs on the state owner")
    }

    // MARK: - What one call is

    /// A peer this device has answered `ready` to.
    private struct Readiness {
        let account: String
        var identity: CallIdentity
        var deadline: MonotonicInstant
    }

    /// The one live call. A reference, because a port called from the middle
    /// of a transition may call straight back in — the smoke fixtures do
    /// exactly that — and a copy written back afterwards would erase whatever
    /// the re-entrant call decided.
    private final class LiveCall {
        let account: String
        var identity: CallIdentity
        var deadline: MonotonicInstant
        let outgoing: Bool
        let generation: CallGeneration
        var remoteSdp = ""
        /// The next sequence this device will send: knock/ready are 0, the
        /// description is 1, everything after it counts from 2.
        var nextSequence: Int64 = 2
        /// The highest sequence accepted from the peer; `-1` before any.
        var remoteSequence: Int64 = -1
        var media = false
        var muted = false
        var speaker = false
        var answerKnown = false
        var descriptionSent = false
        /// This device's camera, as the user set it.
        var localVideo = false
        /// The peer's camera, as its last authenticated `media` control
        /// claimed.
        var remoteVideo = false
        /// A camera this call owes the user and has not opened yet: an
        /// explicit "video call" start waiting for the media engine
        /// (`call-v2.md:73-75`), or the camera the background took away and
        /// the foreground has to give back (`:67-69`). It lives on the call so
        /// that it ends with it.
        var pendingCamera = false
        var speakerBeforeVideo = false
        /// When something was last heard from the peer. Every accepted
        /// control of a live call refreshes it, the `media` control included
        /// (`call-v2.md:27`), because that is what the peer being silent is
        /// measured from.
        var heartbeatReceived: MonotonicInstant
        /// When this side last sent a heartbeat, and whether that one is still
        /// waiting for the server to accept it. At most one may be
        /// (`voice-v1.md:143-145`).
        var heartbeatSent: MonotonicInstant
        var heartbeatPending = false
        var disconnectedAt: MonotonicInstant?
        var connectedAt: MonotonicInstant?
        /// The explicit intent this call grew out of. The fifteen-minute
        /// ceiling is measured from here and not from the connection, so
        /// neither a long ring nor a reconnection can extend it.
        let started: MonotonicInstant

        init(account: String,
             identity: CallIdentity,
             deadline: MonotonicInstant,
             outgoing: Bool,
             generation: CallGeneration,
             started: MonotonicInstant) {
            self.account = account
            self.identity = identity
            self.deadline = deadline
            self.outgoing = outgoing
            self.generation = generation
            self.started = started
            heartbeatReceived = started
            heartbeatSent = started
        }
    }
}

// MARK: - The pieces the controller is built from

/// One run of one call's media.
///
/// Every media callback carries the generation it was created under, and a
/// callback from a superseded one grants nothing and terminates nothing: "stale
/// callback generation … cannot change live media" (`voice-v1.md:106-107`).
public struct CallGeneration: Hashable, Sendable, CustomStringConvertible {
    public let number: UInt64

    public init(number: UInt64) {
        self.number = number
    }

    public var description: String { "call generation \(number)" }
}

/// What a media port may fail with.
public enum CallMediaError: Error, Equatable, Sendable {
    /// The camera permission is not granted, or the user refused it. The call
    /// continues, audio-only (`call-v2.md:69-71`).
    case cameraDenied
}

/// Whatever answers "am I on the state owner right now?".
///
/// `StateOwner` is it in the application; a test supplies its own. The check
/// is a runtime one because the owner is an object with a serial executor and
/// not a global actor, so there is nothing for the compiler to check instead.
public protocol CallOwner: AnyObject {
    var isOnOwner: Bool { get }
}

extension StateOwner: CallOwner {}

/// The two clocks a call is measured on.
///
/// Wall-clock milliseconds date the bodies and decide freshness, because that
/// is what the wire carries; every deadline — ring, heartbeat, silence,
/// duration — is measured on the monotonic clock instead, so that moving the
/// device clock cannot extend consent by a millisecond
/// (`voice-v1.md:92-93,116-118`).
public struct CallClock: Sendable {
    public let monotonic: MonotonicClock
    private let wall: @Sendable () -> Int64

    public init(monotonic: MonotonicClock, wall: @escaping @Sendable () -> Int64) {
        self.monotonic = monotonic
        self.wall = wall
    }

    /// The device clocks: `mach_continuous_time()` for intervals and the
    /// system's UTC time for the bodies.
    public static let system = CallClock(monotonic: .continuous) {
        var time = timeval()
        guard gettimeofday(&time, nil) == 0 else { return 0 }
        return Int64(time.tv_sec) * 1_000 + Int64(time.tv_usec) / 1_000
    }

    /// UTC milliseconds, as `sent_ms` and `expires_ms` carry them.
    public func wallMillis() -> Int64 { wall() }

    /// The monotonic reading every deadline is measured against.
    public func now() -> MonotonicInstant { monotonic.now() }
}

/// Where a call identifier and a nonce come from.
///
/// Both are fresh per explicit action and live only in memory: "Caller
/// explicit call action creates call ID/nonce", "the receiver … creating an
/// in-memory random callee nonce" (`voice-v1.md:84-86`). They are the runtime
/// consent boundary, so they come from the system's cryptographic generator
/// and from nowhere else — a test supplies its own only to be able to name
/// them.
public struct CallEntropy: Sendable {
    private let nonceSource: @Sendable () -> String
    private let callIdSource: @Sendable () -> String

    public init(nonce: @escaping @Sendable () -> String,
                callId: @escaping @Sendable () -> String) {
        nonceSource = nonce
        callIdSource = callId
    }

    /// 32 random bytes as 64 lowercase hexadecimal digits, and a random
    /// UUIDv4 in its canonical lowercase form.
    ///
    /// `SystemRandomNumberGenerator` is the platform's cryptographic
    /// generator, and `UUID()` is version 4 from the same source.
    public static let system = CallEntropy(
        nonce: {
            var generator = SystemRandomNumberGenerator()
            return (0..<32)
                .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
                .joined()
        },
        callId: { UUID().uuidString.lowercased() })

    public func nonce() -> String { nonceSource() }

    public func callId() -> String { callIdSource() }
}

/// What the interface may know about a call.
///
/// It is the Java public view (`CallController.java:80-90`) member for member:
/// no SDP, no ICE credentials and neither nonce — nothing here could grant a
/// call capability to anything that reads it.
public struct CallPresentation: Equatable, Sendable {
    public let state: CallController.State
    /// The peer, or the last peer once the call has ended.
    public let account: String
    public let callId: String
    public let generation: CallGeneration
    public let muted: Bool
    public let speaker: Bool
    /// The media engine lost its connection and is inside its recovery window.
    public let reconnecting: Bool
    /// Why the last call ended.
    public let reason: CallBody.EndReason?
    /// Whether media authority has been granted for this call.
    public let mediaActive: Bool
    /// How long the call has actually been connected.
    public let elapsedMillis: Int64
    public let localVideo: Bool
    /// What the peer's last authenticated `media` control claimed.
    public let remoteVideo: Bool
}
