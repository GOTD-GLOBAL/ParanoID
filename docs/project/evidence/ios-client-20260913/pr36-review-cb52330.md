---
status: draft
owner: maintainers
decision_owner: martadvix-web
last_reviewed: 2026-09-14
---

# Full-component PR36 re-review of cb52330

## Revision and review scope

Permanent [GitHub review](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#pullrequestreview-5200511065)
records `CHANGES_REQUESTED` on the exact reviewed HEAD; this is advisory AI
review, not architecture acceptance or human approval.

- HEAD: `cb523306c186e91a6d65e4050bd0b65eb9c7ab77`.
- PR base: `2d91bd4dba79bd35f563e51850f2e18796a3c9ba`.
- Tree: `27de60ff782b59ee2de8356c4b85c03530f452e4`, independently matched to
  the contributor-tested `aab9e5dee8fe75c5a3170faac5f12e80819cdb12`.
- e642907 and aab9e5d are retained ancestors. Component boundary: **208 changed
  files, zero outside allowlist**. Server/core/Android/key-protocol/deploy diff
  against the PR base is empty.
- Four fresh independent **GPT-6-Astra** contexts reviewed complete storage,
  TLS/FFI/build, realtime/text/lifecycle and call/media integration paths, not
  just the PR41 delta. The coordinator, who implemented prior corrections,
  checked their findings against the source. No Fable or human-audit claim;
  same-model blind spots and bounded review coverage remain.

Requirements: REQ-CLIENT-001, REQ-ID-005/007/008, REQ-MSG-002/003/005,
REQ-CALL-002/003/006. The review read applicable governance, storage, realtime,
first-contact, voice-v1, call-v2 and voice-turn-v1 boundaries. RFC-0021 and
ADR-0014 remain proposed; this review changes no decision authority.

## Subsequent C1 closure (2026-09-14)

PR43 fixes the remaining controls. The [dad2f7d Mac receipt](mac-receipt-pr43-dad2f7d.md)
records C1 7/0 GREEN and actual old-code behavioral RED: seven tests, thirteen
expected assertions, no unexpected failures. The code is integrated in 96298cd
without runtime/test/workflow differences from the tested revision.
[Final integration review](pr36-review-96298cd.md) closes C1 at host/simulator
scope, while main and all permanent acceptance/live gates remain with their
owners. The original source finding and its review-time limitations below are
preserved as history, not presented as a currently unresolved bug.

## Historical verdict at cb52330: changes required

Prior PR40/41 corrections remain closed at their tested host/simulator scope.
No new concrete blocker was established in storage/onboarding, TLS/FFI/build
or realtime/text/lifecycle. One remaining family of unbound call controls needs
correction; successful tests do not exercise every possible owner/UI interleaving.

### C1 — P2: stale End/Reject can terminate a replacement call

Paths under `clients/ios/`:

- `App/ParanoID/AppModel.swift:811–817` checks the displayed active call, then
  dispatches `calls.end()` without its identity or generation.
- `App/ParanoID/Voice/CallCoordinator.swift:225–229` crosses to the owner and
  rejects/hangs up whichever call is current at execution time.
- `ParanoidKit/Sources/ParanoidKit/Voice/CallController.swift:405–416` acts on
  the current live call; it has no expected-call argument on these entry points.

Concrete ordering, including offer admission: while idle, peers A and B acquire
separate authenticated readiness slots (`CallController.swift:948–956`). A's
offer arrives first and the UI displays A; its End/Reject action queues an owner
operation. Before that operation executes, authenticated end A is processed,
then B's delayed valid offer. `finish()` clears live A but not B's readiness
slot (`1099–1115`); B's offer consumes its valid slot and becomes incoming
(`976–1009`). The queued unbound action then rejects B. This requires neither
an unsolicited offer bypass nor publication reordering: even an updated UI
cannot change the already-scheduled unbound action. Owner serialization prevents
simultaneous mutations, not mistaken targeting across the asynchronous hop.
Answer and camera already carry expected generation; these controls do not.
A fifth fresh context adversarially checked this finding and confirmed this
legal ordering; the coordinator re-read the admission/terminal paths.

The same omitted binding exists for mute/speaker (`AppModel.swift:826–834`,
`CallCoordinator.swift:232–237`, controller `439–460`): old desired values can
be applied to B. No runtime microphone-leak reproduction is claimed.

Required regression: park the final owner dispatch of A's action, replace A
with incoming B, release it, and require no B termination/control emission or
mute/speaker mutation. Carry original ID/generation across every call-targeted
UI hop and validate before mutation, retaining valid same-call behavior.
This finding is **source-traced, not a Swift-executed race reproduction here**.

### D1 — documentation reconciliation, no runtime change

The reviewed tree still calls PR41 draft and its package compilation blocked;
the successful aab9e5d receipt existed in the PR discussion but not this tree.
Its verification table also retained universal ATS-constructor and local-only
proximity wording. A separate docs-only branch records the receipt and corrects
those statements without changing the reviewed runtime, tests or workflows.
The earlier e642907 failure remains preserved, not rewritten as passing.

## Verification evidence

Contributor's [complete Mac receipt](mac-receipt-pr41-aab9e5d.md) reports actual
package compilation, full package **293/0**, lazy-key **14/0**, storage **25/0**,
and signed-simulator app **64/0**. Source-tree equality makes it applicable to
cb52330. These are Yaroslav's executions, not coordinator Apple runs.

Coordinator execution on cb52330:

- Storage source **5 PASS**, UI **20 PASS**, freeze/open **3 PASS**, onboarding
  **3 PASS**, call review **5 PASS**, pinned-session mutations **11 PASS**.
- Bridge **6 ABI tests PASS**, clippy `-D warnings` and locked iOS-target cargo
  check **PASS**. Lock matches **123 registry + 2 path packages**.
- Toolchain gate `--no-xcode` **PASS**, not an Apple-toolchain check.
- WebRTC dependency **11 PASS on synthetic offline archive**; notices **30 PASS**;
  full notices rendering covers 91 crates plus WebRTC. No fresh real binary
  download or signed-bundle revalidation occurred.
- Call parity **94/94 labels**, not 94 media scenarios executed here.
- Docs consistency **7 facts PASS**; it does not detect every stale prose claim.
- GitHub reports all five named checks SUCCESS on cb52330. Informational legacy
  remains FAILURE. Rulesets endpoint returned none; main required-status-checks
  endpoint reports branch not protected. Process gates are not GitHub enforcement.
- Reviewed worktree clean and HEAD unchanged. Full base-to-HEAD whitespace check
  reports vendored upstream notices whitespace, not a newly introduced runtime
  defect; legal text was not reformatted.

## Remaining acceptance boundaries

No local Swift/Xcode/XCTest execution, physical-device upgrade, power loss,
real NWPath transition, actual media-stop latency, real relayed media, archive,
export/TestFlight or live-server validation was performed. Physical media disposal
is asynchronous after synchronous controller-authority termination. The ATS gate
is finite lexical coverage, not arbitrary Swift data-flow assurance. Known
first-commit availability cost and missing whole-state anti-rollback witness remain.

Next code gate: C1 correction plus targeted regression and new-SHA review/Mac
verification. Main integration remains Sergey's decision after those gates;
permanent ADR acceptance, device acceptance, export/TestFlight and all live
operations require their own evidence/authority. No merge or deployment was done
by this review.
