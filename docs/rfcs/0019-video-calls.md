---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-09-18
required_reviewers: []
last_reviewed: 2026-09-11
---

# RFC-0019: 1:1 video calls on the retained voice contract

## Required review rationale

Protected domains touched: end-to-end encryption semantics (media E2EE claim is
extended from audio to video), protocol compatibility (call-v1 body and SDP
validator change), deployment topology (relay bandwidth and port scope), and
foundational dependencies (video codec path of the pinned libwebrtc build). Under
[ADR-0003](../decisions/0003-closed-alpha-review-policy.md) a fresh independent
AI design review may serve as the second reviewer only inside the private
synthetic-data alpha; independent qualified human review remains required before
sensitive data, public release or any production quality claim.

## Summary

Add camera video to the existing 1:1 E2EE voice call. The video track rides the
same authenticated DTLS-SRTP PeerConnection that already carries Opus audio, so
the messaging server and the coturn relay keep seeing only ciphertext. A call
starts as audio; either side may turn the camera on or off during the call
without renegotiation by pre-negotiating one inactive-capable video section.
No groups, no SFU, no screen sharing in this version.

## Motivation

The owner (Сергей Мальцев, Telegram, 2026-09-11) requested video calls in chats:
"Давай добавим в наши чаты возможность видео вызовов." REQ-CALL-001 already
names audio and video communication. Voice 1:1 calls exist on the live host
([current state](../project/current-state.md)); video is the smallest next step
that reuses the reviewed signaling, consent, relay and cleanup machinery instead
of introducing new transport.

## Goals and non-goals

### Goals

- 1:1 video call between two ParanoID devices with the same E2EE property as
  voice: no media keys or decodable frames on the server or relay.
- Camera never starts before explicit local user action; incoming ring shows no
  preview and captures nothing.
- Start as audio, add/remove video mid-call, switch front/back camera, and
  degrade back to audio on a weak network without dropping the call.
- Works through the existing coturn relay within the authorized port scope.

### Non-goals

- Group video, SFU, conferences (separate RFC; needs true group media E2EE).
- Screen sharing, filters, virtual backgrounds, recording.
- Picture-in-picture, Android Auto, wearables.
- Any acoustic or picture quality claim without measured evidence.

## Proposed design

### Signaling (call-v1 → call-v2 body)

The [voice-v1 contract](../protocol/voice-v1.md) rejects any `m=video` section.
This RFC proposes a versioned extension:

- `v` becomes 2. Implementation note (2026-09-11): a mixed v1/v2 call is
  **not** supported. A v1 client cannot accept unknown fields, and keeping two
  parallel body shapes in the strict validator was judged riskier than an
  alpha version break; both alpha phones update through the in-app feed.
  Text messaging is unaffected across versions. The exact successor contract
  is [call-v2](../protocol/call-v2.md).
- New boolean field `video` on every body: capability on
  `knock`/`ready`/`offer`/`answer`, camera state on the new `media` kind,
  `false` on `heartbeat`/`end`. All other fields and limits are unchanged.
- Complete SDP may contain exactly one audio section (unchanged rules) plus at
  most one video section, DTLS-SRTP, RTCP mux, the same single fingerprint and
  ICE context (BUNDLE). Owner decision (Telegram, 2026-09-11): H.264 is offered
  first (hardware encoder/decoder where the device provides it, constrained
  baseline profile), VP8 stays as the mandatory fallback so any two devices
  can still negotiate video. Direction of the video section is `sendrecv` when the
  local camera is intended, otherwise `recvonly`/`inactive`. Still no trickle
  and no renegotiation: camera on/off flips the track `enabled` flag and sends
  the existing E2EE control channel a new `media` control (`kind: "media"`,
  `video_on: true|false`, `seq` monotonic) so the peer UI shows honest state
  instead of inferring it from a black frame.
- SDP limit rises from 6144 to 12288 UTF-8 bytes; the frame2 limit (16384)
  stays. Candidate limits unchanged. Video payloads map only to H.264/VP8 and
  RTP helper formats; VP9/AV1 are rejected.

### Media

- Same PeerConnectionFactory; add `DefaultVideoEncoderFactory`/`DecoderFactory`
  from the pinned `io.github.webrtc-sdk:android:150.7871.01` (no new dependency).
  Codec preference order in the offer: H.264 (hardware, constrained baseline)
  then VP8; the SDK picks H.264 when both sides support it and falls back to
  VP8 otherwise. Devices whose H.264 hardware encoder is missing or broken
  (known on some OPPO/MediaTek firmware) must still complete a VP8 call; this
  is a required test, not an assumption.
- Capture through `Camera2Enumerator`, default front camera, 640×480@24 fps
  initial, capped at 720p; sender uses the SDK's built-in bandwidth estimation
  and simulcast is off (1:1 only).
