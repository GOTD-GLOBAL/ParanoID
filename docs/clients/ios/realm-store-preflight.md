---
status: draft
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
created: 2026-10-14
last_reviewed: 2026-10-14
technical_disposition_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187
source_scope_approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046
---

# Realm-store implementation preflight and acceptance contract

Supporting appendix to [RFC-0030](../../rfcs/0030-ios-identity-v3.md), not a new
RFC/ADR or rollout receipt. **The bounded technical disposition is verified;
this draft is not an accepted ADR or implemented contract.** Next: isolated retained-owner → realm allocation → encrypted
candidate/login-bookkeeping commit → reopen, a prerequisite for the still-unmet
recover-test-nickname/login/restart application milestone.

## 1. Authority and frozen baseline

Source-research baseline: `2f786afc707c7a8159ba1d3620db55f4c416623d`.
The proposal branch now starts from integrated PR #84 head
`79d6c8d4e018b1a852f091fe611f35316d0a0a14`: #85 was merged into the owner-store
feature by `051018254660ff86f44a7e6db7cb53a7c3a6dafb`, then status docs changed.
Source/tests are unchanged; line references below still name the frozen source.
This draft and its navigation/status/threat pointers are documentation only.
Recheck the implementation base after the required gates; no main merge or
realm implementation is claimed by the completed owner-component integration.

