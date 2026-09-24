---
status: draft
owner: identity
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-24
---

# ADR-0016: Proposed Devnet server identity authentication

## Context and proposed choice

[RFC-0027](../rfcs/0027-solana-server-authentication.md) records exact local
private synthetic-data scope, human risk owner, Telegram provenance and requirement
conflict. [The v3 contract](../protocol/identity-login-v3.md) proposes separate
Devnet realm/database, dual owner/device proof for enrollment/replacement,
device-only status, stable membership and immutable transport generations.
No on-chain login transaction or automatic contact-key substitution.

Alternatives: retain disconnected nickname (does not deliver login); reuse owner
as messaging root/Olm key (breaks separation); silently rekey immutable contacts
(breaks peer verification); implement contact rotation now (separate larger scope).

## Consequences and retained risks

Fresh contact exchange after replacement; no history restoration from seed.
Existing wrapped owner key stays on phone: a compromised owner device can compete
for takeover. One successful replacement/day and eight lifetime generations are
explicit private-alpha limits, not secure recovery after seed theft or unlimited
production recovery. Current-generation traffic/status survives generation cap.
Existing peer capacity can be exhausted by repeated contact replacement. RPC is
trusted; public blockchain identity allows inter-server correlation. Existing
media and in-flight content-free push cannot be recalled. These need human risk
acceptance, not a fabricated AI/human approval.

## Disposition gates

Status remains draft. No approval date, URL or accepted marker is fabricated.
Permanent owner scope/decision evidence is pending. REQ-ID-006 scoped reconciliation
and all limits above must be included in that disposition. Fresh independent
Opus5.5 technical review must close blockers; AUTH-01..08 and code/artifact review
must precede relevant delivery claims. Policy ADR0003 is not application approval.
Local implementation preparation is authorized in the current Telegram task;
merge, migration, phone release and deployment remain separately gated.

## Migration and rollback

No current DB/phone migration or deletion. New mode refuses legacy/populated DB.
Rollback never restores lower membership generations or re-enables retired keys.
Do not route new-cohort clients to the old v2 service. Any operational cutover
requires exact source/artifact review, rollback design and explicit authorization.