- Audio behaviour is unchanged. Owner decision (Telegram, 2026-09-11): turning
  video on routes audio to the speakerphone, except when a wired headset or
  Bluetooth headset is connected, in which case that route is kept. Turning
  video off restores the previous route.

### Consent and lifecycle

- New foreground service type `camera` added alongside `microphone` on
  `VoiceCallService`; permission `CAMERA` is requested only on the first
  "turn video on" tap, never on incoming ring.
- All terminal paths already dispose tracks/PeerConnection; the video
  capturer, EglBase and surface views are added to the same owned-disposal set.
- Backgrounding the app pauses the camera (track disabled, `media` control
  `video_on: false`) and keeps audio; returning re-enables if the user had it on.
- Maximum call duration, heartbeat, deadlines and busy rules are unchanged.

### Network degradation

- The SDK's congestion controller lowers video bitrate first; if the estimated
  send bandwidth stays below 150 kbit/s for 10 s the client disables its video
  track and shows "видео приостановлено"; audio continues. Manual re-enable
  is always allowed.

## Alternatives

- Separate PeerConnection for video: doubles ICE/DTLS, breaks single-fingerprint
  authentication; rejected.
- Renegotiation on camera toggle: needs trickle/renegotiation semantics that v1
  deliberately rejects; pre-negotiated inactive section avoids it.
- Start with group video via LiveKit/mediasoup: violates the owner's "SFU must
  not decrypt" requirement until frame-level E2EE (SFrame-style) is designed;
  deferred to a separate RFC.
- Jitsi/Matrix Element Call reuse: brings its own identity and signaling stack;
  contradicts the retained Rust identity/Olm channel.

## Security and privacy

- E2EE property is identical to voice: DTLS-SRTP keys are endpoint-only and the
  fingerprint is authenticated inside the Olm-encrypted, signed control body.
- New asset: camera frames. Threats: camera activation without consent (control
  by explicit tap and separate foreground type), preview leak in recents
  (FLAG_SECURE on the call activity), stale capturer after crash (owned-disposal
  set), peer showing video while claiming off (`media` control is informative
  only; the UI states what is *received*, not what the peer claims).
- Metadata: relay and server additionally learn that a call carries a second
  RTP stream and its bitrate profile; IP/timing exposure unchanged.
- Threat model delta: [video-v1-threats](../security/video-v1-threats.md).

## Compatibility and migration

- v15 (audio only) and a v2-capable client interoperate as audio-only; a v2
  body never reaches a v1 peer. Old-code reopen and cross-version call tests
  are required, as for voice.
- No storage schema change; call controls remain non-durable events.
- Rollback = ship a newer same-signer audio-only build; no data migration.

## Operations and observability

- Relay: video roughly triples per-call relay traffic (≈0.3–1.5 Mbit/s per
  direction). The authorized UDP 40000–40015 range still limits concurrent
  relayed calls; port scope is unchanged by this RFC. Host bandwidth accounting
  is added to the deployment checklist before enabling video on the live host.
- No new listeners, DNS or credentials.

## Validation plan

1. Native tests: v2 body validation, v1/v2 negotiation matrix, SDP validator
   with one video section, rejection of two video sections or mismatched
   fingerprint/ICE, size limits.
2. Controller tests: camera never created on ring, toggle sequence, background
   pause/resume, disposal on every terminal path, degradation trigger.
3. Real media: Android ↔ aiortc direct and through the isolated coturn fixture
   with a synthetic moving pattern; decoded frame count > 0 both ways,
   zero decoded frames while video is off, audio unaffected.
4. Two physical phones on the live host: owner's acceptance call (Wi-Fi and
   mobile), camera switch, toggle, background/return, weak-network degradation.
5. Measured: APK size delta, battery per 10-min video call, CPU on OPPO,
   and which codec (H.264 vs VP8) each physical test pair actually negotiated.

## Open questions

- Whether `media` video-on/off control should also be shown in chat history
  (currently: no, calls leave no history).

Resolved by the owner on 2026-09-11 (Telegram): offer H.264 first with VP8
fallback; speakerphone on video start unless a wired/Bluetooth headset is
connected.

## Decision and follow-up

- Disposition: proposed; owner resolved the open questions on 2026-09-11 and
  directed implementation (Telegram); permanent acceptance pending.
- Decision-owner approval permalink: pending (Telegram thread, no permalink invented).
- Delegation evidence permalink, if applicable: not applicable.
- Required-review evidence permalinks: pending fresh independent design review.
- Resulting ADR: [ADR-0013](../decisions/0013-video-calls.md) (proposed).
- Closure rationale: pending.
- Replacement RFC for `superseded`: not applicable.
- Implementation issues: to be opened after disposition.
