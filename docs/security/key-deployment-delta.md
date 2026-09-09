---
status: draft
owner: security
last_reviewed: 2026-09-09
---

# Key deployment migration security delta

Companion to [RFC-0011](../rfcs/0011-key-deployment-migration.md),
[registration threats](server-v0-threats.md) and the
[runbook](../operations/key-deployment-rollout.md). Risk/decision owner:
martadvix-web. Local implementation evidence is not independent review, live
rollout, physical-phone evidence or production architecture acceptance.

## Assets, boundaries and enforcement

| Threat | Control / evidence | Residual boundary |
| --- | --- | --- |
| Old bearer authority revived by downgrade | Sticky versioned config rejects legacy controllers; BEFORE INSERT startup trigger rejects old v0 binaries; hashes and side-effect-free binary/controller capability responses gate migration, key startup and rollback | Trusted artifact publisher and dedicated OS account; capability declarations are not signatures or malicious-code attestation |
| Wrong/unknown schema accepted under a generic exception | Only exact base SQL hash and exact additive key SQL hash/version; actual PG schema compared with isolated reference before transition; unknown table regression | Owner/ACL excluded from schema comparison; private cluster and account remain trust prerequisites; no PG-major migration |
| Lost/rewritten history or activation on update | Offline lifecycle lock; dump restored into fresh DB; complete ordered envelopes, room, key metadata and grant comparisons; same-schema code rollback never restores stale history | Filesystem/power failure can leave a stopped instance requiring inspection; no host-loss RPO guarantee |
| Operator steals client auth to implement health | Operator readiness uses private SQL and verified IP TLS liveness, not message routes, tokens or device private keys; actual two-key-only JNI fixture passes health | Does not establish end-to-end device health; operator retains database/superuser authority |
| Concurrent lifecycle operators race service stop/switch | Separate nonblocking operation lock spans update stop/switch/start and serializes migration/switch; supervisor retains lifecycle lock | Manual systemctl/direct same-account interference is outside automated locking; unit ownership is validated |
| Offline helper adopts an already-running PG | Reject existing/stale postmaster state before launching its own child | Crash recovery with stale PID state requires explicit stopped inspection; never kill an unverified PID |
| Advisory backend dies or PG restarts while old worker continues | Reproduced baseline: second process served concurrently. Fixed with process-lifetime OS file lock in canonical private single-socket namespace; second process refuses after backend termination and PG restart, replacement succeeds only after original process exit | Linux same-host/single-socket deployment only. No distributed workers. Never unlink lock files while an owner may live; malicious root/account can bypass local locks |
| Unauthenticated completed-request sockets monopolize TLS slots | Reproduced baseline: keepalive socket did not close. Key-mode keepalive now disabled; fifteen-second absolute post-handshake stream deadline also closes idle/incomplete/stalled requests; real socket tests and JNI exchanges pass | Sixteen slots, shared rate budget and eight-second handshake timeout bound resources, not volumetric DoS or guaranteed fairness; slow legitimate requests may retry |
| Secret material leaks in release or recovery | Fresh seven-file allowlist; no-follow regular-file validation and content hashes; private config/TLS backups and their hashes retained only under backup root | Identity backup includes old tokens and TLS private key, unlike prior history-only backup; encrypt before transfer; no publisher signing/encryption tooling in this package |

## ALPN compatibility correction

The first hosted external check found that axum-server PEM loading advertised h2
while the bounded key dispatcher was HTTP/1-only. Default curl negotiated h2 and
failed, while explicit HTTP/1 succeeded. A real local TLS regression reproduced
the mismatch before a minimal key-mode-only ALPN restriction to `http/1.1`. The
certificate, key resolver, cipher/version policy and all auth/schema/controller
bytes are unchanged. Both-protocol offers now select HTTP/1 and complete the
request; repeated packaged JNI migration/messaging tests pass. This is a separate
server-only correction, not permission to bypass TLS pin or negotiate unsupported
HTTP/2. Final focused review and hosted update are recorded separately.

## Deliberate non-changes

No Android/key-protocol/core source, device wire format, E2EE construction, peer
verification, grant/activation semantics or server auth-handler source changed by
this deployment work. No anonymous signup, automatic slot allocation, credential
rotation, history expiry, recovery redesign, proxy HTTP path or neighboring-service
operation. APK 0.0.4 compatibility is checked with its actual Java/JNI transport
sources locally; installed OPPO behavior remains a separate test.

## Recovery restrictions

Do not remove sticky config, key schema, startup trigger or active/revoked grant
state. Do not restore a pre-cutover dump to recover availability. Compatible code
rollback preserves current data, even messages accepted after an update. A failed
compatible recovery stops the dedicated unit; diagnose from restricted evidence.
Backups and reference/verification DBs are deliberately retained and require disk
monitoring and separately authorized retention/deletion. No live fixture, phone
secret or hosting credential is included in these local test artifacts.
