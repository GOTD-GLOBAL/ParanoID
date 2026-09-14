# iOS client evidence — 2026-09-13

Evidence catalogue of the candidate native iOS client
([RFC-0021](../../../rfcs/0021-ios-client.md),
[proposed ADR-0014](../../../decisions/0014-ios-client.md),
[REQ-CLIENT-001](../../../product/requirements.md)).

This directory is what a reviewer reads instead of trusting the pull-request
description. It says which command was run, when, what it printed, and which
file that run wrote — with the size and SHA-256 of every such file — and it
names, in its own section, everything that was **not** run.

| File | What it is |
| --- | --- |
| `README.md` (this file) | the catalogue: commands, results, versions, digests, what was not run, the owner's decisions |
| [artifacts.json](artifacts.json) | the same catalogue for machines: 33 artifacts and 56 screenshots, each with path, bytes, SHA-256 and the time it was produced |
| [stage1-text.md](stage1-text.md) | joint test 1 (text and QR on real phones), written in advance, **partly run** in the unscheduled session of 2026-09-14: steps 4, 5 and 6 read `SHOWN (joint, reported)` — the contributor's report, not a capture — and every other `Result` cell stays `NOT RUN`; steps 1, 2, 4 and the first half of 5 had been pre-run by the contributor alone on 2026-09-13, which is not the joint test |
| [stage2-voice.md](stage2-voice.md) | joint test 2 (calls on real phones), written in advance, **partly run** in the same session of 2026-09-14: steps 4, 8 and 9 read `SHOWN (joint, reported)` — one call the owner placed to the iPhone, answered and spoken on, with both cameras turned on — and every other `Result` cell stays `NOT RUN` |
| [independent-review.md](independent-review.md) | the independent AI reviews of policy item 2: reviewer, model, revision, every finding and what became of it |

## Counters

| Counter | Value |
| --- | --- |
| Accounts this branch created on the hosted alpha | `hosted_registrations: 2` — one from the build Mac through `service-bridge` while diagnosing the phone's TLS failure, and one from the physical iPhone once App Transport Security was switched off; both under the owner's answer to RFC-0021 question 4 (no fixed budget). The phone then paired the owner's Android from its QR and sent a text the hosted server accepted. The joint session of 2026-09-14 ran on that same iPhone account and registered nothing, so the counter is unchanged by it |
| Contacts with the hosted server | one TLS handshake from the build Mac with no HTTP request (2026-09-13T08:06Z); then the build Mac's `service-bridge` registration, made while diagnosing the phone's TLS failure; then, after the App Transport Security fix of `adb56be`, the iPhone's registration, the pairing of the owner's Android from his QR image on the iPhone, and one text the hosted server accepted (one check) — its delivery to the owner's Android was still pending because his phone had not polled; then, on 2026-09-14, the unscheduled joint session on that same account, which registered nothing: text both ways with the owner's Android and one call it placed to the iPhone |
| Physical phones involved so far | two: the contributor's iPhone 16 Pro Max (iOS 26.6.1, Developer Mode enabled) — a Debug build against the local stand and, later the same day, a Release build against the hosted server, both installed on 2026-09-13 with team `5RPGVC566Q` — and the owner's Android, which until 2026-09-13 had taken part only as the source of a QR image and the addressee of one text not yet delivered, and which on 2026-09-14 exchanged text with the iPhone and called it |
| Simulator devices used | iPhone 17 Pro and iPhone 17e, both on iOS 26.5 |

RFC-0021 question 4 was answered on 2026-09-13 — **as many accounts as the
tests need, no fixed budget** — which sets a budget, not a number. The two
registrations above are recorded under that answer with the reason each was
needed, and no separate per-registration permalink is written beside them.
Each is counted here because the server has **no account-deletion path** and
every registration is permanent; any further registration is counted here the
same way.

## The revision this catalogue describes

| Fact | Value |
| --- | --- |
| Branch | `feat/ios-client-20260911` |
| Head this catalogue describes | `bcb40463120419ffb9e86824078c220db50dbceb` |
| Merge base with `origin/main` | `2d91bd4dba79bd35f563e51850f2e18796a3c9ba` |
| Committed files changed against that base | 185 |
| Committed files outside the iOS allowlist | 0 |
| Uncommitted paths, when the boundary gate last ran for this catalogue | 24 at 2026-09-13T19:57Z, all inside the same allowlist — a reading of that moment, not a property of the branch |

The boundary gate reads committed changes only and says so out loud. The
uncommitted number above is a reading, not a property of the branch: it moves
while the branch is being edited, so the gate's own `note:` line in the run
that is being reported is the record, and this row is only that line at that
moment. Nothing in this branch touches `server/`, `clients/core/src/`,
`clients/android/`, `key-protocol/` or `deploy/` — that is the part the gate
checks, and it re-passed at this head. The device smoke further down was run
around this head — its simulator frames straddle the Keychain entitlement fix
`bcb4046`, which is this head — and its hosted leg at the later App Transport
Security fix `adb56be`, where the gate table below was not re-run.

## Command → result

### Re-run at this head on 2026-09-13, exit 0 observed

| Command | Result |
| --- | --- |
| `python3 clients/ios/test_component_boundary.py` | `base: origin/main (2d91bd4dba79), merge-base: 2d91bd4dba79, head: bcb404631204` / `PASS: 185 files changed, 0 outside allowlist`, with the gate's own `note:` line counting the uncommitted paths it does not read |
| `python3 clients/ios/test_ui_contract.py` | `Ran 20 tests in 0.027s` / `OK` |
| `python3 clients/ios/test_notices.py` | `PASS: 30 tests` |
| `python3 clients/ios/test_call_controller_parity.py` | `labels: 94/94 covered (93 verbatim, 1 embedded)` |
| `python3 clients/ios/test_bridge_lock.py` | `OK: 123 registry packages and 2 path packages match Cargo.lock of clients/core` |
| `npx markdownlint-cli2@0.18.1` over every file changed for this catalogue | 0 findings on the lines of those files |
| `grep -c` for the registration counter over `docs/project/evidence/ios-client-*/README.md` | `1` — the counter is written once, in the table above, and nowhere else in this file |

### The last end-to-end `build.sh` run is older than this head

