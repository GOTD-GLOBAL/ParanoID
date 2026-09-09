---
status: draft
owner: operations
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Fresh self-service v2 preparation: scoped owner correction

The [later authorized live rollout](self-service-v2-rollout-2026-09-09.md) completed
this exact old-data-only replacement on 2026-09-09. Its explicit current user
instruction supersedes this preparation worker's no-live restriction below, not
the protected boundaries or draft architecture status. The old cluster is now
discarded; this document grants no repeat deletion of later v2 data.

Requirements: REQ-ID-008, REQ-MSG-004, REQ-DEPLOY-001, REQ-SEC-001.
Companion proposal: [RFC-0012](../rfcs/0012-self-service-messenger.md) and
[draft ADR-0007](../decisions/0007-self-service-messenger.md).

## Supplied instruction, not fabricated permanent approval

The current implementation task explicitly conveys Sergey's correction: finish
an APK for two phones and replace the old ParanoID SERVER database in place with
a NEW database. Do not preserve, archive or create a pre-cutover backup of the old
server database merely to support legacy migration. This is an explicit bounded
discard request under REQ-MSG-004, not permission for routine history eviction.
The earlier integration report's recommendation to implement legacy migration
and verified pre-transition backup is therefore NOT the scope of this task.

This task authorizes local candidate implementation and disposable synthetic
tests only. It explicitly prohibits live host operations, deletion, restart,
network-rule changes, commit, push and merge. The coordinator must review before
any deployment. The task text supplies provenance; no stable Telegram permalink,
GitHub approval, accepted application architecture or permanent general deletion
approval is invented here. ADR-0007 stays draft. Historical v0/v1 decisions and
rollout records are not rewritten.

## Exact preserved boundaries

- Existing intended origin: `https://157.180.49.125:38443`; no wildcard or another
  public IP, no proxy HTTP or trust-all fallback.
- Existing private installation: `/home/paranoid/paranoid-alpha`, dedicated
  `paranoid-alpha.service` and private PostgreSQL socket. Never use neighboring
  PostgreSQL, Nginx or Docker services.
- Preserve TLS key/certificate and saved phone trust, all phone keys, snapshots,
  contacts, history and APK signing identity. Do not uninstall or clear phone data.
- Discard authority is the old SERVER database only, not the installation root,
  TLS directory, phone state, neighboring files/services or unrelated backups.
- No dump/archive/copy of the old real DB is to be made by this preparation task.
  Existing historical backup files outside the scoped DB are not automatically
  deleted under this instruction.
- Fresh server registration does not import old grants, revocations, inbox rows,
  dedup state or sequence. Server-side loss is intentional for this one reset;
  subsequent accepted v2 messages still require retention. Client continuity
  and behavior with a freshly empty server need separate real client verification.

The [fresh-only operational runbook](fresh-self-service-v2.md) records the later
candidate commands, exact target, tests and fail-stopped recovery boundaries.

## Candidate and remaining review boundary

The minimal candidate reuses the isolated package, private PG16 lifecycle and
existing user unit. Explicit `self-service-v2` mode requires the exact reviewed
IPv4 opt-in and port 38443; `self-service-v2-local` and old v0/v1 modes retain their
own gates. TLS validation is not disabled. Fresh initialization and SQL/TLS
readiness need no operator grant or client private key. Capability probes are
integrity/compatibility gates, not signatures or deployment authorization.

A tested fresh empty-database initializer is not by itself a tested in-place
replacement tool. Before any destructive execution, the coordinator must identify
and independently review the final replacement implementation and artifact,
validate the exact stopped dedicated root/cluster identity, and prove its
containment in a disposable fixture. Do not improvise `rm -rf` or delete the whole
root because only fresh initialization passed. Failure after discard has no old
DB rollback: remain stopped, preserve TLS/phone state and diagnose using compatible
v2 code. No restored stale pre-reset DB is a recovery strategy.

Existing v0/v1 backup/update behavior stays historical. A fresh-only v2 controller
must not label an old four-table restore check as verified v2 backup or rollback.
V2 backup/update/restore remains a separate capability until genuinely verified;
reject unsupported operations rather than silently running legacy recovery.
