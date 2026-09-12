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
/// There is nothing else here — no `BGTaskScheduler`, no `BGAppRefreshTask`,
/// no `PushKit` registration and no remote notifications — because this client
/// has no background delivery at all.
final class AppLifecycle {
    private let runner: LifecycleRunner
    private let center: NotificationCenter
    private let pump: Task<Void, Never>
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
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
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
