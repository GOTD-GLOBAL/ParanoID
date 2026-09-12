import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the foreground rule: when the realtime lanes run, when
/// they stop, and what a call does to that
/// (`docs/clients/ios/README.md`, `clients/android/src/org/paranoid/text/TextEngine.java:81-90,157-161`).
///
/// The lanes are a fake in every check but the first, which drives the real
/// `RealtimeLoop` over the real core (the macOS slice of
/// `ParanoidCore.xcframework`) so that the generations are the owner's own.
/// Nothing here opens a connection: the device has no identity, so no lane
/// dials anything at all (`RealtimeLoop.java:171,275`), and no account is
/// created on any server.
final class LifecycleTests: XCTestCase {
    /// The local stand of a simulator run. Nothing in these tests may reach
    /// the hosted alpha.
    private static let stand = try! ServiceTrust(realm: "https://127.0.0.2:38443",
                                                 pin: String(repeating: "ab", count: 32))

    // MARK: - the generations of a real loop

    func testBecomingActiveStartsTheLanesAndASecondNotificationKeepsTheSameGeneration() async throws {
        let live = try Live()
        let runner = LifecycleRunner(target: live.loop)

        let started = await runner.handle(.didBecomeActive)
        XCTAssertEqual(started, .start)
        let minted = await live.owner.current
        let first = try XCTUnwrap(minted)

        // A second `didBecomeActive` restarts nothing: the generation is the
        // one the lanes are already running (`RealtimeLoop.java:53`,
        // `StateOwner.start()`).
        let again = await runner.handle(.didBecomeActive)
        XCTAssertEqual(again, .unchanged)
        let unchanged = await live.owner.current
        XCTAssertEqual(unchanged, first)

        // A system alert or the Control Center: `willResignActive` with no
        // `didEnterBackground` after it, and then the application is on screen
        // again. Neither notification touches the lanes, so the run the
        // receive lane is waiting under is still the run it started with and
        // no `messages` page is asked for.
        let resigned = await runner.handle(.willResignActive)
        XCTAssertEqual(resigned, .unchanged)
        let resignedPhase = await runner.state.phase
        XCTAssertEqual(resignedPhase, .resigned)
        let resumed = await runner.handle(.didBecomeActive)
        XCTAssertEqual(resumed, .unchanged)
        let kept = await live.owner.current
        XCTAssertEqual(kept, first, "an alert costs neither a generation nor a round trip")

        // The background is the pause, and it is the generation that makes
        // every answer still in flight worthless
        // (`docs/protocol/realtime-v1.md:127-130`).
        let paused = await runner.handle(.didEnterBackground)
        XCTAssertEqual(paused, .stop)
        let stopped = await live.owner.current
        XCTAssertNil(stopped)
        let stale = await live.owner.isCurrent(first)
        XCTAssertFalse(stale)

        // Coming back mints one, which is what makes the first cycle of the
        // resumed lane ask for `messages` rather than wait on `events`
        // (`RealtimeLoop.java:254`): `stop()` moved the counter and `start()`
        // moves it again.
        let restarted = await runner.handle(.didBecomeActive)
        XCTAssertEqual(restarted, .start)
        let resumedRun = await live.owner.current
        let next = try XCTUnwrap(resumedRun)
        XCTAssertEqual(next.run, first.run + 2)
        // The session survived both, because a pause is not a reset
        // (`docs/protocol/realtime-v1.md:179-181`); this device never opened
        // one, so what is checked is that nothing dialled to find out.
        XCTAssertEqual(live.transport.calls.count, 0, "a device without an identity dials nothing")

        await runner.handle(.didEnterBackground)
    }

    // MARK: - an alert is not a pause

    func testAResignThatIsNotFollowedByABackgroundChangesNothing() async throws {
        let lanes = FakeLanes()
        let runner = LifecycleRunner(target: lanes)

        let started = await runner.handle(.didBecomeActive)
        XCTAssertEqual(started, .start)
        let minted = lanes.generation

        let resigned = await runner.handle(.willResignActive)
        XCTAssertEqual(resigned, .unchanged)
        let resumed = await runner.handle(.didBecomeActive)
        XCTAssertEqual(resumed, .unchanged)

        XCTAssertEqual(lanes.log, ["start"], "neither a stop nor a second start")
        XCTAssertEqual(lanes.generation, minted)
        let phase = await runner.state.phase
        XCTAssertEqual(phase, .foreground)
        let running = await runner.state.isRunning
        XCTAssertTrue(running)
    }

