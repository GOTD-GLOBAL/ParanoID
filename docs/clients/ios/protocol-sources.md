---
status: draft
owner: ios
last_reviewed: 2026-09-11
---

# iOS client behaviour: rule to source table

Skeleton for [RFC-0020](../../rfcs/0020-ios-client.md). Every iOS behaviour is
written from the protocol document and the shared core or server code; the
Java client is a cross-check only. Line numbers refer to `main` at `fe9c26c`
(Android v15). The `Discrepancy` column names the numbered doc-to-code
findings reported to the owner ("Findings from iOS-client preparation", section
A); those documents are not corrected here (RFC-0020 question 10). The table
grows as the client is written; rows without a discrepancy say `none`.

## Core bridge

Rules of the Swift adapter over the C-ABI bridge
(`clients/ios/ParanoidKit/Sources/ParanoidKit/Core/`); line numbers of
`clients/ios/**` refer to the client branch itself.

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| A reply carrying an `error` member rejects the operation with that code and changes nothing; a NULL or non-JSON reply is a native failure; `input_limit` (8 MiB state, 65536-byte request), `invalid_request` and `invalid_state` are decided by the core, never by the client | `docs/clients/core/self-service.md:97-100,170-171` | `clients/core/src/lib.rs:418-424`; `clients/ios/bridge/src/lib.rs:28-56` (`paranoid_core_command`) | `SelfServiceClient.java:55-61` (`nativeCall`) | none |
| The next snapshot is the top-level `state` member of the reply; it is persisted before any network side effect, and an unchanged snapshot is not written again. iOS takes the member verbatim (`JsonSpan`) and compares it as text; Android compares after an `org.json` round trip. Equivalent because every core reply is serialised through `serde_json::Value` (sorted `BTreeMap` keys, `preserve_order` absent from `clients/ios/bridge/Cargo.lock`), so one state is always one text | `docs/clients/core/self-service.md:97-100` | `clients/core/src/lib.rs:220-227` and `clients/core/src/clean_service.rs:312-345` (`reply`) | `SelfServiceClient.java:69-76` (`apply`) | none |

## Registration

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| Registration challenge intent is exactly `{credential, purpose:"register", method:"POST", path:"/v2/registration/commit", body: SHA256("{}")}`; other purposes use `/v2/auth/challenge` | `docs/protocol/self-service-v2.md:26-33` | `clients/core/src/self_service.rs:250-261` (purpose derived from method/path/body); `server/src/self_service_http.rs:175-181,206` | `clients/android/src/org/paranoid/text/SelfServiceClient.java:112-126` | none |
| Proof transcript `LP("paranoid-proof-v2", id, nonce, epoch, expires, realm, pin, account, device, credential, purpose, method, path, body)` and `Authorization: ParanoidV2 <id>.<signature>`; challenge context must equal the saved credential | `docs/protocol/self-service-v2.md:35-45` | `key-protocol/src/proof_v2.rs:20-22`; `clients/core/src/self_service.rs:262-275` | Java only forwards the core result (`SelfServiceClient.java:125`) | none |
| Identity is created and upgraded to core schema 3 durably before the first network request; `create_identity{realm,pin}` then `upgrade_v2` | `docs/protocol/first-contact-v1.md:131-133` | `clients/core/src/lib.rs:439-469`; `clients/core/src/clean_service.rs:754-767` | `SelfServiceClient.java:80-84,128-134` | none |
| Registration/status response `{mode:"active",account,device,credential}` must match the local credential, otherwise `status_conflict`; then `prepare_contact_v2` publishes the fallback key | `docs/protocol/self-service-v2.md:50-51` | `clients/core/src/clean_service.rs:796-829` | `SelfServiceClient.java:131-134,186-189`; `RealtimeLoop.java:173-176` | none |
| Server bounds: eight new accounts per 60 s, 1024 accounts, identical retries free | `docs/protocol/self-service-v2.md:68-71` | `server/src/self_service_http.rs:336-345` | not applicable | none (input to RFC-0020 question 4) |
| Realm is the saved HTTPS origin without path; `pin` is SHA-256 of the server leaf SPKI DER; saved trust wins over compiled defaults | `docs/protocol/key-enrollment-v1.md:41-42`; `docs/protocol/first-contact-v1.md:31,45` | `clients/core/src/lib.rs:166-169,457-460` | `KeyClient.java:9-10,17-21,37-41`; `PinnedTls.java:18-21` | A.5: documents say `SPKI`, code says `pin` / `tls_pin` / `PARANOID_KEY_PIN`; same value |

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

