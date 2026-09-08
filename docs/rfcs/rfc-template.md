---
status: draft
owner: <author-or-team>
decision_owner: <human-github-login>
decision_deadline: YYYY-MM-DD
required_reviewers: []
last_reviewed: YYYY-MM-DD
---

# RFC-NNNN: Proposal title

Use an empty `required_reviewers` list only when no independent human domain
review is required. For the closed-alpha exception, add
`review_mode: closed-alpha-ai`, record the independent AI reviewer separately,
and supply all scope, review and owner evidence required by the
[policy](../governance/documentation-policy.md#closed-alpha-review-exception).
Otherwise list each required human GitHub login.

## Required review rationale

For each required reviewer, record the protected domain, relevant qualification,
and why the reviewer is independent from the author and decision owner. Write
`Not applicable` with a reason when no independent domain review is required.

## Summary

Describe the proposal and intended outcome in a few sentences.

## Motivation

Which requirements, user problems, risks, or measurements justify this work?

## Goals and non-goals

### Goals

- Goal

### Non-goals

- Explicitly excluded scope

## Proposed design

Describe behavior, boundaries, data, flows, failure modes, and trust assumptions.
Include diagrams and versioned contracts where useful.

## Alternatives

Compare credible alternatives against the same decision drivers.

## Security and privacy

Describe assets, attackers, metadata, key lifecycle, permissions, abuse cases,
and changes to the threat model.

## Compatibility and migration

Describe version negotiation, rollout, migration, downgrade behavior, and rollback.

## Operations and observability

Describe deployment, configuration, capacity, logs, metrics, alerts, backup,
restore, and incident response.

## Validation plan

List prototypes, tests, benchmarks, reviews, and measurable acceptance criteria.

## Open questions

- Question, owner, and decision deadline

## Decision and follow-up

- Disposition:
- Decision-owner approval permalink:
- Delegation evidence permalink, if applicable:
- Required-review evidence permalinks:
- Resulting ADR:
- Closure rationale for `completed`, `rejected`, `withdrawn`, or `superseded`:
- Replacement RFC for `superseded`:
- Implementation issues:
