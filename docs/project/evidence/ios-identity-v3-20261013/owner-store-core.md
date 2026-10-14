---
status: draft
owner: ios
last_reviewed: 2026-10-14
---

# Isolated owner-store core: portable execution checkpoint

**Portable component delivery, not a native durable owner store, app
capability, #73 closure, ADR acceptance or live result.** The production
allocation/commit/reopen/ledger/authority orchestration proposed in the
[owner-store contract](../../../clients/ios/owner-store-format.md) at
`7848016147ce338bc5f3cc156c15017174c627ca` is implemented and executed on
Linux against non-cryptographic file/key/AEAD doubles plus the **real Rust
`identity`/`lookup`/`sponsored_sign` commands** through the unchanged C ABI.
The Apple owner adapter (typed owner policy, `.complete`,
`WhenUnlockedThisDeviceOnly`, no-sync, create-only directory) is **not
implemented**; its native-first tests are staged outside the active target and
are **NOT RUN**. Base: `7848016` on `feat/ios-owner-store-20261014`.

## Scope and contracts

- [RFC-0030](../../../rfcs/0030-ios-identity-v3.md) / draft
  [ADR-0017](../../../decisions/0017-ios-concurrent-identity-v3.md); accepted
  [ADR-0003](../../../decisions/0003-closed-alpha-review-policy.md) governs
  review. REQ-ID-002/003/004/006, REQ-CLIENT-001, REQ-MULTI-001, REQ-SEC-001
  are refined, not satisfied; no MR gate passes.
- `IdentityCatalogue.swift`, `CatalogueStore.swift`, their tests, the package
  manifest, legacy stores, Apple adapters, app, Rust, server and Android are
  byte-identical to the base (`git diff 7848016 --stat` on those paths is empty).
- New files (all `internal`, no app call site, no public factory):
  `Storage/OwnerAllocationCoordinator.swift`, `OwnerStoreCodec.swift`,
  `OwnerAttempt.swift`, `OwnerScalars.swift`, `OwnerVerifiedInput.swift`,
  `OwnerNamespaceLease.swift`; `Tests/ParanoidKitTests/OwnerStoreTests.swift`;
  staged `Tests/NativeFirstTests/OwnerNativeAdapterTests.swift` (NOT RUN).

## What is implemented and executed

| Contract area | Implemented behavior (executed on Linux) |
| --- | --- |
| §1 writers / lease | `OwnerNamespaceLease` with `LeasedFileIO`/`LeasedCryptography`; retired holder handles fail before any backend call (asserted: zero backend events); old `CatalogueStore` retired before the new coordinator acquires; coordinator has no fresh-catalogue API |
| §1 serialization | `busy` on reentry and while an external verifier is awaited (`awaiting` fence); `busy` does not cancel the active operation; MainActor-confined, no app/realm lock held across I/O |
| §2 admission | 65,536-byte raw cap before parsing; frame 29..65,565 before opening; schema-directed nonrecursive parser, duplicate decoded keys, unknown/missing fields, ASCII-only strings with caps, `U64` checked accumulation (`18446744073709551615` ok, +1 refused, no leading zero/sign/fraction), literal `true`/`false`/`null`, BOM/VT/trailing data refused |
| §2 scalars | `UUID`, `Name`, canonical `B58-32`/`B58-64` (bounded re-encode check, 44/88 char cap), padded `Entropy` 16/32, `WireBytes` 1..1,232 with encoded precheck, `RealmKey` must equal full fi or ru tuple, `Binding` five fields |
| §3 catalogue v5 | unallocated bytes == bootstrap bytes; `allocated` + null/non-null binding; binding without allocation refused; realm `allocated` → `invalidTransition`; version tokens `5` only |
| §3 owner v1 | `owner/identity/genesis/program` must equal real Rust `identity(entropy)`; binding checked through real Rust `lookup`; phases and ledger conditions; `wordsBackupConfirmed` false→true only, required for nonempty ledger |
| §3 ledger | eight entries max (ninth refused at the limit, no pruning); distinct IDs; `ownerSigned`/`assembled` exact stages; assembled framing `0x02‖sig‖owner_sig‖message` byte consistency; `sends` 0..3; only last entry unresolved; terminal heights strictly above prefix expiry maximum; `ownerBound` only when confirmed |
| §4 operations | `loadRetained`, `begin/finish/cancel`, `reserveNewOwner` → creation permit only after final sync, `initializeNew` (16-byte injectable fixture RNG, called only after durable reservation), `recoverVerified`, `confirmWordsBackup`, `recordOwnerSigned` (+append permit), `recordAssembled`, `reserveSend` (durable `sends+1` before one-use ticket, fourth refused), `resolveExpired` (typed dispositions, strict height, successor permit), `confirmRegistry` (unresolved→`ownerBound`, terminal unchanged), `publishConfirmedBinding` (idempotent, revalidated) |
| §4 permits | nonpersistable classes with `fileprivate` initializers; bound to operation, coordinator, revision; consumed once; invalid after finish/cancel/error/deadline/lease loss; foreign coordinator's permit refused |
| §5 ordering | allocation final sync → `mkdir owner/` → owner protect/readback → sync `owner/` + root → intent create/protect/sync → parent sync → key create once → readback compare → seal → temp → rename → byte-exact readback → parent sync → remove intent → parent sync; catalogue key never created |
| §6 matrix | every row of the consistency table executed, including empty `owner/` under unallocated, key-only, XOR, symlink inode, pending/temp, swapped-store documents, other-key box, foreign install; `locked` retryable without latch; any failure after write begins → `broken` with no backend access afterwards |

