---
status: accepted
owner: maintainers
decision_owner: martadvix-web
approved_change: bounded second-human review exception for private test-data alpha
approval_date: 2026-09-08
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/12
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/12#issuecomment-5581548687
last_reviewed: 2026-09-08
---

# Instructions for AI agents

These instructions apply to every AI system working in this repository.

## Required reading order

Before changing anything:

1. Read `README.md`.
2. Read `docs/README.md` and `docs/project/current-state.md`.
3. Read `CONTRIBUTING.md`.
4. Read every accepted ADR and requirement relevant to the proposed change.
5. Read the relevant security, protocol, API, architecture, and operations
   documents.

Do not infer the current system from issue titles, old discussions, or the
legacy repository. The legacy repository is evidence and research material,
not the architecture of this project.

## Documentation contract

- Treat documentation changes as part of implementation, not follow-up work.
- Never describe planned behavior as implemented behavior.
- Mark assumptions, unknowns, and unresolved decisions explicitly.
- Do not invent product or architecture decisions to fill gaps.
- Use stable requirement identifiers when connecting requirements, code, tests,
  RFCs, and ADRs.
- Update `docs/project/current-state.md` whenever a capability, project phase,
  major risk, or accepted decision changes.
- Update `CHANGELOG.md` for notable user-facing or operator-facing changes.
- Update the threat model for changes involving identity, cryptography,
  authorization, metadata, federation, plugins, payments, storage, recovery,
  or deployment trust boundaries.
- Update protocol or API specifications before or with contract changes.
- Keep diagrams as text in the repository whenever practical.
- Use ISO 8601 dates in `YYYY-MM-DD` form.

If implementation, tests, specifications, or accepted decisions disagree, stop
and report the discrepancy. Do not silently choose one as the truth.

## Decisions

Use an RFC while a significant design is being discussed. Create a `draft` or
`proposed` ADR before disposition, then mark it `accepted` only after the required
human approval is recorded. An accepted ADR is historical evidence: do not rewrite
its decision. Correct minor errors transparently or supersede it with a new ADR.

RFCs are never normative and never use `accepted`; close a successful RFC as
`completed` and link the accepted ADR. An AI review, CI result, merge permission,
or bot-executed merge is not decision approval. Before marking an ADR `accepted`,
verify the human decision owner, required domain reviews, and approval evidence
defined in `docs/governance/documentation-policy.md`.

An RFC or ADR and the canonical review process are required for every
[protected decision domain](docs/governance/documentation-policy.md#protected-decision-domains).
Independent qualified human review is the default. Only the explicit
[closed-alpha exception](docs/governance/documentation-policy.md#closed-alpha-review-exception)
may substitute independent AI review for the second human. It never removes human
decision-owner approval, E2EE, tests, threat analysis or deployment authorization.
Do not apply a proposed policy revision before its approval and merge.

## Definition of done

Before calling work complete, verify that:

- the implementation matches the documented requirement and accepted decision;
- relevant tests and security analysis were updated;
- impacted reference, explanation, how-to, and operational docs were updated;
- links and Markdown checks pass;
- the PR explains documentation impact, migration, rollout, and rollback;
- unresolved risks and follow-up work are visible, not hidden in chat context.

## Handoff format

At the end of a substantial task, leave a concise handoff containing:

- objective and actual outcome;
- files and contracts changed;
- requirements, RFCs, and ADRs involved;
- checks performed and their results;
- remaining risks, assumptions, and exact next step.

User instructions take precedence. When a user makes a durable product or
architecture decision, record it in the appropriate repository document as part
of the same change.
