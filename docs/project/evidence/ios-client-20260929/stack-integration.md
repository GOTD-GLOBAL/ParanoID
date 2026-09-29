---
status: draft
owner: client
last_reviewed: 2026-09-29
---

# iOS stack integration after the PR60 deployment report

## Actual base and scope

GitHub still reported PR60 OPEN/draft at `463a864` during this integration;
`origin/main` remained `866827f`. Do not call this a post-PR60 main merge.
The local main checkout was not updated or used as the integration base.
The iOS stack below is based on the fetched `origin/main` object. PR60 and PR62,
other agents' worktrees and deployment configuration were not edited.

A bounded external read-only check at the beginning of this work found:

- `138.16.180.53:38444`: expected pinned TLS key, HTTP 200, health protocol
  `paranoid-identity-v3`, status `ok`.
- `157.180.49.125:38443`: expected pinned TLS key, HTTP 200, health protocol
  `paranoid-self-service-v2`, status `ok`.

Pins came from PR60's `KeyClient.java`. The public leaf SPKI was checked before
HTTP, then normal certificate/hostname/validity validation used that pinned
leaf. No credentials, enrollment, login, state mutation or SSH were involved.
Health does not disclose the deployed commit; exact installed artifact identity
remains unverified. This is evidence of two responding services, not a claim
that PR60 merged or that iOS can log in through Solana.

## Reconciled source stack

| PR | Code checkpoint | Base after coordination |
| --- | --- | --- |
| 63 | `dea6829` unchanged | main |
| 64 | `53866c8` | PR63 branch |
| 66 | `e43cc96` | PR64 branch |
| 65 | `6d197cf` | PR66 branch |
| 59 | `a7f3ac9` (this evidence is a later docs-only commit) | PR65 branch |

Each changed feature branch retains its original head as an ancestor through a
normal two-parent merge; no force-push or squash/rebase of contributor history.
PR58 is a separate docs-only proposal, refreshed from main without including
PR60. Its 21 open product questions are not answered by this integration.

## Conflict dispositions

All conflicting independent additions were preserved, never resolved by taking
one entire file wholesale:

- CHANGELOG/current-state, client README/self-service and verification rows keep
  every feature and every original exact-head Mac receipt with its limitations.
- Python UI contracts retain all feature-specific tests; an AST check found no
  duplicate test-method definitions hiding an earlier assertion.
- PR66 intentionally supersedes PR64's contact-order assertion with local-name
  ordering. Chat recency and button checks remain. This is the original PR66
  proposal, not a new product choice made during conflict resolution.
- `Chat.swift` preserves PR59's `position(_:)`/scroll-to-new helpers in full and
  PR65's trimmed composer/counter behavior. Only the old composer comment's
  Android line references were superseded by PR65's updated explanation.
- The caption-header conflict preserves both iOS proposal provenance and the
  unread-specific description; background/update limitations stay intact.

Every original changed XCTest method name was found in the final combined
source. This is a preservation check, not Swift compilation or execution.
Core/server/key-protocol/Android/blockchain/bridge source trees remain identical
to `origin/main` throughout the iOS stack; protocol/RFC/ADR and CI rules are not
changed by these merge resolutions.

## Executed checks

The coordinator reran all Python commands of `ios-static`, including notices,
lock/toolchain pins, controller parity, docs consistency and boundary checks,
plus Markdown and whitespace checks on each of the five code checkpoints:

| PR checkpoint | UI contract | Other listed source gates |
| --- | --- | --- |
| 63 | 25/0 | PASS |
| 64 | 26/0 | PASS |
| 66 | 27/0 | PASS |
| 65 | 28/0 | PASS |
| 59 | 29/0 | PASS |

The unchanged bridge graph also passed Rust device-triple `cargo check`, clippy
with `-D warnings`, and six host ABI tests at the PR63 checkpoint. Subsequent
stack commits do not change that graph. This is not an Apple-linked build.
PR58's refreshed docs-only tree passed Markdown, docs consistency and UI 24/0.
Fresh exact-head CI and independent integration review are recorded in PR comments.

The earlier PR60 Java integration finding was rechecked at `463a864`: its new
`IdentityPorts` interface and explicit source lists make the exact iOS host-facade
javac substep pass on Linux. That is not a full pinned Mac `java_deps.sh` run.

## Native gate and decisions still open

New merge heads invalidate any claim that the historical per-PR Mac receipts
already cover the combined source. No Swift, Xcode, simulator or physical-device
execution was performed during this Linux integration. Before source merge,
obtain exact-head Mac receipts for the resulting staged candidates, including:

- full ParanoidKit and app test targets, separately signed Keychain checks;
- call auto-dismiss/retry/return-banner lifecycle cases;
- chat recency, contact sorting/blocked section and fingerprint presentation;
- the combined unread divider/scroll-to-new and trimmed-composer/draft-recovery
  scenarios, not only separate feature tests;
- stand-backed text flow, fresh device bundle and negative/mutation cases.

Keep the core xcframework, notices and app from that same checkout. Do not carry
an old binary into a future PR60 integration. Combining a later merged PR60 with
this stack requires fresh source checks and a native run of that new tree.

This reconciliation does not approve caption wording, RFC0023's additional
presentation-only ordering use, the iOS/Android trim difference or blocked-list
product behavior. Preserve their proposed status for the decision owner.
It adds no iOS identity-v3 login path, no peer-key replacement shortcut, no
persistent unread state/read receipts, no APNs implementation or deployment.
GitHub draft/readiness is a test gate, not product/architecture acceptance.

## Merge and rollout discipline

Merge order: 63, 64, 66, 65, 59; PR58 may be considered separately. Prefer normal
merge commits for the staged chain so parent ancestry is retained; if another
method is chosen, explicitly reconcile/rebase the dependent PRs and rerun their
gates rather than assuming automatic retargeting. Confirm each PR base and diff
before merge. Source merge needs Sergey's explicit instruction; app publication
and server changes require their own scope. No main merge or deployment occurred
as part of this integration. Revert a reviewed integration change to roll back;
there is no state migration here.
