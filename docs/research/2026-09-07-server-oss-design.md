---
status: draft
owner: architecture
last_reviewed: 2026-09-07
---

# Server prior art: messaging, media, calls and project automation

## Outcome and authority

Recommendation, not acceptance: implement a small ParanoID server core ourselves;
reuse a maintained SFU and resumable-upload implementation behind adapters. Keep
AI execution outside the messaging process. Do not fork a whole messenger as the
new core. This document supports RFC-0005; it is not an implementation or audit.

This investigation revisits the earlier unpublished OSS landscape with current
GitHub snapshots, selected implementation files and primary documentation. It
adds project automation and explicit AI/E2EE boundaries. No third-party code was
copied into product code. No server was deployed.

## Method and limits

Read GitHub metadata, pinned README/license files and selected code from 15
repositories. Sources use immutable commit URLs where possible, not claims about
future releases. Active development branches are evidence, NOT deployment pins.
No candidate was installed, benchmarked, penetration-tested or comprehensively
audited in this research. Recent pushes and non-archival status are weak upkeep
signals, not proof of support or safety. Release/security-advisory history,
dependency SBOMs and exact production versions remain adoption gates.

The previous OPPO Olm self-test does not establish group security, secure key
storage, remote authentication, delivery durability or voice/video E2EE.

## Shortlist and reuse boundaries

| Area | Evidence | ParanoID recommendation and trade-off |
| --- | --- | --- |
| SFU | LiveKit provides WebRTC multi-user conferencing, Go/Pion server, JWT auth and native Android SDK; server and SDK are Apache-2.0.[7], [8], [5] | First candidate as a separate service, Android SDK behind our RTC adapter. Own membership and keys; do not use RTC data channels as durable chat storage. |
| Lower-level SFU | mediasoup offers Rust/Node APIs, signaling-agnostic media routing, simulcast/SVC; ISC license.[22], [23] | Fallback if LiveKit fails mandatory E2EE/mobile tests. More signaling/mobile integration belongs to us. |
| Conference reference | Jitsi Videobridge is a WebRTC SFU in the Jitsi Meet stack, with Apache-2.0 license.[36], [37] | Compare conference operations; not selected as an embedded complete meeting UI/identity stack. Android E2EE not established here. |
| NAT traversal | coturn implements TURN/STUN; its actual LICENSE has three BSD-style conditions despite API metadata reporting NOASSERTION.[1], [2] | Reuse as a separate service only if needed beyond chosen SFU TURN support. Avoid two overlapping TURN deployments without a reason. |
| Resumable blobs | tusd supports resumable uploads to disk or S3-compatible stores; MIT. Handler verifies offsets, locks uploads, and returns metadata.[21], [29], [30] | Use tusd behind ParanoID authorization for encrypted blobs; no public raw endpoint or meaningful names in Upload-Metadata. |
| Delivery and sync | Synapse exposes incremental sync tokens, room timelines/state and ephemeral updates; current code is AGPL.[26], [25], [24] | Borrow the distinction between durable events and ephemeral updates; write our own protocol, no Matrix state-resolution/federation transplant. |
| Attachment authorization | Signal attachment controller issues upload forms, validates lengths and applies count/byte rate limits. Current file is AGPL-3.0-only; server build/test instructions require the FoundationDB client library.[31], [13], [14] | Architectural reference only. Independently implement scoped upload authorization; do not copy controller or impose its backend stack. |
| Topic routing | Tinode uses JSON/WebSocket or protobuf/gRPC, Go server GPL-3.0; README distinguishes Apache-2.0 clients.[19], [20] | Routing/topic reference, not server-code donor under permissive-core constraint. Verify individual client file provenance separately. |
| Metadata privacy | SimpleXMQ uses unidirectional queues and an agent coordinating duplex connections across servers; AGPL.[15], [16] | Study pairwise queues and metadata minimization, not transplant global group routing or infer unlinkability. README includes historical persistence caveats; audit current implementation before relying on durability. |
| Project conversation UX | Zulip centers conversations around topic-based threading; Apache-2.0.[38], [39] | Adopt project → group → thread/task concept as proposal, not its entire server. Keep topic labels encrypted if private. |
| Group crypto | OpenMLS implements RFC 9420, MIT; Android/iOS are listed as build-only, unsupported-but-built CI targets.[11], [12] | First group-crypto candidate, not accepted or proven on OPPO. Compare against library-backed per-device pairwise fan-out for small groups. |
| Durable automation | Temporal exposes workflows, durable history, task queues, timers and retry policies; MIT.[17], [32], [18] | Reference the job lifecycle now; optional service later when restartable multi-step workflows justify it. No mandatory Temporal cluster in first alpha. |
| Voice agents | LiveKit Agents offers programmable server-side participants, dispatch and STT/LLM/TTS integration; Apache-2.0.[3], [4] | Optional call participant adapter, not our entire text automation platform. Local inference and E2EE-compatible agent key flow must be tested. |
| Encrypted bots | mautrix-go supports appservices, bridges and E2EE, but MPL-2.0.[9], [10] | Bot-as-client reference. MPL is not permissive; embedding requires explicit license review, not automatic approval. |

