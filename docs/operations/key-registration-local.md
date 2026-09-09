---
status: draft
owner: operations
last_reviewed: 2026-09-08
---

# Key registration: bounded local operator and test runbook

## Scope and authority

This is the explicitly authorized local candidate for RFC-0010 and proposed
ADR-0006, not a deployment runbook for the hosted alpha. Two known testers, one
phone each, two explicitly assigned existing slots, synthetic data only. No
public signup, new server fleet, recovery, blockchain, iOS, store publishing or
production-security acceptance is included. Independent parent review is pending.

The Android application ID remains `org.paranoid.devtext`; `org.paranoid.text`
is its unchanged Java/JNI namespace. Candidate version is 0.0.4-dev/versionCode 4,
ARM64, API 26+. Build requires the retained signing keystore explicitly and checks
certificate SHA-256
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
It never generates/copies a replacement signing key or uninstalls an application.

The only compiled default connection data are public:
`https://157.180.49.125:38443`, SPKI SHA-256
`8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`.
Saved origin/SPKI always win. This task did NOT add key-registration routes to
that hosted endpoint. Do not present the APK's default as a demonstrated live
registration service. Local tests inject separately generated loopback trust.

## Reproduce the actual isolated vertical slice

Prerequisites: unprivileged Linux user, PostgreSQL 16 binaries under
`/usr/lib/postgresql/16/bin`, Rust/Cargo, JDK 21, Python 3 and OpenSSL. Android
build additionally needs SDK platform/build-tools 35, NDK 28.2.13676358 and the
Rust `aarch64-linux-android` target. Public Maven downloads are SHA256-pinned by
`clients/android/dependencies.py`; no real account credentials are downloaded.

From the repository root:

```sh
umask 077
python3 clients/android/dependencies.py
cargo test --locked --manifest-path clients/core/Cargo.toml
python3 scripts/check-server.py
python3 scripts/check-pinned-tls.py
python3 scripts/check-registration.py
PARANOID_LEGACY_FIXTURE=1 python3 scripts/check-registration.py
```

The server suite intentionally waits 61 seconds for a real challenge-expiry
negative. The full fixture starts only its own private PG cluster, with TCP
access disabled, and chooses an available loopback IP on port 38443 from
127.0.0.2–127.0.0.4. It never kills an unknown listener or starts a systemd unit.
Only its own subprocesses and temporary synthetic data are cleaned up.
Set `PARANOID_EVIDENCE` to a private log directory if needed; the default in this
worker environment is `/home/codex/paranoid-registration-evidence`.

The fixture executes the actual Android `KeyClient`, `KeyTransport`, `PinnedTls`,
`SnapshotCodec`, `SyncCycle` and JNI vodozemac core on the Linux JVM, not a mocked
server response. It creates two identities, obtains real local CLI grants,
roundtrips real request/grant/contact QR data through ZXing, authenticates and
activates automatically, exchanges Cyrillic E2EE text and authenticated receipts,
restarts both server/JVM, reloads encrypted snapshots and checks duplicate-free
history. The legacy variant starts with populated rootless Olm state, existing
peer pins, ratchets, cursor/history, a pending receipt and exact lost-ack retry
bytes already in PostgreSQL. All old local fields are compared before/after
adding root/auth state; all original server rows are compared through migration.

Both variants dump to a private file, restore to a different fresh database,
compare ordered envelopes/room/grant/mode rows, refuse v0 startup on the restored
schema and resume key-auth sync against it. This is not a restore over live data,
a zero-RPO disaster-recovery promise or evidence of a physical phone installation.

## Build and verify the APK without changing identity

