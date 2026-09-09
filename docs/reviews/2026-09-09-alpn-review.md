---
status: draft
owner: independent-ai-review
last_reviewed: 2026-09-09
---

# Independent focused ALPN review

**Verdict: PASS — approve the exact ALPN-corrected artifact for the already-authorized bounded isolated same-schema update. No blocking security concern or logic error found.** This supplements, rather than replaces, `final-deployment-review.md`. It does not establish live deployment success, phone activation, or physical two-phone acceptance.

## Scope and identity

- Read-only source: `/home/codex/projects/paranoid-worktrees/key-registration-rollout`; branch `feat/key-registration-rollout`, HEAD `7bef87befd8833ab496469b7104254b4eb1bec92`, dirty feature worktree.
- New archive: `dist/build-qqljw60f/paranoid-alpha-007fd1812c0dbba9a489-linux-x86_64.tar`.
- Independently calculated **SHA256 `36bbd35237a34d314cefd130e562a84dd6803f2cf240d464dfccd1c4cd090df4`**, matching the requested identity.
- Old reviewed archive: `dist/build-ww2f6k5o/paranoid-alpha-618a684d9084e05cc2fc-linux-x86_64.tar`; independently rechecked SHA256 `69254e3886c0486b8be92234b3ff44eb5f3192c8d39da1aa6358bc123581360b`.
- New extracted release: `/tmp/paranoid-alpn-review-63w_k5p8/release`. All seven members were regular files under the flat `release/` directory, with no links or traversal. All six payload digests matched the manifest and corresponding source-side files, including `server/target/release/paranoid-server`.
- Independent reviewer: fresh-context Hermes subagent; no further agent delegation. Read AGENTS, previous approval/freeze, deployment security delta and bounded authority; loaded project-invariant-preflight and requesting-code-review skills. No source edits, Git mutations, live host access, grants, identity changes, or service deployment performed.

## Exact comparison to the approved baseline

Only **`paranoid-server` and `manifest.json` differ in the tar payloads**. Manifest changes are limited to release ID and the binary entry in its checksum map. Controller, both schemas, TLS generator, packaged README, architecture, dependency/runtime metadata and schema contract remain unchanged.

| Payload | New SHA256 | Baseline comparison |
| --- | --- | --- |
| paranoid-server | `35104d352a778decdf83f2119c5bff37e147329ae4f07ec3235e30f55d81fd53` | Changed from `1004a3c37286911a45ba41d290f218f8de86e389bd2809635653eb9a7a89aae8` |
| alpha.py | `fb1d26a82a35f729575e26da0926e17c9e8f4c89b37efc8b0b5fc7b648ccaf8a` | Identical |
| schema.sql | `28035059271b03fe7f05f012effb16087c326381d23eb1ac5542e2935b1bb23a` | Identical |
| key-schema.sql | `f50a37b3b91bdd7b5d74114be58600cae86293881b12cf88909b36d33cb65ee9` | Identical |
| create-test-tls.py | `243ee07823de18c800ff6f9ea18bbcd54bd38dc985b464a14825916ff2b6a69d` | Identical |
| README.md | `a72150ae3d6b05cc5ab8aff32ee321a78fe0104230794f378555f4b34a0787ea` | Identical |

Compared every frozen source entry in `final-reviewed-hashes.json` with current bytes, then inspected actual changed-file diffs against its retained private source snapshot. Executable source changes are only `server/src/main.rs` and the added ALPN path in `deploy/test_migration_runtime.py`. Frozen Android/core/key-protocol/auth-handler/schema/controller/dependency-lock files remain identical. Four additional documentation files changed: CHANGELOG, operations index, RFC index, and threat-model index; these only describe/link the earlier deployment work and do not alter the reviewed runtime contract. This review does not claim the entire source tree is byte-identical outside the ALPN fix.

## Code and TLS semantics

`server/src/main.rs:153–164` changes only successful TLS setup in key mode. It clones the inner Rustls `ServerConfig`, replaces `alpn_protocols` with exactly `http/1.1`, then wraps that configuration. Non-key mode returns the original configuration unchanged. TLS-loading errors still fail closed. The change now agrees with the existing `.http1_only()` and disabled keep-alive at lines 293–298.

