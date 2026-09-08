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

## Independent-review remediation: 2026-09-08

This bounded local follow-up started at `9985d33cb7e1d3af0ec1969b6a78fdd65d13dd77`
on the same deployment branch. The independent review reproduced two P2 blockers:
stale ignored files entering rebuilds, and releases/backups redirected outside an
installation. This implementer fixed those findings, not a remote auth bypass,
and does not label self-verification as independent approval. Parent re-review
is still required before publishing. The earlier table is historical evidence;
its original 43.411s duration is not the duration of this follow-up run.

Observed RED before fixes: the builder tar included synthetic `config.json` and
`tls/key`; symlink components were accepted; stage accepted redirected persistent
directories; initialization followed a symlink ancestor; invalid config and
release IDs/members were accepted; redirected locks were acquired; update reached
systemctl before rejecting unsafe state; CLI stage/run created locks before
validating input; initialization overwrote a preexisting synthetic config.
Each affected behavior was fixed and its negative test rerun GREEN. Additional
regressions cover public/non-directory persistent paths, simulated owner mismatch,
hard-linked/FIFO locks, unconfined/missing/tampered current and preexisting next.

The final-source verification commands below actually ran locally (Python package
commands used `PYTHONDONTWRITEBYTECODE=1`). Builder tests mock only Cargo/Git/version
subprocesses inside synthetic filesystem fixtures; native lifecycle tests use
real builds, PostgreSQL, TLS, dumps/restores and server processes, not mocks.

| Command | Actual follow-up result |
| --- | --- |
| `python3 deploy/test_build.py` | Exit 0; 2 tests, stale files preserved/excluded and symlink component rejected |
| `python3 deploy/test_containment.py` | Exit 0; 15 tests, including negative subcases and pre-side-effect checks |
| `python3 deploy/test_package.py` | Exit 0; 2 tests, real PG16 initialization/TLS and overwrite/IPv6 refusal |
| `python3 deploy/test_integration.py` | Exit 0; 1 test in 44.796s, actual systemd enable, child-kill restart, automatic failed-executable update recovery, retained history and real restores |
| `python3 deploy/test_native.py` | Exit 0; 1 test in 4.244s, fresh real archive, private PG16, TLS/auth/idempotent retry/live lock, same-binary update/code rollback, two restores/full-row comparisons, unchanged config/TLS; no systemd |
| `python3 scripts/check-server.py` | Exit 0; 13 transport and 1 deployment test; private cluster stopped/removed |
| `python3 scripts/check-pinned-tls.py` | Exit 0; real JVM pin/key/SAN/expiry handshakes PASS |
| `cargo test --locked --manifest-path clients/core/Cargo.toml` | Exit 0; 3 state and 6 recovery tests |
| `cargo build --locked --manifest-path clients/core/Cargo.toml` plus CI's `javac --release 8` and CoreSmoke/StorageSmoke/SyncSmoke commands | Exit 0; JNI/codec/real HTTP409/507 sync PASS; JDK emitted 3 obsolete Java 8 option warnings |
| `cargo fmt --manifest-path server/Cargo.toml -- --check` | Exit 0 |
| `cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings` | Exit 0 |
| `ruff check deploy` | Exit 0, All checks passed, after correcting initial new style findings |
| Python `ast.parse` of every `deploy/*.py` | Exit 0; syntax PASS, without bytecode side effects |
| `npx --yes markdownlint-cli2 '**/*.md'` | Exit 0; 0 issues |
| `git diff --check` | Exit 0 |

One immediate native run following the systemd test failed its port-availability
preflight with EADDRINUSE (exit 1) before creating an installation or children.
Subsequent socket checks showed no listener and the temporary unit was not-found /
inactive; the explicit rerun above passed. No unrelated listener was killed.
Do not run the two lifecycle harnesses concurrently or while 38443 is unavailable.
Raw local transcripts: `/tmp/paranoid-systemd-final-source.log`,
`/tmp/paranoid-native-final-source.log` (failed preflight),
`/tmp/paranoid-native-final-source-retry.log`, `/tmp/paranoid-server-green.log`.
These paths are local handoff evidence, not published build dependencies.

The CI workflow now installs native PG16/OpenSSL prerequisites and runs package,
containment and non-systemd lifecycle tests with Rust 1.98.1. Hosted execution,
GitHub rulesets/required-check configuration and approval lookup were **NOT RUN**
in this local-only follow-up. The parent must inspect those separately; adding a
workflow does not prove it is a required branch check. Full external link crawling,
Docker, reboot/linger, target ABI, production SSH/keys/deploy, firewall/neighbor
changes, backup transfer/host-loss recovery, phone/iOS acceptance and independent
re-review were also **NOT RUN**. No E2EE, retention, schema or accepted ADR changed.

Final transfer output is rebuilt after the local commit into fresh private
`dist/build-<random>/`, checked for exactly six regular members, component/source
hash equality, tar checksum and clean-commit provenance, then exercised using
`PARANOID_ALPHA_ARTIFACT` with `test_native.py`. The exact final commit, artifact
path, checksum and post-commit result are supplied in the remediation handoff,
not embedded circularly into the artifact's source-commit metadata.

## Subsequent authorized target attempt

The [2026-09-08 rollout record](linux-alpha-rollout-2026-09-08.md) separately records
completed package review/CI, exact merged-source provenance, target checks and
actual host-local installation/health. The first firewall-blocked attempt stopped
its unit/linger while retaining state. The subsequent explicitly authorized IPv4
resume passed external pinned TLS/negative-auth checks, actual JVM adapter checks,
and final-unit restart/crash recovery with unchanged identities and database rows.
A fresh disposable native fixture passed in 2.342s. Earlier local-only NOT RUN
statements below are historical, not current deployment status. Physical-phone
acceptance and host reboot remain unrun.

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
