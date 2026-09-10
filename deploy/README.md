# ParanoID native private-alpha bundle

## Optional voice TURN issuer controller

REQ-CALL-006/RFC-0018 adds the `self-service-v2-turn-file-v1` controller
capability and one closed package member, `voice-turn-controller.json`.
New v2 bundles contain nine regular members. Old v2 bundles remain valid with
TURN disabled; the existing schema and same-data maintenance probes retain their
contracts. `voice-turn-capabilities` identifies the optional controller support.

The exact optional config entry is `"voice_turn": {"v": 1, "relay_ip":
"157.180.49.125"}`. It is allowed only in self-service-v2 and the IP must equal
the saved config IP. Absence preserves existing unit bytes and disables issuance.
Enabling it adds `LoadCredential=voice-turn-secret:ROOT/voice-turn/issuer.secret`
to the versioned messaging USER unit. The source is an isolated 0400 file owned
by the messaging account, containing exactly 64 lowercase ASCII hex bytes with
no newline. The systemd runtime copy is opened with no-follow/nonblocking flags,
validated through its descriptor, then passed as an absolute path through
`PARANOID_TURN_SECRET_FILE`; `PARANOID_TURN_RELAY_IP` comes from validated config.
Inherited arbitrary TURN variables are stripped. No secret value enters argv,
environment, controller output, snapshots or this package.

Installation is not performed by building. A later authorized enable operation
must preserve the exact current config fields, TLS and PostgreSQL identity;
prepare the private issuer source; review the new effective user unit and
capability; update the server using the existing same-data maintenance procedure;
then atomically install the optional config and matching generated unit before
reloading/restarting that same user unit. The existing `v2_unit` check compares
the resulting unit to `unit(root)`; it does not independently audit arbitrary
systemd drop-ins. Review any effective overrides before activation.

Rollback disables issuance by removing only `voice_turn` and restoring the
matching generated unit, then restarts the existing service on retained data.
Only then can a prior controller that lacks this config capability be selected
through same-data rollback. Never send an enabled TURN config to an old bundle,
rotate TLS, reset identities, discard the cluster or restore over new messages.
The separate [TURN package](turn/README.md) contains its launcher, source patch,
configuration and private runtime dependencies. Required relay expiry/ACL/network
acceptance remains NOT RUN; public service/firewall changes need separate review
and authorization. This section records preparation, not deployment.

## Same-v2 maintenance candidate (RFC-0015, 2026-09-09)

The new `update-v2` and `backup-v2` actions preserve an existing self-service-v2
cluster. They are separate from the historical fresh-install/discard actions
below. Local populated PostgreSQL/TLS and dedicated user-unit tests pass; final
exact-bundle independent review and authorized hosted deployment remain separate
pending gates. Requirements: REQ-MSG-004, REQ-DEPLOY-001, REQ-SEC-001.

Prerequisites add Python `cryptography` with AES256/GCM support (41.0.7 was
observed on the existing host). The controller imports it before stopping an
update target. Existing runtime and old capability responses stay compatible;
`self-service-update-capabilities` reports
`self-service-v2-encrypted-same-data-v1`. The supplied exact v2 runtime, all three
schema hashes and existing `self-service-v2` config must match. Schema changes,
v0/v1 transitions and a new PG system identifier are refused.

After independent review, verify the exact bundle outside the running root and
retain that new controller there for rollback; the old controller intentionally
rejects v2 maintenance. Existing endpoint/TLS/unit/PG data remain unchanged.
The following is a runbook, not a claim that this candidate is deployed:

```sh
python3 /absolute/reviewed/release/alpha.py update-v2 \
  --root /home/paranoid/paranoid-alpha \
  --release /absolute/reviewed/release \
  --expected-pg-system-id 7683525211206671315
# Code rollback uses the NEW reviewed controller and OLD verified v2 release:
python3 /absolute/reviewed/release/alpha.py update-v2 \
  --root /home/paranoid/paranoid-alpha \
  --release /home/paranoid/paranoid-alpha/releases/346f059914a290be4851 \
  --expected-pg-system-id 7683525211206671315
```

