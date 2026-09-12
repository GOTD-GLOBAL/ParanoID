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

This records source/provenance, not independent legal approval.
