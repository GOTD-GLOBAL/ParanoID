import ParanoidKit
import XCTest

/// Smoke test of the C-ABI bridge inside the application process on the iOS
/// simulator: the `create_identity` -> `upgrade_v2` path the Android client
/// takes before its first network request (`SelfServiceClient.java:80-84`),
/// executed by the `ios-arm64-simulator` slice of `ParanoidCore.xcframework`
/// linked through `ParanoidKit`. The host-side `CoreBridgeTests` cover the
/// error mapping; this test proves the simulator slice links and runs.
///
/// Snapshots hold private keys: only `state.version` is printed, never the
/// state text.
final class BridgeSmokeTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)
    private static let createIdentity =
        #"{"op":"create_identity","realm":"\#(realm)","pin":"\#(pin)"}"#
    private static let upgradeV2 = #"{"op":"upgrade_v2"}"#

    #if targetEnvironment(simulator)
    private static let environment = "simulator"
    #else
    private static let environment = "device"
    #endif

    func testCreateIdentityInSimulatorReachesStateVersion3() throws {
        let created = try CoreBridge.command(state: "", request: Self.createIdentity)
        XCTAssertEqual(created.stateVersion, 0)
        XCTAssertNil(created.object["error"])

        let upgraded = try CoreBridge.command(state: try XCTUnwrap(created.state), request: Self.upgradeV2)
        let version = try XCTUnwrap(upgraded.stateVersion)
        XCTAssertEqual(version, 3)
        let publicBundle = try XCTUnwrap(upgraded.object["public"] as? [String: Any])
        XCTAssertEqual(publicBundle["realm"] as? String, Self.realm)

        // One line for the xcodebuild log; the host process is the ParanoID app.
        print("BridgeSmokeTests: state.version=\(version) environment=\(Self.environment) "
            + "host=\(Bundle.main.bundleIdentifier ?? "-")")
    }

    func testRunsInsideTheApplicationBundle() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "global.paranoid.messenger")
        XCTAssertEqual(Self.environment, "simulator", "this pull-request step runs on the simulator only")
    }
}
