# Client notice sources (iOS)

`webrtc-150.7871.01/` carries the redistribution notices for the pinned
`WebRTC.xcframework` binary (webrtc-sdk/Specs release 150.7871.01), built from
the same upstream source commit as the Android client. LICENSE, NOTICE,
PATENTS and AUTHORS are byte-for-byte copies of
`clients/android/licenses/webrtc-150.7871.01/`.
UPSTREAM-IOS-DEPENDENCY-NOTICES.txt is the same-commit build-time third-party
notice text, retained conservatively because the pinned release publishes no
iOS-specific bundle; PROVENANCE.md records the exact archive, slice and notice
hashes and the limits of what was verified.

`clients/ios/webrtc_dependency.py` pins the archive and slice hashes and
re-extracts only the iOS device and simulator slices on every build. Every
file in this directory is meant to be included in the app's third-party
notices bundle. Rust crate notices are collected from the locked dependency
graph at build time; a crate without packaged license text gets a pinned copy
here with a note in this file.

`jni-sys-macros-LICENSE-APACHE` and `jni-sys-macros-LICENSE-MIT` are the
pinned copies for the one crate in the iOS graph whose published package
carries no license text. They are byte-for-byte copies of
`clients/android/licenses/jni-sys-macros-LICENSE-{APACHE,MIT}`, which come
from the root of jni-rs/jni-sys at commit
`64d77b7a5f119d7b55b4e2c169a4668067ff59e6`, the crate's own VCS metadata.
`jni` itself stays in the graph — the shared core depends on it
unconditionally — so its notices ship in the iOS bundle too. The
`matrix-pickle` and `matrix-pickle-derive` notices reuse the existing pinned
copy at `spikes/002-android-bootstrap/licenses/matrix-pickle-LICENSE` rather
than a second copy here.

`clients/ios/notices.py` walks the locked graph from `bridge/Cargo.toml`
filtered for `aarch64-apple-ios`, so it requires license texts only for crates
that actually link into the app, and fails the build with `Missing license
text: <crate> <version>` when one has none. It has no ZXing, org.json or
Firebase block: this client scans QR with Vision, parses JSON in Rust and has
no push gateway.

This records source/provenance, not independent legal approval.
