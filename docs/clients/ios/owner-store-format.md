---
status: draft
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-10-14
---

# PROPOSED catalogue allocation and owner-store contract

Implementation appendix to [RFC-0030](../../rfcs/0030-ios-identity-v3.md) and
[draft ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md), **not an
adopted format or implemented capability**. It specifies only an isolated
synthetic vertical slice: retained bootstrap catalogue → durable owner
allocation → encrypted owner commit → matching binding publication → retained
reopening of both stores **with owner artifacts present**. Both fi/ru slots
stay unallocated; no realm store, app factory, network, signing UI or migration.
Technical-basis comment 6150510664 is not approval of these new details. #73
scope provenance, independent review, ADR/adoption/main and live/device gates
remain unresolved. Existing component/Mac receipts do not cover this appendix.

## 1. Compatibility and writer ownership

Keep `IdentityCatalogue`, `IdentityCatalogueCodec`, `CatalogueStore`, their APIs,
refusals and tests unchanged. In particular, the bootstrap reader refuses
allocated/bound state and the old store refuses even an empty `owner/` or foreign
key. Do not add `allowOwnerPaths`, weaken `value == context`, or use two writers.

Proposed separate types: `AllocatedCatalogueState`, `AllocatedCatalogueCodec`,
`OwnerEnvelopeV1`, `OwnerEnvelopeCodec`, and `OwnerAllocationCoordinator` with a
private `OwnerStore`. Stable context is `(installID, ownerRef, fullFi, fullRu)`;
allocation and binding are mutable state, **not** part of that context. Compare
all context on every open/write, and the exact retained state before replacement.

The caller owns an existing isolated root and explicit catalogue/owner/fi/ru key
namespaces. An exclusive namespace lease binds root identity, those namespaces,
backend identities and coordinator incarnation. Bootstrap-to-new-writer handoff
means: quiesce all old operations, retire the old store and revoke its backend
handles, then transfer the lease to exactly one new coordinator. A stale handle
must fail before I/O; merely retaining two stores and promising not to call one
is not the handoff. An isolated lease-enforcing backend wrapper is allowed;
legacy store APIs need not change. The new coordinator first reads the retained
bootstrap using the new reader; it has no fresh-catalogue creation API.

Serialize all catalogue/owner operations and reject reentry/overlap as `busy`,
including while an external verifier awaits. An actor alone is not sufficient
if an `await` admits a second operation. Do not hold an application/realm lock
across I/O. Multiprocess writers, hostile concurrent filesystem mutation and
trustworthy discovery of a fresh installation remain outside this slice.

## 2. Byte admission and scalar types

Both plaintexts have a **65,536-byte raw cap**, checked before parsing or making
parser copies, and before sealing any candidate. A bounded file read rejects
oversize/growth before unbounded allocation. Reuse the existing AES-GCM framing:
`0x01 || nonce[12] || ciphertext[N] || tag[16]`, AAD exactly `[0x01]`, fresh nonce
per seal, opaque distinct 256-bit wrapping keys. Frame length is 29..65,565
bytes; an empty decrypted document still fails schema admission. Authenticate
into raw bytes, not the legacy lossy `String(decoding:as:)` path. No new cipher,
KDF, signing or PDA derivation in Swift; do not change `SnapshotCodec`.

A schema-directed, nonrecursive parser accepts strict UTF-8, no BOM, the four
JSON whitespace bytes and valid JSON string escapes. Reject duplicate **decoded**
keys at every depth, unknown/missing fields, wrong/null types, malformed UTF-8,
escapes/surrogates, control characters, trailing commas/data and excess array
entries. Never first decode an arbitrary JSON tree/dictionary that collapses
keys. Decoded strings are ASCII and bounded by their declared type; keys at
most 32 bytes. Maximum container depth is four (root → attempts → attempt →
sponsorRealmKey), maximum fields per object fourteen. Reject unexpected
containers immediately rather than traversing them. No arbitrary metadata blob.

