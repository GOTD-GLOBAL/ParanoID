---
status: draft
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-08
---

# RFC-0009: Isolated native Linux alpha package

## Scope and authority

REQ-DEPLOY-001, REQ-MSG-004 and REQ-SEC-001 drive this package. The owner
[martadvix-web authorized](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
preparation and isolated deployment for two OPPO testers, non-sensitive data,
IP HTTPS on 38443, separate service/data, no neighboring-service changes,
after configuration, security and rollback checks. This task prepares/tests
locally only: no SSH, credential decryption, remote mutation, merge or push.
ADR-0003 applies; independent review is pending the parent reviewer. This RFC
and the companion draft ADR do not claim production architecture acceptance.

## Proposed deployment boundary

Use a versioned native Linux bundle built with Cargo.lock. Python 3, OpenSSL,
PostgreSQL 16 and systemd are explicit host prerequisites; install no packages
implicitly. Docker is not required. A dedicated unprivileged service account
runs one systemd user unit supervising a private PostgreSQL cluster and the
server. PostgreSQL uses only a private Unix socket; never existing TCP 5432.
No Nginx/proxy, ports 80/443, existing database or host firewall is modified.

Development mode remains loopback-only. A separate explicit `closed-alpha-v0`
mode requires direct TLS termination in the Rust server, port 38443, private
Unix-socket DB and no CI override. Missing/invalid TLS fails closed, never HTTP.
The runtime never receives Olm keys. Tokens remain disposable closed admission,
not production identity. Existing ciphertext/receipt/client contracts do not change.

## Lifecycle and history

Persistent data/config/TLS identities live outside immutable releases. Supervise
both children; child failure exits the group so systemd restarts both. Health
must check a DB-backed authenticated cursor read over verified TLS, not just
liveness. Retain all releases, backups and history; no automatic deletion.

Updates/rollbacks only permit identical schema hashes. Stop writes, make a
restricted logical dump, restore it into a newly created isolated database,
compare canonical data, then switch the release pointer and restart. Never
restore an old backup over live data as a code rollback: that loses later
messages. Schema changes and PostgreSQL major upgrades require a new reviewed
migration package. Backups include ciphertext/routing metadata but no tokens,
TLS private key or client content keys; private local copies only, encrypt
separately before any transfer. Disk loss recovery needs separately protected
configuration/TLS identity and an explicit recovery procedure, not automatic repin.

## Threat delta and validation

Direct TLS adds internet-facing handshake/HTTP exposure. Closed bearer admission,
body/page/row/payload quotas, global 20 HTTP requests/second, a 10-second handler
deadline and process resource limits bound some abuse, not
volumetric DoS; risk owner martadvix-web. This remains private test-data alpha.
The OS account/root can read transport credentials, TLS key and metadata but not
client content keys. A compromised same-account process can replace artifacts;
hashes are integrity checks, not publisher signatures. Use a dedicated account,
trusted artifact transfer and review before installation. No request access logs.

Tests must exercise direct TLS, wrong trust rejection, plaintext rejection,
auth, durable append/retry, process crash/restart, backup/isolated restore and
schema-compatible update/rollback preserving post-update history. systemd
syntax checks are not boot evidence. Mark unavailable runtime/host/phone checks
NOT RUN, never replace Docker evidence with native evidence without labeling it.
