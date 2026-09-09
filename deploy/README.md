# ParanoID native private-alpha key-migration bundle

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

## Compatible update / code rollback

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

## Backups and limits

Stop the dedicated unit, run `python3 alpha.py backup --root "$ROOT"`, then restart
and health-check. Dumps, identity copies, comparison manifests and restored/reference
DBs are retained, never purged automatically. Monitor disk. Identity copies include
old tokens and TLS private key: private local storage ONLY; encrypt before any
transfer, with a separately held key. No backup encryption/transfer or automatic
host-loss recovery is implemented. Never reset client state or repin TLS. TLS
certificate renewal preserving the key is a separate reviewed operation.

A fresh `install --root NEW_ROOT --ip IPV4 --release RELEASE` is still a v0 fixture,
not automatic key enrollment. The existing root must use the migration above.
Canonical runbook: `docs/operations/key-deployment-rollout.md`; proposed RFC-0011.
