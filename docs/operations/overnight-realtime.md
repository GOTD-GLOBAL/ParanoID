---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Overnight realtime private-alpha runbook

This runbook covers REQ-MSG-006, REQ-CLIENT-004 and REQ-DEPLOY-002 under the
[owner's bounded task](../product/overnight-realtime.md). RFC-0015 and ADR-0010
remain proposed. The current task expressly authorizes the tested signed APK
and existing-service deployment after independent review; it does not supply
permanent ADR approval evidence or authorize a public release.

## Candidate and actual local evidence

Android versionCode8 (`0.0.8-realtime`) preserves package `org.paranoid.devtext`,
the retained signing certificate, v7 core3/sealed4 storage and existing saved
origin/SPKI. No phone reset or ratchet migration is needed from delivered v7.
Actual populated-v7 JNI upgrade tests preserve identity, contacts, verification,
blocking, history and exact queued ciphertext before completing delivery.
Unsupported pre-v7 historical snapshots remain refused without replacement;
retained historical failures are recorded separately, not called fixed.

The exact source/artifact/review/deployment records are external in
`/home/codex/paranoid-self-service-evidence/overnight-realtime-20260909T191524Z`.
Its living checkpoint and machine-readable status distinguish completed gates
from remaining work. The [dated rollout](realtime-rollout-2026-09-09.md) records
successful final Fable review/closure, signed APK verification, the attended
existing-service update and actual hosted product Java/JNI acceptance. Final
postflight passed at 2026-09-09 20:59:04 UTC. Original build hashes remain bound
to the immutable source snapshot; these postbuild factual documentation updates
have a separate manifest and do not imply an artifact rebuild.

A matched optimized-JNI v7 baseline measured P50 3043.98 ms and P95 3057.50 ms
for 20 alternating actual local messages. The exact final optimized realtime
fixture measured P50 102.94 ms and P95 122.01 ms for 24 messages, satisfying the
500/1500 ms target.
Measurements end at receiver durable commit/Java listener notification, not a
physical display frame. The realtime proxy adds a second verified TLS hop.
Debug-JNI early runs measured approximately600ms P50 and failed that target;
those records are retained. No model-generated crypto timing is evidence.

Real fixture coverage includes zero-contact delivery/reply, crossing sends,
publication before a blocked receipt request, immutable post-commit retry after
response loss, offline state-worker progress, failed-save freeze, process/server
restart and actual old-v2-binary rollback. Native signing rejects arbitrary
routes/bodies by deriving operation intents from saved state. The14 real server
realtime tests cover auth replay/bindings, revocation,300-second expiry,2048
nonces,64 sessions/eight waits, missed wakeups, actual TLS reuse/timeout and
bounded occupancy. With three pool connections available, eight idle waiters
measured27.404ms server-accept P95 against27.535ms baseline (30 each).

Native Android35 emulator checks exercise real self-registration and E2EE,
keyboard focus during incoming updates, composer/send, retained state across
an in-place same-signer update, and actual foreground-service permission flows.
Notifications expose neither sender nor content. Screenshots and interaction
results are in the external `ui/` record; physical OPPO/camera/background battery,
Doze and force-stop delivery remain NOT RUN. Emulator fixture APKs use isolated
loopback trust and version7; they are test-only, never the phone deliverable.

## Build and acceptance

Use [the Android retained-key build](../../clients/android/README.md) and
`python3 deploy/build.py --self-service-v2` from the coherent frozen integration
worktree. Verify APK package/version, ARM64 ABI, signer and16KiB alignment.
Verify bundle allowlist and every manifest hash; preserve the immutable existing
release for rollback. Compiler inputs, retained source snapshots and task-only
patches must identify the actual dirty-source build, rather than imply Git HEAD
alone contains it.

Run the realtime fixture against the final server binary and optimized host JNI:

```sh
python3 clients/android/test_realtime.py --help
```

Use its documented options and a new private evidence directory. Run unchanged
clean core tests plus new realtime signing tests, client TLS and UI contracts,
retained server suites and the real PostgreSQL/TLS/systemd deployment tests in
[deploy/README](../../deploy/README.md). Packaged deployment tests must select
`PARANOID_TEST_PACKAGED=1`, the exact `PARANOID_V2_RELEASE`, and retained
`PARANOID_V2_OLD_RELEASE`. Recheck source hashes after all builds/tests.

Fresh `claude-fable-5` final review must inspect exact source, test evidence,
manifest and deployment code. Preserve JSON success and actual model usage.
Fix blocking findings with RED/GREEN evidence and obtain independent closure
before deployment or APK handoff. Earlier design closure is not a final-code
verdict; AI review is not a qualified human security audit.

The actual final product, execution-script and bounded closure reviews passed.
The initial exact packaged sequence remains 13 PASS/1 FAIL: a standalone pinned
TLS/database readiness failure with UNKNOWN cause. Four focused reproductions,
a full 11-test capture and the requested additional Gate1 full 11-test diagnostic
passed without product/assertion/timeout changes. Closure permits the attended
same-data operation; it does not claim a fix or authorize unattended rollout.
Historical core 27 PASS/14 FAIL and two old JVM failures remain unchanged.

## Existing-service rollout and rollback

The only authorized target is `paranoid@157.180.49.125`, existing root
`/home/paranoid/paranoid-alpha`, unit `paranoid-alpha.service`, PostgreSQL system
ID `7683525211206671315`, HTTPS port38443. Preserve origin, certificate, SPKI,
configuration, all application rows, releases and neighboring services. Capture
read-only service/neighbor/process and TLS fingerprints before and after.
Use the existing authorized SSH helper without copying or exposing credentials.

The [2026-09-09 execution record](realtime-rollout-2026-09-09.md) reports the
completed update, verified backup and postflight. The worker transaction lasted
2.433077 seconds; outage duration was not continuously measured. External hosted
messaging passed with 12 measured sends, P50 76.50962 ms/P95 85.743713 ms. That
product Java/JNI result is separate from the local fixture and physical Android.

The independently reviewed new controller's `update-v2` performs an encrypted,
fully authenticated and restore-verified backup before changing the pointer.
See [the exact command and rollback procedure](../../deploy/README.md).
The backup key remains private on the host. Backup verification can take minutes
while only the dedicated unit is stopped. It is a DB-only, co-resident-key
backup, not off-host disaster recovery. Neither `replace-v2` nor legacy
`update/switch/backup` is a valid same-v2 update path.

On readiness failure, recover with the new reviewed controller and the retained
old v2 release using the SAME current database. Never restore an old dump over
messages accepted after update. Preserve encrypted backups and verification DBs;
cleanup requires a later explicit retention action. Verify external pinned TLS,
actual final-transport synthetic registration/text/receipts, exact hosted binary
hash, retained cluster/TLS and unaffected neighbors. Use only generated test
identities; do not query existing user message plaintext.

## Known limits and next scope

Basic optional background connection uses an Android foreground service after
notification permission. It has bounded reconnects, a visible stop control and
no Google dependency; it is not persistent delivery after force-stop, nor a
measured Doze/battery guarantee. FCM/UnifiedPush/Huawei providers are future
adapters and have no credentials or delivery implementation in this candidate.
Voice is not delivered and has no pretend call control. Multi-server membership
is specified architecturally, not exposed as a working second-server UI.
Role-based invitations, federation and public blockchain anchoring remain future
proposals. Independent qualified human review is required before sensitive data,
public release or production/security assurance.
