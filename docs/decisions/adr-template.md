---
status: draft
owner: <role-or-team>
decision_owner: <human-github-login>
required_reviewers: []
last_reviewed: YYYY-MM-DD
---

# ADR-NNNN: Decision title

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

## Context and problem statement

What decision is required, which requirements or risks force it, and by when?

## Decision drivers

- Measurable driver
- Constraint or quality attribute

## Considered options

1. Option A
2. Option B
3. Option C

## Decision

State the chosen option and the decisive reason in one paragraph.

## Consequences

### Positive

- Expected benefit

### Negative

- Accepted cost or limitation

### Risks and mitigations

- Risk and mitigation

## Validation

How will tests, metrics, prototypes, reviews, or operational exercises confirm
that the decision works?

## Compatibility and migration

Describe rollout, backward compatibility, data migration, and rollback.

## Disposition and acceptance evidence

- Disposition: <accepted | rejected | withdrawn>
- Disposition rationale:
- Decision owner and identity:
- Pull request URL:
- Permanent disposition or approval evidence URL:
- Withdrawal author statement URL, if applicable:
- Delegation evidence URL, if applicable:
- Required-review evidence URLs:
- Telegram message ID, sender mapping, timestamp, and exact approval text, if used:
- Disposition date: YYYY-MM-DD
- Known limitations and follow-up:

## Links

- Requirement: <link | not applicable — reason>
- RFC: <link | not applicable — reason>
- Threat model: <link | not applicable — reason>
- Experiment or benchmark: <link | not applicable — reason>
- Supersedes:
- Superseded by:
