# Contributing to ParanoID

ParanoID is security-sensitive infrastructure. Small, reviewable, traceable
changes are preferred over large batches of code with undocumented assumptions.

## Before writing code

1. Read the project state and relevant requirements.
2. Search accepted ADRs and open RFCs for related decisions.
3. Identify security, privacy, compatibility, deployment, and migration impact.
4. Open an RFC before implementing an architecturally significant change.

Use requirement identifiers such as `REQ-ID-001` in design documents, tests,
and pull requests. A pull request must not create a new requirement implicitly.

## Documentation types

Use the following form for the reader's actual need:

- **Tutorial**: guided learning for a newcomer.
- **How-to guide**: steps for completing a specific task.
- **Reference**: exact contracts, schemas, configuration, APIs, and facts.
- **Explanation**: rationale, concepts, constraints, and trade-offs.

Architecture maps, ADRs, RFCs, threat models, requirements, and runbooks have
their own dedicated locations described in `docs/README.md`.

## When documentation must change

| Change | Required documentation |
| --- | --- |
| New user capability | Requirement, reference, tutorial/how-to as applicable, changelog |
| Public API or protocol | Versioned specification, compatibility notes, tests, changelog |
| Architecture or foundational dependency | RFC followed by ADR, C4 views, current state |
| Identity, crypto, federation, plugin, or payment boundary | RFC/ADR and threat model |
| Deployment or configuration | Reference, runbook, rollback procedure |
| Behavior change or bug fix | Affected reference and regression test; changelog if notable |
| Removed or deprecated behavior | Migration guide, compatibility policy, changelog |

If no documentation is needed, the PR must state why.

## Pull requests

- Keep one coherent change per pull request.
- Link the requirement, issue, RFC, and ADR where applicable.
- Describe risks, test evidence, rollout, rollback, and documentation impact.
- Do not merge with unresolved contradictions between code and documentation.
- Prefer diagrams and specifications that can be diffed in Git.
- Obtain security review for changes to protected boundaries.

## Versioning and changelog

Public contracts will use Semantic Versioning once the first public API or
protocol version is declared. Maintain `CHANGELOG.md` as a curated human-readable
record; it is not a copy of the commit log.

## Canonical language

Canonical technical and governance documentation is written in English.
Translations may be provided, but must identify the canonical source and its
revision. A translation cannot introduce requirements or decisions.