Writers emit compact UTF-8, no BOM/newline, fields in the orders below, fi then
ru, attempts in insertion order. ASCII strings emit literally except `"` and
`\`, which use `\"` and `\\`; none of the admitted value grammars need these
escapes. Readers accept object order and either realm order; attempt array order is
history order and is never sorted. Mutation compares the retained prefix IDs.
Canonical byte output is deterministic, not a signature format.

| Type | Exact representation / limit |
| --- | --- |
| `U64` | JSON number token `0` or `[1-9][0-9]{0,19}`, accumulated with checked integer arithmetic, at most `18446744073709551615`; never `Double`/NSNumber coercion. No sign, fraction, exponent, leading zero, boolean or string |
| `UUID` | Lowercase ASCII hex `8-4-4-4-12`, 36 bytes; version/variant bits not interpreted, as in the bootstrap codec |
| `Name` | `[a-z][a-z0-9_]{2,23}`, 3..24 bytes; no `@`, case folding or normalization |
| `B58-32` | Canonical Bitcoin/Solana Base58 alphabet, decode to exactly 32 bytes and re-encode equal; at most 44 characters |
| `B58-64` | Same, exactly 64 decoded bytes, at most 88 characters |
| `Entropy` | Canonical padded RFC 4648 STANDARD Base64 of exactly 16 or 32 bytes (24 or 44 characters), decode/re-encode equal; no URL alphabet, whitespace or omitted padding |
| `WireBytes` | Canonical padded STANDARD Base64, 1..1,232 decoded bytes, at most 1,644 characters; precheck encoded length before bounded decoding |
| `RealmKey` | Exactly `{origin,pin,protocol}` in that output order; reuse the bootstrap origin grammar/300-byte cap, 64 lowercase hex pin, literal `identity-v3`; exact match to full expected fi or ru tuple |
| `Binding` | Exactly `{genesis,program,identity,owner,name}` in that order; first four `B58-32`, last `Name` |

