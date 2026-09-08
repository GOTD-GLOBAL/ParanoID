# Changelog

All notable changes to ParanoID will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/).
The project will adopt [Semantic Versioning](https://semver.org/) when its first
public contract is declared.

## [Unreleased]

### Added

- Development Android/Rust text-client code with peer-pinned Olm, encrypted local
  snapshots and explicit self-signed HTTPS SPKI pinning for IP-based connections.
  Local TLS/JVM/packaging checks pass; connected OPPO acceptance and hosted rollout
  remain blocked by the documented client/runtime and deployment gates.

- Development-only Rust/PostgreSQL HTTP transport with durable opaque-envelope
  acceptance, idempotent retries, recipient cursor sync, bounded non-evicting
  storage and real HTTP/database tests. No phone messaging or hosted deployment
  is delivered by this increment.

- Experimental ARM64 Android native crypto diagnostic with a local synthetic
  exchange and tamper/replay checks; no networking or production security claim.

- Draft single-server text contract and acceptance matrix for two OPPO phones:
  durable server/recipient delivery indicators, retained ciphertext history,
  reconnect, key-loss limits and future iPhone boundaries. No messenger shipped.
- Reproducible dependency-only server stack compilation probe; not a runtime
  server or accepted architecture.

- Owner-approved bounded closed-alpha review-policy exception (ADR-0003),
  effective on merge. E2EE, human decision ownership and the external
  security-review gate for sensitive/production use remain required.

- Initial documentation governance, project map, decision process, security
  threat-model skeleton, and contribution workflow.
- Explicit RFC closure states and human authority and evidence requirements for
  accepting ADRs.