`bash clients/ios/build.sh` last ran end to end at **2026-09-13T14:40Z**, at
commit `c2fdcc0`; it wrote `build-manifest.json`, `build-steps.tsv` and most of
the digests further down, and the manifest names the commit it ran at. Its 22
steps are 20 `ok` and 2 `skipped`. The console log kept below is one run older
— `out/step47/build-sh.log`, finished 14:34Z — because the later run
overwrote only the machine-readable files; that log ends
`OK: 20 step(s) passed, 2 skipped: iOS <-> Android cross-test (plan step 34);
archive and export`, and the two runs record the same 22 gates with the same
statuses.

It is **not** a run of this head. `build.sh` had 22 gates then; at
`bcb4046` it defines **24**, because the single skipped cross-test gate became
three ordinary steps — the `core-bridge` build, the protocol comparison and the
QR cross-check — and the chain has not been re-run end to end since they
landed. Those three were run on their own and carry their own evidence files,
which is what the table below reports for them. Nothing else is claimed for
them: a full re-run may still find something these separate runs did not.

### The 24 gates `build.sh` defines at this head, in order

`status` and `seconds` for gates that were part of the 14:40Z run are that
run's own record (`clients/ios/out/logs/build-steps.tsv`); the three gates that
did not exist in it say where their result comes from instead. A skipped gate
says why and is never counted as a pass.

