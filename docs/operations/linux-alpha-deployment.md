---
status: draft
owner: operations
last_reviewed: 2026-09-08
---

# Native Linux private-alpha deployment

## Boundaries and prerequisites

This is the locally exercised package from [RFC-0009](../rfcs/0009-isolated-linux-alpha-package.md)
and [draft ADR-0005](../decisions/0005-isolated-linux-alpha-package.md), not a
production-ready messenger. Requirements: REQ-DEPLOY-001, REQ-MSG-004, REQ-SEC-001.
Independent review of this diff remains pending. The
[owner authorization](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
is bounded to two OPPO testers, non-sensitive data, IP HTTPS 38443, separate
service/data and unchanged neighboring services, after safety/rollback checks.
No SSH or production credential access was performed to prepare this package.

Host prerequisites (check separately at authorized rollout): Linux x86_64 ABI
compatible with the build host, Python **3.11+**, OpenSSL, PostgreSQL **16** binaries at
`/usr/lib/postgresql/16/bin`, systemd user manager, a dedicated unprivileged
ParanoID account with a persistent private home, available IP/38443 and disk/RAM.
The artifact dynamically links libc/libgcc; use `ldd release/paranoid-server` on
the intended host before starting. No root runtime, Docker engine, Nginx config,
public DB listener or ports 80/443. Never reuse the existing PostgreSQL service.
The account must not run unrelated applications: its other processes can read
alpha credentials and data. The owner's existing `paranoid` account is the intended
account, subject to the bounded pre-deployment check.

The user manager must survive logout and start at boot. Check
`loginctl show-user paranoid -p Linger`; if disabled, an authorized administrator
must explicitly enable lingering with `loginctl enable-linger paranoid` before
rollout. This package never runs sudo or modifies host-wide services/firewall.
Local tests prove user-unit enablement and automatic restart, **not a host reboot**.
If prerequisites are missing, stop and resolve them within authorized scope;
do not fall back to the existing DB or a proxy around development HTTP.

The package currently accepts IPv4 only; IPv6 is rejected before creating state.
See the [local verification record](linux-alpha-verification.md) for exact results.
The integration harness additionally needs a JDK for the real Android TLS adapter
check; a JDK is not a deployment-host prerequisite.

## Rollout status and network preflight

The [2026-09-08 rollout record](linux-alpha-rollout-2026-09-08.md) records the
initial blocked attempt and subsequent explicitly authorized IPv4 firewall resume.
The retained unit now runs with scoped linger and an externally verified pinned
TLS endpoint. Only inbound TCP 38443 on `enp5s0`, destination `157.180.49.125`,
from any IPv4 source was allowed. IPv6 and existing rules/services were preserved.
Independent package review and four PR #15 checks passed; earlier pending-review
language above describes the local preparation phase. Phone acceptance is unrun.

Before future installation or resume, inspect inbound firewall policy read-only
as part of prerequisites, not just socket availability. An unbound port does not
prove external reachability. If a rule is missing, stop for explicit scoped owner
authorization; do not modify global policy or assume deployment approval permits
a firewall change. Preserve the existing root and identities on resume; `install`
correctly refuses it. See the attempt record for retained paths and remaining gates.

## Build and verify locally

From the reviewed repository revision, with Rust/Cargo available:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 deploy/test_build.py
PYTHONDONTWRITEBYTECODE=1 python3 deploy/test_containment.py
PYTHONDONTWRITEBYTECODE=1 python3 deploy/test_package.py
PYTHONDONTWRITEBYTECODE=1 python3 deploy/test_native.py
python3 scripts/check-server.py
python3 deploy/test_integration.py
python3 deploy/build.py
```

The integration test requires a working **local** systemd user manager and unused
127.0.0.1:38443. It refuses an existing `paranoid-alpha-local-test.service`, uses
fresh disposable data, enables/starts that unit, then stops/disables it and removes
only its temporary synthetic cluster. It does not use production configuration.
The successful update fixture is the same executable under a distinct release
identifier; this proves lifecycle/history compatibility, not an unbuilt future
version. A deliberately invalid executable tests automatic failed-update recovery.

Each build prints a fresh `dist/build-<random>/paranoid-alpha-*-linux-x86_64.tar`
path with a matching `.tar.sha256`. Its private output directory also contains
`release/`: binary, schema, controller, TLS generator, README and manifest.
Only those six regular nonsymlink members enter the archive. The builder never
reuses or deletes old `dist/release` or other operator files; do not transfer
an older tar by guessing its path. Use the exact printed artifact path.
 Cargo.lock pins dependencies; manifest records source commit,
dirty-tree flag, toolchain, architecture and component hashes. Build from a clean
reviewed commit for rollout. The workflow is reproducible; cross-toolchain bitwise
reproducibility and signed publisher provenance are **not** claimed. Hashes detect
corruption, not malicious replacement of both artifact and manifest. Transfer
through the separately trusted operator channel; review before executing Python.

## Install after review on the authorized host

The following commands are an operator runbook, not instructions executed during
local preparation. Transfer only the public release tar/checksum; **never** package
local test credentials, databases or private keys. Verify the checksum, extract
into a fresh private staging directory and confirm its manifest/ABI. Do not extract
over an installed release or an existing service directory.

As the dedicated account, with no shell tracing:

```sh
sha256sum -c paranoid-alpha-RELEASE-linux-x86_64.tar.sha256
# In a fresh private staging directory:
tar -xf paranoid-alpha-RELEASE-linux-x86_64.tar
python3 release/alpha.py install \
  --root /home/paranoid/paranoid-alpha \
  --ip 157.180.49.125 --release "$PWD/release"
```

`install` refuses an existing root/unit, initializes only that root, creates two
independent 256-bit admission tokens, creates a self-signed 90-day IP-SAN TLS
identity, stages the release, verifies the generated unit, enables/starts it and
checks authenticated TLS/database readiness. It does not overwrite partial failed
installs: preserve them, inspect the static error and diagnose offline. It never
prints tokens or private keys. On failure, stop only `paranoid-alpha.service` before
maintenance; do not delete the persistent root to retry.

Filesystem validation occurs before lifecycle writes or service stops. Root and
ancestors must be real, root/account-owned directories without writable ancestors
(except root-owned sticky temporary directories used by local tests). The root
must be a private account-owned absolute simple `paranoid-*` path; symlink
aliases and traversal are rejected. Data/socket/releases/backups/TLS directories
must be private real same-owner directories. Config/lock/TLS files must be
private single-link regular files; config and lock are opened without following
symlinks. Config keys/types are exact: canonical IPv4 `ip` and distinct 64-hex
`alice`/`bob` tokens (case-equivalent hex values are not distinct). Current is
only a verified direct release child with a matching non-dot/non-dotdot ID.
Unexpected release files, redirected targets and preexisting `next` are refused.
Preserve invalid/partial installs for offline inspection, not automatic repair.

`test_native.py` builds/extracts the real archive and tests PG/TLS/history/code
rollback without systemd; `PARANOID_ALPHA_ARTIFACT=/absolute/archive.tar` selects
an existing artifact instead. CI runs this and the package/negative tests with
explicit PG16/OpenSSL prerequisites. It does not run `test_integration.py` or
assume a user manager is provisioned. Local systemd checks remain separate.

Persistent layout:

```text
/home/paranoid/paranoid-alpha/   (0700, dedicated account)
  config.json                  (0600; alice/bob admission tokens + IP)
  tls/                         (key/cert + public-connection.json)
  data/                        (dedicated PG16 cluster; TCP disabled)
  socket/                      (private Unix socket)
  releases/<content-id>/        (versioned code, never overwritten)
  current -> releases/<id>      (atomic code pointer)
  backups/<UTC-random>/         (history.dump + verified manifest)
  paranoid-alpha.service       (only this unit is linked/enabled)
```

Provision the **public** URL and SPKI SHA-256 from `tls/public-connection.json`
out of band. Privately provision only Alice's token to Alice and Bob's to Bob;
never publish `config.json`, tokens in URLs or command arguments, or shared
screenshots. Peer Olm pairing codes are a separate trust input. The Android
[enrollment guide](../../clients/android/README.md) still applies. No server
content keys, peer verification changes or plaintext fallback are introduced.

The above bearer provisioning is current fixture behavior, not the requested
product UX. [RFC-0010](../rfcs/0010-phone-key-registration.md) proposes replacement
with phone-generated keys and exact-key maintainer grants, not token export or
public signup. It authorizes no change to this deployment. Its DB/config migration
is not compatible with the current same-schema update command; review and test
a migration-capable path before any rollout, preserving all retained identities.
The subsequent [local key-registration candidate](key-registration-local.md)
implements and rehearses only isolated fixtures. It does not modify this
controller, relax its same-schema gate or authorize hosted migration.

## Health, restart and resource bounds

```sh
python3 /home/paranoid/paranoid-alpha/current/alpha.py health \
  --root /home/paranoid/paranoid-alpha
systemctl --user status paranoid-alpha.service
```

Health performs a verified-IP TLS, authenticated cursor read against PostgreSQL;
`GET /health` alone is liveness only. It trusts the local certificate, disables
proxies/redirects and performs no mutation. Failure reports no raw credential,
payload or DB error. The generated unit limits memory to 512 MiB, CPU to one core,
tasks to 128, file descriptors to 1024, disables core dumps and restarts on failure.
If either child exits, the supervisor stops the other before systemd restarts.
Private PostgreSQL statement/error-statement logging is disabled. The server
has no access logs; stdout is discarded and only static controller failures enter
journald. Disk capacity, process health and certificate expiry require monitoring.

Alpha mode terminates TLS itself on 38443. It refuses missing/bad TLS and CI/TCP DB
configuration; no HTTP fallback. Development mode remains loopback-only. All alpha
HTTP requests share a 20-request/second fixed-window budget (429 on excess) and
10-second handler deadline. Existing payload/page/row quotas remain. These are
not protection against distributed or TLS-handshake DoS. Quotas reject writes
without deleting history; disk/index/WAL overhead can exceed the payload quota.

## Update and rollback without losing history

Do not run lifecycle operators concurrently. Keep an operator copy of the last
verified controller outside `current` for recovery. Verify a new artifact in a
fresh staging directory. Both directions use the same command:

```sh
python3 release/alpha.py update \
  --root /home/paranoid/paranoid-alpha --release "$PWD/release"
# Roll back code using a retained release (substitute its actual ID):
python3 release/alpha.py update \
  --root /home/paranoid/paranoid-alpha \
  --release /home/paranoid/paranoid-alpha/releases/PREVIOUS_ID
```

The controller verifies that the unit belongs to this installation, checks hashes
and identical schema hash before stopping it, obtains the lifecycle lock, starts
only private PG, makes a dump, restores into a newly named verification database,
and compares every ordered envelope and room-state row. A failed restore blocks
the switch. It retains the dump, checksum/size/tool-version manifest and restored
verification database. Then it stages/selects code and restarts/checks TLS+DB.
Failed readiness attempts the previous code pointer and returns a failure, even
when recovery succeeds. If recovery also fails, stop the unit and investigate;
no data or identities are automatically regenerated or overwritten.

Rollback changes **code only**. It must preserve messages accepted after the
update; never overwrite the live DB using a pre-update dump. There is no automatic
schema migration or downgrade; schema changes, PostgreSQL major updates and
incompatible runtime/config changes require a separately reviewed migration.
Do not rotate TLS keys or credentials as part of a code update.

## Backup and disaster recovery limits

For an additional verified local history backup, stop this unit, run `backup`,
then restart and health-check it:

```sh
systemctl --user stop paranoid-alpha.service
python3 release/alpha.py backup --root /home/paranoid/paranoid-alpha
systemctl --user start paranoid-alpha.service
python3 release/alpha.py health --root /home/paranoid/paranoid-alpha
```

Only ciphertext and routing metadata are dumped. The dump does not contain
admission tokens, TLS private key or client Olm keys. RPO is the last completed
backup; update backups are made with the server stopped. No online-write snapshot
or cross-host disaster-recovery claim is made. There is no automatic backup or
verification-DB purge: monitor disk and decide retention/deletion explicitly.
Restores compare live and restored history and room state; full application HTTP
checks resume against retained live history after switching. Remote copy/restore,
host loss and OS reboot remain **NOT RUN**.

For host-loss recovery, do not restore over an existing instance. First obtain
an isolated target and verify dump checksum/tool major, restore to a fresh DB,
compare counts/data, then exercise authenticated cursor reads with preserved
configuration/TLS identity. Separately encrypt and protect config/TLS backup and
any transferred history dump with an operator-held key outside the backup location.
This package does not implement encryption/transfer or automate disaster recovery.
Loss of TLS key requires explicit re-enrollment, never auto-repin; loss of client
Olm keys makes retained old ciphertext unreadable. Renew the certificate before
90-day expiry preserving its key/IP-SAN/server-auth constraints through a reviewed
procedure; automated renewal/key rotation is not included.
