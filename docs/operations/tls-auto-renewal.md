---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# Automatic same-key renewal: installation and recovery contract

Installed on the existing host after independent review and actual checks below.
See [proposal/authority/threats](../rfcs/tls-same-key-automation.md); this records
bounded deployment, not permanent architecture acceptance.

## Installation gates (coordinator only)

1. Review exact source and tests independently; verify PR #30 dependency. Record
   scoped owner authorization without inventing a Telegram permalink or accepted ADR.
2. Read-only host inspection: owned 0700 `/home/paranoid/paranoid-alpha`, `tls`,
   `data`; owned single-link 0600 cert/key/config/unit/operation.lock; existing
   P-256 SPKI `8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`.
   Release `alpha.py` may be owned 0755 (or other non-group/world-writable mode);
   do not chmod an installed release to 0600. Confirm synchronized system time,
   systemd user manager, installed Python cryptography, health command and
   unit fragment match the intended root. No runtime package install or sudo.
3. Install reviewed `deploy/tls_renewal.py` as
   `/home/paranoid/tls-renewal/renew.py` (owned, 0600), directory 0700; create
   `state/` owned 0700. Install service/timer templates in the same user's systemd
   unit directory. Keep the maintenance script outside rotating releases.
4. Run `/usr/bin/python3 /home/paranoid/tls-renewal/renew.py --check` as paranoid;
   parse JSON and require `result: not_due` for this first installation. A due or
   pending-recovery result requires a separately inspected installation path.
   Run `systemd-analyze --user verify` on installed units. Exercise real synthetic
   loopback TLS and actual user-manager permissions; mocked lifecycle tests alone
   are not evidence for host operation.
5. `systemctl --user daemon-reload`, then start the **service** once. Require
   successful exit and unchanged application PID/start timestamp, certificate,
   config and package before enabling the timer. Only then enable/start
   `paranoid-tls-renewal.timer`; inspect its next trigger and service journal.
   Do not induce a real early renewal by adding a force flag.

## Local verification and reusable fixture interface

`/usr/bin/python3 -m unittest deploy.test_tls_renewal -v` exercises synthetic
P-256 certificates, real atomic/fsync files, no-op/repeat, rollback, crash replay,
drift and permissions. Only systemd/network operations are mocked explicitly.
`systemd-analyze --user verify deploy/paranoid-tls-renewal.service
 deploy/paranoid-tls-renewal.timer` checks templates; `systemd-analyze calendar daily`
checks the calendar expression. Test transcript: `/tmp/paranoid-auto-renew-tests.log`
in the implementation environment (not portable repository evidence).

Fixture callers may import `Renewal(root, state, pin, ip, ops, now=None)` and
`SystemOps(root, unit=..., ip=...)`. A fixture with a differently named unit also
sets module `UNIT` for the baseline unit path. `now` is naive UTC for compatibility
with installed cryptography 41.0.7; production uses real UTC, fixed root and pin.
No configurable host/force CLI exists. Production `SystemOps` uses real user
systemd, `current/alpha.py health --root ROOT`, and exact DER/IP TLS on port 38443.
Unit source must resolve to `ROOT/UNIT`, no drop-ins or pending daemon reload.
Only static loaded properties are hashed: `ExecStart` runtime PID/time fields
would spuriously break a real restart. Data directory inode/device is guarded;
this script does not itself query PG identity or audit rows. The installed health
controller supplies authenticated database readiness; a synthetic no-PG fixture
must explicitly disclaim database acceptance.

## Operation and failure

Daily persistent timer; due within 30 days, 90-day validity starting five minutes
before issuance. Brief dedicated messaging outage includes supervisor-controlled
private PG restart. No key change, client repin or contact/channel migration.
Only existing authenticated health and direct TLS verification use networking.
Inspect `systemctl --user status paranoid-tls-renewal.service` and
`journalctl --user -u paranoid-tls-renewal.service`; nonzero exit is a failure,
not a skipped success. `state/failure.json` retains the latest failure even after
later success. Transaction directories are retained indefinitely (public certs
and guards only); no automated purge. Arrange operator monitoring separately.

