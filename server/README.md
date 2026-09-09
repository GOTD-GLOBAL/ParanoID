# ParanoID development transport server

Working local development code, NOT a deployed messenger or accepted production
protocol. See [RFC-0008](../docs/rfcs/0008-executable-text-development-slice.md)
and [draft ADR-0004](../docs/decisions/0004-development-transport.md).

## Reproduce on Linux

The separate [key-registration candidate](../docs/operations/key-registration-local.md)
adds local-only TLS key admission under proposed RFC-0010/ADR-0006. It does not
change the deployment controller or accept a production protocol. The v0 mode
below remains for unmigrated development fixtures only.

Requires an unprivileged user, Python 3, Rust/Cargo (tested 1.98.1), and PostgreSQL
16 binaries. No running database, Docker privilege or production access is needed.

```sh
python3 scripts/check-server.py
```

This command creates a fresh private cluster/Unix socket, disables TCP, executes
real HTTP/PostgreSQL tests, then stops/removes the disposable cluster. It installs
nothing. Set `PG_BIN` if PostgreSQL binaries live elsewhere. Test-created schemas
are removed with that cluster. CI uses a digest-pinned disposable PostgreSQL
service and the same Rust suite. CI fixture passwords are public synthetic values,
not real credentials; no untrusted GitHub event text enters workflow commands.

## Development binary

```sh
cargo build --locked --manifest-path server/Cargo.toml
# Configure locally without shell tracing; do not commit an environment file:
# PARANOID_DEVELOPMENT_ONLY=1
# PARANOID_DATABASE_URL=<dedicated private development Unix-socket database>
# PARANOID_ALICE_TOKEN=<64 random lowercase hex characters>
# PARANOID_BOB_TOKEN=<64 independently random lowercase hex characters>
# PARANOID_BIND=127.0.0.1:38300 (default; non-loopback is refused)
# PARANOID_QUOTA_BYTES=16777216 (default payload-byte quota)
server/target/debug/paranoid-server
```

Tokens must come from a CSPRNG, not the public `a`/`b` test fixtures. Do not put
credentials in URLs, CLI arguments, logs or Git. Environment credentials remain
visible to the same OS user/root; this is not a production secret-storage design.

The binary checks that the Unix socket and its `paranoid-*` parent are private
0700 directories with the same owner. This prevents accidental system/remote DB
use, not a malicious operator from forging a directory name. A narrowly scoped
`PARANOID_CI_TEST_DATABASE=1` override permits only user/database `paranoid_test`
on 127.0.0.1:5432 for the disposable CI service. It does not prove that arbitrary
operator-supplied databases are disposable. Never set it for a real database.

## HTTP contract

- `GET /health`: liveness, NOT continuous DB readiness.
- `POST /v0/messages`: UUID `id`, `recipient` (`alice`/`bob`) and base64
  `ciphertext`. Authenticate via `Authorization: Bearer <token>`; sender comes
  from that credential. No registration or phone/email required by this fixture.
- `GET /v0/messages?after=0&limit=50`: only the authenticated recipient's inbox.
- Send success returns `id`/committed `sequence`, not recipient delivery or reading.
  Identical retries return the same result; altered retries return conflict.
- Malformed JSON/query and handler errors use static error codes without reflecting
  submitted field names/values. No raw DB errors or token values enter error logs.
  Unknown JSON fields and protocol routes are rejected.

Decoded payload 1–16384 bytes; HTTP body at most 24576 bytes; page size 1–100.
One fixed room serializes sequence allocation through transaction commit with
`synchronous_commit=on`. Payload quota and a hard cap of 100000 rows reject NEW
writes without eviction; retries still work when full. This is not an exact disk
usage promise: indexes/row overhead need monitoring. There is no deletion API,
automatic purge, schema upgrade/downgrade contract or server-side content key.

## Evidence and missing capabilities

Real HTTP and PostgreSQL tests cover acceptance, lost-response retry, conflict,
concurrent retries, recipient isolation, bad auth/input, non-evicting quotas,
extractor redaction, configuration gates and server process kill/restart.
An Olm fixture exchanges actual ciphertext through HTTP/DB and decrypts replies;
identities/peer keys are trusted inside the test process. This is NOT remote peer
authentication, two physical phones, durable client crypto state or an Android app.

The development transport alone provides no root/device recovery, peer delivery
receipts or mobile UI; the separate Android client now implements its documented
development subset. Do not expose development HTTP through a reverse proxy as a
shortcut around its loopback boundary. The separate explicit `closed-alpha-v0`
mode terminates TLS directly on 38443 and requires a private Unix-socket DB with
no CI override. See the [native alpha runbook](../docs/operations/linux-alpha-deployment.md)
for the locally verified package, resource/rate bounds and rollback contract.
This does not claim a hosted deployment. The product acceptance target
remains two OPPO phones on an isolated hosted instance installed by the same
simple reproducible Linux package, after client/auth/TLS boundaries are completed.