The inspected Android SDK license file is Apache-2.0.[6]

Licenses above describe inspected repository/file scope, not transitive libraries,
codecs, model weights or patents. A permissive upstream permits possible reuse,
not unconditional removal of attribution. Copyleft code does not become permissive
by translation, renaming or partial rewriting. Separate-process deployment is not
a blanket legal exemption. Preserve notices, exact upstream revision, modified-file
inventory, tests and update path for every actual import.

## Concrete findings from implementation reads

### Calls: default settings are not the security contract

[Retrieved excerpts](evidence/livekit-e2ee-2026-09-07.md) preserve the key-distribution
and signaling statements from the mutable LiveKit documentation.

LiveKit states that applications must generate, store and distribute keys; signaling
and API calls remain readable to the service under TLS.[34]

Its Android `E2EEOptions.kt` initializes
`defaultDiscardFrameWhenCryptorNotReady = false`, and `KeyProvider.kt` supports both
shared and participant-specific key paths.[27], [28]

That source observation is not proof of plaintext leakage. It is a mandatory test
trigger: no media leaves a ParanoID participant before a valid cryptor/key epoch,
no silent downgrade, and no server-side content key delivery. The documentation's
server-generated shared-key example is NOT our proposed trust model. Token issuer
and SFU get admission information, not content keys. Selected participant devices
must distribute keys through an authenticated E2EE channel. How that channel and
membership epochs work remains protected design work.

### Files: resume encrypted bytes, not a fresh encryption attempt

The tusd handler checks `Upload-Offset`, returns conflict on mismatch, acquires
upload locks and echoes Upload-Metadata on HEAD responses.[30]

Proposal: clients keep a stable encrypted upload artifact/state across retries.
The metadata header must not contain filenames, captions, plaintext hashes or keys.
Do not regenerate random encryption state against already-uploaded ciphertext.
A reviewed streaming/chunk encryption format must reject truncation, reordering and
splicing before media decoding. TUS provides resumption, not E2EE.

### Automation: retries can multiply side effects

Temporal's lifecycle persists history/state/tasks before transferring work; its
retry guide explicitly warns that retries at client and server layers multiply.[32], [33]

Proposal: durable job IDs, an outbox, bounded retry budgets and effect-specific
idempotency keys. A remote operation that succeeded before a lost response must
be reconciled, not blindly replayed. A queue does not give exactly-once external
effects. Irreversible actions require human approval tied to exact parameters.

## Proposed server structure

A modular core, not a microservice for every message type:

- `Access`: server membership, scoped sessions, rate limits, authorization checks.
- `Delivery`: ciphertext envelopes, durable acceptance, per-device cursors, retries.
- `Rooms`: membership versions and roles; cryptographic group state stays distinct.
- `Blobs`: upload/download grants, quotas, lifecycle, tombstones and orphan cleanup.
- `Calls`: invitations, accept/reject/cancel/end states, participant grants, SFU adapter.
- `Automation`: opaque job routing, policy decisions and audit identifiers; no chat keys.

