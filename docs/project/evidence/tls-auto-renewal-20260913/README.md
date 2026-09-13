---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# Automatic same-key renewal evidence

See the [runbook](../../../operations/tls-auto-renewal.md#observed-installation--2026-09-13)
for scope, direct owner authorization, schedule, preservation and limitations.
The runtime source is [deploy/tls_renewal.py](../../../../deploy/tls_renewal.py);
its deployed/reviewed SHA-256 is
`fb962a83a94925eefce773435464d536e0f670a9b90f01bc270dc840ef3cb3a8`.
No private keys or application data are included. Imported initial-review and
TDD-log trailing whitespace was normalized for Git checks; the
[normalization manifest](text-normalization.json) records original and archived
hashes. Findings and test outcomes were not edited.

## Sources of evidence

- [Host installation receipt](installation.json): exact installed script/unit/timer
  hashes, successful actual user-service execution, `not_due`, unchanged
  app/certificate/config/package and enabled persistent timer.
- [Actual host source/unit modes](host-modes.txt): distinguishes Python 0755
  from the 0600 unit; neither was chmodded by this task.
- [Initial review](review-initial.txt) and
  [closure transcript](review-final-transcript.txt): corrected the real installer
  gate/order issue and withdrew the unit-mode finding after actual host evidence.
  Closure APPROVE applies to the exact runtime and corrected installer hashes.
  Runtime transcript tool bodies are bounded previews. Review is isolated AI,
  with actual model identity not exposed, not a human audit.
- [TDD transcript](tdd-transcript.log): retains actual RED/GREEN steps rather than
  only final success. [Final unit tests](unit-tests.log): 13 PASS; real synthetic
  crypto/files with explicit lifecycle/network mocks.
- [Installer](installer.py.txt), [installer gate tests](installer-tests.py.txt)
  and [actual gate-test output](installer-tests.log): four PASS, temporary files
  and mocked systemd/CLI. Neither due nor recovery-required may start automation
  in this first-install path; unchanged baseline precedes timer enablement.
- [Actual local systemd/TLS result](runtime-result.json),
  [harness](runtime-harness.py.txt) and [synthetic controller](fixture-alpha.py.txt):
  real local service stop/start and TLS for successful due renewal, repeat no-op
  with unchanged PID and failed-candidate-health rollback to working old TLS.

The runtime fixture generates disposable synthetic keys. Its controller health
command checks real TLS but deliberately emits a stubbed readiness token marked
`SYNTHETIC TOKEN; NO DATABASE`. It does not establish PostgreSQL readiness. The
first harness attempt failed because its initial descriptive readiness output
lacked the runtime's expected token; this was a fixture mismatch, not a product
fix. Final runs used the marked stub and the unchanged reviewed runtime hash.
Actual hosted readiness was separately checked with the real installed alpha
controller. No production certificate/key was copied into the local fixture.

Tests may be reproduced using the production module and `python3 -m unittest
 deploy.test_tls_renewal -v` from repository root. Archived parent scripts keep
the original paths; adjust only build-host paths for local reproduction. Real
systemd fixture execution creates a uniquely named local user unit, stops/removes
its own runtime link afterward and removes only its disposable synthetic tree.
No fixture command authorizes SSH or a new hosted due cycle.

No hosted forced renewal, hosted failure injection, reboot, full history audit,
physical phone or iOS/TestFlight acceptance is claimed. The first live automatic
service execution was deliberately not due and did not restart the application.
