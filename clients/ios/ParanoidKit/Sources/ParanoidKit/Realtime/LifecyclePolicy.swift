/// Which lifecycle phase the application is in, as the platform reports it.
///
/// The three transitions this client reacts to are the three UIKit posts
/// `App/ParanoID/AppLifecycle.swift` subscribes to, and the distinction
/// between `resigned` and `background` is the whole point of this type: a
/// system permission alert, the Control Center pull-down and the app switcher
/// all post `willResignActive` **without** `didEnterBackground`, and treating
/// those as a pause would restart the lanes — and with them the messages-first
/// page — every time the user was asked for the microphone.
public enum LifecyclePhase: Sendable, Equatable {
    /// Nothing has been posted yet: the process is up and no scene has become
    /// active. The lanes are stopped, because nothing has started them.
    case launching
    /// `UIApplication.didBecomeActiveNotification`.
    case foreground
    /// `UIApplication.willResignActiveNotification` and nothing since: an
    /// alert, the Control Center or the app switcher is covering the
    /// application, which is still in the foreground.
    case resigned
    /// `UIApplication.didEnterBackgroundNotification`.
    case background
}

/// How far along the call controller is, in the words the core and the Android
/// controller publish (`clients/android/src/org/paranoid/text/CallController.java:49,93,96,104,139,147,179,226,264`).
///
/// The raw values are those published strings, so the call controller that
/// arrives with the call screens maps its view without a table of its own.
/// Only one question is asked of them here — whether a call is live — and the
/// answer is Android's own, written the same way round:
/// `callActive = !state.equals("idle") && !state.equals("ended")`
/// (`TextEngine.java:86`). The switch is exhaustive on purpose: a state added
/// later cannot inherit a default that would quietly take the lanes down in
/// the middle of a call.
public enum CallActivity: String, Sendable, Equatable, CaseIterable {
    /// No call (`CallController.java:49`).
    case idle
    /// An outgoing call the user has just placed (`:96`).
    case starting
    /// An outgoing call waiting for the callee's nonce (`:104,139`).
    case authorizing
    /// An incoming call on the screen, not yet answered (`:179`).
    case incoming
    /// The answer is known and the media is coming up (`:147`).
    case connecting
    /// Media is flowing (`:226`).
    case connected
    /// The call is over (`:93,264`). Android keeps this state until the next
    /// call and holds the connection for ten more seconds instead
    /// (`TextEngine.java:81-83`), which is what `LifecyclePolicy.callTeardown`
    /// is.
    case ended

    /// Whether a call is live right now (`TextEngine.java:86`).
    public var isActive: Bool {
        switch self {
        case .idle, .ended:
            return false
        case .starting, .authorizing, .incoming, .connecting, .connected:
            return true
        }
    }
}

/// One thing that happened, in the order it happened.
///
/// Everything the policy knows arrives as one of these, which is what makes
/// the order it is told about them the order it sees: the platform posts are
/// handed over through `LifecycleRunner.post(_:)`, a queue, and not as
/// separate tasks whose interleaving nobody controls.
public enum LifecycleEvent: Sendable, Equatable {
    /// `UIApplication.didBecomeActiveNotification`.
    case didBecomeActive
    /// `UIApplication.willResignActiveNotification`.
    case willResignActive
    /// `UIApplication.didEnterBackgroundNotification`.
    case didEnterBackground
    /// The call controller published a new state.
    case callChanged(CallActivity)
    /// The teardown window after a call ended has elapsed. It is posted by the
    /// runner's own timer and never by the application.
    case callTeardownElapsed
}

/// What one event asks of the lanes.
public enum LifecycleAction: Sendable, Equatable {
    /// Start them, minting a generation (`StateOwner.start()`).
    case start
    /// Pause them (`StateOwner.stop()`).
    case stop
    /// Nothing at all: the lanes are left exactly as they are, which means no
    /// generation is minted and nothing in flight is refused.
    case unchanged
}

