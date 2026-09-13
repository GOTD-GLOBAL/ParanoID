import Foundation
import ParanoidKit

/// Why a Debug launch has no server to talk to.
///
/// It is shown on the `NoStand` screen and nowhere else, and it never carries
/// the values it read: a realm and a pin are not secret, but a screen that
/// echoed launch arguments back would be one more place for them to end up in
/// a screenshot.
struct DebugFixtureProblem: Error, Equatable {
    let reason: String
}

/// The local stand a Debug build is launched against.
///
/// `python3 clients/ios/local_stand.py --print-descriptor` prints the pair
/// this reads — `-paranoid-realm <https origin>` and `-paranoid-pin <64 hex>`
/// — and they are the **only** two launch arguments this client understands.
/// Everything else on the command line belongs to the system, to Xcode or to
/// XCTest and is ignored.
///
/// Three rules hold here, and each of them is one line of code:
///
/// - **The same validation as Release.** The pair goes through
///   `ServiceTrust(realm:pin:)`, which is `PinnedTrustEvaluator.checkedRealm`
///   and `.checkedPin` — the port of `KeyClient.java:37-41` and
///   `PinnedTls.java:18-21`. A fixture is not a relaxed path: a realm that is
///   not a bare HTTPS origin and a pin that is not 64 lowercase hexadecimal
///   digits are refused here exactly as they would be in a shipped build.
/// - **Saved trust wins.** This type only reads the arguments;
///   `SelfServiceClient` compares them with what the snapshot already names
///   and refuses the launch with `savedTrustWins` if they disagree
///   (`KeyClient.java:17-20`). A stand can never be pointed at an identity
///   that was registered somewhere else.
/// - **Debug only.** The whole file compiles to nothing in a Release build:
///   `trust(arguments:)` answers `nil` there without looking at the command
///   line, so a shipped application starts from the compiled hosted default
///   (`ServiceTrust.hostedDefault()`, `KeyClient.java:9-10`) and from nothing
///   else.
///
/// A Debug build with neither this pair nor `-paranoid-allow-hosted` has no
/// realm at all: `ServiceTrust.hostedDefault()` answers `nil`, the application
/// shows `NoStand`, and it creates no identity and opens no connection. That
/// is what keeps a simulator run on the local stand and off the hosted alpha.
enum DebugFixture {
    #if DEBUG
    /// The HTTPS origin of the stand.
    static let realmArgument = "-paranoid-realm"
    /// The SHA-256 pin of that stand's public key, 64 lowercase hexadecimal
    /// digits.
    static let pinArgument = "-paranoid-pin"

    /// Reads the pair, or answers `nil` when this launch names no stand.
    ///
    /// - Throws: `DebugFixtureProblem` when one of the two is given without
    ///   the other, when a value is missing, or when the pair does not pass
    ///   the checks a Release build applies to its own.
    /// The environment variables that carry the same pair.
    ///
    /// `devicectl` launches a build on a physical phone without relaying launch
    /// arguments, so on a device the only channel that reaches the process is
    /// its environment. The names mirror the flags, the values pass the same
    /// checks, and an argument still wins when both are present.
    static let realmVariable = "PARANOID_REALM"

    /// See ``realmVariable``.
    static let pinVariable = "PARANOID_PIN"

    static func trust(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ServiceTrust? {
        let realm = value(of: realmArgument, in: arguments) ?? environment[realmVariable]
        let pin = value(of: pinArgument, in: arguments) ?? environment[pinVariable]
        switch (realm, pin) {
        case (nil, nil):
            return nil
        case (let realm?, let pin?):
            do {
                return try ServiceTrust(realm: realm, pin: pin)
            } catch {
                throw DebugFixtureProblem(reason: "\(realmArgument)/\(pinArgument): \(error)")
            }
        case (_?, nil):
            throw DebugFixtureProblem(reason: "\(pinArgument) <64 hex> is missing")
        case (nil, _?):
            throw DebugFixtureProblem(reason: "\(realmArgument) <https origin> is missing")
        }
    }

    /// The value that follows `name`, or `nil` when the flag is absent.
    ///
    /// A flag with nothing after it, or with another flag after it, counts as
    /// present with no value, which the caller reports rather than guesses at.
    private static func value(of name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return "" }
        return arguments[next]
    }
    #else
    /// A Release build takes no stand from the command line or the environment.
    static func trust(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> ServiceTrust? { nil }
    #endif
}
