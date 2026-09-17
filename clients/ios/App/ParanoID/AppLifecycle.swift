import ParanoidKit
import UIKit

/// The one place where UIKit meets the realtime lanes.
///
/// It holds no rule of its own: every notification is handed to
/// `LifecycleRunner`, which owns the `LifecyclePolicy` that decides whether
/// the lanes start, stop or are left exactly as they are. The policy lives in
/// the package and imports no UIKit, so the whole foreground rule of this
/// client — "incoming messages and calls arrive only while the application is
/// open" (`docs/clients/ios/README.md`), with a live call as its one exception
/// — is checked on the host by `LifecycleTests` rather than on a device.
///
/// The three posts are subscribed to, not two: `willResignActive` is what
/// tells the runner that a system permission alert or the Control Center is
/// covering the application, so that the `didBecomeActive` which follows it is
/// not mistaken for a return from the background. Only
/// `didEnterBackground` is a pause.
///
/// `post(_:)` is synchronous and ordered, and one task drains the queue, which
/// is the point: `didEnterBackground` and `didBecomeActive` applied in the
/// wrong order would leave the application on screen with its lanes paused
/// and nothing to say so.
///
/// The fourth source is not a UIKit post at all: `NetworkWatcher` reports that
/// the default path changed, which is Android's fourth one too — its
/// `registerDefaultNetworkCallback` sits beside the activity's own callbacks
/// and hands its verdict to the same worker (`TextEngine.java:122,200-215`).
/// It is wired here for the reason the three posts are: this is the only place
/// where a platform fact becomes a `LifecycleEvent`, and the rule about what
/// to do with one lives in the package, where a test can drive it.
///
/// There is nothing else here — no `BGTaskScheduler`, no `BGAppRefreshTask`,
/// no `PushKit` registration and no remote notifications — because this client
/// has no background delivery at all. The path monitor is not one either: it
/// observes and never wakes a process, and a change seen while the lanes are
/// stopped is decided as `.unchanged` (`LifecyclePolicy`).
final class AppLifecycle {
    private let runner: LifecycleRunner
    private let center: NotificationCenter
    private let pump: Task<Void, Never>
    private let network: NetworkWatcher
    private var tokens: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - runner: the policy over the realtime loop.
    ///   - center: the notification centre, `default` in the application.
    init(runner: LifecycleRunner, center: NotificationCenter = .default) {
        self.runner = runner
        self.center = center
        self.pump = Task { await runner.consume() }
        // The handlers capture the runner and nothing else: `post(_:)` is
        // `nonisolated` and never suspends, so a notification is handed over
        // on the thread UIKit posted it on, in that order.
        tokens = [
            Self.observe(UIApplication.didBecomeActiveNotification,
                         as: .didBecomeActive, on: center, runner: runner),
            Self.observe(UIApplication.willResignActiveNotification,
                         as: .willResignActive, on: center, runner: runner),
            Self.observe(UIApplication.didEnterBackgroundNotification,
                         as: .didEnterBackground, on: center, runner: runner),
        ]
        // The monitor is registered last and only here, so it cannot report a
        // path before there are lanes to report it to: Android starts its own
        // callback in the same position, right after the loop it protects
        // exists (`TextEngine.java:117-122`). The watcher's own first-path
        // rule then keeps the report that arrives immediately afterwards from
        // restarting a generation that was minted a moment ago.
        network = NetworkWatcher { runner.post(.networkChanged) }
        network.start()
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
        // Symmetric with `init`: every source this object subscribed to is
        // released before the queue it fed is closed, so nothing is posted
        // into a runner that is being torn down.
        network.cancel()
        runner.finish()
        pump.cancel()
    }

    private static func observe(_ name: Notification.Name,
                                as event: LifecycleEvent,
                                on center: NotificationCenter,
                                runner: LifecycleRunner) -> any NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            runner.post(event)
        }
    }
}
