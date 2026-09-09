---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Key-registration deployment rollout and local evidence

This is a **locally tested candidate**, not a live rollout record. The implementing
worker made no host login/read/write, firewall/neighbor changes, push or merge.
[Owner authority](key-rollout-authorization-2026-09-09.md) reserves the bounded live
rollout to the parent after independent review. [RFC-0011](../rfcs/0011-key-deployment-migration.md)
and [security delta](../security/key-deployment-delta.md) remain proposed/draft,
not architecture acceptance. [ADR-0006](../decisions/0006-phone-key-registration.md)
remains proposed. APK 0.0.4 source/wire compatibility was retained; physical OPPO
acceptance is not replaced by the local JVM/JNI fixture.

## Exact operation boundary

Existing root: `/home/paranoid/paranoid-alpha`; dedicated systemd user service
`paranoid-alpha.service`; existing PG16 role `paranoid_alpha`, DB `postgres`,
private Unix socket; existing configured IPv4:38443 and unchanged pinned TLS.
Do not use install/init, overwrite history, reset keys, rotate TLS, change
neighboring services, auto-assign a slot or treat an empty DB as admission.
Approval/activation of exactly the two owner-supplied public credentials remains
a separate known-tester mapping and phone-proof step.

The release contains seven allowlisted regular files. Its manifest advertises
`paranoid-key-v1`, deployment API 1 and every component hash. Both binary and
controller must answer their exact capability probe. The only permitted schema
transition is base SHA-256
`28035059271b03fe7f05f012effb16087c326381d23eb1ac5542e2935b1bb23a`
plus additive key SQL SHA-256
`f50a37b3b91bdd7b5d74114be58600cae86293881b12cf88909b36d33cb65ee9`.
Actual PG schema is compared with an isolated reference before migration.
No generic changed-schema gate was added. Future incompatible schema/controller/
runtime changes require another reviewed transition, not a manifest relabel.

## Migration commands — parent/operator only after review

Use the verified extracted release and a separately retained trusted controller.
Compare tar SHA-256 with the reviewed evidence before extraction/execution. Inspect
members before extracting into a fresh private directory; never extract over the
installation. From that extracted `release` directory:

```sh
umask 077
ROOT=/home/paranoid/paranoid-alpha
RELEASE="$PWD"
python3 "$RELEASE/alpha.py" deployment-capabilities
"$RELEASE/paranoid-server" deployment-capabilities
systemctl --user stop paranoid-alpha.service
python3 "$RELEASE/alpha.py" migrate-key --root "$ROOT" --release "$RELEASE"
# Execute the following ONLY after successful migration:
systemctl --user start paranoid-alpha.service
python3 "$RELEASE/alpha.py" health --root "$ROOT"
```

The operator explicitly stops the one unit; migration itself does not manage
systemd. Nonblocking operation and lifecycle locks reject concurrent operations
and a live supervisor. Existing/stale postmaster state is refused, never adopted
or killed. A dump is restored into a new private verification database and every
ordered envelope/room row is compared. Key-mode backup also compares metadata and
grants, including active/revoked modes. Private config/TLS copies and their hashes
are retained with the backup. These identity copies include old tokens and the TLS
private key: **encrypt before transfer**, with a key kept separately. No automated
encryption, transfer or backup deletion is provided.

Only after verified backup, config atomically gains `deployment: key-v1`; all
original field values remain. This sticky addition makes the old controller fail
before schema mutation. The additive SQL transaction installs version/realm/pin,
empty grant table and the v0 startup trigger without changing history. Ordinary
key startup never initializes schema. The migration does not approve any phone.
After the pointer switch, supervision uses explicit key mode and exact IP opt-in.

Health uses private local SQL plus verified IP TLS `/health`, without a client
private key or user bearer. It is intentionally not proof of device messaging.
Perform the existing public-key approval/phone flow from the
[registration runbook](key-registration-local.md) with the approved exact mapping;
no client wire or Android source was changed by this deployment worker.

## Update and code rollback

```sh
# New compatible code, using this reviewed controller:
python3 "$RELEASE/alpha.py" update --root "$ROOT" --release /absolute/new/release
# Compatible rollback: substitute the actual retained key-capable release ID.
python3 "$RELEASE/alpha.py" update --root "$ROOT" \
  --release "$ROOT/releases/REVIEWED_KEY_CAPABLE_ID"
```

