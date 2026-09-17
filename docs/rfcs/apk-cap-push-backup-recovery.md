---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# APK-cap rollout: optional FCM schema and verified rollback recovery

## Observed failure and root cause

After the reviewed maintenance adoption passed the original coordinator status,
the owner-authorized kit12 update failed in message switch preparation. Both
message worker and coordinator recorded completed rollback, with old release,
config, unit, TLS key/certificate/pin and PG identity restored/preserved. TURN and
policy were active. Failed transaction `8bbb341ef62a6d5440048983ce5367fe` is retained.
No new backup archive was created and no candidate code remained active.

Read-only live schema comparison with an existing private reference DB showed
exactly the optional `ss_push_tokens` table/constraints from RFC-0020 runtime
startup. `self_service_http.rs` creates it only when push is enabled; the base
self-service-init schema does not include it. The existing backup gate compared
against base-only schema and correctly refused the mismatch. A local populated-PG
regression reproduced the exact ValueError before any fix. This is not permission
to skip schema checks, disable push or discard its tokens.

## Bounded controller correction

Keep the base schema contract/hash unchanged. If the existing application DB has
`ss_push_tokens`, add the exact known runtime DDL ONLY to the newly created empty
reference DB. Then compare entire schema snapshots exactly as before. Unknown
tables, extra columns, wrong constraints/views still fail. No application DDL or
schema migration is performed by maintenance.

Include existing optional push rows in ordered count/SHA256-row digests for both
source and restored verification DB. Return the actual verified table set in the
backup manifest. pg_dump already covers all tables; this fixes strict acceptance
and explicit restoration coverage, not encryption or signer/trust behavior.
Tests cover absent/present optional table, real encrypted restore, changed-token
rejection and extra-column rejection. The duplicated reference DDL is checked
against the server runtime SQL so drift is visible. REQ-MSG-004, REQ-SEC-001 and
RFC-0020/RFC-0013 remain applicable; no permanent ADR acceptance is implied.

## One-off completed-rollback acknowledgment

The coordinator retains a terminal rolled-back pointer after failure; do not call
fresh installation or retry update as though it were still active. The owner has
explicitly requested completing deployment. A separate, exact-failure-bound
operator helper may select the already verified active predecessor only after:

- exact failed pointer and predecessor journal fingerprints match;
- failed coordinator and message worker both confirm completed rollback;
- actual live identity equals the predecessor in every field;
- original worker preflight/loaded-unit and network/system/relay checks pass;
- coordinator and message-operation locks are held.

Preserve the failed current pointer as an immutable before-image and leave BOTH
transaction journals untouched. Atomically repoint current.json to the byte-exact
existing active predecessor. Keep an immutable proof receipt. Unknown or partially
recovered states stop; crash recovery accepts only exact before/after images.
The original status check runs unchanged afterward. This modifies no runtime,
config, TLS, schema, token, message, service or failed transaction evidence.
It is a single explicitly reviewed operational acknowledgment, not a generic
automatic rollback-adoption capability. The subsequent update opens a NEW
transaction and must pass the full normal backup/restore/readiness gates.

## Review and scope

Independent review is required before helper write mode and the revised package.
Root is trusted; metadata before-images contain hashes/paths, not raw secrets.
Push credentials/tokens are never printed or placed in general evidence. Live
failure injection, data reset, current-data restore from old backups, new key/pin,
neighbor changes and publication-feed changes remain unauthorized.