| # | Gate | Command | Status | s | What it printed |
| --- | --- | --- | --- | --- | --- |
| 1 | toolchain pins | `python3 test_toolchain.py` | ok | 1 | `OK` — Xcode 26.6 (17F113), SDK 26.5, Swift 6.3.3, rustc 1.98.1, three iOS targets, OpenSSL 3.6.2, PostgreSQL 16.13 |
| 2 | WebRTC xcframework | `python3 webrtc_dependency.py` | ok | 0 | `Verified WebRTC 150.7871.01: 2 slices` |
| 3 | WebRTC pin rules | `python3 test_webrtc_dependency.py` | ok | 1 | `PASS: 11 tests (real archive)` |
| 4 | bridge lock == core lock | `python3 test_bridge_lock.py` | ok | 0 | `OK: 123 registry packages and 2 path packages match Cargo.lock of clients/core` |
| 5 | shared core tests (release) | `cargo +1.98.1 test --offline --locked --release --manifest-path ../core/Cargo.toml --target-dir out/core-target --lib --test clean_first_contact --test realtime_signing --test voice_calls` | ok | 7 | 17 + 6 + 14 tests passed, 0 failed — the core is built and tested from here, never modified |
| 6 | bridge ABI tests (host) | `cargo +1.98.1 test --offline --locked --manifest-path bridge/Cargo.toml --target-dir out/bridge-target` | ok | 1 | 6 tests passed, 0 failed |
| 7 | `ParanoidCore.xcframework` | `bash build-core.sh` | ok | 1 | three `arm64` slices combined; digests in `bridge-hashes.json` |
| 8 | ParanoidKit tests | `swift test --package-path ParanoidKit --scratch-path out/spm` | ok | 11 | 242 tests, 0 failures |
| 9 | Android cross-test (Java host) | `bash java_deps.sh` | ok | 1 | the Java facade compiled against the shared core. `java_deps.sh` was **untracked at `c2fdcc0`**, so that run read an uncommitted file; it is committed at this head and the cross-test run of 19:34Z built the facade again from the committed one (`java-host.json`, 15:10Z, reference `fe9c26c`) |
| 10 | core-bridge (iOS side of the cross-test) | `swift build --package-path ParanoidKit --scratch-path out/spm --product core-bridge` | ok | — | new at this head, so not in the 14:40Z run. It builds the executable the two cross-tests drive; both cross-test runs below list it among the commands they executed |
| 11 | iOS ↔ Android protocol compatibility | `python3 test_android_compatibility.py --evidence-dir out/checks/compat` | ok | — | run on its own at this head: `PASS (15 checks)`, `commit: bcb4046`, 2026-09-13T19:34Z. Twelve checks are wire-level, and the last three are a live stand — both shipped stacks registered on one local stand and a text crossed in each direction with the peer's receipt. The same script with `--skip-stand` printed `PASS (12 checks)` with no server at all (`out/checks/compat-offline`, 15:14Z, `commit: 674ec31`) |
| 12 | QR cross-check | `python3 test_qr_cross.py --evidence-dir out/checks/qr-cross` | ok | — | run on its own: `2/2 identical`, `PASS (4 checks)` with six refusals and no refusal echoing the payload (`out/checks/qr-cross`, 2026-09-13T15:24Z, `commit: 674ec31` — one commit behind this head) |
| 13 | pinned TLS handshakes | `python3 check-pinned-tls.py` | ok | 3 | nine leaf cases against real loopback servers; seven rejected before any HTTP request |
| 14 | realtime transport rules | `python3 test_realtime_transport.py --evidence-dir out/checks/transport` | ok | 34 | the eight transport rules against the fake server |
| 15 | third-party notices | `python3 notices.py --offline` | ok | 0 | the notices that ship inside the bundle |
| 16 | notices rules | `python3 test_notices.py` | ok | 1 | `PASS: 30 tests` |
| 17 | UI contract | `python3 test_ui_contract.py` | ok | 0 | `Ran 20 tests … OK` (source-only: captions, call rules, `FLAG_SECURE` comparison) |
| 18 | call scenario parity | `python3 test_call_controller_parity.py` | ok | 0 | `labels: 94/94 covered (93 verbatim, 1 embedded)` |
| 19 | component boundary | `python3 test_component_boundary.py` | ok | 0 | `PASS: 163 files changed, 0 outside allowlist` in that run; re-run at this head it prints `PASS: 185 files changed, 0 outside allowlist` |
| 20 | simulator tests (unsigned) | `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' … -skip-testing:ParanoIDTests/KeychainStoreTests` | ok | 25 | `ParanoIDTests`: 34 tests, 0 failures — `BridgeSmokeTests`, `CallAudioSessionTests`, `QrTests`, `SdpCompatibilityTests`, `SdpPublishGatingTests` (16); `ParanoIDUITests`: 4 tests of which **3 skipped** — the text and call scenarios only run from `test_sim_text.py` / `test_voice_sim.py`, which are the two rows below |
| 21 | simulator Keychain tests | `xcodebuild test … -only-testing:ParanoIDTests/KeychainStoreTests` | ok | 6 | 8 tests, 0 failures; the only run where the application owns a Keychain (ad-hoc simulator signature, no team) — measured, see below |
| 22 | device build (Release, unsigned) | `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | ok | 6 | `out/ParanoID.app`, `global.paranoid.messenger` 0.0.1 (1) |
| 23 | application bundle | `python3 test_app_bundle.py out/ParanoID.app` | ok | 1 | `PASS: 24 checks (1 skipped)`; the skipped one is the Team ID, which needs a signed bundle |
| 24 | archive and export | owner signing gate | **skipped** | 0 | `Archive skipped: PARANOID_IOS_TEAM_ID unset` — no signing material existed on this machine at that run. The device installs of 2026-09-13 were signed with team `5RPGVC566Q` from the `xcodebuild` command line, outside `build.sh`; this gate has not been re-run, and no archive or export exists |

### Runs from earlier in this branch, dated by the file each one left

Each one wrote the artifact named beside it; the digest of that artifact is in
the table further down, so the file a reviewer is pointed at is the file that
run produced. Where a check was run more than once, the date is the run whose
file is still on disk, because a re-run overwrites the artifact in place.

| Command | Run (UTC) | Result | Artifact |
| --- | --- | --- | --- |
| `python3 clients/ios/test_voice_sim.py --evidence-dir out/evidence/voice-sim` | 2026-09-13T12:15Z | `PASS` — two simulators, two call-v2 calls one each way, both sides `connected` over direct `host`-to-`host` ICE, ≈2300 RTP packets received and sent per side per call, 40 s held, four heartbeat envelopes per side per hold | `voice-sim-result.json` + 32 screenshots |
| `python3 clients/ios/test_sim_text.py --evidence-dir out/evidence/sim-text` | 2026-09-13T12:12Z | `PASS` — identity, QR paste, pairing, text both ways, receipts, block/unblock, contact names, reinstall | `sim-text-result.json` + 17 screenshots |
| `python3 clients/ios/test_voice_relay_lane.py --evidence-dir out/checks/voice-lane` | 2026-09-13T19:24Z (re-run at this head; the first run was 08:38Z) | `7/7 PASS, signature verified` — nine signed requests, nine signatures verified by the stub | `voice-relay-lane.json` |
| TLS handshake to the hosted origin from the build Mac, no HTTP request | 2026-09-13T08:06Z | the live SubjectPublicKeyInfo digest equals the pin this client carries; the renewed leaf is valid to 2026-12-12T07:38:09Z | `hosted-preflight.json` |
| `python3 clients/ios/test_realtime.py --evidence-dir out/checks/realtime` | 2026-09-12T19:17Z | `PASS` — injected transport faults through the fault proxy, 0 proxy errors | `realtime-fixture-result.json`, `latency-samples.json`, `network-timings.json` |
| `python3 clients/ios/test_clean_self_service.py --evidence-dir out/checks/local-text` | 2026-09-12T18:38Z | `PASS` — two clients on one stand: text both ways, receipts, the exact retry of a lost answer, block/unblock, every stored row frame-2 ciphertext | `clean-fixture-result.json` |
| the same with `--longpoll` | 2026-09-12T18:40Z | `PASS` — 300 s across the server's idle, socket-lifetime and renewal bounds with no failure published | `checks/step27-longpoll-smoke/clean-fixture-result.json` |
| `python3 clients/ios/test_clean_self_service.py --registration-only --evidence-dir out/checks/registration` | 2026-09-12T18:19Z | `PASS` — `enrollment.mode == "active"`, two durable commits before any request, a 64-digit fingerprint, 0 dialogs | `registration-result.json` |
| QR round trip on the simulator | 2026-09-12T19:07Z | byte-identical round trip of the core's own 901-byte contact; 2049 bytes refused | `qr-round-trip.json` |
| storage commit order and the injected-fault matrix | 2026-09-12T07:22Z | every durable step failed in turn | `storage-20260912/summary.json` |
| every `run` command of `.github/workflows/ios.yml`, locally in workflow order | 2026-09-13T13:39Z | twelve of the thirteen exited 0; the thirteenth is the `rustup toolchain install` setup line, not re-run on a Mac that already pins 1.98.1 | `ci/step45-workflow-commands.log`, `ci/step45-verification.log` |
| Device smoke on the contributor's iPhone 16 Pro Max (iOS 26.6.1, Developer Mode enabled): a Debug build signed with team `5RPGVC566Q`, installed with `xcodebuild -allowProvisioningUpdates` and `xcrun devicectl`, against the local stand bound to the Mac's LAN address, with a persistent peer in place of the in-memory fixture peer, and a simulator as the call peer. The Debug build takes the stand's realm and pin through a `DEBUG`-only environment channel, because `devicectl` relays no launch arguments | 2026-09-13T20:41Z (the result file's time) | identity created on the device; own QR shown; a QR scanned off the Mac screen with the real camera; fingerprint sheet confirmed; 2 texts device→peer and 1 peer→device with receipts; one call device→simulator `connected`, video from the iPhone visible (the simulator has no camera). The local stand afterwards: 5 accounts, 5 devices, 7 stored envelopes all frame 2, 0 plaintext rows. Screen lock during dialling not run — it moves to the joint test | `device-smoke-20260913/device-smoke-result.json` + 7 simulator screenshots |
| The same iPhone against the hosted alpha: a Release build signed with the same team at `adb56be`, after the App Transport Security fix | 2026-09-13, recorded in the same file | the phone registered (`hosted_registration_from_device: true`); it paired the owner's Android from his QR image, scanned off a screen, and sent one text the hosted server accepted (one check); delivery to the owner's Android `pending` — his phone had not polled. Before the fix, a `service-bridge` registration from the build Mac diagnosed the phone's TLS failure; the two together are the counter's 2 | the same `device-smoke-result.json` |
| `.github/workflows/ios.yml` on a GitHub runner: pull request [#36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36), opened as a draft on 2026-09-14 | 2026-09-14 | job `ios-static` passed; the docs workflow passed; the server workflow's `client-core-and-tls` and `native-package` passed; `Legacy client history` is informational and fails on `main` too | none on this Mac — the run lives on GitHub |

Every run above used the local stand — the **unchanged** server binary against
a private PostgreSQL 16 on the build Mac — or no server at all, with two
exceptions: row 4 is the TLS handshake to the hosted alpha, which sent no HTTP
request and created no account, and the hosted leg of the device smoke, which
is where the two registrations, the pairing from the owner's QR image and the
one accepted text of the **Counters** table come from. The `server_state`
block of `device-smoke-result.json` (5 accounts, 5 devices, 7 frame-2
envelopes, 0 plaintext rows) is the **local** stand's — its `stand` line says
so — and no such count was taken on the hosted server.

The device smoke found three defects, two on the local stand and one against
the hosted server. An empty entitlements file made the simulator's Keychain
answer `errSecMissingEntitlement (-34018)` — fixed by declaring
`keychain-access-groups` (`bcb4046`), with no change of behaviour on the
device; and the fixture peer kept its key in memory only, so a peer registered
in one process could not be read by the next — replaced by a persistent peer,
harness only. The third is defect 4 of
[verification.md](../../../clients/ios/verification.md): App Transport
Security refused the self-signed leaf on a public IP address before
`PinnedSessionDelegate` ran (`NSURLErrorDomain -1200`, stream error `-9802`),
which a LAN stand never shows and which `NSPinnedDomains` cannot exempt for an
IP literal. Fixed in `adb56be` by `NSAllowsArbitraryLoads = YES` under the
`test_ui_contract.py` contract of exactly that key and no `URLSession` outside
the delegate; the reasoning is in
[ios-client-threats.md](../../../security/ios-client-threats.md).

**The stand runs a prebuilt server binary, and that is an environment fact.**
Since `main` `547099f` (2026-09-13), `server/src/android_updates.rs:297` opens
the update staging file with `libc::O_TMPFILE`, which the `libc` crate defines
only on Linux, so the pinned `cargo +1.98.1 build --locked --release
--manifest-path server/Cargo.toml` stops on this Mac with
`error[E0425]: cannot find value O_TMPFILE in crate libc`. That commit reached
this branch with the `origin/main` merge of 2026-09-13T16:43Z: the runs dated
before it built the server from source, and every stand started after it is
given `--server-binary` pointing at a server built before it. `server/` is a
red zone and this branch does not change it either way. Which binary answered
is checkable rather than asserted: each stand result file records its SHA-256,
and the cross-test of gate 11 records
`a4a65d123ee06f6e8b6e6ab63da4e23cd4eb6fa3c8f8ea15f5898ee407880e93`.

### What the Keychain step's signature actually needs

Gate 21 claims an ad-hoc simulator signature and no team. That was measured on
2026-09-13 (Xcode 26.6, iPhone 17 Pro 26.5) by running the one command of that
gate three times, changing only the signing settings:

| Run | Signing settings | Signing identity | Result |
| --- | --- | --- | --- |
| as gate 21 runs it | none added | `Sign to Run Locally` | 8 tests, 0 failures, exit 0 |
| with a team | `DEVELOPMENT_TEAM=5RPGVC566Q` | `Sign to Run Locally` | 8 tests, 0 failures, exit 0 |
| unsigned | `CODE_SIGNING_ALLOWED=NO` | none | 8 tests, **8 failures**, `keychain(-34018)`, exit 65 |

So the signature the simulator applies by itself is what these tests need; a
development team changes neither the identity nor the outcome and none is
asked for, and disabling signing — which is what gate 20 does — is exactly why
gate 20 skips this bundle of tests and gate 21 runs it. The run with the team
is kept in `out/logs/keychain-signed.log` (`** TEST SUCCEEDED **`,
`Executed 8 tests, with 0 failures`), digested in
[artifacts.json](artifacts.json).

## Versions

| Component | Version | Where it was read |
| --- | --- | --- |
| Xcode / build | 26.6 / 17F113 | `build-manifest.json` (and gate 1 of the 14:40Z run) |
| iOS SDK | 26.5 | `build-manifest.json` |
| Deployment target | iOS 17.0 | `app-bundle.json` |
| Swift | 6.3.3 | `build-manifest.json` |
| Rust | 1.98.1 (`rustc 1.98.1 (48a229cea 2026-09-01)`), targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin` | `toolchain.json` |
| WebRTC | 150.7871.01 (pinned archive, `ios-arm64` slice `53c02ea6…`) | `build-manifest.json` |
| PostgreSQL (local stand) | 16.13 | `build-sh.log`, gate 1 |
| OpenSSL | 3.6.2 | `toolchain.json` |
| JDK (Java cross-check only) | 21.0.12.1 | `java-host.json` |
| Python | 3.14.4 | `build-manifest.json` |
| Bundle | `global.paranoid.messenger` 0.0.1 (1), unsigned, background mode `audio` | `build-manifest.json` |
| Simulators | iPhone 17 Pro, iPhone 17e, iOS 26.5 | `voice-sim-result.json` |
| Physical device | iPhone 16 Pro Max, iOS 26.6.1, Developer Mode enabled; Debug and Release builds of `global.paranoid.messenger` signed with team `5RPGVC566Q` | `device-smoke-result.json` |
| Android reference for the source cross-check | `fe9c26cb4824…` (v15 plus the two classes that moved past it on `main`: call-v2 video and the push wake gateway) | `java-host.json` |
| Owner's Android build in the joint session of 2026-09-14 | not recorded — call-v2 rejects v1 call bodies, so the build that called this client was v16 or later; the exact version was not asked for | nowhere: the session left no file, and this is the contributor's report |
| Markdown linter | `markdownlint-cli2@0.18.1`, the version CI pins | `docs.yml` |