The [current-state receipt](../../project/current-state.md#owner-adapter-corrections-and-source-review-closed--2026-10-14)
covers owner code `17d8d88871e48e6323438c98c1ae5556bea6c5ce`, receipt head
`09eac341a3823edd67fcb652f63de04067709408`: contributor Mac package **551 tests,
1 skipped, 0 failures**, signed-simulator Keychain **14/0**, unsigned iOS build
and scoped source-review closure. These are existing owner-component results,
not this document's execution or realm/login/phone evidence. Historical
“next/unimplemented” owner headings do not override those later source facts.

**The missing #73 source-scope evidence is now recorded.** Human `martadvix-web`
[confirmed on 2026-10-14](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046) with the exact text “Подтверждаю”, in the context
of the [bounded source/local-test request](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785). The earlier Telegram
[provenance limitation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153858611)
is historical; it is not a remaining request to repeat the product decision.
This covers private non-sensitive test-data source/local component/native work,
preserving identity/history, E2EE and review. It authorizes no main merge,
release, server/config/schema/DB operation, live RPC/login/registration/replacement,
phone/Apple/TestFlight action or sensitive-data use. PR #73 itself is still open;
closing its evidence gap is not merging that PR or accepting an ADR.

[Yaroslav's earlier technical-basis agreement](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664)
and the D87 record below remain distinct from formal
[ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md) acceptance. Exact
contracts, independent revision review and actual tests still apply under
[ADR-0001](../../decisions/0001-documentation-as-code.md),
[ADR-0003](../../decisions/0003-closed-alpha-review-policy.md) and the
[approval policy](../../governance/documentation-policy.md#durable-approval-and-delegation-records).
No further approval is inferred from urgency, CI or a merge.

### Verified D87 technical disposition — not ADR acceptance

Human `Cooldom66671` [posted the direct D87-01–07 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187) on
2026-10-14 against `c66fcbc9961a29245bbbfbcd33ac1292a4338fae`, accepting the
[source-review qualifications](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#pullrequestreview-5520287987).
His [technical delegation](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)
is recorded separately by `martadvix-web`. This is verifiable technical evidence,
not merely the preceding Telegram relay. It chooses the successor writer, typed
realm backend, stricter new-format metadata, preserved login evidence, owner-
locked read-only first slice, and direction A for both shared-core questions.
The verified-B six-item definition and the staged absent-key readback order are
agreed. Do not reopen these direction questions or call the core refactor trivial.
No implementation, formal ADR acceptance, live authority or test result follows.

D87-06/07 select directions for separately scoped **RFC → ADR** work. Changes to
`key-protocol`, `clients/core` (including `clean_service`) or the shared JSON
command contract wait for that process and required owner approvals. Neither
this appendix nor an RFC draft alone unblocks arbitrary schema-3 reopen.
D87-07 is a critical-path dependency of verified-B admission and the restart-
keeps-login milestone, not an optional later cleanup; its RFC drafting runs in
parallel with the namespace/readback contract. Neither alone delivers the app.
Existing #85 closure is unchanged. The [draft namespace/readback contract](realm-key-namespace-contract.md)
now refines D87-02 query identity, bound-key observations and synthetic native
probes. It is not an implemented backend or Apple receipt. The separately drafted
D87-07 RFC remains required for general schema-3 admission; future D87-06 wire
changes/inventory do not block the current namespace slice's retained grammar.

## 2. Existing facts versus inherited proposals

Line ranges/symbols refer to the frozen baseline; linked design/protocol
documents remain draft, not accepted architecture.

| Basis | What is actually established / required next |
| --- | --- |
| [CatalogueStore](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/CatalogueStore.swift), `inspect`, `readCatalogue`, `commit` (78–159) | Bootstrap-only; refuses owner/realm artifacts and foreign keys, checks exact context, journals before key creation, adopts after final directory sync. It is not a general catalogue writer. |
| [OwnerStoreCodec](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerStoreCodec.swift), `AllocatedCatalogueCodec` (86–141) | Supports allocated owner/binding, but **rejects allocated realms** at line 124; encoding explicitly retains both realms unallocated. `OwnerEnvelopeCodec` holds owner material/ledger, not login state. |
| [OwnerAllocationCoordinator](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerAllocationCoordinator.swift), `readCatalogue`, `refresh`, `recoverVerified`, `publishConfirmedBinding` | Lines 343–355 reject even `realms/` and fi/ru keys. Recovery uses the isolated trusted verifier seam; no production RPC verifier exists. Confirmation precedes explicit catalogue publication; both realm slots remain unallocated. |
| [OwnerNamespaceLease](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerNamespaceLease.swift), `claim`, `retire`, `LeasedFileIO`, `LeasedCryptography` | One holder/coordinator identity per lease object; stale wrappers fail before backend access. Not a process-wide root registry, multiprocess lock or protection against a caller constructing another lease over the same root. |
| [AppModel.start](../../../clients/ios/App/ParanoID/AppModel.swift) (305–358) | Still constructs legacy `SnapshotStore`/`SelfServiceClient` and one `Runtime`; no catalogue/owner/realm app factory or v3 login adoption. |
| [Concurrent design](concurrent-realms-design.md#versioned-persistence-candidate), lines 171–229 | Proposed matched confirmed owner/catalogue before realm allocation; independent keys, Snapshot v4, immutable intent/result and scoped failure. This is the inherited target, not delivered realm storage. |
| [Identity-login v3](../../protocol/identity-login-v3.md#inspect-status-and-immutable-intent-recovery), lines 197–231, 292–295 | Immutable operation/generation across unknown outcomes; status is not a full commit result; no automatic rekey/replacement. Its old implementation-status paragraph is historical; do not infer absent Android/server code from it. |

## 3. Finite slice and component ownership — proposed

After the gates above, use a caller-owned synthetic root: reopen a matched
confirmed owner/catalogue, allocate one slot, commit fresh core then schema-3
upgrade and login-bookkeeping states, close/reopen. Repeat for the sibling,
proving the first slot/owner unchanged. No UI, transport, production verifier,
owner-authentication policy or automatic login is included.

- One successor full-state coordinator is the **only catalogue writer**. It
  admits the already supported bootstrap/owner forms plus allocated realm flags
  through a separately named codec. Keep the existing codecs, stores, APIs and
  refusal tests intact; no `allowRealms` switch or weakening of equality checks.
- This is a compatibility design gap, not a direct reuse of the owner writer.
  Proposed catalogue output retains v5/minReader 5 and the existing fields,
  extending only each slot's allocation to `unallocated|allocated`, monotonic.
  Ratify that reader/version strategy before writes. Old owner/bootstrap readers
  must continue refusing allocated realms, never normalize them back to empty.
- The successor preserves the owner file/key/phase/ledger/binding exactly; it
  reads via the existing owner codec, never re-signs or rewrites the owner.
  Returning to the old owner coordinator after realm allocation is unsupported.
  Future owner mutation must use a reviewed compatible common writer, not a
  second coordinator sharing the catalogue. That later integration is excluded.
- Per-slot storage owns only its explicit key namespace, envelope/temp/intent
  and scoped result. Slot labels `fi`/`ru` select paths, never trust. Full
  `(origin, pin, protocol)` plus installID, ownerRef and binding authorize context.
  Four distinct opaque key backends are supplied, not app defaults.
- Existing local names, call logs, drafts, install marker and legacy v2 bytes
  are untouched. This slice creates no metadata migration or global membership
  flag. Retained metadata must later be scoped before any app factory adoption.

### State refusal and typed namespace contract

D87-01 means an old reader refuses a valid but unsupported successor **state**
without changing its bytes; refusal/freeze does not prove file corruption.
It does not assert a uniform existing error API. The bootstrap codec returns
`unsupportedState`; `AllocatedCatalogueCodec` returns `invalidTransition` for
allocated realms; `CatalogueStore.readCatalogue` maps unsupported codec errors
into `invalidCatalogue`; artifact checks can refuse before decoding. The owner
coordinator freezes retained non-lock failures. Preserve these APIs/tests here.
Changing every old API/UI to a new typed refusal is a separate behavior change,
not implicitly authorized by a docs-only compatibility statement.

D87-02 proposes a typed `RealmKeyBackend`, analogous to the owner-policy type
boundary but **not an implemented API**. Existing `OwnerKeyBackend.storedPolicy`
reads accessibility/synchronizable, not a complete namespace identity. Require
messaging-policy enforcement and actual Keychain readback; Swift object identity
and different accessibility policies do not prove separate items.

Before mutation, define four explicit, non-overlapping namespace/query identities
for catalogue/owner/fi/ru: class/account/service/accessGroup and sync/domain
selection, separately from accessibility policy. For retained items, bind the
returned identity/policy attributes to the actual loaded key. Exact handling of
missing/default attributes, class/domain query evidence and ambiguous matches
must be specified and verified on Apple; do not invent returned attributes or
accept an arbitrary first match. This remains a pre-code contract detail.
For an absent item there can be no pre-create stored-attribute readback: verify
intended namespace and absence first, then permit/journal/create, then read back
identity/policy/key before use/adoption. Mismatch freezes with key/intent retained;
no deletion, repair or re-creation. Fixture descriptors are not native proof.

### Single-lease handoff, not two writers

Use the **same `OwnerNamespaceLease` instance** for a root across same-process
handoffs. Quiesce work, cancel/fence outstanding authority, close the old
coordinator, retire its holder, then acquire exactly one successor holder with
fresh wrappers. The successor has a new coordinator incarnation; copying the
old incarnation/permits is not a handoff. A recreated coordinator is not allowed
to bypass a live holder by constructing a second lease object. Trusted caller
ownership is a precondition until a separate app-factory design enforces it.

Proposed creation permits bind lease/holder/incarnation, installID/ownerRef, full
target, operation, revision and deadline. Mint after allocation final sync; consume
before key/core creation. Reentry, including awaited work, is busy. Completion,
error, cancellation, expiry, close or lease loss revokes authority; persisted
flags never reconstruct it. Existing examples:
[handoff test](../../../clients/ios/ParanoidKit/Tests/ParanoidKitTests/OwnerStoreTests.swift)
`testLeaseHandoffRetiresOldBootstrapHandlesBeforeNewWriter` and
[regressions](../../../clients/ios/ParanoidKit/Tests/ParanoidKitTests/OwnerStoreRegressionTests.swift)
`testExclusiveLeaseRejectsSecondCoordinatorAndMixedNamespaceWithoutIO`.

## 4. Realm data admission — proposed, needs format disposition

Semantic fields below are **not implemented Swift APIs**. Proposed plaintext
is strict UTF-8 JSON with required fields in this writer order:

```text
{version:1, kind:"realm", installID:UUID, ownerRef:UUID,
 realm:{origin,pin,protocol:"identity-v3"}, binding:Binding,
 snapshot:SnapshotV4, loginIntent:null|Intent,
 membership:null|CommitResult, terminal:"none"|"revoked"|"banned"|"absent"}
```

### Field and encoding table

Every listed envelope/wrapper/metadata field is required; only `loginIntent`
and `membership` permit `null` (not a rule for core internals). Limits below
count decoded ASCII bytes unless called **raw**. Reuse
[owner format §2](owner-store-format.md#2-byte-admission-and-scalar-types)
`UUID`, `B58-32`, `Name`, `RealmKey`, `Binding`; these are inherited local
proposals, not wire-wide restrictions. `Hex32` is 64 lowercase hex bytes;
`UUIDv4` is 36 lowercase bytes with version 4/RFC4122 variant. Wire facts come
from [ChallengeRequestV3 / parse_generation](../../../key-protocol/src/identity_v3.rs)
and [Credential / verify / fingerprint](../../../key-protocol/src/lib.rs).

| Object / fields in proposed writer order | Exact type, encoding and admission |
| --- | --- |
| Envelope `version,kind,installID,ownerRef` | Literal JSON integer `1`, string `"realm"`, two owner-format UUID strings (36 bytes, no version/variant inference); exact retained installation/owner reference. |
| `realm:{origin,pin,protocol}` | Origin ≤300 bytes under `IdentityCatalogue.Realm`'s [existing grammar](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/IdentityCatalogue.swift): exact HTTPS ASCII DNS/IPv4, canonical non-default optional port, no path/query/userinfo/normalization; `pin:Hex32`, literal `"identity-v3"` (11 bytes). Exact full selected catalogue tuple; not wire's broader 512-byte credential realm allowance. |
| `binding:{genesis,program,identity,owner,name}` | Four canonical `B58-32` strings (≤44 bytes, exactly 32 decoded bytes, decode/re-encode equal), `Name` = `[a-z][a-z0-9_]{2,23}` (3..24). Non-null; exact confirmed catalogue binding and available validated owner binding, including compiled chain/program; not a name-only lookup. |
| `snapshot:{version,realm,tls_pin,token,state}` | Existing [Snapshot v4](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Service/Snapshot.swift) shape (`Snapshot.text/open`), **PROPOSED strict wrapper admission**: literal integer `4`; `realm`/`tls_pin` equal outer origin/pin; token `""` or `Hex32` as in v4 (new candidates always `""`); `state` is one raw core JSON object, **not a string**. No v4 migration/adoption permission. |
| `loginIntent: null` or `Intent` | Exactly `purpose,operation,genesis,program,identity,owner,name,credential_object,expected_generation,credential_fingerprint`. Purpose `"enroll"` or `"replace"` (≤7); operation `UUIDv4`; five binding fields identical to outer binding; nested credential below. Final field is a **PROPOSED local** `Hex32` copy of Rust reply `fingerprint`, not a tenth challenge-request field. |
| Intent `expected_generation` | JSON string `"0"` or `[1-9][0-9]{0,18}`, checked ≤`9223372036854775807`; enroll exactly `"0"`, replace `1..9223372036854775806`. No sign, whitespace, leading zero, fraction, exponent, JSON number or coercion. Server's eight-generation admission policy is not this scalar's parser range. |
| `credential_object:{root,account,device,auth,realm,pin,olm,signature}` | Existing eight-field `Credential`: root/auth canonical unpadded STANDARD Base64, exactly 32 decoded bytes / 43 encoded; signature exactly 64 / 86; decode/re-encode equal, no URL alphabet/padding/whitespace. Account/pin/olm `Hex32`; realm equals outer origin; device canonical lowercase UUID (36) under the D87-06 retained-read choice below; no local version tightening. Every field equals the existing Rust public credential; decoded root/auth/owner keys must be distinct as in `ChallengeRequestV3::validate`. Account derivation/signature/key consistency remain Rust's, not Swift hashing/signing. |
| `membership: null` or `CommitResult` | Exactly `operation,membership,generation,account,device,credential_fingerprint,mode`: operation/membership `UUIDv4`; generation same decimal-string grammar but `1..9223372036854775807`; account/fingerprint `Hex32`, device as credential above; mode exactly `"active"` (6). Account/device/fingerprint equal the retained core credential/result; membership UUID comes only from a full result, never status. |
| `terminal` | Exactly one of `"none"`, `"revoked"`, `"banned"`, `"absent"` (≤7); realm-local observation, not owner authority or a replacement for retained result. |

**Wire discrepancy and scoped retained-read decision:** protocol §Encodings says all
UUIDs are UUIDv4, but `Credential::verify` checks only canonical UUID text for
`device`; `Identity::create` generates v4 and `ChallengeRequestV3::validate`
enforces v4 on **operation**, not device. D87-06 selects direction A for a
separate RFC: retain the v3 requirement, define boundary-specific validation and
an explicit retained-credential compatibility policy, not a global change to
`Credential::verify`. Both client creation paths call shared `Identity::create`,
which generates v4; that does not inventory all retained/external credentials.
The shared verifier also checks messaging contacts. No enforcement/compatibility
change is accepted or implemented here; do not normalize signed IDs or silently
invalidate, regenerate or delete retained credentials. The verified D87-06
record explicitly selects canonical UUID admission matching Rust for retained
local `device`, with a labelled R07 regression that the existing generator emits
v4. This is not a claim that v3 wire admission already enforces v4. A read-only
non-v4 inventory on both servers belongs to the later v3 compatibility RFC and
requires Sergey's separate live authorization; it is not authorized here and
is not a prerequisite to drafting D87-07 or the namespace contract.

### Parser admission and opaque core boundary

**PROPOSED local bounds**, to bound hostile metadata without restricting the
versioned core grammar: core span ≤8,388,608 bytes; **all other plaintext bytes**,
including Snapshot wrapper, whitespace and outer syntax, ≤131,072;
total ≤8,519,680; sealed frame ≤8,519,709. The core limit is sourced from
[`clients/core::command`](../../../clients/core/src/lib.rs); the additive
metadata allowance is a proposal, not additional core capacity.

| Admission surface | Required bound / refusal before effects |
| --- | --- |
| Envelope, wrapper and typed metadata | Strict UTF-8, no BOM, only JSON whitespace. For the **new realm format only**, metadata keys/string contents are literal ASCII under the field grammars: no backslash or JSON escape sequence, embedded quote/control byte, non-ASCII, trailing comma/data. Reject duplicate literal keys, unknown/missing fields and wrong/null types; no permissive dictionary preprocessing. Arrays are never metadata. Exact object field counts: envelope/Intent 10, RealmKey 3, Binding/Snapshot 5, Credential 8, CommitResult 7. |
| Metadata parser | **PROPOSED** nonrecursive schema-directed depth ≤3, root counted as 1 (`envelope → Intent → Credential`); reject unexpected containers without walking them. Literal ASCII keys ≤32 bytes; each value has its table cap. Before allocation, raw string token including quotes ≤`field cap + 2`; reject backslash directly rather than decoding an escaped spelling; versions use `0` or `[1-9][0-9]{0,19}`, checked ≤`18446744073709551615`, then require literal `1`/`4`; no sign/fraction/exponent, leading zero or Bool/Double/string coercion. |
| `coreSpan` at `snapshot.state` | Locate by offsets, with iterative string/escape-aware delimiter matching; count its raw bytes from `{` through matching `}`. No metadata depth/field/key/string/array rule inside it. Scanner auxiliary delimiter stack ≤one byte per consumed core byte (thus ≤8,388,608), no recursive Swift calls or arbitrary core tree. Existing Rust JSON/versioned semantic validation remains authoritative, including its own rejection limits. A span match alone is not JSON/core validity. |
| Byte accounting and memory | Bound frame before read/decrypt (reject growth); use checked offset/add/subtract arithmetic. Require `plaintextBytes - coreSpanBytes ≤131072` as well as both other caps, on read and candidate write. **PROPOSED** parser uses one bounded decrypted buffer plus offsets, one bounded core transfer copy and bounded metadata/stack; no whole-envelope Foundation tree or escaping/re-encoding core. CryptoKit/C-ABI/Rust replies and `CoreBridge`/`JsonSpan` make copies: this is not a zero-copy or total-process-memory proof; exact-head peak-allocation evidence remains required. |

D87-03 intentionally narrows the previously proposed **new-format reader**
grammar; decoded ASCII does not imply escape-free source bytes. Existing
catalogue/owner/legacy codecs still accept their supported escaped spellings.
No migration or tightening of those readers is authorized. Opaque core is exempt:
its scanner must still handle escaped quotes, backslashes and Unicode correctly.

Canonical output rules apply only to newly serialized metadata: compact UTF-8,
no BOM/newline, fields in table order and literal ASCII strings. Build each new
Snapshot wrapper directly in that grammar. The new reader accepts permitted
object order and JSON whitespace, not metadata escapes. On bookkeeping-only
commits, copy the entire already admitted Snapshot span verbatim, including
wrapper order/whitespace and every opaque-core escape. No `Snapshot.open(...).text`
round-trip or normalization. Import of an escaped legacy wrapper is excluded,
not silently repaired; any future import needs a separately reviewed contract.
Only an explicit Rust candidate transition replaces core bytes. The old
`Snapshot.open` uses a Foundation tree;
[`JsonSpan.value/Scanner.scanValue`](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Core/JsonSpan.swift)
copies input and only matches nested delimiters, not full nested grammar. Neither
is the new strict admission parser. Never prune retained state to fit.

### Structural coherence, not proof authority

Use existing Rust through the unchanged [CoreBridge.command](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Core/CoreBridge.swift),
not Swift core-field validation. [clean_service](../../../clients/core/src/clean_service.rs)
`command/validate/Status/ServerStatusV2` and server
[`status/commit`](../../../server/src/identity_v3.rs) establish the following mapping;
these **local coherence rules are PROPOSED**, not a server verifier. In every
schema-3 case, even with null intent/result, require the Rust public credential's
realm/pin to equal wrapper/outer trust; bind its fingerprint to the selected slot.

| Retained state | Admission / transition |
| --- | --- |
| Core schema 0 | Intent/membership null, terminal none. Validate with a discarded `upgrade_v2` dry-run, require schema 3 and matching trust/credential, preserve original bytes. Explicit continuation commits that upgrade with the same identity; v3 login/proof use waits for durable schema 3. No creation/signing/network on reopen. Other core versions refuse; no reset. |
| Schema 3, membership null | Requires full Rust semantic validation and enrollment null; **non-signing validation blocker below**. Intent may be null or the exact retained mutation intent. `identity_credential_v3` alone validates legacy identity, not the whole schema-3 state; its separate `{credential,fingerprint}` result supplies comparisons, not full-state admission. |
| Schema 3, membership present | Rust enrollment must exactly equal `{mode:"active",account:result.account,device:result.device,credential:result.credential_fingerprint}`. This is the `server_status_v2.status` mapping: **credential**, not `credential_fingerprint`; operation/membership/generation do not enter that core object. Non-null intent must match result operation/account/device/fingerprint and checked `result.generation = expected_generation + 1`; both may coexist until the second durable clear. |
| Terminal / unknown outcome | Schema 3 may retain either membership form above with none/revoked/banned/absent; a terminal flag preserves any intent/result and does not rewrite historical core enrollment to a mode Rust rejects. Terminal blocks activation/mutation release even if enrollment is active, not read-only reconciliation; no automatic clearing/re-enroll. Status is separately exactly `{mode,generation,operation}`: absent requires `"0"`/`""`; active/revoked/banned require positive generation/UUIDv4 matching retained result or pending operation and expected generation + 1. Absent with pending intent/no result preserves unknown outcome for exact retry; `terminal:"absent"` requires a retained result and records loss, not fresh admission. Disagreement freezes without erasure. |

The first-slice mutation starts on a fresh candidate with `membership:null`.
After a full result, only its matching retained intent may coexist until the
separate durable clear. A new mutation over a retained result is outside this
slice: refuse before changing core, intent or result; do not erase old evidence
to make a new operation fit. A genuine replacement needs a new credential and a
separately reviewed transition; the server rejects reusing an existing binding
for a new operation (`evaluate`, `binding_used` / `device_revoked`). The schema-0
dry-run above applies only to the clean intermediate, not arbitrary legacy
migration or the general schema-3 validation path.

**Source blocker — no signing on reopen remains required:** `view` is not a
non-signing validator for arbitrary schema-3 state. `clean_service::validate`
and `reply` can call `local_contact` → [ContactV2::create](../../../clients/core/src/contact_v2.rs),
which signs with device auth. `identity_credential_v3` bypasses full `validate`.
Do not implement the table by calling either and claiming both guarantees;
D87-07 chooses a separate RFC for pure full-state validation/nonsecret projection.
`ContactV2.fingerprint` excludes its signature and `intro_v2::channel` uses that
fingerprint, so a non-signing path is feasible without changing the transcript.
That does not prove a trivial patch: preserve peer signature verification and
all state checks; avoid signing in both validation and reply/projection, with
no-sign/no-mutation tests. Exact JSON contract, approved RFC/ADR and actual
implementation remain dependencies. Until then general schema-3 reopen stays
blocked; `identity_credential_v3` is not a substitute. No Swift core
reinterpretation, new bridge API or signing exception is authorized here.

Wire control requests are capped at 16,384 bytes by
[`self_service_http::routes`](../../../server/src/self_service_http.rs); this is
not a response/storage cap. Core requests cap at 65,536. Login proof signatures
are canonical unpadded Base64 of 64 bytes (86 characters), not owner-ledger
Base58 signatures; they are deliberately absent from these stored objects.

No status field supplies a missing full result or proves membership UUID. Shape,
AEAD, a terminal flag and Rust credential validation cannot establish server
observation, finalized registry, fresh proof or UI authority; use only labelled
observations in this slice. No challenges, sessions, login proof signatures,
owner entropy, words or UI grants belong in metadata. Never invoke a signing
API merely to validate storage. Production proof/result authority stays gated.

Reuse standard AES-256-GCM framing `0x01 | nonce[12] | ciphertext | tag[16]`,
AAD `[0x01]`, distinct per-realm keys and fresh nonces. **Do not enlarge legacy
`SnapshotCodec` or claim `CatalogueAppleCryptography` already supports this cap**:
[their existing path](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/CatalogueAppleAdapters.swift)
`AppleFramedBox.seal/open` uses the old whole-plaintext 8 MiB bound.
A separately bounded realm raw-byte adapter and exact parser fixtures need
review; legacy `SnapshotCodec.open` repairs UTF-8 and is not strict admission.
Keep catalogue/owner 64 KiB limits. Realm policy follows messaging
`AfterFirstUnlockThisDeviceOnly`, non-synchronizable, backup-excluded files with
`.completeUntilFirstUserAuthentication`; owner policy remains unlocked-only.

## 5. Allocation, crash and preservation contract — proposed

Before allocation, verify matching durable `registryConfirmed` owner/catalogue,
full context, known artifact/key continuity and no existing selected-slot state.
Unregistered/pending/unpublished/locked owner grants no new allocation. Commit
only the selected allocation bit, retaining owner metadata and the sibling.

D87-01 requires allocation flag, known paths/artifacts and key continuity to be
checked before each mutating transition; read-only inspection is necessary, not
forbidden. This check is phase-aware: after durable allocation, the current
one-use permit can authorize the expected key/file creation intermediate.
Persisted `allocated` alone never authorizes it, and a new instance cannot
reconstruct the permit from missing halves. Keep failures read-only/preserving.

After final sync and permit consumption: create-only/no-follow `realms/` if
absent, then the selected slot directory; protect/exclude and sync new directories
and parents. An existing `realms/` must be a verified directory, never recreated.
Journal `realm-write-v1\n` in that slot's `write.pending`, protect/full-sync it
and its parent **before** key/core creation. Read back the create-only key.
For every commit: validate current retained state/key and transition; journal;
seal; create-only/protect/exclude/full-sync `state.enc.tmp`; rename; bounded exact
ciphertext readback; sync directory; remove only this transaction's intent;
sync directory again; only then adopt candidate or release success authority.
No network is dispatched by this component. No key/temp cleanup on failure.

| Retained condition / interruption | Required outcome, never automatic reset |
| --- | --- |
| Unallocated selected slot with any artifact/key | Refuse inconsistency; preserve it and all unrelated stores. |
| Allocated slot missing both halves or XOR; temp/intent, malformed/authentication/context/key mismatch | Freeze selected scope; no recreated permit, key, identity or fallback snapshot. |
| Failure/cancellation after allocation or any write begins | Allocation never reverses; writer terminally broken, no further backend effects or false success. Before/after-effect exceptions are both covered. |
| Clean schema-0 intermediate | Retain the same identity; explicit local continuation may upgrade and durably commit, never regenerate. |
| Realm A fails, common catalogue and B integrity verified | Fence A; allow only verified B storage operations. No claim of running lanes in this slice. |
| Owner read-only lock/freeze with verified B | Block owner work, new allocation and **all realm writes** in this slice; only the bounded read admission below is proposed. Binding disagreement, when observed, is not a benign lock. |
| Catalogue/installation continuity or common storage failure | Global freeze; preserve owner, both realms, keys and metadata. Inaccessible is not absent. |
| Final acknowledgement lost after all bytes/markers settled | Failed writer stays broken; a new reader may open the clean result. No universal crash detection, atomic Keychain/filesystem transaction or anti-rollback claim. |

### Verified B means local read-only admission

D87-05 uses **verified B** only for a local storage read in the current context,
not proof of live membership, finalized registry or transport/UI authority.
All of the following must hold before returning the read result:

1. The exclusive lease/holder/incarnation remain valid for the trusted isolated
   root; namespace identities are explicit and non-overlapping, not object IDs.
2. Catalogue/install key-file continuity, bounded AEAD open and full-state schema
   are valid; exact expected installID/ownerRef and both full realm tuples match.
   Owner and B are allocated with confirmed non-null binding, no common pending
   artifact or installation uncertainty. This does not solve app fresh/lost setup.
3. No-follow inspection of known parents/files, B key/file halves and actual
   namespace/policy checks succeed, with no B temp/intent or known retained-key
   substitution. Inaccessible is not absent. A's failure must be provably local.
4. B's authenticated frame/envelope obeys all caps/schema/context checks; binding
   matches the catalogue and any available validated owner binding. An inaccessible
   owner is not claimed freshly validated, and observed contradiction is not lock.
5. Full non-signing Rust validation succeeds; credential, trust and fingerprint
   match wrapper/slot; intent/result/enrollment/terminal obey §4. Status never
   invents a missing full result. D87-07 still blocks general schema-3 admission.
6. The operation performs no creation, signing, network, candidate adoption,
   cleanup or durable reconciliation. Missing evidence causes refusal, not a
   weakened definition of verified.

When owner is classified locked/frozen at write admission, refuse **all realm
writes before the first mutating effect**, including bookkeeping, intent/result/
terminal changes and journal cleanup. This is a deliberate narrowing of this
slice, not removal of the later device-only design. Only precisely classified
read-only lock qualifies; arbitrary I/O errors do not. A lock discovered after
writing begins never makes the failed writer retryable and grants no cleanup;
no OS-atomic observation/fencing across Keychain and filesystem is claimed.

Follow [MR-06/07](concurrent-realms-design.md#requirement-and-acceptance-mapping):
v4 data stays byte-exact; intact v5 catalogue/key causes old-reader refusal.
Losing both legacy objects while realm files survive must freeze the new reader;
the old reader is unsafe/unsupported for rollback. Rollback means compatible
full-state reader or stopped preserved installation, never deletion/reinstall,
old-ratchet restore or lowered server generations. Fresh-Welcome/lost-install
classification remains an app-adoption gate, not solved by a fixture root.

## 6. Login seam and unknown outcomes

Existing Rust supplies everything cryptographic: `create_identity`, then
`upgrade_v2` through [core dispatch](../../../clients/core/src/lib.rs) (438–489);
`identity_credential_v3` returns **credential and fingerprint separately**, and
`identity_device_proof_v3` returns only the signature
([clean_service](../../../clients/core/src/clean_service.rs), 885–911).
Owner proofs use existing Rust `identity_owner_proof_v3`
([Devnet crate](../../../blockchain/solana/client/src/lib.rs), 349–361).
No Swift signing, transcript hashing, key derivation or new Rust/core/ABI changes.

Proposed offline bookkeeping transitions: persist immutable intent before any
future mutation challenge; unknown dispatch/reply preserves it; validated full
result plus core `server_status_v2` candidate commit in one realm envelope;
clear only that matching intent in a **second durable commit**. A status-only
response is parsed separately. Mismatch freezes without deleting either input;
exact retry keeps operation/expected generation but needs a new challenge and
fresh explicit owner authority, never proof replay. `absent`, generation conflict,
revoked/banned/capacity never silently enroll, replace, repin or rekey.

Tests use labelled server observations, not a production verifier. Open never
signs as owner or networks. Production login, prompt/call admission, RPC trust
and transport retries remain separately reviewed D2/D3 work. Android
[`IdentityLogin.intent/run`](../../../clients/android-devnet/src/org/paranoid/devnet/IdentityLogin.java)
creates new operation IDs per run; it is comparison evidence, not a durable-intent
implementation to copy. Existing [core tests](../../../clients/core/tests/identity_v3.rs)
and [Android host test](../../../clients/android/test_identity_login.py) are case
sources, not iOS acceptance or a request to build another server stand.

## 7. RED → GREEN acceptance matrix — all new rows NOT RUN

Proposed suite: `RealmStoreContractTests` in the existing package test target.
One behavior at a time: compile an inert seam, observe an assertion fail for
missing behavior, implement minimally, rerun with regressions. Missing symbols/
SDKs/linkage, undiscovered or already-green tests are **not behavioral RED**.
Keep pre-fix/fixed SHAs, logs and TDD history; no test weakening.

| Row / proposed test suffix | RED observation → GREEN oracle | Mapping |
| --- | --- | --- |
| R01 `confirmedAllocationReopens` | Missing supported allocation fails the assertion → matched confirmed pair allocates A, real core schema-0 and schema-3 commits reopen with the same credential; B unallocated. | REQ-ID-002/003, MR-13 |
| R02 `preconditionsHaveZeroEffects` | Instrument new transition and remove its guard only in a disposable mutation probe → unconfirmed/unpublished/foreign/locked owner and cancelled operation cause zero writes/key/core creation. | MR-06/13 |
| R03 `sameLeaseHandoff` | Missing revocation permits stale access → old handles/late callbacks fail before I/O; second holder, mixed wrappers, consumed/foreign/expired permits refuse. | MR-02/09 |
| R04 `siblingAndOwnerPreserved` | Missing second-slot support fails → distinct A/B credentials/keys, own full trust and byte-identical retained owner/ledger/A/metadata while B commits; reverse direction too. | REQ-MULTI-001, MR-01/02 |
| R05 `faultEveryEffect` | Deliberate missing fence/order is detected → before/after directory, intent-parent-sync, key, temp, rename, readback, removal/final-sync faults retain evidence and stop further effects; no premature candidate/proof release. | MR-06 |
| R06 `retainedLossNeverCreates` | Missing classification is caught → allocated both-missing/XOR/temp/intent, wrong inode/key/context and authenticated malformed bytes refuse read-only; fresh coordinator gets no permit. | MR-06/07 |
| R07 `strictBytesAndCaps` | New codec absent or guard mutation fails → exact limits pass, +1/overflow/duplicates/unknowns/trailing data fail; literal field/token caps and metadata depth checked, escaped ASCII metadata refused while escaped core spans remain valid; existing owner/catalogue grammar unchanged, deep core delegated to Rust; raw Snapshot/core spans unchanged; retained device grammar mirrors Rust canonical UUID and a labelled generator-v4 regression; simulator-measured peak memory; no signing on open. | REQ-SEC-001, MR-02/14 |
| R08 `unknownOutcomeRetainsIntent` | Missing bookkeeping fails → restart/cancel/lost reply preserve operation, generation, credential and exact intent; status has only its three fields, absent remains unknown without a retained result; no synthesized membership or cleared unrelated intent. | AUTH-03/04, MR-05 |
| R09 `resultThenIntentClear` | Missing two-commit ordering fails → fault between result/core commit and clear reopens reconcilable state; schema-0 dry-run never adopts; schema-3 full validation (non-signing seam unresolved), credential/result/enrollment mapping and generation + 1 checked; mismatch/terminal A preserves B and never auto-replaces. | AUTH-04, MR-04/05 |
| R10 `freezeScopeAndCompatibility` | Missing scope guard is caught → owner lock permits only verified-B read admission after the full-validator dependency; every locked-owner realm write refuses before mutation; missing any verification item refuses; A fault contains only with verified common/B state; catalogue loss freezes all; old refusal APIs/tests and v4 bytes unchanged. | MR-06/07 |
| R11 `nativeEncryptedReopen` | Runtime RED against inert native adapter → real filesystem/CryptoKit commit/reopen, tamper/wrong-key/AAD/sliced-Data/upper-cap negatives and fault preservation pass. Memory keys explicitly labelled. | MR-06 component only |
| R12 `typeAndNoAdoptionBoundary` | Negative constructor/authority probes are wrongly admitted before fix → expected compiler rejection with positive controls; unchanged app/legacy/Rust/pins/dependencies; no default network/verifier factory. | REQ-CLIENT-001, MR-02/14 |

Already-passing negatives are regressions, not RED. Reverted test-only guard
mutations establish sensitivity, not feature-before-implementation RED. Sequence
R01, its R02/R03/R05/R06/R07 negatives, R04, R08/R09/R10, then R11/R12; no
horizontal framework before testing. No row alone closes a full MR gate.

## 8. Native handoff and exit criteria — conditional, not executed here

After approval/review, give Yaroslav's Mac agent the new source/test SHA, approved
formats, synthetic namespaces and R01–12 filters. Use pinned prerequisites and
final commands in [the Mac handoff](owner-store-mac-handoff.md#reproducible-final-mac-verification),
not an unchanged-owner rerun. Focus new tests in debug/release:

```sh
bash clients/ios/toolchain.sh swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter RealmStoreContractTests
bash clients/ios/toolchain.sh swift test -c release --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter RealmStoreContractTests
```

Then run existing owner/catalogue/codec/Devnet/core package regressions and the
full package, Swift 6 strict-concurrency/type-admission probes, notices and
unsigned iOS build. Require real signed-simulator Keychain creation/attribute
readback for **new isolated realm accounts** using the documented Keychain
workflow, preserving all existing accounts. Host memory fixtures cannot pass
that gate. Receipt: full SHA/source hashes, commands/exit codes, actual discovered
counts/skips, raw RED/GREEN, fixture-versus-native attribution, clean-source
before/after and independent final review with blocking findings closed.

D87-03 memory evidence uses **`xcodebuild test` on an iOS simulator** with
`XCTMemoryMetric`, an explicit test target/filter and exact build configuration.
The proposed package tests above and a passing build are not memory measurements;
no suitable memory harness was found in the frozen tree. Record the measured process,
interval spanning decrypt/parser/transfer/bridge/Rust/reply, simulator/runtime,
boundary success/refusal fixtures, actual numeric peak results and limitations.
[Apple's XCTMemoryMetric documentation](https://developer.apple.com/documentation/xctest/xctmemorymetric)
describes a before/after difference; do not relabel net change as transient peak.
Name and justify the actual peak metric/instrumentation in the receipt. No Linux
measurement substitutes for this selected acceptance; simulator measurements do
not prove physical-device memory or lock behavior. Memory acceptance is NOT RUN.

Missing native capability is NOT RUN; the known full-wrapper server-build limit
is neither repaired nor waived. No minimum count substitutes for named coverage.

## 9. Decisions still required and rollout boundary

- **Before implementation:** the bounded #73 source scope and D87 direction
  records in §1 are verified, not still awaiting repetition. Remaining gates:
  complete the namespace/query/readback contract, including Apple default/missing-
  attribute rules, independent exact-revision review and actual required evidence;
  do not claim `OwnerKeyBackend` already provides the new contract.
  D87-06/07 are RFC directions: separately scope and approve their RFC → ADR
  changes and compatibility before modifying shared code. General schema-3
  reopen requires the resulting real non-signing validator, not just a draft RFC.
  The bounded directions are technically agreed; the appendix remains draft,
  unimplemented and every new test NOT RUN.
- **Before app adoption:** fresh-install versus lost-catalogue classification,
  compatible owner mutations, scoped local metadata, app-enforced single lease,
  final callback fences, prompt/no-passcode/call policy, production RPC verifier
  and its bounded resource lifetime, strict login transport/result validation.
- **Before delivery:** exact-head native component and app evidence, separately
  authorized physical lock/backup/restart tests, existing-server admission and
  per-action install/enroll/replacement/peer consent. Follow [D1–D5](../../rfcs/0030-ios-identity-v3.md#implementation-increments):
  VDSina first; Hetzner membership confirmation and separately scoped Android
  second-realm capability before D5; one successful realm never satisfies MR-16.

The [iOS threat delta](../../security/ios-identity-v3-threats.md#concurrent-server-expansion--2026-10-12)
and [threat model](../../security/threat-model.md#trust-boundaries-to-define) retain
OS/Keychain/backend trust, no anti-rollback, dishonest-RPC and common-owner
correlation residuals. Words restore owner authority, not history or safety after
seed theft. No secret/snapshot/proof/raw-query logging; synthetic fixtures only.

Local documentation checks only; no existing phone/container, Keychain, server,
DB, live application endpoint, Apple account or production data touched. No new Mac/native/
device, live login or rollout-readiness claim follows.
