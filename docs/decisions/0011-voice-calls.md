---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-09
---

# ADR-0011: Retained-channel WebRTC voice candidate

## Proposed decision

Use mature libwebrtc/Opus on native Android and strict call-v1 E2EE controls on
the existing signed account-ID channel for the bounded one-server 1:1 alpha.
Exact dependency, control contract and alternatives are in
[RFC-0017](../rfcs/0017-voice-calls.md) and [voice-v1](../protocol/voice-v1.md).
Preserve root/device/contact/TLS bindings, working v8 text and storage shape.
No media keys or decoded audio enter the messaging server or a TURN relay.

## Authority and required reviews

The [owner task](../product/voice-calls.md) explicitly authorizes this local
implementation/testing/APK/PR after the verified PR18 merge. It does not approve
this ADR permanently. Human decision/risk owner is martadvix-web; permanent
approval permalink and architecture disposition are outstanding. The accepted
[closed-alpha policy](0003-closed-alpha-review-policy.md) permits fresh independent
AI second review only within explicitly scoped private synthetic-data alpha.
Fresh `claude-fable-5` design and exact-source final reviews must record actual
success/model identity, findings, fixes and closure; they are not human audits.
Qualified independent human review remains required before sensitive data,
public release or production claims. No live TURN/server action or PR merge.

The [independent design reports and provenance](../project/evidence/voice-calls-20260909/README.md)
now record successful initial review and separate exact-contract closure. Both
raw model-usage maps contain `claude-fable-5` and `claude-haiku-4-5-20251001`;
neither is represented as a sole-model or human review. Closure opened the
implementation gate after correcting heartbeat ledger exhaustion, reusable
prekey replay, bounded outbox admission and delayed-revocation claims. It did
not approve final code, artifacts or this ADR. Permanent human architecture
approval and final implementation review remain outstanding.

## Consequences and validation

Native media adds substantial APK size and supply-chain/audio-lifecycle risk.
IP/timing metadata remains visible; direct ICE has connectivity limits without
authorized relay deployment. Call controls advance existing ratchets/cursors and consume retained server
opaque-history capacity, without consuming the text Event ledger. See [threat/test mapping](../security/voice-v1-threats.md).
No acoustic superiority or reliable Doze/Bluetooth claim without measurements.

Validate TDD auth/consent/replay/resource boundaries, actual WebRTC decoded tone,
Android UI/media permission/routing, retained v8 text/state and artifact signer.
Stop/dispose media on terminal paths; restart never resumes a call. Roll back
through a reviewed newer same-signer binary preserving data; do not uninstall,
clear storage or assume Android permits a version downgrade. Tests and actual
artifacts are tracked in [the local record](../operations/voice-calls-local.md).
