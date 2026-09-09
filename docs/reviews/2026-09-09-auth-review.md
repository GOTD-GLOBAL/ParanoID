---
status: draft
owner: independent-ai-review
last_reviewed: 2026-09-09
---

# Independent security/code review: phone key registration

**Verdict: REQUEST CHANGES before hosted cutover.** Two reproduced server-side findings: **H1 single-worker ownership survives loss of its PostgreSQL lock**, and **M1 unauthenticated idle keep-alives exhaust all connection slots**. No additional root/device proof forgery, exact-key admission bypass, legacy-slot takeover, active-to-bearer downgrade, or client-state destruction was demonstrated in the reviewed scope. Passing tests are bounded evidence, not a security guarantee.

## Scope and provenance

- Reviewer: independent fresh-context Hermes subagent, model `gpt-6-astra` / `openai-codex`; advisory AI review under ADR-0003, not an independent human cryptographic audit.
- Source, read only: `/home/codex/projects/paranoid-worktrees/phone-key-registration-app`.
- HEAD: `7bef87befd8833ab496469b7104254b4eb1bec92`; branch `feat/phone-key-registration`; **60 modified/untracked files**. Tests used a private copy at `/tmp/auth-review-h2kezjb4`, including privately copied build caches. No reviewed application source was edited.
- Review/testing completed on 2026-09-09; UTC tool timestamp near completion: `2026-09-09T04:34:58Z`.
- Read AGENTS required documents, relevant accepted ADR-0001/0003, requirements, RFC-0010, proposed ADR-0006, protocol, architecture/API maps, threat models and local operations runbook. Loaded project-invariant-preflight and github-code-review skills. No standalone invariant registry: use requirement IDs and REG-01–06.
- The task supplies newer, bounded two-known-phone rollout authorization. Older local-only documentation is not treated as withdrawal of that authorization. RFC/ADR remain proposed/draft, and this review does not accept production architecture. The expected loopback-only key listener is **not** reported as a vulnerability.
- No live-host connections, public endpoint requests, remote writes, real phone credentials, live grants, deployment, signing-key access, or other agents/CLIs. All database mutation and fixture grants were synthetic inside disposable private clusters. The parent's report of empty hosted storage was not used as safety evidence; the migration test was populated.
- Final source check: all **143 captured tracked/untracked file hashes identical**, no added or missing source files; `git diff --check` passed. See `auth-review-hashes-before.json` and `auth-review-hashes-after.json`.
- Focused implementation hashes: `auth-reviewed-files.sha256` (23 files). These and the full snapshot manifest identify exact reviewed bytes; a HEAD hash alone cannot identify an uncommitted feature.
- Read-only APK SHA256 independently matched the supplied installed candidate: `4b05d5e631cd9cc302f4f8e317f6cb0e2ddff7130a3b4162022ba32bf1122528`. No APK rebuild, signing, installation or physical phone verification was performed.

## Severity-ranked findings

### H1 — High operational correctness blocker: lock-session loss does not fence the old worker

**Files/lines:** `server/src/main.rs:115–129` and `167–172`. Contract: `docs/protocol/key-enrollment-v1.md:175–182`; claimed process-lifetime ownership: `docs/operations/key-registration-local.md:181–186`.

**Cause:** startup checks out one SQLx connection, acquires `pg_try_advisory_lock(706172616e6::bigint)`, and keeps the connection object in `_key_guard`. Nothing polls that connection or couples its loss to the listener's lifetime. Holding a Rust connection object is not evidence that its PostgreSQL session and lock still exist. Other pool connections continue serving, and can reconnect after DB restart.

**Actual reproduction against the reviewed binary, private PG and real TLS:**

1. Start first key worker on `127.0.0.20:38443`; a second worker on `.21` initially exits nonzero because of the advisory lock.
2. In the private cluster, select the sole granted advisory-lock backend PID and call `pg_terminate_backend` on it. Confirm zero granted advisory locks.
3. First process remains alive and its database-backed `/v0/messages` GET using a synthetic unmigrated fixture token returns **200**, without any advisory lock.
4. Second worker now starts successfully on `.21`; **both processes simultaneously serve database-backed requests**.
5. Stop/restart that private PostgreSQL instance without restarting the first application. Its ordinary pool reconnects and serves **200**, still with zero advisory locks.

**Impact:** unsupported multi-worker operation becomes possible after an ordinary backend/DB failure, violating the explicit one-worker assumption and multiplying process-local challenge/rate/connection budgets. This is a hosted restart/failure-boundary defect even for two testers. Distinct boot epochs and database room serialization still exist: **no cross-worker replay acceptance, account takeover or signature bypass is claimed**.