## Receive

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| `GET /v2/events?after=<cursor>&limit=20`: wait at most 20 s within session life, 25 s handler bound; client read timeout must exceed it | `docs/protocol/realtime-v1.md:96-100,138-142,153-154` | `clients/core/src/clean_service.rs:714-718` (core emits `limit=20`); `server/src/self_service_http.rs:599-603,611-621` | `RealtimeLoop.java:249-258` | A.7: `self-service-v2.md:59` shows `limit=50` and the server default is 50 (`self_service_messages.rs:19-20`); clients send 20 and reject larger pages |
| 429 `waiter_busy` triggers a bounded plain GET `/v2/messages` instead of blocking receive | `docs/protocol/realtime-v1.md:169-172` | `server/src/self_service_http.rs:604-608` | `RealtimeLoop.java:254-255` | none |
| On each resumed receive generation a signed `messages` fetch confirms readiness before the `events` long poll; the connection is published before delivering the page | `docs/protocol/voice-v1.md:137-142` | not applicable (client ordering) | `RealtimeLoop.java:252-256,259-271` | none |
| One event per complete candidate: `receive_v2` returns `acceptance`; persist the whole candidate before UI or receipt network; rejected or failed-save events publish nothing | `docs/protocol/first-contact-v1.md:138-146,173-178` | `clients/core/src/clean_service.rs:620,867-873` | `SelfServiceClient.java:65-78,203-204` | none |
| Delivery marks: one check only after `{id,sequence>=1}` server acceptance (`accepted_v2`), two checks only after the peer's authenticated receipt; never reading | `docs/protocol/self-service-v2.md:56-58`; `docs/protocol/first-contact-v1.md:122-127` | `clients/core/src/clean_service.rs:874-880` | `SelfServiceClient.java:197-200`; `RealtimeLoop.java:226-227` | none |
| Transport frame is byte `2` plus strict JSON, decoded at most 16384 bytes; raw frames stay strings until strict native parsing | `docs/protocol/first-contact-v1.md:64-76,90-92` | `clients/core/src/clean_service.rs:474` (`receive_candidate`) | `SelfServiceClient.java:65-78` | none |
| Missing or unreadable snapshot fails closed; no automatic reset or fresh identity | `docs/protocol/first-contact-v1.md:173-178`; `docs/clients/core/self-service.md:97-102` | not applicable (platform storage) | `StorageGuard.java:7-8`; `SelfServiceClient.java:9-11,25-27` | A.12: iOS Keychain outlives the app container, so an absent install marker is a fresh install (stale key deleted); with the marker present the rule is unchanged |

## QR and contacts

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| ContactV2 has exactly `type: "paranoid-contact-v2"`, `credential`, `bundle`, `fallback_key`, `signature`; fingerprint is SHA-256 of `LP("paranoid-contact-v2", credential fingerprint, bundle.device, bundle.realm, bundle.curve, bundle.one_time_key, fallback_key)` | `docs/protocol/first-contact-v1.md:20-29` | `clients/core/src/clean_service.rs:830-839` (`contact_text_v2` preview) | `SelfServiceClient.java:89-91` | none |
| Verify root credential, account derivation, Olm binding, realm/SPKI, canonical encodings and device signature before any trust; same account or same curve key as self is refused | `docs/protocol/first-contact-v1.md:31-36,43-45` | `clients/core/src/clean_service.rs:835,848` (`ContactV2::verify`); `clients/core/src/self_service.rs:93-103` | not applicable (core) | A.5 (naming only) |
| Pairing requires the user's explicit fingerprint confirmation (`verified: true`), otherwise `peer_not_verified`; rescanning the same contact is idempotent, a changed pin is refused | `docs/protocol/first-contact-v1.md:35-36,148-151` | `clients/core/src/clean_service.rs:840-850` | `MainActivity.java:499-504` (`Отпечаток совпадает`); `SelfServiceClient.java:92-94` | none |
| Contact text limit 4096 bytes at the core; QR payload at most 2048 bytes, rendered at 640 px (256..1280), ECC M, margin 4; scanner decodes frames up to 1280 px and prefers the largest bounded preview | none in `docs/protocol/` (rendering is a platform rule) | `clients/core/src/clean_service.rs:831-832,844-845` | `QrCodec.java:12-23`; `MainActivity.java:614`; `QrScanActivity.java:41-47` | none; iOS must reproduce the dense-QR preview fix (v15) with a camera preset of comparable resolution |
| Scanner is in-app only: no external scanner, URI, upload or persisted camera frame; camera denial leaves identity untouched and offers paste | none in `docs/protocol/` (UI/privacy rule) | not applicable | `QrScanActivity.java:14,26-29,37,51-58` | none |
| Block is orthogonal to trust: pins and history preserved, same channel on unblock; an unknown account cannot be blocked; at most 64 peers, 16 unverified | `docs/protocol/first-contact-v1.md:152,162-169` | `clients/core/src/clean_service.rs` block path (line to be added when the iOS flow is written) | `SelfServiceClient.java:95-97` | none |

