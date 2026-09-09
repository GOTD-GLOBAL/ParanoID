---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Authorized live self-service v2 rollout — 2026-09-09

## Actual outcome and authorization

**Installed and running** on `https://157.180.49.125:38443` as of
2026-09-09 13:23 UTC. This is the actual bounded private-alpha installation,
not architecture acceptance, production readiness or two-phone acceptance.
RFC-0012/0013 and ADR-0007/0008 remain draft.

The current task explicitly instructed the independent rollout worker to finish
LIVE installation after bounded FPD-D01 closure and fresh live guards. Supplied
user direction included “Ну так собирай!” and “Ты устанавливает или опять болтает?”;
the coordinator explicitly confirmed installation scope. This later instruction
supersedes the older preparation-worker no-live boundary for this one rollout,
not the [old-data-only discard scope](fresh-v2-scope-correction.md). No stable
Telegram permalink or permanent GitHub architecture approval is invented.

## Exact installed artifact and review

- Account `paranoid@157.180.49.125`, root `/home/paranoid/paranoid-alpha`.
- Release `346f059914a290be4851`, tar SHA256
  `5901728d6a09947ffe906163c0d91ae3d14670eca69e051120d3d4c603b03827`.
- Retained private stage `/home/paranoid/self-service-v2-346f059914a290be4851/release`;
  created only after verifying its absence. Eight unique regular allowlisted tar
  members, all manifest hashes and target-native controller/runtime capability
  responses passed before stopping anything. No host packages installed.
- Current points to `ROOT/releases/346f059914a290be4851`. Exact artifact comes
  from the reviewed dirty source snapshot, not HEAD alone.
- Independent final report `final-predeploy-review-independent-b7e2.md` had only
  FPD-D01 outstanding. Independent bounded closure checked corrected RFC-0013 and
  Android wording against historical pinned self-signed-leaf policy and actual
  unchanged TLS code. Both source maps differ only in their respective corrected
  Markdown document; tar/APK hashes remain identical. No broad rebuild/retest.
  FV2-R01 interrupt closure remains valid. Neither review accepts draft ADRs.

## Executed cutover and preservation

Fresh target inventory and pre-stop guards found unchanged key-v1, old PG16 system
ID `7683205479877615472`, envelopes 0, key_grants 2, key_meta 1, room_state 1,
only the previously authorized old schema/verification databases, and unchanged
TLS/IP/SPKI/unit/neighbors. Read-only SQL selected catalog/settings/counts only.
No old database dump, archive, copy or migration was made.

`systemctl --user stop paranoid-alpha.service` exited 0 at 13:20:56 UTC. Separate
stopped-state checks proved MainPID 0, inactive/dead but enabled, no private
supervisor/server/PG processes, no listener, absent postmaster.pid and
`pg_ctl status` exit 3, unchanged old system ID and safe unmounted no-follow tree.
Preservation checks passed before the single destructive invocation:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 /home/paranoid/self-service-v2-346f059914a290be4851/release/alpha.py replace-v2 \
  --root /home/paranoid/paranoid-alpha \
  --release /home/paranoid/self-service-v2-346f059914a290be4851/release \
  --ip 157.180.49.125 --expected-pg-system-id 7683205479877615472 \
  --discard-server-database
```

This is a **historical command, not a repeatable upgrade procedure**. It ran once,
13:21:58–13:22:01 UTC, exit 0, actual output:

```text
PASS: old SERVER cluster discarded without backup; fresh self-service v2 ready offline; start dedicated unit
```

Only old `ROOT/data` was discarded. New PG16 system ID is
`7683525211206671315`. Post-replacement checks before start confirmed stopped PG,
verified selected release, preserved public-cert/config-other-fields hashes,
unchanged TLS key metadata, unit/link and socket/lock identities, old releases,
stat-only backup-tree inventory, and neighbor PIDs/start times. TLS private key
was never copied into evidence; no private values were printed. Only config
`deployment` deliberately changed `key-v1` to `self-service-v2`.

The same preserved enabled unit started successfully at 13:22:38 UTC, with no unit,
linger, firewall, Nginx, Docker or shared-PostgreSQL changes. Observed supervisor
PID 1286107, private PG PID 1286108, server PID 1286121, exact listener
`157.180.49.125:38443`, actual environment `PARANOID_MODE=self-service-v2`.
Preservation comparisons passed again after start. Neighbors retained Nginx
4077836, Docker 1386, shared PostgreSQL 41171 and their activation timestamps.

## Actual readiness and public checks

The staged controller's `health --root /home/paranoid/paranoid-alpha` exited 0:
`PASS: TLS authenticated database readiness`. This exercises v2 metadata
version/realm/SPKI, required columns and enabled downgrade guard, plus verified
HTTPS liveness. It is not full schema attestation or E2EE.

External probes verify the retained certificate, exact IP SAN, validity and SPKI
`sha256//iqWUqRSPYQ2p3mcdfHrnxpDmceU+sOijuTG+64iJcLo=` before HTTP, using TLS 1.3,
HTTP/1.1, no proxy/redirect or insecure mode. Certificate expires
2026-12-07 16:41:17 UTC. Explicit trust in this self-signed leaf is not an Android
system-CA-chain requirement.

| Actual public probe | Result |
| --- | --- |
| GET `/health` | 200, `{"protocol":"paranoid-self-service-v2","status":"ok"}` |
| GET `/v2/messages?after=0&limit=1`, no auth | 401 |
| Same request, invalid Bearer | 401 |
| POST `/v2/registration/commit`, no proof, `{}` | 401 |
| GET `/v0/messages?after=0&limit=1` | 404 |
| POST `/v1/registration/challenge`, `{}` | 404 |
| GET `/v2/updates/android` | 404, expected absent publication |

Independent native curl probes at 13:26 UTC also returned exit 0 / HTTP 200 with
the retained correct pin and exit 90 / HTTP 000 with a deliberately wrong pin
(`SSL: public key does not match pinned public key`). No HTTP request or insecure
fallback followed the wrong-pin failure.

Post-start read-only catalog/count inventory: app DB only `postgres`; ss_accounts,
ss_devices, ss_conversations, ss_messages and guard room_state all 0; ss_meta 1.
No synthetic phone registration, grant, message or content read was performed.
`ROOT/updates` remains absent; publication is outside this rollout. Its expected
404 is not a failure of v2 registration compatibility.

## Evidence and remaining limits

Unique retained evidence directory:
`/home/codex/paranoid-self-service-evidence/live-rollout-kbo345jb/`.
It contains independent `FPD-D01-closure.md`, before/after inventory and
preservation snapshots, staging hashes/native outputs, exact stop/replace/start
commands with exits/times, stopped guards, health output, HTTPS observations and
scripts. SSH used the authorized encrypted credential only through a pipe to a
temporary agent, strict existing known_hosts and no forwarding; agents closed.
No sibling evidence or executable artifact was rewritten.

First updater-enabled APK still needs external **in-place** installation on the
phones. Installed signer/version, Android state continuity, real v2 registration,
contacts, two-phone E2EE/receipts/offline retry remain separate verification.
No phone was reset or installed by this rollout; no new signer or pin was created.
V2 history-preserving update/backup/restore/code rollback remains unsupported by
this fresh-only controller. Never repeat discard, remove markers, use legacy
backup/update/switch, restore old disposable data or delete locks/PID files.
No additional v2 restart/reboot, child-crash or phone acceptance test is claimed.
