// swift-tools-version: 6.0
// ParanoidKit: the Swift package of the ParanoID iOS client (RFC-0020,
// draft ADR-0014). Storage, TLS, transport, realtime, calls and the UI model
// live here; the shared Rust core is reached only through the C-ABI bridge
// (`clients/ios/bridge`) packaged as `Binaries/ParanoidCore.xcframework` by
// `clients/ios/build-core.sh` (git-ignored; build it before `swift build` or
// `swift test`). No third-party packages. The `tls-smoke` executable is the
// host-side handshake tool of `clients/ios/check-pinned-tls.py` and
// `service-bridge` the host-side client fixture of
// `clients/ios/test_clean_self_service.py`; the `core-bridge` executable is
// added with its own pull-request step.
import PackageDescription

let package = Package(
    name: "ParanoidKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ParanoidKit", targets: ["ParanoidKit"]),
        // libwebrtc for the iOS application and its test bundles only.
        .library(name: "WebRTC", targets: ["WebRTC"]),
        // Host-only checking tools, never linked into the application.
        .executable(name: "tls-smoke", targets: ["tls-smoke"]),
        .executable(name: "service-bridge", targets: ["service-bridge"]),
    ],
    targets: [
        // `paranoid_core_command` / `paranoid_core_free` from the Rust bridge
        // (`bridge/include/paranoid_core.h`, module `ParanoidCoreFFI`); the
        // macOS slice serves the host `swift test` run.
        .binaryTarget(name: "ParanoidCoreFFI", path: "Binaries/ParanoidCore.xcframework"),
        // Pinned libwebrtc 150.7871.01 (`clients/ios/webrtc_dependency.py`,
        // git-ignored, iOS device + simulator slices only). No target of this
        // package depends on it: `ParanoidKit` stays pure Swift over the core
        // so the macOS host `swift test` run keeps building, and the media
        // layer that imports `WebRTC` lives in the application and its tests.
        .binaryTarget(name: "WebRTC", path: "Binaries/WebRTC.xcframework"),
        .target(
            name: "ParanoidKit",
            dependencies: ["ParanoidCoreFFI"],
            path: "Sources/ParanoidKit"
        ),
        // Real loopback handshakes against the OpenSSL fixtures of
        // `clients/ios/check-pinned-tls.py`, through the shipped
        // `PinnedSessionDelegate` (`clients/android/test/TlsSmoke.java:36-46`).
        // It runs on this Mac only: the fixtures and the servers are the
        // Python script's, and no target of the application depends on it.
        .executableTarget(
            name: "tls-smoke",
            dependencies: ["ParanoidKit"],
            path: "Sources/tls-smoke"
        ),
        // The stdin/stdout client fixture of
        // `clients/ios/test_clean_self_service.py`, the counterpart of
        // `clients/android/test/CleanSelfServiceBridge.java`. It drives the
        // shipped `SelfServiceClient`, `SnapshotStore`, `ProofFlow` and
        // `RealtimeTransport` against the local stand of
        // `clients/ios/local_stand.py`; the application never links it.
        .executableTarget(
            name: "service-bridge",
            dependencies: ["ParanoidKit"],
            path: "Sources/service-bridge"
        ),
        .testTarget(
            name: "ParanoidKitTests",
            dependencies: ["ParanoidKit"],
            path: "Tests/ParanoidKitTests"
        ),
    ]
)