These reuse [bootstrap grammar](concurrent-realms-design.md#proposed-in-memory-bootstrap-encoding)
and actual [Rust encodings](../../../blockchain/solana/client/src/lib.rs):
`entropy` at lines 84–91; `identity` at 342–347; `sponsored_sign` at 303–304
returns a Base64 message but a **Base58 owner_signature**; `sponsored_assemble`
at 332–334 returns Base64 transaction/message but a **Base58 signature**.
Public keys/PDAs and blockhashes are Base58. Rust's transaction cap is 1,232.
The 1,232 message cap and limits on depth, fields, strings and ledger length
below are **new bounded component proposals**, not existing product decisions.

## 3. Exact plaintext objects

Notation below describes field types, not literal JSON examples. Every listed
field is required; `null` is allowed only where written. Boolean means the
literal JSON `true` or `false`.

### Catalogue v5 extension

```text
{version:5, minReader:5, kind:"catalogue", installID:UUID,
 owner:{ref:UUID, allocation:"unallocated"|"allocated", binding:null|Binding},
 realms:[{slot:"fi", origin:String, pin:String, protocol:"identity-v3",
          allocation:"unallocated"},
         {slot:"ru", origin:String, pin:String, protocol:"identity-v3",
          allocation:"unallocated"}]}
```

The full reader accepts the exact existing all-unallocated/null-binding
bootstrap shape without rewriting it on open. It additionally accepts allocated
owner/null binding and allocated owner/non-null binding. An unallocated owner
with binding is invalid; realm `allocated` remains explicitly unsupported.
`version`/`minReader` are literal integer tokens `5`, not coercible equivalents.
Other unsigned version numbers are `unsupportedVersion`; malformed tokens are
`invalidFormat`. Owner ref and both full realm descriptors must match context.
Only `unallocated → allocated` and `null → Binding` are writer transitions;
once set, allocation/binding never revert or change. Reading a plausible binding
does not itself verify the registry or authorize publication/enrollment.

### Owner envelope v1

```text
{version:1, kind:"owner", installID:UUID, ownerRef:UUID, entropy:Entropy,
 owner:B58-32, identity:B58-32, genesis:B58-32, program:B58-32,
 phase:"unregistered"|"registrationPending"|"registryConfirmed",
 binding:null|Binding, wordsBackupConfirmed:Boolean, attempts:[Attempt]}
```

`version` is the literal integer token `1` with the same error distinction.
`owner`, `identity`, `genesis`, `program` must equal the **actual existing Rust
`identity(entropy)` result**, including its compiled chain/program. That command
is permitted for material consistency on open: it derives but does not sign.
Use Rust `lookup(owner,name)` for binding identity/PDA consistency, not a Swift
reimplementation. A binding repeats the identical four envelope public fields.
Entropy and those four fields are immutable after initialization; binding never
changes once confirmed, and phase never regresses.
No mnemonic, RPC URL, private key, UI/auth flag or realm login state is stored.
`wordsBackupConfirmed` starts false for a new identity, may become true only by
an explicit backup-confirmation operation, and never reverts. Recovery may
initialize it false; knowledge of entered words is not a backup assertion. Any
nonempty ledger requires it true, including after registry confirmation.

| Phase | Binding / ledger condition |
| --- | --- |
| `unregistered` | `null`, attempts empty |
| `registrationPending` | `null`, 1..8 attempts; backup confirmation true; uncertainty or all-terminal history remains in this phase |
| `registryConfirmed` | Non-null matching binding; 0..8 retained attempts (empty for recovery); no new registration/sign/send operation |

A pending candidate is `Attempt.name`, never a confirmed binding. Confirmation
may adopt another name for the same owner if a trusted finalized paired read
finds an earlier registration; do not overwrite historical attempt names.

### Attempt ledger

```text
{attemptID:UUID, stage:"ownerSigned"|"assembled", name:Name,
 sponsorRealmKey:RealmKey, payer:B58-32, blockhash:B58-32,
 last_valid_height:U64, message:WireBytes, owner_signature:B58-64,
 transaction:null|WireBytes, signature:null|B58-64, sends:U64,
 resolution:"unresolved"|"expiredAbsent"|"nameTaken"|"ownerBound",
 finalized_height:null|U64}
```

Proposal: **eight entries for the lifetime of this owner envelope**, including
terminal entries; distinct attempt UUIDs, no removal/reordering/replacement.
This intentionally trades availability for bounded evidence. Exhaustion refuses
new attempts before signing, still allows reads/reconciliation/confirmation;
no pruning, silent reset or cap increase. A separate reviewed retention design
is required to permit more. Both the raw cap and all per-field caps apply.

- `ownerSigned`: exact Rust message/owner signature durably stored **before any
  sponsor call can receive the signature**; `transaction`/`signature` null,
  `sends = 0`. This is real pre-sponsor evidence, not an empty placeholder.
- `assembled`: preserves every pre-sponsor field, adds the exact Rust transaction
  and its identifier (payer signature), starts `sends = 0`. `payer` differs
  from envelope owner. Sponsor, payer, blockhash, height, name, message and
  owner signature are immutable even across retries.
- `sends` is an integer 0..3. Reserve one send with durable `sends + 1` commit
  **before** release to `sendTransaction`; lost dispatch/ack consumes that
  count. All releases contain identical saved transaction bytes; no reset at
  restart, automatic retry or fourth release. A pre-sponsor attempt can already
  land through the sponsor even with no local transaction or sends.
- `unresolved` has null `finalized_height`; terminal resolutions have non-null
  height. A transition to `expiredAbsent`/`nameTaken` requires a finalized height
  strictly above **every currently retained** `last_valid_height` and a subsequent
  trusted registry read. On decode, apply that strict comparison only to
  expiredAbsent/nameTaken and only to the expiry maximum of the prefix through
  that entry, not future appended attempts. `ownerBound` has no expiry condition.
  `expiredAbsent` requires owner identity and that candidate's name PDA absent;
  `nameTaken` requires owner identity absent and a valid name binding to another
  owner. A timeout, sponsor error, missing status or malformed record is not
  either proof. Malformed/inconsistent evidence stops the operation without
  rewriting the ledger. `ownerBound` means this owner's binding was confirmed,
  **not** that this particular transaction landed.
- Only the last entry may be unresolved in a non-confirmed envelope. Before appending
  another (even same name), all previous entries must be terminal and a fresh
  external expiry/absence decision must cover the exact retained ledger and
  proposed name, whose name PDA must be absent. `nameTaken` does not authorize
  another attempt for that taken name. No candidate change while any attempt can
  land. Confirmation
  atomically marks remaining unresolved entries `ownerBound`; terminal entries
  stay unchanged. `ownerBound` is allowed only in registryConfirmed, which has
  no unresolved entries. Terminal resolutions never change. No terminal entry
  may sign, assemble or send again.

Storage admission checks shape, encodings, immutable transitions and scalar/
context equalities. For an assembled transaction it must check the fixed
existing two-signature framing without interpreting instructions: decoded bytes
must be `0x02 || signature[64] || owner_signature[64] || message` (and within
1,232 bytes). This is **byte consistency, not signature/message verification**.
On insertion/assembly the trusted signing boundary supplies actual Rust results
and checks request/result name, owner, message, identity/nickname and payer
against the captured target. Assembly itself signs again in existing Rust and
therefore requires fresh valid foreground signing authority if the old one ended.

Reopening/validating storage must **never call `sponsored_sign`,
`sponsored_assemble`, `register` or owner-proof commands**, even to compare saved
bytes. Neither AEAD nor ledger parsing proves signatures, instruction semantics,
authentic sponsor expiry, finalized registry state or live RPC/program/genesis
trust. Those belong to the upstream authenticated verifier/signing flow; no
such live implementation is supplied by this slice. Android
[`RegistrationFlow`](../../../clients/android-devnet/src/org/paranoid/devnet/RegistrationFlow.java)
lines 99–121 supplies comparison evidence only: it cosigns before persisting
and replaces expired history. Do not copy those gaps into this contract.

## 4. Mutation APIs and evidence authority

The following are semantic operations, not public Swift signatures. No generic
`commit(arbitraryState)`, `verified: Bool`, mutable public permit constructor or
JSON-deserializable authority is allowed. Before any upstream signer invocation,
the coordinator checks non-confirmed phase, backup confirmation and the specific
transition: capacity/append permit for a new attempt, or the retained unresolved
ownerSigned target for assembly. It then admits only the captured request. Supplying a
Rust result afterwards cannot bypass this pre-signing gate. Synthetic signer
inputs in this storage slice are not an implemented foreground signing flow.

| Operation | Preconditions and durable effect |
| --- | --- |
| `loadRetained` | Read-only catalogue + owner consistency classification; grants no creation/publication/send authority |
| `reserveNewOwner(operation)` | Retained all-unallocated/null catalogue and no owner artifacts/keys; commit allocation; only after final sync mint one creation permit |
| `initializeNew(permit)` | Consume permit, obtain new 16-byte entropy after reservation, call Rust identity, initialize `unregistered`; no registration/signing |
| `recoverVerified(operation, externalVerifier)` | Volatile recovery/identity first, successful evidence boundary below before any allocation; reserve, initialize confirmed owner, then publish matching binding |
| `confirmWordsBackup(operation)` | Explicit current-operation confirmation; commit false→true only |
| `recordOwnerSigned(operation, rustResult)` | Valid foreground owner authority, prechecked capacity and (for nonempty history) fresh expiry/absence permit for this ledger/name; append unresolved ownerSigned; first append changes phase to registrationPending |
| `recordAssembled(operation, attemptID, rustResult)` | Same immutable request, valid signing authority, unresolved ownerSigned; commit assembled form |
| `reserveSend(operation, attemptID)` | Explicit foreground registration operation, unresolved assembled, sends below 3; commit increment, then issue a one-use process-local dispatch ticket for exact saved bytes |
| `resolveExpired(operation, externalVerifier)` | Verifier covers exact ledger/candidate and strict finalized-height/registry conditions; commit terminal resolutions, never remove entries. If capacity remains, issue one append-eligibility successor permit for the checked candidate; at eight entries reconciliation still succeeds, but issues no append permit |
| `confirmRegistry(operation, externalVerifier)` | Trusted verified pair for same owner; commit registryConfirmed plus matching binding and resolutions first, then explicit catalogue publication |
| `publishConfirmedBinding(operation)` | Revalidate current confirmed owner and allocated catalogue/null binding; commit exact matching binding. Same pair already published is a read-only no-op |

Proposal: inject an explicitly named **isolated trusted external verified-input
seam**. It is not a boolean supplied by a UI and has no production conformance,
default verifier or public `VerifiedResult(...)` shortcut. Tests may deliberately
supply synthetic evidence through that seam and must label it as trusted input,
not executed live verification. The coordinator captures the request and checks
returned correlation/context before privately minting a `VerifiedBindingPermit`
or `ExpiryPermit`. Binding evidence carries exactly `Binding` and a finalized
height (`U64`). Expiry evidence carries that height and at most eight typed
`(attemptID, expiredAbsent|nameTaken)` dispositions covering the unresolved IDs,
plus the checked proposed `Name`; the captured complete ledger is the request
target, not caller-replaceable response data. Already-terminal entries remain
unchanged; rechecking them may issue a fresh append permit without rewriting
history. No-name/rejected/failed results produce no permit. Rust `verify`
validates supplied record bytes/program/genesis values; it does **not** prove
the RPC source, live genesis, Program/ProgramData accounts or finality. A future
production verifier must establish all RFC-0030 RPC/program/finalized-pair checks; that implementation/adoption remains gated.
An expiry permit also requires trustworthy expiry of the exact saved blockhash,
not merely a height greater than an untrusted sponsor-supplied number. How the
future live verifier establishes that association is unresolved; synthetic
verified-input fixtures cannot close it or authorize a new live RPC method.

All permits/tickets bind coordinator incarnation, exclusive root/key lease,
installID, ownerRef, full fi/ru context, operation UUID, purpose/phase, exact
material/binding or ledger/candidate target, and the retained state revision.
They are nonpersistable, unforgeable outside the coordinator, single-use and
invalid after completion, error, cancellation, lease loss or coordinator close.
An operation spans the pipeline, not a single method return; it stays the sole
active operation until explicitly finished/cancelled. In a multi-commit operation,
consume each permit for its exact transition and
mint its narrow successor only after that transition succeeds (verification →
reservation → owner commit → publication). Never rebind a stale permit to a
new revision or let an unrelated operation inherit the verified result.
Any bounded external wait uses a caller-supplied finite monotonic deadline;
expiry invalidates authority and late results have no effects. Completion bounds
apply to the caller/authority, not forced termination of an uncooperative trusted
verifier continuation. That worker can retain its own request copies until it
returns; production verifier resource/copy-lifetime policy and a global bounded
worker pool are not supplied by this isolated slice. No app authority
or Face ID result is invented by a test fixture. Recovery failure, no-name,
wrong-context or cancellation **before allocation** performs zero recovery
catalogue/owner/realm writes. Cancellation after reservation cannot undo durable
allocation: preserve it, invalidate the permit and never recreate on reopening.

A creation permit exists only after the allocation's **final directory sync**;
one initialization consumes it before new entropy generation/first owner effect.
New entropy uses the platform CSPRNG (`SecRandomCopyBytes` on Apple); recovery
uses only the volatile Rust-recovered material already bound to verification.
It cannot be reconstructed from `allocated`, absence, a marker, a saved binding
or a new coordinator. A successfully committed owner may outlive a cancelled
operation without catalogue publication; reopening reports that intermediate,
never publishes automatically. Explicit publication after reopen needs a fresh
operation and revalidation of the matching durable pair, not a new signature.

## 5. Paths, protection and transaction ordering

Only these paths are written: `text-state.enc`, `text-state.enc.tmp`,
`catalogue.write.pending`, `owner/`, `owner/state.enc`, `owner/state.enc.tmp`,
`owner/write.pending`. Catalogue intent is ASCII `catalogue-write-v1\n`; owner
intent is ASCII `owner-write-v1\n`. Marker presence (including malformed/empty)
is uncertainty, never creation authority. No deletion API except removing the
current transaction's intent after success. Preserve keys/temps/markers on error.
Inspect all these paths plus `realms`, `realms/fi`, `realms/ru`, their named
state/temp/intent paths and all four key namespaces. Any realm artifact/key
refuses this unallocated-realm slice, including empty directories. Throwing
no-follow inspection distinguishes absence from inaccessible/wrong inode types.

For initial owner creation, after durable reservation and permit consumption:
mark the owner transaction begun, then create `owner/` through an explicit
create-only/no-follow directory seam under
the leased root (owner-only mode 0700, refuse existing inode); apply/read back
owner protection and backup exclusion, sync that directory and its root parent.
Only then create/protect/full-sync `owner/write.pending` and sync `owner/`
**before** create-only wrapping-key creation and retained-key equality readback.
A crash after mkdir but before intent is still allocated owner loss, not fresh.
No reuse of the legacy key-before-intent/temp-cleanup algorithm.

For every catalogue/owner replacement: validate current state, bounds, authority,
key continuity and allowed transition before mutation; mark transaction begun;
create-only/protect/full-sync intent, sync its parent; load/compare retained key;
seal candidate; create-only temp (0600), protect/exclude/read back attributes,
full-sync temp; rename to destination; bounded byte-exact ciphertext readback;
full-sync destination parent; remove intent; full-sync parent again. Only then
adopt state/return success or release a dispatch/publication capability. For
initial owner creation the post-intent key step creates once instead of loading
an absent key. Catalogue is always retained, so its key is never created here.

Owner policy is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable = false`, files/directories/intent/temp `.complete`,
backup excluded. Catalogue/realm messaging defaults stay unchanged. Account
injection into existing `KeychainKey` does not select accessibility, and existing
`CatalogueAppleFileIO` hardcodes messaging protection: neither is an owner
adapter merely by changing its path/account. Explicit typed owner-policy/opaque
key seams are allowed; host fixtures prove their invocations, not real Keychain
or on-device Data Protection. Existing adapters' native receipts stay frozen.
The Mac branch delivers these seams as `OwnerAppleFileIO`,
`OwnerAppleCryptography` and `OwnerKeychainKey`
([receipt](../../project/evidence/ios-identity-v3-20261013/owner-apple-adapter.md)):
the host proves the invocation order and backup flag, an ad-hoc signed
simulator proves the Keychain attributes, and on-device `.complete`
behaviour stays a separate physical check.

## 6. Consistency, errors and crash containment

Evaluate common catalogue/lease/realm integrity first. No automatic repair,
rollback to old bytes, cleanup, rekey or allocation reset is provided.

| Retained catalogue | Owner artifacts / decoded state | Result |
| --- | --- | --- |
| Missing/corrupt/XOR, pending/temp or wrong context | Any | Catalogue freeze; preserve all evidence |
| Unallocated, null binding | No owner directory/file/key/temp/intent | Valid bootstrap; explicit reservation possible |
| Unallocated | Any owner artifact/key, even empty directory | Consistency refusal; never promote or delete |
| Allocated | Both key/file absent (with or without directory), XOR, pending/temp, wrong inode, authentication/schema/context failure | Owner loss/freeze; creation permit cannot be recovered |
| Allocated | Read-only key/file temporarily locked, no uncertainty observed | `locked`; owner operations blocked, retry inspection/open after unlock |
| Allocated, null binding | Valid unregistered or registrationPending | Valid retained owner; no realm onboarding |
| Allocated, null binding | Valid registryConfirmed | Preserved publication-pending intermediate; no automatic publication/onboarding |
| Allocated, non-null binding | Valid registryConfirmed with identical binding | Valid matched pair; this slice still provides no realm allocation |
| Allocated, non-null binding | Non-confirmed owner or different binding | Binding/consistency refusal; preserve both |

Fixed public error categories, no associated payload/path/key/underlying error:
`busy`, `authorityRequired`, `cancelled`, `locked`, `invalidDirectory`,
`artifactsPresent`, `continuity`, `contextMismatch`, `invalidFormat`,
`unsupportedVersion`, `limitExceeded`, `invalidTransition`, `bindingMismatch`,
`authenticationFailed`, `keyMismatch`, `readbackMismatch`, `backendFailure`,
`broken`. `busy` rejects the incoming request without cancelling the active
operation. Other semantic refusals before effects preserve state and invalidate
the rejected operation's permits; no mutation on parser/limit failure. Integrity failures
freeze the affected scope. Once a write has begun, **any** failure/cancellation
(including lock/readback/sync uncertainty) terminally breaks that writer;
subsequent mutation calls return `broken` without backend access. A catalogue
write failure breaks the coordinator's common scope; owner-only uncertainty
freezes owner work and cannot publish a binding. A precisely classified
read-only lock before effects may retry; other I/O errors are not absence.

These are storage classifications, not a command to revoke all runtime/device
credentials. Owner lock/freeze does not automatically stop verified device-only
traffic; common catalogue failure has wider containment in the parent design.
This slice constructs no runtime. Lost final acknowledgement may leave a pair a
new instance can open while the failed writer remains broken. Complete loss or
rollback of all evidence is undetectable; no anti-rollback/power-loss guarantee.

## 7. Component acceptance and remaining gates

All new checks below are **required future tests, NOT RUN by this document**.
They refine REQ-ID-002/003/004/006, REQ-CLIENT-001, REQ-MULTI-001 and REQ-SEC-001
([requirements](../../product/requirements.md)); they do not pass full
MR-02/06/07/13/14 or MR-16.

- Exercise the whole durable recovery path, not only codec round-trips: reopen
  catalogue and owner on a new coordinator with owner directory/key/file present,
  same confirmed pair, both fi/ru unallocated and no realm/network effects.
  Separately retain unregistered and both pending stages, exact bytes/counts.
- Fault before/after every directory, intent-parent-sync, key, temp, rename,
  readback and final-sync effect; verify ordering, one creation, no cleanup,
  no recreated permits, no premature publication/send and the full matrix.
  Test lease handoff/reentry, cancellation and late/foreign/reused capabilities.
- Negative raw/framed boundaries, strict UTF-8/duplicates/unknowns/depth,
  integer overflow/coercion, Base64-vs-Base58 confusion, maximum ledger and
  no pruning, fourth send, candidate change, context/key/store swaps. Assert
  zero signing calls on **every** retained open/structural-validation path.
- Failed/no-name/cancelled recovery writes nothing; owner confirmation then
  catalogue failure preserves intermediate; explicit later publication only.
  Old bootstrap codec/store continue refusing new allocated/owner artifacts;
  legacy v4 data stays byte-for-byte unchanged and intact-v5 downgrade refuses.
- Unit doubles prove orchestration only. Exact-head Mac tests must exercise real
  CryptoKit plus filesystem encrypted commit/reopen. Real Keychain policy,
  on-device `.complete`/backup behavior, process restart/power loss, UI authority,
  live verifier, recovery/login and both-realm phone acceptance remain separate.

No blocker is hidden by a permissive default: production verifier/auth policy
(including authenticated blockhash expiry), fresh-Welcome/lost-install
classification and app namespace adoption remain unresolved integration decisions.
Exhausted-ledger recovery needs a separately reviewed retention proposal; no workaround is authorized here. The isolated
component can implement the conservative contract without choosing those
product/security policies. Rollback is a compatible full-state reader or a
stopped preserved installation, never deleting the catalogue/key to launch an
old reader. No current-state, delivery, operational permission or ADR status
changes follow from this documentation-only proposal.
