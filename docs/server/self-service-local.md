---
status: draft
owner: server
last_reviewed: 2026-09-09
---

# Self-service server foundation: local use and verification

Server-only implementation for issue #16. Shared client/server wire fields live in
[the v2 contract](../protocol/self-service-v2.md). Companion
[RFC-0012](../rfcs/0012-self-service-messenger.md),
[ADR-0007](../decisions/0007-self-service-messenger.md) and the
[threat delta/test mapping](../security/self-service-v2-threats.md) are included
as drafts in this candidate. Nothing here authorizes deployment, public
signup on the hosted endpoint, merging, production claims or accepting an ADR.
Android/iOS implementation and physical-device acceptance are separate workstreams.

## Interfaces and explicit local boundary

Build: `cargo build --locked --manifest-path server/Cargo.toml`.
Runtime executable: `server/target/debug/paranoid-server`.

The explicit `self-service-init` command initializes a fresh database or migrates
exact key-v1 fixtures, using:

- `PARANOID_DATABASE_URL`: private local Unix socket accepted by the existing
  development database predicate; canonical owner-private `paranoid-*` parent.
- `PARANOID_KEY_REALM`: intended saved HTTPS origin.
- `PARANOID_KEY_PIN`: its lowercase SHA-256 SPKI digest.

The helper takes the existing `paranoid-key-worker.lock` in the private socket
namespace, before connecting. Stop the existing service first. Never unlink a
live lock or use this helper against the hosted server as part of this task.
It changes schema transactionally, refuses repeated initialization, and rejects
unknown/ambiguous legacy state. It is not a deployment or backup controller.

Runtime settings:

- `PARANOID_MODE=self-service-v2-local` explicitly selects the new router.
- `PARANOID_BIND=127.0.0.1:38300` (or another loopback address/port).
- `PARANOID_DATABASE_URL` as above, pointing to already initialized v2 storage.
- `PARANOID_TLS_CERT` and `PARANOID_TLS_KEY` are mandatory PEM paths.

No legacy bearer/grant environment is required for self-service. Public wildcard
or non-loopback binds are rejected, including when old reviewed-IP environment is
present. There is no HTTP runtime fallback. HTTP integration tests bind their own
in-process routers to ephemeral loopback ports; that does not expose an insecure
runtime mode. The actual binary reuses bounded TLS sockets/handshake/stream
lifetimes, HTTP/1-only ALPN, disabled keepalive, process-lifetime file lock and the
existing advisory ownership guard. `/health` is protocol-labelled **liveness**,
not proof of database readiness, E2EE delivery or physical-phone acceptance.

Only `/v2/registration/challenge`, `/v2/registration/commit`, `/v2/auth/challenge`,
`/v2/auth/verify`, GET/POST `/v2/messages`, and `/health` exist on the new router.
Historical v0/v1 routes remain separate fixtures; they are not merged into v2.

## Persistence and migration

`ss_accounts`, `ss_devices`, `ss_conversations` and `ss_messages` use full derived
account IDs. One device per account is immutable in this increment. A singleton
`ss_meta` row serializes registration, account-state checks, message commit order
and quota checks. Sequence numbers are transactionally updated under that lock,
not allocated with a PostgreSQL sequence that could commit out of order.

Quota accounting queries the bounded message table under the same lock; it does
not trust mutable client-supplied counters. This simple implementation trades
throughput for a small auditable transactional path. Account and global row/byte
limits reject new writes without eviction. Exact retries are checked first.
Conversation rows are created only in the successful message transaction. There
is no directory endpoint or server-readable message content key.

Migration verifies the structural legacy schema against a temporary reference
built from the pinned `schema.sql` and `key-schema.sql`: relations, columns,
constraints, indexes, trigger/function definitions and RLS flags. It verifies all
stored credential bindings and signatures, realm/pin, canonical message IDs,
room sequence and byte totals, and rejects unbound populated slots. Owner/ACLs
and PostgreSQL physical identifiers are not part of that structural comparison;
the private database owner and local host remain trusted.

Approved/pending legacy credentials become pending v2 accounts and gain no v2
history access until their matching device signs registration commit. Active
credentials remain active. Revoked bindings remain tombstoned and cannot revive.
All original envelope ciphertext, IDs, sequence values and grant states remain.
`ss_legacy_slots` records only these verified mappings; unknown new roots receive
independent empty accounts. Original `key_meta` is copied into
`ss_legacy_key_meta` before its version advances to 2, blocking old key-v1 startup.
The old v0 initialization trigger remains; fresh v2 databases also install an
empty historical room startup guard. Never remove these guards for rollback.

## Verification commands

```sh
# Disposable PostgreSQL, no TCP listener, no existing cluster or remote host:
python3 scripts/check-server.py

# Same private-PG lifecycle, focused server tracer:
TEST_FILTER=offline_migration python3 server/check-self-service.py

cargo fmt --manifest-path server/Cargo.toml -- --check
cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings
```

