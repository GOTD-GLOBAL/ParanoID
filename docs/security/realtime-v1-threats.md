---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Signed-session realtime trust delta

Private synthetic-data alpha only; [RFC-0015](../rfcs/0015-overnight-realtime.md),
proposed [ADR-0010](../decisions/0010-overnight-realtime.md),
[wire contract](../protocol/realtime-v1.md) and
[exact server tests/evidence](../server/realtime-local.md). Fresh Fable design
review and bounded closure are complete; the 14-test realtime server matrix and
retained server regressions pass. Final combined-source product and execution-script
reviews and bounded closure subsequently passed before the
[attended rollout](../operations/realtime-rollout-2026-09-09.md). No human audit or
production privacy/security assurance is claimed. Human residual risk owner is
martadvix-web; permanent architecture disposition remains proposed.

New scope traces to [REQ-MSG-006, REQ-CLIENT-004, REQ-MULTI-002,
REQ-SERVER-003 and REQ-DEPLOY-002](../product/overnight-realtime.md). UI,
client persistence/background and deployment evidence remain separately scoped.

## Server data flow and boundaries

The retained root/device proof opens a public, ephemeral session context bound to
realm, SPKI, immutable account/device/credential and startup epoch. Each request
still requires a fresh nonce and device-auth signature over exact method/path/body.
The process ledger admits at most one use of each valid nonce. A locked PostgreSQL
authorization check precedes any message mutation or returned ciphertext. The
existing recipient inbox and exact `(sender,id)` storage remain the durable source.

Waiting registers a notification observer before its inbox snapshot, releases all
database connections/transactions, and uses unlocked one-second probes as hints.
Data, empty timeout and revocation completion require the locked final check.
No ciphertext message queue or content keys are added to server memory. Existing
metadata exposure (identity, graph, IP, timing, size and ciphertext) remains.

| Threat / severity | Control and executable coverage | Residual boundary |
| --- | --- | --- |
| RT-S01 stolen public session enables impersonation; high | Session is non-bearer; independent transcript/signature/context/duplicate-header/concurrent-replay test | Device-auth key compromise defeats request authentication; endpoints remain trusted |
| RT-S02 replay or altered route/body creates duplicate/change; high | Verify before consume, nonce ledger retained for whole 300-second session, 2048-op cap; unchanged exact message idempotency and quota tests | Lost responses need a fresh request nonce with identical ciphertext; session-open response loss can occupy one of two slots until expiry |
| RT-S03 revoked or rebound account keeps a live read; high | Exact active mode/root/device/auth/fingerprint/full Credential checked under shared transaction lock per operation/final wait; revoked-wait and binding/restart tests | A transaction authorized before revocation may finish; remote cached plaintext is never erased. Reactivation/rekey is unsupported and future support requires durable generation |
| RT-S04 missed notification loses a message; high | Subscribe-before-snapshot, re-arm-before-query, durable inbox/cursor and at-most-one-second unlocked recovery tick; legacy wake, pagination and no-notify commit tests | One-second bound assumes healthy scheduler/DB; storage failure returns static failure. A test controls committed-without-notify state, not every OS cancellation schedule |
| RT-S05 waits exhaust DB or transport resources; medium | Eight waits globally/one account, no permit queue, unlocked idle probes, no sleeping transaction; 64 sessions/two account; existing 16 sockets, eight-second handshake/header limits and 120-second absolute v2 lifetime; real capacity/TLS/eight-waiter tests | Shared limits are not fairness/Sybil resistance; malicious authorized clients can deny scarce slots; idle connection lifetime is longer than historical mode |
| RT-S06 transport optimization drops old persistence/abuse safeguards; high | Existing message helper and full binding checks retained; registration/challenge/auth/total ingress, decoded/body/page/row/byte quotas unchanged; exact retry/no-eviction/ingress regressions | Existing storage/account metadata and account-enumeration risks remain, as in v2 threat model |
| RT-S07 fallback silently weakens trust or breaks after rollback; high | Capability is only discovery; retained pin/identity and v2 proof fallback; 404 triggers pinned rediscovery; 401 never weakens auth; schema and capabilities JSON unchanged | Client/old-binary integration and final deploy same-data rollback evidence are coordinator gates, not established by these server tests |

## Compatibility and review boundaries

No server schema, root credential, E2EE frame, recipient routing, replay cursor,
accepted-row deletion or migration is introduced. The retained v2 binary can use
the same current data after rollback; stale dump restoration is not rollback.
The old TLS key/SPKI/origin, existing neighboring services and historical source
remain protected. The only newly direct Cargo dependency is the already resolved
`hyper-util` 0.1.20 timer; its version is unchanged.

The native client signer/persistence/concurrency, Android background/provider and
deployment encrypted-backup boundaries have separate coordinator-owned analysis
and actual tests recorded in the dated rollout. Server opaque fixtures cannot prove
E2EE, durable plaintext rendering, physical OPPO behavior or Doze delivery.

## Native state, transport and Android boundaries

