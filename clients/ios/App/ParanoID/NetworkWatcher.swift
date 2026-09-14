import Network

/// One report of the default path, reduced to the two facts a reconnect turns
/// on.
///
/// Android compares the `Network` the system hands its callback with the one
/// it saw last (`TextEngine.java:209`), and that comparison is an identity:
/// the same object is the same joined network, a different one means the
/// device is dialling over something else. The callback is
/// `registerDefaultNetworkCallback`, so it is only ever told about the network
/// that carries the traffic — an interface that merely became available is not
/// a report at all there.
///
/// `NWPath` offers no such identity, and `availableInterfaces` is not one
/// either: it is *every* interface available to the path, ordered by
/// preference, so one satisfied Wi-Fi path on a Mac reports
/// `["en0#14", "en0#14", "utun6#24"]` — a duplicate and a tunnel, over a route
/// that is plain Wi-Fi. On a phone those extra entries appear and disappear
/// under iCloud Private Relay, an on-demand VPN, Wi-Fi Calling and Personal
/// Hotspot without the default route moving once. Comparing the whole list
/// would call each of those a change of network; Android would not have been
/// told about any of them.
///
/// So what is kept is the **first** of those interfaces. That is the path's
/// own preferred interface by the system's ordering, and it is the closest
/// signal `NWPath` offers to "the network the traffic is on" — but it is a
/// proxy, not a proof: nothing here observes which interface a `URLSession`
/// socket actually bound to, and this type does not claim to. Two limits
/// follow and are stated rather than hidden. First, two different Wi-Fi
/// networks joined in turn on the same `en0` carry the same `name#index`, so
/// that change is invisible to this reducer, and a report that repeats the
/// same value is ignored even when it followed a switch of that kind; Android
/// would see a new `Network` there and this client will not, and it recovers
/// from that case only by the request's own timeout and backoff. Second, the
/// pairing of "first interface changed" with "the socket is dead" is inferred
/// from the platform's ordering and has been driven at this seam with stated
/// paths, not observed on a phone across a real Wi-Fi to cellular, VPN or
/// same-interface transition — `docs/clients/ios/verification.md` records
/// those as `NOT RUN` with the reason. What is proven is narrower and still
/// worth having: Wi-Fi giving way to cellular turns `en0#14` into `pdp_ip0#21`,
/// a VPN that takes the route makes its tunnel the preferred interface, and an
/// interface that is merely available never reaches this value.
///
/// It is a value with an initializer of its own so that the decision above it
/// can be driven without a network: a test states the path instead of waiting
/// for one.
struct NetworkPath: Equatable, Sendable {
    /// The path can carry traffic (`NWPath.Status.satisfied`).
    let isSatisfied: Bool
    /// The interface the path is dialling over, written `name#index`, and
    /// `nil` for a path that has none — an unsatisfied one, and the loopback
    /// case the platform is free to report.
    let carrier: String?

    init(isSatisfied: Bool, carrier: String?) {
        self.isSatisfied = isSatisfied
        self.carrier = carrier
    }

    /// Reads one report of the system monitor.
    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        carrier = path.availableInterfaces.first.map { "\($0.name)#\($0.index)" }
    }
}

/// The `changed` test inside Android's `onAvailable` (`TextEngine.java:209`),
/// as a value.
///
/// Three of its four answers are "no", and each of those is a decision:
///
/// - **The first path of the process is not a change.** Android's test is
///   `last != null && !last.equals(network)` and `last` is null until the
///   first callback, so the first network a device has never restarts
///   anything. Neither does it here, and the reason is the same one the
///   lifecycle table is built on: by the time this monitor reports, the scene
///   has become active and `LifecyclePolicy` has already minted the lanes'
///   generation (`.didBecomeActive` → `.start`). Restarting them a moment
///   later would throw away the `messages` read they are in the middle of —
///   the very read that makes a resumed client show its inbox at once.
/// - **The same path reported again is not a change.** A monitor reports on
///   every route change, an address renewal or a second interface merely
///   becoming available included, and none of those is the device dialling
///   over something else. Android is protected from them because its callback
///   is never invoked for them at all; here it is ``NetworkPath`` that has
///   already dropped everything but the interface the path dials over, and
///   this is the comparison of it.
/// - **A path that is not satisfied is not a change.** There is nothing to
///   reconnect over yet, so it only records that the network the lanes were
///   using is gone — Android's `onLost`, which clears `last` for exactly that
///   reason (`TextEngine.java:212`).
///
/// What follows a loss **is** a change, and this is the one place where the
/// mechanism has to differ from Android's rather than only its spelling.
/// There, `onLost` clears `last`, so the `onAvailable` after it computes
/// `changed == false` and only `startConnection()` runs (`:210`) — and on a
/// thread-based loop that is enough: `RealtimeLoop.start()` ends in
/// `lifecycle.notifyAll()` (`RealtimeLoop.java:57`) and a receive lane parked
/// in `lifecycle.wait()` leaves its backoff on the spot. Nothing here can be
/// notified. A `Task` suspended in a `URLSession` call or in `Backoff`'s sleep
/// leaves it when the request fails, when the sleep ends or when its
/// generation is superseded, and the first of those can take the request's
/// whole 30-second bound over an interface that no longer exists — 25 seconds
/// of «Подключение» with the server answering, which is the owner's report of
/// 2026-09-13. So connectivity coming back after none is reported as the
/// change it is, and `RealtimeLoop.restart()` then does what Android's
/// `notifyAll()` did.
///
/// "After none" includes a launch that found no network at all, which is why
/// the first-path rule counts *reports* and not satisfied ones: a client that
/// opened in a lift has already started its lanes, already failed and is
/// already parked in a `Backoff` step of up to sixteen seconds by the time the
/// network arrives. That is the reported defect in miniature, and the report
/// that says the network is here is exactly the one that has to free it.
struct NetworkChange {
    /// Whether any path at all has been reported, which is what makes
    /// Android's `last != null` true from the second report onwards.
    private var seen = false
    /// The last path reported, satisfied or not. Keeping the unsatisfied one
    /// rather than clearing to `nil` is Android's `onLost` (`:212`) with the
    /// loss written down instead of erased: it is what makes the path after it
    /// differ, on a platform where nothing can be notified.
    private var last: NetworkPath?

