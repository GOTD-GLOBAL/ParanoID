# Changelog

All notable changes to ParanoID will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/).
The project will adopt [Semantic Versioning](https://semver.org/) when its first
public contract is declared.

## [Unreleased]

### Fixed

- Independent registration replay exposed intermittent decoding of pristine
  public grant QR images. The ZXing adapter now retains camera detection first,
  then tries its pure-image decoder on reader failure. A deterministic 200-grant
  regression runs in every APK build; typed credential checks remain unchanged.

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

- Migration-capable isolated Linux key-registration package: exact offline schema
  transition after verified restore, retained TLS/config/history, key-aware
  readiness and compatible code rollback. Process ownership now survives PG
  lock-backend loss; TLS keep-alive/idle occupancy is bounded. Populated native
  systemd/PostgreSQL/TLS/JNI tests pass; live cutover and phone acceptance are
  recorded separately, not inferred from local results.

- Local Android key-registration candidate (`org.paranoid.devtext`, 0.0.4-dev,
  versionCode 4): persisted independent root/device keys, exact-slot operator
  grants, automatic one-use key login, typed verified QR contacts and existing
  Olm text/receipts. Real isolated TLS/PostgreSQL/JVM JNI and populated v0
  preservation/restore tests accompany the signed ARM64 APK. No live migration,
  deployment, physical OPPO test or production architecture acceptance is claimed.

- Draft RFC-0010, proposed ADR-0006 and a key-enrollment contract clarify the
  requested phone-created identity/automatic proof/verified QR UX versus the
  existing manual bearer fixture. Recommended two-tester exact-key admission
  preserves legacy identities/history; the subsequent local candidate above
  implements the bounded flow without accepting the proposed ADR.
  Sergey accepts the one-time operator step as bounded Telegram UX input, not ADR
  or deployment approval. Canonical requirements retain future default/own/existing
  server selection and QR/link/store invitation UX, with independent trust and an
  explicit unverified deferred-link/fallback boundary; no alpha scope expansion.

- Authorized target-host rollout and resume: after an initially blocked attempt,
  explicit owner authorization allowed one precise IPv4 UFW TCP 38443 rule and
  retained-service/linger resume. External pinned TLS and negative pin/auth checks,
  Linux JVM Android TLS adapter, final-unit restart/crash recovery, and disposable
  history/restore tests pass. Original identities/data and neighboring services
  are preserved; physical OPPO acceptance remains unrun.

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
