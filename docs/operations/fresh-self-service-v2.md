---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Fresh self-service v2 runbook — preparation and recorded rollout

## Later authorized live outcome (2026-09-09)

The [dated live rollout](self-service-v2-rollout-2026-09-09.md) records successful
installation of exact release `346f059914a290be4851`, independent FPD-D01 closure,
fresh live guards and the single old-data-only replacement at 13:21:58 UTC.
The preserved enabled unit is running v2 and strict pinned HTTPS/DB readiness
passes. The old system ID below is **historical, already discarded**; never rerun
this replacement against the new cluster or use it as a code-update procedure.
No feed/phone operation or architecture acceptance occurred. Earlier worker-local
no-deploy statements below describe preparation scope, superseded only by the
later explicit installation instruction recorded in the dated rollout.

Requirements: REQ-ID-008, REQ-MSG-004, REQ-SEC-001, REQ-DEPLOY-001;
[RFC-0012](../rfcs/0012-self-service-messenger.md),
[draft ADR-0007](../decisions/0007-self-service-messenger.md).
This is a local candidate for independent coordinator review. No live action,
network rule, service restart, merge or phone reset was performed by this worker.

## Scope correction and provenance

See also the canonical [scoped owner correction](fresh-v2-scope-correction.md);
this runbook specifies the replacement implementation and executable boundary.

In the supplied 2026-09-09 task Sergey explicitly corrected the old preservation
plan: “Так на месте старой просто сделай новую!” (make a new database in place of
the old one), then “Не надо ничего сохранять не занимай место” (do not preserve
anything or waste disk space). The coordinator confirmed the isolated boundary
in the read-only `fresh-v2-live-preflight.md` evidence on the same date.

For **this one disposable old ParanoID server database replacement**, discard the
old isolated PG16 `data` cluster, including its old schema/verification databases.
Do not migrate its grants/history, create a pre-cutover dump, copy the old data
folder, or make a new archive of real server state. Existing `backups/` outside
`data` is NOT silently included in deletion. The earlier migration/backup runbooks
remain historical procedures for their own modes, not instructions for this cutover.
This is the explicit REQ-MSG-004 deletion request, not a general retention change.

Preserve the existing TLS key/certificate, config IP and other field values,
client app/signing identity, phone snapshots/root/auth/Olm keys/contacts/history,
private socket directory and lock inodes, unit, releases and neighboring services.
Only the config `deployment` marker deliberately changes `key-v1` →
`self-service-v2`; ordinary users register by device proof, without operator grants.

This task text is supplied user provenance, with **no stable Telegram permalink
or permanent GitHub approval record supplied**. It is not fabricated ADR acceptance,
a new production security claim, or permission for this worker to deploy.
The coordinator must review the candidate and repeat prerequisites before live
cutover. Do not broaden the authorization to other installations or later v2 data.

## Exact reviewed target and trust

From the canonical [hosted endpoint record](linux-alpha-rollout-2026-09-08.md),
[key rollout](key-rollout-2026-09-09.md) and coordinator read-only preflight:

- Account `paranoid`, root `/home/paranoid/paranoid-alpha`.
- **Only deletion target:** `/home/paranoid/paranoid-alpha/data`.
- Existing PG16 system identifier `7683205479877615472`; app DB `postgres`, role
  `paranoid_alpha`, private socket `/home/paranoid/paranoid-alpha/socket`.
- Origin `https://157.180.49.125:38443`; existing IP SAN certificate and key remain.
- SPKI `sha256//iqWUqRSPYQ2p3mcdfHrnxpDmceU+sOijuTG+64iJcLo=` (curl notation).
- Unit `paranoid-alpha.service`, already enabled with scoped linger. Preflight
  locates its actual file under `~/.config/systemd/user/`; retain its existing
  ExecStart through `ROOT/current/alpha.py run --root ROOT`. Do not assume the
  legacy `update` FragmentPath check matches this live unit.
- Reported old app rows: zero envelopes and two grants. These are coordinator
  observations, not a new live query by the implementation worker.

## Implemented candidate

`python3 deploy/build.py --self-service-v2` builds an eight-regular-file bundle:
legacy members plus `self-service-schema.sql`, manifest contract
`paranoid-self-service-v2`. Default build and its seven-file key-v1 contract remain
unchanged. New `self-service-capabilities` probes identify the exact v2 SQL hash,
runtime and controller; old `deployment-capabilities` responses remain unchanged.
Execute only trusted reviewed source/artifacts: hashes are not publisher signatures.

The explicit `PARANOID_MODE=self-service-v2` requires port 38443 and
`PARANOID_REVIEWED_SELF_SERVICE_IP` equal to the bind IPv4. Only the reviewed
`157.180.49.125` or explicitly selected loopback test IPv4 is allowed. Other public
addresses, wildcard, multicast, IPv6, missing/mismatched opt-in and other ports
fail closed. `self-service-v2-local` stays loopback-only; old key-IP opt-in cannot
open that mode. Mandatory TLS/HTTP1 ALPN, bounded ingress and worker locks are reused.
No trust-all TLS, HTTP public listener, bearer fallback or operator signup is added.

Controller actions:

- `fresh-v2 --root ROOT --release RELEASE --ip EXACT_IP`: requires an already
  initialized **empty** private PG cluster and existing release pointer; refuses
  legacy/v2 tables rather than migrating/deleting them. Offline initialization,
  sticky config, v2 schema/guard checks and release selection; no backup or restart.
- `install-v2`: the existing isolated installer for a **nonexistent** root,
  with explicit v2 initialization before generating/validating/enabling its unique
  user unit. Generates fixture/new-install TLS only, never use it on the retained
  hosted root. Existing `install` remains v0.
- `replace-v2 --discard-server-database --expected-pg-system-id ID`: one-shot
  destructive action, **only from sticky key-v1**. Requires the reviewed exact root
  for the public IP, current TLS key/certificate/SAN/expiry and saved public SPKI,
  expected PG16 system identifier, private safe installation paths, operation and
  lifecycle locks plus a held worker lock. Rejects running/stale `postmaster.pid`,
  non-stopped `pg_ctl status`, symlinks, hard links, non-regular entries, foreign
  ownership/device and mounts anywhere at/under `data`. It requires Python's
  fd-based symlink-resistant `rmtree`. It stages a verified release, writes durable
  sticky v2 config **before** deleting exactly `data`, runs the reused private
  `initdb`, explicitly initializes v2, checks DB readiness and selects the release.
  No systemctl, backup, import, TLS generation or automatic retry/discard is invoked.
- `run`, `health`, `unit`: select the v2 runtime from sticky config. Reuse the
  existing supervisor/private PG lifecycle and user-unit restart/autostart config.
  No token is exported into the v2 child. Health checks metadata version/realm/SPKI,
  required storage columns and the enabled historical startup guard, then verified
  IP/CA TLS `/health`; no client signing key or registration side effect.
- Legacy `backup`, `switch`, `update`, `migrate-key` refuse a v2 installation.
  **V2 backup/restore/update/code rollback is not implemented by this fresh-only
  slice.** Do not expose old partial table comparison as verified v2 recovery.
  No automatic downgrade or stale dump restore is available.

The root and all its processes remain trusted to the dedicated account. Path
checks plus exclusive locks are not a sandbox against a malicious same-UID process
concurrently changing mount namespaces/files. No automatic deletion of locks,
stale PID files or partial-install artifacts is provided.

## Future scoped replacement procedure — coordinator only after review

Do not execute these commands as part of local preparation. First independently
review source plus final bundle hashes, stage/extract only allowlisted regular
members into a new private release directory (not over the installation), verify
host ABI/PG16/Python/OpenSSL, exact account/root/IP/SPKI/system identifier and
headroom. Recheck unit ExecStart/ownership, config/pointer, all no-follow/mount
boundaries, current listener and neighboring service PIDs/start times. Retain only
nonsecret hashes/inventory; **no old DB dump or TLS key copy**.

After the coordinator's scoped go-ahead, as the dedicated account, using the
separately staged reviewed controller, not `current/alpha.py`:

```sh
umask 077
export PYTHONDONTWRITEBYTECODE=1
ROOT=/home/paranoid/paranoid-alpha
# Set RELEASE to the actual independently reviewed extracted release directory.
python3 "$RELEASE/alpha.py" self-service-capabilities
"$RELEASE/paranoid-server" self-service-capabilities
systemctl --user stop paranoid-alpha.service
# Verify this unit's supervisor/server/PG are stopped and the old listener gone.
# Do not kill/adopt PG, remove stale PID files, or change neighbors to force success.
python3 "$RELEASE/alpha.py" replace-v2 --root "$ROOT" --release "$RELEASE" \
  --ip 157.180.49.125 --expected-pg-system-id 7683205479877615472 \
  --discard-server-database
# ONLY after exit 0 and unchanged TLS/config-field checks:
systemctl --user start paranoid-alpha.service
python3 "$RELEASE/alpha.py" health --root "$ROOT"
```

