---
status: accepted
owner: maintainers
last_reviewed: 2026-08-11
---

# Run the mobile identity conformance checks

## Prerequisites

- JDK 21;
- an Android SDK containing platform 36 and build tools 36.0.0 for Android host
  checks;
- macOS with supported Xcode tooling for iOS simulator checks.

Use the checked-in Gradle wrapper. Its Gradle 9.5.1 distribution checksum is
pinned in `gradle/wrapper/gradle-wrapper.properties`. Do not replace the wrapper
binary or remove checksum verification without an explained supply-chain review.

## Verify JVM and Android

Run from the repository root on Windows:

```powershell
.\gradlew.bat `
  :clients:shared:identity-conformance:jvmTest `
  :clients:shared:identity-conformance:testAndroidHostTest `
  --no-daemon
```

Run from the repository root on Linux or macOS:

```shell
./gradlew \
  :clients:shared:identity-conformance:jvmTest \
  :clients:shared:identity-conformance:testAndroidHostTest \
  --no-daemon
```

## Verify the iOS simulator

Run on macOS:

```shell
./gradlew \
  :clients:shared:identity-conformance:iosSimulatorArm64Test \
  --no-daemon
```

Windows cannot execute the iOS simulator task. A disabled-task warning on
Windows is expected and is not iOS test evidence.

## Interpret a vector change

The selected Kotlin result must equal the `hkdf_sha512_v1` entry in
`specs/protocol/identity/key-derivation-experiment-v1.json`. A mismatch is a
failed conformance check, not a fixture update request.

If a deliberate research change should alter the fixture, update the Rust
generator, Rust tests, experiment records, threat analysis, and every platform
test together. Do not generate, print, or commit a mnemonic, seed, private key,
or signature from a real account.