Explicitly **not** provided: production verifier/signer/assembler, entropy
source, Keychain policy, Darwin `.complete`, power loss, multiprocess locking,
anti-rollback, app namespace, Welcome/lost-install classification.

## Actual execution

Swift `6.3.3`, `x86_64-unknown-linux-gnu`. A **scratch-only** SwiftPM manifest
compiles the production files above plus the unchanged `IdentityCatalogue`,
`CatalogueStore`, `DevnetBridge`, `CoreBridge`, `JsonSpan` and their existing
tests against the Rust bridge built with `cargo build --offline --locked`
(`clients/ios/bridge`). Owned targets use `.swiftLanguageMode(.v6)`,
`-strict-concurrency=complete`, `-warnings-as-errors`. No repository manifest,
dependency, lock or CI edit. Scratch root (ephemeral; stages are read-only
copies with `receipt.json` SHA-256 and `execution.log`):

```text
/home/codex/.hermes/profiles/paranoid/cache/scratch/owner-store-1cbdbed1-94f8-41a7-bb48-be19aa99a171
```

| Run | Actual result |
| --- | --- |
| Final debug on head | 15 owner + 23 store + 28 codec + 21 Devnet facade = 87 XCTest methods, 0 failures, exit 0 |
| Final release on head | same 87, 0 failures, exit 0 |
| Owner creation fault matrix | 29 effects, before/after = 58 cases |
| Owner replacement fault matrix | 12 effects, before/after = 24 cases, plus 13 publication effects × 2 |
| Unchanged catalogue matrices | 35/36 boundaries, 70/72 cases, as in the store checkpoint |
| Rust bridge `cargo test --offline --locked` | lib 2, abi 6, devnet 6, devnet_memory 1 passed |
| Native owner adapter / full package / Xcode | **NOT RUN**: adapter not implemented |
| Real Keychain / Data Protection / power loss / device | **NOT RUN** |

Exact head of this receipt and SHA-256 of owned files are in the raw receipt
`clients/ios/bridge/evidence/owner-store-tdd.txt`.

### RED/GREEN record

One observable behavior per round; RED is an executed XCTest failure caused by
the missing behavior (inert stubs throwing `authorityRequired`), never a
compile error. Rows marked "first-run GREEN" characterize already-implemented
behavior and are **not** counted as RED; their teeth were checked with scratch
mutation probes on copies, never on committed source.

