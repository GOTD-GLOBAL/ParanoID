// swift-tools-version: 6.0
// ParanoidKit: the Swift package of the ParanoID iOS client (RFC-0019,
// draft ADR-0013). Storage, TLS, transport, realtime, calls and the UI model
// live here; the shared Rust core is reached only through the C-ABI bridge
// (`clients/ios/bridge`) packaged as `Binaries/ParanoidCore.xcframework` by
// `clients/ios/build-core.sh` (git-ignored; build it before `swift build` or
// `swift test`). No third-party packages. The `service-bridge`, `core-bridge`
// and `tls-smoke` executables are added with their own pull-request steps.
import PackageDescription

let package = Package(
    name: "ParanoidKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ParanoidKit", targets: ["ParanoidKit"]),
        // libwebrtc for the iOS application and its test bundles only.
        .library(name: "WebRTC", targets: ["WebRTC"]),
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
        .testTarget(
            name: "ParanoidKitTests",
            dependencies: ["ParanoidKit"],
            path: "Tests/ParanoidKitTests"
        ),
    ]
)
