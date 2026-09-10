---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-09
---

# RFC-0017: Authenticated peer voice on the retained messenger

Implement [REQ-CALL-002–005](../product/voice-calls.md) under the owner's explicit
post-PR18 local task. Human risk/decision owner: martadvix-web. This proposed
design is not permanent ADR acceptance. Private synthetic-data alpha only;
fresh independent `claude-fable-5` design and exact final-source reviews are
required, with findings and actual model/success records retained. The owner
task is supplied provenance; permanent architecture-approval evidence remains
outstanding. No live deployment is authorized by this RFC.

## Proposal and alternatives

Retain native Android, Rust identity/Olm and authenticated pinned-TLS transport.
Add strict encrypted call controls inside the existing signed first-contact
channel, then direct endpoint-to-endpoint WebRTC DTLS-SRTP audio. The relay never
terminates media keys. Use `io.github.webrtc-sdk:android:150.7871.01`, the upstream
libwebrtc distribution selected by the completed independent design review.
Exact dependency/license correspondence remains part of final artifact verification.
Opus and the mature audio-processing/jitter/congestion pipeline use reliable SDK
defaults first. No custom codec, RTP crypto or home-grown jitter buffer.

The [wire contract](../protocol/voice-v1.md) owns all fields/state rules.
An encrypted knock/ready exchange creates fresh volatile per-call nonces before
an offer may ring. Restart destroys readiness, preventing an old offer from
recreating a call without changing the retained storage schema. Only the existing
ratchet/outbox/cursor state persists for calls. Call controls add no text replay
Event rows; an already retained Olm session must never be recreated from a
replayed prekey after failed decryption. This design correction prevents both
heartbeat exhaustion of text and replay under a forged higher relay sequence. Received controls become runtime
events only after successful sealed persistence. Calls never appear as text or
generate delivery receipts; unknown controls cannot create contacts.

Complete nontrickle SDP keeps v1 smaller and auditable. Its entire content is
authenticated; explicit fingerprint/ICE fields must match one bounded audio
transport. Renegotiation and trickle candidates are rejected in v1. Brief ICE
disconnection gets bounded recovery time; failure ends the call and allows a
fresh user call. A later reviewed version may add authenticated ICE restart.

The2026-09-10 reviewed relay-only correction publishes one immutable local SDP
snapshot after successful installation and a500 ms window following a usable
relay candidate, or earlier gathering COMPLETE. Direct mode retains COMPLETE.
This avoids waiting for unrelated gathering paths after relay allocation, at the
cost of omitting slower candidates. No trickle, renegotiation, deadline extension,
new signaling fields or failure downgrade is introduced. Actual RED evidence and
the fresh review precede this change; post-change media/artifact closure remains
required. The canonical publication rules are in the wire contract above.

Rejected alternatives: a mock call button; audio files over message history;
server-terminated audio; unauthenticated SDP; public free TURN credentials;
wholesale XMPP migration for this slice; a new persisted call schema without
demonstrated need. Future SFU requires actual group media E2EE, not hop DTLS.

## Security, compatibility and review

Read [the threat delta and test plan](../security/voice-v1-threats.md).
Core3/sealed4 remain unchanged in shape, preserving v8 bytes and keys. The
[actual old/current Java/JNI fixture](../project/evidence/voice-calls-20260909/v8-compatibility-result.json)
passes old-code reopen with pending and accepted call state, v8 call rejection,
and subsequent bidirectional text/receipts across the ratchet gap. This is local
JVM evidence, not a physical upgrade. A media failure cannot reset messaging or identity.
A confirmed authorization failure terminates local media. The retained signed-
session transport has one fresh-nonce retry for a first ambiguous HTTP401; only
a repeated rejection confirms failure on that path. No additional re-attestation
or deadline extension is added for calls. Encrypted heartbeats through
the authorized relay bound peer-revocation detection; they do not erase cached
content or provide instantaneous revocation of already transmitted audio.

Direct ICE may expose IP addresses to the peer. No public third-party STUN/TURN
is selected. Local direct media and isolated coturn tests are allowed; public
relay credentials/listeners require a concrete reviewed deployment request.
Dependency hashes, source/license correspondence, real media, Android UI,
retained-signer APK and independent final review are release gates. Compilation
alone satisfies none of the media/quality gates.

## Current disposition

Fresh design review and independent exact-doc closure completed before runtime
implementation. The [durable review/evidence record](../project/evidence/voice-calls-20260909/README.md)
preserves findings F-01–F-08, their design corrections, actual model usage and
successful invocation metadata. The native implementation, Java adapter and
controller tests now pass; Android UI/service/media code compiles. Actual direct
and isolated local TURN relay audio pass decoded-tone, mute and cleanup checks.
Full app acceptance passes 14 steps; final inset UI and signed APK checks
pass, with final exact-source review pending in
[the operations record](../operations/voice-calls-local.md).
[ADR-0011](../decisions/0011-voice-calls.md) remains proposed.
