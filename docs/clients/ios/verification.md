---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# iOS client verification: requirement-to-test mapping

Validation plan for [RFC-0021](../../rfcs/0021-ios-client.md) and
[proposed ADR-0014](../../decisions/0014-ios-client.md), and the honest status
of the client pull request. Every row says what was **actually run**, on what,
and what was not. Under the
[closed-alpha policy](../../governance/documentation-policy.md#closed-alpha-review-exception)
item 4, acceptance criteria for delivered behaviour must actually pass and
missing phone evidence cannot be replaced by a simulator or a dependency build.

**A signed build ran on a physical iPhone on 2026-09-13, first against the
local stand and then against the hosted alpha.** An iPhone 16 Pro Max on
iOS 26.6.1, signed with team `5RPGVC566Q`, created an identity, showed its own
QR, read a contact off the build machine's screen with the real camera,
confirmed the fingerprint sheet, exchanged text in both directions with
receipts and placed a call that connected and carried video — all on the local
stand, from a Debug build. Those rows are `SHOWN`; evidence in
[the device session](../../project/evidence/ios-client-20260913/README.md).
Later that day a Release build signed with the same team registered on the
hosted server (after the App Transport Security fix, defect 4), paired the
owner's Android from the QR image he sent and sent one text the hosted server
accepted (one check). Delivery to the owner's Android was still pending: his
phone had not polled.

**On 2026-09-14 both joint tests were partly run, in one unscheduled session
on the hosted alpha.** Yaroslav scanned the owner's QR with the iPhone camera
and the contact was paired; text crossed both ways and both checks appeared on
the iPhone, the second being the acknowledgement of a real Android client and
the first time this client has seen it; the owner then called the iPhone from
his Android, Yaroslav answered and they spoke, and both sides turned their
cameras on. It is the first call this client has carried against the Android
client rather than a simulator, and the first picture it has received from a
real camera. The contributor is the only participant this record has: every
result of that session is **his report**, given immediately afterwards, and is
written `SHOWN (joint, reported)` rather than `SHOWN`. The session was not
planned, so no owner "go" permalink exists for it and none is inferred.
Everything the report does not cover stays `NOT RUN`, including the Android
side of the pairing and a call placed from this client to an Android. After the
session the iPhone stopped connecting and has not recovered; that failure is
measured in pull request #36 and is not a result of either stage.

Three hosted accounts exist (`hosted_registrations` is 3: one `service-bridge`
registration from the build Mac on 2026-09-13 to isolate the phone's TLS
failure, one from the physical iPhone on 2026-09-13 after the App Transport
Security fix, and one from the build Mac on 2026-09-14 while diagnosing
issue #38; all three under the owner's answer to RFC-0021 question 4, no fixed
budget, and all three permanent, because the server has no delete path). The
first is dead: that fixture kept its wrapping key in process memory only, so
its state file no longer opens and the account is registered but unreachable —
which is why a third exists at all. The third is a diagnostic account with no
messages and no contacts, registered to measure the hosted server from a second
identity; unlike the first it keeps its wrapping key beside its state, so that
diagnosis needs no further registration. The second is the contributor's own
and is still in use: the joint session of 2026-09-14 consumed no registration,
it ran on that account. Before all three, the only contact this branch had had
with the hosted server was one TLS handshake that compared the live
SubjectPublicKeyInfo digest against the pin this client carries.

## Current package/simulator receipt (4066f36, identical iOS tree on main)

Yaroslav's [4066f36 receipt](../../project/evidence/ios-client-20260918/mac-receipt-pr50-4066f36.md)
(recorded 2026-09-23) covers PR50's final head. It reports five focused
call-tone/audio suites 42/0, the app target without Keychain 90/0, an
ad-hoc-signed Keychain suite 11/0, package 362/0, a freshly built device bundle
with 23 checks and 1 skipped, and all 16 ios-static Python gates green. These
results are quoted in the owner's merge-gate review. PR50 merged as `02baeb2`.
`git diff 4066f36 c735f94 -- clients/ios clients/core key-protocol` is empty,
so the receipt applies to main's current iOS code. PR46's earlier
[cc5b0c7 receipt](../../project/evidence/ios-client-20260918/mac-receipt-pr46-cc5b0c7.md)
separately records `MessageTimeTests` 7/0, package 328/0 and a passing simulator
text scenario. Both are contributor Mac execution on the simulator and host.
Neither adds physical-phone evidence, and every phone row below keeps its own
status.

## Earlier package/simulator receipt (dad2f7d, integrated in 96298cd)

Yaroslav's [full dad2f7d receipt](../../project/evidence/ios-client-20260913/mac-receipt-pr43-dad2f7d.md)
records package **300/0**, C1 **7/0**, lazy-key **14/0**, storage **25/0** and
signed-simulator app **64/0**, with old-code behavioral RED **7 tests / 13
assertion failures / 0 unexpected** on cb52330. The coordinator verified an
empty dad2f7d..96298cd diff for clients/ios, .github and CHANGELOG.md after the
manual documentation-only merge resolution. The Mac evidence applies to that
identical code, not to new physical-device behavior. The
[final review](../../project/evidence/ios-client-20260913/pr36-review-96298cd.md)
records closure scope and retained owner/device/export/live gates. No additional
Mac run is implied by recording this evidence in documentation.

## Earlier package/simulator receipt (aab9e5d, identical cb52330 tree)

The [complete contributor Mac receipt](../../project/evidence/ios-client-20260913/mac-receipt-pr41-aab9e5d.md)
records package **293/0**, lazy-key **14/0**, storage **25/0** and signed-simulator
ParanoIDTests **64/0**, including successful compilation of the new onboarding
fixture. The earlier e642907 package compilation failure remains a separate
receipt. The coordinator verified tree equality after PR41's merge as cb52330;
no additional Mac run is implied. Historical scenario counts below are not the
current package total and earlier physical-phone reports do not establish
current-revision device acceptance. F1–F7 regression mapping is in the
[review handoff](review-integration-handoff.md).

## Status vocabulary

- `NOT RUN`: no evidence exists. Every such row names its reason.
- `CLAIMED`: passed on the simulator, the host or the local stand — the
  unchanged server binary plus a private PostgreSQL 16 on the build Mac. It is
  not phone evidence and never becomes phone evidence.
- `SHOWN`: passed on a physical iPhone, with the evidence file recorded. The
  qualifier names the stand: `(phone, local stand)` and `(phone, hosted)` are
  the contributor's own device session of 2026-09-13; a joint test with the
  owner also records the owner "go" permalink beside the result. Before that
  session this file used `SHOWN` for a joint test only, because no other phone
  evidence existed; the widening is a change of this file's own vocabulary and
  not of [the policy](../../governance/documentation-policy.md), and a reviewer
  who prefers the narrower reading can tell the two apart by the qualifier.
- `SHOWN (joint, reported)`: performed in a joint session with the owner, and
  recorded from a participant's report given immediately afterwards — not from
  a screen recording and not from an observation by whoever writes these files,
  because the contributor is the only participant the record has. The evidence
  file is named as for `SHOWN`, and the qualifier is what tells a reported
  result from a captured one. A joint test also records the owner "go"
  permalink beside the result; the session of 2026-09-14 was unscheduled and
  has no such permalink, so that half is missing and is not filled in from
  anywhere.
- `FAILED`: run and failed; the failure is kept, not hidden.

Only `SHOWN` or `SHOWN (joint, reported)` in a joint test with the owner
counts toward the acceptance of
[REQ-CLIENT-001](../../product/requirements.md) on the hosted alpha. The two
joint tests were written in advance with every `Result` column reading
`NOT RUN`, and are now partly run:
[stage1-text.md](../../project/evidence/ios-client-20260913/stage1-text.md)
(steps 4, 5 and 6, on 2026-09-14) and
[stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md)
(steps 4, 8 and 9, the same day). Stage 1 steps 1, 2, 4 and the first half of 5
(one check, no reply yet) were exercised on 2026-09-13 by the contributor alone
against the hosted server with the owner's QR image — a pre-run, not the joint
test. Every other `Result` cell in both stages stays `NOT RUN`.

## Requirements

> Since 2026-09-17 the three delivery states are **drawn** rather than typed into
> the bubble (`ReceiptMark`): the evidence rows below name `✓` and `✓✓` because
> that is what was on the screen when each run happened, and the states, their
> order and their words — «В очереди», «Сохранено сервером», «Доставлено» — are
> unchanged. No read receipt exists in this client (REQ-MSG-003).

| Requirement | What must hold for iOS (source) | What was actually run | Status |
| --- | --- | --- | --- |
| REQ-CLIENT-001 | Supported clients include iOS ([requirements](../../product/requirements.md)) | A Release build for a device links and passes the bundle gate **unsigned** (`test_app_bundle.py`, `CLAIMED`). On 2026-09-13 two builds signed with team `5RPGVC566Q` (`xcodebuild -allowProvisioningUpdates` with the team on the command line, installed with `xcrun devicectl`) ran on an iPhone 16 Pro Max, iOS 26.6.1, Developer Mode enabled: a Debug build for the local-stand session (it takes the DEBUG-only `PARANOID_REALM`/`PARANOID_PIN` environment channel, because `devicectl` relays no launch arguments) and a Release build for the hosted server. No archive, no `.ipa` export and no TestFlight upload: the export-compliance gate is closed and `build.sh`'s signed-archive gate did not run | SHOWN (phone, local stand and hosted); acceptance waits for the joint tests |
| REQ-ID-005 | Identity created on the phone with locally owned keys and automatic proof-of-possession, no operator or bearer ([self-service v2](../../protocol/self-service-v2.md)) | `test_clean_self_service.py --registration-only` on the local stand: `create_identity` then `upgrade_v2`, two durable commits before any request, registration to `enrollment.mode == "active"`, a 64-digit contact fingerprint and a core-validated session; repeating both operations commits nothing. The application itself does the same through «Создать ID» in `test_sim_text.py`. On 2026-09-13 the same flow ran on a physical iPhone 16 Pro Max against the local stand (identity created on the device), and the Release build then registered the phone's identity on the hosted alpha — the second of the three accounts in `hosted_registrations` | SHOWN (phone, local stand and hosted) |
| REQ-ID-007 | Contacts added only through explicitly verified QR key bindings ([first-contact v1](../../protocol/first-contact-v1.md)) | `QrTests` round-trips the core's own ~900-byte contact through the encoder and back byte-identically, refuses 2049 bytes and lets the core refuse a tampered contact; in `test_sim_text.py` the application shows its own QR and pairs the peer by **pasting** that peer's contact text and confirming «Отпечаток совпадает». `test_qr_cross.py` then crossed the pixels with the ZXing build Android ships, both ways, and held the decoded text to one fingerprint on both cores and in Python. A code read off a real camera is a device action: on 2026-09-13 it ran on a physical iPhone 16 Pro Max against the local stand (a contact read off the build machine's screen with the real camera, fingerprint sheet confirmed), and the same phone then read the owner's Android contact off a screen from the QR image he sent and paired it against the hosted server. In the joint session of 2026-09-14 that scanner read the owner's own QR and the contact was paired (`stage1-text.md`, step 4, reported); the report does not say whether the code was read from his phone or from a screen and does not record the fingerprint being compared aloud, and the Android side of the pairing — the owner scanning this phone's QR — was not performed (step 3, `NOT RUN`) | SHOWN (phone, local stand and hosted); the owner's own QR SHOWN (joint, reported) |
| REQ-ID-008 | Self-service registration on the common server without approval or a transferred code ([self-service v2](../../protocol/self-service-v2.md)) | `test_ui_contract.py` reads the screens: no operator, grant, role, invitation or manual URL/pin form exists. Registration completes on the local stand with no out-of-band step. On 2026-09-13 the same flow ran on a physical iPhone 16 Pro Max against the local stand (the device registered itself on the stand, no operator), and the phone then registered itself on the hosted alpha the same way | SHOWN (phone, local stand and hosted) |
| REQ-MSG-002 | 1:1 E2EE text through one server with persistent history, reconnect and no duplicate display ([realtime v1](../../protocol/realtime-v1.md)) | `test_clean_self_service.py` (two independent clients on one stand: texts both ways, exact retry of an answer lost after commit adds no row, `psql` proves every stored row is frame-2 ciphertext and no plaintext appears in any table), `--longpoll` (300 s across the server's idle, socket-lifetime and renewal bounds with no failure published), `test_realtime.py` (injected transport faults), and `test_sim_text.py` (the application: one bubble per tap on a double tap). Both sides of those runs were this client. `test_android_compatibility.py` then put the shipped Android client on the other side, both on the wire and on one local stand, and a text crossed in each direction with its receipt — on the build Mac, not over a real network and not on a phone. On 2026-09-13 the same flow ran on a physical iPhone 16 Pro Max against the local stand (two texts phone → peer and one peer → phone, with a persistent peer on the build machine, receipts delivered). Against the hosted server the phone sent one text to the owner's Android that the server accepted, with delivery and a reply still pending. The joint session of 2026-09-14 closed that gap: the message reached the owner's Android and his reply appeared on the iPhone (`stage1-text.md`, steps 5 and 6, reported). Whether a read receipt appeared anywhere was not reported, and steps 7-15 — closed application, screen lock, Wi-Fi to LTE, block and unblock, rename, ten-minute idle — stay `NOT RUN` | SHOWN (phone, local stand); text both ways with the Android client SHOWN (joint, reported) |
| REQ-MSG-003 | One check means durable server acceptance, two mean recipient delivery, not reading ([first-contact v1](../../protocol/first-contact-v1.md)) | Same runs: `✓` appears only after `{id, sequence >= 1}` was committed, `✓✓` only after the peer's authenticated receipt, and no read receipt exists anywhere in the source (`test_ui_contract.py`). On 2026-09-13 the same flow ran on a physical iPhone 16 Pro Max against the local stand (one check then two, in the application on the phone); on the hosted server the text to the owner's Android showed one check, «Сохранено сервером», and the second was still pending. In the joint session of 2026-09-14 both checks appeared on the iPhone for a text to the owner's Android — the first time this client has seen the second check, which is the acknowledgement from a real Android client (`stage1-text.md`, step 5, reported) | SHOWN (phone, local stand); both checks against the Android client SHOWN (joint, reported) |
| REQ-MSG-005 | First-contact text appears immediately as an unverified conversation on a receiver with zero contacts, reply enabled, no scan or approval ([first-contact v1](../../protocol/first-contact-v1.md)) | `test_clean_self_service.py`: the receiver, which scanned nothing, shows the conversation as `network_unverified` and replies without pairing; both directions end double-checked. Between two instances of this client. The Android direction has since been run for the paired case alone (`test_android_compatibility.py`: both clients pair each other first, on the wire and on the stand); the unpaired first-contact story with an Android peer is still untested | CLAIMED |
| REQ-CALL-002 | Real 1:1 encrypted audio (and, under call-v2, camera video) over a mature WebRTC engine ([voice scope](../../product/voice-calls.md), [call-v2](../../protocol/call-v2.md)) | `test_voice_sim.py`: two simulators on one local stand, two calls one each way, both peers reach `RTCPeerConnectionState.connected` over direct ICE (`host` to `host`, nothing relayed), each call held 40 s with about 2300 RTP packets received and sent per side and four heartbeat envelopes stored per account per hold. **No audio was decoded to a speaker, no camera saw a face and nothing crossed a real network.** On 2026-09-13 the same flow ran on a physical iPhone 16 Pro Max against the local stand (one call from the phone to a simulator over the build Mac's LAN connected and carried video from the phone's camera; the simulator has no camera, and whether audio was heard is not recorded). On 2026-09-14 the owner called the iPhone from his Android on the hosted alpha, Yaroslav answered and they spoke, so audio carried in both directions, and both sides then turned their cameras on and each saw the other — the first call this client has carried against the Android client rather than a simulator, and the first picture it has received from a real camera over call-v2 (`stage2-voice.md`, steps 4, 8 and 9, reported). No duration, codec, frame rate or candidate pair was reported, and the outgoing direction — this client calling an Android — was not exercised on real phones (step 1, `NOT RUN`) | SHOWN (phone, local stand); a call against the Android client SHOWN (joint, reported) |
| REQ-CALL-003 | Signaling binds immutable account/device/realm/channel, fresh call identity and media fingerprint/ICE context ([voice v1](../../protocol/voice-v1.md), [call-v2](../../protocol/call-v2.md)) | `SdpCompatibilityTests`: libwebrtc's own offer, answer and one `media` control pass the **unchanged core validator** between two synthetic identities, with `v: 2` and a boolean `video` in every body, and a fourteen-member v1 body is refused as `invalid_request`. `CallControllerTests` (23 tests on a fake clock) and `test_call_controller_parity.py` (`labels: 94/94 covered`) measure the state machine against the Android smoke scenarios. The SDP is never rewritten | CLAIMED |

## Platform checks without a requirement identifier

These accompany the rows above and never substitute for them.

| Check | What was actually run | Status |
| --- | --- | --- |
| Core compiles and links for `aarch64-apple-ios` without changes | `build-core.sh` builds the bridge for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-apple-darwin` and combines three single-architecture `arm64` archives into `ParanoidCore.xcframework`; `BridgeSmokeTests` runs `create_identity` → `upgrade_v2` inside the application on the simulator. The core was not modified | CLAIMED |
| Pinned TLS: the eight leaf checks, the session rules numbered 9, and the socket rules | `check-pinned-tls.py` breaks checks **1, 2, 3, 6, 7, 8** over real loopback sockets, each refused before any HTTP request; its check-9 fixture (a TLS 1.1 server) runs only where the local OpenSSL still offers TLS 1.1 and prints `SKIPPED` otherwise. Checks **4 and 5** have **no socket fixture**: they are proven on parsed certificates by `PinnedTrustTests` (unknown critical extension, `CA:TRUE`, one bit flipped in `signatureValue`, wrong signature algorithm), with the corrupted leaf also driven through `PinnedSessionDelegate` on a real `SecTrust`. `test_realtime_transport.py` covers the socket rules; `X509LeafTests` covers the parser. Offline, no hosted contact. On the phone against the hosted server, App Transport Security refused the self-signed leaf on a public IP before `PinnedSessionDelegate` ran (defect 4: `NSURLErrorDomain -1200`, stream error `-9802`; a LAN stand never shows it, and `NSPinnedDomains` does not match an IP literal). Fixed by `NSAllowsArbitraryLoads = YES`, with `test_ui_contract.py` holding exactly that key and a finite lexical allowlist of reviewed pinned-session factories (not arbitrary Swift data-flow proof); see [ios-client-threats.md](../../security/ios-client-threats.md) | CLAIMED |
| The pin this client carries is the live one after the owner's same-key renewal | One TLS handshake from the build Mac, no HTTP request: the live SubjectPublicKeyInfo digest equals the compiled pin, and the renewed leaf is valid to 2026-12-12T07:38:09Z. Recorded locally in `out/evidence/hosted-preflight.json`, whose own counter read zero when that handshake was taken, before any of the three registrations existed. After the ATS fix the physical iPhone's Release build registered on the hosted server with the same pin, which is unchanged; the count read 2 in `device-smoke-result.json` at that point, and is 3 since the diagnostic account was registered from the build Mac on 2026-09-14 while diagnosing issue #38. That the registration went through `PinnedSessionDelegate` is not a packet capture: it follows from review of the current production pinned-session factories, reinforced by the finite lexical gate (`test_ui_contract.py`), and from the handshake succeeding against a leaf no certificate authority signs | SHOWN (phone, hosted) |
| Storage: commit order and injected faults; the install-marker matrix | Yaroslav reported exact 628958b on Mac: lazy-key 14/0, storage 25/0, package 278/0 and signed simulator Keychain 11/0; see [receipt](../../project/evidence/ios-client-20260913/lazy-storage-mac-628958b.md). Earlier 0709212 receipt separately records strict RED on d96cea1. Reviewed storage cases closed at host/simulator scope, not physical-device or power-loss evidence. See [handoff](lazy-storage-handoff.md). | CLAIMED |
| Component boundary: no committed diff outside the allowlist | `test_component_boundary.py` against the pull-request base | CLAIMED |
| Call scenario parity: every `check(…, "<label>")` of the Android `CallControllerSmoke` is named by an iOS assertion | `python3 clients/ios/test_call_controller_parity.py` → `labels: 94/94 covered`, over the scenarios `swift test --filter CallControllerTests` runs. It says the scenarios match, not that the media does; REQ-CALL-002/003 still need `stage2-voice.md` | CLAIMED |
| Call timers and terminal reasons: the 45/30/10/900-second deadlines with the reason each one ends on, the ten-second heartbeat with one outstanding at a time and numbered from `seq` 2, the five-second clock tolerance, the knock ceilings, the bounded terminal table and the `end` every terminal path does or does not send | `swift test --filter CallControllerTests` → 23 tests on a fake clock, no network; it says what the state machine decides, not what the media does | CLAIMED |
| TURN credential lane: a live session is required and never downgraded on failure; a valid authenticated 404 from the pinned origin is the only answer that permits the pre-disclosed direct-ICE mode; the first ambiguous 401 is signed again exactly once; the optional route discards neither the text session nor the discovery timestamp; the credentials never reach the snapshot ([voice TURN v1](../../protocol/voice-turn-v1.md)) | `python3 clients/ios/test_voice_relay_lane.py --evidence-dir out/checks/voice-lane` → `7/7 PASS, signature verified` over a real pinned loopback socket, with `clients/ios/test/turn_stub.py` verifying the client's Ed25519 session signature itself; plus `swift test --filter VoiceRelayLaneTests` (12 tests, no socket). It says what the lane decides, not that any media flowed: REQ-CALL-002 still needs `stage2-voice.md`, and no TURN server was involved | CLAIMED |
| Media engine publication: the one local description of a call leaves the device exactly once; the relay lane publishes only after a usable component-1 UDP `typ relay` IPv4 candidate (500 ms coalescing, or gathering complete) and never without one; the direct lane only at gathering complete and never on an empty `complete`; a description above the 9000-byte frame budget or outside the call-v2 shape is refused instead of rewritten ([call-v2](../../protocol/call-v2.md)) | `xcodebuild test -only-testing:ParanoIDTests/SdpPublishGatingTests` → 16 tests: ten drive `WebRtcAudioEngine.PublicationGate` with a fake candidate feed, four run the real engine in the simulator and two measure the configuration and the codec preferences (one offer of about 3.8 kB with 6 candidates and no second publication; a relay-only engine with nothing answering publishes nothing in 8 s; the camera refusals). It says when a description may be sent, not that any media flowed | CLAIMED |
| Call consent and the audio session: the privacy sentence stands before «Позвонить» and before «Ответить» and nowhere after; the microphone is requested only from an explicit Call or Answer and a refusal tells the peer, the user and nobody else; the audio session is running before the first `knock` and libwebrtc stays silent until `connected`; the intent waits ten seconds for a confirmed online lane and then says so, and an intent cancelled by a newer one never takes that one's session away; the camera is opened by «Включить камеру» or an explicit video-call intent alone and a refusal downgrades the call to audio without changing any section's direction ([voice v1](../../protocol/voice-v1.md), [call-v2](../../protocol/call-v2.md)) | `python3 clients/ios/test_ui_contract.py` → `OK` (20 tests, offline and source-only): the caption contract plus eight call rules read out of `AppModel`, `CallCoordinator`, `AudioSessionController`, `CallScreen` and the chat toolbar — including the screen rule (`isIdleTimerDisabled` follows either camera; the proximity sensor excludes both local and remote video and enables only once the call is `connected`; Android's cited `!speaker && connected && !videoEnabled` covers local video alone, so a ringing call never blanks the screen; the one deliberate difference — this client keeps the sensor through a reconnection where Android releases it — is written down in `AudioSessionController.audible`), the intent-ownership rule, the call-identifier re-check on a refused microphone (a permission dialog can outlive its 45-second ring) and the re-activation of a session an interruption took away while the call was still ringing; plus `xcodebuild test -only-testing:ParanoIDTests/CallAudioSessionTests` → 5 tests on the real `RTCAudioSession` in the simulator. Together they say what the client is wired to do and what the platform does with it, not that any call connected | CLAIMED |
| Call screen capture protection, and what is **not** protected: Android puts `FLAG_SECURE` on the call window alone (`MainActivity.java:478`, Android v16), which takes it out of screenshots, screen recordings and mirroring. iOS has no equivalent flag, so this client covers the video stage — and only the stage, so the call stays operable — while `UIScreen.isCaptured` reports a recording, AirPlay or a wired mirror. A **screenshot** cannot be refused on iOS (there is no API; a client only learns afterwards) and the **app-switcher snapshot** the system takes as the application leaves the screen is not covered either. Both are open gaps of this port, not parity | `python3 clients/ios/test_ui_contract.py` → `OK`: the `FLAG_SECURE` line is read out of `MainActivity.java` and the cover, its notification and its caption «Видео скрыто: идёт запись или трансляция экрана.» out of `CallScreen.swift`. Source-only: no simulator can start a screen recording | CLAIMED |
| Two simulators on one call: each phone registers on the local stand, pairs the other by the fingerprint that phone's own core published and says «Сервер подключён»; one calls, the other answers, and **both** reach `RTCPeerConnectionState.connected`; the media carries RTP in both directions; the call outlives the 30-second silence deadline on the peer's ten-second heartbeat; «Завершить» ends it on both sides; and the same call again in the other direction ([call-v2](../../protocol/call-v2.md)) | `python3 clients/ios/test_voice_sim.py --evidence-dir out/evidence/voice-sim` → `Voice (two simulators, direct ICE): PASS`: two `xcodebuild test-without-building` processes drive `ParanoIDUITests/VoiceCallUITests` on `iPhone 17 Pro (26.5)` and `iPhone 17e (26.5)` at once, each uninstalled first, against the unchanged server on a private PostgreSQL 16 cluster that starts no TURN — so `/v2/voice/turn` answers `404 turn_disabled`, the disclosed direct-ICE mode, and the pair that carried every call is `host` to `host` with nothing relayed. Two calls, one each way, each held 40 s with about 2300 RTP packets received and sent on both sides, with 32 screenshots beside the JSON. It says two applications on one Mac negotiated, connected and carried packets to each other, not that a person heard anything | CLAIMED |
| iPhone ↔ Android at the protocol level: the shipped Android facade and the shipped iOS classes take turns on one wire — identity and enrollment, pairing from the other side's contact text, a text each way with its receipt, a full call-v2 round (knock, ready, offer, answer, media, heartbeat, end) whose bodies arrive byte-identical with `video` still a JSON boolean, the snapshot codec crossed both ways, a saved wrapper reopened by both adapters with no write and the same public view, malformed call bodies refused with one and the same code, and a tampered envelope refused in both directions; then both **shipped client stacks** register on one local stand and carry a text to each other through it, both ways | `python3 clients/ios/test_android_compatibility.py --evidence-dir out/checks/compat` → `iOS/Android protocol compatibility: PASS (15 checks)`, and `--skip-stand` → `PASS (12 checks)` with no server at all. Both pipes link the **same** Rust core (two builds of one source: a JNI `cdylib` and the macOS slice of the C ABI xcframework), so a fault in the core would reproduce on both; every scenario therefore also matches an expectation the harness computes in Python without calling the core — the account, credential, contact and channel transcripts, the sealed-snapshot byte layout, and a call-v2 validator written from the protocol document — and 21 negative vectors are refused by that validator first and then by both clients. It says the checked scenarios interoperate on the checked revisions, with each side holding its own state and no stand-in for the core. It is not acceptance on devices | CLAIMED |
| The contact QR crosses both encoders: a real 901-byte `paranoid-contact-v2` payload drawn by the shipped iOS encoder is read by the ZXing 3.5.3 build Android ships, and a ZXing-drawn code of the same payload is read back on this side; the text that returns previews to one fingerprint on the publishing core, on the peer's core and in the harness's own transcript | `python3 clients/ios/test_qr_cross.py --evidence-dir out/checks/qr-cross` → `2/2 identical` and `PASS (4 checks)`, with six refusals (both byte bounds on both sides, a contact whose signature moved, a PNG that is not a code) and no refusal echoing the payload. The reverse direction is read with `Vision` inside the fixture: the application reads codes from `AVCaptureMetadataOutput` in a live capture session, which no command-line tool can drive, so this says the ZXing pixels carry the payload and **not** that the shipped scanner ran. The shipped scanner has since run on the physical iPhone, off the build machine's screen and off the owner's Android QR image (REQ-ID-007) | CLAIMED |
| WebRTC dependency: archive and slice digests, bundled notices | `webrtc_dependency.py` re-extracts the pinned `150.7871.01` archive and `test_webrtc_dependency.py` measures the digest, slice and re-extraction rules; `notices.py` / `test_notices.py` bundle the licence texts and fail a linked crate without one; `test_app_bundle.py` weighs the embedded framework of an unsigned bundle against the pinned slice | CLAIMED |
| Reconnect on a change of network: a running loop mints a generation with its lanes left enabled, cancels what is on the socket and relaunches them, so a poll over an interface the device no longer has ends there and not at its own 30 s bound plus backoff; a change seen while the lanes are stopped starts nothing; «Повторить подключение» does the same restart unless a call is live or the client is already connected, in which case it only wakes the send lane; and a start or a restart says «Подключение · подробнее» instead of leaving the previous caption standing, without inventing a connected state | `swift test --package-path clients/ios/ParanoidKit` → 261 tests, 0 failures in the earlier reconnect-candidate run (not the current storage follow-up), six of them this row's (the policy row, the relaunch under a new generation, back-to-back changes never launching two tasks under one generation, the outbox and session surviving a restart, a lane freed from a dead poll, and `StateOwner.restart()` refused while stopped); `xcodebuild test -only-testing:ParanoIDTests/ConnectivityRestartTests` → 15 tests, 0 failures on the simulator, which include the source scan that keeps the watcher inside the no-background-delivery contract; `python3 clients/ios/test_ui_contract.py` → `OK` (20 tests). Then on one simulator against the local stand, 2026-09-14: the whole shipped chain — a real `NetworkWatcher` wired as `AppLifecycle` wires it, a real `LifecycleRunner`, the real policy — took a stated change of the carrying interface to `RealtimeLoop.restart()` in 0.069 ms and had the lanes relaunched under the new generation in 0.096 ms, while the first path, the same path again, an unsatisfied path and a change with the lanes stopped each restarted nothing; and «Повторить подключение», pressed 4.17 s after a frozen server was resumed, cancelled the running long poll at `[-999]` after 4346 ms of its 30000 ms bound — the first caller `RealtimeTransport.cancelActive()` has ever had — with the client green 5.296 s after the restore against 20.002 s untouched. `NWPathMonitor` is live in the simulator and reports the host's real default path, but **no real path change was produced** and none is claimed; the frozen-server drop is a timeout and not a path change, so the 25 s (recorded, unfixed) against 20 s (measured, fixed) difference is where the backoff landed and is **not** an improvement. Evidence: `clients/ios/out/evidence/reconnect-20260914/reconnect-result.json` | CLAIMED |
| Reinstall and strict missing-state refusal | Yaroslav reported exact 628958b on Mac: lazy-key 14/0, storage 25/0, package 278/0 and signed simulator Keychain 11/0; see [receipt](../../project/evidence/ios-client-20260913/lazy-storage-mac-628958b.md). Earlier 0709212 receipt separately records strict RED on d96cea1. Reviewed storage cases closed at host/simulator scope, not physical-device or power-loss evidence. See [handoff](lazy-storage-handoff.md). | CLAIMED |

## What has not run, and why

Each of these is `NOT RUN`. None of them is waiting on a decision this client
can take. Two rows left this list on 2026-09-13 — anything at all on a
physical iPhone, and a QR code read off a real camera — and are `SHOWN` above.
Three more left it in the joint session of 2026-09-14 — a text delivered to and
answered by the owner's Android, audio actually heard, and interoperability
with the Android client on its own hardware as far as those and one incoming
call reach — and are `SHOWN (joint, reported)` above. What that session did not
cover stays below, in narrower rows.

| Check | Why it has not run |
| --- | --- |
| A signed archive and an `.ipa` export | The signed builds were installed straight from `xcodebuild` and `xcrun devicectl`; no archive or export was produced, and `build.sh`'s signed-archive gate did not run. The export-compliance gate is closed |
| Data Protection class of the state file | A simulator has no Data Protection and reports no protection class. The class the write asks for can only be observed on a device, and the device session did not measure it |
| A real screen recording covering the call stage | No simulator can start a screen recording, AirPlay or a wired mirror, and none was started during the device call |
| Screen lock during dialling or during a call | `xcrun simctl` exposes no lock verb and `XCUIDevice` has no lock API; the reason is recorded in the voice evidence beside the two calls that did run. Not exercised in the device session either: it moves to the joint test |
| A call over a real network (LTE, NAT), and any relayed call | The two simulator calls were on one Mac over loopback, and the device call of 2026-09-13 crossed only the build Mac's LAN to a simulator. The joint call of 2026-09-14 ran between two phones over the hosted alpha, but the network each side was on, the candidate pair that carried the media and the answer `/v2/voice/turn` gave were not reported, and LTE was not tried (stage 2, step 16, `NOT RUN`). The stand starts no TURN server, so no call there has been relayed |
| The Android side of the pairing, and a call placed **from** this client to an Android | The QR went one way in the joint session of 2026-09-14: the iPhone scanned the owner's code and he did not scan the iPhone's, so the fingerprint compared aloud and the verified contact on his Android are untested (stage 1, step 3). The call went one way as well — the owner dialled and the iPhone answered — so the outgoing path from this client to an Android has been exercised only against a simulator on the build Mac's LAN (stage 2, step 1) |
| A real change of network path, on any device | The open item of 2026-09-13/14 — after a network drop the application stayed at «Нет подключения» while the server answered from the Mac and the pinned key was unchanged — has a cause and a fix on this branch: this client had no connectivity-change restart, which Android gained on 2026-09-12 (`TextEngine.java:200-215`, read in this branch's merged Android tree `0.0.22-push`, not at `fe9c26c`). The fix is `CLAIMED` in the platform row above and **no real path change was ever produced for it**: a simulator has no network of its own, so `NWPathMonitor` there reports the build Mac's default path; `xcrun simctl` has no network verb; and moving the Mac's own default route needs an administrator and would have taken down its only WAN interface. The rule was therefore driven at the seam it exists for, with the shipped watcher, runner and policy. The owner's reviewer named the three transitions that would turn this into phone evidence, and each is `NOT RUN`: Wi-Fi to cellular and back; a change of Wi-Fi network on the same interface, which this reducer cannot see at all because the interface's `name#index` does not move; and a VPN taking and releasing the route. Until they are observed on a device with the pinned requests correlated against real `NWPath` reports, the watcher's comparison is a stated proxy for the socket's interface, not a demonstrated one, and the reconnect row above stays `CLAIMED`. Nothing was run on a phone and nothing against the hosted alpha, no device log was ever collected for the original drop, and the drop that was reproduced is a frozen server, which produces a timeout and not a path change |
| Recovery after a network drop on the phone | Unchanged by the fix above, because that fix has not been on a phone. It also does not explain the failure of 2026-09-14, which is a different one: a signed `GET /v2/messages` that did not return while the pinned handshake stood and the route answered — recorded in [the device session](../../project/evidence/ios-client-20260913/README.md) and measured in pull request #36 |
| A TestFlight build, internal or otherwise | The [export-compliance gate](export-compliance.md) is closed: `ITSAppUsesNonExemptEncryption = YES` is prepared, not satisfied, and Apple applies the requirement to TestFlight as well |
| The `ios-static` workflow on a macOS runner | `.github/workflows/ios.yml` ran on pull request #36 (opened 2026-09-14 as a draft): `ios-static` passed, as did the docs workflow and the server workflow's `client-core-and-tls` and `native-package` jobs; "Legacy client history" is informational and fails on `main` too. Every check the job contains was also run locally on the pinned build Mac with exit 0 — twelve of its thirteen `run` commands, and that is what the rows above record; the thirteenth is the `rustup toolchain install` setup line, which was not re-run on a Mac that already pins 1.98.1. There is still no macOS runner (RFC-0021 question 6, answered "no"), so nothing needing Xcode, a simulator or the local stand runs in CI |
| Independent human review of identity, cryptography, persistence and application security | Not available to the contributor; the closed-alpha exception permits an independent AI review in a fresh context, recorded in [independent-review.md](../../project/evidence/ios-client-20260913/independent-review.md) — two reviews on `bcb4046`, ten findings, all answered — and it is not a human audit |

## Joint tests with the owner

Both are live actions, and a planned one records an explicit owner "go" whose
permalink goes into the evidence directory beside the result. The scenarios are
written in advance so that the result cannot be shaped after the fact, and a
`Result` cell changes only after the step has been performed. Both are now
**partly run**: on 2026-09-14 Yaroslav and the owner held one unscheduled
session on the hosted alpha, which covered steps 4, 5 and 6 of stage 1 and
steps 4, 8 and 9 of stage 2. Those rows read `SHOWN (joint, reported)` because
the contributor is the only participant the record has and every result is his
report; the session was unscheduled, so it has no owner "go" permalink and none
is inferred for it. It consumed no registration — it used the account the
iPhone registered on 2026-09-13; `hosted_registrations` is 3, its third entry
being the diagnostic account registered from the build Mac the same day while
diagnosing issue #38, outside this session. Stage 1 also had a solo pre-run on
2026-09-13 (steps 1, 2, 4 and the first half of 5, by the contributor alone
with the owner's QR image), which is not the joint test. Every other step of
both stages is still `NOT RUN`:

- [stage1-text.md](../../project/evidence/ios-client-20260913/stage1-text.md):
  registration, QR in both directions, text and receipts, block and unblock,
  cold start, screen lock, LTE and Wi-Fi. The iPhone's scan of the owner's QR
  and text both ways are done; the Android side of the pairing (step 3) and
  steps 7-15 — closed-application delivery, screen lock, Wi-Fi to LTE, three
  messages each way on LTE, relaunch, block and unblock, rename and the
  ten-minute idle — are not.
- [stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md):
  calls in both directions with both applications open, the **expected**
  45-second `timeout` when the iPhone is locked or closed, lock during ringing
  and during a call, mute and speaker, the camera, a real screen recording, and
  hang-up from each side. The incoming call, with audio both ways and both
  cameras on, is done; the outgoing call (step 1), the two-minute hold, hang-up
  from either side, mute, speaker, a real screen recording, lock during
  dialling and during a call, the background and closed-application calls, LTE
  and busy are not.

Stage 2 needs an Android build of **v16 or later** on the owner's phone:
call-v2 rejects v1 call bodies, so an older build can exchange text with this
client but cannot call it. The call of 2026-09-14 connected, so his build is
v16 or later; the exact version was not asked for.
