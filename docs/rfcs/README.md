---
status: accepted
owner: maintainers
decision_owner: martadvix-web
approved_change: RFC/ADR lifecycle, decision authority, durable evidence, and protected-domain review governance
approval_date: 2026-08-17
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/4
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/4#issuecomment-5311797500
last_reviewed: 2026-08-15
---

# Request for comments process

RFCs make significant proposals reviewable before implementation. They are not
accepted architecture until an ADR records the decision.

## States

- `draft`: author is still developing the proposal;
- `proposed`: ready for review and experiments;
- `completed`: review concluded; link every resulting accepted ADR;
- `rejected`: not selected; preserve the reason;
- `withdrawn`: author stopped the proposal;
- `superseded`: replaced by a linked RFC.

RFCs never use `accepted`. `completed` closes the discussion but does not make the
RFC normative; accepted decisions exist only in linked ADRs.

## Review and closure

Before moving an RFC to `proposed`, name its human `decision_owner`, required
domain reviewers, decision deadline, and validation plan. The proposal owner is
responsible for collecting evidence but cannot substitute authorship for the
required approval.

Close an RFC and record its disposition in one coherent pull request:

- use `completed` and link the accepted ADR or ADRs when a choice is approved;
- use `rejected` and preserve the rationale when no option is selected;
- use `withdrawn` when the author stops the proposal without a decision;
- use `superseded` and link the replacement RFC when discussion moves elsewhere.

Follow the human authority and acceptance-evidence rules in the
[documentation policy](../governance/documentation-policy.md#decision-authority-and-acceptance-evidence).

## Active governance proposal

- [RFC-0007: Bounded closed-alpha review policy](0007-closed-alpha-review-policy.md)
  (completed): approved by owner; ADR-0003 and the policy take effect on merge.

## Naming

Use `NNNN-short-title.md`. Allocate the next number and never reuse it. Add active
RFCs to this file when the first proposal is opened.

## Required use

Create an RFC for every
[protected decision domain](../governance/documentation-policy.md#protected-decision-domains)
or any other change whose reversal would be expensive or compatibility-sensitive.

Use [the RFC template](rfc-template.md).
