---
status: draft
owner: maintainers
decision_owner: martadvix-web
last_reviewed: 2026-09-14
---

# Final PR36 integration review: 96298cd

## Technical verdict

Permanent [technical GitHub review](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#pullrequestreview-5201368202)
records APPROVED on the exact reviewed HEAD. That is AI code-review disposition,
not human main-merge authorization or permanent ADR acceptance.

**C1 is closed at the verified host/simulator scope. No remaining concrete code
blocker was found; the code is ready for the human owner's bounded private-alpha
main-integration decision.** This is not merge authorization, architecture
acceptance, completion of physical-device acceptance or production assurance.

This round verifies integration of the independently reviewed/tested C1 fix into
the previously full-reviewed PR36 component. It does not claim a fresh exhaustive
line-by-line audit or repeat Apple tests on Linux. Earlier full cb52330 reviews
covered storage/onboarding, TLS/FFI/build, realtime/text/lifecycle and calls/media;
C1 was their remaining code finding. Independent C1 implementation/test reviews,
actual contributor Mac RED/GREEN and two fresh integration/boundary reviews
complete that evidence chain. Reviewers are separate GPT-6-Astra contexts, not
Fable or human auditors; shared-model blind spots remain.

## Revision and merge integrity

- Reviewed HEAD: `96298cd2f3968374f9035226069bfe704079b33f`.
- PR base: `2d91bd4dba79bd35f563e51850f2e18796a3c9ba`.
- Merge parents: `e9c767b907615a5b60d112c17632f36aadc83622` and
  `dad2f7d2df96d5ab4cecd21219df1b5538c7164a`.
- Coordinator independently fetched the branch, checked ancestry and empty
  `git diff dad2f7d 96298cd -- clients/ios .github CHANGELOG.md`.
- `git show --remerge-diff` confirms manual resolution only in
  `docs/project/current-state.md`: retain C1 section plus the PR42 verified
  heading, not the older package-blocked heading. Both sections survive.
- Remaining dad2f7d..96298cd changes are documentation only. No merge-created
  runtime/test/workflow difference invalidates the exact dad2f7d Mac receipt.
- Full PR boundary **215 changed files / 0 outside allowlist**. Server, shared
  core, Android, key-protocol and deploy diff against PR base is empty.
- Frozen review worktree remained clean; this review did not merge or edit it.

## C1 closure and checks

Inside the controller, scoped End/Reject/Hangup/Mute/Speaker validate call ID and
generation against live state after owner-affinity checking and before mutation.
UI and Coordinator carry the captured fields through the final hop. Prior
Answer/video, freeze and relay-cancellation corrections remain unchanged.

The [full contributor Mac receipt](mac-receipt-pr43-dad2f7d.md) records:

- CallControlDispatchTests **7/0 GREEN**; full package **300/0**;
  lazy-key **14/0**; storage **25/0**; signed-simulator app **64/0**.
- Old cb52330 baseline: **7 tests / 13 assertion failures / 0 unexpected**,
  **Swift exit 1**; harness exit 0 records expected behavioral RED. Tests ran;
  compiler/setup failure was not substituted for the wrong-call regression.
- The real StateOwner/CallController tests hold a queued action while valid
  A-end/B-offer processing installs B. Signaling/media ports are fakes, not a
  physical iPhone interaction race or a media-stop timing measurement.

The coordinator read that receipt in full and verified its permanent publication
at PR43 comment 5668320999. These are Yaroslav's Apple executions; source identity
makes them applicable here without representing them as coordinator runs.

Coordinator checks actually executed on 96298cd: C1 source **4 PASS**, baseline
classifier **4 PASS**, UI **20 PASS**, prior call **5 PASS**, freeze/open **3 PASS**,
onboarding **3 PASS**, storage bootstrap **5 PASS**, pinned mutations **11 PASS**,
docs consistency **7 facts PASS** and the component boundary above.

GitHub independently reports SUCCESS for markdown, ios-static, client-core-and-tls,
native-package and postgres-http on this exact HEAD. Informational legacy history
remains FAILURE. No GitHub branch-protection or required-review enforcement is
inferred from green workflows; the prior read reported no rulesets and unprotected
main. No settings were changed.

## Documentation reconciliation

The merge faithfully retained both source sections, including their historical
pending-Mac/C1-blocked language. A separate docs-only reconciliation records this
receipt and closure in current-state, C1/general handoffs, verification mapping,
evidence catalogue and the historical cb52330 review. Runtime, tests, workflows
and CHANGELOG stay untouched. Recording this evidence does not require another
Mac run of identical code; it does require docs checks and normal review.

## Owner decision and remaining limits

Sergey retains the explicit decision to integrate PR36 into main within the
bounded private non-sensitive alpha scope. Reconcile the evidence-only docs
before publishing an up-to-date main status. No AI review or contributor feature-
branch merge is that owner decision.

RFC-0021 and ADR-0014 stay **proposed**. Acceptance needs its own permanent human
approval and required evidence; main merge alone does not change their status.
REQ-CLIENT-001 physical/joint acceptance, real-device tap/network races, actual
media-stop latency, real-container upgrade, power loss, relayed-device media,
archive/export, TestFlight and hosted probes remain separately gated/unrun as
recorded in their plans. Earlier reported device-connectivity failures are not
proven resolved by these package/simulator results. No scope expansion, real sensitive communication,
production assurance, live-server action or release is authorized here.

Next: owner decision on the reviewed code plus documentation reconciliation.
If source/tests/workflows change before integration, reassess the changed scope
and the applicability of the current receipt rather than carrying it forward
blindly. No main merge, release, deployment or ADR acceptance was performed by
this review.