## Artifacts

The raw output stays under `clients/ios/out/`, which is git-ignored, and is
**not** copied into this directory: those files carry absolute paths of the
build Mac and loopback addresses, and the screenshots show contact
fingerprints and account identifiers. What travels into the repository is this
catalogue — path, size, SHA-256, and what the file says. Re-running the command
reproduces the run, not the digest.

`Produced` is each file's own time, and several files are **newer** than the
14:40Z `build.sh` run because the check that writes them was run again
afterwards: a re-run overwrites the artifact in place. Where a gate's row above
reports the 14:40Z run and the file below is newer, the digest here is of the
file as it now stands, not of what that run wrote.

| Artifact (git-ignored) | Produced (UTC) | Bytes | SHA-256 | What it says |
| --- | --- | --- | --- | --- |
| `clients/ios/out/evidence/build-manifest.json` | 2026-09-13T14:40Z | 8052 | `cf46cb6dc780e85554d78868f79438ff9006e5f60dd264f7682d64490ff601bc` | build.sh manifest: every gate with status and seconds, the toolchain versions, the bundle identity and the digests of the built binaries |
| `clients/ios/out/logs/build-steps.tsv` | 2026-09-13T14:40Z | 2106 | `534a43b5dbab0367f12ae99754cd6fbb43528dd25f5acb666f7ab72799a9d9c9` | the same run as a tab-separated step log (name, status, seconds, command) |
| `clients/ios/out/step47/build-sh.log` | 2026-09-13T14:34Z | 351569 | `1345f2371aacd9876878fa0c3cf1653fcf4cce7412ae0906165332886cbab64e` | full console output of a `build.sh` run of step 47, finished 14:34Z — one run older than the manifest above, which a later run overwrote; both runs show the same 22 gates with the same statuses |
| `clients/ios/out/evidence/bridge-hashes.json` | 2026-09-13T14:38Z | 2125 | `060b0578cda0b288dab1f520bdccb5c2a73961ae8e78c6cfe97b8c25724ca685` | build-core.sh manifest: the three release slices, the xcframework, the header digests and the bridge lock digest |
| `clients/ios/out/evidence/bridge.json` | 2026-09-11T20:24Z | 4482 | `e01ada5545552a524539645f93fb7e895be88aeb2039582826fbee902d672ca5` | plan steps 5-6, kept as it was written: the first compile of the unchanged core and key-protocol for aarch64-apple-ios, with the red-zone stop gate not tripped |
| `clients/ios/out/evidence/toolchain.json` | 2026-09-13T19:23Z | 868 | `9e91b4960408a862581baf204b59365293b58a85ce01ab363ea049b8f9127f7a` | test_toolchain.py: pinned versus observed toolchain, with the members it could not observe listed as skipped. The file now on disk is a later run whose `skipped` list is `xcode`, `ios_sdk`, `swift`, `pg_bin`, so it observes `rustc`, the three Apple targets and OpenSSL only; the Xcode, SDK, Swift and PostgreSQL readings of gate 1 are preserved in `build-manifest.json` and `build-sh.log` |
| `clients/ios/out/evidence/app-bundle.json` | 2026-09-13T20:13Z | 3930 | `d7fb910d36b91bf4ec58a6b352031192bb729022f7e14669c134f11988f88af6` | test_app_bundle.py: the last run overwrote the 14:40Z reading of the unsigned bundle with a signed Release bundle (team `5RPGVC566Q`) taken apart — `PASS`, the Team ID reported, the signed entitlements without `aps-environment`, the WebRTC digest `SKIPPED` because Xcode re-signed the framework. It predates `adb56be`, so it still reports no `NSAppTransportSecurity`; the gate has not read a bundle built after that commit |
| `clients/ios/out/logs/keychain-signed.log` | 2026-09-13T19:34Z | 180812 | `279edb7cdbbf6d3b7a6e2c5448c179f508ee90f264217a824fc5bee0c6ed3f47` | the Keychain gate run with a development team (`DEVELOPMENT_TEAM=5RPGVC566Q`): `Executed 8 tests, with 0 failures`, `** TEST SUCCEEDED **` — the third row of the signing table above |
| `clients/ios/out/evidence/pinned-tls.json` | 2026-09-13T19:25Z | 2366 | `1e0c3fb4975717bc25a321eed504c6b680bc818a8a4edd7bb5ca0c3ad49e195a` | check-pinned-tls.py: nine leaf cases against real loopback servers, what was rejected before any HTTP request, and the TLS floor |
| `clients/ios/out/checks/transport/realtime-transport.json` | 2026-09-13T19:24Z | 22682 | `3c2f900937790657d50dd33211d750160b25e89ce0a35d45c3ef2dc601ecdcd0` | test_realtime_transport.py: the eight transport rules against the fake server, with the server-side record of connections, resets and idle closes |
| `clients/ios/out/checks/voice-lane/voice-relay-lane.json` | 2026-09-13T19:24Z | 9213 | `52ec22e259281ed55442c103c6bde012064d07b095bc404dbd34da5d7f954fa2` | test_voice_relay_lane.py: seven TURN-lane scenarios over a pinned loopback socket, with nine client signatures verified by the stub |
| `clients/ios/out/evidence/qr-20260912/qr-round-trip.json` | 2026-09-12T19:07Z | 1902 | `5846ecff3a774f51d7b7aa363ddd76b704033509355d2b86466ef6e7ba800319` | QR round trip: the core contact through the generator and back byte-identically, with the size limits and what was not run |
| `clients/ios/out/evidence/storage-20260912/summary.json` | 2026-09-12T07:22Z | 3480 | `939158ba3ad406eae4f987e0969b20326fc7ddef1dc292b5f2b7777fa81ea19f` | storage commit order and the injected-fault matrix |
| `clients/ios/out/evidence/snapshot-codec-20260912/run.json` | 2026-09-12T06:59Z | 1762 | `646236f70904c5bb5d823e65e2d05a55c2b408fd6e83f9e2deff1c75014fab65` | snapshot codec run: what the state file holds and how it is read back |
| `clients/ios/out/evidence/swift-corebridge.json` | 2026-09-11T20:55Z | 2766 | `2927d3bfc97cb3fb4f8bb239dfa7baf6859b788c4b4a9b927e75b0950ed7d7e1` | the Swift side of the C-ABI bridge measured against the core |
| `clients/ios/out/evidence/sdp-spike.json` | 2026-09-13T14:40Z | 12191 | `80f76c5327a6a8ee63686e0f2487f0e4e79ea492509d9e579d5d641ce323b8cb` | the libwebrtc offer/answer spike the call-v2 validator was written against |
| `clients/ios/out/evidence/java-host.json` | 2026-09-13T15:10Z | 6255 | `94abb30fa8a2c03ef599f69553af6550e4f02ccfdf160d1eb1d44cf9623bba28` | java_deps.sh: the Java facade compiled against the shared core for the cross-check, with the Android reference commit and the classes that are Android-only |
| `clients/ios/out/checks/compat/result.json` | 2026-09-13T19:34Z | 16616 | `548624db8a98d950e1577439c8a86c6e75b8b5d2e9859a4609ff7f32f572889b` | test_android_compatibility.py at this head: 15 checks, `PASS`, the source digests of both sides, the independent expectations computed in Python, and the local-stand leg with the digest of the server binary that answered it |
| `clients/ios/out/checks/compat-offline/result.json` | 2026-09-13T15:14Z | 15274 | `aa15acdd57a316c7fcc2564eff06f07bacb7a27a0024b403a4fcd1fea120c65f` | the same script with `--skip-stand`: 12 checks, `PASS`, no server and no socket. Written at `674ec31`, one commit behind this head |
| `clients/ios/out/checks/qr-cross/result.json` | 2026-09-13T15:24Z | 4096 | `bb0d6395e577a6a8e8fb23e1213498929265800ea3a879df6705cec10a44e376` | test_qr_cross.py: the contact QR through both encoders, `2/2 identical`, 4 checks and 6 refusals. Written at `674ec31` |
| `clients/ios/out/checks/registration/registration-result.json` | 2026-09-12T18:19Z | 1670 | `66afb28e8c5c5099c67aace412e1e753f9f5b6dead5994bde4cbb5d0d5cc9693` | registration on the local stand: create_identity, upgrade_v2, the commits before any request, enrollment.mode and the 64-digit fingerprint |
| `clients/ios/out/checks/local-text/clean-fixture-result.json` | 2026-09-12T18:38Z | 4556 | `b91829f9a7775f6492c7f20b5af84a9af0755739b38f2d9410adcaa1e18305aa` | two clients on one stand: text both ways, receipts, the exact retry of a lost answer, block/unblock and the ciphertext check of every stored row |
| `clients/ios/out/checks/step27-longpoll-smoke/clean-fixture-result.json` | 2026-09-12T18:40Z | 4553 | `d96994a28312507b89e4efadf43035128d5f4c4f3ee1252168a8fe9e8696ad36` | the same scenario with the 300-second long-poll across the idle, socket-lifetime and renewal bounds |
| `clients/ios/out/checks/realtime/realtime-fixture-result.json` | 2026-09-12T19:17Z | 4373 | `311566a9a8e597e3f5b9b187b73093abf5091a80ea51e08901ca67a1c1f8c60c` | test_realtime.py: injected transport faults through the fault proxy, with the request counts per path and the latency samples |
| `clients/ios/out/checks/realtime/latency-samples.json` | 2026-09-12T19:17Z | 2794 | `e96ebba8166f70ca28fdfbbbaf66702857fb8036fe1d44aa0bc6cdf61b54bf2e` | the individual latency samples of that run |
| `clients/ios/out/checks/realtime/network-timings.json` | 2026-09-12T19:17Z | 16521 | `34f538d7aa4b41b3bbd90d1385daf312d71a23577c6cfa6b08af1c21a33fb42c` | the network timings of that run |
| `clients/ios/out/evidence/sim-text/sim-text-result.json` | 2026-09-13T12:12Z | 2556 | `971bc6f48a1dcf2a6b2b2a09ad3c0414fd7efe0768a1787c386d64cc030f0570` | test_sim_text.py: the application itself on one simulator — identity, QR paste, pairing, text, receipts, block/unblock, contact names, reinstall |
| `clients/ios/out/evidence/voice-sim/voice-sim-result.json` | 2026-09-13T12:15Z | 5171 | `0ba4005c5a24338666a7fff919a673f3b4b0d0e65eb30de9476b80cd3e072f09` | test_voice_sim.py: two simulators, two call-v2 calls one each way, both sides connected over direct ICE with the RTP counters, the held time and the heartbeat envelopes; screen lock recorded NOT RUN with its reason |
| `clients/ios/out/evidence/device-smoke-20260913/device-smoke-result.json` | 2026-09-13T21:51Z | 3227 | `7794d8838b67b557f12695543d13bcd9e4261c4e863bc9d9ffa42727b1d51d91` | the device smoke on the physical iPhone: device, build, results, the local stand's state, the hosted registration note, the defects found and what was not run; listed in `artifacts.json` under `group: device` |
| `clients/ios/out/evidence/hosted-preflight.json` | 2026-09-13T08:06Z | 615 | `6fea521e5b880d34c7e55bcdeb4400fbb4a6848e99337701193b756398255b03` | one TLS handshake to the hosted alpha and nothing else: the live SubjectPublicKeyInfo digest equals the pin this client carries, the renewed leaf is valid to 2026-12-12, and the registration counter as it stood then, zero |
| `clients/ios/out/ci/step45-workflow-commands.log` | 2026-09-13T13:39Z | 839 | `e901781e2c2d11c104aa1eff37781d55106755ef8575cb17a8b07dadc26991f7` | every run command of .github/workflows/ios.yml executed locally on the build Mac, in workflow order |
| `clients/ios/out/ci/step45-verification.log` | 2026-09-13T13:39Z | 11996 | `3f2c1da6580af99f6a64b48c699107a9c9ceb42463f0b12f8591b06a53f92a4e` | the verification pass of that workflow: YAML parse, action pin, path filters, no always-skipping step |
| `clients/ios/out/ci/toolchain-ci.json` | 2026-09-13T13:28Z | 868 | `362a09ff38886768d58d24a6ca97449f323ccacc70fe9983ffe66bc8e88b6077` | test_toolchain.py --no-xcode, the form the Ubuntu job runs |

