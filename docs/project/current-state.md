---
status: accepted
owner: maintainers
last_reviewed: 2026-09-08
---

# Current project state

## Phase

**Inception and architecture discovery.** This repository is a clean reboot. It
contains documentation governance and project framing, but no messenger
implementation or accepted production architecture.

The earlier proof of concept is preserved in the private
`GOTD-GLOBAL/ParanoID-legacy` repository. It may be mined for lessons, UX ideas,
and experiments, but it is not a dependency or source of current architecture.

## Experimental device evidence

A disposable Android packaging diagnostic exists in
`spikes/002-android-bootstrap`. The owner supplied a screenshot of installation
and launch on OPPO CPH2671 (Android 16/API 36). It displays device information
locally, has no network permission and is not a messenger or stack acceptance.

## Present facts

- The new repository is private and intentionally starts from a clean history.
- The product vision is documented as a draft.
- Initial product requirements are traceable but do not yet have complete
  acceptance criteria.
- Documentation-as-code is the first accepted project decision.
- No application stack, blockchain, identity protocol, messaging protocol,
  cryptographic construction, database, hosting platform, or token model has
  been selected.
- No production security or privacy claims are valid yet.

## Active single-server implementation boundary

The founder now prioritizes one server and two OPPO phones exchanging E2EE text
with history, reconnect and no duplicates. One check means server acceptance;
two mean peer delivery, not reading. Server history remains until an additional
explicit deletion request. iPhone and multiple-server support remain future
scope; a second server is not an acceptance gate for this slice.

[RFC-0006](../rfcs/0006-single-server-text-contract.md) records concrete assistant
recommendations and their [acceptance matrix](../protocol/server-v0-acceptance.md).
It is draft, not an accepted architecture. Identity/E2EE, delivery/persistence
and stack disposition still lack independent qualified human reviewers and
durable owner approval evidence. Existing RFC-0004/0005 remain drafts in open PRs.

A [dependency-only stack check](../research/2026-09-08-server-stack-check.md)
compiled pinned Axum/Tokio/SQLx dependencies on Linux. It implements no server,
API, message store or client. No phone-to-phone message has been demonstrated.
The local Docker daemon was inaccessible to this invocation; no production host
was changed. No iOS build or protected-domain implementation was performed.

The older discovery list below is background, not a request to restart broad
research. The immediate gate is disposition of the narrow contract, then the
TDD implementation order in RFC-0006.

## Next decision gates

1. Validate and prioritize the initial requirements with the founder.
2. Define assets, adversaries, metadata exposure, recovery, and trust boundaries.
3. Specify identity and nickname lifecycle, including cost and abuse resistance.
4. Compare protocol and implementation strategies, including open-source prior art.
5. Select the first vertical slice and its measurable acceptance criteria.
6. Accept the initial architecture and stack through RFCs and ADRs.

## Update trigger

Update this document whenever a gate is completed, a production capability is
added, a major risk changes, or an accepted decision changes what a newcomer
should believe about the project.
