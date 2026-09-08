---
status: completed
owner: maintainers
decision_owner: martadvix-web
decision_deadline: 2026-09-08
required_reviewers: []
last_reviewed: 2026-09-08
---

# RFC-0007: Bounded closed-alpha review policy

## Summary and required review rationale

The founder reports no independent qualified human reviewer and authorizes
removing the mandatory second-human gate after discussion of closed-alpha
controls. Recommend a bounded exception for private test-data development, not
a permanent removal of human security review or human decision authority.

This is a governance proposal, not adoption of identity, E2EE, protocol, storage,
stack or deployment decisions. The human decision owner remains martadvix-web.
No independent human reviewer is assigned for this governance proposal; owner
approval is required. This revision is non-normative until approved and merged.

## Motivation and provenance

An unconditional second-human gate prevents the actual team from developing the
first single-server/two-OPPO slice. Pretending an AI is human would falsify evidence.
The existing RFC-0006 in PR #11 remains an unaccepted application proposal.

Exact latest Telegram instruction: "Я разрешаю отменить обязательный человеческий
ревью автоматически". This is recorded as source input, not verified GitHub
approval. The tool context does not expose a stable original Telegram permalink,
message ID or authenticated GitHub identity mapping. Owner confirmation on GitHub
is necessary under the existing durable-evidence policy. Do not reuse the older
PR #11 scope comment as approval of this policy change.

## Proposed decision

Use the [closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception)
for explicitly scoped private test-data development. It substitutes an independent
AI review plus owner risk acceptance for the second human reviewer only. The AI
is never described as human, qualified human approval or a cryptographic audit.

Preserve RFC/ADR lifecycle, human owner approval, threat modelling, E2EE, tests,
traceability, secret-handling controls and explicit rollout authorization. An
exception does not approve any application design or automatically merge anything.
Do not backdate acceptance or rewrite historical approval evidence.

## Alternatives

- Keep the unconditional second-human gate: strongest independent-human process,
  but unavailable to the current team.
- Remove all human review permanently: not recommended; unacceptable unbounded
  risk and contrary to retaining human decision authority.
- Call the assistant a human reviewer: false provenance, explicitly prohibited.

## Risks, validation and rollback

Independent-context AI review can share model blind spots and is not equivalent
to specialist review. Residual risk is accepted by the named human owner for a
specific scope, not silently transferred to users. Require an independent human
security review before real sensitive use or promotion outside the exception.

Validate all policy references, Markdown and links. Review concrete negative
cases: production claim, real sensitive data, self-review, invented owner approval,
missing tests, unresolved security finding and unsigned scope expansion must not
qualify. Reverting the policy does not retrospectively claim alpha code was audited;
suspend exception-dependent work and review it under the restored rules.

## Disposition

- Status: completed; owner approved the bounded policy change on 2026-09-08.
- Approval: [owner GitHub comment](https://github.com/GOTD-GLOBAL/ParanoID/pull/12#issuecomment-5581548687).
- Independent AI review: PR #12 comment 5580637163; no blocking findings.
- Resulting ADR: [ADR-0003](../decisions/0003-closed-alpha-review-policy.md).
- Closure rationale: owner disposition recorded; policy becomes normative on merge.
- Implementation impact: application designs still require their own disposition.
- Merge authorization: owner approval comment above explicitly authorizes PR #12
  after evidence and checks. No application deployment is authorized.