| Stage | Behavior | RED | GREEN |
| --- | --- | --- | --- |
| 01 | bootstrap → reservation → entropy after final sync → owner commit → reopen (real Rust identity) | 1/1 (`authorityRequired`) | 1/0; suite 73/0 |
| 02 | verified-recovery seam: owner confirmed, then matching binding, reopen both | 1/1 | 2/0 |
| 03 | explicit backup confirmation survives reopen | 1/1 | 75/0 |
| 04 | ownerSigned durable before leaving (real `sponsored_sign` vector), phase pending | 1/1 | 76/0 |
| 05 | assembled stage retains pre-sponsor fields, framing check | 1/1 | 77/0 |
| 06 | durable `sends+1` before ticket; fourth refused | 1/1 | 78/0 (after one test-fixture fix) |
| 07 | expiry resolution strict height, successor permit single use, taken name blocked | 1/2 | 79/0 |
| 08 | registry confirmation binds unresolved only; publication failure preserves intermediate | 1/7 | 80/0 |
| 09 | lease handoff retires old handles before new writer | 1/1 | 81/0 |
| 10 | 58-case creation fault matrix (ordering, no cleanup, no recreated permit, entropy after reservation) | 1/47 | 82/0 |
| 11 | consistency matrix incl. `locked` retry (new `OwnerBackendLock` seam) | 1/13 | 83/0 |
| 12 | busy while verifier awaited; deadline/foreign/no-name/thrown → zero writes; stale/foreign permits | 1/2 (after one compile fix, excluded) | 84/0 |
| 13 | byte/scalar/version/duplicate/escape/ledger-limit negatives, allocated catalogue grammar, old reader refusal | 1/5 | 85/0 |
| 14 | replacement + publication fault matrix | first-run GREEN; mutants: no-latch **survived**, no-readback **survived**, key-compare killed → added torn-readback and oversized-seal cases → all three mutants killed | 86/0 |
| 15 | every retained stage reopens with Rust allowlist `{identity, lookup}`; legacy store refuses | first-run GREEN; mutant "signing on open" killed (4 failures) | 87/0 |
| 16 | refactor: permit initializers `fileprivate`, no public mint | — | 87/0 |

Runtime counts in RED rows are executed methods / failures, not independent
bugs. Fixture-expectation corrections made during GREEN (06, 07, 10, 12) are
recorded in the stage logs; no historical RED log was edited.

## Native handoff (Mac, separate; not claimed here)

`Tests/NativeFirstTests/OwnerNativeAdapterTests.swift` names the proposed
`OwnerAppleFileIO(fileSystem:)` and `OwnerAppleCryptography(owner:)` with a
typed `policy` (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable = false`, `FileProtectionType.complete`). Required
native-first sequence on the Mac, as for PR #83:

1. Move the file into `Tests/ParanoidKitTests`, add minimal stub adapters
   throwing `ENOSYS`, observe runtime RED for
   `testRealReservationOwnerCommitAndReopenWithOwnerArtifactsPresent`.
2. Implement create-only/no-follow `createOwnerDirectory` (mode 0700, EEXIST on
   any inode), `protectOwnerAndExclude` setting **and reading back** `.complete`
   plus backup exclusion on directory, intent, temp; reuse `F_FULLFSYNC`/rename.
3. Implement `OwnerAppleCryptography` over a Keychain seam that selects the
   owner accessibility; the policy case must be **skipped with reason** on a
   host without Keychain, never passed by the memory double.
4. Run the four staged cases, `OwnerStoreTests` (15), `CatalogueStoreTests`
   (23), `IdentityCatalogueTests` (28), full package, notices, unsigned iOS
   build; record exact head, counts, skips and snapshot hashes.
5. Still open from PR #83 (do not reuse its frozen receipt): checked dynamic
   read-budget bounds and direct new-crypto `open` regressions for sliced
   `Data`, foreign AAD and the upper framing limit.

No Mac run of unchanged heads is requested; the frozen #81/#83 receipts are
not extended by this document.

## Contract deviations and open decisions for the parent

- None found that required changing the contract. Two interpretations were
  applied conservatively and should be confirmed by the contract reviewer:
  (a) an allocated catalogue with **no** owner artifacts after a cancelled
  reservation is reported as `continuity` (owner loss), and that classification
  latches the coordinator `broken` like other integrity failures;
  (b) a semantic refusal (`invalidTransition`, `authorityRequired`,
  `limitExceeded` before effects) ends the active operation, so the caller must
  `begin` again — the contract says permits are invalidated, it does not say
  whether the operation itself survives.
- `OwnerBackendLock.locked` is a new typed error the native adapters must
  throw for a precisely classified read-only lock; it is the only backend error
  the coordinator does not treat as failure.
- Base58 decoding is a bounded conversion used only for grammar/consistency;
  it is not a cryptographic routine and performs no signing or hashing.
