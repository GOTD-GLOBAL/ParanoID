---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Clean first-contact: local test and APK candidate record

## Objective and authority

[REQ-MSG-005](../product/requirements.md#first-contact-incoming-correction-2026-09-09),
[RFC-0014](../rfcs/0014-first-contact-incoming.md) and proposed
[ADR-0009](../decisions/0009-clean-first-contact.md) record the exact owner
Telegram amendment on 2026-09-09. Fresh installs, automatic root-proof registration,
zero-contact plaintext/reply and real delivery receipts are the candidate scope.
Historical test-message migration/preservation/recovery is outside this gate;
existing tests/results remain present and are accounted separately.

Local implementation, genuine TDD, generated pinned-TLS/isolated PostgreSQL/JVM/JNI
fixtures and retained-signer APK build are authorized. No phone/live database
wipe, SSH, deploy, upload or publication occurs. The owner uninstalls his own
applications. Unsupported existing snapshots must fail without changing bytes;
there is no app reset command or automatic migration in this candidate.

## Reproduce and separate acceptance accounting

From the Android worktree, use the retained local toolchain/dependency cache:

```sh
cargo test --offline --locked --manifest-path clients/core/Cargo.toml \
  --lib --test clean_first_contact
cargo test --offline --locked --manifest-path clients/core/Cargo.toml \
  --test key_vectors --test registration --test state --test sync_recovery \
  --test self_service --no-fail-fast
cargo fmt --manifest-path clients/core/Cargo.toml -- --check
cargo clippy --offline --locked --manifest-path clients/core/Cargo.toml \
  --all-targets -- -D warnings
python3 clients/android/test_ui_contract.py
python3 clients/android/test_clean_self_service.py \
  --server-binary /home/codex/paranoid-self-service-evidence/server-build-zeu65f67/release/paranoid-server \
  --evidence-dir /path/to/new/private/fixture-evidence
python3 clients/android/test_self_service.py --server-root /path/to/server-checkout
```

The clean Rust command and `test_clean_self_service.py` are current acceptance.
The original `test_self_service.py` is a separate historical fixture, with its
real result recorded even when incompatible old assumptions fail.
The clean acceptance command is explicit, not a claim that a failing all-tests
command passed. Historical source/tests stay present and their actual exits are
recorded independently. The final fixture invocation/options, TDD commands,
outputs and any failures are preserved in the unique evidence README below.
Do not reconstruct success counts from planned assertions: only reached passing
assertions in actual logs establish the result.

The Android fixture uses real `SelfServiceClient`, Java JNI and Rust/vodozemac,
not mock responses, with a generated local pinned certificate and a private
Unix-socket-only PostgreSQL cluster. Synthetic users register without an operator.
Only the sender initially knows the genuine recipient QR; the receiver begins
with zero contacts and must show real plaintext, reply and authenticated receipts.
Persisted reopen/restart, exact immutable retries and duplicate behavior remain
acceptance assertions. The retained exact live server binary is tested ONLY in
this isolated local fixture. Retained release `346f059914a290be4851` binary SHA256
is `3418332f112b2ce4ac699e9b5fb26222619b48dca7405fffdf69af237cf0c211`;
its source bundle SHA256 is
`5901728d6a09947ffe906163c0d91ae3d14670eca69e051120d3d4c603b03827`.
These identities are verified from retained local evidence, not a new remote
health/auth/message check.

## Observed local acceptance results

The initial clean fixture failed against the old JNI on frame0 rather than
mandatory frame2 (`android-clean-fixture-behavior-red.log`). The integrated
fixture then passed, and the final exact-source rerun
`android-clean-fixture-final.log` exited **0**. `fixture-final/clean-fixture-result.json`
records:

- five fresh automatically registered accounts and zero operator grants;
- receiver starts with zero contacts, gets immediate plaintext and unverified
  reply, and exchanges genuine channel-bound delivery receipts;
- durable frame2 text/receipt bytes equal actual PostgreSQL rows; an accepted
  server write with a lost client response retries the exact same bytes/ID;
- injected incoming text/receipt save failure freezes the process, preserves the
  prior encrypted disk snapshot, allocates no peer and sends no receipt;
- exact same-key verification, block/unblock with unrelated peer progress,
  new/new simultaneous crossing and encrypted snapshot/server/JVM restart pass.

The final-fixture JNI SHA256 is
`10394fb870e8c745c7df34e9036bba5574c2b2a71bcb820c83db8c87e91e6ad4`.
The before/after source comparison reports `changed: []` and test exit0. This
identifies the final Linux JNI integration run; the ARM64 APK native payload has
its own build hash in the external artifact record. Earlier attempt2 used JNI
`3ded3045a65d110fd6b77019c2418a2a61d1dda6ab847fb1543354b122764ef6`
and remains a separately identified passing run, not the final fixture library.

`android-clean-schema-green.log` and `android-snapshot-boundary-green.log` exit0
for actual JNI durable wrapper4/core3 creation/reopen, unknown old wrapper/native
refusal without writes, populated native0 refusal and same-ID continuation from
pristine interrupted creation. The initial boundary negative failed first.

The final clean Rust matrix in `core-clean-final.log` is **15 passed / 0 failed /
0 ignored, exit0** (51.66 seconds). It covers genuine text/reply/receipts, independent
channel derivation/crossing, strict nested receipt-body parsing, valid-signature
wrong inner context, corrupt Olm, wrong signature/wrapper stripping, changed
same-root fallback, replay/reload/sequence/bytes conflicts, unknown and mismatched
receipt targets, 16/64 peer/block budgets, 8 sessions, 1000 accepted events,
history/outbox exhaustion and 8 MiB post-decryption snapshot rollback. A further
stripped-new-frame versus unchanged historical-v0-decoder check passes separately
in `core-strip-historical.log`. Final additional boundary tests and the complete
build suite count/result are recorded in the external evidence README.
Earlier genuine RED→GREEN logs remain alongside those results. An older slow
matrix was explicitly interrupted after replacement by the successful optimized
matrix; its nonzero exit is preserved and is not passing evidence. Clippy and
formatting results are recorded by the final evidence run.

Historical accounting is separate and honest:

| Unchanged historical check | Actual result |
| --- | --- |
| Frozen initial core suite | 39 passed / 2 failed / 0 ignored, exit101 |
| Final historical core suite, clean suite explicitly excluded | 27 passed / 14 failed / 0 ignored, exit101 (`historical-final-core-result.json`) |
| Old `SelfServiceSmoke` expecting native schema2 | exit1, assertion that old v2 migration should occur |
| Old `SelfServiceMigrationSmoke` expecting wrapper3 migration | exit1, explicit unsupported snapshot refusal |
| Original reciprocal-contact real TLS/PostgreSQL/JVM/JNI fixture | exit0, three registrations/two dialogs/text/receipts/restart |

No historical tests were deleted, skipped or converted to expected failures.
The clean schema deliberately refuses old-state migration and historical v2
operations; the existing asymmetric retained-context/recovery defect is not
claimed fixed. Those nonzero exits are outside the owner's clean-install build
gate and never represented as an all-tests pass. Actual final build/check commands
and outcomes remain in the unique evidence README.

## APK and stable source identity

Candidate identity: package `org.paranoid.devtext`, versionCode **7**,
versionName **0.0.7-clean-first-contact**, ARM64/API26+. Build input and finished
APK must be retained in a unique stable evidence directory, independent of the
mutable Android `out/` path. The actual APK SHA256, signer/version verification
output and full-source snapshot hashes belong in the final record, never invented.

Use [the retained-signing build instructions](../../clients/android/README.md).
The existing keystore must yield certificate SHA256
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
No new key is generated or copied. Read secrets only from the retained signing
setup and pass password by environment variable name, never print them, enable
shell tracing, or put secret values in CLI arguments/recorded commands. Run actual
`sha256sum`, `apksigner verify --print-certs` and `aapt dump badging` on the final
stable APK, comparing packaged native bytes with the captured ARM64 build.

Unique evidence directory for this execution:
`/home/codex/paranoid-self-service-evidence/clean-first-contact-05_er157/`.
Its README is the actual outcome record with initial/final source hashes, source
delta, complete build input snapshot, test/build logs and stable artifact identity.
Runtime results above are observed, with exact run identities. The final build
record is maintained externally so source snapshot hashes do not depend on an
APK hash embedded in its own inputs. Older artifact hashes in the historical
Android document identify older builds only; consult the unique evidence README
for the final candidate path and actual verification, never a reused out/ filename.

## Review, rollout, rollback and remaining limits

The next gate after local tested build is independent code review by the parent,
recording exact source/artifact identity, findings and resolutions. Building is
authorized before that review; publishing/delivering the APK is not. Permanent
ADR approval provenance remains outstanding and ADR-0009 stays proposed.

No server v2 schema/API change or live rollout is part of this candidate. The
same immutable opaque transport is exercised locally. Unsupported old client
snapshots are preserved and refused; rollback is not a stale snapshot restore,
old-decoder install or silent reset. A future separately authorized update must
respect saved identity/trust/state compatibility and current data.

Real Android Keystore, camera, installation, UI rendering, background behavior
and two-OPPO messaging remain NOT RUN. Finite budgets, one device/account,
foreground sync, fallback-prekey initial-secrecy limits, transferable signatures,
relay metadata, spam availability and absent recovery remain explicit. Local
fixtures/APK verification do not establish production security or physical-phone
acceptance, and do not close issue #16's eventual phone acceptance by themselves.