**Required correction:** fail closed on loss of ownership, with listener/in-flight work tied to an enforceable lifetime/fencing mechanism. Do not silently reacquire the advisory lock and retain old challenges/epoch. A heartbeat alone has a takeover window; use effective per-operation fencing/serialization, or a properly scoped same-host process lock for this single-host alpha, combined with explicit DB-failure behavior. The implementation choice must satisfy the invariant rather than merely retain a connection variable.

**Acceptance regression:** repeat backend termination and database restart with the application left running; whenever a replacement can acquire ownership, the old worker must no longer serve protected work. Preserve the initial two-worker refusal test. Verify resource budgets cannot be multiplied by the failure path.

**Evidence:** `auth-boundary-repro.py`, successful `auth-boundary-repro-3.log:1–4`.

### M1 — Medium availability blocker for the exposed listener: idle HTTP keep-alives retain all permits

**Files/lines:** `server/src/limited_accept.rs:44–59`, `29–32`; `server/src/main.rs:168–172`. Related limits: `docs/protocol/key-enrollment-v1.md:164–173`.

**Cause:** the semaphore permit is retained for each connection's whole lifetime, but the eight-second timeout covers only TLS acceptance. The server does not disable keep-alive or establish an idle/total connection lifetime policy. Handler deadlines do not cover a completed request sitting idle between requests.

**Actual reproduction:** open 16 TLS connections, finish an unauthenticated `/health` request on each with keep-alive, then leave them idle for **35 seconds**. A seventeenth TLS client is refused; every original connection still successfully handles another request. Closing those held connections restores admission. The final repeat sent no Authorization header at all on `/health`; the fixture token is used only for the separate DB-backed lock-loss checks. This requires no grant or device key and no sustained request-rate flood.

**Impact:** one inexpensive connection holder can deny both phone clients admission while staying below the documented per-second request budget. The test proves survival beyond 35 idle seconds, not an experimentally infinite duration. Source inspection found no explicit idle close in this wrapper. Shared/volumetric DoS remains an acknowledged residual risk, but this specific idle-slot starvation is avoidable and should not be described as fixed merely by counting sockets or timing handshakes.

**Required correction:** for this request-per-connection Android client, disabling HTTP/1 keep-alive is a minimal compatible option. Alternatively enforce a bounded idle/total connection lifetime and confirm permit release. `KeyTransport.java:19–20` already requests `Connection: close`; neither this fix nor H1 needs a new APK, wire protocol or SPKI pin.

**Acceptance regression:** hold 16 completed-request connections without sending more bytes; after the chosen bound they must release permits and a legitimate seventeenth client must complete TLS plus a request. Also test first-header/partial-header and handshake stalls. This does not establish protection against continuous reconnect/volumetric attacks.

**Evidence:** `auth-boundary-repro.py`, `auth-boundary-repro-3.log:5–6`.

The parent acknowledged both reproductions and sent them to the separate rollout implementation worker. **No proposed correction in that other worktree was reviewed here, and neither finding is marked resolved.**

## Auth/client findings: controls traced and independently exercised

