---
status: accepted
owner: maintainers
last_reviewed: 2026-08-09
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
- `accepted`: normative until superseded;
- `deprecated`: retained for context but should not guide new work;
- `superseded`: replaced by a linked document.

`last_reviewed` describes when the document was checked against reality, not when
its spelling was last edited.