## Voice

| Rule | Protocol source | Core / server | Java cross-check | Discrepancy |
| --- | --- | --- | --- | --- |
| Strict `CallV1` body: 14 exact fields, `v` 1, kinds `knock/ready/offer/answer/heartbeat/end`, per-kind nonce/seq/digest rules, `expires_ms - sent_ms` at most 45000, `end` reasons enumerated | `docs/protocol/voice-v1.md:39-61` | `clients/core/src/voice_v1.rs:26-83` | `CallController.java:36-37,278-295` | none |
| Receiver accepts no control dated more than 5 s in the future; expired first-seen controls are rejected; a clock jump ends the negotiation | `docs/protocol/voice-v1.md:90-92,130-131` | core validation is clock-free by design (`clients/core/src/voice_v1.rs:1,27-38`) | `CallController.java:33-34,282-283` (`CLOCK_SKEW=5_000`) | A.8: the document does not say which layer enforces it; iOS must repeat the wall-clock checks in Swift |
| SDP: exactly one audio `m=` with Opus, DTLS-SRTP fingerprint (SHA-256, one), RTCP mux, one ICE context, at most 16 candidates of at most 512 bytes, at most 6144 bytes total; no video, data, trickle or renegotiation | `docs/protocol/voice-v1.md:55,62-68` | `clients/core/src/voice_v1.rs:84-194` (`validate_sdp`) | `CallController.java:290` (6144 bound before core) | none; iOS SDP must pass `validate_sdp` unchanged (stop gate if it does not) |
| Readiness slots: at most 8, one per peer, 45 s monotonic expiry; knock limits 6 per peer per minute and 24 globally; at most one live call, busy otherwise; restart destroys slots | `docs/protocol/voice-v1.md:84-97` | not applicable (volatile controller) | `CallController.java:35,156-168,169-180` | none |
| Deadlines: ring/negotiation 45 s, ICE recovery 10 s, heartbeat every 10 s, silence 30 s terminates, maximum call 15 min | `docs/protocol/voice-v1.md:114-117,132` | not applicable | `CallController.java:33-34` | none |
| Call controls enqueue only while the realtime lane is connected, at most one heartbeat outstanding, fewer than 16 pending peer envelopes; enqueue failure ends the call locally | `docs/protocol/voice-v1.md:144-153` | `clients/core/src/clean_service.rs:387-398,860-866` | `CallController.java:92,102,174` (`online` gate) | none (owner finding B.5: transient online-flag loss drops `ready`; iOS debounces from the start) |
| Consent: microphone requested only from explicit Call/Answer intent; ringing never creates media; relay/direct metadata disclosed before consent | `docs/protocol/voice-v1.md:105-112`; `docs/protocol/voice-turn-v1.md:98-103` | not applicable | `CallController.java:89-107` | none |
| TURN: `GET /v2/voice/turn` with empty body via `operation:"turn"`; strict six-field response, `v` 1, `ttl` 1200, two exact `turn:` URLs on the realm host, remaining lifetime 1000..1205 s; credentials volatile; `Cache-Control: no-store` | `docs/protocol/voice-turn-v1.md:22-30,52-67,84-94` | `clients/core/src/clean_service.rs:719`; `server/src/self_service_http.rs:113-125,451-456,507-538`; `server/src/voice_turn.rs:22,125-128,203-204` | `VoiceRelayConfig.java:17-18,65-70`; `RealtimeLoop.java:124-131` | none |
| Authenticated 404 `turn_disabled` (or a legacy 404) permits the disclosed direct-ICE compatibility mode; every other failure ends the call without fallback | `docs/protocol/voice-turn-v1.md:131-139` | `server/src/self_service_http.rs:531-535` | `RealtimeLoop.java:124-131` and relay lane | RFC-0020 question 5 (parity is the default) |
