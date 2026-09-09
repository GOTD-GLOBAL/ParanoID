# Self-service server: observed vertical TDD ledger

Date: 2026-09-09. Branch: `feat/self-service-server`, based on `a76b7c9`.
Draft/local implementation only; no commit, push, deployment or ADR acceptance.
All commands below were actually executed against disposable private PostgreSQL.
This ledger records condensed **observed output**, not fabricated sample logs.

## Sequence and prerequisites

Read AGENTS-required material, live issue #16 and the server/security contracts.
Wrote `docs/protocol/self-service-v2.md` before test/production code. An owner
correction then split server/client worktrees; three owned new files were preserved
and transferred. No client/deploy files were edited or reverted by this worker.

The initial fixture did not compile because SQLx 0.9 rejects dynamic `String` SQL.
That was **not** counted as RED; it was corrected to the repository's QueryBuilder
pattern before the first behavioral RED below. The Python wrapper's optional
importlib spec/loader diagnostic was also fixed. Automatic editor lint invoked
Rust 2015, reporting spurious async errors; actual Cargo edition is 2021 and the
real builds below compiled successfully.

Command prefix for each focused cycle:

```sh
TEST_FILTER=<filter> python3 server/check-self-service.py
```

The wrapper delegates private PostgreSQL creation/readiness/cleanup to
`scripts/check-server.py` and changes only Cargo's test selection. Each RED run
below reported `0 passed; 1 failed`; its following GREEN was run before moving to
the next behavior. Expanded verification of a previously implemented tracer is
identified separately, rather than falsely labelled a fresh RED cycle.

## Observed RED -> GREEN cycles

| Filter / vertical behavior | Actual RED signal | Actual subsequent GREEN |
| --- | --- | --- |
| `fresh_offline_schema_has_no_operator_or_accounts` | `explicit offline self-service initialization is missing: ParanoID development server could not start or stopped with an error` | `1 passed; 0 failed` after explicit offline schema helper |
| `three_accounts` | HTTP challenge `left: 404`, `right: 200` | `2 passed; 0 failed` running both current tracers after v2 registration, device PoP, immutable device rows and replay consumption |
| `auth_status` | unknown auth HTTP `left: 404`, `right: 401` | `3 passed; 0 failed` after known-device auth/status and router restart behavior |
| `registration_capacity` | over-capacity commit `left: 200`, `right: 429` | `1 passed; 0 failed`, including exact fresh retry at 1024 accounts |
| `new_account_rate` | ninth new account after restart `left: 200`, `right: 429` | `1 passed; 0 failed` with persisted eight-per-60-second-window metering |
| `unauthenticated_ingress` | `auth requests must be bounded before DB lookup` | `1 passed; 0 failed`, including four/account and sixteen/global challenge caps with zero durable accounts |
| `general_messaging` | `challenge should succeed`, `left: 401`, `right: 200` | `1 passed; 0 failed` after general conversations, sender-bound append, idempotency and retained cursor history |
| `ciphertext_storage` | `quota rows=1024 size=16384 global=false`, `left: 200`, `right: 507` | `1 passed; 0 failed` testing actual seeded row/byte boundaries for account and global quotas, unchanged rows and exact retry |
| `offline_migration` | `verified legacy migration must work: approved` | `1 passed; 0 failed` across approved/pending/active/revoked histories, matching-key promotion and unknown-key isolation |
| `migration_rejects` | `must reject ALTER TABLE key_grants ADD COLUMN surprise TEXT` | `2 passed; 0 failed` for positive/negative migration after exact structural snapshot comparison |
| `local_tls_mode` | `explicit self-service TLS mode must start without legacy bearer env` | `1 passed; 0 failed` after loopback-only TLS runtime and shared lifetime/offline lock |
| `conflicting_device` | conflicting device commit `left: 503`, `right: 409` | `1 passed; 0 failed` after explicit transactional conflict check |
| `historical_admin` | `key admin must refuse v2 before touching old schema` | `1 passed; 0 failed` after admin cutover rejection |
| `pre_marker` | `old v0 initialization SQL must fail even without marker-aware code` | `1 passed; 0 failed` after fresh startup guard and archived key-meta/version advancement |
| `nominally_empty` | `unknown existing schema is not fresh` | `1 passed; 0 failed` after counting existing schema objects rather than only tables |
| `durable_device` | auth binding changed after challenge issuance: `left: 200`, `right: 409` | `1 passed; 0 failed` after repeating every persisted binding check inside the operation transaction |
| `migration_rejects` (standalone type regression) | `must reject CREATE TYPE unexpected AS ENUM ('state')` | `2 passed; 0 failed` after adding standalone types to the structural snapshot |

