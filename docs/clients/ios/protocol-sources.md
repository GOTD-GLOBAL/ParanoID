---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# iOS client behaviour: rule to source table

Behaviour map for [RFC-0021](../../rfcs/0021-ios-client.md). Every iOS
behaviour is written from the protocol document and the shared core or server
code; the Java client is a **source-level** cross-check, and the rows below are
the reading of it. Since then the two clients have also been run against each
other on the build Mac — `clients/ios/test_android_compatibility.py` and
`clients/ios/test_qr_cross.py`, both `CLAIMED` in
[verification.md](verification.md) — which checks the scenarios those scripts
cover on the revisions they digest, and not every row of this table. Contact
with the owner's Android on its own hardware is from 2026-09-13 — a signed
build on a physical iPhone paired it from the owner's QR image and sent one
text the hosted server accepted — and from the unscheduled joint session of
2026-09-14, which carried text both ways and one call he placed to the
iPhone, both sides' cameras on. That session is the contributor's report,
`SHOWN (joint, reported)` in
[stage1-text.md](../../project/evidence/ios-client-20260913/stage1-text.md)
and [stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md);
it confirms no individual row of this table, because it was not read row by
row. Line numbers refer to `main` at `fe9c26c`
(Android v15) unless a row says otherwise; a row marked `(Android v16)` cites
post-v15 Android code instead — the call-v2 and video work, and the
connectivity-change restart Android added on 2026-09-12 (`2cdb850`) — read in
the merged Android tree of this branch (`0.0.22-push`, versionCode 22), not at
`fe9c26c`. Those line numbers do not resolve at `fe9c26c` and some of them mean
something else there. Line numbers of `clients/ios/**` refer to this branch.

## Discrepancies are not corrected here

The `Discrepancy` column names the numbered doc-to-code findings reported to
the owner as "Findings from iOS-client preparation", section A. **This pull
request corrects none of them.** The owner's agents answered RFC-0021 question
10 on 2026-09-12 in
[issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27): the factual
corrections go into a **separate docs-only pull request**, with five items
reframed rather than applied verbatim. Until that change lands, each row below
carries the finding as a recorded waiver, and the owner's answer is the
permalink above; the same permalink is in the body of this pull request. A row
with nothing to waive says `none`.

