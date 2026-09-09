---
status: draft
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: pending exact-scope confirmation and domain reviewer selection
last_reviewed: 2026-09-09
---

# ADR-0007: Self-service registration and general direct messaging

## Context and decision drivers

[Issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16),
[REQ-ID-008](../product/requirements.md#default-server-self-registration-correction-2026-09-09)
and [RFC-0012](../rfcs/0012-self-service-messenger.md) replace operator-dependent
onboarding as the product target. They do not reinterpret historical v1 grants as
public signup permission. The locally implemented server candidate must be
reviewable alongside its proposed decision, not defer that record to integration.

Drivers: REQ-ID-001/004/005/006/007/008, REQ-MSG-002/003/004, REQ-SEC-001;
REQ-DEPLOY-001 remains a separate lifecycle gate. Preserve key ownership and
acknowledged history while removing ordinary operator approval and fixed pair
routing. ADR-0002 remains reserved; 0007 is the next unused number in this
worktree's decision log. Accepted ADR-0001 and ADR-0003 are unchanged.

## Proposed decision — not accepted

Recommend a separate [v2 contract](../protocol/self-service-v2.md): existing
root-signed credentials and derived account IDs, independent device authentication,
and a domain-separated, exact-request-bound, one-use device proof. Successful
registration creates an independent account under declared resource limits, without
a grant, reusable bearer, phone/email or blockchain dependency. No unproven root
receives a legacy slot or its history. One immutable device per account is the
initial limit, not recovery or device-management support.

Use general account/device/account-pair conversation records. Authenticate sender
from proof; synchronize only the authenticated recipient's inbox. Serialize state
checks, quotas and sequence assignment under the singleton PostgreSQL transaction
lock, with synchronous commit before acknowledgement. Resolve exact sender/message
ID retries before quotas; changed recipient or ciphertext conflicts. Never evict
acknowledged history to admit a new write. Content encryption, contact verification
and peer-authenticated receipts stay client responsibilities; server acceptance is
not delivery or reading. There is no mutual-contact ACL or public directory API.

The original binary mode `self-service-v2-local` remains loopback/mandatory TLS,
private PostgreSQL socket and process-lifetime ownership lock. The later
[fresh-only deployment candidate](../operations/fresh-self-service-v2.md) adds
explicit `self-service-v2` with exact reviewed IPv4:38443 opt-in, package lifecycle
and readiness. It does not authorize live deployment or startup migration.
The supplied owner correction discards only the old isolated server DB without
a backup, preserving TLS and phone state. This scoped exception supersedes legacy
migration as the immediate deployment plan, not the historical migration controls
or accepted ADRs. No permanent approval record is fabricated; this ADR stays draft.
[Server use and evidence](../server/self-service-local.md) describes implemented
behavior; [the dedicated threat delta](../security/self-service-v2-threats.md)
records the data flow, controls, exact tests and remaining risks.

## Considered options

1. Keep operator grants: preserves the old alpha but fails REQ-ID-008.
2. Give arbitrary applicants old grants/free slots: risks takeover and still
   encodes a fixed pair; rejected as the self-service approach.
3. Replace crypto, client storage and transport wholesale: unnecessary expansion
   with loss of existing evidence and increased migration risk.
4. Add a versioned self-service layer with explicit offline migration: recommended
   local candidate, retaining reusable components and strict historical ownership.

## Consequences and residual risks

Automatic server registration and more than two accounts are locally executable.
New admission, proof and migration surfaces require independent review. Shared
limits cap allocation, not Sybil resistance, availability or fairness. Authenticated
senders can probe recipient existence and send unsolicited ciphertext to known
IDs. Stable identity/graph/timing/size metadata remains visible. Global commit
serialization and quota scans trade throughput for a simple transactional path.

Human risk and decision owner: `martadvix-web`, pending disposition, not an
assertion that these residual risks have been accepted. Security/architecture,
server, client and operations roles supply follow-up evidence as mapped in the
threat delta; no human domain delegation is fabricated. No production privacy,
E2EE interoperability, phone acceptance or deployment readiness is inferred.

## Compatibility, migration and rollback

`self-service-init` runs offline with the same worker lock, never during ordinary
startup. Fresh storage starts empty. Existing storage must exactly match the
supported legacy structure and verified credential/realm/SPKI bindings. Import
original ciphertext, IDs and sequence through explicit old-slot mappings;
approved/pending becomes pending until matching device proof, active stays active,
and revoked remains tombstoned. Unknown/corrupt/unbound populated state aborts the
transaction. Original envelopes and grants remain retained.

Preserve original `key_meta` in `ss_legacy_key_meta` before setting its version to 2.
Retain/install the historical v0 startup guard and v2 cutover marker. Marker-aware
old entry points reject v2 storage; tests also exercise historical startup SQL and
an independently built unchanged HEAD executable. Do not remove guards or restore
stale pre-cutover data as rollback. Rollback requires compatible v2-aware code and
all current history. Local populated DB dump/restore passed; package lifecycle,
installed client snapshot migration and any authorized host rollout remain separate.

## Validation and current evidence

The [exact requirement/threat-to-test matrix](../security/self-service-v2-threats.md#exact-test-mapping)
maps RFC SS-01–SS-07 without claiming completion of client or operational gates.
The [independent evidence record](../server/self-service-local.md#independent-server-review-evidence)
identifies the reviewed base/revision scope, retained logs, signer implementation,
19 targeted / 43 full server tests and historical executable probes.

Independent fresh-context Hermes review (`gpt-6-astra`) found no blocking runtime
defect but reported documentation blocker **SR-01**. This documentation change
supplies its missing artifacts; coordinator independent re-review is still pending.
Neither this author nor a green doc check closes that review on the reviewer's
behalf. No runtime suite was rerun as part of this documentation-only correction.

## Required review and disposition evidence

Protected domains: identity/authentication/cryptographic proof, API authorization,
metadata, persistence/migration and deployment trust boundaries. Requested review
mode is `closed-alpha-ai` under [ADR-0003](0003-closed-alpha-review-policy.md), for
isolated local Linux/PostgreSQL/TLS and disposable synthetic identities/messages;
no physical devices, hosted data or public admission change are included here.
This field is a request, not evidence that all exception conditions are fulfilled.

- Human decision owner and residual risk owner: `martadvix-web`; no delegation.
- Required domain reviewers: selection/exact-scope confirmation pending. Default
  qualified-human review applies unless the bounded exception is fully evidenced.
- Local development provenance: RFC-0012 records the supplied Telegram instruction;
  no stable message permalink or new architecture approval is asserted.
- Permanent exact architecture/scope approval and decision PR: pending, not supplied
  by the prior operator-grant deployment authority or this task instruction.
- Independent AI report: retained local report and logs linked through the evidence
  record above; final SR-01 documentation re-review remains pending.
- Disposition: **draft**; no acceptance date, approval record, merge permission or
  deployment authorization. RFC-0012 remains draft, not completed.
- Exit gate: record review and owner disposition before adoption; obtain separately
  scoped migration/deployment authorization. Production/sensitive-use claims need
  the qualified human reviews required by policy. Two-phone application acceptance
  cannot be replaced by server-only tests.

## Links

- [Requirements](../product/requirements.md) and [product target](../product/self-service-messenger.md)
- [RFC-0012](../rfcs/0012-self-service-messenger.md) and [v2 wire contract](../protocol/self-service-v2.md)
- [Threat delta](../security/self-service-v2-threats.md) and [current state](../project/current-state.md)
- Supersedes: none. ADR-0006 remains the historical proposed operator-grant record;
  this distinct draft does not rewrite it or any accepted decision.