During structural-comparison GREEN, the positive migration initially failed too.
A fixture-only diagnostic exposed PostgreSQL `42725`, `operator is not unique:
text || "char"`. Explicit catalog `"char"` casts fixed the actual cause; then
both positive/negative migration tests passed. No production raw-error logging was
introduced. A later test-only duplicate-JSON fixture initially had Rust quoting
errors; using a raw literal corrected the test before executing it.

## Expanded adversarial and lifecycle verification

These extend the earlier proof/persistence tracers; they are not falsely presented
as independent RED-first feature cycles:

- `every_proof`: actual HTTP rejects independently mutated id, nonce, epoch, expiry,
  realm, pin, account, device, credential fingerprint, purpose, method, path and
  body digest; wrong device signer; changed request body/path; duplicate JSON;
  substituted account/device/fingerprint. Invalid proofs leave the genuine proof
  usable; two concurrent valid uses return exactly `[200,401]`. Passed.
- `local_tls_mode`: also seeds actual HTTP messages, serves them through verified
  TLS, SIGKILLs/restarts the real executable and compares exact retained inbox.
  A second worker on a **different port** fails; offline init of a **different
  fresh database** sharing the private socket fails while the worker owns the lock.
  Wildcard bind fails. Passed.
- `expired_v2_challenge_never_creates_an_account`: real 61-second wait, then 401,
  no account row, fresh proof retry. Passed in the complete suite.
- `migrated_history`: actual pg_dump/psql restoration to a fresh database preserves
  imported messages, old exact retry, post-cutover sequence 4, full inbox and
  key-only downgrade refusal. Passed. This is database-fixture recovery, not a
  deployed lifecycle/controller backup or Android snapshot migration.

## Static checks and full regression status

Executed and passed:

```text
cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings
Finished `dev` profile [unoptimized + debuginfo]
```

The first Clippy run exposed the inherited main-file test module before executable
items. Moving that unchanged test module to the end fixed the lint; no lint was
disabled. `cargo fmt` ran for server and shared key-protocol.

Final full command: `python3 scripts/check-server.py` — exit 0. Actual output:

```text
Fresh private PostgreSQL ready; TCP disabled
main unit tests:       1 passed; 0 failed
deployment tests:      1 passed; 0 failed
registration tests:    9 passed; 0 failed; finished in 73.88s
self_service tests:   19 passed; 0 failed; finished in 142.82s
transport tests:      13 passed; 0 failed; finished in 0.65s
Server checks passed; disposable PostgreSQL stopped and removed
```

Total: 43 passing executable tests; no ignored tests. Server/key-protocol
`cargo fmt -- --check`, Clippy with `-D warnings`, and `git diff --check` passed.
`npx --yes markdownlint-cli2@0.18.1` linted 65 Markdown files with zero errors.
An ad-hoc check found all 11 local links in the four owned Markdown files present;
this is local-path checking, not a claim of a complete external lychee run.
An earlier complete run also passed before the final standalone-type regression
and additional dump/restore coverage; the output above is the fresh final run.

An OS-safe `/tmp/hermes-verify-*.py` temporary wrapper additionally parsed the
focused runner, executed the fresh-offline-init test against private PostgreSQL,
and checked server formatting. It printed `AD-HOC verification passed` and was
removed. This was **ad-hoc focused verification**, not substituted for suite green.

The fixture-only migration diagnostic was removed, and initialization is private
behind the locking CLI. No CI, deployed backup/controller, deployment or physical-
device acceptance is inferred from these local checks.