`update-v2` checks the exact PG identifier, current/candidate manifests and
capabilities, key path and existing dedicated active/enabled unit before stop.
The unit fragment must resolve to `ROOT/paranoid-alpha.service` and match the
reviewed root-specific unit text. It holds a separate operation lock, stops only
that unit, obtains the lifecycle lock and starts only private PG on the retained
Unix socket. There is no unit rewrite, initdb, data deletion or application-schema
initializer. A new empty schema-reference database is initialized with the
verified current binary and compared with the application schema before backup.

A unique private `backups/v2-*` directory retains `history.enc` and a verification
manifest. The DB custom archive is streamed through AES-256-GCM, with a fresh
96-bit random nonce, full 128-bit tag and bounded canonical context authenticated
as AAD. The maximum archive is 512 MiB; pg_dump and pg_restore each have a
180-second deadline. A new random 32-byte `ROOT/backup.key` is created exclusively
as a same-owner 0600 file, fsynced, reused and never overwritten or regenerated.
Keep it private: losing it loses access to these backups. It never enters the
bundle, feed, logs or external evidence.

The complete archive is decrypted and authenticated into an anonymous private
temporary file before pg_restore receives any bytes. Restore targets only a new
`verify_v2_*` DB. Exact schema and counts plus ordered SHA256 digests of every
row in all six tables are compared, including account revocation, sequence and
registration budgets. PostgreSQL computes row digests internally; raw application
rows never enter diagnostic output. Restored and schema-reference DBs remain
private in this cluster; monitor disk because they are not purged automatically.
No named plaintext dump or TLS/config copy is retained by this new backup path.

Only successful encrypted-restore comparison permits a staged-code switch.
Copied code files and release directories are fsynced before atomic pointer
replacement; the pointer parent is also fsynced (OR-M5). TLS/config hashes and PG
identity must still match before cutover. Readiness checks the retained IP/TLS
certificate and v2 database binding. Failed startup/readiness attempts the prior
verified v2 code on the SAME current database and returns failure even if recovery
succeeds. New messages accepted after update survive rollback; a backup is never
restored over current messages. Failed compatible recovery stops only this unit.
SIGINT/SIGTERM during maintenance returns nonzero with a redacted diagnostic;
inspect service state and preserved artifacts before resuming.

Maintenance downtime includes dump, encryption, authenticated restore and all-row
comparison, and can take minutes near the 256 MiB ciphertext budget. This is a
bounded offline alpha operation, not zero-downtime deployment. Encryption protects
an archive copied without its key; the key is co-resident with the server, so it
provides no host-compromise protection. These DB-only backups do not preserve
lost TLS/configuration or establish off-host disaster recovery. A retained
verification DB also contains decrypted routing metadata under existing private
filesystem protection. No message content private keys are held by the server.

An additional offline encrypted backup uses `backup-v2 --root ROOT
--expected-pg-system-id ID` with the dedicated unit already stopped, followed by
an explicit same-unit start and health check. Never repeat historical
`replace-v2`, use legacy `backup/update/switch` on v2, remove live locks/PID files,
rotate TLS or reinitialize phone/server identity for an update.

Checks: `test_v2_update.py` exercises populated real PG, encrypted archive
corruption/wrong-key rejection, exact restore, schema/PG/key/lock/unit guards,
code durability and same-data rollback with retained post-update rows;
`test_v2_systemd.py` adds an actual unique disposable local user unit, failed
readiness and automatic rollback; `test_v2_maintenance_interrupts.py` injects
real SIGINT/SIGTERM at backup boundaries. Set `PARANOID_V2_OLD_RELEASE` to the
retained exact v2 release. `PARANOID_TEST_PACKAGED=1` plus
`PARANOID_V2_RELEASE=/absolute/final/release` selects a frozen packaged controller.
These are local/operator tests, not E2EE, phone, reboot or hosted acceptance.

