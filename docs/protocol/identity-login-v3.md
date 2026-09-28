---
status: draft
owner: protocol
decision_owner: martadvix-web
last_reviewed: 2026-09-24
---

# Identity login v3 — private Devnet candidate

Implementation status (2026-09-24): server candidate only, local mode
`identity-v3-local`; see [current state](../project/current-state.md). Deviations:
the fixture-only ban has no API; `recipient_retired` is 409 with that code.

Companion to [RFC-0027](../rfcs/0027-solana-server-authentication.md).
This document replaces the initial RFC's exchange, not deployed v2 behavior.
No implementation, normative acceptance, migration or deployment is claimed.

## Boundary and principal model

Only a new `solana-devnet-v3` deployment mode is in scope. It requires an empty,
separate database and a different explicitly trusted HTTPS realm from the current
v2 service. Startup on a populated or wrong-mode database fails without mutation.
Its realm/pin are delivered through an explicitly confirmed server profile, never
learned from a login challenge. The existing service is not converted or wiped.
There is no automatic client fallback to legacy registration.

Identity is the tuple `(genesis, program, identity PDA)` of RFC0026. Name is not
an authentication principal. A server-local membership contains identity, owner,
canonical name, random membership UUID, state (`active` or `banned`), generation,
current transport account and the operation that created the current generation.
Absence is a query result, not a stored membership. `banned` blocks new grants,
replacement and ordinary traffic, but authenticated status remains available.
There is no self-service unban or delete/recreate-membership route. In this
local slice banned is exercised only by test fixtures; no operator ban API/tool
is delivered. Fixture transition active->banned holds ss_meta first, leaves all
bindings inactive, deletes push tokens, invalidates sessions/notifies waiters
and blocks grants exactly as replacement. Status/inspect still report banned.
Banned memberships retain all eight reserved slots; no automatic quota release.

Generation is a canonical decimal STRING in JSON and LP, range 0..9223372036854775807.
Zero means absent. Mutation increments once, checked for overflow. No wrapping,
reuse or lowering, including rollback. Transport account/root/device/auth/Olm are
independent of blockchain authority. New enrollment/replacement generates a fresh
transport credential; only exact active-device status reuses it.

Enforce UNIQUE constraints on the lifetime binding table for root, account,
device, auth, credential fingerprint and Olm digest; mutation operation UUIDs
are also globally UNIQUE on historical bindings. Device UUID and Olm digest
uniqueness is first-claim reservation, not cryptographic possession: malicious
registered users may preclaim visible victim identifiers, denying enrollment.
Fresh client keys/UUIDs mitigate accidental overlap, not this deliberate attack.
Every account, root, device UUID, auth key and credential fingerprint is globally
unique across memberships and all historical generations in this database.
Retired bindings remain immutable tombstones. Neither v3 nor v2 can assign any
of these identifiers to another identity or reactivate a retired binding. The
public Olm binding digest must also be unique; a fresh device must generate fresh
Olm keys. Root/auth aliases with the blockchain owner key are rejected after
canonical decoding. No registry-key-to-Olm derivation or secret transfer exists.

## Encodings and common parser rules

All control routes are POST, with no query/redirect/method override. Body cap is
16384 bytes. Raw strict typed JSON rejects duplicate/unknown fields recursively,
including the nested credential; no JSONObject preprocessing. Proof owner_signature and device_signature encode exactly 64 bytes as canonical
unpadded Base64. Empty operation is allowed ONLY in the absent status response;
all other operation fields are UUIDv4. All fields below
are strings except `credential_object`, a strict existing Credential, and
`expires`, a nonnegative JSON integer within signed 64-bit range. UUIDs are
canonical lowercase UUIDv4. Hashes are lowercase 64-hex; nonce is canonical
padded Base64 for exactly 32 bytes. Keys/signatures in credentials use canonical
unpadded Base64. Solana genesis/program/PDA/owner use canonical 32-byte base58.
Name uses RFC0026's exact ASCII grammar. Limits are validated before allocations.

LP is the existing u32-BE byte-length-prefixed UTF-8 encoding. No JSON hash or
field-order dependence: transcripts explicitly select the following ordered fields.
Server and client compare realm/pin and genesis/program against configured pins.
Identity PDA derivation is checked using the decoded owner, not caller testimony.
The registry owner is Ed25519; strict verification rejects malformed/small-order
inputs. This is typed off-chain signing, never a general wallet signing API.

