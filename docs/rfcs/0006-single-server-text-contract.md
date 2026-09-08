---
status: draft
owner: architecture
decision_owner: martadvix-web
decision_deadline: pending-application-disposition
review_mode: pending-application-disposition
required_reviewers:
  - <reviewer-per-selected-policy-mode>
last_reviewed: 2026-09-08
---

# RFC-0006: One-server text contract for two phones

## Required review rationale

Identity, E2EE, protocol, persistence, stack and trust boundaries are protected
by the [documentation policy](../governance/documentation-policy.md).
ADR-0003 now permits independent AI review instead of a second human for
explicitly owner-approved private test-data alpha scope. The placeholder is
resolved at application disposition under that policy; it does not mandate
finding an unavailable second human before drafting or publishing this proposal.
The founder delegated technical recommendations to the primary assistant, not
human decision authority under the policy. This document is not adoption or
permission to implement protected contracts before disposition. No exception is
created by calling work a spike. The accompanying dependency-only compile check
implements no application behavior or protected contract.

## Summary and provenance

The founder requested one server and two OPPO phones exchanging E2EE text with
history, reconnect and no duplicates. His follow-up specifies one check for
server acceptance, two for recipient delivery, and server history deletion only
on an additional explicit request. Technical choices are the assistant's job;
future iPhone support must be preserved.

This records that Telegram input, not a fabricated approval permalink. The tool
context exposes the sender display name Sergey Maltsev but no stable message
permalink, message ID or authenticated mapping to GitHub. Owner confirmation on
GitHub is required for durable approval evidence. No protected decision is accepted.