    // MARK: - a call keeps the signalling lanes

    func testTheBackgroundStopsTheLanesUnlessACallIsLive() async throws {
        // The outgoing states of the call controller are `starting`,
        // `authorizing` and `connecting` (`CallController.java:96,104,147`);
        // `incoming` is the answered-or-not screen and `connected` is media
        // flowing. All five are Android's `callActive`
        // (`TextEngine.java:86`), and the lanes they are signalled over cannot
        // be the thing that ends them
        // (`docs/clients/core/voice-calls.md:54-58`).
        for state in CallActivity.allCases {
            let source = FakeMonotonicSource()
            let lanes = FakeLanes()
            let runner = LifecycleRunner(target: lanes,
                                         policy: LifecyclePolicy(clock: source.clock),
                                         pacer: RecordingPacer())

            await runner.handle(.didBecomeActive)
            await runner.handle(.callChanged(state))
            let action = await runner.handle(.didEnterBackground)

            switch state {
            case .starting, .authorizing, .incoming, .connecting, .connected:
                XCTAssertEqual(action, .unchanged, "\(state.rawValue) is a live call")
                XCTAssertEqual(lanes.log, ["start"])
                let running = await runner.state.isRunning
                XCTAssertTrue(running)
            case .ended:
                // The call is over but its last control and the receipt it
                // produces have ten seconds to leave the device
                // (`TextEngine.java:81-83`).
                XCTAssertEqual(action, .unchanged, "the teardown window is open")
                XCTAssertEqual(lanes.log, ["start"])
                let tearing = await runner.state.isTearingDown
                XCTAssertTrue(tearing)
            case .idle:
                XCTAssertEqual(action, .stop)
                XCTAssertEqual(lanes.log, ["start", "stop"])
                // A second `didEnterBackground` asks for nothing: the lanes
                // are already paused.
                let twice = await runner.handle(.didEnterBackground)
                XCTAssertEqual(twice, .unchanged)
                XCTAssertEqual(lanes.log, ["start", "stop"])
            }
        }
    }

    func testACallThatEndsInTheBackgroundStopsTheLanesWhenTheTeardownWindowElapses() async throws {
        let source = FakeMonotonicSource()
        let pacer = RecordingPacer()
        // The window is waited out by letting exactly the asked-for time pass
        // on the fake clock, so the decision is the policy's arithmetic and
        // not a real ten-second sleep.
        pacer.onWait = { source.advance($0) }
        let lanes = FakeLanes()
        let runner = LifecycleRunner(target: lanes,
                                     policy: LifecyclePolicy(clock: source.clock),
                                     pacer: pacer)

        await runner.handle(.didBecomeActive)
        await runner.handle(.callChanged(.connected))
        let backgrounded = await runner.handle(.didEnterBackground)
        XCTAssertEqual(backgrounded, .unchanged)
        XCTAssertEqual(pacer.waits, [], "a live call arms no timer; it simply keeps the lanes")

        // The peer hangs up while the application is in the background.
        let ended = await runner.handle(.callChanged(.ended))
        XCTAssertEqual(ended, .unchanged)
        await runner.settle()

        XCTAssertEqual(pacer.waits, [LifecyclePolicy.callTeardown])
        XCTAssertEqual(LifecyclePolicy.callTeardown, 10 * MonotonicClock.nanosecondsPerSecond)
        XCTAssertEqual(lanes.log, ["start", "stop"], "the window ended in a pause")
        let running = await runner.state.isRunning
        XCTAssertFalse(running)

        // A call that comes back to the foreground inside its window arms
        // nothing at all: the lanes run because the application is open.
        let reopened = LifecycleRunner(target: FakeLanes(),
                                       policy: LifecyclePolicy(clock: source.clock),
                                       pacer: pacer)
        pacer.reset()
        await reopened.handle(.didBecomeActive)
        await reopened.handle(.callChanged(.connected))
        await reopened.handle(.callChanged(.ended))
        let foreground = await reopened.handle(.didBecomeActive)
        XCTAssertEqual(foreground, .unchanged)
        XCTAssertEqual(pacer.waits, [])
    }

