---
status: accepted
owner: maintainers
last_reviewed: 2026-08-09
---

# ADR-0001: Use documentation as code

## Context and problem statement

ParanoID is intended to attract external developers, reviewers, operators, and AI
systems while evolving across messaging, federation, cryptographic identity,
plugins, enterprise workflows, and AI. Knowledge retained only in chats or in the
founder's memory would make onboarding slow and security review unreliable.

## Decision drivers

- New contributors must reconstruct current intent and implementation quickly.
- Security-sensitive choices need durable rationale and traceability.
- Documentation must change atomically with code and remain reviewable offline.
- The open-source project needs vendor-independent, searchable source files.
- International contributors need one canonical technical language.

## Considered options

1. Documentation as versioned Markdown, diagrams, schemas, and generated reference
   beside code.
2. A separate hosted wiki or knowledge-base product as the canonical source.
3. Informal issue, chat, and meeting history with occasional summaries.

## Decision

Use documentation as code in the same Git repository as implementation. Use
English as the canonical language for technical and governance documentation.
Organize reader-facing documentation by need, preserve important decisions as
ADRs, discuss significant proposals as RFCs, and enforce documentation checks in
pull requests.

External tools may render, search, or discuss the documents, but repository files
remain canonical. Translations are derived artifacts and identify their source
revision.

## Consequences

### Positive

- Documentation and implementation can be reviewed and reverted together.
- History exposes when and why a contract changed.
- Plain text is searchable, diffable, portable, and accessible to humans and AI.
- Onboarding and external review have a predictable starting path.

### Negative

- Every meaningful change carries documentation work.
- Maintainers must actively prevent stale or ceremonial documents.
- Non-technical stakeholders may need rendered views or editing assistance.
- English-only canonical content creates translation work for some audiences.

### Risks and mitigations

- **Documentation drifts from code.** Require same-PR updates and add automated
  contract checks as executable specifications appear.
- **The repository becomes a document graveyard.** Maintain a single map, explicit
  owners, status metadata, review dates, and deletion/supersession rules.
- **AI produces confident but fictional documentation.** Require traceability,
  explicit unknowns, and human review of durable decisions.

## Validation

- A newcomer can follow `README.md` to current state, requirements, architecture,
  decisions, security, and contribution rules without external chat history.
- Pull requests explicitly report documentation impact.
- Markdown and links are checked in CI.
- Architecture and security reviews can trace claims to requirements and tests.

## Compatibility and migration

The previous prototype remains in `ParanoID-legacy`. Information brought forward
must be reviewed and rewritten as current evidence or decisions; old documents are
not copied wholesale.

## Links

- [Documentation policy](../governance/documentation-policy.md)
- [Documentation map](../README.md)
- [Diataxis](https://diataxis.fr/)
- [C4 model](https://c4model.com/)
- [Architectural Decision Records](https://adr.github.io/)