/// When the realtime lanes run: the whole foreground rule of this client, as
/// pure logic with no platform in it.
///
/// This client has no background delivery, no push and no CallKit
/// (`docs/clients/ios/README.md`), so "the lanes run while the application is
/// open" is not a default that happens to hold — it is the contract, and the
/// user is told it in so many words on the chat list and the connection
/// screen. The texts are the mock-up's and they live with the screens; this
/// type adds none of its own and is the only thing that decides *when* the
/// lanes run:
///
/// | event | state | action |
/// |---|---|---|
/// | `didBecomeActive` | lanes stopped | `start` — a new generation, so the first cycle asks for `messages` |
/// | `didBecomeActive` | lanes running | `unchanged` — the same generation |
/// | `willResignActive` | any | `unchanged` |
/// | `didEnterBackground` | a live call | `unchanged` — the signalling lanes stay up |
/// | `didEnterBackground` | inside the teardown window | `unchanged` |
/// | `didEnterBackground` | otherwise | `stop` |
/// | `callChanged` / `callTeardownElapsed` | in the background | the same three rules |
/// | `callChanged` / `callTeardownElapsed` | in the foreground | `unchanged` |
///
/// Three of those rows are the ones worth saying out loud:
///
/// - **A new generation is what makes a resumed client read its inbox now.**
///   The receive lane asks for `messages` on the first cycle of a generation
///   and for `events` afterwards (`RealtimeLoop.java:254`), so the start after
///   a background is what turns a twenty-second long poll into an immediate
///   page. That is also why a `willResignActive` that is not followed by a
///   `didEnterBackground` must not mint one: the lanes never stopped, there is
///   nothing to catch up on, and a permission alert would otherwise cost a
///   round trip and a generation every time it appeared.
/// - **An active call never stops the signalling lanes.** A call is signalled
///   over the same realtime transport as everything else — the `call` controls
///   arrive inside receive pages and leave through the outbox
///   (`docs/clients/core/voice-calls.md:54-58`) — so stopping the lanes would
///   end the call the `audio` background mode exists to keep alive. This is
///   Android's `callActive` term in `startConnection`/`stopConnection`
///   (`TextEngine.java:86,90,158-161`). The `UIBackgroundModes` entry that
///   buys the process that time is the application's and arrives with the call
///   screens; the decision here is the same either way, because a call the
///   user is on must not be cut off by a lifecycle rule.
/// - **A call that has ended still has a teardown to send.** Android keeps the
///   connection for ten seconds after a call leaves the screen
///   (`TextEngine.java:81-83`, `callDraining`) so that the last control and
///   the receipt it produces actually leave the device; the same ten seconds
///   are `callTeardown` here, measured on the monotonic clock, and when they
///   elapse in the background the lanes stop.
///
/// Nothing else starts a lane: there is no `BGTaskScheduler`, no
/// `BGAppRefreshTask` and no `PushKit` registration anywhere in this client,
/// and `LifecycleTests` scans both the package and the application sources to
/// keep it that way.
///
/// The type is a value: it is `decide`d against, not observed, so a test can
/// drive the whole table without an owner, a loop or a clock that ticks.
public struct LifecyclePolicy: Sendable {
    /// How long the lanes stay up after a call has ended, so that the last
    /// control and its receipt leave the device (`TextEngine.java:83`,
    /// `ui.postDelayed(…, 10000)`).
    public static let callTeardown: UInt64 = 10 * MonotonicClock.nanosecondsPerSecond

    /// The last phase the platform reported.
    public private(set) var phase: LifecyclePhase = .launching
    /// The last call state the controller published.
    public private(set) var call: CallActivity = .idle
    /// Whether the lanes are running, as far as this policy has been obeyed.
    public private(set) var isRunning = false

    /// When the teardown window after a call ends, if a call has ended.
    private var teardownUntil: MonotonicInstant?
    private let clock: MonotonicClock

    /// - Parameter clock: the monotonic clock the teardown window is measured
    ///   on. It is the client's one clock (`MonotonicClock.continuous`), which
    ///   keeps counting while the device sleeps.
    public init(clock: MonotonicClock = .continuous) {
        self.clock = clock
    }