Both preserve **all current rows**, including post-update messages and activation.
The controller verifies the unit belongs to this root, holds a separate operation
lock across stop/switch/start, creates/verifies a fresh backup and checks readiness.
It rejects bearer-only binaries, old controllers, changed base/key schema and
unsupported capability responses before switching. Hashes/capabilities are not
publisher authentication; execute only trusted independently reviewed artifacts.

A failed update attempts only a compatible previous release. A failed compatible
recovery issues an explicit stop and reports failure, retaining data. A stopped
alternative is `switch --root ROOT --release RELEASE` followed by explicit start
and health. Never restore a stale dump over live data to roll back code.

## Crash/failure matrix

| Boundary | State and safe response |
| --- | --- |
| Candidate/schema/restore fails before sticky intent | Old config/schema/pointer retained; unit remains stopped; diagnose before choosing to resume |
| Durable intent exists, DB transaction not committed | Old controller blocked; same reviewed `migrate-key` can resume against exact v0 schema |
| DB committed, pointer not switched | Old startup trigger and config block downgrade; same command validates version/realm/pin, creates a current backup and resumes |
| Pointer selected, new readiness fails | No implicit migration downgrade; remain stopped or choose an independently reviewed compatible key release |
| Incomplete staged release, `config.pending`, preexisting `next`, stale PG PID file or redirected paths | Fail stopped; retain evidence for scoped inspection. Do not blindly remove or overwrite files to bypass validation |
| Post-cutover update fails | Compatible code rollback only, with current history; failed recovery stops the unit |
| PG advisory backend killed/restarted | Lifetime private OS worker lock remains exclusive; ordinary pool reconnect is safe within this same-host single-socket boundary |
| Original worker killed | Kernel releases its lifetime lock; replacement may start only then; no heartbeat takeover window |

Exception injection exercises the backup, durable-intent and committed-schema
boundaries locally; it is not a power-cut test. Actual process SIGKILL, PostgreSQL
backend termination/restart, systemd restart and isolated dump restoration are
separately exercised. A filesystem/power crash can require stopped manual recovery.
Never unlink worker/lifecycle/operator locks while an owner may still run.

## Reproducible local verification

Use only disposable fixtures and explicit PG16/OpenSSL/JDK/Rust/systemd prerequisites.
`PYTHONDONTWRITEBYTECODE=1` prevents imports contaminating strict release directories.
The E2EE test uses public Java dependencies and locally compiled JNI/classes; it
never copies an Android signing keystore or real phone snapshot.

```sh
export PYTHONDONTWRITEBYTECODE=1
python3 deploy/build.py
# Set to the printed artifact's sibling release directory:
export PARANOID_KEY_RELEASE=/absolute/dist/build-ID/release
python3 -m unittest discover -s deploy -p test_migration.py -v
python3 -m unittest discover -s deploy -p test_migration_native.py -v
python3 -m unittest discover -s deploy -p test_migration_runtime.py -v
python3 deploy/test_migration_e2ee.py
```

- `test_migration.py`: sticky config, exact key hash/API, old binary/controller
  rejection, operation locking and failed-recovery stop, plus containment regressions.
- `test_migration_native.py`: populated PG transition, exception boundaries and
  idempotent CLI resume, unchanged TLS/tokens, v0 startup refusal, key-only health,
  full restored-table/identity copies and actual-schema/postmaster-adoption rejection.
- `test_migration_runtime.py`: exact binary capability response; real TLS close and
  fifteen-second idle lifetime; PG backend termination/restart cannot admit a
  duplicate worker, but original SIGKILL releases the lifetime lock.
- `test_migration_e2ee.py`: real packaged user-systemd supervisor, populated legacy
  Olm snapshots, exact public grants, two real proof activations, pinned TLS/JNI
  E2EE/receipts, post-update messages surviving compatible code rollback/JVM restart,
  both revoked bearer rejections and private health; full four-table dump/restore
  followed by real client sync against the restored DB. The rollback fixture uses
  the same built binary with separately identified reviewed-compatible content;
  it does not prove compatibility of an arbitrary future binary.
- Existing build/containment/native/systemd tests remain separate regression gates.

Build/provenance and final command outputs are recorded in the local implementation
evidence directory `/home/codex/paranoid-key-rollout-evidence/implementation/`.
No log contains real phone credentials or live secrets. Source/current-state,
changelog, canonical indexes and broader registration threat/contract reconciliation
outside this worker's ownership remain the parent's integration responsibility.