- **Primitive and authority separation:** `key-protocol/src/lib.rs:9–16,37–67,77–99,111–125`; `proof.rs:21–41`. Length-prefixed UTF-8/domain-separated transcripts bind root/account/device/auth/realm/pin/Olm and every request context field. Root and auth secrets are generated independently. Canonical unpadded key/signature roundtrips reject alternative padding. Confirmed actual vodozemac 0.10.0 verification calls dalek `verify_strict` (`types/ed25519.rs:391`). Own network regression rejects an otherwise correctly bound proof signed with the account root instead of device auth, a second device's proof against the copied grant, and padded signatures; those failures leave the legitimate proof usable.
- **Exact admission and immutable mapping:** `registration.rs:96–151`, `key-schema.sql:15–24`. Operator must supply explicit slot and exact verified credential/Olm digest; credential root signature and configured realm/pin are checked. Unique slot/account/device/auth/fingerprint/grant constraints cap admission to two mappings. There is no public grant-creation route or first-free-slot allocator. Operator comparison is still a human trust assertion, not cryptographic retroactive proof of legacy ownership. Renewal changes only an expired, unconsumed exact grant; preactivation retirement does not recycle the slot.
- **Proof use and transaction boundaries:** `key_http.rs:164–228,237–318`. Server issues/stores challenges, rechecks durable mode/expiry and exact method/path/query/body under the room transaction, verifies the stored credential's auth key, and removes the challenge once before effects. Invalid proofs do not consume it. Own regression rejects reordered-but-semantically-equivalent cursor query bytes and duplicate intent fields. A forced DB insert failure returns 503, rolls back sequence/usage, leaves the proof consumed, and allows a fresh-proof identical-envelope retry to commit exactly one row. Consuming before failed commit is intentional fail-closed behavior, not lost admission/history.
- **Cutover and history:** `key_http.rs:241–258,303–318`, `key_transport.rs:53–75`, `key-schema.sql:1–8`. Same room lock serializes activation and message work, including v0 mode checks. Active slots reject v0 bearer; another unmigrated slot retains access intentionally. Active revoke is intentionally unsupported, not a recovery defect. Schema guard blocks a stopped old binary's initialization. It does not stop an already-running old binary: offline migration must quiesce it, as documented. Populated legacy migration, ordered dump/restore, retained key-only modes and duplicate-free continued messaging passed independently.
- **Android persistence/status/activation:** `KeyClient.java:49–61,82–110`, core `lib.rs:417–447,484–537`; `TextEngine.java:41–55,94–121`. Candidate state is saved before network use and pending mapping before activation. Lost commit/activation response is resolved with fresh status, not key regeneration; active local state rejects a pending downgrade. Existing realm/pin, Olm identity/ratchets/peer pins/history/outbox and encrypted legacy token are retained, but `KeyClient` has no bearer network fallback. Local commit ambiguity freezes the client. Snapshot/Keystore mismatch fails closed. JVM smoke and populated fixture support these claims; Android AtomicFile/Keystore crash behavior remains a device gate.
- **Contacts:** `contact.rs:35–55,57–71`, core `lib.rs:460–482,503–537,583–588`; `MainActivity.java:69–79`. Public request/grant/contact types are distinct. Raw QR is typed/deserialized in Rust before Android JSONObject can collapse duplicate QR fields. Root credential, device signature, realm/pin, Olm digest, opposite routing alias and existing peer pin are checked before explicit full-fingerprint confirmation. Legacy Olm pairing cannot replace contact verification once root identity exists. Retaining an already verified old Olm pin is intentional, not a newly verified root claim.
- **TLS/resource boundaries:** `PinnedTls.java:47–83`, `KeyTransport.java:12–33`, manifest `:6–8`. Per-connection leaf-SPKI pin, exact SAN, certificate validity/usage/self-signature, adequate key sizes, TLS 1.2/1.3, default hostname checks, no proxy, no redirects and no cleartext fallback. Actual JVM handshakes rejected wrong pin/SAN/expiry. Request/body/challenge/QR/frame caps are explicit and largely bounded; H1/M1 qualify the claimed server lifecycle/resource protection. Camera activity is not exported; images are not persisted/uploaded by the scanner. Physical camera and Android TLS behavior are unverified.

## Requirement/invariant assessment

| IDs / concise invariant | Enforcement examined | Review status |
| --- | --- | --- |
| REQ-ID-001/005, REG-01: no phone/email/manual bearer; locally retain keys before use | KeyClient, TextEngine/StorageGuard, JNI smoke | Preserved in source/JVM; physical phone storage NOT RUN |
| REQ-ID-004/006, REG-02: possession is not admission; exact named slot, two-device cap | CLI checks, SQL uniqueness, grant/mode tests | No authorization bypass found; actual human mapping ceremony out of scope |
| REQ-ID-005/006, REG-03: exact-context one-use proof; reject replay and wrong authority | strict crypto, challenge store, room transaction, native and own adverse tests | Proof checks pass; **single-worker prerequisite violated by H1** |
| REQ-ID-007/SEC-001, REG-04: verified typed peer QR and pinned TLS | contact checks, UI confirmation, QR200, real TLS negatives | Bounded local evidence; no production privacy or physical scan claim |
| REQ-MSG-002/003/004, REG-05: preserve ratchets/history/outbox, no false duplicate delivery | core tests, real populated TLS/JVM/PG migration/restart | Local fixture passes; physical two-phone acceptance NOT RUN |
| REQ-MSG-004/DEPLOY-001, REG-06: preserve post-cutover state, refuse bearer downgrade | schema guard, mode transactions, populated restore | Native preservation passes; **H1 restart boundary blocker**, separate deployment/rollback integration NOT REVIEWED |
| REQ-ID-004/SEC-001: bounded public ingress | global/device budgets, socket permits and deadlines | **M1 availability gap**; volumetric/shared-budget denial remains residual |
| REQ-ID-002/003: do not invent recovery/blockchain capabilities | source/UI/docs scope | Deferred deliberately, not treated as missing alpha implementation |

