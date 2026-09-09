---
status: proposed
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: pending independent parent review
last_reviewed: 2026-09-09
---

# RFC-0011: Bounded offline key-v1 deployment migration

Non-normative proposal; no production architecture acceptance. Companion to
[ADR-0006](../decisions/0006-phone-key-registration.md) and
[rollout authority](../operations/key-rollout-authorization-2026-09-09.md).
Implementation is local only; parent retains all live-operation responsibility.

## Invariants and enforcement

- REQ-DEPLOY-001: isolated existing PG16 Unix socket, exact configured IPv4:38443,
  direct TLS only. Runtime bind tests and populated native deployment tests.
- REQ-ID-006 / REG-05: no implicit slot assignment, no bearer revival. Explicit
  additive known-schema transition only; sticky incompatible configuration plus
  database startup guard; key-capable code rollback only. No client wire changes.
- REQ-MSG-004 / V0-14: retain every envelope and room row and all later key grants;
  quiesced dump, isolated restore and complete ordered comparisons before mutation.
- REQ-SEC-001 / REG-06: preserve original TLS identity and tokens, never export
  client secrets. Exact package allowlist, content hashes, no-follow private paths.

## Proposed mechanism

A versioned key-capable package still supports v0 before explicit `migrate-key`.
Its manifest declares key capability and contains the exact reviewed additive
key schema. No generic changed-schema update is permitted. A sticky configuration
extension blocks legacy controllers before schema mutation, even across crashes.
The database trigger blocks old binaries. A crash is resumed only by the reviewed
migration command; there is no automatic downgrade or stale restore.

Stop the dedicated unit explicitly before offline migration. Serialize controller
operations and reject a running supervisor. Back up and verify current data in a
fresh private database before changing configuration or schema. Preserve private
config/TLS copies with the backup; never include them in release artifacts.
After cutover, health uses private local SQL and verified TLS readiness, never
user message authority or revoked tokens. Compatible code rollback always keeps
current data. When recovery cannot safely resume, fail stopped with retained state.

## Alternatives and limits

Generic schema acceptance and bearer-only rollback are rejected. Restoring an old
dump over live history loses post-cutover writes and is prohibited. Reinitialization,
TLS rotation, public signup, device key changes and PostgreSQL major upgrades are
outside scope. Hashes do not authenticate publishers; trusted dedicated account and
trusted artifact provisioning remain prerequisites. Same-account/root compromise,
disk loss and volumetric DoS remain risks. Independent review and live/phone
acceptance are separate gates, not inferred from local tests. Parent must reconcile
current-state/changelog/index documents outside this worker's ownership.
