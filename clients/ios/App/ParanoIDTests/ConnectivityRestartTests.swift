import Foundation
import ParanoidKit
import XCTest

@testable import ParanoID

/// The application half of the connectivity-change restart: which path is a
/// reconnect, what «Повторить подключение» does, and what the user is left
/// looking at while it happens.
///
/// The defect it answers is the owner's report of 2026-09-13 — the phone lost
/// its network, the hosted server kept answering from the Mac, the pinned key
/// never changed, and the client sat at «Нет подключения». Android had the
/// same defect and fixed it a day earlier by watching the default network
/// (`TextEngine.java:200-215`) and restarting the loop when it actually
/// changed (`RealtimeLoop.java:59-67`). The package half of that landed in
/// `StateOwner.restart()`, `RealtimeLoop.restart()` and the `.networkChanged`
/// row of `LifecyclePolicy`, and `LifecycleTests` drives the table; what is
/// checked here is everything above it that only the application has.
///
/// Nothing in this file opens a socket, reaches a server or waits for an
/// interface to go down: every path is stated, the lanes are a fake, and the
/// one real measurement — that no source of this client asks for background
/// delivery — is made by reading the sources themselves.
final class ConnectivityRestartTests: XCTestCase {
    // MARK: - which path is a change (`TextEngine.java:208-212`)

    /// The first path of the process restarts nothing. Android's test is
    /// `last != null && …`, and `last` is null until the first callback
    /// (`TextEngine.java:209`); here the lanes are already starting under a
    /// generation the scene minted a moment ago, and restarting them would
    /// throw away the `messages` read that generation exists for.
    func testTheFirstPathIsNotAChange() {
        var change = NetworkChange()
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
    }

    /// A monitor reports on every route change — an address renewal, a second
    /// interface merely becoming available — and none of those is the device
    /// dialling over something else. This is Android's identity comparison.
    func testTheSamePathReportedAgainIsNotAChange() {
        var change = NetworkChange()
        let wifi = NetworkPath(isSatisfied: true, carrier: "en0#14")
        XCTAssertFalse(change.changed(wifi))
        XCTAssertFalse(change.changed(wifi))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
    }

    /// An interface that becomes *available* while the route stays where it
    /// was is not a change of network, and this is the case the comparison
    /// exists to refuse.
    ///
    /// Cellular coming back as Wi-Fi stays the default — leaving a lift, a
    /// tunnel, a basement — adds `pdp_ip0` to `NWPath.availableInterfaces`
    /// without moving the route, and so do the `utun*` interfaces iCloud
    /// Private Relay, an on-demand VPN, Wi-Fi Calling and Personal Hotspot
    /// create and tear down. Android is never told about any of them:
    /// `registerDefaultNetworkCallback` reports the network that carries the
    /// traffic. Restarting on one would abandon an in-flight voice relay
    /// request for a route that did not change, which is the regression
    /// `TextEngine.java:184-187` records.
    func testASecondInterfaceMerelyBecomingAvailableIsNotAChange() {
        var change = NetworkChange()
        // What one satisfied Wi-Fi path really reports: a duplicate and a
        // tunnel beside the interface the route is actually on.
        XCTAssertEqual(NetworkPath(isSatisfied: true, carrier: "en0#14"),
                       NetworkPath(isSatisfied: true, carrier: "en0#14"))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
        // Cellular available, Wi-Fi still carrying; then a tunnel that is not
        // preferred either. The carrying interface is unchanged in both.
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
    }

