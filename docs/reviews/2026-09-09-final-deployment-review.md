---
status: draft
owner: independent-ai-review
last_reviewed: 2026-09-09
---

# Final independent pre-deploy review — bounded key-registration rollout

**Verdict: APPROVE this exact artifact for the already-authorized, bounded private two-phone isolated rollout, subject to the live pre-cutover inventory/backup/restore gates below. No unresolved blocking defect found in the reviewed deployment delta. Both original runtime blockers independently retested and resolved for this artifact.** This is not authorization for broad production, a human audit, approval of arbitrary future rollback binaries, or evidence that either real phone is activated.

Completed: 2026-09-09T05:13:09Z. Reviewer: fresh-context Hermes subagent, `gpt-6-astra` / `openai-codex`, same-model independent AI review under ADR-0003; shared-model blind spots remain. No further agents used.

## Exact scope, provenance and freeze

- Read-only source: `/home/codex/projects/paranoid-worktrees/key-registration-rollout`; branch `feat/key-registration-rollout`, HEAD `7bef87befd8833ab496469b7104254b4eb1bec92`, dirty feature worktree. HEAD alone does not identify reviewed bytes.
- Exact tar: `dist/build-ww2f6k5o/paranoid-alpha-618a684d9084e05cc2fc-linux-x86_64.tar`.
- **Tar SHA256 `69254e3886c0486b8be92234b3ff44eb5f3192c8d39da1aa6358bc123581360b`** independently matched the supplied digest.
- Before source review/testing, inspected all seven tar members: regular files, flat `release/` allowlist, no links/traversal. Extracted into private `/tmp/paranoid-final-review-q6wkplth/release`. All six payload hashes matched both the manifest and source-side files, including the source-side release binary. Tests executed this extracted final release binary, not a rebuilt debug substitute.
- `final-reviewed-hashes.json` freezes all **151 source files** and every payload digest. `final-drift-check.json` shows no changed/added source files; repeated final hash check also passed. Source auth handlers/schema (`lib.rs`, `key_http.rs`, `key_transport.rs`, `registration.rs`, `key-schema.sql`) match the original auth-review worktree byte-for-byte.
- No source/Git/live-host changes. Read AGENTS and required introductory documents, relevant accepted ADR-0001/0003, requirements, key protocol, migration RFC/security delta/runbook/authority and original `auth-review.md`/repro/log. Loaded preflight, backup and code-review skills. Inspected delta source and history; did not stash, commit, auto-fix or delegate.

Key frozen hashes:

| Component | SHA256 |
| --- | --- |
| packaged paranoid-server | `1004a3c37286911a45ba41d290f218f8de86e389bd2809635653eb9a7a89aae8` |
| deploy/alpha.py | `fb1d26a82a35f729575e26da0926e17c9e8f4c89b37efc8b0b5fc7b648ccaf8a` |
| server/src/main.rs | `536098ee0023db3f85eb3836c34392219bd32a88e78b62933dff93ad857505d3` |
| server/src/limited_accept.rs | `4fbce8975368c41ef6c0a52afdd3d92133641289d1ed97770400dc1ab457fd65` |
| deploy/build.py | `95d8f7ab8c0aa51b61b286c05eb0afeeade256417909c66f99ecac08f6c8579e` |
| base schema | `28035059271b03fe7f05f012effb16087c326381d23eb1ac5542e2935b1bb23a` |
| additive key schema | `f50a37b3b91bdd7b5d74114be58600cae86293881b12cf88909b36d33cb65ee9` |

## Findings and invariant assessment

### H1 original advisory-lock-loss blocker: RESOLVED within single-host/single-socket scope

`main.rs:193–223` acquires a process-lifetime OS file lock in the canonical private PG socket directory before DB/listener startup. Advisory session ownership remains supplemental. Killing its PG backend or restarting PG no longer permits a replacement while the original worker lives. Independent final-binary regression used actual backend termination, actual PG restart, DB-backed authenticated GETs, duplicate worker launches and SIGKILL/replacement. Original DB GET remained 200 while duplicates exited nonzero; replacement served only after original exit. This satisfies REG-03's one-worker prerequisite without a heartbeat takeover window.