No firewall/Nginx/Docker/shared-PostgreSQL/linger change is needed or authorized.
Do not run `init`, `install`, `migrate-key`, legacy `update`, `backup` or recursive
root deletion on the retained installation. Confirm enabled state/ExecStart are
unchanged; do not rewrite the existing enabled unit merely to make the old update
helper accept its FragmentPath.

After start, repeat exact external CA/IP/SPKI verification and negative wrong-pin,
old-route and unauthenticated-message checks. Exercise actual phone-saved identities
registering and messaging through the reviewed APK; check two-phone E2EE/receipts,
offline retry and restart. No operator approval/request/grant QR is part of signup.
Preserve phone state even if registration fails. Verify current v2 rows survive
an explicit restart of this unit and neighbors/TLS remain unchanged. Do not confuse
health or opaque synthetic transport tests with physical two-phone acceptance.

## Fail-stopped recovery, not old-data rollback

FV2-R01 correction: a caught Ctrl-C/SIGINT (`KeyboardInterrupt`) inside
`replace-v2`, `fresh-v2` or `install-v2` exits **130**, with a static redacted
diagnostic that completion is unconfirmed, the dedicated unit must be kept
stopped and old server data may already be discarded. It does not print PASS,
clear sticky intent, retry, back up, roll back or activate a service. Existing
context-manager cleanup still stops private PG. The handler is scoped to these
three operations, independent of CLI option order; legacy v0/v1 actions and
intentional graceful `run` SIGINT/SIGTERM exit 0 are unchanged.

Do not continue the start step after interruption, even if TLS/config fields
are intact. Inspect the actual dedicated service state: `install-v2` on a new
root may have enabled its unit before interruption during readiness. The
diagnostic is an operator instruction, not a guarantee that an already enabled
unit was automatically stopped. No new service-manager recovery is added.

Before durable sticky intent, failures do not delete the old cluster. Diagnose
before deciding whether to resume old code. After intent, do **not** strip the
marker or automatically rerun destruction: `replace-v2` rejects v2 mode, even if a
new system identifier is supplied. Once deletion occurs, the old server DB/grants
are intentionally unavailable; old release directories are not data recovery.

A failure between deletion and completed initdb requires individually reviewed
repair of only the interrupted fresh cluster. A completed empty PG cluster can
use `fresh-v2` after inspection. A committed v2 schema with old pointer requires
individually reviewed selection of the already staged compatible v2 release and
readiness checks, not reinitialization. Leave the unit stopped on any failure.
The inherited `point` helper is lower-level; do not use it to bypass review or select
historical code. Forced power-loss and exhaustive failure-boundary recovery remain
unverified; no automated crash-resume claim is made.

## Local verification and limits

Permanent checks: `deploy/test_fresh_v2.py`, `deploy/test_fresh_guards.py`,
`deploy/test_v2_interrupts.py`, server
binary bind tests and the existing server/deploy suites. Tests use generated
loopback TLS, disposable private PG and synthetic device proofs/messages. They
exercise fresh init, real supervisor start/stop/start, three independent self-
registrations, two recipient messages and exact retries after restart, v1-route/
bearer rejection, unchanged TLS/outside-data sentinel, explicit stopped cluster
replacement with old verification DB removal, no new backups, wrong-ID/confirmation/
live-PG/lock/link guards and repeat-discard refusal. Opaque test payloads are NOT
E2EE. No real TLS key/old DB is copied into evidence.

The interrupt regression runs the unchanged selected controller through `runpy`
and sends real SIGINT using unique AST function/statement anchors, not fixed line
numbers. It verifies exit 130 before discard (after sticky intent), after discard
(before initdb), and during fresh initialization with real private PG cleanup.
Installer interruption is checked before manager calls; ready v2 `run` receives
real SIGINT/SIGTERM and retains graceful exit 0. These are bounded process tests,
not exhaustive subprocess interruption or forced-power-loss certification.

Fresh installer tests run real initdb/schema/TLS and `systemd-analyze --user verify`,
but intercept user-manager activation and readiness at that orchestration boundary.
The separate supervisor test actually checks readiness and messaging twice. This
proves generated autostart configuration/orchestration, **not actual systemd
activation, reboot or physical phones**. Injected mount records test parser guards;
no mount or network rule is created. Final command outputs, provenance and known
limits are retained in `/home/codex/paranoid-self-service-evidence/fresh-v2-preparation.md`.

The earlier integration report's proposed legacy migration/pre-cutover backup
work is **superseded for this one fresh replacement**, not silently declared tested
or implemented. Future v2 history-preserving upgrades/restore and remaining phone/
architecture gates stay separate. Independent candidate review is still required.