This narrow proposal uses the existing RFC-0004 (PR #6) and RFC-0005 (PR #10)
research. PRs #6/#10 were closed without merge during owner-requested cleanup;
their branches remain research history, not accepted architecture.
In particular, RFC-0004's root identity/reset ambiguity is resolved here as a
recommendation: never silently reset or reinterpret an established identity.
No second-server test is a gate for this slice.

## Motivation and scope

Traceability: REQ-ID-001/002, REQ-MSG-001/002/003/004, REQ-CLIENT-001,
REQ-NET-001, REQ-MULTI-001 and REQ-SEC-001 in
[requirements](../product/requirements.md).

Deliverable after acceptance: a real Android app on two OPPO phones, a single
server, authenticated 1:1 E2EE text, offline catch-up, restart-safe history,
server-accepted and peer-delivered indicators. Initial delivery is foreground or
on reopening; background push and guaranteed delivery to a killed app are not
promised. Server persists the message while the recipient is unavailable.

Not this slice: multiple devices per account, simultaneous multiple servers,
federation, blockchain names, groups, files, media, calls, bots, AI or iOS UI.
iOS is a required future client, not removed from the product. Do not condition
Android acceptance on an iOS build or a second-server deployment.

## Proposed design

### Stack and platform separation

Recommend one Rust service using Tokio/Axum and PostgreSQL through SQLx. No
Redis, broker or SFU is needed. Candidate pins and actual compilation evidence
are in [the bounded stack check](../research/2026-09-08-server-stack-check.md).
Pin the PostgreSQL image digest and exercise its restore before a rollout;
there is no selected or deployed image yet.

Android uses a native Kotlin UI. Future iOS uses a native Swift UI. A separate
Rust client core owns library-backed E2EE and its state transitions; it must not
link Axum, SQLx, Android APIs or server configuration. Android JNI and an iOS C ABI
adapter are platform edges, not separate cryptographic protocols. All platforms
use the same versioned envelopes and conformance vectors. iOS bridging is not
proven by the Android JNI self-test. Secrets/local storage and background lifecycle
use platform adapters; Keychain and Android Keystore are not interchangeable APIs.

Use HTTPS requests for send, paginated sync and acknowledgements. WebSocket is a
wake-up/low-latency path, not the durable source of truth. A missed socket event
must be recoverable from sync. Scope every session, local store and cursor by an
explicit server identity even though only one server is configured now.

### Identity and admission

Recommend a randomly generated root signing seed stored only on the client,
a separately random device signing key and a root-signed device credential.
Use standard library Ed25519 key generation and BIP39 encoding for root seed
backup; do not add a home-grown seed KDF or derive messaging/ratchet keys from
the recovery seed. Exact credential encoding, signing domain, test vectors and
key-use rules must receive specialist review in the identity ADR before code.

Closed admission uses a single-use invitation bound to this server and the
intended root/device key, expiry and invitation authority. No phone/email,
blockchain or open registration. Authenticate possession using a short-lived,
one-use server-bound challenge; consume it atomically. Sessions bind to device,
server and revocation generation. Deny by default outside the fixed 1:1 room.
Never log challenges paired with authorization material or bearer tokens.

Verify the peer root fingerprint by out-of-band QR before opening an E2EE session.
Authenticate the peer's Olm identity/prekeys through its verified device credential;
the server may route keys but cannot vouch for or silently replace them. Bind the
server/room/sender/recipient/message context inside authenticated message content
and reject a mismatch with the outer routing envelope. Canonical byte encodings,
expiry, replay and version-rejection vectors belong in the implementation contract,
not ad hoc JSON signing. A key change stops sending until explicitly reverified.

Recommend vodozemac 0.10.0 Olm for this 1:1 candidate, not Megolm/group crypto.
The two-phone local diagnostic proves neither peer authentication nor a complete
standalone integration. Review dependency advisories, prekey consumption, session
setup races and persistent ratchet state before adoption. No custom primitives,
plaintext mode or downgrade when encryption fails.

### Acceptance, delivery and check marks

- Pending: sender has durably committed a local outbox entry, encrypted bytes,
  the stable random message ID and advanced ratchet state together.
- One check: server has committed the immutable envelope, idempotency record,
  per-conversation sequence and sync-visible acceptance in one DB transaction.
- Two checks: the sender has verified an authenticated recipient delivery receipt
  for that exact message, emitted only after recipient decryption/validation and
  durable local inbox/history plus crypto-state commit. This does not mean read.
- Failure: a permanent authorization, key or quota error is visible; never show
  an acceptance check for a merely queued request or a socket write.

The second check must not be minted by the server. Delivery receipts travel as
peer-authenticated control messages over the same durable channel, carry the
original message ID/context, and are deduplicated. Receipts do not generate
receipts recursively. The server-acceptance indicator remains a statement about
an honest server's commit, not proof against malicious storage operators.

### Retries, ordering and reconnect

Delivery is at-least-once, with exactly-once display within retained local state.
Do not promise exactly-once network delivery. Unique server identity is
(server, conversation, sender device, message ID); enforce the same logical key
on the client inbox. Repeating the identical envelope returns its original result.
Reusing its ID with different ciphertext/context fails with an idempotency conflict.
Never re-encrypt a message merely because its acceptance response was lost.

Serialize sequence allocation and envelope commit per conversation. A cursor
must represent a contiguous committed prefix, not a bare auto-increment value
that a concurrent later transaction can overtake. Sync and WebSocket use that
same source; sync resumes at the last durably applied position. UI ordering uses
server conversation sequence, not client wall clocks. Preserve local pending
entries without rendering both a pending and confirmed copy of the same message.

Apply inbox dedup before attempting ratchet decryption. Persist ratchet changes,
message/history, receipt outbox and cursor atomically; crash recovery must observe
all or none. Store retryable encrypted bytes durably on both sending paths.
Invalid ciphertext must not advance cryptographic state or appear delivered;
record a visible rejection/sync outcome without blocking every later valid event.
Details need conformance vectors before the receiver implementation is written.

### History, deletion and lost keys

Server history contains ciphertext and minimal routing/order/receipt metadata,
not seeds, content keys or plaintext. Retain messages after delivery, disconnect,
logout and app reinstall. No TTL, acknowledgement-triggered purge or quota eviction.
At the storage limit reject new sends explicitly; preserve previously acknowledged
history. Reserve bounded capacity for control events such as delivery receipts.
Per-device/account rate limits and configured quotas apply before expensive work.

An additional explicit authenticated deletion request is the only ordinary
history-deletion trigger. Initial recommendation: conversation-wide deletion
requires both participant approvals, is not implied by a local UI hide, and uses
idempotent tombstones so old retries cannot recreate deleted messages. The first
slice may omit the deletion endpoint; no automatic substitute is allowed. Later
implementation must specify request authority, backup expiry and restore-time
application of deletion records in a separate reviewed contract. Deletion cannot
recall copies saved by recipients. No claim of physical deletion from backups is
made without that contract and an exercised process.

The client retains readable local history in encrypted storage with a random
local key protected by the platform. Persist sessions independently of server
ciphertext. Loss of a local database/key must never trigger ratchet regeneration
under the old session identity or silently mark undecryptable history as delivered.

Recovery recommendation: surviving seed can prove root ownership, revoke the old
device and authorize a fresh device/session after peer verification. It does NOT
reconstruct historical ratchet secrets. Losing all usable local history keys means
old server ciphertext remains stored but unreadable on the replacement device.
Show this explicitly. Losing the seed and all authorized devices means account
loss; there is no administrator plaintext/key escrow or password reset backdoor.
Show and verify seed backup at account creation; explain that this is identity
backup, not chat backup. Encrypted history-key backup is a later separately
reviewed feature; do not weaken forward secrecy by deriving past ratchet keys
from the seed. A lost/stolen device may already hold readable copies.

## Alternatives

- Go/PostgreSQL: viable, but another core language beside the Rust crypto work;
  no current blocker justifies switching. This is a recommendation, not rejection
  of Go through an accepted ADR.
- SQLite server: simpler startup, but PostgreSQL is the selected recommendation
  for transactions, concurrency and future hosted use. SQLite remains a possible
  local client store, not an iOS-incompatible network contract.
- WebSocket-only delivery: rejected recommendation; it does not provide durable
  catch-up by itself.
- Plaintext first, server-held content keys, reconstructing ratchets from root:
  incompatible with the requested E2EE boundary; not fallback implementations.
- Shared Flutter UI: possible later choice but not needed to preserve iOS protocol
  compatibility; native shells isolate mobile lifecycle and secure storage.

## Security, operations and rollback

See [the threat-model delta](../security/server-v0-threats.md). The server and
hosting operator can observe IPs, peers, timing, sizes and stored history volume.
No anonymity claim follows from E2EE. Content-free logs and low-cardinality metrics
only; no tokens, keys, invitation payloads or message contents in logs.

Deploy only after bounded host authorization and inspection of existing services,
ports, DNS/TLS, service identity, storage isolation, resources and rollback. No
production access or Docker socket privilege escalation is part of this work.
Backup/restore must verify messages, dedup records, receipts, sequence and tombstones;
a database that merely starts is insufficient evidence. Restoring an old backup
can lose later accepted data: disclose the measured RPO, never promise zero loss
from a stale snapshot. Live server restart and disaster restore are distinct tests.
Do not rewind client ratchets to match an older server snapshot.

Protocol v0 rejects unknown/incompatible versions explicitly. No conversion from
synthetic diagnostic identities to real accounts. Migrations and rollback must
preserve history; an unsafe downgrade is rejected, not implemented by dropping data.

## Validation plan and implementation order

See the [acceptance matrix](../protocol/server-v0-acceptance.md). No listed
messaging test has passed yet. The dependency compilation is not a substitute.

After human disposition, implement small TDD PRs in this order:

1. Server health/configuration, isolated local PostgreSQL harness, migration tests
   and reviewed versioned API schemas. No unauthenticated public message endpoint.
2. Authorized ciphertext append plus durable sequence, retry conflict and sync.
3. Two headless clients with real E2EE, authenticated receipts and crash-safe local
   state. Prove restart/lost-ACK/offline behavior, not just happy-path delivery.
4. Android adapters and UI on the two OPPO devices. Use real peer keys, verify QR,
   exchange text over Wi-Fi and mobile data, and exercise offline/restart scenarios.
5. Authorized hosted rollout with exercised backup/restore and rollback. Record
   actual phone evidence before claiming phone-to-phone delivery.

## Open questions and decision follow-up

Technical recommendations are supplied here; the founder need not choose wire
formats or database algorithms. Remaining blockers are review/disposition and
exact reviewed cryptographic encodings/vectors, not a new market study.

- Disposition: draft; no accepted architecture or protocol in this change.
- Decision owner: martadvix-web; approval permalink pending GitHub confirmation.
- Review mode, reviewer identities and evidence: to be recorded at application
  disposition under ADR-0003; second-human absence alone is not an alpha blocker.
- Delegation evidence: none meeting the durable-evidence policy.
- Resulting ADRs: separate identity/E2EE, delivery/persistence and stack records
  required before adoption; do not batch-accept protected domains through this RFC.
- Deadline: owner schedules application disposition; no invented deadline.
- RFC-0004/0005: archived draft material in closed PRs #6/#10; no architecture
  accepted by their closure or by this file.
- Implementation authorization: blocked on the existing disposition gate.
- Production authorization: not requested or granted by this document.
