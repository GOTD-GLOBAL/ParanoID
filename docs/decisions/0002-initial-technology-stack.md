---
status: accepted
owner: architecture
last_reviewed: 2026-08-11
---

# ADR-0002: Adopt the initial implementation stack

## Context and problem statement

ParanoID needs an implementation foundation for its first identity vertical
slice. The legacy Node/Fastify and Android prototype is research material, not a
current architecture. A durable choice is required for the server, mobile
clients, database, identity reference behavior, and proposed Solana program.

## Decision drivers

- Security-critical identity and protocol implementation.
- Android and iOS support under `REQ-CLIENT-001`.
- Efficient self-hosting under `REQ-DEPLOY-001`.
- Solana program compatibility without making all application code blockchain
  code.
- Future WebSocket, federation, media, and extension workloads.
- Deterministic specifications and conformance tests.
- Operational simplicity during inception.

## Considered options

1. Rust/Axum server, PostgreSQL, Kotlin Multiplatform clients, and Rust/Anchor.
2. Kotlin/Ktor server, PostgreSQL, and Kotlin Multiplatform clients.
3. TypeScript/Fastify server and React Native clients.
4. Rust server and Flutter clients.

## Decision

Adopt Rust with Tokio, Axum, Tower, SQLx, and PostgreSQL for the initial modular
monolith; Kotlin Multiplatform with Compose Multiplatform for Android and iOS;
a Rust identity reference crate; and Rust with Anchor for the proposed Solana
identity-registry prototype. Use contract-first HTTP/OpenAPI and introduce
WebSocket contracts only when required by a vertical slice.

Do not introduce initial microservices, Redis, a message broker, a full Solana
node, or a PARA token without separate evidence and decisions.

## Consequences

### Positive

- The server, identity reference, and Solana program share Rust expertise and
  tooling.
- Android and iOS can share product logic and UI while retaining native escape
  hatches.
- PostgreSQL provides a mature transactional persistence baseline.
- A modular monolith minimizes initial deployment and failure complexity.
- Explicit contracts preserve replacement and extraction paths.

### Negative

- The project must maintain both Rust and Kotlin expertise.
- Rust compilation and cross-platform mobile integration add build complexity.
- Some iOS integrations still require Swift and Apple tooling.
- The stack does not reuse the legacy application implementation directly.

### Risks and mitigations

- **The mobile/native boundary becomes fragile.** Validate it with a narrow
  identity spike before committing protocol behavior to that boundary.
- **Rust slows early feature delivery.** Keep a modular monolith, maintain small
  reviewable crates, and measure delivery during the first vertical slice.
- **Framework selection is mistaken for security.** Require threat modelling,
  reviewed primitives, conformance vectors, and independent security review.
- **Dependency churn harms reproducibility.** Pin toolchains and dependencies,
  retain lockfiles, and update them through tested changes.
- **Shared UI harms platform fidelity.** Permit native screens and integrations
  when physical-device evidence justifies them.

## Validation

- The initial scaffold builds and tests on supported developer and CI platforms.
- Android and iOS applications execute an identical signing test vector on
  physical devices.
- The server runs identity conformance tests against PostgreSQL.
- The Anchor prototype passes local-validator and Devnet integration tests.
- A supported deployment passes install, backup, restore, upgrade, and rollback
  exercises before release claims are made.

## Compatibility and migration

There is no current application or public contract to migrate. The legacy
prototype remains separate. Any future replacement of a foundational component
requires a superseding ADR and contract compatibility evidence.

## Links

- Requirements: `REQ-ID-001` through `REQ-ID-004`, `REQ-CLIENT-001`,
  `REQ-DEPLOY-001`, `REQ-SEC-001`
- RFC: [RFC-0001](../rfcs/0001-initial-technology-stack.md)
- Threat model: [Threat model](../security/threat-model.md)
- Experiment or benchmark: pending initial scaffold and identity spike
- Supersedes: none
- Superseded by: none
