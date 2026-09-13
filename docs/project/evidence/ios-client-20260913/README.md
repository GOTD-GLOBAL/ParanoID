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
| [artifacts.json](artifacts.json) | the same catalogue for machines: 28 artifacts and 49 screenshots, each with path, bytes, SHA-256 and the time it was produced |
| [stage1-text.md](stage1-text.md) | joint test 1 (text and QR on real phones), written in advance, every `Result` cell `NOT RUN` |
| [stage2-voice.md](stage2-voice.md) | joint test 2 (calls on real phones), written in advance, every `Result` cell `NOT RUN` |

## Counters

| Counter | Value |
| --- | --- |
| Accounts this branch created on the hosted alpha | `hosted_registrations: 0` |
| Contacts with the hosted server | one TLS handshake, no HTTP request, no POST, no registration |
| Physical phones involved so far | none |
| Simulator devices used | iPhone 17 Pro and iPhone 17e, both on iOS 26.5 |

The counter changes to `1` only in plan step 50, together with the permalink of
the owner's authorisation for that single registration. The server has **no
account-deletion path**, so every registration is permanent and is counted here.

## The revision this catalogue describes

| Fact | Value |
| --- | --- |
| Branch | `feat/ios-client-20260911` |
| Head at catalogue time | `c2fdcc05d242a50f57be72e9947dfe5edeed1249` |
| Merge base with `origin/main` | `2cdb850ca532fd281986e792efb164e150c0a30c` |
| Committed files changed against that base | 163 |
| Committed files outside the iOS allowlist | 0 |
| Uncommitted paths in the working tree when the catalogue was built | 23, all inside the same allowlist. 17 are the documents of plan steps 44–47 and one is the two `docs.yml` exclude lines beside them; the remaining five are code, not documents: `.github/workflows/ios.yml` (step 45), `clients/ios/build.sh`, `clients/ios/notices.py`, and the Java host of the cross-test — `clients/ios/java_deps.sh` with `clients/ios/test/java/` |

The boundary gate reads committed changes only and says so out loud; the
uncommitted set was checked separately against the same allowlist and is also
clean. Nothing in this branch touches `server/`, `clients/core/src/`,
`clients/android/`, `key-protocol/` or `deploy/`.

## Command → result

### Run for this step on 2026-09-13, exit 0 observed

