---
status: draft
owner: ios
last_reviewed: 2026-09-14
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
`ParanoidKit` package tests; the Android cross-test; the pinned-TLS fixtures
(six of the eight leaf checks over real sockets, the other two on parsed
certificates in the package tests) and the transport socket rules; the notices
packager and its negative test; the source contracts, the call-scenario parity
and the boundary gate; the simulator test runs (unsigned, plus one signed run
for the Keychain tests, because an unsigned application owns no Keychain); the
Release build and the bundle gate; and finally the archive.

One of those steps reports honestly rather than passing, and one now runs:

- **The iOS ↔ Android comparison runs.** `test_android_compatibility.py` and
  `test_qr_cross.py` are ordinary steps of the chain, and its Java host side
  `clients/ios/java_deps.sh` is the step before them. What they prove is
  bounded, and [verification.md](verification.md) says so: the Android facade
  builds on this machine and the checked scenarios agree at the checked
  revisions, which is not acceptance on a pair of phones.
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
- `NSAppTransportSecurity` equal to exactly `{NSAllowsArbitraryLoads: true}`
  and nothing else. `adb56be` (2026-09-13) set that key because on a physical
  iPhone App Transport Security refused the self-signed leaf on the hosted
  server's public address before the pinning delegate ran
  (`NSURLErrorDomain -1200`; measured and recorded in
  [the threat delta](../../security/ios-client-threats.md) and ADR-0014; a LAN
  stand never shows it). The gate was rewritten to require that one key with
  that one value, so it tests the decision instead of forbidding it, and
  `test_ui_contract.py` holds the other half: no `URLSession` outside
  `PinnedSessionDelegate`. The gate has not read a bundle built since the
  rewrite; its last recorded run predates `adb56be`;
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
The gate has read one signed bundle so far: on 2026-09-13, before the ATS
change above, a Release build signed with team `5RPGVC566Q` passed with the
Team ID reported and the framework digest `SKIPPED`.

## Continuous integration

`.github/workflows/ios.yml` landed with pull request #36. It is one Ubuntu job,
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

The workflow **first executed on a runner for pull request #36**
(<https://github.com/GOTD-GLOBAL/ParanoID/pull/36>, opened 2026-09-14 as a
draft): `ios-static` passed. On the same pull request the docs workflow
(`markdown`) passed, as did the server workflow's `client-core-and-tls` and
`native-package` jobs; its `Legacy client history` job is informational and
fails on `main` too. Before that run, every check in the workflow was run
locally on the pinned build Mac with exit 0 — twelve of its thirteen `run`
commands. The thirteenth,
`rustup toolchain install 1.98.1 --profile minimal --component clippy`, is
runner setup rather than a check and was not re-run on a Mac that already pins
1.98.1, so the pull request was its first execution. Those local runs, and not
a CI badge, are what [verification.md](verification.md) records; the runner
repeated the same checks on Ubuntu and proves nothing wider.

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

The first three of the following happened on 2026-09-13; the fourth has not.
Each is a live action that needs an explicit owner "go" whose permalink is
recorded in the evidence directory.

| Step | State | What it needs |
| --- | --- | --- |
| App ID without the push capability | exists for `global.paranoid.messenger` on team `5RPGVC566Q` since the signed install below, which went through `xcodebuild -allowProvisioningUpdates` with the team on the command line; the signed entitlements carry no `aps-environment` (bundle gate, 2026-09-13) | — |
| Signed install on the contributor's iPhone | done 2026-09-13: iPhone 16 Pro Max, iOS 26.6.1, Developer Mode on; a Debug build for the local stand, then a Release build (`adb56be`) for the hosted server, both signed with that team and installed with `xcodebuild` (`DEVELOPMENT_TEAM` on the command line) and `xcrun devicectl`, not through `build.sh` | the Apple team, the contributor's Apple ID in Xcode Accounts, an owner "go" |
| Hosted registration for that phone | done 2026-09-13 with the Release build; `hosted_registrations` is 3, the branch total rather than this step's — one from the build Mac through `service-bridge` on 2026-09-13 while diagnosing the phone's TLS failure, registered but unreachable ever since because that fixture kept its wrapping key in process memory only, so its state file no longer opens; one from the iPhone the same day, the contributor's own and still in use; and one diagnostic account from the build Mac on 2026-09-14, with no messages and no contacts, registered to read the hosted server from a second identity while issue #38 was diagnosed, a third being needed because the first cannot be reopened — all three under the owner's answer to RFC-0021 question 4 (no fixed budget) | an owner "go"; the server has no account-deletion path, so all three are permanent |
| TestFlight internal build | `NOT RUN` | an internal group containing the owner, and the export-compliance gate below |