The session signer receives only `send/messages/events` plus optional immutable
outbox ID. It constructs exact method/path/body/current cursor and fresh UUIDv4
nonce in native code; caller-supplied path/body/nonce fields are refused. Session
identity, realm, pin and credential must match saved state. Device/root keys
never leave the native state. Four independent transcript/binding tests have
actual RED and GREEN records; all17 retained clean first-contact tests also pass.
Session lifetimes use the server's authoritative expiry and Java monotonic
receipt/renewal bounds; the phone wall clock does not grant server authority.

A per-membership Java transport keeps one pinned SSLSocketFactory and at most two
concurrent requests. HTTP bodies are bounded, redirects/proxies are refused and
successful responses are drained before reuse. Wrong-pin/SAN/expiry behavior
remains the existing strict TLS boundary. Only public session context is cached;
no bearer session or new persisted secret. Nonce replay retries sign fresh
requests over the same durable ciphertext. Distinct429 responses trigger bounded
retry/polling;404 triggers pinned capability rediscovery and old v2 proof fallback.
A stopped loop invalidates queued work by generation and cancels active I/O.

Network send and receive lanes submit short actions to the single state owner.
They never make that owner wait on a network operation. Receive saves each full
candidate before notifying the renderer; receipt I/O follows publication. The
real generated-pinnedTLS/PG/JVM fixture blocks an actual receipt POST while
requiring durable plaintext notification, drops a committed response then checks
exact immutable retry, and exercises crossing, server/JVM/offline recovery and
incoming-save freeze. No failed commit is represented as delivered. JNI timing
is a notification measurement, not a physical Android frame measurement.

The opt-in Android foreground connection uses `specialUse` with an explicit
manifest subtype, an ongoing stop notification and user-granted notifications.
This is the declared non-push private-alpha use case; it is not a Play Store
policy acceptance claim. The official Android type description is the basis:
[foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types).
`remoteMessaging` specifically describes continuity between a user's devices;
this alpha uses no such claim to bypass background limits. No boot receiver,
wake lock, mandatory Google provider or fabricated FCM credentials. Service
restarts are non-sticky; force-stop/process/OEM/Doze can prevent delivery.

The service is private/nonexported and only begins from explicit visible user
interaction. Notification content includes neither sender nor message text;
notifications follow durable new incoming state. Android system notifications
still expose app use/timing to the OS and observers. Network retry is bounded
with backoff; connection/session/socket caps are not a battery-life guarantee.
The future wake-provider contract must bind wake to a saved membership and only
schedule authenticated sync; FCM/UnifiedPush/Huawei are not integrated tonight.
Actual service/permission/UI tests and screenshots remain separate from JVM
acceptance; no physical OPPO or reliable Doze/force-stop claim follows.

## Deployment encryption, rollback and retained state

The new explicit same-v2 controller verifies current/candidate manifests, all
three unchanged schema hashes, runtime capabilities, exact existing unit/root,
PG system ID and private no-follow paths before the stopped maintenance phase.
Only that unit is stopped. A dedicated host-private256-bit backup key protects
streaming AES-GCM archives with canonical authenticated context and full128-bit
tag. Decryption authenticates fully before pg_restore consumes plaintext.
Archive size is bounded at512MiB; restore targets newly created private verifier
DBs, then compares exact schema and complete ordered row digests/counts.

Only encrypted DB archive and nonsecret manifest are retained as backup files;
TLS/config remain in place. Anonymous temporary plaintext and verifier DBs stay
inside the existing trusted host boundary. Co-resident backup key does not
protect against host compromise or key+archive theft. This is DB backup, not
off-host disaster recovery or TLS-key recovery. Retained verifier DBs/archive
usage need later explicit retention policy; this task purges no existing data.

The current release pointer and staged files/directories are fsynced. Failed
readiness or tested SIGINT/SIGTERM attempts restore the old verified pointer and
start the SAME current data; messages accepted by new code are preserved. A stale
backup is never restored over newer data. Only an unrecoverable rollback leaves
the dedicated unit stopped for explicit recovery. Dump/encrypt/restore verification
can cause minutes of downtime at the stated limits. Power-loss certification and
host reboot remain unrun. Exact final-bundle tests and fresh independent Fable
code review are mandatory before the narrow authorized live operation.

The actual 2026-09-09 update exited 0 after authenticated encrypted-backup restore
and all-six-table/schema comparison. Final postflight retained the exact cluster,
TLS/configuration/unit and scoped neighbors; hosted synthetic messaging passed.
Only aggregate backup facts were exported. The worker transaction took 2.433077
seconds, with no continuous outage measurement. No live rollback was performed;
same-current-data recovery and signal/failure boundaries have local real-system
test evidence.

One original exact-bundle standalone readiness test failed (13 PASS/1 FAIL in the
packaged sequence), with cause UNKNOWN. Subsequent focused/full-order passes and
the requested PG-timing/PID diagnostic satisfy independent DEPLOY-GATE-1 closure
without proving a fix. The reviewer permits only attended rollout with reviewed
same-data recovery; recurrence can leave the dedicated unit stopped with its data
retained. This availability risk, co-resident backup-key limits, physical-device
unknowns and private-alpha governance remain after the successful host update.