| Command | Result |
| --- | --- |
| `bash clients/ios/build.sh` | `OK: 20 step(s) passed, 2 skipped: iOS <-> Android cross-test (plan step 34); archive and export` — the 22 gates below |
| `python3 clients/ios/test_component_boundary.py` | `PASS: 163 files changed, 0 outside allowlist` (`note: 23 uncommitted change(s) are not part of this gate`) |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm` | `Executed 242 tests, with 0 failures (0 unexpected)` |
| `npx markdownlint-cli2@0.18.1 "docs/project/evidence/ios-client-20260913/README.md"` | 0 findings for this file |
| `grep -c` for the registration counter over `docs/project/evidence/ios-client-*/README.md` | `1` — the counter is written once, in the table above, and nowhere else in this file |

These commands were run twice: once when this catalogue was first written, and
again at 14:29–14:34Z after two false sentences — one in this file, one in
[verification.md](../../../clients/ios/verification.md) — were corrected. Both
runs printed what the table above says. The gate times and the digests further
down belong to the second run, because `build.sh` overwrites its own output.

### The 22 gates inside that `build.sh` run, in order

`status` and `seconds` are the script's own record
(`clients/ios/out/logs/build-steps.tsv`); a skipped gate says why and is never
counted as a pass.

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
| 9 | Android cross-test (Java host) | `bash java_deps.sh` | ok | 1 | the Java facade compiled against the shared core; `java_deps.sh` is in the working tree but **untracked at `c2fdcc0`**, so this gate ran from an uncommitted file |
| 10 | iOS ↔ Android comparison | plan step 34 | **skipped** | 0 | `test_android_compatibility.py` and `test_qr_cross.py` have not landed; the comparison itself did **not** run and did **not** pass |
| 11 | pinned TLS handshakes | `python3 check-pinned-tls.py` | ok | 3 | nine leaf cases against real loopback servers; seven rejected before any HTTP request |
| 12 | realtime transport rules | `python3 test_realtime_transport.py --evidence-dir out/checks/transport` | ok | 34 | the eight transport rules against the fake server |
| 13 | third-party notices | `python3 notices.py --offline` | ok | 0 | the notices that ship inside the bundle |
| 14 | notices rules | `python3 test_notices.py` | ok | 1 | `PASS: 30 tests` |
| 15 | UI contract | `python3 test_ui_contract.py` | ok | 0 | `Ran 20 tests … OK` (source-only: captions, call rules, `FLAG_SECURE` comparison) |
| 16 | call scenario parity | `python3 test_call_controller_parity.py` | ok | 0 | `labels: 94/94 covered (93 verbatim, 1 embedded)` |
| 17 | component boundary | `python3 test_component_boundary.py` | ok | 0 | `PASS: 163 files changed, 0 outside allowlist` |
| 18 | simulator tests (unsigned) | `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' … -skip-testing:ParanoIDTests/KeychainStoreTests` | ok | 25 | `ParanoIDTests`: 34 tests, 0 failures — `BridgeSmokeTests`, `CallAudioSessionTests`, `QrTests`, `SdpCompatibilityTests`, `SdpPublishGatingTests` (16); `ParanoIDUITests`: 4 tests of which **3 skipped** — the text and call scenarios only run from `test_sim_text.py` / `test_voice_sim.py`, which are the two rows below |
| 19 | simulator Keychain tests | `xcodebuild test … -only-testing:ParanoIDTests/KeychainStoreTests` | ok | 6 | 8 tests, 0 failures; the only run where the application owns a Keychain (ad-hoc simulator signature, no team) |
| 20 | device build (Release, unsigned) | `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | ok | 6 | `out/ParanoID.app`, `global.paranoid.messenger` 0.0.1 (1) |
| 21 | application bundle | `python3 test_app_bundle.py out/ParanoID.app` | ok | 1 | `PASS: 24 checks (1 skipped)`; the skipped one is the Team ID, which needs a signed bundle |
| 22 | archive and export | owner signing gate | **skipped** | 0 | `Archive skipped: PARANOID_IOS_TEAM_ID unset` — no signing material exists on this machine and none was created |

### Runs kept from earlier in this branch, not repeated for this step

Each one wrote the artifact named beside it; the digest of that artifact is in
the table further down, so the file a reviewer is pointed at is the file that
run produced.

| Command | Run (UTC) | Result | Artifact |
| --- | --- | --- | --- |
| `python3 clients/ios/test_voice_sim.py --evidence-dir out/evidence/voice-sim` | 2026-09-13T12:15Z | `PASS` — two simulators, two call-v2 calls one each way, both sides `connected` over direct `host`-to-`host` ICE, ≈2300 RTP packets received and sent per side per call, 40 s held, four heartbeat envelopes per side per hold | `voice-sim-result.json` + 32 screenshots |
| `python3 clients/ios/test_sim_text.py --evidence-dir out/evidence/sim-text` | 2026-09-13T12:12Z | `PASS` — identity, QR paste, pairing, text both ways, receipts, block/unblock, contact names, reinstall | `sim-text-result.json` + 17 screenshots |
| `python3 clients/ios/test_voice_relay_lane.py --evidence-dir out/checks/voice-lane` | 2026-09-13T08:38Z | `7/7 PASS, signature verified` — nine signed requests, nine signatures verified by the stub | `voice-relay-lane.json` |
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

## Versions

| Component | Version | Where it was read |
| --- | --- | --- |
| Xcode / build | 26.6 / 17F113 | `toolchain.json`, `build-manifest.json` |
| iOS SDK | 26.5 | `toolchain.json` |
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

| Artifact (git-ignored) | Produced (UTC) | Bytes | SHA-256 | What it says |
| --- | --- | --- | --- | --- |
| `clients/ios/out/evidence/build-manifest.json` | 2026-09-13T14:31Z | 8052 | `40e9d377dbfcd455633bc35069829743c5e8cb6a2e09507f44f1a3451f59f7db` | build.sh manifest: every gate with status and seconds, the toolchain versions, the bundle identity and the digests of the built binaries |
| `clients/ios/out/logs/build-steps.tsv` | 2026-09-13T14:31Z | 2106 | `6a569a5156e99cd41c86943f01ed9962ac484c403eb2ffda992e3b3a0689b32d` | the same run as a tab-separated step log (name, status, seconds, command) |
| `clients/ios/out/step47/build-sh.log` | 2026-09-13T14:34Z | 351569 | `1345f2371aacd9876878fa0c3cf1653fcf4cce7412ae0906165332886cbab64e` | full console output of the build.sh run of step 47 |
| `clients/ios/out/evidence/bridge-hashes.json` | 2026-09-13T14:29Z | 2125 | `6833e73d3cd9b989a7a02b7106fb6e2a887942caf9896d04c2e82548ea1614bb` | build-core.sh manifest: the three release slices, the xcframework, the header digests and the bridge lock digest |
| `clients/ios/out/evidence/bridge.json` | 2026-09-11T20:24Z | 4482 | `e01ada5545552a524539645f93fb7e895be88aeb2039582826fbee902d672ca5` | plan steps 5-6, kept as it was written: the first compile of the unchanged core and key-protocol for aarch64-apple-ios, with the red-zone stop gate not tripped |
| `clients/ios/out/evidence/toolchain.json` | 2026-09-13T14:29Z | 1009 | `96e0f9661548482c044b9032faba4111e09884dc3f5119f3d9354ad5e030703b` | test_toolchain.py: pinned versus observed toolchain, with the members it could not observe listed as skipped |
| `clients/ios/out/evidence/app-bundle.json` | 2026-09-13T14:31Z | 3585 | `dbda113125710f9ab83fdbf88a94a95ce297bc995cd49e04dca9a3b1a7a6b760` | test_app_bundle.py: the unsigned Release bundle taken apart (Info.plist, embedded WebRTC slice, notices, no simulator slice) |
| `clients/ios/out/evidence/pinned-tls.json` | 2026-09-13T14:03Z | 2366 | `1e0c3fb4975717bc25a321eed504c6b680bc818a8a4edd7bb5ca0c3ad49e195a` | check-pinned-tls.py: nine leaf cases against real loopback servers, what was rejected before any HTTP request, and the TLS floor |
| `clients/ios/out/checks/transport/realtime-transport.json` | 2026-09-13T14:30Z | 22680 | `6050eedc28837f88d3af851c19297b317d9063fe25327ea5b2dd1c774d94f3ae` | test_realtime_transport.py: the eight transport rules against the fake server, with the server-side record of connections, resets and idle closes |
| `clients/ios/out/checks/voice-lane/voice-relay-lane.json` | 2026-09-13T08:38Z | 9213 | `3c46aa18e8007b6e13abd84cf843c44188a53d87b5d844e66c2ec8d323cf9d89` | test_voice_relay_lane.py: seven TURN-lane scenarios over a pinned loopback socket, with nine client signatures verified by the stub |
| `clients/ios/out/evidence/qr-20260912/qr-round-trip.json` | 2026-09-12T19:07Z | 1902 | `5846ecff3a774f51d7b7aa363ddd76b704033509355d2b86466ef6e7ba800319` | QR round trip: the core contact through the generator and back byte-identically, with the size limits and what was not run |
| `clients/ios/out/evidence/storage-20260912/summary.json` | 2026-09-12T07:22Z | 3480 | `939158ba3ad406eae4f987e0969b20326fc7ddef1dc292b5f2b7777fa81ea19f` | storage commit order and the injected-fault matrix |
| `clients/ios/out/evidence/snapshot-codec-20260912/run.json` | 2026-09-12T06:59Z | 1762 | `646236f70904c5bb5d823e65e2d05a55c2b408fd6e83f9e2deff1c75014fab65` | snapshot codec run: what the state file holds and how it is read back |
| `clients/ios/out/evidence/swift-corebridge.json` | 2026-09-11T20:55Z | 2766 | `2927d3bfc97cb3fb4f8bb239dfa7baf6859b788c4b4a9b927e75b0950ed7d7e1` | the Swift side of the C-ABI bridge measured against the core |
| `clients/ios/out/evidence/sdp-spike.json` | 2026-09-13T14:30Z | 12200 | `07aa35b8cfa9419d3763efa4fd2efcf07da1e3e02af4a1ddcabd6ed5473e0923` | the libwebrtc offer/answer spike the call-v2 validator was written against |
| `clients/ios/out/evidence/java-host.json` | 2026-09-13T14:29Z | 6039 | `956a9bcc24f24baebe86c352e8ea6b9c50ca66ab25953056ebb5b42411ae0896` | java_deps.sh: the Java facade compiled against the shared core for the cross-check, with the Android reference commit and the classes that are Android-only |
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
| Registration on the hosted alpha | No owner "go". The server cannot delete an account, so a registration is permanent; the counter above stays at zero until plan step 50 |
| The iOS ↔ Android protocol comparison | `test_android_compatibility.py` and `test_qr_cross.py` have not landed; `build.sh` prints the reason and records the gate as skipped. The Java host side did build (gate 9), from a file untracked at this revision |
| Interoperability with the Android client, on any level above source | The only peers this client has talked to are other instances of itself. `protocol-sources.md` is a source-level cross-check, not an executed one |
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
signed build on a phone, the single hosted registration, and TestFlight
distribution.

## Before either joint test may run

1. An explicit owner "go" for that specific live action, with a permalink
   recorded in the evidence file beside the result.
2. A signed build installed on the contributor's iPhone. That needs an App ID
   without the push capability and the Apple team; the
   [export-compliance gate](../../../clients/ios/export-compliance.md) is
   separate and blocks TestFlight distribution specifically.
3. For stage 1, exactly one hosted registration per iPhone identity, counted in
   this file.
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