    // MARK: - the task the lanes run in

    func testStartLaunchesTheLanesTaskAndStopCancelsIt() async throws {
        let lanes = FakeLanes()
        let launched = Latch()
        let cancelled = Latch()
        // `run()` stays parked the way a receive lane parked on a long poll
        // does, so that the cancellation is observable.
        lanes.parked = 60 * MonotonicClock.nanosecondsPerSecond
        lanes.onRun = { launched.signal() }
        lanes.onCancel = { cancelled.signal() }
        let runner = LifecycleRunner(target: lanes)

        await runner.handle(.didBecomeActive)
        let started = await launched.wait(for: 1)
        XCTAssertTrue(started, "start() is followed by run()")
        XCTAssertEqual(cancelled.value, 0)

        await runner.handle(.didEnterBackground)
        let freed = await cancelled.wait(for: 1)
        // `stop()` is what makes the answers worthless; the cancellation only
        // frees a lane parked on a socket sooner than its next guard would.
        XCTAssertTrue(freed, "the lanes task is cancelled when the application leaves")
        XCTAssertEqual(lanes.log, ["start", "stop"])
        XCTAssertEqual(lanes.runs, 1)
    }

    // MARK: - the order the platform posted them in

    func testEventsAreAppliedInThePostedOrder() async throws {
        let lanes = FakeLanes()
        let runner = LifecycleRunner(target: lanes)
        await runner.handle(.didBecomeActive)

        // Two posts with no await between them: if they were two tasks over an
        // actor, the application could end up on screen with the lanes paused
        // and nothing to say so.
        runner.post(.didEnterBackground)
        runner.post(.didBecomeActive)
        runner.finish()
        await runner.consume()

        XCTAssertEqual(lanes.log, ["start", "stop", "start"])
        XCTAssertEqual(lanes.generation.run, 3, "start, stop and start each moved the counter")
        let running = await runner.state.isRunning
        XCTAssertTrue(running)
        let phase = await runner.state.phase
        XCTAssertEqual(phase, .foreground)
    }

    // MARK: - nothing else ever starts a lane

    func testOnlyAForegroundNotificationStartsTheLanesAndNoSourceAsksForBackgroundDelivery() throws {
        // The three cases the platform can post at a client whose lanes are
        // stopped, plus the call states: none of them may start anything,
        // because this client has no background delivery at all.
        var policy = LifecyclePolicy()
        XCTAssertEqual(policy.decide(.willResignActive), .unchanged)
        XCTAssertEqual(policy.decide(.didEnterBackground), .unchanged)
        XCTAssertEqual(policy.decide(.callTeardownElapsed), .unchanged)
        for state in CallActivity.allCases {
            XCTAssertEqual(policy.decide(.callChanged(state)), .unchanged, state.rawValue)
        }
        XCTAssertFalse(policy.isRunning)
        XCTAssertEqual(policy.decide(.didBecomeActive), .start)

        // "No background delivery, no push" (`docs/clients/ios/README.md`) is
        // a property of the sources and not only of this table. Comment lines
        // are dropped before the scan, because the documentation names these
        // frameworks precisely to say that they are not used; what is checked
        // is that no line of code mentions one.
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let forbidden = ["BGTaskScheduler", "BGAppRefresh", "BGProcessingTask",
                         "PushKit", "PKPushRegistry", "registerForRemoteNotifications",
                         "UNUserNotificationCenter"]
        var scannedPackage = 0
        var scannedApplication = 0
        var subscriptions: Set<String> = []
        for (directory, isApplication) in [("ParanoidKit/Sources/ParanoidKit", false),
                                           ("App/ParanoID", true)] {
            let root = ios.appendingPathComponent(directory, isDirectory: true)
            let files = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
            for case let name as String in files where name.hasSuffix(".swift") {
                let text = try String(contentsOf: root.appendingPathComponent(name),
                                      encoding: .utf8)
                let source = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                if isApplication {
                    scannedApplication += 1
                    for token in ["didBecomeActiveNotification", "willResignActiveNotification",
                                  "didEnterBackgroundNotification"] where source.contains(token) {
                        subscriptions.insert(token)
                    }
                } else {
                    scannedPackage += 1
                    // The policy is pure logic: the platform reaches it only
                    // through the application's subscriptions.
                    XCTAssertFalse(source.contains("import UIKit"),
                                   "\(name) must not import UIKit")
                }
                for token in forbidden {
                    XCTAssertFalse(source.contains(token), "\(name) must not name \(token)")
                }
            }
        }

        XCTAssertGreaterThan(scannedPackage, 5, "the scan found the package sources")
        XCTAssertGreaterThan(scannedApplication, 0, "the scan found the application sources")
        XCTAssertEqual(subscriptions.count, 3, "the three notifications the application subscribes to")
    }