### Screenshots

49 PNG screenshots, 140–340 KB each, are listed one by one in
[artifacts.json](artifacts.json) with SHA-256, size and a description of the
frame. They are **not** committed: the pairing and contact frames show a
64-digit contact fingerprint and an account identifier, which this directory
never records — so the digest-plus-description form is used for all of them,
including the ones under 200 KB, rather than committing a subset and cutting
the story in half. Seven more, under `device-smoke-20260913/`, are
simulator-side frames of the device smoke, listed in `artifacts.json` the same
way; none of them was taken on the iPhone.

| Set | Count | What is in it |
| --- | --- | --- |
| `clients/ios/out/evidence/voice-sim/` | 32 | the two-simulator call run: welcome, identity, pairing confirmation, contacts, «Сервер подключён», then per call the caller prompt, outgoing, connected, held, ended and a mid-call frame — for both the iPhone 17 Pro (`a-*`) and the iPhone 17e (`b-*`) |
| `clients/ios/out/evidence/sim-text/` | 17 | the text run on one simulator: welcome, identity, add contact, paste, fingerprint confirmation, contacts, chat, sent, delivered, double tap, details, blocked, unblocked, renamed, default name, and the two frames after a reinstall |
| `clients/ios/out/evidence/device-smoke-20260913/` | 7 | the simulator side of the device smoke, 19:05Z–20:08Z: the local-state screen «Не удалось открыть локальное состояние» — two frames on the two simulators before the entitlements fix, when the Keychain answered `-34018`, and one more at 20:06Z whose cause the result file does not record — the welcome screen right after the fix, «Чаты» with «Сервер подключён» (two frames, the last at 20:08Z), and the chat with one text each way and «Доставлено» |

