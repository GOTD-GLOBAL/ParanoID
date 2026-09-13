---
status: proposed
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-13
---

# Repeating same-key TLS maintenance (private alpha)

## Authority and scope

Sergey explicitly authorizes automatic certificate renewal **without key change**
in the current 2026-09-13 task. The Telegram permalink is unavailable; this is
bounded task provenance, not permanent ADR acceptance. Depends on PR #30's
[one-off operation](../operations/tls-renewal-2026-09-13.md). Fresh independent
review, real runtime verification and installation are coordinator gates; this
workstream changes local code/tests/docs only. No numerical RFC slot is allocated.

REQ-ID-007 (separate contact/server trust), REQ-MSG-004 (retained history),
REQ-SEC-001 (no new privacy claim) and REQ-DEPLOY-002 (same-data maintenance)
remain unchanged. Tests enforce retained SPKI/key bytes, immutable configuration,
release/unit/data identity, no DB operation and guarded certificate-only rollback.
No client/API/wire contract changes. ADR-0003 supplies the bounded review process.

## Proposed transaction

A daily persistent user timer starts its own bounded oneshot, never the service
being stopped. Fixed host root and pin; no CLI root, pin or force bypass. Read-only
`--check` validates identity and reports due date/pending recovery. Normal not-due
runs validate cert/key/pin but do not restart or write state. Renew at <=30 days
remaining using the existing P-256 key, SHA256 signature, unchanged subject/issuer,
SPKI/extensions/critical flags, fresh serial, five-minute backdating and 90-day
validity. No key generation, serialization, copy, digest log or export.

Acquire the existing alpha operation.lock (never replace/unlink). Snapshot fresh
release/config/unit hashes and data/key filesystem identity for each transaction:
legitimate intervening server updates remain supported. Save only old/new public
certificates and a fsynced journal in owner-only state. Stop alpha, confirm
MainPID=0 and no manager Job, revalidate baseline/key/cert, atomically replace
certificate with a unique exclusive sibling temporary and fsync. Start alpha,
bounded authenticated PG/TLS health and exact served DER, revalidate then commit.

On failure, rollback only the known old/new certificate under the unchanged
baseline; unknown drift refuses overwrite. On interruption, pending journal is
reconciled **before** fresh expiry: restore old certificate and verify readiness,
record recovery, return failure for operator visibility; never adopt an
uncommitted candidate as not-due. Retain all journals and a failure receipt.
An expired rollback certificate fails closed and requires operator intervention.

## Threats and alternatives

Manual-only renewal risks unnoticed expiry; automatic rekey breaks pinned trust
and is rejected. Same-account/root compromise and malicious concurrent writers
are outside the cooperative-lock boundary; mode/symlink/hash guards detect
accidental drift, not a compromised owner. Power loss is addressed with durable
prepare-before-rename ordering, but hardware/filesystem durability needs host
validation. Timer failure is locally persistent, not an external paging system.
Untrusted subprocess output must never be logged (configuration may hold secrets).
The supervisor's normal private-PG stop/start is permitted; no backup, SQL write,
restore/reset, application update, firewall/DNS or neighboring-service change.
See the [runbook](../operations/tls-auto-renewal.md) for deployment gates.
