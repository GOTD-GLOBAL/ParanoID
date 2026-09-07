---
status: draft
owner: architecture
decision_owner: martadvix-web
decision_deadline: pending-owner-scheduling
required_reviewers:
  - <independent-messaging-security-reviewer>
  - <independent-media-and-automation-security-reviewer>
last_reviewed: 2026-09-07
---

# RFC-0005: Server boundaries for messaging, media and project automation

## Required review rationale

Reviewer placeholders and deadline are intentionally unresolved. This RFC cannot
move to proposed until real qualified independent humans and a deadline are named.
The domains include protocol/persistence, stack, crypto, permission and deployment
boundaries under the documentation policy. Fable/Opus advice is not human approval.
Owner martadvix-web selects reviewers independent of author and decision owner.
This umbrella proposal does not batch-accept these domains; separate ADRs are needed.

## Summary

Write the ParanoID core ourselves as one modular service. Reuse selected OSS behind
replaceable adapters: LiveKit first for SFU, tusd for resumable ciphertext upload,
optional TURN and AI workers outside the core. Do not fork a full messenger.

Evidence, source-level findings, alternatives and licensing boundaries are in the
[server research](../research/2026-09-07-server-oss-design.md). No candidate is accepted.
RFC-0004 in PR #6 remains a separate alpha proposal; this RFC does not supersede it.

## Motivation

REQ-MSG-001, REQ-CALL-001, REQ-CLIENT-001, REQ-DEPLOY-001, REQ-NET-001,
REQ-MULTI-001, REQ-EXT-001, REQ-ENT-001 and REQ-AI-001 motivate this proposal.
REQ-SEC-001 prevents unsupported privacy claims. New REQ-AI-002 records future
project-group automation intent, not approved agent plaintext access.

## Goals and non-goals

Goals: text/groups; pictures, voice messages and clips; 1:1 audio/video and
conferences; independent server spaces; optional project-specific automation.
Initial call target remains eight participants pending a separately approved change.
Non-goals: custom cryptographic primitives, SFU implementation from scratch,
mandatory managed services, blockchain in the first slice, global server replication,
server-side recording, universal access for agents or automatic production rollout.

## Proposed design

```text
Android clients (content keys and local history)
   | TLS + ciphertext envelopes / scoped blob requests
ParanoID core: Access | Delivery | Rooms | Blobs | Calls | Automation routing
   |                    |                |                 |
PostgreSQL       tusd/private blobs    SFU adapter      policy gateway
(events/outbox)                        LiveKit          isolated AI endpoint
                                         |
                            encrypted media from clients
```

The diagram names proposals, not existing deployments. SFU, blob store and core
receive no content keys. An explicitly admitted AI endpoint is a content recipient,
not a decryption extension inside the core. Co-host root can inspect that endpoint;
strong operator-blind mode requires a separately controlled client/runtime.

Candidate core stack is Rust/Axum/Tokio/PostgreSQL; Go/PostgreSQL is the fallback.
These candidates need release pins, dependency review and a build before acceptance.
Single transaction persists envelope and outbox before acceptance ACK. Delivery is
at-least-once; stable request IDs and client transactional inbox/state provide dedup.
No Redis/Kafka/Temporal cluster is mandatory in the first two-phone slice.

Room authorization version and E2EE epoch are separate concepts. Device revocation,
concurrent membership changes and in-flight ciphertext need explicit rules. Server
membership cannot mint a trusted cryptographic member. Authenticate group state on
clients and fail on conflicting/unverifiable changes rather than silently keying them.

Blob service stores ciphertext only. Typed media descriptors and keys travel inside
E2EE messages. Resume stable encrypted bytes. Propose encrypted client-generated
previews; explicit owner confirmation remains pending, with no plaintext exception.

Calls have invite/accept/reject/cancel/end lifecycle, short-lived room-scoped SFU
grants and one selected SFU per call. Distribution of frame keys is client-authorized
E2EE, not bundled plaintext in a server-issued token. Test no-frame-before-key and
no-downgrade explicitly. SFU outage need not stop durable text delivery.

