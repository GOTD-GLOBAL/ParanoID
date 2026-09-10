---
status: draft
owner: client
last_reviewed: 2026-09-09
---

# Core voice controls

The core implementation for [REQ-CALL-003](../../product/voice-calls.md) extends
the existing clean core3 channel without a new snapshot field or call-signaling server route.
[Voice-v1](../../protocol/voice-v1.md) owns the exact wire contract;
[RFC-0017](../../rfcs/0017-voice-calls.md) and proposed
[ADR-0011](../../decisions/0011-voice-calls.md) record its reviewed design.

## Entry points and persistence

`send_call_v1` accepts a retained peer account and strict typed call body. The
native code checks active registration, immutable contact/block context, SDP
and body bounds, and fewer than 16 pending peer envelopes before encrypting a
new immutable frame2 outbox entry. The ordinary 400-envelope text limit remains.
There is no arbitrary plaintext/signature or unbound server-SDP authority.

`receive_v2` uses the existing signed introduction and strict Olm context. An
unknown sender's call control cannot commit a newly allocated contact. Valid
controls produce transient `call_event` with `account`, authenticated `channel`
and typed `body`, only alongside `acceptance: accepted`. The event is outside
`state`; view/reopen, duplicate, rejection and failed-save paths produce no
runtime call authority. The Android adapter must seal and commit the full
candidate before forwarding it to the volatile controller.

Calls advance the shared ratchet and cursor but create no text history, receipt,
receipt commitment or durable Event row. This prevents periodic heartbeats from
consuming the text replay ledger. After all existing sessions reject decryption,
a prekey whose session ID matches a retained session cannot recreate that
session from the reusable fallback key. Retained sessions are never evicted.
The guard prevents ciphertext replay at a forged higher relay sequence from
reconstructing consumed message keys and exhausting session slots.

Wall-clock freshness, live nonces, explicit consent, call sequences and media
generations belong to the volatile runtime controller after cryptographic
acceptance. A native accepted control alone does not ring, capture a microphone
or establish a call. Existing server metadata, storage/sequence bounds and
reusable-fallback initial-secrecy limitations remain.

## Actual compatibility evidence

[Native validation](../../project/evidence/voice-calls-20260909/core-implementation-validation.json)
records 14 voice tests within 62 supported native tests. Twenty simulated
maximum-duration calls exchange 3700 actual Olm controls, then text/receipts
continue without call Event growth. Higher-sequence prekey replay, malformed
SDP/body/bindings, unknown/blocked peers and resource boundaries are covered.

The [real old/current JNI fixture](../../project/evidence/voice-calls-20260909/v8-compatibility-result.json)
loads actual v8 Java/JNI and the current implementation. Core3/sealed4 reopen
unchanged in both directions; v8 rejects unsupported call controls and still
exchanges authenticated text/receipts after the ratchet gap. These checks use
synthetic state in separate JVMs, without a physical installation or network.

[Implementation gates](../../operations/voice-calls-local.md) retain final-media,
APK, independent exact-source review and historical-test boundaries. This core
fixture does not prove audio, reliable background calls or permanent architecture
acceptance. [Existing text compatibility](self-service.md) remains applicable.

## Optional relay signing

[REQ-CALL-006](../../product/voice-relay.md) adds only fixed `turn` without an
envelope ID to the existing native session selector. It signs GET `/v2/voice/turn`
with an empty body and fresh nonce after full saved-context validation. Five
realtime signing tests now pass, including independent transcript/signature
verification and selector/context negatives. It exposes no arbitrary signer and
changes no persistent client schema. [Canonical contract](../../protocol/voice-turn-v1.md).