The delegation of technical decision authority under which the contributor
answered the remaining questions is
[issue #27, comment 5651949919](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919);
it settles technical choices and waives neither review nor evidence.

## Core bridge

Rules of the Swift adapter over the C-ABI bridge
(`clients/ios/ParanoidKit/Sources/ParanoidKit/Core/`).

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| A reply carrying an `error` member rejects the operation with that code and changes nothing; a NULL or non-JSON reply is a native failure; `input_limit` (8 MiB state, 65536-byte request), `invalid_request` and `invalid_state` are decided by the core, never by the client | none in `docs/protocol/` (the core API is a component contract, not a wire contract): `docs/clients/core/self-service.md:97-100,170-171` | `clients/core/src/lib.rs:418-424`; `clients/ios/bridge/src/lib.rs:28-56` (`paranoid_core_command`) | `SelfServiceClient.java:55-61` (`nativeCall`) | none |
| The next snapshot is the top-level `state` member of the reply; it is persisted before any network side effect, and an unchanged snapshot is not written again. iOS takes the member verbatim (`JsonSpan`) and compares it as text; Android compares after an `org.json` round trip. Equivalent because every core reply is serialised through `serde_json::Value` (sorted `BTreeMap` keys, `preserve_order` absent from `clients/ios/bridge/Cargo.lock`), so one state is always one text | `docs/protocol/first-contact-v1.md:173-178` (persist before any side effect); `docs/clients/core/self-service.md:97-100` | `clients/core/src/lib.rs:220-227` and `clients/core/src/clean_service.rs:312-345` (`reply`) | `SelfServiceClient.java:69-76` (`apply`) | none |

## Registration

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| Registration challenge intent is exactly `{credential, purpose:"register", method:"POST", path:"/v2/registration/commit", body: SHA256("{}")}`; other purposes use `/v2/auth/challenge` | `docs/protocol/self-service-v2.md:26-33` | `clients/core/src/self_service.rs:250-261` (purpose derived from method/path/body); `server/src/self_service_http.rs:175-181,206` | `clients/android/src/org/paranoid/text/SelfServiceClient.java:112-126` | none |
| Proof transcript `LP("paranoid-proof-v2", id, nonce, epoch, expires, realm, pin, account, device, credential, purpose, method, path, body)` and `Authorization: ParanoidV2 <id>.<signature>`; challenge context must equal the saved credential | `docs/protocol/self-service-v2.md:35-45` | `key-protocol/src/proof_v2.rs:20-22`; `clients/core/src/self_service.rs:262-275` | Java only forwards the core result (`SelfServiceClient.java:125`) | none |
| Identity is created and upgraded to core schema 3 durably before the first network request; `create_identity{realm,pin}` then `upgrade_v2` | `docs/protocol/first-contact-v1.md:131-133` | `clients/core/src/lib.rs:439-469`; `clients/core/src/clean_service.rs:754-767` | `SelfServiceClient.java:80-84,128-134` | none |
| Registration/status response `{mode:"active",account,device,credential}` must match the local credential, otherwise `status_conflict`; then `prepare_contact_v2` publishes the fallback key | `docs/protocol/self-service-v2.md:50-51` | `clients/core/src/clean_service.rs:796-829` | `SelfServiceClient.java:131-134,186-189`; `RealtimeLoop.java:173-176` | none |
| Server bounds: eight new accounts per 60 s, 1024 accounts, identical retries free | `docs/protocol/self-service-v2.md:68-71` | `server/src/self_service_http.rs:336-345` | not applicable | none (input to RFC-0021 question 4) |
| Realm is the saved HTTPS origin without path; `pin` is SHA-256 of the server leaf SPKI DER; saved trust wins over compiled defaults | `docs/protocol/key-enrollment-v1.md:41-42`; `docs/protocol/first-contact-v1.md:31,45` | `clients/core/src/lib.rs:166-169,457-460` | `KeyClient.java:9-10,17-21,37-41`; `PinnedTls.java:18-21` | A.5: documents say `SPKI`, code says `pin` / `tls_pin` / `PARANOID_KEY_PIN`; same value |
| App Transport Security is off: `NSAppTransportSecurity` is exactly `{NSAllowsArbitraryLoads: true}` with no per-domain exception, and every `URLSession` is built by `PinnedSessionDelegate` (pinned SPKI, self-signed leaf, TLS 1.2 floor, no proxies, no redirects); trust never comes from a CA chain. On a device ATS refuses a self-signed leaf on a public IP before any delegate runs and its exception lists take no IP literal, which a LAN stand never shows | none in `docs/protocol/` (platform rule); `docs/security/ios-client-threats.md:139-157`; `docs/decisions/0014-ios-client.md:130-136` | not applicable (`clients/ios/App/ParanoID/Info.plist:27-31`; `clients/ios/ParanoidKit/Sources/ParanoidKit/Tls/PinnedSessionDelegate.swift`; `clients/ios/test_ui_contract.py:733-741` enforces both halves) | `PinnedTls.java:15,47-72` (a pinned trust manager replaces the platform store; Android has no ATS) | none; defect 4 of the device smoke, found 2026-09-13 against the hosted server (`NSURLErrorDomain -1200`, stream error `-9802`) and fixed in `adb56be` |

## Session

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| Session opens with purpose `session`, POST `/v2/session` body `{}`; response is strict `SessionV2` `{id, epoch, expires, realm, pin, account, device, credential}`, `expires` = issuance + 300 s | `docs/protocol/realtime-v1.md:21-33` | `server/src/self_service_http.rs:376-397`; core context check `clients/core/src/clean_service.rs:684-698` | `RealtimeLoop.java:184-189` (native parse before use) | none |
| Session request transcript `LP("paranoid-session-request-v1", id, epoch, expires, realm, pin, account, device, credential, request_nonce, method, path, SHA256(body))`; header `ParanoidSessionV2 <id>.<nonce>.<signature>` | `docs/protocol/realtime-v1.md:46-57` | `key-protocol/src/session_v2.rs:45-47`; `clients/core/src/clean_service.rs:722-728` | `RealtimeLoop.java:197-201` | none |
| Allowed session operations: POST `/v2/messages` (exact outbox envelope), GET `/v2/messages`, GET `/v2/events`, and GET `/v2/voice/turn` | `docs/protocol/realtime-v1.md:64-69`; `docs/protocol/voice-turn-v1.md:22-24` | `clients/core/src/clean_service.rs:700-721`; `server/src/self_service_http.rs:448-456` | `RealtimeLoop.java:130-131,226,250,254` | A.3: `operation:"turn"` is absent from the realtime-v1 list |
| Session lifetime: server bounds by monotonic age and wall expiry; client renews around 240 s of monotonic age | `docs/protocol/realtime-v1.md:179-181` | `server/src/self_service_http.rs:39-42,611-619`; core checks only `expires <= 0` (`clean_service.rs:691`) | `RealtimeLoop.java:43-47` (240 s renew, no clamp) | A.4: the documented client-side 300 s clamp exists in no code; iOS follows the Java 240 s monotonic renewal |
| Capability discovery: `GET /health` advertises `realtime: "signed-long-poll-v1"`; 404/401 on session routes triggers pinned rediscovery, never looser trust | `docs/protocol/realtime-v1.md:159-165,172-178` | `server/src/self_service_http.rs:102-106` | `RealtimeLoop.java:177-183,190-194,205-209` | none |
| A first 401 on a signed-session request is retried once with a fresh nonce; a second 401 or `session_exhausted` drops the session | `docs/protocol/realtime-v1.md:71-78`; `docs/protocol/voice-v1.md:118-123` | replay ledger `server/src/self_service_http.rs:33-38` | `RealtimeLoop.java:202-210` | none |
| At most two live sessions per account, 64 globally; 429 `session_capacity` waits, it does not fall back | `docs/protocol/realtime-v1.md:35-36,167-169` | `server/src/self_service_http.rs:380-387` | `RealtimeLoop.java:192` (5 s legacy window) | none |

## Send

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| The outbox is offered oldest first and every entry is sent exactly as `sign_session_v2 {operation:"send", id}` describes it (method, path and the verbatim envelope); without a session the same envelope is posted through a paced `message` proof | `docs/protocol/realtime-v1.md:64-66,127-130` | `clients/core/src/clean_service.rs:700-711,677` (the immutable outbox is the signing source) | `RealtimeLoop.java:221,226` | none |
| A 409 or a 507 defers that envelope, leaves it in the queue and lets the rest of the batch go out; the last deferred rejection ends the pass, every other status ends it at once | `docs/protocol/self-service-v2.md:80-81` | `server/src/self_service_messages.rs:63` (507 `quota_exceeded`); `server/src/self_service_http.rs:313,334` (409 `binding_conflict`) | `RealtimeLoop.java:228,230` | none |
| A failed pass publishes the offline flag with no debounce, backs off and asks itself for another pass; an idle lane waits for a wake instead of polling | none in `docs/protocol/` (client pacing) | not applicable | `RealtimeLoop.java:34,54,219,236-238` | none |
| Status text for 404 on a lane failure | none in `docs/protocol/` (UI rule) | not applicable | `RealtimeLoop.java:286-294` has no 404 case (falls through to "нет подключения"); `TextEngine.java:201` calls the same status "Сервер пока не поддерживает эту версию…" | iOS publishes the `TextEngine` wording, because a 404 here is what retires the session and rediscovers the capability (`realtime-v1.md:172-177`) |

## Receive

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| `GET /v2/events?after=<cursor>&limit=20`: wait at most 20 s within session life, 25 s handler bound; client read timeout must exceed it | `docs/protocol/realtime-v1.md:96-100,138-142,153-154` | `clients/core/src/clean_service.rs:714-718` (core emits `limit=20`); `server/src/self_service_http.rs:599-603,611-621` | `RealtimeLoop.java:249-258` | A.7: `self-service-v2.md:59` shows `limit=50` and the server default is 50 (`self_service_messages.rs:19-20`); clients send 20 and reject larger pages |
| Every route other than `GET /v2/events` has a 10 s handler bound, so a client read timeout must exceed ten seconds there for the same reason it must exceed twenty-five on the long poll: below the deadline the server is working to, the client aborts a request the server may still be answering and a slow server is indistinguishable from a dead one | `docs/protocol/realtime-v1.md:138-142,153-154` | `server/src/self_service_http.rs` (the inner timeout layer: 25 s for `GET /v2/events`, 10 s for everything else) | `RealtimeTransport.java:36` sets 8 s for these routes | **Deliberate divergence.** `RealtimeTransport.readTimeout` is 15 s here — ten plus the same five-second margin `eventsReadTimeout` keeps — while Android's 8 s always loses that race. Measured on 2026-09-14: a signed `GET /v2/messages` on the hosted alpha timed out on this client at eight seconds while `/health` answered in 0.2 s (issue #38). Android carries the same value and the same consequence; that is filed for the owner rather than changed from this branch |
| A change of the default network reconnects the running lanes at once: a new generation with the lanes left **enabled**, the requests in flight cancelled and the send gate kicked, so a long poll over an interface the device no longer has ends there instead of at its own 30 s bound plus the backoff after it. The same change found with the lanes stopped starts nothing, and nothing but an actual change of route may do it — a wake must never abandon an in-flight voice-relay request | none in `docs/protocol/` (client pacing); the protocol permits what it does: `docs/protocol/realtime-v1.md:149` ("Explicit cancellation may close a waiting connection") and `:154` ("connection expiry/cancellation uses a new signed request"), and the session, the capability and the outbox are untouched, so `:179-181` and the account's two live-session slots are unaffected | not applicable (client pacing); `server/src/self_service_http.rs:398-409` (the two slots a restart does not spend) | **(Android v16)** `TextEngine.java:200-215` (`watchNetwork`: `registerDefaultNetworkCallback`, the `changed` test at `:209`, the `restart()`-then-`startConnection()` of `:210` behind its `realtime==null` / `broken` guard, and `onLost` at `:212`), registered right after the loop exists (`:122`); `RealtimeLoop.java:59-67` (`restart()`: `generation++` with `enabled` left set, `lifecycle.notifyAll()`, `kick()`, `transport.cancelActive()` on a thread of its own) against `:68-70` (`nudge()`, which keeps the generation); `RealtimeTransport.java:66-71` (`cancelActive` without replacing the saved trust); `TextEngine.java:184-187` (the gate that keeps every hint that is not a callback on `nudge()`) | none; one **mechanism** differs, not the rule. Android's `onLost` clears `last`, so the `onAvailable` after a loss computes `changed == false` and runs `startConnection()` alone — enough there, because `RealtimeLoop.start()` ends in `lifecycle.notifyAll()` (`:57`) and frees a lane parked in `lifecycle.wait()`. Nothing on this platform can be notified out of a `URLSession` long poll or a `Backoff` sleep, so this client reports a satisfied path after an unsatisfied one as the change it is and restarts. Android's `Network` identity also has no `NWPath` counterpart: the comparison here is the interface the path dials over, `availableInterfaces.first` |
| 429 `waiter_busy` triggers a bounded plain GET `/v2/messages` instead of blocking receive | `docs/protocol/realtime-v1.md:169-172` | `server/src/self_service_http.rs:604-608` | `RealtimeLoop.java:254-255` | none |
| On each resumed receive generation a signed `messages` fetch confirms readiness before the `events` long poll; the connection is published before delivering the page | `docs/protocol/voice-v1.md:137-142` | not applicable (client ordering) | `RealtimeLoop.java:252-256,259-271` | none |
| One event per complete candidate: `receive_v2` returns `acceptance`; persist the whole candidate before UI or receipt network; rejected or failed-save events publish nothing | `docs/protocol/first-contact-v1.md:138-146,173-178` | `clients/core/src/clean_service.rs:620,867-873` | `SelfServiceClient.java:65-78,203-204` | none |
| Delivery marks: one check only after `{id,sequence>=1}` server acceptance (`accepted_v2`), two checks only after the peer's authenticated receipt; never reading | `docs/protocol/self-service-v2.md:56-58`; `docs/protocol/first-contact-v1.md:122-127` | `clients/core/src/clean_service.rs:874-880` | `SelfServiceClient.java:197-200`; `RealtimeLoop.java:226-227` | none |
| Transport frame is byte `2` plus strict JSON, decoded at most 16384 bytes; raw frames stay strings until strict native parsing | `docs/protocol/first-contact-v1.md:64-76,90-92` | `clients/core/src/clean_service.rs:474` (`receive_candidate`) | `SelfServiceClient.java:65-78` | none |
| Missing or unreadable snapshot fails closed; no automatic reset or fresh identity | `docs/protocol/first-contact-v1.md:173-178`; `docs/clients/core/self-service.md:97-102` | not applicable (platform storage) | `StorageGuard.java:7-8`; `SelfServiceClient.java:9-11,25-27` | A.12: install.v1 retains the proposed reinstall distinction; absent marker plus surviving file freezes before deletion. Marker-present key/file XOR is strict. Welcome creates no key; first commit acquires it. Old pending/commit defaults are ignored. Partial first-commit key creation may freeze. See [self-service.md](self-service.md) and [Mac handoff](lazy-storage-handoff.md). |

## QR and contacts

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| ContactV2 has exactly `type: "paranoid-contact-v2"`, `credential`, `bundle`, `fallback_key`, `signature`; fingerprint is SHA-256 of `LP("paranoid-contact-v2", credential fingerprint, bundle.device, bundle.realm, bundle.curve, bundle.one_time_key, fallback_key)` | `docs/protocol/first-contact-v1.md:20-29` | `clients/core/src/clean_service.rs:830-839` (`contact_text_v2` preview) | `SelfServiceClient.java:89-91` | none |
| Verify root credential, account derivation, Olm binding, realm/SPKI, canonical encodings and device signature before any trust; same account or same curve key as self is refused | `docs/protocol/first-contact-v1.md:31-36,43-45` | `clients/core/src/clean_service.rs:835,848` (`ContactV2::verify`); `clients/core/src/self_service.rs:93-103` | not applicable (core) | A.5 (naming only) |
| Pairing requires the user's explicit fingerprint confirmation (`verified: true`), otherwise `peer_not_verified`; rescanning the same contact is idempotent, a changed pin is refused | `docs/protocol/first-contact-v1.md:35-36,148-151` | `clients/core/src/clean_service.rs:840-850` | `MainActivity.java:499-504` (`Отпечаток совпадает`); `SelfServiceClient.java:92-94` | none |
| Contact text limit 4096 bytes at the core; QR payload at most 2048 bytes, rendered at 640 px (256..1280), ECC M, margin 4; scanner decodes frames up to 1280 px and prefers the largest bounded preview | none in `docs/protocol/` (rendering is a platform rule) | `clients/core/src/clean_service.rs:831-832,844-845` | `QrCodec.java:12-23`; `MainActivity.java:614`; `QrScanActivity.java:41-47` | none; iOS must reproduce the dense-QR preview fix (v15) with a camera preset of comparable resolution |
| Scanner is in-app only: no external scanner, URI, upload or persisted camera frame; camera denial leaves identity untouched and offers paste | none in `docs/protocol/` (UI/privacy rule) | not applicable | `QrScanActivity.java:14,26-29,37,51-58` | none |
| Block is orthogonal to trust: pins and history preserved, same channel on unblock; an unknown account cannot be blocked; at most 64 peers, 16 unverified | `docs/protocol/first-contact-v1.md:152,162-169` | `clients/core/src/clean_service.rs` block path (line to be added when the iOS flow is written) | `SelfServiceClient.java:95-97` | none |

## Calls (call-v2)

This client speaks [call-v2](../../protocol/call-v2.md), not voice v1.
Everything of voice v1 that call-v2 does not change stays in force and is
listed here against its voice-v1 line; the deltas are listed against call-v2.

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| Strict call body: the 14 v1 fields plus a boolean `video`, `v` **2**, kinds `knock/ready/offer/answer/media/heartbeat/end`, per-kind nonce/seq/digest rules, `expires_ms - sent_ms` at most 45000, `end` reasons enumerated. A 14-member v1 body is refused as `invalid_request`: there is no mixed v1/v2 call | `docs/protocol/call-v2.md` (version and fields) over `docs/protocol/voice-v1.md:39-61` | `clients/core/src/voice_v1.rs:26-83` with the v2 shape | `CallController.java:36-37,278-295` (v15, v1 shape; the v2 body is Android v16's) | none; the alpha break is call-v2's own, and this client cannot call an Android build older than v16 |
| `kind: "media"` is informative: `seq >= 2`, both nonces, exact offer digest, empty SDP/ICE/reason, accepted only in `connecting`/`connected`, monotonic per sender, refreshes the heartbeat deadline. It grants, changes and revokes no media authority — a forged `media` cannot open a camera | `docs/protocol/call-v2.md` (new field and new kind) | `clients/core/src/voice_v1.rs` v2 validation | Android v16 `CallController` | none |
| Video direction is always `sendrecv` in signaling; camera on/off is a track-enable flag plus a `media` control and **never** a renegotiation; trickle and renegotiation stay rejected | `docs/protocol/call-v2.md` (SDP) | not applicable (client rule) | Android v16 engine | none |
| Receiver accepts no control dated more than 5 s in the future; expired first-seen controls are rejected; a clock jump ends the negotiation | `docs/protocol/voice-v1.md:90-92,130-131` | core validation is clock-free by design (`clients/core/src/voice_v1.rs:1,27-38`) | `CallController.java:33-34,282-283` (`CLOCK_SKEW=5_000`) | A.8: the document does not say which layer enforces it; iOS must repeat the wall-clock checks in Swift |
| SDP: exactly one `m=audio` with Opus **followed by exactly one `m=video`**, both `UDP/TLS/RTP/SAVPF` and `a=sendrecv`, bundled on the audio section's single DTLS-SRTP fingerprint (SHA-256, one) and ICE context, RTCP mux required in audio and allowed once in video, each transport attribute repeated at most once with an identical value; video payload types only `H264/90000`, `VP8/90000` and the `rtx`/`red`/`ulpfec`/`flexfec-03` helpers, at least one of H.264 or VP8 mandatory; no data channel, no trickle, no renegotiation | `docs/protocol/call-v2.md` (SDP) over `docs/protocol/voice-v1.md:55,62-68` | `clients/core/src/voice_v1.rs:84-194` (`validate_sdp`) with the v2 sections | `CallController.java:290` (v15's 6144 bound, superseded by call-v2) | none; iOS SDP passes `validate_sdp` unchanged (`SdpCompatibilityTests`), and the client stops rather than patching the core if it ever does not |
| SDP size: call-v2 raises the core bound to 12288 bytes, but a `call` control travels in one frame2 envelope whose **measured** ceiling is 10040 bytes, so this client caps a description at 9000 bytes before the core sees it and refuses rather than rewrites | `docs/protocol/call-v2.md` (SDP limit) and `docs/protocol/first-contact-v1.md:64-76` (frame2) | `clients/core/src/voice_v1.rs` (`MAX_SDP`); `clients/ios/ParanoidKit/Sources/ParanoidKit/Voice/SdpExtract.swift` (`maxSdpBytes`) | `TextEngine.java:138-144` (the line scan this cap is written from) | none; the 12288-byte figure in the document is not reachable through one envelope, which is a property of the transport, not a contradiction |
| Codec order: H.264 (hardware, constrained baseline) first, VP8 as the mandatory fallback, applied through `setCodecPreferences` and never to finished SDP text; VP9 and AV1 exist in this libwebrtc build and are dropped in configuration | `docs/protocol/call-v2.md` (owner decision 2026-09-11) | not applicable (engine configuration) | `WebRtcAudioEngine.java:263-284` (Android v16) | none |
| Readiness slots: at most 8, one per peer, 45 s monotonic expiry; knock limits 6 per peer per minute and 24 globally; at most one live call, busy otherwise; restart destroys slots | `docs/protocol/voice-v1.md:84-97` | not applicable (volatile controller) | `CallController.java:35,156-168,169-180` | none |
| Deadlines: ring/negotiation 45 s, ICE recovery 10 s, heartbeat every 10 s, silence 30 s terminates, maximum call 15 min | `docs/protocol/voice-v1.md:114-117,132` | not applicable | `CallController.java:33-34` | none |
| Call controls enqueue only while the realtime lane is connected, at most one heartbeat outstanding, fewer than 16 pending peer envelopes; enqueue failure ends the call locally | `docs/protocol/voice-v1.md:144-153` | `clients/core/src/clean_service.rs:387-398,860-866` | `CallController.java:92,102,174` (`online` gate) | none (owner finding B.5: transient online-flag loss drops `ready`; iOS debounces from the start) |
| Consent: microphone requested only from explicit Call/Answer intent; ringing never creates media; relay/direct metadata disclosed before consent. The camera is opened only by an explicit toggle or a video-call intent, and a refusal downgrades the call to audio without changing any section's direction | `docs/protocol/voice-v1.md:105-112`; `docs/protocol/voice-turn-v1.md:98-103`; `docs/protocol/call-v2.md` (consent deltas) | not applicable | `CallController.java:89-107` | none |
| Screen capture of a call: Android sets `FLAG_SECURE` on the call window alone, which removes it from screenshots, recordings and mirroring. iOS has no equivalent flag, so this client covers the video stage while `UIScreen.isCaptured`, leaves the controls reachable, and cannot refuse a screenshot or the app-switcher snapshot | none in `docs/protocol/` (platform rule; the protocol has no screen-capture clause) | not applicable | `MainActivity.java:478` (Android v16) | **Deliberate non-parity**, recorded as an open gap in [verification.md](verification.md) rather than claimed as equivalent |
| Foreground-only delivery: no APNs/PushKit registration, no `aps-environment`, no background refresh, no CallKit; a call to a locked or closed iPhone ends in the caller's 45-second `timeout` | none in `docs/protocol/` (delivery is a platform capability; [realtime v1](../../protocol/realtime-v1.md) assumes only a live long poll) | not applicable | `TextEngine.java:86,90,158-161` (the Android foreground rule this is written from); the Android push wake of RFC-0020 has no iOS half | none; it is a documented user-visible limitation, and threat-model boundary 8 stays unused by this client |
| TURN: `GET /v2/voice/turn` with empty body via `operation:"turn"`; strict six-field response, `v` 1, `ttl` 1200, two exact `turn:` URLs on the realm host, remaining lifetime 1000..1205 s; credentials volatile; `Cache-Control: no-store` | `docs/protocol/voice-turn-v1.md:22-30,52-67,84-94` | `clients/core/src/clean_service.rs:719`; `server/src/self_service_http.rs:113-125,451-456,507-538`; `server/src/voice_turn.rs:22,125-128,203-204` | `VoiceRelayConfig.java:17-18,65-70`; `RealtimeLoop.java:124-131` | none |
| Authenticated 404 `turn_disabled` (or a legacy 404) from the pinned origin permits the disclosed direct-ICE compatibility mode; a TLS failure, a timeout, a malformed 200 or a relay failure ends the call without fallback | `docs/protocol/voice-turn-v1.md:131-139` | `server/src/self_service_http.rs:531-535` | `RealtimeLoop.java:124-131` and relay lane | none; RFC-0021 question 5 was answered on 2026-09-12 by the owner's agents in [issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27) and the client implements that answer |