Candidate implementation: Rust with Axum/Tokio and PostgreSQL. This is our proposed
engineering choice, not a measured winner or accepted stack. Rust aligns with the
existing experimental library/tooling; PostgreSQL would hold authoritative events,
membership and an outbox in transactions. Go with PostgreSQL is the fallback if
Rust development/operations evidence is worse. No need for Redis, Kafka or NATS as
mandatory initial delivery dependencies; add a broker only for measured needs.

Separate service boundaries: SFU/TURN; resumable blob endpoint when introduced;
AI worker runtime. A `BlobStore` adapter initially targets a private local volume,
later a vetted self-hosted S3-compatible store. Do not select MinIO or another
object server without its own current license/maintenance review.

### Delivery contract to specify before production use

1. Client encrypts and submits a versioned envelope with a stable request ID.
2. Core checks device/session and authorized membership version; atomically persists
   the ciphertext, authorized recipients and outbox task before an acceptance ACK.
3. Background delivery wakes online clients; disconnected devices catch up by cursor.
4. Device ACK advances only after durable client storage; read receipts are separate.
5. Retries return the same accepted event; UI deduplicates. Crypto replay rejection
   alone is insufficient because a crash can happen between decryption and storage.
6. Removed users cannot obtain new deliveries or grants; already held plaintext or
   keys cannot be remotely erased. Epoch rotation and in-flight message rules need
   an explicit client/group protocol, not just a server ACL.

A single-server log order is a delivery order, not proof of sender chronology or
cryptographic group agreement. Do not use one global sequence across all projects;
exposed sequence gaps can leak unrelated activity. Encryption authenticates content,
not availability: omission, delay and some metadata leakage remain possible.

### Media, groups and conferences

Voice messages, pictures, files and recorded clips share the blob mechanism, with
media descriptors and keys inside encrypted messages. Client-side encoding and
preview generation avoid giving the blob service plaintext. Preview encryption
is a security proposal pending confirmation; this design accepts no plaintext
preview exception. Audio/video calls use a different real-time SFU path.

Prior product direction remains one selected self-hosted SFU per call, up to eight
participants in V1, no server recording; larger conferences, cascading and failover
are later scope. No internet/RPC dependency for previously authorized local clients
on a LAN server/SFU. Internet background wakeups on OPPO need their own push/power
management tests; an always-open WebSocket does not prove reliable incoming calls.

No blanket claim that Olm test success establishes group E2EE. Evaluate OpenMLS
credential binding, joins/removals, concurrent commits, offline catch-up, state
rollback and Android persistence against an explicitly defined group threat model.
RFC 9420 is a protocol specification, not ParanoID's completed identity design.[35]

## AI automation: proposal requiring an explicit owner decision

Recommended default: no agent receives group plaintext automatically. Two modes:

- Explicit task handoff: a participant sends selected content to an agent endpoint;
  access is limited to that task, not the entire group history.
- Visible agent membership: an agent joins as a separately identified E2EE endpoint,
  with explicit admission and clear UI. The agent can read only the epochs/history
  it is intentionally given. Removal rotates future keys, not already seen data.

A runtime on the same host as the messaging server makes the host administrator
trusted for any plaintext accessible to that runtime. Containers do not hide keys
from host root. A stronger operator-blind mode needs an independently controlled
endpoint/client-side execution, not a marketing claim about sandboxing.

Each automation grant is bounded by project, group, triggering event, allowed
operations, expiry, budget and external integrations. Separate service principals
and secret stores; never root SSH or the messenger database credential. Invocation
origin and content are untrusted; messages, retrieved files and model outputs cannot
grant new permissions. Tool access is enforced by a policy gateway outside the LLM.

