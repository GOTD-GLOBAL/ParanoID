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
| [artifacts.json](artifacts.json) | the same catalogue for machines: 32 artifacts and 49 screenshots, each with path, bytes, SHA-256 and the time it was produced |
| [stage1-text.md](stage1-text.md) | joint test 1 (text and QR on real phones), written in advance, every `Result` cell `NOT RUN` |
| [stage2-voice.md](stage2-voice.md) | joint test 2 (calls on real phones), written in advance, every `Result` cell `NOT RUN` |

## Counters

| Counter | Value |
| --- | --- |
| Accounts this branch created on the hosted alpha | `hosted_registrations: 0` |
| Contacts with the hosted server | one TLS handshake, no HTTP request, no POST, no registration |
| Physical phones involved so far | none |
| Simulator devices used | iPhone 17 Pro and iPhone 17e, both on iOS 26.5 |

The counter moves only with an explicit owner "go" for that specific
registration, whose permalink is written here beside it. RFC-0021 question 4
was answered on 2026-09-13 — **as many accounts as the tests need, no fixed
budget** — which sets a budget, not an authorisation: each registration still
needs its own "go", and each is counted here because the server has **no
account-deletion path** and every registration is permanent.

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
checks, and it re-passed at this head.

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
| 24 | archive and export | owner signing gate | **skipped** | 0 | `Archive skipped: PARANOID_IOS_TEAM_ID unset` — no signing material exists on this machine and none was created |

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

Every run above used the local stand — the **unchanged** server binary against
a private PostgreSQL 16 on the build Mac — or no server at all, with one
exception: row 4 is the single TLS handshake to the hosted alpha. That
handshake sent no HTTP request, created no account and is the only contact this
branch has had with the hosted server; it is the contact the **Counters** table
at the top of this file records.

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
| Android reference for the source cross-check | `fe9c26cb4824…` (v15 plus the two classes that moved past it on `main`: call-v2 video and the push wake gateway) | `java-host.json` |
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
| `clients/ios/out/evidence/app-bundle.json` | 2026-09-13T14:40Z | 3585 | `17bcc1748f14d00a245e7589558acd8cb9ee0c84e9af4e4e5cdbd9fdaf193667` | test_app_bundle.py: the unsigned Release bundle taken apart (Info.plist, embedded WebRTC slice, notices, no simulator slice) |
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
| `clients/ios/out/evidence/hosted-preflight.json` | 2026-09-13T08:06Z | 615 | `6fea521e5b880d34c7e55bcdeb4400fbb4a6848e99337701193b756398255b03` | one TLS handshake to the hosted alpha and nothing else: the live SubjectPublicKeyInfo digest equals the pin this client carries, the renewed leaf is valid to 2026-12-12, and the registration counter is zero |
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
the story in half.

| Set | Count | What is in it |
| --- | --- | --- |
| `clients/ios/out/evidence/voice-sim/` | 32 | the two-simulator call run: welcome, identity, pairing confirmation, contacts, «Сервер подключён», then per call the caller prompt, outgoing, connected, held, ended and a mid-call frame — for both the iPhone 17 Pro (`a-*`) and the iPhone 17e (`b-*`) |
| `clients/ios/out/evidence/sim-text/` | 17 | the text run on one simulator: welcome, identity, add contact, paste, fingerprint confirmation, contacts, chat, sent, delivered, double tap, details, blocked, unblocked, renamed, default name, and the two frames after a reinstall |

## NOT RUN

Nothing below has evidence, and none of it is waiting on a decision this client
can take. The full requirement-level table is
[verification.md](../../../clients/ios/verification.md); this is the list a
reviewer should hold the pull request to.

