---
status: accepted
owner: maintainers
decision_owner: martadvix-web
required_reviewers: []
approved_change: bounded second-human review exception for private test-data alpha
approval_date: 2026-09-08
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/12
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/12#issuecomment-5581548687
last_reviewed: 2026-09-08
---

# ADR-0003: Bounded closed-alpha review policy

## Context, drivers and alternatives

The founder has no independent qualified human reviewer available for private
alpha development. RFC-0007 compares keeping the unconditional second-human gate,
removing all human review, and a bounded exception. Pretending an AI is human is
not an alternative. ADR-0002 is reserved by the earlier unmerged stack proposal;
its number is not reused and this record does not accept it.

## Decision

Adopt the bounded [closed-alpha review exception](../governance/documentation-policy.md#closed-alpha-review-exception)
as approved in PR #12. For explicitly approved private test-data alpha scope,
independent fresh-context AI review can replace the SECOND human reviewer only.
Human decision-owner acceptance, RFC/ADR lifecycle, E2EE, threat analysis, actual
tests and explicit deployment authorization remain required. Before sensitive
communication, public release, production/security/privacy claims or expansion
outside the approved private test scope, independent qualified human review
remains required. This accepts no application architecture or deployment.

## Review rationale and evidence

This is a governance-process decision, not an identity/crypto/storage/stack
adoption. Human decision owner martadvix-web approved the exact bounded change
and authorized merge after evidence and checks. No second human was assigned;
that absence is explicit, not represented as an approval. The independent AI
report is PR #12 comment 5580637163; it found no blocking issues, but is advisory
and is not a human security audit. Reviewer/model identity beyond the isolated
Hermes context was not exposed by the runtime.

Permanent human approval is recorded in front matter, from the owner's GitHub
comment on 2026-09-08. Telegram text is provenance only, not the approval record.
This accepted record becomes normative only when this exact revision is merged.

## Consequences, validation and rollback

The actual team can develop a bounded alpha without fictional human credentials.
AI reviewers can share blind spots; the owner accepts that residual process risk
only within the documented scope. No failed test or blocking security finding is
waived. Markdown, links, approval provenance and independent-context review check
this documentation change; no runtime tests apply to it. Application tests remain
separate deliverables, not claims made by this ADR.

Publish policy, AGENTS, contribution rules, templates and RFC disposition together.
A future policy reversal requires a new decision and a PR; it cannot make alpha
code retrospectively audited. Historical accepted decisions are not rewritten.

## Links

- [RFC-0007](../rfcs/0007-closed-alpha-review-policy.md)
- [Threat model](../security/threat-model.md): security objectives remain unchanged.
- [ADR-0001](0001-documentation-as-code.md): documentation-as-code.
- Requirements: governance-only change; no new product requirement.
