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

# Documentation map

This is the entry point and navigation contract for ParanoID documentation.

## Project and product

- [Current state](project/current-state.md): what exists now, what does not, and
  the next decision gates.
- [Vision](product/vision.md): intended users, value, and product boundaries.
- [Requirements](product/requirements.md): traceable product requirements and
  open acceptance criteria.
- [Glossary](product/glossary.md): canonical project vocabulary.

## Architecture and decisions

- [Architecture map](architecture/README.md): C4 views and architecture scope.
- [Architecture principles](architecture/principles.md): constraints that guide
  design work.
- [Quality attributes](architecture/quality-attributes.md): measurable scenarios
  used to compare designs.
- [Decision log](decisions/README.md): accepted and superseded ADRs.
- [RFC process](rfcs/README.md): proposals under discussion.

## Contracts and operations

- [Protocol documentation](protocol/README.md): wire formats, state machines,
  federation, and compatibility.
- [API documentation](api/README.md): machine-readable and human-readable APIs.
- [Operations](operations/README.md): deployment, upgrades, backups, observability,
  incidents, and recovery.
- [Threat model](security/threat-model.md): assets, actors, boundaries, and threats.

## Documentation by reader need

As content grows, classify developer, administrator, and user documentation using
the Diataxis model:

- `tutorials/` for guided learning;
- `how-to/` for task-oriented instructions;
- `reference/` for exact facts and contracts;
- `explanation/` for concepts and trade-offs.

Do not mix these purposes in a single document without a clear reason.

## Governance

- [Documentation policy](governance/documentation-policy.md)
- [External standards and methods](references.md)
- [Contributing rules](../CONTRIBUTING.md)
- [AI agent rules](../AGENTS.md)
- [Security policy](../SECURITY.md)

## Status vocabulary

Every durable design or governance document should include metadata:

- `draft`: incomplete and non-normative;
- `proposed`: ready for decision or review;
- `accepted`: normative until superseded; reserved for artifacts that are sources
  of truth, including ADRs, requirements, policies, and specifications;
- `deprecated`: retained for context but should not guide new work;
- `superseded`: replaced by a linked document.

Proposal processes may also use terminal, non-normative states:

- `completed`: review concluded and any accepted decision is recorded elsewhere;
- `rejected`: reviewed but not selected, with the reason preserved;
- `withdrawn`: closed by the author without a decision.

An RFC never uses `accepted`: even a completed RFC remains proposal history. Only
a linked accepted ADR makes an architecture decision normative. Artifact-specific
process documents define which subset of this vocabulary is valid.

`last_reviewed` describes when the document was checked against reality, not when
its spelling was last edited.
