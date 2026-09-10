---
status: proposed
owner: product
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Private-alpha 1:1 voice scope

The owner instructed: “18 pr тестируй, ошибки устраняй и мержим. Следующий этап -
голосовые звонки.” Then: “Как смержишь 18 - делай голосовые вызовы”. This is direct
task provenance; no Telegram permalink or permanent architecture acceptance is
invented. [Issue #19](https://github.com/GOTD-GLOBAL/ParanoID/issues/19) records the
scope. PR18 was independently checked MERGED at `2026-09-09T22:01:42Z`, merge
commit `366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f`.

The task authorizes local implementation, synthetic tests, a retained-signer APK
and a client PR. It does not authorize merging that PR, phone automation, live
server changes, new public TURN/firewall/DNS listeners or sensitive-data use.
The [RFC](../rfcs/0017-voice-calls.md), [proposed ADR](../decisions/0011-voice-calls.md)
and [canonical wire contract](../protocol/voice-v1.md) precede protected code.

| ID | Required outcome | Evidence gate |
| --- | --- | --- |
| REQ-CALL-002 | Real 1:1 encrypted Opus audio over a mature WebRTC engine | Actual Android and compatible endpoint ICE/DTLS/SRTP negotiation, packets and decoded synthetic tone; acoustic quality separately measured on phones |
| REQ-CALL-003 | Call signaling binds immutable account/device/realm/channel, fresh call identity and media fingerprint/ICE context | Actual encrypted control and negative signature, recipient, context, fingerprint, replay, restart, block and revocation tests |
| REQ-CALL-004 | Explicit outgoing/answer consent, permission and honest call states with complete cleanup | Answer/reject/cancel/busy/crossing/missed/timeout, mute/routes, terminal cleanup, save-failure and lifecycle tests; incoming ring never captures audio |
| REQ-CALL-005 | Bounded resources, reconnect behavior, metadata disclosure and deployment isolation | Size/candidate/rate/TTL limits, real local media, failure/recovery checks, exact separate TURN deployment request |

REQ-MSG-002/003/004/005/006, REQ-ID-005/007/008, REQ-CLIENT-003/004 and
REQ-SEC-001 remain protected. Retain v8 identity, contact pins/trust, history,
outbox, TLS and signer. Calls never mean identity verification. Groups, video,
SFU, federation and a wholesale XMPP migration are outside this implementation.
The owner permits a GPL-compatible open client and mature OSS reuse; specific
dependency provenance and independent design/final review remain required.

## Implementation checkpoint

The [retained evidence](../project/evidence/voice-calls-20260909/README.md) records
successful fresh design review and exact-contract closure, 62 supported native
tests including 14 voice tests, real v8/current Java/JNI compatibility, committed
event dispatch and the Java call lifecycle tests. The native control path,
Android call UI/service and WebRTC adapter are implemented; Android compilation
passes. Separate real Android/aiortc direct and isolated local TURN relay tests
pass decoded synthetic audio, mute/unmute and capture/route cleanup. Full app acceptance passes 14 steps; final inset UI
verification and signed APK checks pass, with independent final code review pending in [the local record](../operations/voice-calls-local.md).

Physical OPPO acoustics, noisy-room AEC, Bluetooth/headsets, mobile network
handover, Doze, force-stop and reliable background incoming calls require actual
separate evidence. No comparative audio-quality claim follows from codec choice.
