---
status: draft
owner: maintainers
last_reviewed: 2026-09-09
---

# Archival PR18 CI harness correction

This is CI-only work on the **draft, DO NOT MERGE**
[PR18](https://github.com/GOTD-GLOBAL/ParanoID/pull/18), related to
[issue16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16). It changes no delivered
runtime, cryptography, authentication, schema, Rust test assertion or Android
source. The reviewed source/artifact checkpoint remains commit
`a78dbccb1f45667749de0d4720fee96c28ee1916`; a subsequent CI commit does not imply a
rebuild, new source review, deployment, merge or phone action.

## Actual original failures

[Run34406605403](https://github.com/GOTD-GLOBAL/ParanoID/actions/runs/34406605403)
failed `postgres-http` and `client-core-and-tls`; native-package and Markdown
passed. These failed logs remain historical evidence.

- All14 realtime tests failed in `database()` at offline initialization, before
  exercising realtime assertions. CI supplied a TCP database URL and the v0
  `PARANOID_CI_TEST_DATABASE=1` bypass. `self_service::init_cli` deliberately
  requires a private Unix socket and calls `development_database_allowed` with
  `false`, regardless of that environment variable. The failure is therefore the
  preserved local-database security guard, not a new runtime regression.
- Independently, realtime and self-service fixtures replace `/postgres?` with
  their new database name. The old CI `/paranoid_test` URL does not contain that
  substring and would leave those tests on the shared database even if the
  security guard were weakened. Do not weaken it.
- Client clean first-contact17, realtime signer4, vectors1 and registration7
  passed before the mixed historical `self_service` target reported14 failures.
  This is the documented unsupported pre-v7 schema/old-intro baseline, not a
  reason to change delivered code or old test expectations.

## Wiring and preserved gates

The PostgreSQL job now installs PostgreSQL16 and invokes the existing
`scripts/check-server.py`: a fresh disposable cluster, private0700 socket,
TCP disabled, per-test databases and no CI TCP bypass. **All existing server
Cargo targets** still gate, including full realtime and self-service security
suites. The job allowance is30minutes for cold compilation plus actual
five-minute expiry/TLS lifetime tests; test deadlines/assertions are unchanged.

Client integration targets are discovered and gate by default. The10 supported
cases inside the mixed `self_service` target still gate. Only the14 exact
historical failure names in `scripts/ci-legacy-client-tests.txt` are excluded
from that supported invocation. A separate explicitly informational legacy job
runs the **entire unchanged self_service target without exclusions**, prints
Cargo's raw exit, writes it to the Actions summary and returns that same exit.
It deliberately has no `continue-on-error`: historical failure keeps that job
and the aggregate workflow red. Do not describe supported green checks as an
all-green workflow. No failed historical assertion is fixed, waived or hidden.

This follows [REQ-MSG-005's explicit historical-scope amendment](../product/requirements.md#first-contact-incoming-correction-2026-09-09)
and [the overnight v7 continuity boundary](../product/overnight-realtime.md).
REQ-MSG-006, REQ-ID-004/005/008 and REQ-SEC-001 remain enforced by unchanged
realtime/signing, binding, registration, rejection and persistence suites.
No protocol, threat-model or accepted ADR decision changes are introduced.
The repository rulesets API returned an empty list during this correction;
workflow jobs are not evidence that branch protection requires them.

## Verification and evidence

Before correction, the wiring regression failed and a direct TCP
`self-service-init` reproduced exit1 with the original static error. The same
unchanged server under the private runner passed the focused
`realtime_session_auth_binds_every_context_and_nonce_replay_has_one_winner`
test (1passed,13filtered). The supported mixed-target invocation passed10tests,
14explicitly filtered for separate execution. The wiring regression validates
private setup, exact historical names and unmasked legacy exit behavior.

New evidence is isolated beneath
`/home/codex/paranoid-self-service-evidence/overnight-realtime-20260909T191524Z/ci-correction-20260909T212852Z`.
Final remote run/commit links and completed outcomes are recorded in the PR and
issue comments after execution, not guessed in this pre-run source note.
Historical source review and signed-artifact evidence are untouched. Rollback
of this CI-only change is a later revert; it requires no runtime action.
