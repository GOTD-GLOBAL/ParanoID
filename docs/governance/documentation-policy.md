---
status: accepted
owner: maintainers
last_reviewed: 2026-08-09
---

# Documentation policy

## Objective

At any project stage, a new developer, reviewer, operator, auditor, or AI agent
must be able to determine:

- what the system is intended to do;
- what it actually does now;
- why important decisions were made;
- which contracts must remain compatible;
- where trust boundaries and known risks exist;
- how to build, test, deploy, observe, recover, and change it safely.

## Documentation as code

Canonical documentation is versioned with the code it describes. It is reviewed
in the same pull request, rendered from text where practical, and checked by
automation. Chat messages, meetings, issue comments, and external presentations
are inputs, not durable sources of truth.

## Sources of truth

Different artifacts answer different questions:

| Question | Canonical artifact |
| --- | --- |
| Why was a durable choice made? | Accepted ADR |
| What is being proposed? | RFC |
| What must the product do? | Versioned requirement |
| What contract must implementations follow? | Protocol/API/schema specification |
| What is implemented and verified now? | Code and automated tests |
| What is usable or deployed now? | Current-state document and release record |
| How is the system operated safely? | Runbook |
| What can go wrong and where is trust placed? | Threat model |

Contradictions between these artifacts are defects. Report and resolve them in
the same change; do not hide them behind precedence rules.

## Required metadata

Durable documents use YAML front matter with `status`, `owner`, and
`last_reviewed`. Draft templates may use placeholders. Generated references must
identify their generator and source revision.

## Decision hygiene

- An ADR captures one decision, its context, options, trade-offs, consequences,
  and verification method.
- Accepted ADRs are append-only historical records. Supersede rather than rewrite.
- An RFC is temporary design discussion and may change until accepted or closed.
- The decision log links the accepted ADR produced by a successful RFC.
- Rejected options remain documented when they explain important trade-offs.

## Traceability

Requirements receive stable identifiers. Pull requests and tests reference the
identifiers they satisfy. Public contracts declare versions. Breaking changes
include migration and rollback documentation before merge.

## Freshness

- Review changed documents in every relevant pull request.
- Review security and architecture documents at each release milestone.
- Review `current-state.md` at least monthly during active development.
- Review runbooks through exercises, not editorial inspection alone.
- A reviewer may block a change because documentation is misleading, even if the
  code works.

## Automation

CI checks Markdown structure and links. As the stack is selected, add checks that
compare generated API/protocol references, schemas, database migrations, CLI help,
configuration examples, and architecture rules against their sources.

Automation can detect drift but cannot decide whether an explanation is useful.
Human review remains required.

## Security and privacy

Never place secrets, private keys, seed phrases, production personal data,
vulnerability details under embargo, or customer-confidential material in the
repository. Use synthetic examples. Mark security assumptions and unsupported
claims explicitly.

## Canonical language and translations

English is the canonical language for technical and governance documentation.
Translations link to the canonical file and record the source revision. If a
translation conflicts with the canonical document, the conflict must be fixed;
the translation does not create a new requirement.