    // MARK: - the states a call passes through

    func testTheCallStatesThatKeepTheLanesAreAndroidsCallActive() {
        // `callActive = !state.equals("idle") && !state.equals("ended")`
        // (`TextEngine.java:86`), and the raw values are the strings the
        // controller publishes (`CallController.java:49,93,96,104,139,147,179,226,264`).
        XCTAssertEqual(CallActivity.allCases.filter(\.isActive).map(\.rawValue),
                       ["starting", "authorizing", "incoming", "connecting", "connected"])
        XCTAssertEqual(CallActivity.allCases.filter { !$0.isActive }.map(\.rawValue),
                       ["idle", "ended"])
        XCTAssertEqual(CallActivity(rawValue: "connected"), .connected)
        XCTAssertNil(CallActivity(rawValue: "draining"))
    }

    // MARK: - fixtures

    /// The real loop over a device with no identity: the owner mints the
    /// generations and the lanes find nothing to dial.
    private final class Live: @unchecked Sendable {
        let device: Device
        let transport: FakeTransport
        let owner: StateOwner
        let loop: RealtimeLoop

        init() throws {
            device = try Device(name: "lifecycle", trust: LifecycleTests.stand)
            transport = FakeTransport(server: try StandServer(credential: [:]))
            let signal = WakeSignal()
            let owner = StateOwner(client: device.client, hook: signal)
            self.owner = owner
            let flow = ProofFlow(owner: owner, transport: transport)
            loop = RealtimeLoop(owner: owner, flow: flow, transport: transport,
                                listener: SilentListener(), signal: signal)
        }
    }

    /// A listener that is asked nothing in these checks; the lanes never get
    /// as far as publishing anything, because there is no identity to talk
    /// about.
    private struct SilentListener: RealtimeListener {
        func changed(connected: Bool, status: String) {}
    }

    /// The two lanes, faked: it mints generations the way `StateOwner` does and
    /// records what the runner asked of it.
    ///
    /// `@unchecked Sendable` for the reason every fixture here is: the test
    /// reads the recording after the call it is about has returned, and the
    /// recording itself is kept under a lock because `run()` is a task of its
    /// own.
    private final class FakeLanes: LifecycleTarget, @unchecked Sendable {
        /// How long `run()` stays parked, so that a test can watch it be
        /// cancelled. Zero returns at once.
        var parked: UInt64 = 0
        /// Called from the lanes' task when it starts.
        var onRun: (@Sendable () -> Void)?
        /// Called from the lanes' task when it is cancelled.
        var onCancel: (@Sendable () -> Void)?

        private let lock = NSLock()
        private var enabled = false
        private var counter = Generation(run: 0)
        private var recorded: [String] = []
        private var launches = 0

        /// `start` and `stop`, in order.
        var log: [String] { lock.withLock { recorded } }
        /// The generation in force, whatever the phase.
        var generation: Generation { lock.withLock { counter } }
        /// How many times the lanes' task was launched.
        var runs: Int { lock.withLock { launches } }

        func start() async -> Generation {
            lock.withLock {
                if !enabled {
                    enabled = true
                    counter = counter.next
                }
                recorded.append("start")
                return counter
            }
        }

        func stop() async {
            lock.withLock {
                enabled = false
                counter = counter.next
                recorded.append("stop")
            }
        }

        func run() async {
            lock.withLock { launches += 1 }
            onRun?()
            guard parked > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: parked)
            } catch {
                onCancel?()
            }
        }
    }

    /// A counter two tasks can wait on, for the checks that observe the lanes'
    /// own task instead of driving it.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func signal() {
            lock.withLock { count += 1 }
        }

        /// Waits until the count reaches `target`, for at most a second.
        func wait(for target: Int) async -> Bool {
            for _ in 0..<200 {
                if value >= target { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return value >= target
        }
    }
}
