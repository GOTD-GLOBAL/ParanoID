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

## Invariant and scope gates

Before implementation, migration, dependency/schema/API/config changes, or review:

1. Record the repository, branch, HEAD, worktree status, issue/task, and one-sentence intent.
2. Name every affected requirement ID, accepted ADR, contract, security boundary,
   and protected decision domain. Memory and old discussions are discovery aids,
   never substitutes for repository evidence.
3. Locate the current implementation and tests. For legacy or unexplained behavior,
   inspect commit history, blame, the introducing change, and related PRs/issues.
4. Map each critical invariant to an executable unit, contract, protocol, migration,
   architecture, or security check. Do not weaken an existing check to make a change pass.

After implementation and before a PR is ready, compare the complete diff with the
stated intent and affected IDs. Inspect unrelated paths/subsystems, dependencies,
public API/schema/config/CI/deployment edits, generated or format-only files, renames,
and oversized hunks. Classify each suspicious item as:

- `keep` — directly required by the task;
- `split` — independently landable and moved to another PR;
- `justify` — inseparable and required by a named invariant or build constraint.

Prefer `split` when the relationship is ambiguous. The reviewer repeats this analysis
independently. A PR with unexplained scope drift is not ready. Record the affected IDs,
real verification output, migration/rollout/rollback impact, and scope status (`clean`,
`justified`, `requires split`, or `violated`) in the review evidence.

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

An RFC or ADR and independent qualified human review are required for every
[protected decision domain](docs/governance/documentation-policy.md#protected-decision-domains).

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