This is explicitly not a distributed lock: retain one private canonical socket namespace, trusted dedicated account, and never unlink worker locks while an owner may live. Root/same-account compromise or alternate separately configured socket namespaces are outside this authorized deployment.

### M1 original TLS keep-alive starvation blocker: RESOLVED

`main.rs:281–286` selects HTTP/1 and disables keep-alive; `limited_accept.rs:49–58,65–110` bounds handshake to eight seconds and post-handshake I/O lifetime to fifteen seconds. Own final-binary test filled all sixteen slots for handshake/no-header/partial-header cases, confirmed saturation actually refused another TLS client, then confirmed expiry closed all held sockets and a new TLS GET returned 200. Sixteen completed unauthenticated keep-alives closed and a seventeenth GET immediately succeeded. This is bounded regression evidence, not continuous-reconnect/volumetric denial resistance or fairness proof.

### Migration, restore, rollback and containment: PRESERVED in tested scope

- **REQ-ID-006 / REG-05–06, REQ-MSG-004 / V0-14:** `alpha.py:470–500` verifies exact base/additive capability, actual database schema against a fresh reference, and fully restored current rows before sticky intent/schema/pointer cutover. Native test uses supplied actual legacy-v0 executable/controller, starts the populated legacy service, migrates and rejects old binary/controller afterward. Unknown actual extra table is refused before intent.
- Own adversarial pre-cutover test corrupts ciphertext in the actual restored verification DB after `pg_restore`. Migration raises `restore differs`; original config/TLS/pointer/schema/ciphertext remain unchanged. This tests equality gating, not merely dump-file creation.
- Native exception tests cover failure before backup success, after durable sticky intent, and after schema commit but before pointer selection; same reviewed migration resumes without deleting data. These are exception/crash-boundary simulations, not power-cut experiments. Incomplete stage/config.pending/next or stale postmaster state fails stopped for inspection.
- Sticky configuration adds only `deployment: key-v1`; original IP/token **values** are exact. Config JSON bytes necessarily change for this extension; TLS key/certificate bytes remain exact. Backup records exact private identity-copy hashes.
- **Post-cutover rollback:** code pointers change, current database is never replaced with a stale dump. Real packaged systemd/PG16/TLS/JNI E2EE test activates two synthetic keys, exchanges messages, adds post-update messages, rolls back compatible content, restarts JVM, verifies exactly three displayed messages and active state, compares all four tables after restore, then syncs real JNI clients against the restored DB. Both legacy bearers return 401.
- Own real-systemd double-failure test injects readiness failure only *after actual TLS/PG readiness*, writes a new ciphertext row after candidate startup, then also fails compatible rollback readiness. Final `ActiveState=inactive`; both exact pre/post-update rows, room counters and active modes survive. Explicit compatible restart succeeds; both bearers remain 401. This supplements the implementation's mocked service-stop unit test.
- **REQ-DEPLOY-001 / REQ-SEC-001:** key-mode operator health uses private SQL plus verified IP TLS `/health`, not client keys or bearer message authority. It succeeds with both slots active. It is readiness, not end-to-end phone health; retained tokens still exist in config for migration continuity.
- Capability/schema checks reject changed key SQL, old executable even with relabelled key manifest, old controller, unsupported capability version, unknown config shape/version, concurrent operator, redirected/nonregular/multilink components and unsafe installation paths. Build regressions cover stale secrets excluded and symlink component rejected before publication. Capabilities/checksums are not publisher signatures: only execute trusted reviewed artifacts.

## Own real execution results

All paths below are under `/home/codex/paranoid-key-rollout-evidence/`. Implementation-worker logs were context, not substituted for these executions.