Follow [the Android build instructions](../../clients/android/README.md#build).
Set `ANDROID_SDK_ROOT`, `PARANOID_ANDROID_KEYSTORE` and the signing password via
`PARANOID_ANDROID_KS_PASSWORD` in the build process environment. Do not use shell
tracing or place the password in Git, a URL, an APK asset or an argument to
apksigner. The build passes its environment variable name, not its value.

The worker used the explicitly supplied existing keystore path outside this
worktree, read only by apksigner. Neither the key nor fixture databases/snapshots
are included in the APK. Fresh generated class/dex directories prevent stale
classes from leaking into rebuilds. Only native library, classes and bundled
license notices are inserted into the APK, followed by 16-KiB alignment and
signature/package/version checks.

An independent repeat found ZXing finder heuristics intermittently failing on
pristine generated grant QR images. `QrDiverseSmoke` deterministically reproduces
that failure and now checks 200 distinct public grant encodings during each build.
The adapter attempts ordinary perspective-aware detection first, followed by
ZXing's pure-image decoder on reader failure. Format/error correction, payload
bounds and all typed cryptographic/contact checks remain enforced. This regression
is image-data evidence, not a physical OPPO camera acceptance test.

Output is `clients/android/out/paranoid-text.apk`. The private worker HANDOFF
records the final absolute artifact path, actual SHA256, signer, package/version,
commands, full logs and changed-file list. Packaging success is not OPPO evidence.

## Operator-local admission commands

These commands apply ONLY to a deliberately created disposable private local
cluster in this task. `PARANOID_DATABASE_URL` must identify that Unix-socket
cluster, not a system or hosted database. Private-directory checks reduce
accidents; they do not prove operator-supplied data is disposable. Never copy a
live database URL or credentials to run these examples.

Initialize once, with all old application processes stopped, before starting the
key-capable test server. Set `PARANOID_KEY_REALM` and `PARANOID_KEY_PIN` to the
verified public origin/SPKI of that test server, then run:

```sh
server/target/debug/paranoid-server key-admin-init
```

This explicit transaction preserves the existing `envelopes` and `room_state`,
adds `key_meta` version 1 and the two-slot `key_grants` table, and installs a
BEFORE INSERT guard on the existing singleton room row. Old startup always runs
`INSERT ... ON CONFLICT DO NOTHING`; the guard deliberately refuses even that
statement. Do not remove the guard or run original-schema startup after cutover.
Ordinary key-mode startup checks the schema version and never performs migration.

For a known tester, independently verify the phone's full public credential
fingerprint, the old/public Olm bundle digest, and entitlement to the specific
slot. Merely hashing whatever an anonymous applicant sends is NOT human
verification. The server cannot retrospectively infer root ownership from v0
ciphertext. The explicit operator assertion is the legacy trust boundary.

Save the public request descriptor from that verified phone, then use an explicit
slot, never a first-free-slot selector:

```sh
server/target/debug/paranoid-server key-admin-approve \
  0 VERIFIED_CREDENTIAL_FINGERPRINT VERIFIED_OLD_OLM_DIGEST \
  /private/local/public-request.json /private/local/public-grant.json
```

The CLI checks exact credential/root signature, fingerprint, verified Olm digest,
realm/SPKI and slot. Unique slot/account/device/auth mappings are persisted under
the same room lock used by activation and messages. No third slot or changing
credential ownership is supported. The output is a new public descriptor file,
not a transferable secret; it cannot be redeemed without the matching auth key.
The command refuses an existing output file. Do not overwrite operator evidence.

After the Android build, render a public descriptor on the operator workstation:

```sh
java -cp clients/android/out/host:clients/android/out/deps/json-20240303.jar:clients/android/out/deps/zxing-core-3.5.3.jar \
  PublicQr /private/local/public-grant.json /private/local/public-grant.png
```

This writes a new PNG and roundtrip-checks the QR locally; it is not an approval
operation. Show that public QR to the intended phone. Admission expires after
15 minutes. To explicitly renew only an expired, never-consumed approval while
retaining its exact keys and slot:

```sh
server/target/debug/paranoid-server key-admin-renew \
  0 VERIFIED_CREDENTIAL_FINGERPRINT /private/local/renewed-public-grant.json
```

Renewal invalidates the old grant ID. Import the new descriptor without creating
another identity. Once pending/active, mapping is immutable and not renewed.
Lost commit replies instead use fresh signed status automatically.

To retire an approved/pending grant before activation:

```sh
server/target/debug/paranoid-server key-admin-revoke \
  0 VERIFIED_CREDENTIAL_FINGERPRINT
```

Revocation and activation serialize on the same room lock. If activation wins,
revocation refuses rather than reviving bearer access. A retired pending mapping
is intentionally final in this increment; it preserves keys/history, has no
reset/rebind/recovery procedure and requires separate review before resumption.
There is no public admin route and no automatic recycling of retired slots.

The only new server mode is `PARANOID_MODE=closed-alpha-key-v1`, with direct TLS,
loopback `PARANOID_BIND=<fixture-IP>:38443`, `PARANOID_TLS_CERT/KEY`, private DB
and the retained two v0 fixture tokens in server environment. Those tokens exist
only for unmigrated slots and never enter the new app's network path. Main holds
a database advisory lock for the process lifetime to exclude another key worker.
There is no multi-worker or proxy bypass mode. Public binding is intentionally
refused by this local candidate; future hosted operation requires scoped review.

## Phone workflow and preservation

- Create ID persists root, auth and fresh unassigned Olm state before any request.
  Existing installations add independent keys without calling Olm init again.
  Duplicate create is a no-op; ambiguous storage failure freezes the client.
- A retained Keystore alias without a snapshot, or a snapshot without its key,
  fails closed. A corrupt/unsupported snapshot is never replaced or uninstalled.
- `text-state.enc`, `paranoid-text-state-v0`, package/signature and all old
  ratchet/history/outbox/pin fields remain. The encrypted outer JSON is version 2;
  the existing authenticated AES-GCM storage framing is unchanged. The old saved
  token is retained inside encrypted state for preservation, never displayed or
  used by `KeyClient` authentication. There is no hidden bearer fallback.
- Scan the operator's public grant. The app uses signed status/commit/status,
  durably records the mapping, then signs activation. Lost responses retain keys
  and mapping; reconnect obtains new proof. Pending keys cannot send messages.
- Scan the peer's different contact QR, validate root/device/Olm binding, compare
  the full fingerprint directly and confirm. The original Olm pin cannot change.
  The camera never saves/uploads frames; denied permission/cancel leaves state
  alone. Public-text import is a bounded fallback, not a token input field.
- One check is durable server acceptance; two require a peer-authenticated
  delivered receipt, not reading. Existing quotas, rejection notices, outbox retry
  and non-expiring server history remain. No seed recovery is added.

## Local evidence and residual gates

| Scope | Executed local enforcement | Not established |
| --- | --- | --- |
| REG-01 / REQ-ID-005 | Real JNI creation/reopen/duplicate create; local commit failure and missing-key/snapshot guards | Android Keystore/filesystem lifecycle on OPPO |
| REG-02 / REQ-ID-006 | Exact local approval, wrong Olm/slot/credential rejection, uniqueness, expiry/renewal, pending abort | Actual known-tester human ceremony |
| REG-03 | One winner on concurrent proof reuse; transcript tampering, exact body/path, revoked/expired/old-boot proof denial; real 61-second expiry | Independent crypto/security review |
| REG-04 / REQ-ID-007 | Strict typed QR/root/device/Olm checks, immutable peers, ZXing roundtrips, TLS wrong pin/IP/expiry rejection; signed APK inspection | Camera optics/orientation/accessibility and OPPO runtime |
| REG-05 / REQ-MSG-002/003/004 | Real TLS/PG/JVM JNI E2EE/receipts/restart; populated v0 fields, ciphertext and lost-ack retry preservation | Physical phone migration and real-network reconnect |
| REG-06 | Exact isolated dump/restore, key-only status persistence, v0 startup/downgrade refusal, unchanged deployment gate source | Live migration, deployment-controller integration, host-loss recovery |

Auth bodies are bounded to 8 KiB; message envelopes retain the 24-KiB body cap.
There are at most four live challenges/device and sixteen globally, two challenge
issuances/device/second, eight pre-lookup auth requests/second and twenty total
requests/second, with ten-second handlers. Sixteen concurrent TLS sockets include
handshakes; handshake deadline is eight seconds. These fixed/global budgets are
not resistance to volumetric DoS or fair shared-NAT admission. A public attacker
can still deny availability by exhausting a shared budget. Metadata (stable IDs,
IP, timing, lengths, relationship, operator grants) remains visible to the server.

ZXing core 3.5.3 is Apache-2.0; exact Maven artifact SHA256 is pinned, upstream
HTTPS SHA1 was compared during acquisition, and the tagged upstream license text
is bundled. This is dependency integrity/license evidence, not an OSS security
audit. JVM-only org.json is not bundled into the APK. Public conformance vectors
are independently generated and checked by Rust; no production privacy claims.

`deploy/alpha.py`, `deploy/build.py` and the original `server/schema.sql` are
unchanged. Their same-schema update gate is NOT weakened or a migration path for
this feature. Never switch an existing deployment's mode or apply ad hoc live
SQL from these local examples. A stopped old binary is blocked by the migrated
schema; an already-running old binary must be stopped before migration. After
cutover, rollback must use a reviewed key-capable binary retaining current data.
If none is available, stop and preserve state, never restore a stale dump or
remove the guard to reactivate a bearer. Live rollout and physical OPPO validation
remain separate explicit tasks after independent review; ADR-0006 stays proposed.
