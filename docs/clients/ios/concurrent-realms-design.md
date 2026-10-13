---
status: draft
owner: ios
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-10-13
---

# iOS concurrent realms: RFC-0030 design candidate

This is part of [RFC-0030](../../rfcs/0030-ios-identity-v3.md), not a new
accepted contract. Yaroslav requested the next design step on 2026-10-13,
following Sergey's product direction recorded in PR #73: both named v3
servers, simultaneously in one installation. The owner chose the outcome,
**not the technical choices below**. Permanent product/scope evidence,
technical disposition and implementation authorization retain the RFC's gates.
No implementation, native execution, phone result or live authorization is
claimed. All MR acceptance gates below are NOT RUN.

[Independent design-review closure](https://github.com/GOTD-GLOBAL/ParanoID/pull/74#issuecomment-6142060431)
covers design revision `71eda964b6f41986c0e85c43ed88676807f753df`, with four
initial findings fixed and closed in a fresh-context delta review. All reviewers
used gpt-6-astra; no human audit/acceptance is implied. This evidence pointer
is a later documentation-only addition, not a claim that a future changed
design or implementation has already been reviewed.

## Scope and source baseline

The candidate targets exactly two compiled identity-v3 profiles:

- Finland: `https://157.180.49.125:38444`.
- Russia: `https://138.16.180.53:38444`.

Use the full saved pins in [RFC-0030](../../rfcs/0030-ios-identity-v3.md#server-profiles),
not a fresh lookup or a user-entered pin. Those source values were not
revalidated against live hosts during this design task. Debug/local testing
uses two separately pinned synthetic realms and two isolated server databases;
it must not dial either hosted profile or Devnet by default.

Simultaneous means that, while foreground delivery is permitted, each joined
realm can receive and send without selecting its screen. Choosing the visible
server changes the UI scope, not the active transport. This does not add
federation, forwarding, transparent failover, background delivery, APNs,
Universal Links, several phones per membership or two simultaneous media calls.

Source review baseline is PR #73 commit `a9e7336`. Important facts, not tests:

| Existing boundary | Source at that baseline | Design consequence |
| --- | --- | --- |
| Core state is single-realm; existing state cannot change its realm/pin | `clients/core/src/lib.rs:438-489`; `clean_service.rs:8-21` | Use independent core states, never repoint or clone one |
| Bridge takes explicit state and request | `clients/ios/bridge/src/lib.rs:28-55` | Two state owners can use the same ABI; concurrent execution still needs tests |
| Membership is server-local; proofs bind full realm/pin | `docs/protocol/identity-login-v3.md:62-93,154-169` | A shared owner does not share device credentials or generations |
| Existing Swift wrapper is v4, one state; wrong version refuses | `clients/ios/ParanoidKit/Sources/ParanoidKit/Service/Snapshot.swift:149-184,206-228` | New app-level storage format and downgrade refusal need explicit design |
| Key/file XOR freezes; first commit is not an atomic Keychain/file transaction | `clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/StorageGuard.swift:25-36`; `SnapshotStore.swift:110-161` | Never regenerate a missing half or treat partial creation as fresh |
| App starts one runtime after storage opens | `clients/ios/App/ParanoID/AppModel.swift:305-358` | Coordinator, metadata and final UI callback ownership must change |
| Transport has per-instance trust but currently allows only health/v2 paths | `clients/ios/ParanoidKit/Sources/ParanoidKit/Net/RealtimeTransport.swift:159-165,257-263` | Two URLs alone do not implement v3 login/directory |
| Audio session is process-wide despite per-coordinator state | `clients/ios/App/ParanoID/Voice/AudioSessionController.swift:236-277` | One media/resource arbiter, not two unchanged call coordinators |

No necessity to change shared core, server or wire was identified in that
source review. This is a feasibility hypothesis, not a proven component
boundary. If the implementation cannot satisfy it, stop and propose a scoped
contract change rather than weakening a gate or silently editing a red zone.
Known pre-existing RFC-0030 discrepancies remain reported, not repaired here.

## Candidate choice and alternatives

Recommend **one owner identity and independent realm runtimes**, with standard
existing Rust cryptography and unchanged server-local identity-v3 exchanges.

- A single mutable `activeRealm` with one core fails simultaneous delivery and
  risks sending an old outbox under another trust pair. Do not use it.
- One aggregate messaging snapshot makes every realm's write/failure depend
  on the other and expands the existing whole-snapshot cap. Not preferred.
- Two unrelated nickname owners increase recovery burden and are not needed
  by the stated product direction. Keep this alternative visible for human
  disposition; common-owner correlation is a real consequence of the proposal.
- Two full app runtimes without coordination duplicate physical audio/camera,
  lifecycle observers and nominally global call budgets. Not sufficient.

The candidate choices in this document remain open for human disposition;
they are not derived permissions from the phrase "maximum rights".

## Identity and ownership

One installation retains one nickname authority:
`(genesis, program, identity PDA, owner public key, canonical nickname)`.
Registration happens once on Devnet, through one explicitly selected sponsor.
Joining the second server does not register or sponsor another nickname.

For each realm, generate independent random root/auth/device/Olm material using
the existing core, never by deriving transport keys from owner words or copying
the other realm's snapshot. Each server separately owns membership UUID,
generation, admission, replacement cooldown, capacity and bans. This assumes
independent, correctly configured realm databases; live topology is unverified.

Use these typed internal targets (names are proposed, not exported APIs):

```text
RealmKey = (exact HTTPS origin, full SPKI pin, protocol kind)
RuntimeTarget = (RealmKey, installID, runtimeIncarnation, credentialFingerprint)
OwnerOperationTarget = (installID, ownerRef, operationID, phase, targetContext)
PeerTarget = (RuntimeTarget, peerAccount)
CallTarget = (PeerTarget, callID, callGeneration, mediaLeaseEpoch)
```

A compiled slot ID is only a bounded path/display identifier. A short link
server ID, nickname, account ID or generation counter alone is never authority.
Runtime incarnation changes whenever a runtime is replaced, resumed into a new
run or loses authority; runtime-local generation checks remain necessary too.
Every delayed network, permission, timer, UI and renderer completion validates
its captured target at the final consuming boundary, not only when scheduled.

```text
Application coordinator (short decisions; no awaited I/O under its lock)
  |-- sealed install catalogue and serialized owner-operation coordinator
  |-- process lifecycle/network observer
  |-- one call admission + media/resource arbiter
  |-- Finland: StateOwner -> client/core -> sealed store -> pinned lanes
  `-- Russia:  StateOwner -> client/core -> sealed store -> pinned lanes
```

Each realm owns session nonces/sequences, event cursor, outbox, delivery state,
contacts and verification/block state, directory visibility and publication,
login intent, membership state, drafts and local metadata. Even if fixtures
reuse account/call IDs, these objects do not collide. Common owner authority
is never a shared messenger credential or a global `replaced` flag.

## Versioned persistence candidate

This is a new iOS storage proposal; the existing store does not implement it.
The core schema and embedded per-realm Snapshot v4 remain unchanged.

```text
Application Support/paranoid/
  text-state.enc             # authenticated install catalogue, JSON version 5
  owner/state.enc            # owner envelope v1, separate wrapping key
  owner/write.pending
  realms/fi/state.enc         # realm envelope v1, separate wrapping key
  realms/fi/write.pending
  realms/ru/state.enc
  realms/ru/write.pending
  ... per-store temporary files and existing install marker
```

The catalogue deliberately occupies the existing `text-state.enc` path and
uses the existing `paranoid-text-state-v0` Keychain account and messaging
protection class. With the catalogue and its key intact, the checked old
reader decrypts it but rejects JSON version 5 before constructing a runtime.
This is not protection against loss of both legacy objects; the supported
rollback boundary below explicitly excludes unsafe old-reader downgrades.
The current version-1 AES-GCM envelope can seal this small catalogue; do not
invent a cryptographic primitive or silently reuse a format number with changed
meaning. The per-store codec reuses standard CryptoKit AES-GCM, with explicit
per-type size limits and authenticated plaintext context.

Catalogue v5 contains `minReader`, random `installID`, owner reference, an
optional **confirmed registry binding** (absent before finalized verification),
and exactly two fixed slot descriptors
with full RealmKeys and monotonic `unallocated`/`allocated` flags. Unknown
versions, duplicate fields, unknown slots, invalid descriptors or unsupported
limits fail closed. The owner reference is not secret key material.

- **New nickname:** reserve owner allocation durably before generating/storing
  entropy. Commit owner material with derived owner public key/PDA and
  genesis/program in the `unregistered` phase; a candidate name is not a
  confirmed registry binding. This permits the explicit registration flow,
  but no realm allocation/enrollment yet. Before any signed request leaves
  the phone, durably record the exact sponsor RealmKey and pending attempt
  in the owner store. The catalogue's confirmed binding remains absent.
- On finalized paired registry verification, commit `registryConfirmed` in
  the owner store, then publish the matching confirmed binding in the
  catalogue. Only a matched durable pair allows realm allocation. A crash
  between the two commits preserves owner bytes/ledger and refuses realm
  onboarding; it never regenerates entropy or treats a tentative name as
  confirmed. Ambiguous persistence follows the freeze rules below.
- **Recovery:** first derive and verify the nickname through read-only RPC
  using volatile entered material. If no nickname exists, verification fails
  or the user cancels, perform no recovery-related catalogue allocation or
  owner/realm write. No automatic registration follows. Only after successful
  verification allocate and commit the owner store as `registryConfirmed`,
  then publish the matching catalogue binding. Existing committed state is
  never overwritten by an unsuccessful recovery attempt.
- Reserve a realm's allocation in the catalogue before its first key/core
  creation. Allocation never returns to `unallocated` in this candidate.
  A missing key **and** file for an allocated slot is loss, not a new slot.
- Realm envelope v1 contains installID, full RealmKey, public owner binding,
  embedded Snapshot v4 with core state preserved verbatim, pending immutable
  login intent, confirmed membership result and terminal membership state.
  The same atomic realm commit stores core and login bookkeeping together.
- Owner envelope v1 contains entropy, derived owner/PDA, explicit phase,
  optional confirmed registry binding, words-backup confirmation and the
  bounded registration-attempt ledger. Phases are `unregistered`,
  `registrationPending`, and `registryConfirmed`; durable catalogue allocation
  precedes creation of this envelope. `registrationPending` carries candidate
  name and exact attempt bytes, never a forged confirmed nickname. Registry
  uncertainty stays pending; no new candidate name while an attempt can land.
  Recovery enters only `registryConfirmed` after verification. This store
  does not hold the only copy of realm login intent/device/revocation state.
- Owner key: proposed `WhenUnlockedThisDeviceOnly`, file protection complete;
  catalogue/realm keys and files retain messaging protection semantics. All are
  non-synchronizable and excluded from backup. Existing key/filesystem adapters
  must become explicitly parameterized; two default instances are insufficient.
- Each decrypted envelope must match its expected store kind, installID,
  owner reference/binding and full RealmKey before any core/network operation.
  Keys are distinct; swapping files or whole store directories fails validation.

Proposed parser/storage caps: catalogue and owner plaintext each at most 64 KiB;
realm metadata at most 128 KiB in addition to the unchanged core 8 MiB input
cap. Embed core JSON without string escaping or a second full copy. Bound the
complete serialized realm envelope and parser allocations by those component
caps; document exact byte layout and fixtures in the implementation PR. The
existing SnapshotCodec's 8 MiB **whole-plaintext** cap cannot be advertised as
already supporting the enlarged envelope. Overflow refuses before mutation;
no pruning of history, intents or unresolved registration evidence to make room.

### Commit and crash rules

Only that store's serial owner may write it. Catalogue/owner I/O runs on its
own serial executor, never by holding another realm's executor across I/O.
Store initialization and subsequent commits follow:

1. Validate catalogue, allocation flag, identity and key/file continuity.
   A Keychain error or inaccessible protected file is not absence.
2. Persist/full-sync the write-intent marker **and sync its parent directory**
   before key creation or candidate writes; file sync alone is insufficient.
   Creation of a wrapping key occurs only on the first commit of a
   genuinely unallocated-to-allocated store;
   verify its retained bytes by readback. No error deletes that key.
3. Write the candidate to a temporary inode, set its protection and backup
   exclusion, full-sync it, rename, read back exactly, and sync the directory.
4. Remove the write-intent marker and sync the directory again.
5. Only then adopt state, publish UI/connected success, acknowledge receipt or
   send anything derived from the candidate.

Any failed/ambiguous step breaks that store for the process. After restart,
a leftover intent marker, unsupported framing, context mismatch, missing
allocated state or key/file XOR freezes it while preserving evidence. Never
choose an older snapshot or recreate keys as recovery. This conservative rule
may freeze after a completed rename if the final acknowledgement was lost;
crash-transparent recovery is **not** promised.

Boot checks all known stores, temporary files and intent markers before any
stale-Keychain deletion. Missing install marker with any surviving artifact
freezes globally. Missing/corrupt catalogue in a retained installation also
freezes globally. Only an actually empty fresh installation permits the
existing scoped stale-Keychain cleanup; a realm is never cleaned independently
as if it were an app reinstall. A catalogue write failure stops both runtimes.
An isolated realm-store failure stops that realm only if catalogue and sibling
integrity remain verified. Owner-frozen/locked blocks owner operations, not
already authorized device-only traffic/status. Common disk/Keychain failure
can still stop both. Complete loss/rollback of container and markers is not
detectable anti-rollback; AEAD and the words do not restore message ratchets.

## Per-realm login and recovery

Every operation captures its full target before UI suspension or authentication.
Before a realm runtime exists, OwnerOperationTarget binds the proposed owner
phase and exact purpose: fixed chain context for read-only recovery, selected
sponsor RealmKey for registration, or RealmKey plus retained candidate/intent
for login. It never fabricates a RuntimeTarget with nonexistent credentials.
An owner-operation coordinator serializes explicit foreground signing and
sponsor registration; it never holds a realm state queue during a prompt/RPC.
One owner prompt authorizes its displayed operation and chain/sponsor/realm
target, not all future operations or an automatic second enrollment.

Owner operations and call admission share one process-wide exclusive admission
state: `idle`, `ownerOperation(lease)`, `call(CallTarget)`, or `closing`.
The chosen policy is **first admitted wins, no preemption**. Acquiring an owner
lease before authentication refuses/defer-prompts while a call/closing state
exists; a valid incoming offer while owner work holds the lease receives the
existing authenticated `busy` on its own realm, with no ring/media admission.
Outgoing call intent similarly fails visibly rather than queuing an automatic
future call. Device-only messaging/status needs no owner lease.

A short critical section changes this state; it is not a global lock held over
Face ID, network or storage. The owner lease has its operation's finite deadline
and is checked again after authentication, immediately before Rust signing,
and before submitting bytes. Late auth callbacks after expiry/cancellation
cannot sign or send. Cancel/expiry fences the lease, cancels work and enters
`closing` until the signer/submission path is quiescent; only then may a call
acquire authority. An already dispatched mutation is not recalled: retain its
intent/ledger as unknown outcome and reconcile without new owner signing until
a fresh explicit owner lease is admitted. A late device-only result may be
reconciled under its realm target, never clear another operation's intent.
A hung closing path denies new owner/media authority visibly, not sibling text.
No owner signer may run concurrently with an admitted call on either realm.

1. For an explicitly added, allocated slot, create a fresh core identity for
   its full trust pair, commit it, run `upgrade_v2`, then commit schema-3 state
   before any identity-v3 proof. The public dispatcher requires that upgrade.
2. Device-only `status` checks the exact local candidate. Active saved binding
   can resume without owner signing. No status request asks about the sibling.
3. If enrollment/replacement is needed, use explicit owner/device `inspect`,
   display the named realm and consequences, and obtain a decision. Persist
   the full immutable intent before the first mutation challenge: operation,
   purpose, expected generation, identity binding and credential/fingerprint.
4. Each new challenge is compared with retained intent and trust, signed in
   Rust and posted once. Transport failure means unknown outcome, not failure
   of the remote commit; do not generate a different operation or credential.
5. Reconcile using fresh device-only status; if needed, retry the exact retained
   commit with a new challenge and explicit foreground owner authority. A retry
   preserves the original operation/expected generation. Never replay a proof.
6. Status is `{mode,generation,operation}`, not the full commit result. For a
   pending intent, active status must agree with its operation and credential
   context; obtain an exact commit retry if the full result is required. Never
   synthesize account, device or membership fields absent from the response.
7. Persist the validated result and core `server_status_v2` in one realm
   envelope before clearing the intent with another durable commit. A crash
   before clearing is an idempotent reconciliation case, not a fresh login.

If retained intent and core credential/RealmKey disagree, refuse the operation,
preserve both original byte sequences and freeze that realm. Do not discard
or replace the intent or start a new operation to get past the inconsistency.
An explicit, separately reviewed recovery procedure is needed; this candidate
provides no automatic repair. Sibling operation remains subject to verified
catalogue/sibling integrity, not the faulty realm's assertions.

`generation_conflict` requires a new user-confirmed inspect; `revoked` or
`banned` stops only that realm and revokes any media lease it owns. `absent`
after server reset is a displayed recovery condition, never automatic enroll.
If local persistence of terminal state is unavailable, fence that runtime in
memory immediately and require fresh device status before reconnect on restart.
No network-derived terminal flag alone replaces durable state validation.

Recovering words restores the one owner authority, not either device state,
contacts or history. A fresh installation independently offers restoration of
A and B; each realm may enroll, require replacement, be banned or hit its own
cooldown/capacity. Partial recovery remains visible and does not roll back or
evict the successful realm. The old device retaining owner material may still
compete for either membership; this is not secure recovery after seed theft.

## Concurrent transport and bounded scheduling

Use one StateOwner, pinned transport group, ProofFlow/session state and realtime
run per joined realm. Do not reuse sessions, cursors, retry budgets or caches.
Never hold a process-global lock while a realm waits on network, storage or
Rust work. UI and async listener publication are tagged with RuntimeTarget and
checked again on MainActor. Switching the viewed realm does not reset runs.

The implementation must bound waiters as well as sockets. Proposed application
scheduler budget, to be tested rather than mistaken for an existing guarantee:

- At most one receive lane and one immutable-outbox sender per realm.
- One foreground identity mutation globally, plus one coalesced device-status
  reconciliation per realm. Owner prompts and mutation challenges do not queue
  behind an unbounded stream of directory work.
- One directory request active and one latest unsent user query per realm;
  a new query replaces only the unsent query, never mutates an in-flight request.
- Transport keeps its existing finite socket limits; add a finite maximum of
  eight pending transport tickets per realm and eight globally pending owner/RPC
  work tickets, with cancellation removal and deadline expiry before dispatch.
  Repeated UI taps coalesce or return a visible busy result, never spawn waiters.
- Identity/readiness/control work is admitted ahead of unsent directory work;
  this does not reorder already ratcheted envelopes in an immutable outbox.
  Reserve receive/send progress so directory saturation cannot starve either.
- Coalesce network hints. Preserve ordered lifecycle edges using a bounded
  mailbox; overflow forces a conservative stop/fence and explicit foreground
  reconciliation, never dropping a background/freeze edge and continuing media.

Backoff remains per realm/lane; the current implementation grows from 0.5 to
16 seconds plus jitter below 250 ms (`Realtime/Backoff.swift`), not a measured
30-second schedule. Success in A does not reset B's backoff. Respect server
retry/rate-limit responses; a manual retry never clears a server budget.
All queued work has a finite deadline, bounded by its parent operation and
existing route/call deadlines; an expired ticket sends no request.

One process lifecycle/network observer fans out ordered events. Foreground
allows both connections. Background with neither an admitted call nor a valid
post-call drain stops both. During call A, only A's permitted signaling survives;
B does not gain background messaging. Preserve the existing post-call window
(`LifecyclePolicy.swift:200-203,257-290`) **only for the former call-owning
realm**: on its single transition to ended, capture a drain token with that
RealmKey/runtime/call epoch and an absolute monotonic deadline ten seconds
later. It permits the existing final control/receipt drain, not new calls,
owner signing or background permission for the other realm.

The drain token is separate from the already revoked media lease. Stop that
realm on the original deadline even if requests/callbacks are pending; freeze
or confirmed authority loss stops earlier. Late ended events, reconnect,
network hints and scope changes cannot rearm or extend it. A newly admitted
call clears the prior drain token; two background exceptions cannot accumulate.
Permission-sheet resign-active is not background. Preserve microphone/camera
consent and existing call deadlines; reconnect cannot renew them.

## One application-wide call and media owner

Retain the voice contract's at-most-one ringing/negotiating/connected call
across the entire app, not one per realm. Keep realm-local authenticated
signaling controllers, with one global admission/media arbiter and one audio,
tone, proximity/idle and camera resource owner.

- An explicit outgoing intent reserves the call slot; an authenticated,
  nonce/readiness-validated incoming offer requests admission before ringing
  or media authority, through the same exclusive admission state as owner
  operations. A knock alone never reserves physical media.
- Admission is serialized in a short critical section. The losing realm emits
  existing authenticated `busy` through its own committed core/outbox, without
  new wire kinds, automatic answer, ending the winning call or a second prompt.
  Existing same-peer crossing-call busy semantics remain unchanged.
- A granted lease includes CallTarget and a unique lease epoch. Answer, mute,
  camera, TURN, renderer attach/detach, tone and cleanup callbacks validate it.
  Freeze/confirmed authorization loss revokes the matching lease synchronously;
  it does not revoke a call belonging to the other realm.
- Handoff waits for old media teardown and tone-stop acknowledgement. Late
  release from A cannot touch B. A stuck teardown denies new media activation
  visibly, while independent messaging continues; never activate both engines.
- Retain one application-wide readiness/knock/terminal budget rather than
  multiplying each controller's limits. The existing 8 readiness slots,
  6 peer knocks/minute and 24 global knocks/minute apply across both realms;
  the peer key includes RealmKey. Overload refuses, not evicts live consent.
- QR scanning participates in the same camera ownership: no scanner start
  during an admitted call; call capture waits for scanner-stop acknowledgement.
  Camera permission grants do not automatically grant a capture lease.

The existing one-retry signed-session 401 rule remains bounded; the first
ambiguous rejection is not falsely classified as permanent revocation.
Confirmed authorization loss/second rejection ends the matching media authority
immediately. Device-only v3 status can classify the realm afterward without
reviving the ended consent. TURN/direct/legacy fallback behavior must be
reviewed for v3 explicitly; no fallback to another realm's credentials is valid.

## UI, directory and contact links

The UI shows distinct connection/membership status for Finland and Russia.
The selected view is not a global `isConnected` boolean. Use text server labels
in chat header/composer, send confirmation when needed, call screens/return
bar, contact confirmation, directory, own card and visibility controls; include
them in accessibility labels, not only color.

Capture PeerTarget on tap before the first await. On later scope change, finish
the clearly identified original operation or cancel it; never redirect it to
the current view. Key drafts, send tickets, local names, seen marks, call logs,
block and verification state by full realm scope plus account. Two occurrences
of a nickname are not an instruction to merge history or verified identity.

Directory search is explicit and scoped to one realm, not an automatic fan-out.
Pair only after local core proof verification, finalized registry verification,
confirmation naming realm and fingerprint, and core pairing on the same target.
Changes between preview and confirmation invalidate the preview. Publication
and visibility are independent per membership; do not infer opt-in on B from A.

A pasted contact link's short server ID (first 16 hex of the pin) is a routing
hint. Resolve against all compiled profiles: zero or multiple matches refuses
with no join/pair/repin, including shared TLS keys on different origins. One
match may offer an explicit switch to that realm's view if it is already
joined. Otherwise show that membership is needed and offer ordinary explicit
onboarding, without automatically performing it. Keep the current chat/draft
unchanged. Universal Links/domain files and invitations remain separate work.

## Failure, migration and rollback

| Failure | Required containment |
| --- | --- |
| A timeout/offline/429/507 | B continues; A retains its outbox and own retry state; no reroute to B |
| A pin/protocol mismatch | A fails closed without repin, redirect or v2 fallback; B trust unchanged |
| A revoked/banned/absent | A's state is displayed, no automatic owner action; B remains independent |
| A local realm commit fails | Fence A and its media immediately; B continues only with verified integrity |
| Owner locked/frozen | No owner operation on either realm; intact device-only traffic/status may continue |
| Catalogue/installation continuity fails | Global freeze; preserve all bytes/keys, no partial restart |
| Shared disk/OS resource failure | Disclose possible impact on both; no false isolation guarantee |
| A recipient retired | Do not endlessly retry its envelope; preserve history/ciphertext and surface a terminal send disposition; the implementer must prove unrelated peers continue without violating core outbox ordering |
| Late A UI/media callback after B starts | Target/lease mismatch is a no-op for B |

No migration is executed by this proposal. Existing v2 installs remain in the
legacy path, retaining their trust, files and metadata; they are not silently
converted into either slot. The first candidate uses explicitly authorized
fresh onboarding, preferably a separately authorized development App ID. An
in-place archive/migration path is a separate scoped design, not a deletion
shortcut or reset action hidden in the connection UI.

With the catalogue **and its legacy key intact**, the inspected v4 reader
rejects catalogue v5 before Runtime construction. Old-new-old-new fixture tests
must verify this narrower property, not a universal downgrade guarantee. If
both legacy objects disappear while namespaced realm files survive, that old
reader cannot see those files and may treat the install as fresh. A v5-aware
reader must detect them and freeze globally. Test this combined-loss case
explicitly and record the old reader as **unsafe/unsupported for rollback**,
not as a passing safe downgrade. This design does not backport detection to
previous binaries or claim the OS prevents users from launching one.

No operational rollback to a v4-only reader is authorized by this candidate,
even after a successful intact-catalogue refusal test. Rollback is a compatible
v5-reading client with the complete continuity scan, or a stopped preserved
installation. Unsupported historical readers are not certified. Never remove
the catalogue/key to make an old build launch, restore old ratchets or decrease
server generations.

## Requirement and acceptance mapping

MR labels are proposed test gates under existing requirements, not new accepted
requirements. Every row is NOT RUN. Use two independent synthetic server DBs,
controllable queues/clocks/I/O and explicit packet/request attribution.

| Gate | Requirements / invariant | Required observable result |
| --- | --- | --- |
| MR-01 | REQ-MULTI-001, REQ-CLIENT-001 | One owner, distinct random A/B device credentials; both enroll and remain active concurrently |
| MR-02 | REQ-SEC-001, saved trust, AUTH-01/02 | Swap A/B proofs, intent, sessions, snapshots and pins; all cross-realm uses refuse before unauthorized side effect |
| MR-03 | REQ-MSG-003/005 | Hold A's long poll while B sends/receives/commits text and receipts before A is released; repeat reversed, restart and no duplicate display |
| MR-04 | REQ-ID-002, AUTH-04/07 | Recover owner once; replace A while B is active; old A stops, B keys/history/generation unchanged; reverse; partial recovery visible |
| MR-05 | AUTH-03/04 | Lost commit reply, restart, cancelled/late auth and crash before intent clear retain the same operation; intent/core mismatch preserves bytes and freezes; owner-lease cancellation after dispatch retains unknown outcome, never signs during a call |
| MR-06 | Persistence / REQ-SEC-001 | Fault every key/marker and marker-parent-sync/write/rename/readback/sync boundary; allocated halves lost, intent/core mismatch, swapped stores, owner lock, corrupt/missing catalogue; correct scoped/global freeze and no key/intent regeneration; combine with MR-07 legacy-pair loss |
| MR-07 | Compatibility / REQ-MSG-004 | Existing v2 retained byte-for-byte; old reader refuses intact catalogue v5 without network/reset; loss of legacy catalogue+key with surviving realm stores freezes the new reader and records old reader rollback as unsafe/unsupported, not a successful safe downgrade |
| MR-08 | REQ-ID-007, REQ-MSG-005 | Directory proof/registry/confirmation same target; changed card, wrong pin, RPC uncertainty and ambiguous link ID add nothing; A visibility does not affect B |
| MR-09 | REQ-MULTI-001 / callback ownership | Force identical account/call IDs and local generations; delayed A responses, MainActor hops, permission results and draft restoration cannot mutate B |
| MR-10 | REQ-CALL-001 / voice consent | Simultaneous offers admit one call; test owner Face ID A then incoming B, and call B then owner A: first admitted wins, no overlapping signer/call, loser busy/refused; cancelled/late auth cannot regain signing authority |
| MR-11 | REQ-CALL-001 / media lease | Delay A teardown, tone stop, TURN, renderer detach and permission while B is next; no stale control of B; revoke/freeze A cannot stop call B |
| MR-12 | Foreground boundary / resources | Bounded lifecycle/network/queue storms and cancellation; no background B during call A; A-ended preserves only A terminal/receipt drain for original ten seconds, late callbacks/reconnect never extend it, deadline/freeze stops it and new call clears old drain |
| MR-13 | AUTH-08, REQ-ID-004/006 | Capacity/cooldown/ban A leaves B valid; new owner allocated/unregistered/pending/registryConfirmed stages survive crashes without false confirmation, pending ledger precedes signed send; recovery without registered nickname writes nothing; realm allocation waits for durable confirmed binding; registration once |
| MR-14 | REQ-SEC-001 / metadata | Logs/crash reports contain no words, owner secret, snapshots, proofs or raw directory queries; correlation and recovery limitations are disclosed |
| MR-15 | REQ-CALL-001 / physical evidence | Real iPhone interruption, Bluetooth/speaker, background camera and scanner contention; same-call deadlines and consent survive target changes |
| MR-16 | Delivered behavior | On an approved phone/peer setup both realms stay connected; text/receipts on both and a call on one while text continues on the other; exact-head Mac, device and server receipts |

MR-01..14 begin on isolated host/simulator fixtures; MR-15/16 require separately
authorized physical sessions. At least one real Android peer must be exercised
on each realm; do not assume the current Android can join both simultaneously.
Use independently enrolled approved test peers or separate named sessions,
keeping the iPhone connected to both. Never reset the owner's daily Android
merely to manufacture this evidence. These tests do not authorize enrollment,
replacement, deletion, fault injection or spending on hosted services.

## Implementation sequence and decision gates

1. **Design closure:** permanent product evidence and exact bounded alpha scope;
   independent review; draft ADR with next available number; no status acceptance
   without the required human disposition and evidence.
2. **Storage first:** versioned codec/catalogue/store specifications and negative
   fixtures, commit/freeze matrix, tested downgrade barrier, scoped metadata.
3. **Dual runtime:** typed targets, independent lanes, bounded scheduling,
   lifecycle fan-out and global call/resource arbiter on local stand.
4. **Identity:** existing Rust Devnet bridge, owner store/RPC and per-realm
   login/recovery; use the unchanged shared derivation and proof algorithms.
5. **Directory/UI:** scoped search/pair/visibility/links, explicit server labels,
   independent outbox/error presentation and registration flow.
6. **Verification:** all MR gates, old v2 regression where touched, exact-head Mac
   tests, then separately authorized physical sessions. Source checks are not
   runtime acceptance. No published delivery estimate until this scope is sized.

Before protected implementation, obtain disposition of: common owner and
correlation; catalogue/envelope/freeze and downgrade choices; global call policy
and scheduler bounds; legacy transition; original owner-auth/RPC/words-screen
questions; remote admission; exact features/devices/data/environments and risk
owner. Product direction belongs to Sergey; technical disposition may use the
recorded human delegation only within its bounds. This design neither moves
that authority to AI nor changes ADR-0014/0016 to accepted.