## Historical fresh self-service v2 candidate

When manifest `schema_contract` is `paranoid-self-service-v2`, this bundle has
**eight** regular members: the historical seven below plus `self-service-schema.sql`.
Use `self-service-capabilities` on both server and controller. The original
`deployment-capabilities` probe still describes the unchanged v1 compatibility path.
Do NOT use the historical migration/update/backup instructions below for v2.

Sergey explicitly requested a new database in place of the disposable old SERVER
DB, without preserving it or making backups. This supplied task provenance is
not a permanent architecture approval or authority for the preparation worker to
deploy. The coordinator must review the candidate and repeat prerequisites first.
No permission to erase phone keys/history, rotate TLS or touch neighbors follows.

Existing reviewed root `/home/paranoid/paranoid-alpha`, IPv4 `157.180.49.125`,
port 38443; preserve its exact IP-SAN TLS certificate/key and SPKI
`sha256//iqWUqRSPYQ2p3mcdfHrnxpDmceU+sOijuTG+64iJcLo=`. In that historical one-time scope only its `data` PG16 cluster
was the discard target, including old schema/verify DBs. Keep `tls`, config
IP/other values, socket/lock inodes, existing enabled unit, releases and existing
outside-data backups. Only `deployment` changes from `key-v1` to `self-service-v2`.

Historical one-time action, NOT a repeatable update command, after stopping/verifying only the existing
`paranoid-alpha.service`, checking exact account/root/no-follow/mount boundaries,
unit ExecStart, current PG system ID/TLS and independently reviewed artifact:

```sh
# RELEASE must be the reviewed extracted release, not the current old controller.
python3 "$RELEASE/alpha.py" replace-v2 --root /home/paranoid/paranoid-alpha \
  --release "$RELEASE" --ip 157.180.49.125 \
  --expected-pg-system-id 7683205479877615472 --discard-server-database
```

`replace-v2` validates PG16 identity, TLS key/cert/SAN/expiry/public pin, exact
reviewed public root/IP, private safe paths, stopped PG and lifecycle/operator/
worker locks. It refuses redirected/hard-linked/foreign/mounted/non-regular data,
stages verified code and writes durable sticky v2 intent before deleting **only
`data`**, then runs private initdb and explicit v2 schema initialization/readiness.
No backup/import, unit management, networking change or new TLS generation.
It refuses a second discard in v2 mode, even with a fresh system ID.

After exit 0, unchanged TLS/config-field verification and coordinator go-ahead,
start only the retained unit and run `health`. Existing run/health/unit paths are
v2-aware, without old bearer environment or operator signup. The runtime requires
separate exact-IP opt-in, fixed 38443 and mandatory TLS; local v2 stays loopback.
The existing enabled unit/supervisor provides restart/autostart; no unit rewrite
or new linger/firewall rule is needed. Verify external pinned TLS and real phones
separately; health is not E2EE or device acceptance.

`fresh-v2 --root ROOT --release RELEASE --ip IP` initializes an already empty,
stopped cluster with a release pointer, without deletion/import/backup.
`install-v2` supports a **nonexistent** new root through the existing isolated
installer; never use it to replace the retained root or its TLS. A new root's
TLS is newly generated, so it is not the existing trusted endpoint.

Failures stay stopped. Before sticky intent, old DB remains; after discard there
is deliberately no old DB recovery promise. Do not remove sticky intent or redelete
a fresh v2 DB. Interrupted initdb/committed-schema-before-pointer states require
individually reviewed fresh-state repair, not stale restore or historical runtime.
Legacy backup/update/switch/migrate-key actions still reject v2. The historical
fresh-only slice did not implement v2 update/restore/code rollback; the separate
same-v2 maintenance candidate above now provides that bounded path. No preservation requirement for later
v2 messages is waived. Dedicated same-UID ownership remains a trust assumption;
no hostile-owner or power-loss recovery certification is claimed.

FV2-R01: Ctrl-C/SIGINT caught inside `replace-v2`, `fresh-v2` or `install-v2`
exits **130** with a static redacted diagnostic: completion unconfirmed, keep the
dedicated unit stopped, old server data may already be discarded; no automatic
rollback. Never continue the start step after this result. Existing private PG
cleanup still applies; no marker removal, retry, backup or service recovery is
added. If a new-root `install-v2` was interrupted after enabling its unit, inspect
and stop only that dedicated unit: the message does not attest service state.
Graceful `run` SIGINT/SIGTERM and legacy v0/v1 interrupt handling are unchanged.

Canonical source runbook: `docs/operations/fresh-self-service-v2.md`. Local tests
use disposable PG/loopback TLS and synthetic proof identities; user-systemd
activation/reboot, live host changes and physical-phone acceptance are separate.

## Optional Android update feed (RFC-0013, local candidate)

Only v2 `environment(root)` sets `PARANOID_ANDROID_UPDATE_ROOT=ROOT/updates`.
It does not create or publish that directory; absent feed remains HTTP 404.
Legacy v0/key-v1 environments do not inherit the variable or gain update routes.
The read-only feed is outside `data`: private same-owner `updates/android.json`
and its digest-named APK, with bounded schema/size/hash and no-follow validation.
Source contract: `docs/operations/android-update-publication.md`. Never place
keys/config in the feed; server hash validation is not APK signer verification.
Independent combined-package review and separately authorized publication remain
required. No TLS pin, database, Android state or lifecycle capability changes.

## Historical key-v1 bundle instructions (not fresh-v2)

Two informed OPPO testers, non-sensitive data only. NOT production-ready and not
physical-phone acceptance. No client content/authentication private keys belong
in this bundle. Review source, tar checksum and manifest before execution; hashes
are integrity checks, not publisher signatures. Exactly seven regular members:
server, controller, base/key SQL, test TLS generator, this README and manifest.

Prerequisites: Linux x86_64 compatible libc/libgcc, Python 3.11+ (verification
uses `hashlib.file_digest`), OpenSSL, PG16 at `/usr/lib/postgresql/16/bin`, systemd
user manager and a dedicated unprivileged account. IPv4, exact configured IP on
38443, direct Rustls only. No Docker/Nginx, existing shared DB, package installer,
sudo, firewall or neighboring-service changes. Preserve existing scoped linger.

## Existing alpha: explicit one-way migration

Only after bounded authorization, current-state inventory, independent review
and populated local rehearsal. Use a separately retained copy of this reviewed
controller, not the old `current/alpha.py`. Do NOT run `init` or `install` against
an existing root, clear data, rotate TLS or provision old tokens to testers.

```sh
# From this extracted release, as the dedicated service account:
ROOT=/home/paranoid/paranoid-alpha
RELEASE="$PWD"
python3 alpha.py deployment-capabilities
./paranoid-server deployment-capabilities
systemctl --user stop paranoid-alpha.service
python3 alpha.py migrate-key --root "$ROOT" --release "$RELEASE"
# Only if migration succeeds:
systemctl --user start paranoid-alpha.service
python3 alpha.py health --root "$ROOT"
```

`migrate-key` never stops/starts systemd itself. It refuses a live supervisor or
existing/stale postmaster file, verifies the exact reviewed base/key hashes and
binary/controller capability responses, and compares actual schema against an
isolated reference database. It restores a fresh dump into a separate private
DB and compares every ordered row before mutation. It retains restricted copies
of config/TLS with verified hashes. It atomically adds `deployment: key-v1` to
config, retaining IP and both old tokens, then runs the transactional additive
key initializer and selects the key-capable release. There is no slot assignment
or phone activation in migration. Approval remains explicit exact public keys,
known tester and old-slot mapping; phones perform their own proof/activation.