## Challenge and proof

POST `/v3/identity/challenge` has exactly:

```text
purpose, operation, genesis, program, identity, owner, name,
credential_object, expected_generation
```

Purposes are `inspect`, `status`, `enroll`, `replace`. `inspect` and `status` must
supply generation `0`; `enroll` supplies `0`; `replace` supplies 1..MAX-1. For read
purposes operation is a new ephemeral UUID; no durable operation row is created.
For mutations operation is persisted with immutable intent before first request.
Validate credential signature, encodings, pins and PDA cheaply. **Do not query
membership, admission, registry RPC or durable state to issue this challenge.**
Global limiter decisions depend on global load only, not claimed identity.

Response has exactly:

```text
id, nonce, epoch, expires, realm, pin, purpose, operation,
genesis, program, identity, owner, name, account, device,
credential_fingerprint, expected_generation
```

Fields after server realm/pin echo validated request intent; account/device/hash
come from credential_object. Server adds random id/nonce, per-process random epoch
and expires=issuance wall time+60s. Stored record retains the full credential and
monotonic issuance time. Expiry uses wall AND monotonic clocks. Unknown identities,
banned/absent memberships, stale generations and retired credentials get the
same challenge schema/issuance path. Never disclose membership by challenge errors.

Define path by purpose, without caller negotiation:

- inspect -> `/v3/identity/inspect`
- status -> `/v3/identity/status`
- enroll or replace -> `/v3/identity/commit`

```text
T(role) = LP("paranoid-identity-v3-" + role,
  id, nonce, epoch, expires, realm, pin, purpose, operation,
  genesis, program, identity, owner, name, account, device,
  credential_fingerprint, expected_generation, "POST", path)
```

Roles are exactly `owner` or `device`. Decimal expires is canonical in LP. Client
compares ALL challenge fields with retained intent/config and its candidate keys,
including lifetime plausibility, before constructing bytes locally. Owner signs
T(owner); device auth signs T(device). Purposes and paths prevent cross-operation
reuse. A transcript beginning with LP is not a valid Solana transaction message;
no Solana transaction is signed for authentication.

Inspect/commit request: exactly `{id, owner_signature, device_signature}`.
Status request: exactly `{id, device_signature}`. Server selects stored challenge,
verifies route/purpose, context and signatures BEFORE any membership lookup or RPC.
Owner key is not required for ordinary status/traffic. An unbound candidate can
prove its own auth key but cannot use status to inspect another account/identity.

After valid proof atomically consume the process-local challenge under its mutex,
then perform reads/RPC/transaction. Invalid proof does not consume it. Consumed
challenge stays consumed on all failures, cancellations and serialization errors;
fresh challenge is required. No claim of atomic in-memory+SQL commit. Restart
invalidates all challenges and sessions. Idempotency lives in durable generation
state, independently of challenge consumption.

## Inspect, status and immutable intent recovery

Inspect requires both proofs. A bounded read-only statement (no ss_meta lock)
looks up membership ONLY by `(genesis, program, identity PDA)` derived from the
verified owner. Never search by name, candidate device or Olm digest. It returns exactly:
`{mode, generation}` where mode is `absent`, `active`, or `banned`; absence gives
`0`. It does not perform RPC or grant admission. Owner proof only discloses the
membership of that owner/identity. For existing membership require stored owner,
genesis/program/PDA/name match; mismatch is `identity_mismatch`, not new admission.
For absent membership inspect does not assert name registration exists.

User flow: inspect with persisted fresh candidate -> show current membership ->
explicitly choose enroll or replace -> persist operation and observed generation ->
commit. A generation conflict requires a new user-confirmed inspect/replacement,
never an automatic eviction loop. Transient failure retries use the SAME intent.

Status proves candidate device key and matches the entire stored credential plus
identity tuple/owner/name. Return `{mode, generation, operation}`. Active exact
current binding returns `active` (or `banned`), current generation and mutation
operation. Retired exact binding returns `revoked`, its retired generation and
original operation. Unknown or differently bound credential returns `absent`,
`0`, and empty operation. Unknown status says nothing about identity membership.
Authenticated device status can run offline from RPC and with locked owner storage.
Generation alone is never authority. No device or membership metadata is returned
until proof and exact binding check succeed.

