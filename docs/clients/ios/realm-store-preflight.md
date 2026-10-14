---
status: draft
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
created: 2026-10-14
last_reviewed: 2026-10-14
---

# Realm-store implementation preflight and acceptance contract

Supporting appendix to [RFC-0030](../../rfcs/0030-ios-identity-v3.md), not a new
RFC/ADR or rollout receipt. **All new choices are proposed, not approved or
implemented.** Next: isolated retained-owner → realm allocation → encrypted
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

**#73 remains OPEN as an authenticated scope-evidence gate.** Telegram
confirmation was relayed, but authenticated sender provenance was not retained;
see the [recorded limitation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153858611).
[Yaroslav's technical-basis agreement](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664)
is not product approval, formal [ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md)
acceptance or live authority. Before protected implementation: obtain Sergey's
durable exact-scope confirmation, technical disposition of the new choices and
independent exact-revision review under accepted
[ADR-0001](../../decisions/0001-documentation-as-code.md),
[ADR-0003](../../decisions/0003-closed-alpha-review-policy.md) and the
[approval policy](../../governance/documentation-policy.md#durable-approval-and-delegation-records).
No approval is inferred from urgency, CI, prior component review or a merge.

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

`Binding` and full realm grammar reuse [owner format §2](owner-store-format.md#2-byte-admission-and-scalar-types).
`SnapshotV4` is the existing raw wrapper, including its **verbatim core state**;
no JSON string escaping, dictionary reserialization or foreign-snapshot cloning.
New candidates have an empty legacy token; schema 0 is a durable intermediate,
schema 3 is required before v3 credential/proof use. Validate wrapper/core trust
and public credential against the envelope; parse success is not authority.

`Intent` has the exact protocol challenge-request fields (enroll/replace only),
plus the core-returned fingerprint: complete credential, operation UUIDv4,
chain/owner/name and decimal-string expected generation, not arbitrary JSON.
`CommitResult` has exactly operation, membership, generation, account, device,
credential_fingerprint and active mode. Compare every result/context field;
status's `{mode,generation,operation}` cannot manufacture missing membership data.
Terminal state is realm-local, outside the owner secret. No challenges, sessions,
proof signatures, owner entropy, words or UI authentication grants belong here.

Proposed bounds: core span ≤8,388,608 bytes; **all other plaintext bytes**, including
Snapshot wrapper and outer JSON syntax, ≤131,072; total ≤8,519,680; sealed frame
≤8,519,709. Strict duplicate-decoded-key, unknown/missing field, type, version,
UTF-8, trailing-data and overflow refusal precedes effects; field limits follow
the cited formats. Check limits before copying/decoding; bound parser depth and
span handling with fixtures before approval. Never prune retained state to fit.

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
| Owner read-only lock/freeze with valid retained catalogue/B envelope | Block owner work/new allocation; proposed retained device-only B access does not require owner signing. Binding disagreement, when observed, is not a benign lock. |
| Catalogue/installation continuity or common storage failure | Global freeze; preserve owner, both realms, keys and metadata. Inaccessible is not absent. |
| Final acknowledgement lost after all bytes/markers settled | Failed writer stays broken; a new reader may open the clean result. No universal crash detection, atomic Keychain/filesystem transaction or anti-rollback claim. |

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
| R07 `strictBytesAndCaps` | New codec absent or guard mutation fails → exact limits pass, +1/overflow/duplicates/unknowns/trailing data fail; raw Snapshot/core span unchanged; no signing on open. | REQ-SEC-001, MR-02/14 |
| R08 `unknownOutcomeRetainsIntent` | Missing bookkeeping fails → restart/cancel/lost reply preserve operation, generation, credential and exact intent; status cannot synthesize full result or clear unrelated intent. | AUTH-03/04, MR-05 |
| R09 `resultThenIntentClear` | Missing two-commit ordering fails → fault between result/core commit and clear reopens reconcilable state; mismatch/terminal A preserves B and never auto-replaces. | AUTH-04, MR-04/05 |
| R10 `freezeScopeAndCompatibility` | Missing scope guard is caught → owner lock permits intact device-only reopen; A fault contains only with verified common/B state; catalogue loss freezes all; old refusal tests and v4 bytes remain unchanged. | MR-06/07 |
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
Missing native capability is NOT RUN; the known full-wrapper server-build limit
is neither repaired nor waived. No minimum count substitutes for named coverage.

## 9. Decisions still required and rollout boundary

- **Before implementation:** authenticated #73 scope; Cooldom66671 disposition
  and independent review of the successor writer/version strategy, complete
  field/parser bounds, key-namespace identity checks, creation authority and
  owner-locked retained-read classification. The schema/caps above are proposals.
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
DB, network endpoint, Apple account or production data touched. No new Mac/native/
device, live login or rollout-readiness claim follows.