| Own command / test | Actual result | Evidence |
| --- | --- | --- |
| In private `deploy/`: `PYTHONDONTWRITEBYTECODE=1 PARANOID_KEY_RELEASE=/tmp/paranoid-final-review-q6wkplth/release PARANOID_V0_BINARY=…/implementation/legacy-v0-server PARANOID_V0_CONTROLLER=…/implementation/legacy-v0-controller.py python3 -m unittest -v test_containment test_package test_migration test_migration_native test_migration_runtime` | `Ran 31 tests in 36.595s` / `OK`, exit 0 | `final-native-tests.log` |
| Same release: `python3 deploy/test_migration_e2ee.py` with `PYTHONDONTWRITEBYTECODE=1` | `Ran 1 test in 37.874s` / `OK`, exit 0; actual packaged systemd/PG/TLS/JNI | `final-e2ee-tests.log` |
| In private deploy: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_build` | `Ran 2 tests in 0.007s` / `OK` (cargo/toolchain mocked only for packaging negatives) | `final-build-gates.log` |
| `PYTHONDONTWRITEBYTECODE=1 python3 …/final-boundary-regression.py` | All eight own H1/M1 assertions below passed, exit 0 | script + `final-boundary-regression.log` |
| `PYTHONDONTWRITEBYTECODE=1 python3 …/final-recovery-regression.py` | All three own restore/doublefailure/restart assertions below passed, exit 0 | script + `final-recovery-regression.log` |

Exact own runtime output:

```text
PASS H1: duplicate refused before lock loss
PASS H1: duplicate refused after advisory backend termination; original DB GET=200
PASS H1: duplicate refused after PG restart; original DB GET=200
PASS H1: SIGKILL releases lifetime lock; replacement GET=200
PASS M1: 16 completed unauthenticated keep-alives closed; seventeenth GET=200
PASS M1: handshake: 16 saturated slots closed by 9s; new TLS GET=200
PASS M1: no-header: 16 saturated slots closed by 16s; new TLS GET=200
PASS M1: partial-header: 16 saturated slots closed by 16s; new TLS GET=200
PASS: actual pre-cutover restored ciphertext corruption blocks migration; original config/TLS/pointer/schema/row unchanged
PASS: real systemd candidate and rollback both started; injected double readiness failure leaves ActiveState=inactive; both pre/post-update exact ciphertext rows and active modes retained
PASS: explicit compatible restart private health succeeds; both bearers=401; TLS exact bytes and all original config values preserved
```

Legacy fixtures used (provided implementation baseline builds, not independently rebuilt here): binary SHA256 `9de84ce5b72c971d2826aa6dcec19d9c88b690608daf5d8c706318dcab235441`; controller `41a6ed28dcaaa4aa265d73c9f6b301b2ff4a3e5a4d19d783ba5c7e4bf5759d18`.

## Remaining live gates, constraints and NOT RUN

1. Parent must freshly verify scoped live state and transferred exact tar digest, quiesce only the dedicated unit, and complete current-live-data restricted backup/isolated restore equality **before** sticky cutover. Local fixture success is not proof the live backup exists or is restorable. Empty hosted storage does not waive these gates.
2. Preserve exact configured IP/port/TLS identity and existing config values. Use reviewed offline `migrate-key`, never install/init over retained data. Start only on success. On failure retain stopped state; never remove sticky/schema protection or use bearer-only rollback/stale restore. First migration has no safe v0 code fallback; if no reviewed working key-capable fallback exists, remaining stopped is the recovery policy.
3. Approve only the two user-labelled public credentials under the separate authorized mapping ceremony. No real phone credentials were opened, copied or used here; no grants issued for them. Physical OPPO/Keystore/camera/lifecycle and phone-to-phone acceptance **NOT RUN**; no new APK needed or built.
4. No live host access, live backup, host migration, neighboring-service/firewall changes, reboot/power-loss/storage-loss experiment, transfer encryption, full cryptographic audit, fresh full auth suite, clean reproducible Rust rebuild or GitHub branch-protection inspection. Binary provenance checked against archive manifest/source-side build output, not compiler reproducibility. JNI/classes/public dependencies copied privately from existing local build outputs; used for real compatibility execution, not independent client rebuild.
5. Rollback fixtures intentionally use the same final binary with separately identified compatible content. Tests establish lifecycle/data retention, not semantic compatibility of arbitrary future code. Linux same-host lock, trusted publisher/account, private PG16 socket, retained verification DB disk usage and global ingress budgets remain documented constraints. No production privacy claim or new architecture acceptance; ADR-0006 remains proposed.

All fixture processes stopped; own temporary user units disabled; final process check found no scoped fixture processes remaining. Private review source/extracted artifact retained for reproducibility. One helper read returned a tool `KeyError` while preparing an adapted repro; replaced it with the independent script above. Initial JNI filename assumption was corrected through file discovery before tests. No application test failures or source drift encountered. No review skill/procedure or other profile changed.