Only the current generation stores the full immutable mutation intent digest and
success result; retired binding tombstones retain original operation, generation,
identity and credential. No durable entries for inspect/status or failed mutations.
An exact retry of a current mutation returns its original success BEFORE comparing
current generation, quotas or doing RPC, but AFTER dual proof, current admission (only membership not banned),
full intent digest and binding validation. A banned membership returns banned.
A retired candidate always returns `device_revoked`; never reactivate it.
Different intent with current operation or reuse of a retired operation for the
same membership gives `operation_conflict`. Tombstones allow detecting that reuse.

Intent digest is SHA256(LP("paranoid-identity-intent-v3", purpose, operation,
genesis, program, identity, owner, name, credential_fingerprint,
expected_generation)). Ephemeral id/nonce/epoch/expires are excluded. Realm/pin,
account/device are transitively bound by validated credential_fingerprint.
Lost reply never changes expected_generation: challenge only echoes the client's
saved original value. If no commit happened, status is absent and exact original
commit can retry. If committed, status identifies the operation; exact commit retry
retrieves the same result. If replaced again, old status/retry says revoked.
Local intent/state uses durable write-intent and readback; ambiguous storage failure
fails closed, preserving bytes, never recreating keys or dropping pending intent.

## Commit and registry gate

Commit consumes dual-proof challenge, then cheaply checks DB for exact current
retry or terminal conflicts before RPC. This preliminary read is only a hint;
no mutation/result permission relies on it without the final ss_meta lock check.
Before successful finalized registry verification, hints/errors may reveal only
the proven owner identity: exact own retry, own banned/generation/cooldown/cap,
or own retired candidate. Never check cross-membership name/binding uniqueness
for externally distinguishable errors before RPC. Those conflicts are checked
only under the final ss_meta lock after successful registry verification; a
name collision fails closed as generic identity_invalid. All cross-membership
post-RPC binding collisions also return generic identity_invalid; do not identify
which foreign field collided. Own-identity stale candidate remains device_revoked. Foreign-name inspect
with a caller-owned owner/PDA is indistinguishable from an absent random name.
Fresh mutations first reserve a global verification-start budget: at most eight
starts per fixed 60-second monotonic window, persisted with conservative wall-time
restart handling; clock rollback denies starts until the stored window expires.
This is separate from success counters, has no identity/IP map, and is consumed
on failed attempts too. Exhaustion returns 429 before any RPC. Reserve a semaphore
permit without waiting before spending a start token.
Fresh mutations query only configured HTTPS Devnet RPC (no redirects), verify
expected genesis and the pinned loader/ProgramData owner/authority/size/artifact
from the same shared Rust `program_info` source as RFC0026. Call order is mandatory: first fetch both identity/name
PDAs in one finalized response and fully validate canonical derivation, owner,
layout, name, mutual links and padding. No client-supplied RPC result is trusted.
Only after the pair is structurally valid and matches the signed owner/name
perform genesis and loader/ProgramData verification. No success before ALL checks.
No positive/negative registry or artifact cache in this first slice.

One semaphore limits RPC verification to two concurrent commits, zero waiter queue.
Whole verification budget is 6 seconds (includes genesis, loader and PDA calls).
The pinned SBF size from blockchain/solana/client/src/lib.rs program_info is
73800 bytes is the ELF length, not a freely extensible allocation. The current
RFC0026 deployment pins allocation with no spare bytes; require exact decoded
ProgramData length 45+73800 and request encoding="base64", never base64+zstd.
Any extension requires reviewed pin/cap changes, not automatic acceptance.
ProgramData has the loader metadata prefix (45 bytes), so the current
base64 payload bound is `4 * ceil((73800 + 45) / 3)`. Allow an additional 16384
bytes for its JSON envelope. Derive this cap from the same pinned size rather
than keeping a second artifact constant. Other RPC responses cap at 65536 bytes.
Streaming caps apply before JSON decode; oversized replies fail closed.
Before DB commit recheck proof expiry and require verification completed at most
2 monotonic seconds ago. If lock acquisition misses that freshness window, return
retryable registry_unavailable; do not hold SQL locks during RPC or retry infinitely.
A dishonest RPC and upgrade-after-check remain explicit residual risks, not proofs
of chain correctness. All uncertain/malformed/partial results fail closed.