A direct developer install is not an upload: no archive, no `.ipa` export and
no TestFlight upload were produced, and the signed-archive gate of `build.sh`
did not run. All three stay `NOT RUN` behind the export-compliance gate.

Credentials reach the build only through the environment —
`PARANOID_IOS_TEAM_ID`, `PARANOID_ASC_KEY_PATH`, `PARANOID_ASC_KEY_ID`,
`PARANOID_ASC_ISSUER_ID` — and the `.p8` is never copied into the repository or
passed as a process argument. `App/ExportOptions.plist` is a template with no
`teamID`; the resolved copy is written to the git-ignored `out/`, and
`destination` is `export`, so nothing is uploaded by the build.

## The local stand runs a prebuilt server binary

`clients/ios/local_stand.py` normally builds the **unchanged** server from the
working tree and starts it against a private PostgreSQL 16 cluster. That build
no longer succeeds on macOS, and the reason is in the server, not in this
client: since `main` `547099f` (2026-09-13),
`server/src/android_updates.rs:297` opens the update staging file with
`libc::O_TMPFILE`, a flag the `libc` crate defines only on Linux, so the pinned
command

```sh
cargo +1.98.1 build --locked --release --manifest-path server/Cargo.toml \
  --target-dir clients/ios/out/server-target
```

stops with `error[E0425]: cannot find value O_TMPFILE in crate libc`.

`server/` is a red zone and this branch does not change it. The stand is
therefore started from a server binary built before that commit, passed with
`--server-binary PATH`, which `local_stand.py`, `test_clean_self_service.py`,
`test_realtime.py`, `test_sim_text.py`, `test_voice_sim.py` and
`test_android_compatibility.py` all accept and which skips the build:

```sh
python3 clients/ios/local_stand.py \
  --server-binary clients/ios/out/server-target/release/paranoid-server
```

This is an environment limitation to state, not a result to work around: every
stand result file records the SHA-256 of the server binary it ran against, so
the binary that answered a run is identifiable, and a Linux host (or a server
fix outside this branch) restores the from-source path unchanged.

## Naming a stand in a Debug build

A Debug build takes the local stand's HTTPS origin and TLS pin from either of
two channels. Both are read by `App/ParanoID/DebugFixture.swift`, and both are
inside `#if DEBUG`:

| Channel | Names | Reaches |
| --- | --- | --- |
| Launch arguments | `-paranoid-realm <url>`, `-paranoid-pin <hex>` | a simulator run started by Xcode or `xcodebuild test` |
| Environment variables | `PARANOID_REALM`, `PARANOID_PIN` | a build started on a physical phone by `devicectl` |

The second channel exists because `devicectl` installs and launches a build
without relaying launch arguments to the process, so on a device the
environment is the only channel that carries the pair; it was added for, and
used by, the 2026-09-13 device smoke, with the stand bound to the Mac's LAN
address so the phone could reach it. The values are the same
either way, both go through `ServiceTrust(realm:pin:)` — the `checkedRealm` and
`checkedPin` a Release build applies to its own — and an argument wins when a
launch offers both.

**Neither channel is read in a Release build.** There,
`DebugFixture.trust(arguments:environment:)` compiles to a body that answers
`nil` without looking at the command line or the environment, so a shipped or
TestFlight build cannot be pointed at a stand: it starts from the compiled
hosted default and from nothing else.

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