No arbitrary shell/MCP endpoint or URL fetch by default. Prevent cross-project
context mixing, recursive bot loops, unbounded spend, SSRF and credential export.
For high-impact actions use preview → human approval → execute → reconcile/audit.
Audit metadata may itself be sensitive; retain minimal IDs/outcomes and redact or
encrypt payloads. External model use is explicit data disclosure, opt-in per policy.
Optional self-hosted models do not eliminate operator trust or model-output risks.

## Ordered delivery and decision gates

1. Specify the first local server API and device authorization contract, then build
   a test server with durable ciphertext delivery, restart/reconnect and dedup tests.
   Group crypto, calls and agents must not block this narrower text slice; they are
   separate acceptance tracks, not silently omitted security requirements.
2. Two OPPO clients: real E2EE text, durable client state and safe key storage. Test
   kill/restart around ACK boundaries, revoked device, wrong room and old cursor.
3. Owner-approved isolated production rollout with TLS, resource limits, backup and
   restore rehearsal. Existing SSH access does not authorize deployment.
4. Ciphertext uploads: image and voice recording/send/play/resume, length/quota/TTL
   enforcement, interrupted uploads and unauthorized-download tests.
5. Group membership plus reviewed group key lifecycle; no old-key future access after
   removal. Define forward history sharing explicitly.
6. Self-hosted LiveKit: two OPPO calls, then 4/8 endpoints; UDP-blocked/TURN, handover,
   background incoming call, Bluetooth, jitter/loss, thermal/battery and key-rotation
   tests. Record actual capacity measurements, not guessed server sizing.
7. One project-scoped agent task with no privileged tools, durable retries and
   approval policy; then optional group/voice participation and integrations.

Before production adoption: exact release pins, reachable-advisory review, dependency
licenses/SBOM, independent qualified human security review, restore evidence, load
results and operational rollback. This research closes none of those gates by itself.

## Sources

