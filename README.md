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
Linux test runner. It is not a deployed messenger or two-phone application.

## Working principle

Code, specifications, tests, diagrams, decisions, and operational instructions
must evolve together. A change is not complete when its documentation is stale.

The previous experimental prototype is preserved separately in the private
`GOTD-GLOBAL/ParanoID-legacy` repository.
