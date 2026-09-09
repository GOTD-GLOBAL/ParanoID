# ParanoID

ParanoID is a new, privacy-first messenger project in its inception phase.
The application is being designed as an open-source, self-hostable system with
optional federation, crypto-native identity, mobile clients, and an extension
platform for commercial and enterprise capabilities.

> The repository contains project documentation, isolated Android diagnostics
> and a development-only server transport. No production application architecture
> or technology stack has been accepted yet.

## Start here

Read these documents in order before proposing or implementing changes:

1. [Current project state](docs/project/current-state.md)
2. [Product vision](docs/product/vision.md)
3. [Documentation map](docs/README.md)
4. [Contributing rules](CONTRIBUTING.md)
5. [Instructions for AI agents](AGENTS.md)

## Executable development checks

[Server transport](server/README.md) includes real HTTP/PostgreSQL tests and a
Linux test runner. The [native Linux alpha package](docs/operations/linux-alpha-deployment.md)
adds direct TLS, isolated data and lifecycle tooling. The authorized
[hosted alpha](docs/operations/linux-alpha-rollout-2026-09-08.md) is externally
reachable with pinned TLS; two-phone acceptance remains unrun.

## Overnight realtime candidate

The [overnight operations record](docs/operations/overnight-realtime.md) describes
version8 native messenger UI, measured realtime E2EE, v7 continuity and the scoped
existing-service update. It records build/review/deployment evidence separately.
This current task supersedes the older no-live-action scope below only after its
mandatory review and rollback gates pass.

## Clean-install first-contact candidate

The owner's 2026-09-09 amendment prioritizes automatic registration and immediate
E2EE text/reply for a receiver with zero contacts. The [local candidate record](docs/operations/clean-first-contact-local.md)
tracks actual tests and the retained-signer APK; [RFC-0014](docs/rfcs/0014-first-contact-incoming.md)
and the [protocol](docs/protocol/first-contact-v1.md) define the mandatory signed
account-ID channel. Historical migration/recovery is outside this candidate's
release gate, with existing failures reported separately. Independent code review
precedes publication/delivery; this task performs no live or phone action.

## Working principle

Code, specifications, tests, diagrams, decisions, and operational instructions
must evolve together. A change is not complete when its documentation is stale.

The previous experimental prototype is preserved separately in the private
`GOTD-GLOBAL/ParanoID-legacy` repository.