## Shown on a physical iPhone

Rows that this catalogue listed as `NOT RUN` until 2026-09-13 and that the
device smoke above has shown, and one row the joint session of 2026-09-14
showed; the recording rules at the end of this file are what make them `SHOWN`
rather than `CLAIMED`. A row that carries `SHOWN (joint, reported)` has a status
of its own: the contributor was the only participant this record has, so it is
his report given immediately afterwards, not an observation by whoever writes
this file and not a recording.

| Shown | Where |
| --- | --- |
| Anything at all on a physical iPhone | the contributor's iPhone 16 Pro Max, iOS 26.6.1, Developer Mode enabled: a Debug build on the local stand and a Release build against the hosted alpha, both installed on 2026-09-13 |
| A QR code read off a real camera | scanned off the Mac screen on the local stand, and off the owner's QR image — sent as an image, scanned off a screen — for the hosted pairing |
| Identity, own QR, the fingerprint sheet, text both ways with receipts, on a phone | the local-stand leg of the device smoke |
| A call from a phone that connected and carried video | device→simulator on the local stand; video from the iPhone was visible, the simulator has no camera, and audio actually heard is not recorded |
| A registration, a pairing and one accepted text on the hosted alpha from a phone | the hosted leg of 2026-09-13; what became of that particular envelope is not reported |
| `SHOWN (joint, reported)` — text both ways with the owner's Android, both checks on the iPhone, and a call from that Android answered on this phone with both cameras on | the unscheduled joint session of 2026-09-14 on the hosted alpha, reported by the contributor: he scanned the owner's QR with the iPhone camera and the contact paired; his message reached the owner and **both** checks appeared on the iPhone — the first acknowledgement this client has had from a real Android client — and the owner replied; the owner then called the iPhone, the contributor answered and they spoke, so audio carried both ways, and each side turned its camera on and saw the other. That is the first call this client has carried against the Android client rather than a simulator, and the first picture it has received from a real camera over call-v2. Recorded step by step in [stage1-text.md](stage1-text.md) and [stage2-voice.md](stage2-voice.md); the session was unplanned, so no owner "go" permalink exists for it |

