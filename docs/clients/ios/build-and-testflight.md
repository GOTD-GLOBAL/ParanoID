---
status: draft
owner: ios
last_reviewed: 2026-09-13
---

# iOS client: build, signing and the TestFlight gates

How the candidate client of [REQ-CLIENT-001](../../product/requirements.md) is
built, what each gate refuses, and which steps are owner decisions rather than
build steps. Proposed in [RFC-0021](../../rfcs/0021-ios-client.md), recorded as
[proposed ADR-0014](../../decisions/0014-ios-client.md). The command-level
reference is [`clients/ios/README.md`](../../../clients/ios/README.md); what has
been run is [verification.md](verification.md).

## Pinned toolchain

`clients/ios/toolchain.json` is the single source of the pins: Xcode 26.6
(17F113), iOS SDK 26.5, Swift 6.3.3, Rust 1.98.1 with the `aarch64-apple-ios`,
`aarch64-apple-ios-sim` and `aarch64-apple-darwin` targets, iOS deployment
target 17.0, WebRTC `150.7871.01`, PostgreSQL 16 for the local stand and the
JDK for the Java host side. `test_toolchain.py` refuses a mismatch in the tool
versions it covers (`--no-xcode` skips Xcode, the SDK, Swift and PostgreSQL);
the JDK entry is recorded for the Java host side, which is what reads it, not
by this check. Rust commands run through `toolchain.sh`, so a non-interactive
shell without `~/.cargo/bin` on `PATH` still works.

There is **no** project generator, no CocoaPods and no third-party Swift
package. `App/ParanoID.xcodeproj` is hand-written and reviewable as text;
ADR-0014 rejects XcodeGen as an additional unpinned binary in the build path.
`bridge/Cargo.lock` is seeded from `clients/core/Cargo.lock`, so the iOS build
pins exactly the crate versions the Android build ships, and
`test_bridge_lock.py` catches any divergence.

## One command

`bash clients/ios/build.sh` runs the whole chain in the order
`clients/android/build.sh` uses, stops at the first failure and names the step
that failed: the toolchain pins; the WebRTC archive re-extracted and verified
by digest; the bridge lock; the shared core's own tests and the bridge's host
tests; the three release slices and `ParanoidCore.xcframework`; the
`ParanoidKit` package tests; the Android cross-test; the nine pinned-TLS leaf
checks and the transport socket rules; the notices packager and its negative
test; the source contracts, the call-scenario parity and the boundary gate; the
simulator test runs (unsigned, plus one signed run for the Keychain tests,
because an unsigned application owns no Keychain); the Release build and the
bundle gate; and finally the archive.

Two of those steps report honestly rather than passing:

- **The iOS ↔ Android comparison does not run.** Its scripts
  (`test_android_compatibility.py`, `test_qr_cross.py`) have not landed, so
  that step prints `SKIP:` with that reason and the build manifest records it
  as `skipped`. It is not a silent pass, and it is `NOT RUN` in
  [verification.md](verification.md). The host side of the cross-test,
  `clients/ios/java_deps.sh`, is a separate step: the script gates it on the
  file being present, so where the file is in the tree the Java host builds and
  that gate is recorded `ok`, and where it is absent that gate prints `SKIP:`
  too. Either way the comparison itself does not run, so the Java client is a
  **source-level** cross-check in
  [protocol-sources.md](protocol-sources.md), not an executed one. When the
  comparison lands, that row carries its result and this paragraph goes away.
- **The archive is skipped without a team.** With `PARANOID_IOS_TEAM_ID` unset
  the script prints `Archive skipped: PARANOID_IOS_TEAM_ID unset` and exits 0.
  Signing is the owner's gate, not the build's.

The run writes `clients/ios/out/evidence/build-manifest.json`: the commit, the
tool versions, every step with its status and duration including the skipped
one, the bundle identity and version, and the SHA-256 of the executable, the
embedded framework, the notices on both sides and both lock files.

## The bundle gate

`test_app_bundle.py` is the only thing in the directory that reads a finished
bundle, and it is where the foreground-only promise becomes checkable:

- bundle identifier `global.paranoid.messenger`, the pinned version pair and
  the deployment target of `toolchain.json`;
- `UIBackgroundModes` exactly `[audio]` — no `voip`;
- **no `aps-environment`** in the plist or in the signed entitlements, so the
  build cannot register for push even by accident;
- no `NSAppTransportSecurity` and no `NSAllowsArbitraryLoads`;
- one arm64 executable and exactly one embedded framework, whose binary is the
  pinned WebRTC slice;
- `THIRD_PARTY_NOTICES.txt` identical to what the packager wrote, naming the
  crates that link and none of the Android-only components;
- no `.p12`, `.p8`, `.env` or `.mobileprovision` anywhere inside.

Two rules bend for a *signed* bundle and say so on their own line instead of
passing quietly: the canonical `embedded.mobileprovision` iOS itself places at
the bundle root is tolerated and reported, and the WebRTC digest is `SKIPPED`
because Xcode re-signs an embedded framework (the pin is enforced at
extraction). A signed bundle must report its Team ID; an unsigned one — all
this repository can make without the owner's gate — says `SKIPPED`, never `OK`.

## Continuous integration

`.github/workflows/ios.yml` lands with this pull request. It is one Ubuntu job,
`ios-static`, triggered by a pull request and by a push to `main` when
`clients/ios/**`, `clients/core/**`, `key-protocol/**` or the workflow itself
changes. It runs, in order:

- `cargo +1.98.1 check --locked --target aarch64-apple-ios` over
  `bridge/Cargo.toml` — the shared core and the bridge type-check for the
  device triple with no edit to the core. It does not link, so it needs no
  Apple SDK; it also extracts every crate source the notices step reads;
- `cargo +1.98.1 clippy --all-targets -- -D warnings` and `cargo +1.98.1 test`
  over the bridge, on the host triple, against the `rlib` half of the crate;
- `test_bridge_lock.py`, `test_toolchain.py --no-xcode`,
  `test_webrtc_dependency.py --offline`, `test_ui_contract.py` and
  `test_call_controller_parity.py` — lock-file drift against the Android lock,
  the Rust/target/OpenSSL pins, the pinned WebRTC digests against a synthetic
  archive, and the two source-only contracts;
- the full `notices.py --offline` followed by `test_notices.py` — the whole
  locked graph, every licence text read and written, not a metadata summary;
- `test_component_boundary.py --base "$BASE_SHA"`, on pull requests only,
  where `BASE_SHA` is the event's base commit. This is the one event-shaped
  step: a push to `main` has no pull-request base, and diffing `main` against
  its own previous tip would judge other people's merges. The checkout uses
  `fetch-depth: 0` because the gate needs that base commit and a merge base
  with it, and exits 2 instead of passing vacuously when it cannot have them.

The workflow **has never executed on a runner**: it lands with the pull request
that first triggers it, so at the revision this document describes there is no
run to link to. Every check in it was run locally on the pinned build Mac with
exit 0 — twelve of its thirteen `run` commands. The thirteenth,
`rustup toolchain install 1.98.1 --profile minimal --component clippy`, is
runner setup rather than a check and was not re-run on a Mac that already pins
1.98.1, so it is first executed by that pull request like the workflow around
it. Those local runs, and not a CI badge, are what
[verification.md](verification.md) records.

What the job deliberately cannot prove is everything this page is otherwise
about: no Xcode, no `xcodebuild`, no simulator, no local stand, no
`WebRTC.xcframework`, no app bundle, no signature. That follows from RFC-0021
question 6, answered on 2026-09-13: no paid macOS runner. `test_toolchain.py`
is therefore given `--no-xcode`, which drops only the `xcodebuild`/`xcrun` and
PostgreSQL checks; a missing Rust toolchain, a missing Apple target or a
LibreSSL `openssl` still fails the step rather than skipping it.

The allowlist the gate enforces over the committed range is `clients/ios/**`,
`docs/**`, `README.md`, `CHANGELOG.md`, `.github/workflows/ios.yml` and
`.github/workflows/docs.yml`; any other path fails. `server/`,
`clients/core/src/`, `clients/android/`, `key-protocol/` and `deploy/` are
listed separately as forbidden, so a change to a protected component is named
as forbidden rather than merely as unexpected.

## Signing, distribution and what the owner supplies

None of the following has happened. Each is a live action that needs an
explicit owner "go" whose permalink is recorded in the evidence directory.

| Step | State | What it needs |
| --- | --- | --- |
| App ID without the push capability | not created | who creates it, owner or contributor |
| Signed install on the contributor's iPhone | `NOT RUN` | the Apple team, the contributor's Apple ID in Xcode Accounts, an owner "go" |
| Hosted registration for that phone | `NOT RUN` | an owner "go"; the server has no account-deletion path |
| TestFlight internal build | `NOT RUN` | an internal group containing the owner, and the export-compliance gate below |

Credentials reach the build only through the environment —
`PARANOID_IOS_TEAM_ID`, `PARANOID_ASC_KEY_PATH`, `PARANOID_ASC_KEY_ID`,
`PARANOID_ASC_ISSUER_ID` — and the `.p8` is never copied into the repository or
passed as a process argument. `App/ExportOptions.plist` is a template with no
`teamID`; the resolved copy is written to the git-ignored `out/`, and
`destination` is `export`, so nothing is uploaded by the build.

## Export compliance is a closed gate

The bundle sets `ITSAppUsesNonExemptEncryption = YES` as the conservative
candidate. **That key is not compliance.** Answering yes normally also requires
a code Apple issues after reviewing the documentation, and Apple applies the
requirement to TestFlight as well as to a public release. The
publicly-available-source route is not available while the repository is
private.

Before any upload the owner records four lines in the client pull request: the
applicable export regime, the classification path chosen and whether a formal
review is required, the entity acting as publisher and exporter, and the
resulting Apple compliance code or the reason none is needed. Until those exist
the upload row stays `NOT RUN`. The inventory of what cryptography the
application actually contains — Olm/vodozemac, SHA-256, AES-256-GCM at rest,
pinned TLS, DTLS-SRTP inside WebRTC — is
[export-compliance.md](export-compliance.md).

## Trust anchor and its expiry

The client carries one pin, the same value the Android client carries, and no
rotation path. The hosted certificate was renewed **with the same key** on
2026-09-13, so the pin is unchanged and the new leaf is valid to
2026-12-12T07:38:09Z; that was verified from the build Mac with a TLS handshake
and no HTTP request. A build shipped through TestFlight carries that pin
immutably, so a same-key renewal must happen again before the expiry, and a
**key** change is a separate deploy-trust RFC — the pin feeds the first-contact
channel transcript, so a new key would invalidate enrolled contacts and not
only the transport.
