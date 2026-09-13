---
status: draft
owner: ios
last_reviewed: 2026-09-13
---

# iOS client verification: requirement-to-test mapping

Validation plan for [RFC-0021](../../rfcs/0021-ios-client.md) and
[proposed ADR-0014](../../decisions/0014-ios-client.md), and the honest status
of the client pull request. Every row says what was **actually run**, on what,
and what was not. Under the
[closed-alpha policy](../../governance/documentation-policy.md#closed-alpha-review-exception)
item 4, acceptance criteria for delivered behaviour must actually pass and
missing phone evidence cannot be replaced by a simulator or a dependency build.

**Nothing in this client has run on a physical phone. No row is `SHOWN`.** No
hosted account exists (`hosted_registrations` is zero) and the only contact
this branch has had with the hosted server is one TLS handshake that compared
the live SubjectPublicKeyInfo digest against the pin this client carries.

## Status vocabulary

- `NOT RUN`: no evidence exists. Every such row names its reason.
- `CLAIMED`: passed on the simulator, the host or the local stand — the
  unchanged server binary plus a private PostgreSQL 16 on the build Mac. It is
  not phone evidence and never becomes phone evidence.
- `SHOWN`: passed on a physical iPhone in a joint test with the owner, with the
  evidence file and the owner "go" permalink recorded.
- `FAILED`: run and failed; the failure is kept, not hidden.

Only `SHOWN` counts toward the acceptance of
[REQ-CLIENT-001](../../product/requirements.md) on the hosted alpha. The two
joint tests are written in advance, with every `Result` column reading
`NOT RUN`:
[stage1-text.md](../../project/evidence/ios-client-20260913/stage1-text.md) and
[stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md).

## Requirements

| Requirement | What must hold for iOS (source) | What was actually run | Status |
| --- | --- | --- | --- |
| REQ-CLIENT-001 | Supported clients include iOS ([requirements](../../product/requirements.md)) | A Release build for a device links and passes the bundle gate **unsigned** (`test_app_bundle.py`, `CLAIMED`). No build has been signed, installed on an iPhone or uploaded to TestFlight: there is no App ID, no owner "go" and the export-compliance gate is closed | NOT RUN |
| REQ-ID-005 | Identity created on the phone with locally owned keys and automatic proof-of-possession, no operator or bearer ([self-service v2](../../protocol/self-service-v2.md)) | `test_clean_self_service.py --registration-only` on the local stand: `create_identity` then `upgrade_v2`, two durable commits before any request, registration to `enrollment.mode == "active"`, a 64-digit contact fingerprint and a core-validated session; repeating both operations commits nothing. The application itself does the same through «Создать ID» in `test_sim_text.py`. No hosted registration | CLAIMED |
| REQ-ID-007 | Contacts added only through explicitly verified QR key bindings ([first-contact v1](../../protocol/first-contact-v1.md)) | `QrTests` round-trips the core's own ~900-byte contact through the encoder and back byte-identically, refuses 2049 bytes and lets the core refuse a tampered contact; in `test_sim_text.py` the application shows its own QR and pairs the peer by **pasting** that peer's contact text and confirming «Отпечаток совпадает». A code read off a real camera is a device action and did not happen | CLAIMED |
| REQ-ID-008 | Self-service registration on the common server without approval or a transferred code ([self-service v2](../../protocol/self-service-v2.md)) | `test_ui_contract.py` reads the screens: no operator, grant, role, invitation or manual URL/pin form exists. Registration completes on the local stand with no out-of-band step | CLAIMED |
| REQ-MSG-002 | 1:1 E2EE text through one server with persistent history, reconnect and no duplicate display ([realtime v1](../../protocol/realtime-v1.md)) | `test_clean_self_service.py` (two independent clients on one stand: texts both ways, exact retry of an answer lost after commit adds no row, `psql` proves every stored row is frame-2 ciphertext and no plaintext appears in any table), `--longpoll` (300 s across the server's idle, socket-lifetime and renewal bounds with no failure published), `test_realtime.py` (injected transport faults), and `test_sim_text.py` (the application: one bubble per tap on a double tap). Both sides were this client; no Android peer and no real network | CLAIMED |
| REQ-MSG-003 | One check means durable server acceptance, two mean recipient delivery, not reading ([first-contact v1](../../protocol/first-contact-v1.md)) | Same runs: `✓` appears only after `{id, sequence >= 1}` was committed, `✓✓` only after the peer's authenticated receipt, and no read receipt exists anywhere in the source (`test_ui_contract.py`) | CLAIMED |
| REQ-MSG-005 | First-contact text appears immediately as an unverified conversation on a receiver with zero contacts, reply enabled, no scan or approval ([first-contact v1](../../protocol/first-contact-v1.md)) | `test_clean_self_service.py`: the receiver, which scanned nothing, shows the conversation as `network_unverified` and replies without pairing; both directions end double-checked. Between two instances of this client — the Android direction of the same story is untested | CLAIMED |
| REQ-CALL-002 | Real 1:1 encrypted audio (and, under call-v2, camera video) over a mature WebRTC engine ([voice scope](../../product/voice-calls.md), [call-v2](../../protocol/call-v2.md)) | `test_voice_sim.py`: two simulators on one local stand, two calls one each way, both peers reach `RTCPeerConnectionState.connected` over direct ICE (`host` to `host`, nothing relayed), each call held 40 s with about 2300 RTP packets received and sent per side and four heartbeat envelopes stored per account per hold. **No audio was decoded to a speaker, no camera saw a face and nothing crossed a real network** | CLAIMED |
| REQ-CALL-003 | Signaling binds immutable account/device/realm/channel, fresh call identity and media fingerprint/ICE context ([voice v1](../../protocol/voice-v1.md), [call-v2](../../protocol/call-v2.md)) | `SdpCompatibilityTests`: libwebrtc's own offer, answer and one `media` control pass the **unchanged core validator** between two synthetic identities, with `v: 2` and a boolean `video` in every body, and a fourteen-member v1 body is refused as `invalid_request`. `CallControllerTests` (23 tests on a fake clock) and `test_call_controller_parity.py` (`labels: 94/94 covered`) measure the state machine against the Android smoke scenarios. The SDP is never rewritten | CLAIMED |

## Platform checks without a requirement identifier

These accompany the rows above and never substitute for them.

| Check | What was actually run | Status |
| --- | --- | --- |
| Core compiles and links for `aarch64-apple-ios` without changes | `build-core.sh` builds the bridge for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-apple-darwin` and combines three single-architecture `arm64` archives into `ParanoidCore.xcframework`; `BridgeSmokeTests` runs `create_identity` → `upgrade_v2` inside the application on the simulator. The core was not modified | CLAIMED |
| Pinned TLS: nine leaf checks on DER fixtures (wrong pin, CA chain, expired, corrupted signature, wrong SAN) and the socket rules | `check-pinned-tls.py` and `test_realtime_transport.py` against real loopback servers, plus `PinnedTrustTests` / `X509LeafTests`; offline, no hosted contact | CLAIMED |
| The pin this client carries is the live one after the owner's same-key renewal | One TLS handshake from the build Mac, no HTTP request: the live SubjectPublicKeyInfo digest equals the compiled pin, and the renewed leaf is valid to 2026-12-12T07:38:09Z. Recorded locally in `out/evidence/hosted-preflight.json` with `hosted_registrations: 0` | CLAIMED |
| Storage: commit order and injected faults; the install-marker matrix | `SnapshotStoreTests` fails each of the five durable steps in turn; `KeychainStoreTests` (signed simulator run) reads the stored attributes back and drives the marker matrix. The Data Protection **class** the write asks for cannot be observed in a simulator | CLAIMED |
| Component boundary: no committed diff outside the allowlist | `test_component_boundary.py` against the pull-request base | CLAIMED |
| Call scenario parity: every `check(…, "<label>")` of the Android `CallControllerSmoke` is named by an iOS assertion | `python3 clients/ios/test_call_controller_parity.py` → `labels: 94/94 covered`, over the scenarios `swift test --filter CallControllerTests` runs. It says the scenarios match, not that the media does; REQ-CALL-002/003 still need `stage2-voice.md` | CLAIMED |
| Call timers and terminal reasons: the 45/30/10/900-second deadlines with the reason each one ends on, the ten-second heartbeat with one outstanding at a time and numbered from `seq` 2, the five-second clock tolerance, the knock ceilings, the bounded terminal table and the `end` every terminal path does or does not send | `swift test --filter CallControllerTests` → 23 tests on a fake clock, no network; it says what the state machine decides, not what the media does | CLAIMED |
| TURN credential lane: a live session is required and never downgraded on failure; a valid authenticated 404 from the pinned origin is the only answer that permits the pre-disclosed direct-ICE mode; the first ambiguous 401 is signed again exactly once; the optional route discards neither the text session nor the discovery timestamp; the credentials never reach the snapshot ([voice TURN v1](../../protocol/voice-turn-v1.md)) | `python3 clients/ios/test_voice_relay_lane.py --evidence-dir out/checks/voice-lane` → `7/7 PASS, signature verified` over a real pinned loopback socket, with `clients/ios/test/turn_stub.py` verifying the client's Ed25519 session signature itself; plus `swift test --filter VoiceRelayLaneTests` (12 tests, no socket). It says what the lane decides, not that any media flowed: REQ-CALL-002 still needs `stage2-voice.md`, and no TURN server was involved | CLAIMED |
| Media engine publication: the one local description of a call leaves the device exactly once; the relay lane publishes only after a usable component-1 UDP `typ relay` IPv4 candidate (500 ms coalescing, or gathering complete) and never without one; the direct lane only at gathering complete and never on an empty `complete`; a description above the 9000-byte frame budget or outside the call-v2 shape is refused instead of rewritten ([call-v2](../../protocol/call-v2.md)) | `xcodebuild test -only-testing:ParanoIDTests/SdpPublishGatingTests` → 16 tests: ten drive `WebRtcAudioEngine.PublicationGate` with a fake candidate feed, four run the real engine in the simulator and two measure the configuration and the codec preferences (one offer of about 3.8 kB with 6 candidates and no second publication; a relay-only engine with nothing answering publishes nothing in 8 s; the camera refusals). It says when a description may be sent, not that any media flowed | CLAIMED |
| Call consent and the audio session: the privacy sentence stands before «Позвонить» and before «Ответить» and nowhere after; the microphone is requested only from an explicit Call or Answer and a refusal tells the peer, the user and nobody else; the audio session is running before the first `knock` and libwebrtc stays silent until `connected`; the intent waits ten seconds for a confirmed online lane and then says so, and an intent cancelled by a newer one never takes that one's session away; the camera is opened by «Включить камеру» or an explicit video-call intent alone and a refusal downgrades the call to audio without changing any section's direction ([voice v1](../../protocol/voice-v1.md), [call-v2](../../protocol/call-v2.md)) | `python3 clients/ios/test_ui_contract.py` → `OK` (20 tests, offline and source-only): the caption contract plus eight call rules read out of `AppModel`, `CallCoordinator`, `AudioSessionController`, `CallScreen` and the chat toolbar — including the screen rule (`isIdleTimerDisabled` follows either camera; the proximity sensor follows only this device's camera and only once the call is `connected`, as in Android's `!speaker && connected && !videoEnabled`, so a ringing call never blanks the screen; the one deliberate difference — this client keeps the sensor through a reconnection where Android releases it — is written down in `AudioSessionController.audible`), the intent-ownership rule, the call-identifier re-check on a refused microphone (a permission dialog can outlive its 45-second ring) and the re-activation of a session an interruption took away while the call was still ringing; plus `xcodebuild test -only-testing:ParanoIDTests/CallAudioSessionTests` → 5 tests on the real `RTCAudioSession` in the simulator. Together they say what the client is wired to do and what the platform does with it, not that any call connected | CLAIMED |
| Call screen capture protection, and what is **not** protected: Android puts `FLAG_SECURE` on the call window alone (`MainActivity.java:478`, Android v16), which takes it out of screenshots, screen recordings and mirroring. iOS has no equivalent flag, so this client covers the video stage — and only the stage, so the call stays operable — while `UIScreen.isCaptured` reports a recording, AirPlay or a wired mirror. A **screenshot** cannot be refused on iOS (there is no API; a client only learns afterwards) and the **app-switcher snapshot** the system takes as the application leaves the screen is not covered either. Both are open gaps of this port, not parity | `python3 clients/ios/test_ui_contract.py` → `OK`: the `FLAG_SECURE` line is read out of `MainActivity.java` and the cover, its notification and its caption «Видео скрыто: идёт запись или трансляция экрана.» out of `CallScreen.swift`. Source-only: no simulator can start a screen recording | CLAIMED |
| Two simulators on one call: each phone registers on the local stand, pairs the other by the fingerprint that phone's own core published and says «Сервер подключён»; one calls, the other answers, and **both** reach `RTCPeerConnectionState.connected`; the media carries RTP in both directions; the call outlives the 30-second silence deadline on the peer's ten-second heartbeat; «Завершить» ends it on both sides; and the same call again in the other direction ([call-v2](../../protocol/call-v2.md)) | `python3 clients/ios/test_voice_sim.py --evidence-dir out/evidence/voice-sim` → `Voice (two simulators, direct ICE): PASS`: two `xcodebuild test-without-building` processes drive `ParanoIDUITests/VoiceCallUITests` on `iPhone 17 Pro (26.5)` and `iPhone 17e (26.5)` at once, each uninstalled first, against the unchanged server on a private PostgreSQL 16 cluster that starts no TURN — so `/v2/voice/turn` answers `404 turn_disabled`, the disclosed direct-ICE mode, and the pair that carried every call is `host` to `host` with nothing relayed. Two calls, one each way, each held 40 s with about 2300 RTP packets received and sent on both sides, with 32 screenshots beside the JSON. It says two applications on one Mac negotiated, connected and carried packets to each other, not that a person heard anything | CLAIMED |
| WebRTC dependency: archive and slice digests, bundled notices | `webrtc_dependency.py` re-extracts the pinned `150.7871.01` archive and `test_webrtc_dependency.py` measures the digest, slice and re-extraction rules; `notices.py` / `test_notices.py` bundle the licence texts and fail a linked crate without one; `test_app_bundle.py` weighs the embedded framework of an unsigned bundle against the pinned slice | CLAIMED |
| Reinstall on the simulator starts a new identity; marker-present missing file freezes | `clients/ios/test_sim_text.py::reinstall`: `xcrun simctl uninstall` keeps the Keychain item (counted in the device's own keychain database on both sides) and takes the container, and the next launch creates a new account instead of freezing — `sim-text-result.json` plus the `20-`/`21-` screenshots; the two freezing rows of the marker matrix stay with `ParanoIDTests/KeychainStoreTests` | CLAIMED |

## What has not run, and why

Each of these is `NOT RUN`. None of them is waiting on a decision this client
can take.

| Check | Why it has not run |
| --- | --- |
| Anything on a physical iPhone | No signed build exists: no App ID without the push capability, no owner "go" for the install, and the export-compliance gate is closed. Everything below this line follows from it |
| Data Protection class of the state file | A simulator has no Data Protection and reports no protection class. The class the write asks for can only be observed on a device |
| A QR code read off a real camera | Simulators pair by pasting the contact text; `AVCaptureSession` has no camera to open |
| A real screen recording covering the call stage | No simulator can start a screen recording, AirPlay or a wired mirror |
| Screen lock during dialling or during a call | `xcrun simctl` exposes no lock verb and `XCUIDevice` has no lock API; the reason is recorded in the voice evidence beside the two calls that did run |
| A call over a real network (LTE, Wi-Fi, NAT), and any relayed call | Both simulators were on one Mac over loopback, and the stand starts no TURN server. Every call so far was `host` to `host` |
| Audio actually heard, or a camera image actually seen | Nothing was decoded to a speaker and no camera exists; the measurement is RTP packet counters |
| Interoperability with the Android client | The only peers this client has talked to are other instances of itself and the host fixture built from the same Swift sources. The Java client is a **source-level** cross-check in [protocol-sources.md](protocol-sources.md); at the revision this table was written it had not been executed against this client |
| The iOS ↔ Android cross-test comparison (`test_android_compatibility.py`, `test_qr_cross.py`) | Those two scripts have not landed, so `build.sh` prints `SKIP:` with that reason for the comparison (plan step 34) and the build manifest records `skipped`. It is not a silent pass. Its host side, `java_deps.sh` (plan step 33), is a different matter: it is present in the working tree but untracked at this revision (`c2fdcc0`), and `build.sh` gates that step on the file being there, so the Java host did build and the manifest records that gate `ok` — from an uncommitted file. The comparison itself still did not run. If those scripts land before the pull request is opened, this row carries their actual result instead of this reason |
| Registration on the hosted alpha | No owner "go"; the server has no account-deletion path, so a registration is permanent. `hosted_registrations` is zero |
| A TestFlight build, internal or otherwise | The [export-compliance gate](export-compliance.md) is closed: `ITSAppUsesNonExemptEncryption = YES` is prepared, not satisfied, and Apple applies the requirement to TestFlight as well |
| The `ios-static` workflow actually running in continuous integration | `.github/workflows/ios.yml` lands with this pull request and has never executed on a runner; its first run is that pull request. Every check it contains was run locally on the pinned build Mac with exit 0 — twelve of its thirteen `run` commands, and that is what the rows above record; the thirteenth is the `rustup toolchain install` setup line, which was not re-run on a Mac that already pins 1.98.1. There is still no macOS runner (RFC-0021 question 6, answered "no"), so nothing needing Xcode, a simulator or the local stand can run there at all |
| Independent human review of identity, cryptography, persistence and application security | Not available to the contributor; the closed-alpha exception permits an independent AI review in a fresh context, which is recorded separately in the pull request and is not a human audit |

## Joint tests with the owner

Both are live actions and both wait for an explicit owner "go" whose permalink
goes into the evidence directory beside the result. The scenarios are written
in advance so that the result cannot be shaped after the fact, and every
`Result` cell in them reads `NOT RUN`:

- [stage1-text.md](../../project/evidence/ios-client-20260913/stage1-text.md):
  registration, QR in both directions, text and receipts, block and unblock,
  cold start, screen lock, LTE and Wi-Fi.
- [stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md):
  calls in both directions with both applications open, the **expected**
  45-second `timeout` when the iPhone is locked or closed, lock during ringing
  and during a call, mute and speaker, the camera, a real screen recording, and
  hang-up from each side.

Stage 2 needs an Android build of **v16 or later** on the owner's phone:
call-v2 rejects v1 call bodies, so an older build can exchange text with this
client but cannot call it.