The sticky config blocks old controllers before schema mutation. The database
startup trigger blocks v0 binaries. Never remove the sticky field or trigger.
Key-only activation and all later rows survive restart and compatible code rollback.
The health action in key mode checks private local SQL plus verified IP TLS
`/health`; it never submits a user bearer or acquires client message authority.
This is operator readiness, NOT an end-to-end authenticated phone test.

## Historical key-v1 compatible update / code rollback

Both directions use the desired reviewed key-capable release:

```sh
python3 alpha.py update --root "$ROOT" --release /absolute/desired/release
# Offline alternative (unit must already be stopped):
python3 alpha.py switch --root "$ROOT" --release /absolute/desired/release
systemctl --user start paranoid-alpha.service
python3 alpha.py health --root "$ROOT"
```

Identical base schema AND exact key capability/schema are required. No generic
schema-change switch or bearer-only downgrade. Binary and controller capabilities
are checked as well as hashes. `update` validates the dedicated unit, serializes
operators across stop/switch/start, restores/compares current backup, changes code
only and checks readiness. On failure it attempts only a compatible previous code
pointer. Failed recovery is explicitly stopped, with data retained. It never
restores a stale dump over current history. The dedicated account/controller and
trusted artifact provisioning remain prerequisites, not a hostile-owner sandbox.

## Failure / recovery boundary

Before durable intent: failure preserves old config/schema/pointer; remain stopped
until diagnosis. After intent but before DB commit: v0 controller is blocked;
rerun this same `migrate-key` to finish. After DB commit but before pointer change:
same command validates existing version/realm/pin and resumes without reinitializing.
An incomplete stage, `config.pending`, preexisting `next`, invalid filesystem state
or stale postmaster requires scoped manual inspection; no automatic deletion or
blind repair. A power loss may require that stopped recovery path. Never revive
bearers to regain availability. Operator/postmaster locks must never be unlinked
while their owner may still be alive.

Paths must be private, same-owner, real, single-link files/directories; no symlink
ancestors, redirected persistent directories or unknown bundle files. Config is
exactly the legacy three fields or those three plus `deployment: key-v1`.
The current symlink selects a verified direct releases child. Temporary Python
imports for inspection must use `PYTHONDONTWRITEBYTECODE=1` so `__pycache__` does
not contaminate the strict release allowlist.

Key workers take a private lifetime filesystem lock in the canonical single PG
socket namespace, separate from the supervisor lifecycle lock. This survives PG
backend death/restart; advisory locking is secondary. No multi-host/multi-socket
or distributed worker support. Key-mode HTTP keepalive is disabled; sixteen TLS
slots include handshakes, with eight-second handshake and fifteen-second absolute
post-handshake lifetimes. Shared-budget starvation/volumetric DoS remain risks.

## Historical key-v1 backups and limits

Stop the dedicated unit, run `python3 alpha.py backup --root "$ROOT"`, then restart
and health-check. Dumps, identity copies, comparison manifests and restored/reference
DBs are retained, never purged automatically. Monitor disk. Identity copies include
old tokens and TLS private key: private local storage ONLY; encrypt before any
transfer, with a separately held key. The historical key-v1 path provides no backup encryption/transfer or automatic
host-loss recovery. The separate new v2 path is described above. Never reset client state or repin TLS. TLS
certificate renewal preserving the key is a separate reviewed operation.

A fresh `install --root NEW_ROOT --ip IPV4 --release RELEASE` is still a v0 fixture,
not automatic key enrollment. The existing root must use the migration above.
Canonical runbook: `docs/operations/key-deployment-rollout.md`; proposed RFC-0011.

## Unified one-host delivery work

[REQ-DEPLOY-003](../docs/operations/voice-single-host.md) requires one coordinated
messaging/private-PG/relay installer. The owner selected the existing host and
bounded network scope after tests/review. Current separate component tools are
building blocks; they do not yet meet the unified installation requirement.