| Not run | Why |
| --- | --- |
| Anything at all on a physical iPhone | No signed build exists: no App ID without the push capability, no owner "go" for an install, and the export-compliance gate is closed. Every row below follows from this one |
| The two joint tests with the owner | [stage1-text.md](stage1-text.md) and [stage2-voice.md](stage2-voice.md) are written in advance and every `Result` cell reads `NOT RUN` |
| Registration on the hosted alpha | No owner "go". The server cannot delete an account, so a registration is permanent; the counter above stays at zero until such a "go" is given and recorded here with its permalink |
| Interoperability with the Android client **on its own hardware** | The protocol comparison did run, and it is `CLAIMED`, not `SHOWN`: both stacks were processes on this Mac (gates 11 and 12). No Android build on a phone has spoken to this client, over any network. Stage 2 of the joint tests is where that happens |
| The unpaired first-contact story with an Android peer | `test_android_compatibility.py` pairs both sides before the first text, so REQ-MSG-005 across the two clients is untested; between two instances of this client it is covered by `test_clean_self_service.py` |
| The Data Protection class of the state file | A simulator has no Data Protection and reports no protection class |
| A QR code read off a real camera | Simulators pair by pasting the contact text; `AVCaptureSession` has no camera to open |
| A real screen recording, AirPlay or a wired mirror over the call stage | No simulator can start one; the cover is verified source-only |
| Screen lock during dialling or during a call | `xcrun simctl` exposes no lock verb and `XCUIDevice` has no lock API; recorded with that reason inside `voice-sim-result.json` |
| A call over a real network, and any relayed call | Both simulators were on one Mac over loopback and the stand starts no TURN, so `/v2/voice/turn` answered `404 turn_disabled` and every pair that carried a call was `host` to `host` |
| Audio actually heard, or a camera image actually seen | Nothing was decoded to a speaker and no camera exists; the measurement is RTP packet counters |
| A signed build, an archive, an export | `PARANOID_IOS_TEAM_ID` is unset and no signing material exists on this machine; `build.sh` skips that gate out loud |
| A TestFlight build, internal or otherwise | The [export-compliance gate](../../../clients/ios/export-compliance.md) is closed: `ITSAppUsesNonExemptEncryption = YES` is prepared, not satisfied, and Apple applies the requirement to TestFlight too |
| `.github/workflows/ios.yml` on a runner | It lands with this pull request; its first execution is that pull request. Every check in it was run locally instead, with exit 0. There is no macOS runner (RFC-0021 question 6, answered "no") |
| Independent **human** review of identity, cryptography, persistence and application security | Not available to the contributor. The closed-alpha exception permits an independent AI review in a fresh context, recorded separately (plan step 46) |

## The owner's decisions, by permalink

Only what is recorded on GitHub counts here. A decision that is not in this
table has not been given, whatever a local note may say.

| Decision | Date | Permalink | What it does **not** cover |
| --- | --- | --- | --- |
| Delegation of technical decision authority to the contributor | 2026-09-13 | <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919> | it does not waive independent review, does not replace evidence, is not closed-alpha scope approval and is not ADR acceptance; no live action follows from it |
| Answer to RFC-0021 question 5 (`404 turn_disabled` permits the disclosed direct-ICE mode) and question 10 (a docs-only pull request for the factual corrections) — by the owner's agents | 2026-09-12 | <https://github.com/GOTD-GLOBAL/ParanoID/issues/27> | it covers those two questions only |

Still missing, each one a separate "go" that has not been given: closed-alpha
scope approval, ADR-0014 acceptance, opening the pull request, installing a
signed build on a phone, every hosted registration, and TestFlight
distribution.

## Before either joint test may run

1. An explicit owner "go" for that specific live action, with a permalink
   recorded in the evidence file beside the result.
2. A signed build installed on the contributor's iPhone. That needs an App ID
   without the push capability and the Apple team; the
   [export-compliance gate](../../../clients/ios/export-compliance.md) is
   separate and blocks TestFlight distribution specifically.
3. For stage 1, a hosted registration for each iPhone identity the test needs.
   RFC-0021 question 4 sets no fixed budget, so the limit is the "go" of item 1
   and not a number; every registration is counted in this file and none can be
   deleted afterwards.
4. For stage 2, an Android build of **v16 or later** on the owner's phone:
   call-v2 rejects v1 call bodies, so an older build can exchange text with
   this client but cannot call it.

## Recording rules

- Each row is filled in with what happened, not with what was expected. A step
  that behaves differently is recorded as `FAILED` with the observed behaviour;
  a step that was skipped stays `NOT RUN` with the reason.
- A simulator result never becomes a phone result by being copied into this
  directory. Simulator and local-stand runs are `CLAIMED` in
  [verification.md](../../../clients/ios/verification.md); only a phone makes a
  row `SHOWN`.
- Screenshots are taken on both phones for any row whose result is visual, and
  are named by the step number.
- No account identifier, contact fingerprint, realm, pin, credential or
  snapshot byte is written into this directory, and no address or hostname of
  the build Mac. Counts, verdicts, versions and digests only.
- The foreground-only limitation is **expected behaviour**, not a failure: a
  call placed to a locked or closed iPhone ends in the caller's 45-second
  `timeout`, and that is written into stage 2 in advance.