    /// Wi-Fi lost with cellular taking over, and then a tunnel that does take
    /// the route: the two cases the owner's report is made of.
    func testADifferentCarryingInterfaceIsAChange() {
        var change = NetworkChange()
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
        XCTAssertTrue(change.changed(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21")))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21")))
        // A VPN that becomes the preferred interface is the route moving, and
        // it is the same reconnect for the same reason.
        XCTAssertTrue(change.changed(NetworkPath(isSatisfied: true, carrier: "utun6#24")))
    }

    /// `NWPath.availableInterfaces` is "every interface available to the path,
    /// in order of preference", so the first is the one a connection opened now
    /// would use — and it is the only one this value keeps.
    func testTheCarrierIsTheInterfaceThePathWouldDialOver() {
        // The shape the platform reports is checked where it is read, by the
        // value's own initializer; what is stated here is the rule that
        // initializer follows, because a path cannot be constructed by hand.
        let wifi = NetworkPath(isSatisfied: true, carrier: "en0#14")
        let cellular = NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21")
        XCTAssertNotEqual(wifi, cellular)
        XCTAssertNotEqual(wifi, NetworkPath(isSatisfied: false, carrier: "en0#14"))
        XCTAssertEqual(NetworkPath(isSatisfied: false, carrier: nil),
                       NetworkPath(isSatisfied: false, carrier: nil))
    }

    /// A path that cannot carry traffic is nothing to reconnect over, so it
    /// only records the loss — Android's `onLost`, which clears `last`
    /// (`TextEngine.java:212`). What comes back after it is the change,
    /// because on this platform nothing else frees a lane parked in a long
    /// poll or in a `Backoff` sleep.
    func testAPathThatIsNotSatisfiedIsNotAChangeAndTheOneAfterItIs() {
        var change = NetworkChange()
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: false, carrier: nil)))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: false, carrier: nil)))
        XCTAssertTrue(change.changed(NetworkPath(isSatisfied: true, carrier: "en0#14")))
    }

    /// A device that launched in a lift: the loss is the first report, and the
    /// network that arrives after it is a change.
    ///
    /// Nothing about that client is waiting quietly — `.didBecomeActive`
    /// started its lanes, they failed, and they are parked in a `Backoff` step
    /// of up to sixteen seconds. Android frees exactly this case with the half
    /// of `onAvailable` that always runs: `startConnection()` →
    /// `realtime.start()` → `lifecycle.notifyAll()` (`RealtimeLoop.java:57`)
    /// leaves a parked `lifecycle.wait()` even when `changed` is false. There
    /// is no notifying here, so the change is what has to carry it.
    func testAnArrivalAfterALaunchWithNoNetworkIsAChange() {
        var change = NetworkChange()
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: false, carrier: nil)))
        XCTAssertTrue(change.changed(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21")))
        XCTAssertFalse(change.changed(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21")))
    }

    // MARK: - the watcher posts what the decision admits, and only that

    func testTheWatcherPostsOneEventForAChangeAndNothingForAFirstPathOrALoss() {
        let posts = Counter()
        let watcher = NetworkWatcher { posts.signal() }

        watcher.report(NetworkPath(isSatisfied: true, carrier: "en0#14"))
        watcher.settle()
        XCTAssertEqual(posts.value, 0, "the first path is not a change")

        watcher.report(NetworkPath(isSatisfied: true, carrier: "en0#14"))
        watcher.settle()
        XCTAssertEqual(posts.value, 0, "the same path again is not a change")

        watcher.report(NetworkPath(isSatisfied: false, carrier: nil))
        watcher.settle()
        XCTAssertEqual(posts.value, 0, "there is nothing to reconnect over yet")

        watcher.report(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21"))
        watcher.settle()
        XCTAssertEqual(posts.value, 1, "one event, for one change")

        // One change, one event: a second report of the same path adds none,
        // so a monitor that is chatty cannot restart the lanes in a loop.
        watcher.report(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21"))
        watcher.report(NetworkPath(isSatisfied: true, carrier: "pdp_ip0#21"))
        watcher.settle()
        XCTAssertEqual(posts.value, 1)

        watcher.cancel()
    }

    // MARK: - a start and a restart say so, and nothing else does

    @MainActor
    func testAStartAndARestartAnnounceAndStopAndRunDoNot() async {
        let model = AppModel()
        let lanes = FakeLanes()
        let announced = AnnouncedLanes(lanes: lanes, model: model)

        model.published(connected: true, status: RealtimeStatus.connected)
        XCTAssertTrue(model.isConnected)

        _ = await announced.start()
        XCTAssertEqual(model.lastStatus, Strings.Status.connecting,
                       "a start says the client is connecting")
        // The lanes had been stopped, which is where Android clears the flag
        // (`stopConnection()`, `TextEngine.java:198`).
        XCTAssertFalse(model.isConnected)

        // A page came back: the lanes are the only thing that may say so.
        model.published(connected: true, status: RealtimeStatus.connected)
        await announced.restart()
        XCTAssertEqual(model.lastStatus, Strings.Status.connecting, "and so does a restart")
        // But a restart never stopped anything, so it never claims the client
        // is offline: Android's `restart()` leaves `connected` alone too, and
        // that flag is the gate an outgoing call waits on.
        XCTAssertTrue(model.isConnected)

        // Neither of the other two publishes anything: a pause is not a
        // connection attempt, and running the lanes is them doing their work.
        model.published(connected: true, status: RealtimeStatus.connected)
        await announced.stop()
        await announced.run(under: lanes.generation)
        XCTAssertEqual(model.lastStatus, RealtimeStatus.connected, "stop() and run() publish nothing")
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(lanes.log, ["start", "restart", "stop", "run"])
    }

    /// The announcement is finished before the lanes are asked to connect, so
    /// a publication the lanes make afterwards is always afterwards.
    ///
    /// Two unstructured `Task`s have no order on the main actor. If this one
    /// were one, a page delivered immediately after a restart could be
    /// overwritten by the announcement created before it, and the sheet would
    /// read «Подключение» for a connected client until the next long poll
    /// returned — the same class of stale caption this branch exists to
    /// remove, inverted.
    @MainActor
    func testTheAnnouncementIsOrderedBeforeWhateverTheLanesPublishNext() async {
        let model = AppModel()
        let lanes = FakeLanes()
        // The fake publishes from inside `restart()`, which is where the real
        // lanes' first page can land: after the announcement was asked for.
        lanes.onRestart = { [weak model] in
            Task { @MainActor in
                model?.published(connected: true, status: RealtimeStatus.connected)
            }
        }
        let announced = AnnouncedLanes(lanes: lanes, model: model)
        _ = await announced.start()

        await announced.restart()
        for _ in 0..<200 where model.lastStatus != RealtimeStatus.connected {
            await Task.yield()
        }

        XCTAssertEqual(model.lastStatus, RealtimeStatus.connected,
                       "the lanes' publication is the last word, not the announcement")
        XCTAssertTrue(model.isConnected)
    }

    /// The decorator is a decorator: it forwards every member and swallows
    /// none of them, so the lanes are asked for exactly what the runner
    /// decided.
    @MainActor
    func testEveryMemberReachesTheLanes() async {
        let model = AppModel()
        let lanes = FakeLanes()
        let announced = AnnouncedLanes(lanes: lanes, model: model)

        let generation = await announced.start()
        XCTAssertEqual(generation, lanes.generation)
        let restarted = await announced.restart()
        XCTAssertEqual(restarted, lanes.generation)
        XCTAssertEqual(lanes.generation.run, generation.run + 1,
                       "the restart moved the counter, so the answer in flight is worthless")
        await announced.stop()
        XCTAssertEqual(lanes.log, ["start", "restart", "stop"])
    }

    // MARK: - «Повторить подключение»

    /// The button takes Android's harmless half whenever a restart would cost
    /// something, and the restart only when nothing is in flight to lose.
    ///
    /// `pushWake()` is the rule, verbatim: a hint "must never restart a live
    /// loop: restart() bumps the generation and abandons an in-flight voice
    /// relay request/long-poll, which froze call setup in v20/v21 (owner
    /// report 2026-09-12)", so `if(callActive||callDraining||connected)` takes
    /// `nudge()` and returns (`TextEngine.java:184-187`). Only the path
    /// monitor's own report is exempt, on both platforms, because there the
    /// route really did change.
    func testTheRetryButtonRestartsOnlyWhenThereIsNothingToAbandon() throws {
        let sources = try Self.applicationSources()
        let model = try XCTUnwrap(sources["AppModel.swift"])
        // The slice is taken from the sources with their comments already
        // dropped, so every marker is code: the next member after the button
        // is the bottom banner's.
        let start = try XCTUnwrap(model.range(of: "    func reconnect() {"))
        let end = try XCTUnwrap(model.range(of: "    func showNotice(_ text: String) {"))
        let reconnect = String(model[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(reconnect.contains("if isCallActive || isConnected {"),
                      "Android's gate, over the state this object has for it")
        XCTAssertTrue(reconnect.contains("runtime?.loop.wake()"),
                      "a call or a working connection gets the kick and nothing else")
        XCTAssertTrue(reconnect.contains("runtime?.runner.post(.networkChanged)"),
                      "and everything else gets the restart the user asked for")
        // The wake is the guarded branch and the restart is the other one: a
        // wake alone would free no parked receive lane, which is the defect.
        let gate = try XCTUnwrap(reconnect.range(of: "if isCallActive || isConnected {"))
        let kick = try XCTUnwrap(reconnect.range(of: "runtime?.loop.wake()"))
        let restart = try XCTUnwrap(reconnect.range(of: "runtime?.runner.post(.networkChanged)"))
        XCTAssertTrue(gate.upperBound < kick.lowerBound)
        XCTAssertTrue(kick.upperBound < restart.lowerBound)
    }

    // MARK: - the status line stops being stale

    /// The two stale lines of the owner's report, and what a reconnect leaves
    /// in their place.
    @MainActor
    func testAReconnectLeavesNeitherAGreenLineNorAStaleFailure() {
        let model = AppModel()

        // Stale green: the connection ended while the application was away,
        // and `stop()`/`start()` publish nothing, so this is what the sheet
        // would still be showing. Only the announcement that follows a pause
        // clears it, because only then were the lanes actually down.
        model.published(connected: true, status: RealtimeStatus.connected)
        model.publishConnecting(resumed: true)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.lastStatus, Strings.Status.connecting)

        // Stale failure: a lane that gave up over an interface the device no
        // longer has published «Нет подключения. Сообщения сохранены в
        // очереди.», and the sheet's «Последнее событие» row keeps it.
        model.published(connected: false, status: RealtimeStatus.offline)
        XCTAssertEqual(model.lastStatus, RealtimeStatus.offline)
        model.publishConnecting(resumed: false)
        XCTAssertNotEqual(model.lastStatus, RealtimeStatus.offline)
        XCTAssertEqual(model.lastStatus, Strings.Status.connecting)

        // And no green state is invented on the way: only a delivered page or
        // an accepted envelope may set that flag, which is Android's rule too
        // (`RealtimeLoop.java:237,261-263,280`).
        XCTAssertFalse(model.isConnected)

        // Nor is a green one taken away by a restart. `isConnected` is the gate
        // `waitForCallConnection()` spins on for the whole `callIntentWindow`,
        // so a route that reported twice would otherwise refuse an outgoing
        // call while its pages were arriving normally — and `CallController`,
        // which hears the flag only through `Listener.changed`, would disagree
        // with this object about it.
        model.published(connected: true, status: RealtimeStatus.connected)
        model.publishConnecting(resumed: false)
        model.publishConnecting(resumed: false)
        XCTAssertTrue(model.isConnected)
        // A registered client with that flag still reads «Сервер подключён»
        // under the title, which is Android's order too: `connected` is tested
        // before the last published message (`MainActivity.java:682`).
        let live = ClientView(hasIdentity: true, isActive: true, isConfigured: true)
        XCTAssertEqual(AppModel.statusLine(broken: false, view: live,
                                           connected: model.isConnected,
                                           lastStatus: model.lastStatus),
                       Strings.Status.connected)
    }

    /// What those two publications become under the title
    /// (`MainActivity.java:681-684`).
    func testTheLineAUserIsLeftWithIsConnectingAndNeverConnected() {
        let live = ClientView(hasIdentity: true, isActive: true, isConfigured: true)

        XCTAssertEqual(AppModel.statusLine(broken: false, view: live, connected: true,
                                           lastStatus: RealtimeStatus.connected),
                       Strings.Status.connected)
        // The inputs `publishConnecting(resumed:)` leaves behind, whichever of
        // the two stale states it was called in.
        XCTAssertEqual(AppModel.statusLine(broken: false, view: live, connected: false,
                                           lastStatus: Strings.Status.connecting),
                       Strings.Status.connecting)
        // The rows a reconnect must not disturb: a frozen client says so, a
        // device with no identity says so, and refused events still win over
        // everything (`MainActivity.java:683`).
        XCTAssertEqual(AppModel.statusLine(broken: true, view: live, connected: false,
                                           lastStatus: Strings.Status.connecting),
                       Strings.Status.frozen)
        XCTAssertEqual(AppModel.statusLine(broken: false, view: ClientView(), connected: false,
                                           lastStatus: Strings.Status.connecting),
                       Strings.Status.alpha)
        let refused = ClientView(hasIdentity: true, isActive: true, isConfigured: true,
                                 rejectedCount: 2)
        XCTAssertEqual(AppModel.statusLine(broken: false, view: refused, connected: false,
                                           lastStatus: Strings.Status.connecting),
                       Strings.Status.rejected)
    }

    // MARK: - nothing else starts a lane, and nothing new delivers in the background

    /// The scan `LifecycleTests` makes over both trees, narrowed to the
    /// application and extended to the watcher this branch adds.
    ///
    /// A path monitor is the kind of thing that grows a background mode next
    /// to it — a `BGAppRefreshTask` "to check while we are away", a PushKit
    /// registration "to be woken when the network is back" — and this client
    /// has none and must keep none: incoming messages and calls arrive while
    /// the application is open (`docs/clients/ios/README.md`), and that
    /// sentence is on the connection screen. So the sources are read: no
    /// framework of that kind is named anywhere, the monitor exists exactly
    /// once and is started from exactly one place, and `UIBackgroundModes` is
    /// still the one entry a live call needs.
    func testTheWatcherIsTheOnlyPathMonitorAndNoSourceAsksForBackgroundDelivery() throws {
        let sources = try Self.applicationSources()
        XCTAssertGreaterThan(sources.count, 5, "the scan found the application sources")

        let forbidden = ["BGTaskScheduler", "BGAppRefresh", "BGProcessingTask",
                         "PushKit", "PKPushRegistry", "registerForRemoteNotifications",
                         "UNUserNotificationCenter"]
        for (name, source) in sources {
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(name) must not name \(token)")
            }
        }

        // One monitor, in the one file that is allowed to know the framework
        // exists, started once — a second `start(queue:)` on an `NWPathMonitor`
        // is not allowed by the platform either.
        let monitors = sources.filter { $0.value.contains("NWPathMonitor") }.keys.sorted()
        XCTAssertEqual(monitors, ["NetworkWatcher.swift"])
        let imports = sources.filter { $0.value.contains("import Network") }.keys.sorted()
        XCTAssertEqual(imports, ["NetworkWatcher.swift"])
        XCTAssertEqual(Self.occurrences(of: "monitor.start(queue:", in: sources), 1)
        XCTAssertEqual(Self.occurrences(of: "NetworkWatcher {", in: sources), 1)
        XCTAssertEqual(Self.occurrences(of: "network.cancel()", in: sources), 1,
                       "the watcher is cancelled with the scene that started it")
        let lifecycle = try XCTUnwrap(sources["AppLifecycle.swift"])
        XCTAssertTrue(lifecycle.contains("network = NetworkWatcher { runner.post(.networkChanged) }"))
        XCTAssertTrue(lifecycle.contains("network.start()"))
        XCTAssertTrue(lifecycle.contains("network.cancel()"))

        // The two things that ask for a restart, and nothing else: the monitor
        // above and the button, whose own gate is checked separately.
        XCTAssertEqual(Self.occurrences(of: "post(.networkChanged)", in: sources), 2)

        // The one background mode, unchanged (`test_ui_contract.py` checks the
        // same key; a path monitor is not a delivery path).
        let plist = Self.root.appendingPathComponent("App/ParanoID/Info.plist")
        let raw = try Data(contentsOf: plist)
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: raw, format: nil) as? [String: Any])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio"])
    }

    // MARK: - fixtures

    /// `.../clients/ios`, from this file's own location — the way
    /// `SdpCompatibilityTests` finds the tree it writes its evidence into.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every application source by file name, with the comment lines dropped:
    /// documentation names a framework precisely to say it is not used, and
    /// what is checked is that no line of code mentions one. It is the scan of
    /// `LifecycleTests.testOnlyAForegroundNotificationStartsTheLanes…`, whose
    /// package half stays where it is.
    private static func applicationSources() throws -> [String: String] {
        let app = root.appendingPathComponent("App/ParanoID", isDirectory: true)
        let names = try XCTUnwrap(FileManager.default.enumerator(atPath: app.path))
        var found: [String: String] = [:]
        for case let name as String in names where name.hasSuffix(".swift") {
            let text = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
            found[(name as NSString).lastPathComponent] = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        return found
    }

    private static func occurrences(of needle: String, in sources: [String: String]) -> Int {
        sources.values.reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
    }

    /// A count two threads may touch: the watcher posts on its own queue.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func signal() {
            lock.withLock { count += 1 }
        }
    }

    /// The lanes, faked exactly as `LifecycleTests` fakes them: the counter
    /// moves the way `StateOwner` moves it, and what the runner asked for is
    /// recorded in order.
    ///
    /// `@unchecked Sendable` for the reason that fixture is: the recording is
    /// read after the call it is about has returned, and it is kept under a
    /// lock because the lanes' task is a task of its own.
    private final class FakeLanes: LifecycleTarget, @unchecked Sendable {
        /// Run from inside `restart()`, where the real lanes' next page can
        /// land: after the announcement was asked for.
        var onRestart: (@Sendable () -> Void)?

        private let lock = NSLock()
        private var enabled = false
        private var counter = Generation(run: 0)
        private var recorded: [String] = []

        var log: [String] { lock.withLock { recorded } }
        var generation: Generation { lock.withLock { counter } }

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

        /// `StateOwner.restart()`: the counter moves and `enabled` is left as
        /// it is, so a stopped fake refuses the way the owner does
        /// (`RealtimeLoop.java:62`, `if(closed||!enabled)return`).
        @discardableResult
        func restart() async -> Generation? {
            let minted: Generation? = lock.withLock {
                guard enabled else { return nil }
                counter = counter.next
                recorded.append("restart")
                return counter
            }
            onRestart?()
            return minted
        }

        func run(under generation: Generation) async {
            lock.withLock { recorded.append("run") }
        }
    }
}
