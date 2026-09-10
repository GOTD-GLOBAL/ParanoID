---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-09
---

# ADR-0012: Authenticated ephemeral voice relay credentials

Propose [RFC-0018](../rfcs/0018-voice-turn.md) and the exact
[voice TURN v1 contract](../protocol/voice-turn-v1.md) for
[REQ-CALL-006](../product/voice-relay.md). Local code/tests/package/PR work is
within the existing owner's task; public server/listener changes and permanent
architecture approval are not authorized. Owner: martadvix-web; no approval
permalink is invented. This ADR remains proposed.

A default-disabled endpoint uses the existing signed-session authority and
locked complete active binding check. Credentials expose no account label and
remain only in memory. Self-hosted coturn forwards peer-authenticated encrypted
media, with strict resource/peer limits and an isolated secret. Account revocation
prevents new issuance; issued relay bearer authority has the explicitly bounded
expiry/allocation residual. Direct compatibility is disclosed and bounded.

Fresh independent Fable design and final exact-source reviews are required for
this private synthetic-data alpha under the accepted
[closed-alpha policy](0003-closed-alpha-review-policy.md). Qualified independent
human review remains required before sensitive data/public production claims.
Tests must establish real issuer/coturn/app interoperability and preserve text,
state, TLS and signing identity. Deploying requires separate reviewed authorization.
