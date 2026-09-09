---
status: draft
owner: protocol
last_reviewed: 2026-09-09
---

# Self-service v2 — local implementation contract

Issue #16; REQ-ID-001/004/005/006/008, REQ-MSG-002/003/004, REQ-SEC-001.
This narrow draft was written before implementation; a local candidate now
implements it, with [server-only evidence](../server/self-service-local.md). The
companion [RFC-0012](../rfcs/0012-self-service-messenger.md), draft
[ADR-0007](../decisions/0007-self-service-messenger.md),
[threat delta and exact tests](../security/self-service-v2-threats.md) and
[current state](../project/current-state.md) are included in this candidate.
No ADR acceptance, deployment, public-listener permission or production security
claim follows; independent documentation re-review remains pending.

## Identity and wire contract

Reuse the exact existing root-signed `Credential`, account derivation, Ed25519,
SHA-256, LP encoding and canonical base64 from [v1](key-enrollment-v1.md).
Do not rotate installed root/auth/Olm keys. One immutable device per account initially.
No operator, grant, legacy role, email, phone, wallet or directory in the v2 API.

POST `/v2/registration/challenge` accepts exactly:
`{credential: Credential, purpose: "register", method: "POST", path:
"/v2/registration/commit", body: SHA256("{}")}`.
POST `/v2/auth/challenge` accepts exactly `{account, device, credential,
purpose, method, path, body}` (all strings; credential is fingerprint).
Auth purposes: `status` for POST `/v2/auth/verify`, `message` for GET/POST
`/v2/messages`. Control bodies are exactly `{}`; GET body empty. Path includes
exact cursor query bytes. Challenge endpoints reject query parameters.

ChallengeV2 JSON fields in signing order:
`id, nonce, epoch, expires, realm, pin, account, device, credential, purpose,
method, path, body`. All strings except integer Unix-seconds `expires`.
Nonce: 32 OS-CSPRNG bytes, standard padded base64. Epoch/id: fresh UUIDv4.
Expiry: 60 seconds, checked with server wall and monotonic clock.

```text
LP("paranoid-proof-v2", id, nonce, epoch, expires, realm, pin,
   account, device, credential, purpose, method, path, body)
Authorization: ParanoidV2 <id>.<canonical unpadded Ed25519 signature>
```

POST `/v2/registration/commit` verifies device PoP before durable account creation.
Fresh identical registration retries return the same mapping, even at capacity.
Conflicting account/device/auth/fingerprint bindings fail closed.
POST `/v2/auth/verify` returns `{mode:"active",account,device,credential}`;
registration returns the same shape, with no reusable token. All JSON structures
reject unknown/duplicate fields. Invalid proof must not consume legitimate proof;
successful proof atomically consumes before its database effect. Restart invalidates
all outstanding challenges.

POST `/v2/messages`: `{id: canonical UUID, recipient: full account ID,
ciphertext: standard base64}`. Decoded ciphertext is 1..16384 bytes. Sender derives
only from proof. Response `{id,sequence}` means durable commit, not peer delivery.
GET `/v2/messages?after=0&limit=50`: `{messages:[{id,sender,sequence,ciphertext}],cursor}`.
Sender is full account ID. Limit 1..100, nonnegative cursor. Global commit-ordered
sequence permits inbox pagination without skipping concurrent committed writes.
Unique `(sender,id)` exact retries preserve sequence; altered bytes/recipient conflict.
General accounts/devices and unordered account-pair conversations replace slots.
E2EE/receipts remain client-owned opaque content; no server delivery/read claims.

## Bounds and errors

At most eight new accounts per server per fixed 60-second window, durably metered
under the global transaction lock (restart does not clear the budget). Identical
retries do not spend this budget.
Maximum 1024 accounts/devices, 100000 total messages, 10000 sent messages/account,
16 MiB sent ciphertext/account and 256 MiB globally. Conversations are created only
with committed messages, bounded by message rows. Reject rather than evict; exact
retries are resolved before quota checks. The tests seed the actual limits; they do not weaken them for passing results.
At most 16 outstanding challenges globally and 4/account; no persistent allocation
before PoP. Global fixed-window ingress 20 requests/s, auth 8/s, 10-second handlers;
bounded transient device budgets, 2 challenges/account/s. Shared budgets are not
Sybil resistance or guaranteed fairness. Capacity exhaustion remains an availability
risk requiring later deployment policy, not manual enrollment.
Generic 401 invalid eligibility/proof, 409 binding/idempotency conflict, 429
registration/challenge/rate capacity, 507 message quota, 503 unavailable storage.
Malformed message/cursor returns 400. No payload/private-key logging.

## Fresh-only deployment amendment

The [fresh-v2 runbook](../operations/fresh-self-service-v2.md) defines a later
explicit `self-service-v2` runtime and package candidate: exact reviewed IPv4 and
port 38443 with separate opt-in, mandatory existing TLS, fresh private DB and
no operator registration. `self-service-v2-local` remains loopback-only.
The owner explicitly requests discarding only the old isolated server DB without
backup for this one cutover. No wire change, phone reset, migration weakening or
permanent architecture/deployment approval follows. The legacy helper described
below remains intact, but is not the chosen hosted replacement procedure.

## Local mode and offline transition

Implemented explicit `PARANOID_MODE=self-service-v2-local`, loopback only; no old bearer
variables required. Pinned TLS remains required outside disposable HTTP tests.
`self-service-init` offline helper uses only private local PostgreSQL and the same
process-lifetime lock as historical key mode; no ordinary startup schema mutation.
Realm/pin are supplied through `PARANOID_KEY_REALM` / `PARANOID_KEY_PIN`.
Fresh empty storage may initialize. Populated legacy storage requires exact existing
key_meta/key_grants: verify credential root signature, all stored binding columns,
realm/pin and slot uniqueness. Approved/pending bindings map retained history into `pending` accounts; only their
matching device-signed registration commit promotes them. Active bindings remain
active; revoked accounts map into blocked tombstones and never revive. Unbound populated
slots or ambiguous/corrupt schemas fail closed transactionally. Preserve original
legacy tables and message IDs/ciphertext/sequences, map aliases only via verified
bindings. No arbitrary key ever receives an old slot. Offline operator permissions
are migration permissions, not ordinary signup approval.

V2 marker prevents historical modes in this binary from starting against migrated
storage. For binaries predating that marker, preserve an exact copy of original
`key_meta` in `ss_legacy_key_meta`, then advance only `key_meta.version` to 2;
v1 startup's required version-1 lookup consequently fails. Existing grants and
legacy envelopes/room values are untouched. Fresh databases also contain an empty
historical `room_state` startup-guard table (not used for v2 routing), so an old v0
binary's mandatory initialization insert fails rather than creating parallel state.
Rollback requires v2-aware code and current data, never stale dump restoration or
removing cutover markers. This helper is not a deployment/update/backup controller.
Local server independent tests and populated PostgreSQL dump/restore passed; the
[independent evidence record](../server/self-service-local.md#independent-server-review-evidence)
distinguishes those results from unrun phones, client E2EE interoperability and
v2 deployment lifecycle. SR-01 documentation re-review remains pending.