    /// Whether a call that ended is still inside its teardown window.
    public var isTearingDown: Bool {
        guard let teardownUntil else { return false }
        return clock.now() < teardownUntil
    }

    /// How much of the teardown window is left, or zero when it has elapsed or
    /// never started. It is what the runner arms its one timer for.
    public var teardownRemaining: UInt64 {
        guard let teardownUntil else { return 0 }
        return teardownUntil.nanoseconds(since: clock.now())
    }

    /// Applies one event and says what the lanes should do about it.
    ///
    /// The decision and the state move together, so a caller that obeys the
    /// result keeps the two in step; a caller that drops it would keep asking
    /// for the same action, which is what `isRunning` is for.
    public mutating func decide(_ event: LifecycleEvent) -> LifecycleAction {
        switch event {
        case .didBecomeActive:
            phase = .foreground
            guard !isRunning else { return .unchanged }
            isRunning = true
            return .start
        case .willResignActive:
            // An alert, the Control Center or the app switcher. The
            // application is still in the foreground and the lanes are left
            // alone; only `didEnterBackground` is a pause.
            if phase == .foreground { phase = .resigned }
            return .unchanged
        case .didEnterBackground:
            phase = .background
            return pause()
        case .callChanged(let state):
            if state == .ended, call != .ended {
                // The call has just left the screen: Android's `callDraining`
                // window opens here (`TextEngine.java:81-83`).
                teardownUntil = clock.now().advanced(byNanoseconds: Self.callTeardown)
            } else if state != .ended {
                // A new call, or none at all: there is nothing left to tear
                // down.
                teardownUntil = nil
            }
            call = state
            return phase == .background ? pause() : .unchanged
        case .callTeardownElapsed:
            return phase == .background ? pause() : .unchanged
        }
    }

    /// The pause, with the two reasons not to take it
    /// (`TextEngine.java:83,90,158-161`).
    private mutating func pause() -> LifecycleAction {
        guard isRunning else { return .unchanged }
        // A live call is signalled over these very lanes, and the teardown of
        // one that just ended still has to leave the device.
        guard !call.isActive, !isTearingDown else { return .unchanged }
        isRunning = false
        return .stop
    }
}

/// What a lifecycle decision is applied to: the three members of
/// `RealtimeLoop` a lifecycle event touches.
///
/// It exists so that the policy can be driven without a core, a store and a
/// socket behind it — the same reason `FileSystem`, `ProofPacer` and
/// `PushHook` exist — and `RealtimeLoop` conforms with the members it already
/// has.
public protocol LifecycleTarget: Sendable {
    /// Starts the lanes, minting a generation only if they were stopped.
    func start() async -> Generation
    /// Pauses the lanes: the generation moves and everything in flight is
    /// refused when it returns.
    func stop() async
    /// Runs both lanes until the generation they started under is superseded.
    func run() async
}

extension RealtimeLoop: LifecycleTarget {}