Final transaction takes `SELECT id FROM ss_meta WHERE id=1 FOR UPDATE` first,
then membership/binding rows. All ordinary authorization and replacement use that
same order and gate. Re-evaluate exact retry, tombstone/operation conflicts,
admission, expected generation, quotas and registry freshness/expiry under lock.
Enroll requires absent membership plus configured self-admission=true and capacity.
Replace requires active membership and expected_generation=current; new candidate
identifiers must never have been used. Root/auth must also be distinct from each
other. Banned membership cannot enroll/replace, even with a new operation.

Atomically create new transport binding and current-result record; for replacement
retire the old one, advance generation once and delete its ss_push_tokens row.
Old transport rows/keys remain immutable, inactive and permanently non-reusable.
Result is exactly `{operation, membership, generation, account, device,
credential_fingerprint, mode:"active"}`. Success only after durable transaction
commit. DB crash/cancellation before commit changes nothing; lost reply after commit
is recovered via status/exact retry. No automatic DB rollback across generations.

## All authorization surfaces and retirement

The following are the ONLY permitted surfaces in v3 mode. Default unknown route
is 404. Existing legacy modes are unchanged. New mode needs its own explicit
router; do not expose legacy routers and hope handler checks are sufficient.

| Surface | Required gate |
| --- | --- |
| v0/v1 and v2 registration challenge/commit | Disabled: 404 |
| v3 challenge | Strict cheap syntax, pins, credential; global ingress only |
| v3 inspect/commit | Dual proof, consumed nonce, exact rules above |
| v3 status | Device proof and exact historical binding |
| v2 auth challenge | Existing proof contract; known exact active v3 binding |
| v2 auth verify/session | Existing device proof; locked active membership/generation |
| v2 messages GET/POST | Proof or signed session; locked sender active generation |
| v2 events | Signed session; gate at initial read and final completion |
| v2 push | Signed session; locked active generation; never register for retired key |
| v2 voice TURN endpoint | Existing auth plus locked active generation at issuance |
| Android update metadata/APK | Existing pinned update contract; no account privileges |
| health/readiness | Generic health only, no identities or membership |
| admin/lookup/invite/federation | No new public routes; 404 |

Before implementing, enumerate the actual route strings from the router and test
this allowlist against it. TURN endpoint name comes from the existing voice contract,
not a new alias invented here. Session record stores membership+generation
server-side; no change to its existing signed wire format is necessary because
credential fingerprint identifies exactly one lifetime generation.

Under the ss_meta lock all REST/session authorization rechecks active account,
exact binding, membership state and generation. Old operations authorized/committed
before replacement may complete network delivery afterward: bytes already handed
to transport cannot be recalled. No operation authorizing after replacement can
succeed. Recheck event completion under lock; invalidate old sessions and notify
waiters after replacement, plus existing bounded idle recheck. No claim that socket
closure can retract bytes already authorized. Calls already peer-to-peer may persist;
stop new signaling/grants, not arbitrary remote media. Test existing TURN expiry
and expose its actual bound separately before phone release.

For messages, the SAME locked transaction checks recipient is active before insert.
A retired recipient yields `recipient_retired`, no insert or one-check ACK. Other
missing/banned recipients yield existing generic recipient error. This intentionally
reveals retirement to authenticated senders who know an opaque account ID.
Existing v2 challenge/401 behavior can additionally reveal active/retired status
to anyone holding the public contact credential; this is a disclosed residual, not a
public name directory. No name->account directory or automatic contact replacement.

Push deletion stops new lookups; an FCM request already dispatched before revocation
may still arrive. A queued wake must revalidate recipient binding immediately before
dispatch; no unbounded retries retaining retired tokens. In-flight wake is content-free
and cannot grant access. This finite residual timing leak is disclosed, not hidden
behind an impossible atomic database/external-FCM promise.

## Explicit resource budget

Retain existing total ingress 20/s, auth ingress 8/s, global limiter windows and
no attacker-indexed IP/identity map. The v3 pool is separate from all v2 challenge/session pools. Max 64 pending v3
challenges globally, 60s TTL,
no unexpired eviction; replay attempts fail. Two RPCs as above, 10s total handler
budget; existing event timeout unchanged. Apply caps before expensive work.

Membership cap 128; total lifetime transport binding cap 1024 (including tombstones),
matching existing account capacity. At most 8 generations per membership, including
initial enrollment: reserve eight transport slots at admission, not on replacement.
Thus another identity cannot consume slots needed by an admitted user's replacements.
No automatic pruning or deletion to regain capacity. Once generation 8 is active,
status and existing traffic keep working; further replacement returns
`replacement_limit`. UI displays remaining replacements after authenticated inspect
via a locally computed MAX minus generation; no extra response field. This is an
explicit CLOSED-ALPHA limit, not unlimited production recovery. Owner disposition
must acknowledge it. Future recycling/archival requires a reviewed migration.

