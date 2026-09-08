---
status: draft
owner: operations
last_reviewed: 2026-09-08
---

# Native alpha package: local verification record

Prepared from freshly fetched `origin/main` at
`cd0faca44a5a8d99a8fd9e6ea9ac4875017279d5`, on separate branch
`feat/linux-alpha-deployment`. No main-worktree tracked files, production host,
SSH credential, existing Nginx/database or host ports 80/443 were changed.
Independent parent review is pending; this is implementation evidence, not an
independent review or production architecture acceptance.

## Environment and actual checks

Linux x86_64, unprivileged uid 1003; Python 3.12.3, Rust 1.98.1, PostgreSQL
16.15 (Ubuntu 16.15-0ubuntu0.24.04.1), OpenSSL 3.0.13. The native binary's
`ldd` resolves libc, libm and libgcc locally. Docker API access returned permission
denied; **no Docker test passed or was claimed**. Native systemd user manager was
available, so the test enabled a temporary dedicated unit and exercised real
child processes. Final observed UTC check: 2026-09-08T15:44:22Z.

| Command | Actual result |
| --- | --- |
| `python3 deploy/test_package.py` | `Ran 2 tests ... OK`: private state, no overwrite, valid public TLS descriptor; IPv6 rejected before writes |
| `python3 deploy/test_integration.py` | `Ran 1 test in 43.411s ... OK`: real lifecycle below |
| `python3 scripts/check-server.py` | 13 transport tests and 1 deployment test passed, real isolated PostgreSQL; stopped/removed synthetic cluster |
| `python3 scripts/check-pinned-tls.py` | `Pinned TLS: PASS`: JVM correct pin accepted, wrong key/SAN/expiry rejected before HTTP |
| `cargo fmt --manifest-path server/Cargo.toml -- --check` | Exit 0 |
| `cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings` | Exit 0 |
| `ruff check deploy` | `All checks passed!` |
| `python3 -m compileall -q deploy` | Exit 0 |
| `npx --yes markdownlint-cli2 '**/*.md'` | 0 issues |
| `git diff --check` | Exit 0 |

The integration test built and checksummed the actual release tar, extracted it,
and invoked the packaged installer CLI. It verified enabled systemd state,
private PG readiness and direct Rust TLS using the Android `PinnedTls` JVM adapter
(correct SPKI succeeds, wrong SPKI fails). It exercised missing-key, wrong-port,
CI-override, untrusted-certificate, plaintext and unauthorized-request rejection;
a withheld request body returned 408, and an ingress burst returned 429.

A real message append/retry retained one row. Killing the actual server child
changed the supervisor PID after systemd restarted both children; history remained.
An identified same-binary update fixture, a later append and a rollback retained
both messages. Two planned update/rollback dumps were restored into fresh private
verification databases, compared in full and checksum-checked. An incompatible
schema was refused; a deliberately broken executable caused real start/readiness
failure and automatic return to healthy previous code without history loss.
There is no claim of compatibility with a future unbuilt binary.

TDD failures observed before implementation included: missing TLS-stage rejection,
missing controller/builder/installer, absent 429 ingress limit, and IPv6 accepted
before the explicit bounded rejection was added. Integration also caught rollback
trying to overwrite an already retained release and systemd reporting the linked
fragment path instead of its resolved target; both were corrected and rerun.

## Scope and remaining NOT RUN items

- Production SSH/login, credential decryption, installation, port/firewall change,
  neighboring-service restart: **NOT RUN**, deliberately outside this task.
- Host reboot/linger persistence, target-host ABI/prerequisite check, remote backup
  transfer/host-loss recovery, certificate renewal/rotation: **NOT RUN**.
- Docker/Compose deployment: **NOT RUN**, local daemon permission denied; the
  delivered package is native systemd, not a simulated container package.
- Two physical OPPO phones, mobile network/runtime/Keystore behavior, iOS:
  **NOT RUN**; these tests do not close full RFC-0006 acceptance.
- Publisher signatures, dependency advisory audit, full remote link crawler and
  GitHub CI for this branch: **NOT RUN**. New private owner-approval permalink
  was verified directly through authenticated GitHub API as martadvix-web.
- Independent review: **pending parent review**; no merge or push performed.

REQ-DEPLOY-001 maps to package/health/lifecycle checks; REQ-MSG-004 to unchanged
live history across restart/update/rollback and isolated restores; REQ-SEC-001 to
explicit TLS/admission gates, pinned adapter checks and unchanged client-only Olm
key boundary. V0-14 has local envelope/sequence restore evidence only, not full
phone receipt-state or disaster-recovery acceptance. See the
[runbook](linux-alpha-deployment.md) for operational limits and next rollout checks.
