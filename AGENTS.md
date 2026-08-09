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

Use an RFC while a significant design is being discussed. Create an ADR when a
decision is accepted. An accepted ADR is historical evidence: do not rewrite its
decision. Correct minor errors transparently or supersede it with a new ADR.

An RFC or ADR is required for changes to:

- identity, key derivation, recovery, or blockchain integration;
- cryptographic algorithms or end-to-end encryption semantics;
- federation and protocol compatibility;
- persistence formats, event models, or public APIs;
- plugin permissions and isolation;
- the primary stack or a foundational dependency;
- security boundaries, trust assumptions, or data retention;
- deployment topology or backward compatibility.

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