At most one successful replacement per membership per 24h, stored on bounded
membership row; initial enrollment does not start this cooldown. Exact current
retry bypasses cooldown. Durable timestamp checks are conservative on backward
clock movement (deny new replacement; never reopen allowance). No per-untrusted-key
rate map. Global mutation successes <=8 per 60s under ss_meta, persisted across
restart. Exact current retry/status/inspect bypass success quotas, not ingress.
Existing message/storage/session limits remain; retired inbox is never moved to
new keys or automatically erased. New sends to retired inboxes are rejected.

## Client and recovery security

Common identity/name remains the user's account, with device-bound transport under
it. Restoration requires seed; no operator escrow. The current RFC0026 key stays
Keystore-wrapped as today. Explicit authentication UI is required for owner signing,
including replacement; no background owner signer. This does NOT protect a
compromised/unlocked phone holding that key: it can compete for replacement.
Seed compromise is authority compromise; current registry has no rotation. Cooldown
bounds churn but cannot choose the rightful owner. UX and ADR disclose this; strong
compromised-device recovery is deferred, not claimed. Status/messages need only auth.

Replacement uses fresh contact exchange and new conversation. Verified contact pins
are never overwritten; old ciphertext cannot be decrypted by the new device. Existing
peer caps (16 unverified, 64 total) still apply; no delete/readd shortcut or silent
reset is introduced. Phone release must display a clear capacity error, and disclose
that repeated contact replacement can exhaust this bounded alpha; production needs
a separately reviewed archive/replacement mechanism. Loss of current TEST chats and
contacts is a transition waiver, not permission to erase future state at capacity.

## Errors and acceptance

Proof failures are generic 401, consume only valid proofs; challenge syntax errors
400, caps 429, unknown disabled route 404. After authenticated proof: absent/active/
revoked/banned status as above; conflicts 409 (`generation_conflict`,
`operation_conflict`, `binding_used`, `identity_mismatch`, `device_revoked`,
`replacement_limit`), policy rejection 403 (`admission_denied`), unavailable RPC 503
(`registry_unavailable`), invalid finalized registry 403 (`identity_invalid`).
No unsigned response reveals membership; no seeds/keys/proofs are logged. Errors
never trigger key recreation, legacy fallback or automatic replacement.

[Public primitive vectors](identity-login-v3-vectors.json) are generated independently
by `scripts/identity-login-v3-vectors.py` using Python cryptography/OpenSSL.
They use deliberately fake registry/PDA/credential fields and public fixture seeds;
they validate exact LP/signature bytes ONLY, not semantic registry acceptance.
Actual canonical full-identity and parser-negative vectors remain implementation gates.

AUTH-01: independent LP/hash/Ed25519 vectors, exact types/limits, duplicate/unknown
fields, field-by-field mutations, role/purpose/path separation.
AUTH-02: exact pins/PDA/layout, RPC lies/outages/size/timeout/freshness, no pre-proof RPC.
AUTH-03: replay/expiry/restart, challenge oracle equivalence, global capacity bounds;
foreign name with owned owner/PDA vs random absent name; no pre-RPC cross-membership
binding conflicts and bounded failed verification starts, including valid-proof
challenge consumption followed by start-budget 429 (requires a fresh challenge).
AUTH-04: PostgreSQL races, lost commit replies, same immutable retry, crash boundaries,
retired operation replay, status with absent/retired/current candidate and locked Android owner-key storage (not a SQL lock).
AUTH-05: every route/session/realtime recipient gate; rebind old identifiers via a
second identity; lock ordering; push token deletion and bounded in-flight disclosure.
AUTH-06: E2EE first contact/reply/receipts, fresh-contact replacement, retired-recipient
rejection, peer capacity error, no pin substitution or old-history recovery claim.
AUTH-07: Android persistence/restart/seed recovery, old auth rejection AND hostile
old-owner re-replacement attempt (disclosed limitation), explicit UI confirmation.
AUTH-08: TURN/media revocation measured separately; generation 8/cooldown/128-member
capacity with active traffic/status still working; no lifetime login-operation ledger.
All are planned, NOT RUN until a dated implementation receipt says otherwise.