## Own executed checks and reproducibility

Evidence directory: `/home/codex/paranoid-key-rollout-evidence`. Unless otherwise specified, commands below ran in the **private copy**, not the read-only source.

| Command/check | Real result | Evidence |
| --- | --- | --- |
| `cargo test --locked --offline --manifest-path clients/core/Cargo.toml` | **17 passed**, including public vector, QR parser, state and recovery tests | `auth-core-tests.log` |
| `python3 scripts/check-server.py` | **23 passed**: 9 registration, 13 transport, 1 deployment; includes real 61-second proof expiry | `auth-server-tests.log` |
| `PARANOID_EVIDENCE=/home/codex/paranoid-key-rollout-evidence/auth-fixture PARANOID_LEGACY_FIXTURE=1 python3 scripts/check-registration.py` | **PASS** populated old-client fields, real local TLS/PG/JVM JNI key enrollment/activation, bidirectional Cyrillic E2EE/receipts, server/JVM restart, retained snapshots, exact populated dump/restore and v0 refusal | `auth-registration-tests.log`, `auth-fixture/` |
| `python3 scripts/check-pinned-tls.py` | **PASS** real JVM TLS correct pin, wrong pin/SAN/expiry rejection before HTTP | `auth-jvm-qr-tls.log` |
| Compile current `StorageGuard`, `RegistrationSmoke`, `QrDiverseSmoke`; run Java with private JNI library/classpath | **PASS** continuity/duplicate-create/reopen/local commit failure; **200/200 deterministic grant QR roundtrips** | `auth-jvm-qr-tls.log` |
| `python3 /home/codex/paranoid-key-rollout-evidence/auth-run-independent.py /tmp/auth-review-h2kezjb4` | **1 own added integration test passed**; wrong signing authority/device/padding, nonconsumption on invalid proof, duplicate intent, exact query binding, forced DB rollback/fresh proof retry. Repeated successfully. | `auth-independent-test.rs`, runner, `auth-independent-tests.log`, `auth-independent-tests-repeat.log` |
| `python3 /home/codex/paranoid-key-rollout-evidence/auth-boundary-repro.py` | **Reproduced H1 and M1**, with initial duplicate-worker refusal and socket-close recovery controls | `auth-boundary-repro-3.log` |
| Source SHA256 comparison / `git diff --check` / APK SHA256 | **No source file changes**, diff whitespace check passed; APK digest matches supplied candidate | before/after hash JSON, focused SHA256 manifest |

The independent Rust test is copied only into private `server/tests/independent_auth.rs`; it reuses existing isolated fixture setup but adds its own adverse cases/assertions. It does not modify application implementation. The boundary repro creates its own private PG/TLS fixture, uses `.20/.21` loopback addresses, terminates only its own backend/processes, and cleans its temporary cluster. To use another private review copy, update that repro's `ROOT` path; never point the runner at a live/source deployment.

**Encountered issues:** the initial boundary script used a temporary-directory prefix rejected by the repository's private-database safety gate. It failed before serving; corrected to `paranoid-*` and retained the failed log as `auth-boundary-repro.log`. Successful evidence is the distinct `-3.log` (and prior successful `-2.log`), not the initial failure. Generic write-tool Rust lint assumed edition 2015 and objected to `async`; actual Cargo compilation under the repository manifest and the executed integration test both passed. A transient document read failure was retried against the immutable private copy; final source hashes confirm no underlying change.

## Limits and next gate

- No claim to have fully audited every file in the 60-file diff, all dependencies, the crypto primitives mathematically, side channels, UI accessibility, physical OPPO camera/Keystore/lifecycle/reconnect, or ARM64 runtime. Scope concentrated on named auth/transport/core/client boundaries and relevant tests/contracts. Native state preservation and real JVM TLS do not establish physical phone behavior.
- No separate rollout worktree, hosted migration controller, live DB/TLS configuration, operator credential ceremony, post-cutover rollback bundle or fixes reviewed. No GitHub ruleset/API inspection was performed; workflow/test existence is not asserted to be branch protection.
- Resource/timeout tests are bounded local experiments, not fuzzing/load qualification or volumetric DoS protection. No no-risk inference from an empty live database, or grant secrecy requirement: public grant descriptors confer no auth authority without the device key.
- Preserve the installed APK/wire/pin. Both confirmed findings can be corrected on the server. Re-review the **separate rollout copy's exact fixed hashes** and rerun these adverse cases, then complete migration/backup/deployment and actual two-phone acceptance under the already authorized private test scope. **This report does not clear the rollout while H1/M1 remain unresolved.**
