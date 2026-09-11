---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-11
---

# Video trust delta and acceptance test plan

[RFC-0019](../rfcs/0019-video-calls.md), proposed [ADR-0013](../decisions/0013-video-calls.md),
[call-v2](../protocol/call-v2.md). Extends [the voice delta](voice-v1-threats.md);
everything there remains required. Human residual risk owner: martadvix-web.
Private synthetic data only; no human audit or production assurance is claimed.

```text
Voice-v1 boundary unchanged: Olm/frame2 call control -> sealed commit ->
  transient call state -> explicit consent -> WebRTC DTLS-SRTP (direct/relay)
New asset: camera frames (local capture, remote decode, on-screen render)
New control: informative `media` (camera on/off claim), never authority
```

| Threat | Required control | Tests before candidate handoff |
| --- | --- | --- |
| Camera starts without consent (ring, knock, Answer, peer control) | Capture only from explicit local toggle / explicit video-call intent after media authority; `CAMERA` requested only there; port refuses without grant | Controller: no `mediaVideo` on knock/ready/ring/Answer/forged `media`; UI contract: `CAMERA` request only in toggle path; engine: `SecurityException` without grant |
| Forged `media` control opens or hides video | `media` is informative; validated like heartbeat (nonces, digest, monotonic seq); cannot change tracks | Replay/lower-seq/forged-video-flag/v1 bodies ignored without effect |
| Video section smuggles a second transport or key | One bundled fingerprint/ICE context; per-section transport attrs must equal; SDES rejected; only H.264/VP8(+helpers) | Native: extra `m=video`, second fingerprint/ufrag, VP9/AV1, `recvonly`, SDES, >12288 bytes rejected; libwebrtc-style repeated attrs accepted |
| Camera frames leak to recents/screenshots | `FLAG_SECURE` on the call window | UI contract test |
| Camera keeps running in background | `onPause` disables camera (audio continues); resume restores; permission dialog exempt | UI contract test; physical check |
| Stale capturer/EGL after crash or terminal path | Owned-disposal set includes capturer, surface helper, video tracks/sources, renderers, EGL | Engine cleanup order; app acceptance redial |
| Foreground type promotion refused by OS | Promotion failure -> `videoUnavailable` -> audio-only + `media:false` | Service path review; physical check on Android 14/15 |
| Bandwidth exhaustion / relay port scope | SDK congestion control; 640x480@24 cap; relay range unchanged | Physical weak-network check; relay traffic measured |
| Codec hardware defects (some OPPO/MediaTek H.264) | VP8 mandatory fallback; call must complete on VP8 | Physical pair test records negotiated codec |
| Alpha version skew (v15 vs v16) | v2 rejects v1 and vice versa; text unaffected | Native strict-shape test; both phones updated via feed |

Evidence required before the candidate is handed to the owner: native
`voice_calls` suite green with the v2 fixtures, `CallControllerSmoke` video
section green, UI/background/update contract tests green, retained-signer
APK verification, and the owner's physical two-phone video call (Wi-Fi and
mobile), camera toggle/switch, background pause/resume, and negotiated codec.
