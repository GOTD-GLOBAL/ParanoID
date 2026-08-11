---
status: draft
owner: product
last_reviewed: 2026-08-11
---

# Initial product requirements

These requirements capture founder intent for discovery. `Confirmed direction`
means the intent is explicit; it does not mean the acceptance criteria or design
are complete.

| ID | Requirement | State |
| --- | --- | --- |
| REQ-ID-001 | Account creation and authentication must not require a phone number or email address. | Confirmed direction |
| REQ-ID-002 | The initial paranoid-mode recovery model must be seed-only; losing the recovery words loses the account. | Confirmed direction |
| REQ-ID-003 | A human-readable username or nickname must be anchored in a blockchain registry. | Confirmed direction |
| REQ-ID-004 | Identity registration must have sustainable cost and abuse controls that do not allow unlimited founder-subsidized registrations. | Confirmed direction |
| REQ-ID-005 | Routine authentication should use separately revocable per-device authority instead of exposing or routinely using recovery authority. | Draft |
| REQ-ID-006 | A previously verified account and device should have explicitly bounded authentication behavior when public blockchain access is temporarily unavailable. | Draft |
| REQ-MSG-001 | The product must support text, images, files, video, audio, and voice messages. | Draft |
| REQ-CALL-001 | The product must support real-time audio and video communication. | Draft |
| REQ-CLIENT-001 | Supported end-user clients must include Android and iOS. | Confirmed direction |
| REQ-DEPLOY-001 | A non-specialist must be able to deploy a server through a guided, near one-click flow. | Confirmed direction |
| REQ-NET-001 | A server and its clients must support useful operation inside a local network without public internet. | Confirmed direction |
| REQ-FED-001 | Independently operated servers must be able to federate under explicit administrator policy. | Confirmed direction |
| REQ-MULTI-001 | A user must be able to connect to or participate through more than one server without creating an incoherent identity model. | Draft |
| REQ-EXT-001 | The platform must support modular extensions with explicit permissions and isolation. | Confirmed direction |
| REQ-ENT-001 | The commercial platform must support configurable enterprise messaging and CRM workflows. | Confirmed direction |
| REQ-AI-001 | AI capabilities must be optional, permissioned, and capable of using self-hosted inference in future deployments. | Draft |
| REQ-SEC-001 | End-to-end encryption scope and metadata guarantees must be specified and verified before any production privacy claim. | Required discovery gate |

## Acceptance criteria backlog

Each requirement must gain measurable acceptance criteria before implementation.
The first pass must define at least:

- supported offline and degraded-network scenarios;
- message delivery, ordering, synchronization, and retention semantics;
- device addition, loss, revocation, and seed recovery behavior;
- username uniqueness, registration, transfer, renewal, and dispute rules;
- federation discovery, authorization, abuse handling, and compatibility;
- plugin capability boundaries and user/admin consent;
- measurable self-hosting time, upgrade safety, backup, and restore objectives;
- mobile performance, accessibility, battery, and bandwidth targets.

## Proposed identity acceptance criteria

These criteria make the founder-confirmed identity direction testable. They
remain draft until the identity RFC is accepted.

### REQ-ID-001: No phone number or email address

- `REQ-ID-001-AC1`: A new user can create an identity, register a nickname,
  authorize the first device, and establish a server session without submitting
  a phone number or email address.
- `REQ-ID-001-AC2`: Authentication, refresh, device replacement, and paranoid-mode
  recovery do not depend on an SMS, email, external wallet application, or
  operator-controlled identity provider.
- `REQ-ID-001-AC3`: API schemas, database migrations, mobile analytics, and server
  logs contain no mandatory phone-number or email-address identity field.

### REQ-ID-002: Seed-only paranoid recovery

- `REQ-ID-002-AC1`: Starting from a clean supported client, the correct recovery
  words reconstruct the same account-root public key and registry authority.
- `REQ-ID-002-AC2`: The recovered account can authorize a replacement device and
  revoke a lost device without access to the old device or a server-owned secret.
- `REQ-ID-002-AC3`: Wrong, incomplete, or reordered recovery words cannot recover
  the account, and no administrator or support override exists in paranoid mode.
- `REQ-ID-002-AC4`: Recovery words and derived private root material never appear
  in protocol messages, logs, analytics, crash reports, or server persistence.

### REQ-ID-003: Blockchain-anchored nickname

- `REQ-ID-003-AC1`: A deterministic registry lookup on the selected Solana
  environment resolves a canonical nickname to the expected account-root public
  key and versioned status.
- `REQ-ID-003-AC2`: The server rejects registration or authentication when fresh
  required registry state conflicts with the presented account root.
- `REQ-ID-003-AC3`: Concurrent attempts to claim the same canonical nickname have
  one deterministic winner and leave no ambiguous valid state.
- `REQ-ID-003-AC4`: Before transaction approval, the client displays which
  nickname, public keys, fee-payer relationship, timing information, and other
  metadata will become public or correlatable.
- `REQ-ID-003-AC5`: Ordinary authentication creates no blockchain transaction and
  spends no SOL.

### REQ-ID-004: Sustainable cost and abuse control

- `REQ-ID-004-AC1`: Automated local-validator and Devnet experiments report
  account allocation, base fee, compute use, and estimated sponsor exposure for
  every candidate registry model.
- `REQ-ID-004-AC2`: An unauthenticated attacker cannot cause unbounded founder-paid
  on-chain transactions merely by requesting registrations.
- `REQ-ID-004-AC3`: Rate limits and duplicate, reserved-name, and concurrent-claim
  controls are tested before any sponsored public registration.
- `REQ-ID-004-AC4`: Mainnet registration remains disabled until the founder accepts
  a per-registration cost ceiling, sponsorship budget, exhaustion behavior, and
  user-visible fee policy using current measured prices.

### REQ-ID-005: Per-device authentication authority

- `REQ-ID-005-AC1`: Replayed, expired, wrong-purpose, wrong-server, wrong-origin,
  wrong-device, and concurrently consumed challenges are rejected deterministically.
- `REQ-ID-005-AC2`: Revoking a device invalidates all of its server sessions without
  invalidating unrelated devices.
- `REQ-ID-005-AC3`: Rust, Kotlin, and any Swift boundary produce and verify identical
  public-key and signed-envelope conformance vectors.
- `REQ-ID-005-AC4`: Routine authentication succeeds using only the authorized
  device key and public verification state; it does not require the recovery words
  or account-root private key.

### REQ-ID-006: Temporarily unavailable blockchain

- `REQ-ID-006-AC1`: An authorized device can authenticate against a previously
  verified registry snapshot during a simulated temporary public-internet outage,
  while registration, recovery, transfer, and other high-impact identity changes
  remain unavailable.
- `REQ-ID-006-AC2`: The server exposes registry-cache age and rejects operations
  whose accepted freshness policy has expired.
- `REQ-ID-006-AC3`: Conflicting RPC or chain state cannot silently replace a known
  account root or authorize a high-impact identity change.