/// The one object the application's lifecycle hooks talk to: it holds a
/// `LifecyclePolicy`, applies what it decides to the lanes, and owns the task
/// they run in.
///
/// `App/ParanoID/AppLifecycle.swift` is three `NotificationCenter`
/// subscriptions over this actor and nothing else — no UIKit type reaches the
/// package, and no decision is taken in the application — and the call
/// controller posts its state here the same way.
///
/// ## Why the events are a queue
///
/// `post(_:)` is synchronous and ordered; two `Task`s over an actor are not.
/// `didEnterBackground` and `didBecomeActive` applied in the wrong order would
/// leave the lanes stopped while the application was on screen, which is the
/// one failure this client cannot afford: nothing would arrive, and nothing
/// would say so. The platform posts therefore go into an `AsyncStream` from
/// the main thread, in the order UIKit posted them, and `consume()` applies
/// them one at a time.
///
/// ## The lanes' task
///
/// `start` mints the generation and then launches `run()`, exactly as
/// `RealtimeLoop` documents; `stop` moves the counter — which is what makes
/// every answer in flight worthless — and then cancels that task, which only
/// frees a lane parked on a long poll sooner than its next guard would. A
/// commit that froze the client stops the lanes by itself
/// (`StateOwner.perform`), and this actor does not restart them: a client that
/// cannot persist must not keep talking to a server, and the application is
/// off the network anyway because `updateTrust()` is its only source of a
/// realm and a pin.
public actor LifecycleRunner {
    private let target: any LifecycleTarget
    private let pacer: any ProofPacer
    private var policy: LifecyclePolicy
    private var lanes: Task<Void, Never>?
    private var teardown: Task<Void, Never>?

    private let events: AsyncStream<LifecycleEvent>
    private nonisolated let inbox: AsyncStream<LifecycleEvent>.Continuation

    /// - Parameters:
    ///   - target: the lanes; `RealtimeLoop` in the application.
    ///   - policy: the rules, with the clock the teardown window is measured
    ///     on.
    ///   - pacer: how the one teardown timer waits.
    public init(target: any LifecycleTarget,
                policy: LifecyclePolicy = LifecyclePolicy(),
                pacer: any ProofPacer = SleepingPacer()) {
        self.target = target
        self.policy = policy
        self.pacer = pacer
        let (events, inbox) = AsyncStream<LifecycleEvent>.makeStream(of: LifecycleEvent.self,
                                                                     bufferingPolicy: .unbounded)
        self.events = events
        self.inbox = inbox
    }

    /// The policy as it stands: what the platform last reported, what the call
    /// controller last published and whether the lanes are running.
    public var state: LifecyclePolicy { policy }

    /// Hands one event over, in order. It never blocks and never suspends, so
    /// it is safe from a `NotificationCenter` handler on the main thread.
    public nonisolated func post(_ event: LifecycleEvent) {
        inbox.yield(event)
    }

    /// Closes the queue, which ends `consume()`. The application calls it when
    /// its scene is torn down for good.
    public nonisolated func finish() {
        inbox.finish()
    }

    /// Applies posted events until the queue is closed.
    ///
    /// One at a time and in the posted order: the loop awaits each decision
    /// before it reads the next event.
    public func consume() async {
        for await event in events {
            await handle(event)
        }
    }

    /// Applies one event now, without going through the queue.
    ///
    /// The application uses `post(_:)`, which is ordered; this is the way in
    /// for the runner's own teardown timer and for the tests that drive the
    /// table by hand.
    ///
    /// - Returns: what was done to the lanes.
    @discardableResult
    public func handle(_ event: LifecycleEvent) async -> LifecycleAction {
        let action = policy.decide(event)
        switch action {
        case .start:
            lanes?.cancel()
            _ = await target.start()
            let target = self.target
            lanes = Task { await target.run() }
        case .stop:
            await target.stop()
            lanes?.cancel()
            lanes = nil
        case .unchanged:
            break
        }
        armTeardown()
        return action
    }

    /// Waits for the teardown timer this runner armed, if there is one.
    ///
    /// It is how a test that drives the clock by hand observes the stop the
    /// window ends with; the application never needs it.
    public func settle() async {
        await teardown?.value
    }

    /// Arms, re-arms or disarms the one timer that ends a teardown window.
    ///
    /// It is armed only when it can do something: the application is in the
    /// background, the lanes are still running, and the only thing keeping
    /// them up is a call that has ended. Everything else disarms it — a new
    /// call, a return to the foreground, a stop that has already happened.
    private func armTeardown() {
        guard policy.phase == .background, policy.isRunning, policy.isTearingDown else {
            teardown?.cancel()
            teardown = nil
            return
        }
        let remaining = policy.teardownRemaining
        let pacer = self.pacer
        teardown?.cancel()
        teardown = Task { [weak self] in
            do {
                try await pacer.wait(nanoseconds: remaining)
            } catch {
                return
            }
            await self?.expireTeardown()
        }
    }

    /// The end of a teardown window, on the actor.
    private func expireTeardown() async {
        guard !Task.isCancelled else { return }
        await handle(.callTeardownElapsed)
    }
}
