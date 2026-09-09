---
status: draft
owner: architecture
last_reviewed: 2026-09-09
---

# RFC-0012: Self-service registration and general direct messaging

## Scope and authority

[Issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16) and the
[product brief](../product/self-service-messenger.md) replace operator-dependent
onboarding as the target. Sergey requested implementation in Telegram with
“Поехали issue 16”. This records local development intent, not a permanent
architecture approval, authorization to merge, or expanded live admission policy.
No stable Telegram permalink is available in this tool context. Human decision
and risk owner remains `martadvix-web`; accepted ADR-0001 and ADR-0003 govern
publication and bounded review. The new technical decision remains a draft
recommendation in ADR-0007, not accepted architecture.

The old operator flow is deliberately preserved in the archive. Its grant and
slot checks were intentional security controls, not bugs to remove from v1.
REQ-ID-008 changes the product direction, not the interpretation of v1 authority.
The new work must use an explicitly versioned contract and fail closed on old
state it cannot map. No accepted application ADR is silently superseded.

## Fresh-server scope correction

The supplied owner instruction now chooses a new isolated server DB in place
of the old one, without retaining it or making a pre-cutover backup.
[Exact provenance, preserved boundaries and the local deployment candidate](../operations/fresh-self-service-v2.md)
are recorded separately. This immediate plan is not legacy migration; it preserves
TLS and all phone state and leaves old v0/v1 controls unchanged. The new explicit
exact-IP v2 runtime/installer is a candidate for review, not a live change or a
permanent architecture approval. This RFC remains draft.

## Proposed local implementation boundary

Create and persist local identity -> automatic key proof registration -> verified
contact QR -> direct E2EE text. The common server origin and trusted SPKI are app
defaults; saved trust always wins. No phone, email, wallet, operator code, manual
server URL/pin, or end-user role is needed. Blockchain, multi-server operation,
seed recovery and media/calls remain separate work, not first-text gates.

Preserve root/account derivation, independent device authentication, Olm content
keys, APK package/signing identity and encrypted snapshots. Add a v2 request-proof
profile without grant or slot authority. Registration eligibility is published,
bounded server policy; ownership is proven by the existing root credential and
fresh device proof. A new root never acquires an unbound legacy account.

Use general account, device and conversation records instead of widening a
hard-coded pair. One device per account is an explicit initial limit, not a claim
of device-add/recovery support. Contact discovery is verified public QR exchange,
not a public searchable directory. Supporting more than one conversation must not
reuse a consumed one-time prekey or overwrite another peer's pinned session.

The [exact v2 wire and migration contract](../protocol/self-service-v2.md) was
written before handlers and now accompanies the local server candidate, draft
[ADR-0007](../decisions/0007-self-service-messenger.md) and
[threat/test matrix](../security/self-service-v2-threats.md). Independent review must cover
the new proof domain, stable public-key binding and general routing. Existing v1
vectors remain historical compatibility evidence, not v2 verification.

## Invariants and acceptance mapping

| Gate | Requirements and invariant | Verification required |
| --- | --- | --- |
| SS-01 | REQ-ID-001/005/008: locally saved identity, automatic registration and retry without operator or key regeneration | Real client/server registration, lost reply, reload, storage failure |
| SS-02 | REQ-ID-004/006: possession is not arbitrary authority; bounded resource allocation, no legacy-slot claim | Invalid root/device proofs, cross-request replay, concurrency, capacity, migration tests |
| SS-03 | REQ-ID-007, REQ-SEC-001: explicit peer key binding, client-only content keys, unchanged TLS validation | QR substitution, existing-pin conflicts, >2-account real E2EE and authenticated receipts |
| SS-04 | REQ-MSG-002/003/004: commit before acknowledgement, exact retry/dedup, no automatic history eviction | Offline/restart, one/two check semantics, conflicting retry, full quota tests |
| SS-05 | REQ-ID-006, REQ-MSG-004: installed keys/contacts/history and later data survive migration | Populated old snapshots and DB, interrupted migration, dump/restore, downgrade refusal |
| SS-06 | REQ-DEPLOY-001: reproducible isolated Linux lifecycle without neighboring changes | Actual isolated package install/update/restart/restore, identified artifact |
| SS-07 | REQ-CLIENT-001/002: ordinary Android contact/dialog UI and preserved installation identity | Signed APK checks and two physical phones; JVM tests are not phone evidence |

## Alternatives and consequences

- Keeping operator approval fails the explicitly corrected UX.
- Publicly issuing old grants or free alice/bob slots creates takeover risk and
  does not provide general accounts/conversations.
- Replacing the whole stack discards useful tested crypto/storage/TLS/lifecycle
  components and adds unnecessary scope.
- A versioned self-service layer reuses those components after adaptation, at the
  cost of new API, state migration and abuse-control obligations.

Finite signup/storage budgets bound cost but cannot prove Sybil resistance or
availability: an attacker can exhaust shared budgets. No automatic evictions,
CAPTCHA provider, payment dependency or silent operator queue is introduced.
Server visibility includes stable account/device identifiers, relationship graph,
IPs, timing and ciphertext lengths. E2EE does not conceal this metadata.

## Migration, rollback and review gates

Migration runs offline through a reviewed explicit transition, not startup SQL
or a weakened schema hash check. Preserve original tables and keys; import only
exact authenticated legacy bindings. Unknown/corrupt/ambiguous mappings fail
without destructive cleanup. A revoked identity must not silently re-register to
recover revoked authority. Old processes must be stopped and old binaries must
refuse the new state. Rollback means compatible code retaining all current data,
never overwriting post-upgrade history with a stale backup.

This RFC opens local implementation and test work only. No self-service deployment
is authorized by the earlier two-phone operator-grant rollout record. Before
adoption: actual evidence, independent fresh-context review, owner disposition
and separately scoped deployment permission. ADR-0003 may replace the second
human only within its exact approved private synthetic-data scope; it is not
permission for a public release or production/privacy claims.

## Current evidence

Preflight read the live issue and empty comment thread, current feature branch,
product requirements, accepted ADRs and existing code. Duplicate searches by
issue number, self-service and registration found no open competing PR. GitHub's
rulesets API returned an empty list; workflow presence is not proof of a required
merge check. These are proposal-creation observations, not a fresh remote lookup.

The subsequent local server candidate has [independent evidence](../server/self-service-local.md#independent-server-review-evidence):
19 targeted and 43 full server tests plus Python Ed25519/TLS/PostgreSQL probes
passed. Runtime review found no blocker but overall failed on SR-01 documentation.
The missing draft ADR/threat/current-state artifacts are now included; independent
documentation re-review remains pending. Physical phones, completed client E2EE
journey and v2 deployment are not established by this server evidence. RFC-0012
remains draft; no architecture acceptance or rollout permission is inferred.