`--check` is read-only and never recovers pending work. Normal invocation under
the same operation.lock recovers a pending transaction before considering expiry,
restoring only a recorded certificate under identical recorded config/release/
unit/key/data identity. It reports failure after recovered interruption; inspect
receipts before a later scheduled retry. Never delete a pending journal to make
an uncommitted renewed certificate look not-due. Unknown drift or an expired old
certificate requires attended investigation; do not overwrite keys/config/data.
Restore the recorded environment only with separate authorization, then rerun.

To disable scheduling, stop/disable the **timer**, not an active maintenance
transaction. Wait for the oneshot or inspect its pending journal before changing
release/config. If terminated, next invocation performs journal recovery. Keep
script and state until all pending recovery is resolved. Disabling automation
requires a manual renewal/reminder before expiry. Key compromise/rotation is a
separate RFC; this automation is not compromise recovery or indefinite key safety.

## Observed installation — 2026-09-13

Sergey confirmed in the current ParanoID Telegram task:

> настраиваем автопродление сертификата без смены ключа

The original message permalink is unavailable in this context; this is scoped
operational authorization, not fabricated permanent ADR acceptance. The
[host receipt and review/test evidence](../project/evidence/tls-auto-renewal-20260913/README.md)
record the implementation and actual activation at approximately 10:10:57 UTC.
The prior owner delegation comment in issue #27 is separate, not TLS approval.

- Script `/home/paranoid/tls-renewal/renew.py` SHA-256:
  `fb962a83a94925eefce773435464d536e0f670a9b90f01bc270dc840ef3cb3a8`.
- Service and timer installed as owned 0600 files under
  `/home/paranoid/.config/systemd/user`; maintenance root/state directories 0700.
- `systemd-analyze --user verify`: exit 0, no diagnostics.
- Actual oneshot: `Result=success`, `ExecMainStatus=0`, `result: not_due`;
  `next_due: 2026-11-12T07:38:09Z`. It exits normally; it is not a resident daemon.
- Timer: `enabled`, `active`, `Persistent=yes`; observed next run
  `2026-09-14 00:20:44 CEST`. Daily local midnight plus up to 30 minutes jitter;
  the exact minute varies. `Linger=yes` was already enabled and unchanged.
- Before enabling, the application PID/start time, certificate PEM, configuration
  and selected server package were verified unchanged. No fresh certificate was
  issued during installation. Existing expiry remains December 12.
- Read-back of installed script hash and service/timer states passed. The installed
  alpha health command returned actual TLS/authenticated-database readiness; the
  unchanged Android `PinnedTls` JVM probe returned external HTTP 200.

Independent initial review found a genuine installer ordering/no-due gate issue,
fixed before installation. Its second alleged issue (unit mode 0755) was a false
premise: fresh host stat shows executable `alpha.py` 0755 and private unit 0600.
The closure review explicitly corrected this and APPROVED the unchanged runtime
source and corrected installer. Model identity was not exposed by the runtime;
these are fresh isolated AI reviews under ADR-0003, not human audits.

Thirteen unit/fault tests and four installer-gate tests passed. A separate
**actual local user-systemd and loopback TLS** fixture tested due renewal,
not-due PID preservation and failed-readiness rollback. Its certificate/key were
synthetic and its controller readiness token was explicitly stubbed around real
TLS; no PostgreSQL acceptance is inferred from that fixture. The host installation
used the real installed controller for its separate readiness check.

No hosted due-cycle, hosted failure injection, machine reboot, physical phone,
iOS/TestFlight or complete history-row comparison was performed by this task.
Failure visibility is retained state plus systemd journal; Telegram/email alerts
are not configured. No server package, database, firewall, DNS, APK or push change.