Dependency sources were not present in the usual local Cargo registry. Downloaded exact axum-server 0.8.0 and rustls 0.23.44 crate archives from static.crates.io into the private review directory and verified each archive against its unchanged Cargo.lock checksum before inspection:

- axum-server `src/tls_rustls/mod.rs:190–193`: `from_config` only places the supplied `Arc<ServerConfig>` into ArcSwap; it does not reset ALPN or rebuild TLS policy.
- Lines 233–235: `get_inner()` returns `load_full()`, the underlying `Arc<ServerConfig>`.
- Lines 311–318: normal certificate configuration defaults to `[h2, http/1.1]`, explaining the original mismatch.
- rustls `src/server/server_conn.rs:296–345`: `ServerConfig` uses derived Clone; crypto provider, certificate/key resolver, session/ticket state, protocol versions and client-certificate verifier are preserved. Remaining configuration fields likewise clone. Only ALPN is reassigned by this patch.

No dangerous certificate verifier, insecure client context, TLS/plaintext fallback, key/cert rotation, auth bypass, or schema/controller modification is introduced. The native test trusts the fixture certificate with `ssl.create_default_context(cafile=...)` and verifies the IP hostname; certificate validation is not disabled. Selecting supported HTTP/1 is not a cryptographic downgrade.

Relevant prior invariants remain preserved: REG-03 single-worker ownership, REG-06 bounded TLS occupancy, REQ-SEC-001 verified TLS, and REQ-ID-006 / REQ-MSG-004 retained identity/history. The latter retention guarantees are carried forward through unchanged controller/schema and prior full review, not newly claimed from an ALPN health test.

## Own native execution — actual extracted binaries

Tests run from a private copy of deploy tests, with `PYTHONDONTWRITEBYTECODE=1`. The fixture starts actual local PostgreSQL and the supplied release executable, uses verified TLS on loopback, and cleans up children. No live deployment accessed.

**Independent GREEN:**

```sh
PARANOID_KEY_RELEASE=/tmp/paranoid-alpn-review-63w_k5p8/release \
  python3 -m unittest -v test_migration_runtime
```

Actual output, saved in `alpn-review-native.log`:

```text
test_alpn_offer_h2_and_http1_selects_supported_http1 ... ok
test_binary_declares_bounded_deployment_capability_without_environment ... ok
test_completed_requests_release_tls_slots ... ok
test_idle_completed_handshake_has_absolute_lifetime ... ok
test_single_worker_survives_database_lock_loss_and_restart ... ok

Ran 5 tests in 22.990s

OK
```

Exit 0. The ALPN test offers `[h2, http/1.1]`, asserts selected protocol `http/1.1`, receives HTTP status 200 from `/health`, reads the response and asserts connection closure. Other tests exercise no-ALPN clients, idle lifetime, capability/schema declaration, and worker ownership across PG lock loss/restart.

**Independent RED control:** ran the identical new ALPN test against the retained old reviewed extracted release `/tmp/paranoid-final-review-q6wkplth/release`:

```text
AssertionError: 'h2' != 'http/1.1'
 : HTTP/1-only server must never negotiate h2

Ran 1 test in 1.580s

FAILED (failures=1)
```

Exit 1, expected; full output in `alpn-review-red.log`. Thus this review does not rely on the implementer's red/green logs.

## Issues, limits and handoff

- Initial private test-copy setup omitted the relative TLS generator, producing four setup errors before server execution. Copied the identical packaged generator into the expected private `scripts/` path, without editing source or tests; all five tests then passed. One search wrapper decoding error and one overbroad filesystem-discovery command rejected by the tool guard were worked around using narrower calls. These were review-environment issues, not application defects.
- A post-GREEN process check found no matching fixture processes; the subsequent RED test also executes the same finally cleanup.
- No fresh reproducible compiler build, full auth re-review, packaged JNI run, live update, or phone test performed here. Binary provenance is archive/manifest/source-build-output equality, not compiler reproducibility. Parent separately owns packaged JNI testing and live acceptance.
- Existing backup/restore, exact identity/TLS/config preservation, current-history retention and same-schema rollback constraints remain mandatory. This is an approval of this exact bounded code update, not permission to rerun installation/migration over retained data or rotate any identity.

Created report, `alpn-review-artifacts.json` (full archive payload comparisons), `alpn-review-native.log`, `alpn-review-red.log`, and private extracted fixture/dependency copies. No blocking concerns; no additional scope expansion requested.