Proposed automation starts with explicit task handoff. Later visible agent membership
can receive deliberately shared epochs/history. Grants are scoped by project/group,
event, tools, budget and expiry; outbound effects are idempotent or reconciled.
Prompt text and model responses cannot elevate authority. No shell, host-root,
core database credentials or cross-project context by default. External model use
requires explicit disclosure policy. Only opaque job references enter core/outbox;
plaintext job context remains inside the authorized endpoint boundary.

## Alternatives

- LiveKit vs mediasoup vs Jitsi: integration burden and mobile E2EE tests decide.
- tusd as service vs building a resumable handler: avoid reimplementing offset/lock
  semantics, but own authorization and lifecycle even when tusd is reused.
- OpenMLS vs library-backed pairwise fan-out: resolve in separate group-crypto ADR;
  current Olm self-test decides neither. No bespoke sender-key construction.
- Temporal service later vs bounded PostgreSQL jobs initially: evaluate complexity
  and failure cases without claiming exactly-once external actions.
- Matrix/Tinode/SimpleX server fork: rejected as current recommendation because of
  scope/protocol coupling and copyleft-core constraints, not a formal ADR rejection.

## Security and privacy

See [threat model](../security/threat-model.md). Content hiding does not hide IPs,
routing, sizes/timing or necessarily membership. Pairwise pseudonyms are not a proof
of unlinkability. File keys, filenames and plaintext hashes never enter upload
metadata. Retention/deletion cannot revoke copies already seen by recipients/agents.
E2EE prevents server transcoding, search or AI reading without a new trusted endpoint.

## Compatibility and migration

No public API is introduced by this RFC. Define versioned protocol and rejection
rules before implementation. Preserve portable identity/root-device goals, seed-only
recovery and multi-server separation while deferring blockchain linking. Do not
convert synthetic test accounts into production identity. Later migration requires
proof of identity control, not nickname equality. No acceptance of RFC-0004 root ID.

## Operations and observability

Existing production host is not permission to deploy. Inventory workloads/ports,
resource limits, TLS/DNS and rollback first; no changes in this task. Separate Unix
service identities, private volumes and per-service secrets; no NOPASSWD host access
for agents. Client/LAN operation must not depend on public RPC/inference.
Metrics: queue age, failed deliveries, retry rate, blob quota/orphans, call join errors
and resource usage. No plaintext, content keys or high-cardinality contact IDs in logs.
Restore must prove event/cursor/blob consistency, not merely database startup.

## Delivery priority clarified by the founder

Start with ONE server: messages, file/image transfer, audio/video messages and
calls. The founder plans to recruit acquaintances for the subsequent test group.
Simultaneous connections to multiple independent servers are a later implementation
and test milestone, NOT a gate for the first alpha. Preserve a future server-scoped
session/storage boundary without implementing federation, cross-server calls or
running a second server now. This prioritization does not accept an identity,
crypto, persistence or deployment design and does not remove existing E2EE gates.

## Validation plan

First implement only an authorized two-device, single-server ciphertext delivery slice: durable
acceptance, reconnect, replay-safe request IDs, wrong-device/room rejection and
restart during ACK transitions. Test real OPPO client storage before remote rollout.

Separate tests: interrupted blob uploads, quota/expiry/unauthorized downloads;
group removal/epochs/offline catch-up; two-phone then 4/8-party SFU calls with UDP
blocked, handover, background wakeup and key loss. For agents: denied cross-project
access, prompt injection, duplicate jobs, revoked grants, partial external failure,
approval substitution and egress controls. Missing tests remain explicit gates.

## Open questions

Owner for all triage: martadvix-web; deadlines not yet scheduled.

- Exact server stack/device-auth and persistence contract; independent reviewers.
- Group crypto and authenticated membership ordering.
- AI task-only default vs opt-in continuous group participant; who controls runtime.
- Preview encryption confirmation, content/metadata retention and history sharing.
- SFU release, codec obligations, Android E2EE behavior and measured server capacity.

## Decision and follow-up

- Disposition: draft, awaiting review and bounded experiments.
- Decision-owner approval permalink: pending.
- Delegation evidence permalink: none.
- Required-review evidence permalinks: pending qualified human review.
- Resulting ADR: none; separate domain ADRs required before adoption.
- Closure rationale: not closed.
- Replacement RFC: none.
- Implementation issues: not created; first slice identified above.
