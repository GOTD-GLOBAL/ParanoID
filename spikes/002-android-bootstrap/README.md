---
status: draft
owner: development
last_reviewed: 2026-09-07
---

# Android packaging bootstrap (experimental)

This standalone diagnostic APK verifies packaging, signing and launcher metadata.
It is NOT a messenger, an E2EE implementation or an accepted mobile stack. No
network permission, credentials, contacts, messages or server connection exists.
It displays the device model and Android version locally. Android API 26 or newer
is required. Production is untouched. RFC-0004 / PR #6 is proposal context only.

## Reproduce

Prerequisites: JDK with javac/keytool, Python 3, Android platform 35 and build-tools
35.0.0, installed in a user-owned SDK location. No Gradle or Kotlin dependency is
required for this packaging-only experiment; the activity is plain Java, not a
product language decision.

```bash
export ANDROID_SDK_ROOT=/path/to/android-sdk
bash spikes/002-android-bootstrap/build.sh
```

Output: `out/paranoid-bootstrap.apk` beneath this directory. A disposable debug
signing key is generated in ignored `out/` with a public test password. Never use
this key for production. Do not commit `out/` or distribute its keystore. Deleting
it changes the signing identity; uninstall the previous test app before installing
an APK signed by a replacement key. Never disable device security protections to
install an untrusted artifact.

## Evidence and limits

- Packaging test ran RED before implementation: APK did not exist.
- Build ran with javac, d8, aapt, zipalign and apksigner.
- GREEN: APK contains DEX and binary manifest, expected package/launcher metadata,
  no INTERNET permission, signature verifies (v2 and v3).
- Compilation emitted Java 8 compatibility deprecation warnings; no compile errors.
- No emulator or physical phone execution performed. Signing success is not proof
  of installation or runtime behavior on OPPO.
- UI lifecycle behavior has no instrumented test yet.
- Android E2EE library cross-compilation, Kotlin integration and messaging are NOT
  implemented by this bootstrap. The earlier JVM spike is separate evidence.

## Next check

Independent code review, then owner installation on the two OPPO phones and report
of exact models/Android versions and launch behavior. No production deployment.
