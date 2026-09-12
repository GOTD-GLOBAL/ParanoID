# WebRTC 150.7871.01 redistribution notices (iOS)

Exact pinned archive: `WebRTC.xcframework.zip` from the webrtc-sdk/Specs
GitHub release `150.7871.01` (tag commit
`08bbe32d4b96b23a619369748239018d5358b940`, published 2026-08-31), 69079305
bytes, SHA256
`03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa`.
The release's second asset, `WebRTC.xcframework.zip.shasum` (89 bytes), reads
`03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa  WebRTC.xcframework.zip`
and the `binaryTarget` checksum in the release's `Package.swift` is the same
value. It is quoted here once; the build never downloads it and verifies the
literal constants in `clients/ios/webrtc_dependency.py` instead.

Selected slices (xcframework `Info.plist` library identifiers) and the SHA256
of each `WebRTC.framework/WebRTC` binary:

- `ios-arm64` (12346720 bytes):
  `53c02ea619245badf789eea2dc5f0d0064e14a45c277598c0358ca45f74eec57`
- `ios-arm64_x86_64-simulator` (28860448 bytes):
  `b6a75fc3283c7cdf55a5e4a47fa274465c61fb294caa7d0cf5ab512d53b24dca`

The archive also carries `macos-arm64_x86_64`, `ios-arm64_x86_64-maccatalyst`,
`tvos-arm64`, `tvos-arm64-simulator`, `xros-arm64` and `xros-arm64-simulator`;
they are neither pinned nor extracted. The selected slices' framework
`Info.plist` records `MinimumOSVersion` 13.0, `DTXcodeBuild` 17A400 (Xcode
26.0), `DTSDKName` iphoneos26.0 / iphonesimulator26.0 and `CFBundleIdentifier`
`org.webrtc.WebRTC`; each ships a `PrivacyInfo.xcprivacy` with no collected
data types and no tracking.

Source commit `73cb8180f7258ee292878d6edd05177f41883962` (webrtc-sdk/webrtc)
is recorded in webrtc-build tag m150.7871.01 `build/VERSION`
(`WEBRTC_COMMIT=73cb8180…`, `WEBRTC_BUILD_VERSION=150.7871.01`) and is the
same source commit as the Android pin. LICENSE, NOTICE, PATENTS and AUTHORS
are byte-for-byte copies of `clients/android/licenses/webrtc-150.7871.01/`
(from that source commit). The archive's own `WebRTC.xcframework/LICENSE` is
byte-identical to LICENSE (SHA256
`ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482`).

Relation to the webrtc-build release: webrtc-build tag m150.7871.01 attaches
`LiveKitWebRTC.xcframework.zip` (69113091 bytes, SHA256
`75ba3e7d596bc1ebe35c22472491a3dab8ddc7d22a0281ccaaeb92f2b53fc659`), the
`LiveKit`-prefixed module produced by the same `build/apple/xcframework.sh`
from the same source commit. It has the same 979-member layout and identical
LICENSE bytes but different binary bytes (its `ios-arm64` binary is 12347232
bytes, SHA256
`960cea4374f4b65214992cbcd377ab63b243a90c9bf6898ff2ff8013d734f2fd`); it is a
repackaging under another module name, not the pinned artifact. The unprefixed
`WebRTC.xcframework.zip` is the same workflow's `apple` matrix output re-hosted
on the Specs release; that lineage is inferred from the identical structure
and from the checksum in the Specs `Package.swift`, not from a provenance
attestation. The release's `webrtc.tar.gz` is an Android build archive, not an
iOS input.

UPSTREAM-IOS-DEPENDENCY-NOTICES.txt: webrtc-build's Apple packaging copies
only the source-tree LICENSE into the xcframework and does not run upstream
`tools_webrtc/libs/generate_licenses.py`, so the pinned release publishes no
iOS-specific third-party notice bundle. The file is therefore a byte-for-byte
copy of the same-source-commit build-time notice text from the m150.7871.01
Android build archive
(`clients/android/licenses/webrtc-150.7871.01/BUILD-DEPENDENCY-NOTICES.txt`,
SHA256 `f851751c645ded1b53ac12ff643557c5a10f8c8db45637c0ba525e62739d68f3`),
retained conservatively as a superset: it also lists Android-only components
(android_sdk, ijar, jni_zero, kotlin_stdlib) that are not in the iOS binary,
and the exact per-platform link set of the iOS binary was not derived from a
GN dependency graph. Component names found in the `ios-arm64` binary strings
(boringssl, abseil, libvpx, libaom, dav1d, opus, libyuv, libsrtp, dcsctp,
g711, g722, zlib, libc++) are all covered by that text. Upstream notice bytes
are preserved under a .txt filename to avoid formatting license content for
repository Markdown checks.

No independent source rebuild or provenance-attestation verification was
performed. This records source/provenance, not independent legal approval.