[1]: https://raw.githubusercontent.com/coturn/coturn/d0440b6defb1bca57d1cf8c70a8ec0142c5a4d56/README.md
[2]: https://raw.githubusercontent.com/coturn/coturn/d0440b6defb1bca57d1cf8c70a8ec0142c5a4d56/LICENSE
[3]: https://raw.githubusercontent.com/livekit/agents/4d03f505c66106622ca66b7ddc93eb9c6f817dc9/README.md
[4]: https://raw.githubusercontent.com/livekit/agents/4d03f505c66106622ca66b7ddc93eb9c6f817dc9/LICENSE
[5]: https://raw.githubusercontent.com/livekit/client-sdk-android/91619841c99fb63f548cfaa4409989483cf1e343/README.md
[6]: https://raw.githubusercontent.com/livekit/client-sdk-android/91619841c99fb63f548cfaa4409989483cf1e343/LICENSE
[7]: https://raw.githubusercontent.com/livekit/livekit/e18fbcc0fa40233db212a9fb2f1dc8a0ebd8813a/README.md
[8]: https://raw.githubusercontent.com/livekit/livekit/e18fbcc0fa40233db212a9fb2f1dc8a0ebd8813a/LICENSE
[9]: https://raw.githubusercontent.com/mautrix/go/6cf476b48c0e2aa1ff3464bd338439cc2abd830c/README.md
[10]: https://raw.githubusercontent.com/mautrix/go/6cf476b48c0e2aa1ff3464bd338439cc2abd830c/LICENSE
[11]: https://raw.githubusercontent.com/openmls/openmls/5f1bc2af50a962f365e0fd272dd0748dede48430/README.md
[12]: https://raw.githubusercontent.com/openmls/openmls/5f1bc2af50a962f365e0fd272dd0748dede48430/LICENSE
[13]: https://raw.githubusercontent.com/signalapp/Signal-Server/38707313d7e0e2fe195054c4540dc3493e00980e/README.md
[14]: https://raw.githubusercontent.com/signalapp/Signal-Server/38707313d7e0e2fe195054c4540dc3493e00980e/LICENSE
[15]: https://raw.githubusercontent.com/simplex-chat/simplexmq/27a37387be98d9c7ec0e62373e125539675d0095/README.md
[16]: https://raw.githubusercontent.com/simplex-chat/simplexmq/27a37387be98d9c7ec0e62373e125539675d0095/LICENSE
[17]: https://raw.githubusercontent.com/temporalio/temporal/891d1b648b7252925142cc36f13e40a0e2ed4244/README.md
[18]: https://raw.githubusercontent.com/temporalio/temporal/891d1b648b7252925142cc36f13e40a0e2ed4244/LICENSE
[19]: https://raw.githubusercontent.com/tinode/chat/7c30da06d3c3ac4dedb3f81be1c4f44875e4d016/README.md
[20]: https://raw.githubusercontent.com/tinode/chat/7c30da06d3c3ac4dedb3f81be1c4f44875e4d016/LICENSE
[21]: https://raw.githubusercontent.com/tus/tusd/3caa902f3460e9a47d8ec120673e5d981569bb16/README.md
[22]: https://raw.githubusercontent.com/versatica/mediasoup/f790aad4d36803dda9fe2f571b27d7d914781b65/README.md
[23]: https://raw.githubusercontent.com/versatica/mediasoup/f790aad4d36803dda9fe2f571b27d7d914781b65/LICENSE
[24]: https://raw.githubusercontent.com/element-hq/synapse/07bfe4c2a1c17c842b36d7f0cff77259ae448ccd/README.rst
[25]: https://raw.githubusercontent.com/element-hq/synapse/07bfe4c2a1c17c842b36d7f0cff77259ae448ccd/LICENSE-AGPL-3.0
[26]: https://raw.githubusercontent.com/element-hq/synapse/07bfe4c2a1c17c842b36d7f0cff77259ae448ccd/synapse/rest/client/sync.py
[27]: https://raw.githubusercontent.com/livekit/client-sdk-android/91619841c99fb63f548cfaa4409989483cf1e343/livekit-android-sdk/src/main/java/io/livekit/android/e2ee/E2EEOptions.kt
[28]: https://raw.githubusercontent.com/livekit/client-sdk-android/91619841c99fb63f548cfaa4409989483cf1e343/livekit-android-sdk/src/main/java/io/livekit/android/e2ee/KeyProvider.kt
[29]: https://raw.githubusercontent.com/tus/tusd/3caa902f3460e9a47d8ec120673e5d981569bb16/LICENSE.txt
[30]: https://raw.githubusercontent.com/tus/tusd/3caa902f3460e9a47d8ec120673e5d981569bb16/pkg/handler/unrouted_handler.go
[31]: https://raw.githubusercontent.com/signalapp/Signal-Server/38707313d7e0e2fe195054c4540dc3493e00980e/service/src/main/java/org/whispersystems/textsecuregcm/controllers/AttachmentControllerV4.java
[32]: https://raw.githubusercontent.com/temporalio/temporal/891d1b648b7252925142cc36f13e40a0e2ed4244/docs/architecture/workflow-lifecycle.md
[33]: https://raw.githubusercontent.com/temporalio/temporal/891d1b648b7252925142cc36f13e40a0e2ed4244/docs/architecture/retry.md
[34]: https://docs.livekit.io/home/client/tracks/encryption
[35]: https://www.rfc-editor.org/rfc/rfc9420.txt
[36]: https://raw.githubusercontent.com/jitsi/jitsi-videobridge/8b31b07690146c6dbe49882320a6bdfcb7b4e952/README.md
[37]: https://raw.githubusercontent.com/jitsi/jitsi-videobridge/8b31b07690146c6dbe49882320a6bdfcb7b4e952/LICENSE
[38]: https://raw.githubusercontent.com/zulip/zulip/371b2ff9840988c4a128491d4c076d2e008a2be3/README.md
[39]: https://raw.githubusercontent.com/zulip/zulip/371b2ff9840988c4a128491d4c076d2e008a2be3/LICENSE
