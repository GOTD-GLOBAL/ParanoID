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

## Bounded owner scope amendment — 2026-09-10

The [one-host operational record](../operations/voice-single-host.md) preserves
the exact owner reply and distinguishes bot-recorded Telegram provenance from
permanent human ADR acceptance. It supersedes the earlier absence of bounded
public-listener authority after mandatory tests and fresh review; this ADR
remains proposed. REQ-DEPLOY-003 adds one coordinated installer, with current
TLS/data/identity and neighboring services preserved.

## Subsequent reviewer identity clarification — 2026-09-10

The [direct owner clarification](../operations/voice-single-host.md#owner-clarification-of-independent-reviewer-identity-2026-09-10)
retains the completed original Fable architecture review and accepts subsequent
fresh independent Opus review under its actual identity. All substantive security,
TDD, threat analysis, final source/artifact and deployment gates remain mandatory.
This is a bounded review-process clarification, not permanent ADR acceptance or
permission to replace a failed/missing test with approval.

## Full rehearsal implementation proposal — 2026-09-10

The [separate VM profile and report contract](../operations/voice-vm-rehearsal.md)
preserves fixed production gates while exercising the same source, units, numeric
identities and policy inside a NIC-less disposable guest. Production availability
stays closed until the full runner, artifacts and actual results are reviewed.
The candidate now verifies real report/kit/log bytes and exact production plans;
this is evidence integrity, not authority to synthesize passing results. This ADR
remains proposed and no existing accepted decision is rewritten.

## Owner acceptance simplification — 2026-09-10

The owner (Сергей, Telegram, recorded in
[voice-single-host.md](../operations/voice-single-host.md#owner-acceptance-simplification--2026-09-10-telegram-сергей))
froze the VM full-rehearsal programme above. Production acceptance for this
decision's scope is now: the executed local loopback TURN acceptance
(TURN-RT01/TURN-ACL02, [evidence](../project/evidence/voice-local-acceptance-20260910/summary.md)),
a controlled journaled installation on the existing authorized host, and the
owner's physical two-phone call. The installer's `local-loopback-acceptance`
gate binds the executed report to the exact kit turnserver digest. Credential
expiry, quotas, ACL, E2EE, isolation and rollback obligations are unchanged.
This ADR remains proposed; the simplification is owner operational authority,
not permanent human ADR acceptance.
