---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-11
---

# ADR-0013: 1:1 camera video on the retained E2EE call channel

## Proposed decision

Implement [RFC-0019](../rfcs/0019-video-calls.md) as [call-v2](../protocol/call-v2.md):
a camera video track on the same authenticated DTLS-SRTP PeerConnection as
Opus audio, pre-negotiated in the offer/answer so that camera on/off is a
track flag plus an informative encrypted `media` control, never a
renegotiation. H.264 (hardware) is offered first with VP8 as the mandatory
fallback; the video section is bundled on the single authenticated
fingerprint/ICE context. No media keys or decodable frames enter the
messaging server or the TURN relay. Groups, SFU and screen sharing stay out
of scope and require a separate RFC with true group media E2EE.

## Authority and required reviews

The owner (Сергей Мальцев, Telegram, 2026-09-11) requested video calls and
resolved the two open questions (H.264 first with VP8 fallback; speaker on
video unless a headset is connected). This is task provenance for local
implementation, tests, a retained-signer APK, a PR and — because the owner
directed that updates flow through the in-app channel — publication of the
candidate to the existing `/v2/updates/android` feed. It is not permanent
architecture acceptance. Under [ADR-0003](0003-closed-alpha-review-policy.md)
a fresh independent AI review is the second reviewer inside the private
synthetic-data alpha; qualified human review remains required before
sensitive data, public release or production claims.

## Consequences

- Alpha break: v2 rejects v1 call bodies; both alpha phones must update.
  Text messaging is unaffected across versions.
- Relay traffic per call rises roughly threefold; the authorized UDP range
  is unchanged and bounds concurrent relayed calls.
- New assets/threats are in [the video threat delta](../security/video-v1-threats.md).
- No storage schema change; rollback is a newer same-signer audio-only build.

## Validation

Native call-v2 fixtures, controller video consent/signaling tests, UI and
background contract tests, retained-signer APK checks and the owner's
physical two-phone video acceptance (Wi-Fi/mobile, toggle, camera switch,
background pause/resume, negotiated codec) gate the candidate.