Prerequisites are existing Rust/Cargo, PostgreSQL 16 binaries, OpenSSL and curl.
Tests generate only disposable identities/certificates/ciphertext. They exercise
real sockets and SQL, including >2 independent accounts, nonce/transcript
substitution, replay races, restart invalidation, exact retries, all four payload
quota dimensions, account capacity/rate, legacy migration, downgrade refusal and
binary SIGKILL/TLS restart with retained inbox. A populated v2 PostgreSQL dump/restore
also retains imported history, post-cutover append sequence and exact retry behavior. The real v2 expiry test waits 61
seconds rather than claiming a mutated signature proves elapsed-time expiry.
The runner always stops/removes its own private PostgreSQL cluster.

The detailed observed vertical RED/GREEN ledger is in
[`server/self-service-tdd.md`](../../server/self-service-tdd.md). The final full server suite passed all 43 executable tests, including 19 v2
integration tests; Clippy with warnings denied and formatting checks also passed.
These are local results, not CI or physical-device evidence.

## Independent server review evidence

Prior independent reviewer: fresh Hermes context, model `gpt-6-astra`, separate
from implementation. Reviewed `feat/self-service-server` at base HEAD
`a76b7c9fc910d0f29d4b9ea7ff15b97ef1c760e0`, including the 20 changed/new candidate
files, not HEAD alone. The exact reviewed-file hashes are retained in
`server-reviewed-files-sha256.json`. The documentation correction changes docs,
not the application source covered by that runtime evidence.

Evidence retained locally outside Git at
`/home/codex/paranoid-self-service-evidence/`:

| Prior command / artifact | Observed independent result |
| --- | --- |
| `python3 server/check-self-service.py` | Review report records 19 passed, 0 failed/ignored, 143.13s; no separate targeted log retained in this directory |
| `python3 scripts/check-server.py` | `independent-full-server-suite.log`: main 1, deployment 1, registration 9, self-service 19, transport 13; 43 executable tests, zero failures/ignored; private PG cleanup completed |
| `python3 /home/codex/paranoid-self-service-evidence/independent-server-probes.py` | `independent-server-probes.log`: independent Python cryptography Ed25519 transcripts over verified local TLS/private PG, activation/isolation, concurrent retries/commits/cursor, strict parsing/limits and old-route/bearer rejection; all probes passed and children/PG cleaned up |
| Historical executable built outside worktree from unchanged HEAD server/key-protocol | Same probe log: positive v0/key-v1 startup controls, both modes refuse fresh/migrated v2 storage, original envelope bytes preserved |
| Independent report | `server-independent-review.md`: no runtime blocking finding; overall `passed: false` due to documentation blocker SR-01 |

This documentation worker inspected the report, full-suite output, probe output
and implementation/tests before citing them. It did not rerun runtime tests.
The retained report also records successful fmt/Clippy and discloses a separate
standalone `key-protocol` `cargo test --locked` failure (no lockfile; exited before
tests). That standalone invocation is NOT passing test evidence. The protocol was
compiled/exercised by the locked server suite and independent signer probes.

The [ADR](../decisions/0007-self-service-messenger.md),
[threat/test matrix](../security/self-service-v2-threats.md), current-state,
changelog and navigation now address SR-01's missing artifacts. Coordinator
independent documentation re-review is pending; the original report remains
unchanged. Evidence files are local retained artifacts, not invented public review
URLs, CI checks, human audits, owner approvals or v2 deployment authorization.

## Remaining gates and residual risks

- Self-service is technically bounded, not Sybil-resistant. An attacker can exhaust
  eight registrations/minute, 1024 account slots, shared ingress/challenge budgets
  or global message capacity. Copying a public credential can also consume its
  per-account challenge budget, without proving device ownership. Limits reject
  rather than evict acknowledged data.
- Sender quotas do not prevent unsolicited messages to a known account ID. There
  is **no mutual-contact ACL** in this narrow wire contract. A consent/block policy
  needs explicit product/security disposition; it must not silently change the
  client API. Recipient existence can be probed by an authenticated sender.
- Stable IDs, graph, IPs, sizes and timing remain server-visible metadata. Ciphertext
  tests are not proof of new E2EE interoperability; the separate client workstream
  must exercise real multi-peer Olm and peer-authenticated delivery receipts.
- Global commit serialization and aggregate quota scans favor correctness over
  throughput; no production load/fairness/DoS-resilience claim is made.
- The supported process model is one host/private socket namespace. Direct library
  router construction is for tests; deployment must use the locking TLS binary.
- No deployment package/controller or existing schema-hash gate was changed.
  V2-aware upgrade/rollback, verified full lifecycle backup/restore, release artifact
  provenance and explicit rollout authorization remain separate gates.
- No recovery, device rotation/addition, nickname directory, federation, blockchain,
  server-selection UX or deletion contract is added. No client identities were
  read, reset or migrated by the server worker; no live data or secrets were read.
