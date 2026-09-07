---
status: draft
owner: development
last_reviewed: 2026-09-07
---

# Android native crypto diagnostic (experimental)

Local-only ARM64 Android probe: two ephemeral synthetic Olm participants in ONE
process exchange test messages. Modified messages and replay are rejected.
No network permission, production identity, real user data or persistent storage.
This is NOT messaging between phones, a recovery implementation or an accepted
stack. It supplies feasibility evidence for REQ-CLIENT-001 / REQ-SEC-001 and the
RFC-0004 proposal in PR #6. ADR-0001 governs documentation; no crypto ADR accepted.

## Reproduce on Linux x86_64

Prerequisites: JDK with javac/keytool, Python 3 available as `python`, Rust/cargo,
`aarch64-linux-android` rustup target; user-owned Android SDK platform 35,
build-tools 35.0.0 and NDK 28.2.13676358.

```bash
export ANDROID_SDK_ROOT=/path/to/android-sdk
bash spikes/002-android-bootstrap/build.sh
```

Output: `out/paranoid-bootstrap.apk` in this directory. Supports ARM64 only,
Android API 26+. JNI entry returns a primitive integer and never dereferences JNI handles;
vodozemac is pinned to 0.10.0,
Cargo.lock included. No UniFFI/Kotlin integration or product language decision.

License texts for all locked third-party crates are bundled in APK assets by
`notices.py`. Missing matrix-pickle crate license files are sourced from upstream
commit `3eb007eae1ca87e3a3683c99a58fd19289abae52` (`LICENSE` at repository root)
and stored in `licenses/`. This records notices, not legal approval.

## Device check and rollback

Install over the earlier bootstrap only with the same disposable signing key.
Test key and build artifacts are ignored under `out/`; never commit the key or
use it for production. A fresh checkout generates a new key (public test password),
requiring uninstall of the old test app first. Uninstall `org.paranoid.bootstrap`
to roll back. No server or data migration exists.

Open the app and wait for PASS or FAIL. PASS means the native library loaded and
the local synthetic exchange, every single-byte mutation of one normal message,
and replay check passed ON THAT DEVICE. FAIL is not success; report the screenshot.
This does not authenticate remote contacts, verify server safety, or prove E2EE
of a real conversation. No physical-device result for this revision exists yet.

## Evidence and risks

- Rust RED: probe returned Not implemented; GREEN: real cryptographic probe passed
  on Linux. Decode-level rejection counts as rejection of malformed messages.
- Android ARM64 cross-compilation and packaging test passed; signing v2/v3 verified.
- Library linker requests 16 KB page alignment. Actual device loading is pending.
- Java JNI call runs off the UI thread; native errors return a failure code, no
  secrets. Panics are caught at the boundary, but fatal OS errors remain fatal.
- The public constant pickle key protects synthetic test snapshots in memory ONLY;
  never use this construction for application storage. No prekey authentication
  protocol exists: both accounts are generated together inside this process.
- Build has Java 8 deprecation warnings; there is no Android instrumentation test.
- Dependencies and their notices must be reviewed before production adoption;
  this experiment does not satisfy qualified human cryptographic review gates.
