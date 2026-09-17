---
status: draft
owner: operations
last_reviewed: 2026-09-17
---

# PR35 integration verification

## Authority and boundary

Sergey Maltsev directly requested finishing PR35 and merging it into main on
2026-09-17 (Telegram; original permalink unavailable). This task performs source
integration, local synthetic tests, independent review and PR merge only. It does
not repeat the dated hosted operations, deploy a package, publish an APK or accept
an architecture decision. RFC maintenance reconciliation/recovery and ADR-0008
remain draft. Review mode: `closed-alpha-ai`; human risk owner remains Sergey /
`martadvix-web`. No human audit or expanded sensitive-data scope is claimed.

Requirements preserved:

- REQ-MSG-004: all current message history survives same-data code rollback.
- REQ-DEPLOY-002/003: verified encrypted restore, exact schema and retained
  TLS/config/PG identity; no stale dump over current messages or neighbor changes.
- REQ-SEC-001: explicit metadata/backup limits; no token output or privacy claim.
- ADR-0001/0003: source/docs/test coherence and independent bounded-alpha review;
  merge authorization is not permanent architecture acceptance.

## Changes

Merge integration `4ddfca7` joins PR head `7d9c524` with main `4830134`.
The only conflicts were additive CHANGELOG/current-state sections; all sections
from both branches are retained. Application/server/crypto sources are not
changed by this integration. The PR's optional-table correction remains intact.

The previous CI never invoked the new reconciliation/recovery tests or the real
v2 maintenance suite. `native-package` now runs them, including a freshly built
v2 package via `scripts/check-v2-maintenance.py`. Fixed commands use no PR metadata
interpolation. Existing informational legacy failures remain visible and separate.
No required-check/ruleset configuration is changed; API inspection found no
repository rulesets and main returned `Branch not protected`.

The runner's default baseline is the fresh package, not a historic server. Its
first execution exposed a fixture defect: identical baseline/candidate content
made the supposed rollback a no-op. The fixture now changes a documented synthetic
README marker and recomputes actual member/release hashes; assertions still
require a real pointer change and preservation of rows after switching back.
No runtime code, manifest validation or assertion was weakened. Historical binary
compatibility uses explicit `PARANOID_V2_OLD_RELEASE`, never a fabricated version.

## Actual verification

- CI wiring: new test failed before wiring, then all four tests passed.
- Reconciliation: 15 tests passed, including new semantic config/unit/certificate
  negative cases with a fake read-only coordinator, and existing durable
  before-image/idempotence/interruption tests. No hosted paths were read.
- Restored-baseline validation: 2 tests passed.
- Source v2 maintenance with retained historical v2 baseline: original 14 passed.
- Fresh packaged v2 maintenance: 16 passed, including altered push constraints and
  lost restored push rows rejecting cutover. One signal test covers all four
  SIGINT/SIGTERM × encryption/restore cases, each returning 130 and preserving
  fixture data/identity. The first failing fresh-package run remains a real failure,
  corrected by the distinct-content fixture above.
- Coordinator/message/network/credential suites: 23/6/20/16 passed; TURN/push
  environment suites: 3/4 passed.
- `git diff --check origin/main`: passed (upstream vendored license whitespace is
  unchanged). Markdown CLI2 0.18.1: passed. Unpinned CLI2 0.23.2 reported ten MD060
  errors in two unchanged main files; that is not a PR35 regression or a passed run.
- GitHub CI and final exact-HEAD review are recorded on PR35 before merge.

## Independent review and disposition

Fresh Claude CLI review of `4ddfca7` returned **APPROVE**, no blocking findings.
Actual response model: `claude-opus-5` (CLI also records a small Haiku auxiliary
call). Reviewer did not run tests or inspect the live server. It reviewed the
optional schema/digest flow, one-off helpers, surrounding controller and canon.
Report session: `6743a914-5e14-495d-b738-e7f209ba3386`.

Nonblocking findings addressed in this follow-up:

- CI invocation gap: wired and protected by a RED/GREEN wiring regression.
- Missing semantic drift tests: config/unit/historical certificate negative cases.
- Missing altered-constraint case: real PG regression; additionally lost restored
  token rows must abort cutover and preserve source rows/pointer.
- Fifteen-test ambiguity: dated clarification identifies 14 maintenance + 1 signal
  test; it is not a retrospective new run.
- Proof digest wording: explicitly not an observation transcript or attestation.

The review's absent-table assertion concern is already covered by the exact
six-table manifest assertion in `test_real_encrypted_archive_restore_preserves_all_rows_and_revocation`.
The exact hash-bound helpers remain deliberately operation-specific (fixed UID,
kit and state); they are not generalized here. Root/kit trust remains required.
Full privileged rollback-helper entrypoint fault injection is not added: generic
atomic helper tests and restored-identity tests are not that end-to-end claim.
No root/main invocation or live replay is part of these tests.

## Rollout and rollback

Merging source triggers CI, not deployment. The September13 hosted receipt remains
dated historical evidence, not a fresh status check. Any later deployment needs
its own exact artifact verification and authorization. Operational rollback remains
same-current-data code rollback with verified backup, never stale-dump replacement.
Phone wake/call/reboot acceptance and permanent ADR approval remain separate.
