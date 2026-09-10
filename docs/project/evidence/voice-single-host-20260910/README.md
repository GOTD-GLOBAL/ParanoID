---
status: draft
owner: maintainers
last_reviewed: 2026-09-10
---

# One-host installer candidate and exact remaining gates

[Owner authority and REQ-DEPLOY-003](../../../operations/voice-single-host.md)
authorize the existing host and one coordinated installer after actual acceptance
and required review. Original client/server heads were
`562848658f3b5874827d12185bf3829aba1bfe0d` and
`923e11b1f0a5ba8709002d21e282778123c2bfe5`. Private evidence root:
`/home/codex/paranoid-self-service-evidence/voice-single-host-20260910T045552Z`.
Initial tracked-file hashes, clean status, prior artifacts, failed attempts and
source snapshots remain preserved. No hosted deployment or PR merge occurred.

## Implemented and observed

The candidate contains one coordinator, a message-user worker, the exact retained
message release, the new offline TURN package and the root network helper. It
exposes plan/preflight/apply/status/update/rollback plus safe archive extraction.
Acceptance binds the exact kit and plan. Existing data/TLS/identity are preserved;
fresh mode refuses an existing root. Production activation is hard-refused because
no full-relay rehearsal profile is implemented. There is no force/skip flag.

- [Existing-v8 result](message-existing-result.json): actual owned private-PG/TLS
  update, verified idempotence, encrypted restore-verified backup and rollback
  preserving a row accepted after update. Execution and cleanup passed.
- [Fresh/update result](message-fresh-result.json): actual owned fresh install,
  different fixture-only controller update, same-data rollback and one injected
  readiness failure recovery. Execution and cleanup passed. The original native
  binary and schemas were retained in the fixture-only controller variant.
- These are message-phase fixtures with the issuer disabled. Their exact sources
  are retained externally; subsequent production guards and loaded-unit validation
  are separately identified. They are not full relay or exact final artifact
  acceptance.
- The targeted later fresh-start wrapper run completed and cleaned up, but its
  receipt falsely labelled an import-failed offline report PASS. Its acceptance is
  **INVALID_RECEIPT**. The failed report, receipt and runtime observation are
  immutable. A later correct offline result does not retroactively authorize it;
  no runtime replay was performed to manufacture a clean result.
- [Retained APK readback](retained-apk-readback.json): signed v10 bytes unchanged;
  no new APK, instrumentation or signer was generated.

The [final structured offline report](final-offline-report.json) records 59 passing
tests, exact command/exit/output hash and ten source/test-file hashes. Root
[independently verified](offline-root-verification.json) those bytes and the
[actual output](final-offline-tests.log). The corrected fixture harness refuses a
failed/unstructured report or source/package mismatch. This does not retroactively
validate the earlier invalid receipt.

## Artifact

The [independent artifact verification](artifact-root-verification.json) checks
all 41 regular files, exact manifest membership/hashes, normalized tar metadata,
current coordinator/worker/network/template bytes and Linux x86_64 ELF headers.
Two separate builds from retained components produce the same archive bytes.
Release `de205cfbb63b9bff3ed0`, 19,374,080 bytes; archive SHA256:
`5bb0e23450b81f3d70e62c18ecf1b848b7a509f132aa977bfeb95af8a22cc543`.
Manifest SHA256: `06d09794c98baf4efebe5da9804c1f4846d1818d34c7a6096d169d14d405b2de`.
Message component `4eba2afd548e0666dc24`; relay `9eff656b71da22a57e24`.
The artifact remains private external evidence, not a deployed/public release.
[Normalized extraction/readability](archive-extraction-readability.json) passed in
a new owned scratch directory; no native service was executed. The
[example inputs, actual plan and typed refusal](examples/README.md) demonstrate
the interface. [Final source freeze](source-freeze-final.json) and
[owned-fixture cleanup](fixture-cleanup-final-matrix.json) preserve exact limits.

## Reviews and corrections

[Initial Fable design review](fable-design-review.md.txt) has verified
[actual Fable model/subtype provenance](fable-design-provenance.json). A1–A5 were
amended before implementation in the [design](installer-design.md) and
[test plan](installer-test-plan.md). The fixture was later narrowed to message
phases without issuer enablement after its public-mode/loopback mismatch was
identified; production address checks were not weakened.

The [first integration audit](installer-integration-audit.md) found plan binding,
retained messaging ingress, prior-unit drift and preflight network ownership gaps.
The [bounded final peer audit](installer-final-peer-audit.md) found relay update
restart, merged unit overrides and recovery ingress ordering gaps. Their exact
snapshots and [bounded B1–B3 closure](installer-peer-closure.md) are retained.
The [receipt audit/correction](installer-evidence-correction.md) reconstructs the
actual passing earlier report bindings and the later invalid one; earlier logs
do not establish exact offline-tested source identity. Peer review is not a substitute
for the required final Fable review or actual runtime security tests.

The later requested Fable credential review returned actual Opus models, and one
no-tool probe also returned Opus. [Exact provenance](credential-review-provenance.json)
means the [supplemental report](credential-supplemental-review.md.txt) cannot count
as the required Fable approval. No further model probe, auth change or safeguard
bypass followed. Final exact code/artifact Fable approval remains unavailable
through that invocation path.

## Credential, relay and call gates

[Credential handoff](credential-final-handoff.md) preserves both inert first-case
failures and verified cleanup. The delivered descriptor remains unmeasured; the
[ACL compatibility proposal](credential-acl-proposal.md) is unapproved historical
design input. The unchanged-guard observer has offline tests but its one runtime
diagnostic is NOT RUN. Generic/source/issuer/relay validation was not relaxed.

The [runtime capability audit](runtime-capability-audit.md) records actual local
root/systemd availability and the exact earlier worker rejection. No rejected
expiry/ACL worker scope was retried or rerouted. TURN-RT01, TURN-ACL02, effective
CLI closure, actual relay lifecycle and full coordinated rehearsal remain NOT RUN.
[CLI source inspection](cli-source-verification.json) establishes only that pinned
source recognizes `cli=0`. Unit dependency resolution has genuine
[RED](policy-dependency-red.log) and [GREEN](policy-dependency-green.log) evidence;
it did not start a relay.

The [call plan](call-acceptance-plan.md) and initial Fable C disposition permit a
separate three-case CALL-CURRENT01 after relay gates pass. It remains NOT RUN.
Historical CALL-CONNECT01 remains OPEN. Physical-phone audio, Bluetooth, Doze and
mobile handover were not tested. Owner placement authority is not missing and
must not be requested again.

[Final local documentation, link and CI-wiring checks](final-local-checks.json)
are recorded separately from runtime and artifact evidence.

## Preservation and next step

The exact [owner record](owner-authority.json) identifies the bot-recorded direct
Telegram quote, not permanent ADR acceptance. REQ-DEPLOY-002/003, REQ-CALL-006,
RFC-0018 and proposed ADR-0012 remain linked. Canonical text copies may normalize
terminal blank lines and table delimiter spacing ([record](canonical-text-normalization.json)); raw external
review/process/test files remain unchanged.

Restore a verified required Fable review capability, then disposition the single
credential diagnostic and any evidence-supported compatibility change. A
separately permitted owned full-relay environment/profile must establish expiry,
access-control, CLI, credential/lifecycle, coordinated installation and current
call acceptance. Only a reviewed source revision with those actual results can
make production activation available. The existing host, TLS/data/identity and
neighbors remain untouched meanwhile; no new placement permission is required.
