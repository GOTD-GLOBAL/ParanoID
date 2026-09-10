# Changelog

All notable changes to ParanoID will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/).
The project will adopt [Semantic Versioning](https://semver.org/) when its first
public contract is declared.

## [Unreleased]

### Incoming-call diagnostics — 2026-09-10

- Added test-only controller-first sampling and bounded sanitized SDK/host
  observations. One ordinary baseline failed naturally while its fixed companion
  decoded relay audio; [evidence and remaining unknowns](docs/project/evidence/call-connect-ordinary-20260910/README.md)
  keep CALL-CONNECT01 open. Production source and APK are unchanged.

### Voice relay client — 2026-09-10

- Added strict, volatile relay credential retrieval before media creation, with
  bounded independent I/O and generation-safe cancellation. Call and Answer now
  disclose relay/direct metadata before consent. Signed v10 builds and preserves
  owned-emulator v9 identity/contact/history. Parser, HTTPS/JNI and text checks
  pass; full extension acceptance, final review and missing relay packet gates
  remain explicit in [the local record](docs/operations/voice-calls-local.md).
- Added a reviewed500 ms relay-candidate publication window to prevent unrelated
  gathering delays consuming nearly the entire45-second call setup deadline.
  Actual both-role relay, cancellation/redial, late-callback, direct tone and
  rebuilt-artifact checks pass. Direct mode and authenticated immutable SDP
  retain their existing contracts; missing relay runtime gates remain explicit.

### Voice relay foundation — 2026-09-10

- Added an optional signed-session TURN credential issuer with locked active-device
  checks and bounded quotas. Disabled deployments retain existing messaging
  behavior. A versioned offline package adds isolated secret-file forwarding,
  a patched coturn build and a separate relay unit; [the runbook](deploy/turn/README.md)
  records actual offline checks and missing expiry/ACL packet gates. No live
  server, firewall, DNS, phone or public listener changes were performed.

### Voice implementation checkpoint — 2026-09-09

- Added native authenticated 1:1 call controls on the retained Olm channel,
  Android answer/reject/cancel/mute/routing lifecycle, microphone foreground
  service and pinned WebRTC/Opus integration. Calls retain core3/sealed4 identity,
  history and TLS trust. Fresh design closure and native/JNI/controller checks
  pass, including actual v8 text/receipt continuation and 3700 encrypted controls
  without exhausting the text replay ledger. Real Android/aiortc direct and local
  TURN relay audio pass decoded-tone, mute/unmute and teardown checks. [Exact
  evidence and remaining gates](docs/operations/voice-calls-local.md) record 14 app acceptance steps passing, with final inset UI
  and signed voice APK checks passing; independent final review remains pending. No new live listener,
  server change, physical-phone test or production quality claim is included.

### Realtime rollout — 2026-09-09

- Updated the existing isolated private-alpha service from release
  `346f059914a290be4851` to `3ed25173ad978e6b417c` after independent final Fable
  review and bounded closure. The attended `update-v2` exited 0, retaining the
  current database, TLS/configuration/unit and scoped neighbors; its 22,140-byte
  encrypted backup passed authenticated restore and six-table/schema comparison.
  Final postflight and actual hosted product Java/JNI first-contact, reply,
  receipt and reconnect checks passed. Twelve hosted sends measured P50 76.51 ms
  and P95 85.74 ms to durable receiver notification, not phone rendering.
- Built retained-signer ARM64 `org.paranoid.devtext` versionCode 8,
  `0.0.8-realtime`, with populated-v7 continuity and real Android emulator checks.
  The APK remains a private artifact; feed publication and physical-phone
  installation were not performed. The original intermittent packaged readiness
  failure remains unexplained, with the requested diagnostic and independent
  closure complete; it is not relabeled fixed. [Actual rollout and remaining
  limits](docs/operations/realtime-rollout-2026-09-09.md). Proposed ADRs remain
  unaccepted. The older deployment entry below retains its original scope.

### Deployed — 2026-09-09

- Installed the independently reviewed self-service-v2 release
  `346f059914a290be4851` on the existing isolated hosted alpha under the user's
  explicit live instruction. One-time old-data-only replacement exited 0 without
  backup/import; TLS/config-other-fields/unit/locks/backups/neighbors preserved.
  Existing enabled unit runs v2; external pinned HTTPS health reports
  `paranoid-self-service-v2`, controller SQL/TLS readiness passes and unauthenticated
  message/registration commits fail closed. [Actual rollout evidence](docs/operations/self-service-v2-rollout-2026-09-09.md).
  FPD-D01 documentation-only closure retains the historical pinned self-signed
  leaf and identical artifacts. Feed publication and phone installation/acceptance
  were not included; draft RFCs/ADRs remain unaccepted. This dated deployment
  supersedes earlier preparation-time pending-cutover wording below.

### Fixed

- FV2-R01: interrupted `replace-v2`, `fresh-v2` and `install-v2` operations
  now exit 130 with a static, redacted fail-stopped diagnostic, not false success.
  Real SIGINT regressions cover both sides of the scoped cluster discard and
  fresh initialization; no rollback, backup or retry is introduced. Graceful
  long-running `run` and legacy v0/v1 interrupt handling remain unchanged.

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

- Realtime private-alpha candidate: reused pinned TLS, short-lived signed sessions,
  bounded long polling and independent state/network work publish durable text
  before receipt I/O. Native messenger screens and optional visible background
  connection preserve delivered v7 identity/history. Same-v2 maintenance adds
  encrypted restore-verified backup and same-data rollback. Exact local evidence,
  completed reviewed rollout and remaining limitations are in the
  [overnight runbook](docs/operations/overnight-realtime.md); no permanent ADR
  acceptance is implied.

- Clean-install first-contact client path (RFC-0014/REQ-MSG-005): every new text
  and delivery receipt uses a deterministic signed account-ID channel; unknown
  valid senders appear immediately with unverified identity and reply enabled.
  Immutable pins, transactional rejection, bounded peers/block and clean core3/
  snapshot4 persistence accompany the candidate. Unsupported older snapshots
  are preserved and refused; historical migration/recovery is outside this
  owner-selected build gate, with historical failures reported separately.
  Local test/build status is in `docs/operations/clean-first-contact-local.md`;
  publication, phone delivery and live actions remain excluded pending review.

- RFC-0013 local server update distribution: bounded read-only Android metadata
  and digest-named APK routes, with actual hash/size and safe-file checks. Only
  the v2 controller selects `ROOT/updates`; it creates/publishes nothing and
  leaves legacy environments unchanged. Combined-package review, publication
  authorization and Android installer acceptance remain separate gates.

- Fresh-only v2 Linux deployment candidate: explicit exact-reviewed IPv4:38443
  TLS, eight-member optional bundle, fresh install/schema/readiness, and stopped
  one-shot old-server-cluster replacement without migration or backup. Retains
  TLS, config IP/other values and phone state; sticky v2 blocks historical
  controller operations. [Scoped owner correction and runbook](docs/operations/fresh-self-service-v2.md).
  Independent review and coordinator cutover remain pending; no live deployment.

- Local self-service v2 server candidate for issue #16: automatic device-proof
  registration without grants, versioned one-use request authentication, general
  account/device/conversation storage, recipient cursor sync and commit-ordered
  exact retries under non-evicting quotas. Offline migration preserves verified
  legacy bindings/history and revocation, with historical startup/downgrade guards.
  Original runtime is loopback TLS/private PostgreSQL; the later fresh-only
  deployment candidate above is separate and still makes no hosted change. Draft [ADR-0007](docs/decisions/0007-self-service-messenger.md),
  [RFC-0012](docs/rfcs/0012-self-service-messenger.md),
  [wire contract](docs/protocol/self-service-v2.md) and
  [threat/test matrix](docs/security/self-service-v2-threats.md) accompany it.
  Independent local evidence: 19 targeted / 43 full server tests and external
  Python Ed25519/TLS/PostgreSQL probes passed. SR-01 documentation re-review,
  architecture disposition, client/phone acceptance and v2 deployment remain open.

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