    /// Whether this report is a reconnect.
    mutating func changed(_ path: NetworkPath) -> Bool {
        let previous = last
        let first = !seen
        seen = true
        last = path
        guard path.isSatisfied else { return false }
        return !first && previous != path
    }
}

/// `NWPathMonitor` over the default path, with that decision in front of it:
/// the port of `TextEngine.watchNetwork()` (`TextEngine.java:200-215`).
///
/// Android registers a `registerDefaultNetworkCallback` on the connectivity
/// manager (`:206`) and hands every change to its worker; this registers the
/// system monitor on a queue of its own and hands every change it admits to
/// whatever the application gave it — `LifecycleRunner.post(.networkChanged)`
/// in the shipped client, so that the decision stays where every other
/// lifecycle decision is taken and no rule is duplicated here.
///
/// ## What it is not
///
/// It observes and does nothing else. The monitor opens no socket, sends
/// nothing and reaches no server; it is not a background mode and cannot
/// become one, because a path change does not wake a process that is not
/// running. A network that comes back while the application is away is
/// therefore seen when the application is — and `LifecyclePolicy` leaves
/// stopped lanes stopped in any case, which is the half of Android's
/// `onAvailable` that runs behind `if(realtime==null||broken)return` (`:210`).
///
/// ## Why a class and not a value
///
/// The monitor is a live registration with the system: it has to be started
/// once and cancelled with the scene that started it, which is what
/// `AppLifecycle` does with it alongside its three `NotificationCenter`
/// tokens. Android is no different — its callback lives as long as the
/// process, registered right after the loop exists (`TextEngine.java:122`).
final class NetworkWatcher: @unchecked Sendable {
    /// What one admitted change is worth. The application hands in
    /// `runner.post(.networkChanged)`; nothing here knows what that means.
    private let post: @Sendable () -> Void
    private let monitor = NWPathMonitor()
    /// The monitor's queue, and the only place ``change`` and ``started`` are
    /// ever touched. `@unchecked Sendable` is that discipline and nothing
    /// else, the way Android confines the same state to its `worker`
    /// (`TextEngine.java:210`).
    private let queue = DispatchQueue(label: "global.paranoid.network-path")
    private var change = NetworkChange()
    private var started = false

    /// - Parameter post: what a change is reported as. It is called on this
    ///   watcher's own queue, never on the main thread, so it must not block —
    ///   `LifecycleRunner.post(_:)` never does.
    init(post: @escaping @Sendable () -> Void) {
        self.post = post
    }

    /// Registers the monitor, once.
    ///
    /// A second call does nothing: `NWPathMonitor` may be started once, and a
    /// watcher that was cancelled with its scene is not restarted — the scene
    /// that follows builds its own, exactly as it builds its own
    /// subscriptions.
    func start() {
        let running = queue.sync { () -> Bool in
            let was = started
            started = true
            return was
        }
        guard !running else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            // Weak, because the monitor outlives nothing: it is cancelled in
            // `AppLifecycle.deinit`, and a report that arrives in between must
            // not keep a torn-down scene's watcher alive.
            self?.report(NetworkPath(path))
        }
        monitor.start(queue: queue)
    }

    /// Unregisters the monitor. It is symmetric with ``start()`` and is called
    /// from `AppLifecycle.deinit`, beside the removal of its three
    /// notification observers.
    func cancel() {
        monitor.cancel()
    }

    /// Applies one report.
    ///
    /// The system's own handler calls it, and so does a test that states a
    /// path instead of waiting for one — the seam that lets the whole rule be
    /// checked without a real interface going down. Either way the work is
    /// done on this watcher's queue, so the reports are applied in the order
    /// they arrived and ``change`` is read and written from one thread.
    func report(_ path: NetworkPath) {
        queue.async { [self] in
            guard change.changed(path) else { return }
            post()
        }
    }

    /// Waits until every report handed over so far has been applied.
    ///
    /// It is how a test observes that a path posted nothing; the application
    /// never needs it.
    func settle() {
        queue.sync {}
    }
}
