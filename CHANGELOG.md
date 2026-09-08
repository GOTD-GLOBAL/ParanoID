# Changelog

All notable changes to ParanoID will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/).
The project will adopt [Semantic Versioning](https://semver.org/) when its first
public contract is declared.

## [Unreleased]

### Fixed

- Native alpha rebuilds now use fresh private output and an exact regular-file
  allowlist, preserving ignored/stale operator files without shipping them.
  Lifecycle operations reject redirected or unsafe installation paths, invalid
  configuration and unconfined releases before writes or service stops.
  Native package/containment and non-systemd PG/TLS lifecycle tests now run in CI.

- Rejected/capacity-deferred client events no longer indefinitely stall later
  messages or authenticated receipts; failed crypto state is discarded and
  bounded rejection/progress metadata is persisted visibly.
- Outbound 409/507 failures retain exact retry bytes without blocking inbound
  processing or later outbox entries. Local storage uncertainty still stops all
  operations. Regression tests cover the failure paths.

### Added

- Authorized target-host rollout evidence: verified package/native restore tests
  and host-local TLS/database health passed, but external 38443 timed out with
  default-deny UFW and no allow rule. The new unit was stopped/disabled and linger
  reverted without changing the firewall or neighboring services. Private state
  is retained; external endpoint and phone acceptance remain unfulfilled.

- Native Linux private-alpha package: locked release artifact, explicit direct TLS
  on 38443, isolated PostgreSQL 16, systemd user enable/restart, authenticated DB
  readiness, verified local backup restore and history-preserving code rollback.
  Local real-process tests pass; no production host change or phone test occurred.

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