**After that session the iPhone stopped connecting**, and has not recovered. It
shows «Нет подключения»; a Debug build installed on the same device and launched
with its console attached — the first direct read of this client's failure,
since device logs otherwise need root on the build Mac — logged, on 2026-09-14
at 07:06 (Europe/Moscow), four times in 45 seconds: `realtime: lane failed:
NSURLError Code=-1001 "The request timed out."` for the signed
`/v2/messages` read. The pinned handshake did not fail —
`PinnedSessionDelegate` logged no refusal and the connection was established —
App Transport Security is not involved (that was `adb56be`), and the route is
alive: the same URL unsigned answers `401` from the build Mac in 0.19 s and
`/health` in 0.2 s with the pin unchanged. What hangs is the signed read for
that account, on the first cycle of a generation, which asks for `messages`
rather than `events`, so the lane never reaches the long poll and never
publishes a connected state; relaunching the application does not clear it. The
measurement is posted to the pull request
(<https://github.com/GOTD-GLOBAL/ParanoID/pull/36#issuecomment-5658890864>).
The 8-second budget that request is given is not an iOS divergence:
`clients/android/src/org/paranoid/text/RealtimeTransport.java:36` sets exactly
the same `path.startsWith("/v2/events?") ? 30000 : 8000`, and this branch does
not change it. It is also a **different** failure from the network-drop open
item below, which leaves a lane parked after a connectivity change.

## NOT RUN

Nothing below has evidence, and none of it is waiting on a decision this client
can take. The full requirement-level table is
[verification.md](../../../clients/ios/verification.md); this is the list a
reviewer should hold the pull request to.

| Not run | Why |
| --- | --- |
| Anything on a physical iPhone beyond the device smoke and the joint session | A signed build ran on the contributor's iPhone on 2026-09-13, and the session of 2026-09-14 used it again (both in the section above); the rows below say, one by one, what those two did not cover. The export-compliance gate is still closed, so no TestFlight build exists |
| The rest of the two joint tests with the owner | [stage1-text.md](stage1-text.md) and [stage2-voice.md](stage2-voice.md) are partly run: the session of 2026-09-14 filled stage 1 steps 4, 5 and 6 and stage 2 steps 4, 8 and 9, each `SHOWN (joint, reported)`. Everything else keeps `NOT RUN` with its reason — stage 1 step 3, where the owner would scan this client's QR and compare the fingerprint aloud, and steps 7 to 15 (closed-application delivery, screen lock, Wi-Fi to LTE, blocking, renaming, ten-minute idle) and stage 2 steps 1 to 3, 5 to 7 and 10 to 17 (the outgoing call, the two-minute hold, hang-up behaviour, mute, speaker, screen recording, lock while dialling and during a call, background and closed-application calls, LTE, busy). Stage 1 steps 1, 2, 4 and the first half of 5 had also been pre-run by the contributor alone on 2026-09-13, which fills no `Result` cell |
| What became of the one hosted text of 2026-09-13 | It was accepted by the hosted server (one check) and the owner's phone had not polled. The next day's session exchanged text both ways with both checks on the iPhone, but the report does not say whether that earlier envelope was among what his phone finally polled. The two registrations are counted above; the server cannot delete an account |
| Interoperability with the Android client **on its own hardware**, beyond what one session showed | Text both ways and one incoming call are now `SHOWN (joint, reported)` — the row in the section above. What that session did not exercise stays untested: the owner never scanned this client's QR, so the Android side of the pairing and the fingerprint compared aloud are `NOT RUN` (stage 1 step 3), and no call has gone out from this client to an Android — stage 2 step 1 has run iPhone to simulator only. The protocol comparison of gates 11 and 12 stays `CLAIMED`, not `SHOWN`: both stacks were processes on this Mac |
| The unpaired first-contact story with an Android peer | `test_android_compatibility.py` pairs both sides before the first text, so REQ-MSG-005 across the two clients is untested; between two instances of this client it is covered by `test_clean_self_service.py` |
| The Data Protection class of the state file | A simulator has no Data Protection and reports no protection class, and the device smoke did not measure it either |
| A real screen recording, AirPlay or a wired mirror over the call stage | No simulator can start one and none was started on the iPhone; the cover is verified source-only |
| Screen lock during dialling or during a call | `xcrun simctl` exposes no lock verb and `XCUIDevice` has no lock API; recorded with that reason inside `voice-sim-result.json`. Not run on the iPhone either: `device-smoke-result.json` moves it to the joint test |
| Any relayed call, and the route the call of 2026-09-14 took | The simulator calls were on one Mac over loopback; the device call of 2026-09-13 went from the iPhone to a simulator on the build Mac over the LAN stand. The stand starts no TURN, so `/v2/voice/turn` answered `404 turn_disabled` and every simulator pair that carried a call was `host` to `host`; no relayed call has been placed. The call between the two phones on 2026-09-14 did happen, but whether its media was relayed or direct, and what `/v2/voice/turn` answered for it, were not reported |
| Audio actually heard, or a camera image actually seen, outside the joint session | On the simulators nothing was decoded to a speaker — the measurement is RTP packet counters — and `device-smoke-result.json` records no audio for the device call of 2026-09-13, where video from the iPhone's camera was visible but the simulator has no camera, so no image came back. Both did happen in the session of 2026-09-14, against the owner's Android: `SHOWN (joint, reported)`, the contributor's report and not a recording |
| An archive and an `.ipa` export | The device installs were signed from the `xcodebuild` command line with team `5RPGVC566Q`; `build.sh`'s archive gate was not re-run and no archive or export exists |
| A TestFlight build, internal or otherwise | The [export-compliance gate](../../../clients/ios/export-compliance.md) is closed: `ITSAppUsesNonExemptEncryption = YES` is prepared, not satisfied, and Apple applies the requirement to TestFlight too |
| Recovery after a network drop on the phone — open item, 2026-09-13/14 | After a network drop the application stayed at «Нет подключения» while the server answered from the Mac and the pinned key was unchanged; the cause is under investigation on the branch and no device log was collected for that drop; the console read of 2026-09-14 above belongs to the other failure |
| Independent **human** review of identity, cryptography, persistence and application security | Not available to the contributor. The closed-alpha exception permits an independent AI review in a fresh context, recorded separately (plan step 46) |

## The owner's decisions, by permalink

Only what is recorded on GitHub counts here. A decision that is not in this
table has not been given, whatever a local note may say.

| Decision | Date | Permalink | What it does **not** cover |
| --- | --- | --- | --- |
| Delegation of technical decision authority to the contributor | 2026-09-13 | <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919> | it does not waive independent review, does not replace evidence, is not closed-alpha scope approval and is not ADR acceptance; no live action follows from it |
| Answer to RFC-0021 question 5 (`404 turn_disabled` permits the disclosed direct-ICE mode) and question 10 (a docs-only pull request for the factual corrections) — by the owner's agents | 2026-09-12 | <https://github.com/GOTD-GLOBAL/ParanoID/issues/27> | it covers those two questions only |

Still missing, each one a separate "go" that has not been given: closed-alpha
scope approval, ADR-0014 acceptance and TestFlight distribution. The pull
request was opened as a draft on 2026-09-14
(<https://github.com/GOTD-GLOBAL/ParanoID/pull/36>); the signed install on the
contributor's own iPhone and the two hosted registrations happened on
2026-09-13 and are recorded in the **Counters** table under the question-4
answer, with no separate permalink beside them.

## Before either joint test may run

Both stages are now **partly run**: the session of 2026-09-14 was unscheduled
and went ahead without the "go" of item 1, and no permalink exists for it. The
conditions below govern the steps that remain.

1. An explicit owner "go" for that specific live action, with a permalink
   recorded in the evidence file beside the result.
2. A signed build installed on the contributor's iPhone — done on 2026-09-13:
   a Release build signed with team `5RPGVC566Q`, installed with `xcodebuild`
   and `xcrun devicectl`. The
   [export-compliance gate](../../../clients/ios/export-compliance.md) is
   separate and blocks TestFlight distribution specifically.
3. For stage 1, a hosted registration for each iPhone identity the test needs.
   RFC-0021 question 4 sets no fixed budget, so the limit is the "go" of item 1
   and not a number; every registration is counted in this file and none can be
   deleted afterwards. The iPhone's registration was consumed on 2026-09-13,
   before the stage: the counter reads 2 in total, 1 for the phone.
4. For stage 2, an Android build of **v16 or later** on the owner's phone:
   call-v2 rejects v1 call bodies, so an older build can exchange text with
   this client but cannot call it. The build that called the iPhone on
   2026-09-14 therefore was v16 or later; the exact version was not asked for.

**Pre-run, 2026-09-13.** Stage 1 steps 1, 2, 4 and the first half of 5 (one
check, no reply yet) were exercised by the contributor alone against the
hosted server, with the owner's QR image in place of his screen. That is not
the joint test and no `Result` cell of `stage1-text.md` changes because of it;
what filled those cells is the joint session of the next day, and step 3 —
the owner scanning this client's QR and comparing the fingerprint aloud —
still waits for him.

## Recording rules

- Each row is filled in with what happened, not with what was expected. A step
  that behaves differently is recorded as `FAILED` with the observed behaviour;
  a step that was skipped stays `NOT RUN` with the reason.
- A simulator result never becomes a phone result by being copied into this
  directory. Simulator and local-stand runs are `CLAIMED` in
  [verification.md](../../../clients/ios/verification.md); only a phone makes a
  row `SHOWN`.
- A result the contributor reports afterwards, with no file and no capture
  behind it, is written `SHOWN (joint, reported)` and never plain `SHOWN`, so a
  reader can tell a reported result from a captured one. Nothing the report does
  not cover is inferred from what it does.
- Screenshots are taken on both phones for any row whose result is visual, and
  are named by the step number.
- No account identifier, contact fingerprint, realm, pin, credential or
  snapshot byte is written into this directory, and no address or hostname of
  the build Mac. Counts, verdicts, versions and digests only.
- The foreground-only limitation is **expected behaviour**, not a failure: a
  call placed to a locked or closed iPhone ends in the caller's 45-second
  `timeout`, and that is written into stage 2 in advance.
