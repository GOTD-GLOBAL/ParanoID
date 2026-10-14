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

## Corrected source: parent replay and scoped review closure

Correction source **`985b30b20bdf896813410262fecbeb68ec256b4b`** and receipt-only
HEAD **`1df946251b4338fef6de8edbc0b22dd56cc97858`** are subsequent to the initial
checkpoint described below. The [raw correction receipt](../../../../clients/ios/bridge/evidence/owner-store-review-fixes.txt)
retains runtime RED/GREEN, compile/fixture failures, timed-out runs and exact
source hashes without rewriting historical evidence.

Parent executed the corrected source independently: **109/0 in debug and 109/0
in release**, including 15 existing owner and 22 new regression methods plus
unchanged 23 catalogue-store, 28 catalogue-codec and 21 Devnet tests. Both runs
use the cached debug Rust bridge; only Swift is optimized for release. Receipts
and complete logs are in profile scratch
`owner-parent-fix-review-1df9462-20261014/{parent-debug,parent-release}/`.
All 16 listed source/test hashes and both executed snapshots match the exact
Git objects. The tail from code commit to receipt HEAD changes only the raw
receipt, not runtime/tests/build inputs.

The parent also ran the same compile-negative policy probe against both builds:
old source compiles it (exit 0); corrected source refuses it (exit 1) specifically
because a CatalogueOnly backend does not conform to OwnerCryptography. This is
type-boundary evidence, not actual Keychain accessibility enforcement.

Corrections cover live ticket issuer/operation/revision/phase/lease checks;
explicit close and cancellable/deadline-bounded external wait; fencing before
entropy/sign/assemble and around effects/final sync; retained-origin integrity
freeze; eight-entry reconciliation with **nil append permit at capacity**;
conditional owner conformance; and strict bounded encoding. New regression
coverage also exercises stale-result isolation from a successor, busy-after-effect
uncertainty and contradictory nameTaken/proposed-name evidence.

The prior fixture's simultaneous writer reuse was replaced by explicit close/
retire/reopen. Its deadline-entry wait has a failing watchdog; an unavailable
verifier entry no longer hangs a test. Parent inspected these test changes;
substantive old storage/refusal assertions remain. Pinned Swift is also 6.3.3,
but no Apple SDK compilation is claimed from the Linux compiler.

The independent **retained-integrity, ledger, codec and type-policy** review at
exact `1df9462` now closes its target findings with no new P1/P2. It separately
ran 109/0 debug and release, five new probes and the expected compile-negative.
Parent read the report/probes and repeated those five probes: **5/0, exit 0**,
under `owner-parent-fix-review-1df9462-20261014/integrity-closure-probes/`.
The new cases distinguish invalid new payloads from retained corruption, preserve
terminal history during full-ledger reconciliation/confirmation and reject
oversized writer inputs before core validation. The reviewer report is in
profile scratch `owner-integrity-recheck-47894333-a2af-4d8f-a65a-2c3b524e54eb/`.

The separate **authority/lease/async** exact-head review now closes its target
groups too, with no remaining P1/P2 in the isolated component scope. It repeated
109/0 in debug and release and six new probes in both modes. Parent read those
probes and independently ran **6/0**, exit 0, in
`owner-parent-fix-review-1df9462-20261014/authority-closure-probes/`: all three
async entrypoints, pre-cancellation, late success/nil/error while a successor
waits, issuer deallocation during suspended verification, holder replacement and
foreign close/root checks. The review report is in profile scratch
`owner-closure-43d76f7d-8c4c-42b4-ab8d-001e356b04d0/`.

Both reviewers used fresh independent gpt-6-astra contexts, the same model family
as the implementation agents. This is advisory AI component review, not a human
security audit or acceptance of the format, eight-entry product cap, ADR or app.
An uncooperative verifier worker may stay suspended after caller cancellation:
its late completion has no authority and it does not retain the coordinator,
but forced worker termination, global task-pool bounds and erasure of all Swift
request copies are not promised. The future production verifier owns those
resource/lifetime limits.

**Portable source review is closed; native storage acceptance is not.** The
native blueprint now has an explicit real-Keychain XCTSkip placeholder and an
honest unregistered/backup-only case name, with required remaining stages
visible; it is still excluded and NOT RUN. Owner Apple implementations and all
native/app/phone acceptance remain separate work.

## Initial-source parent review: baseline green, contract regressions blocking

On frozen `697bd68520d1ba764dd306d267b40d0c776c5e1f` the parent independently
repeated debug and release: each **87 XCTest methods, 0 failures**. Release here
means optimized Swift linked to the previously built **debug Rust** static
library, not a separately optimized Rust build. The source snapshots and hashes
are in profile scratch `owner-parent-review-697bd685-20261014/` under
`baseline-debug/` and `baseline-release/`; each has `receipt.json` and
`execution.log`.

Additional parent `OwnerParentProbeTests` executed six methods with **eleven
assertion failures**, exit 1, not compiler/setup errors. The retained stage is
`parent-contract-probes/` in that same scratch root. At this reviewed source:

- `OwnerDispatchTicket.take()` releases after finish or cancel instead of
  rechecking live operation/revision/deadline/lease authority.
- Explicit cancellation during a verifier wait is refused as busy; releasing
  valid late evidence then performs recovery writes.
- Expiry during an allocation write still returns a creation permit rather than
  treating post-effect cancellation/expiry as terminal uncertainty.
- After namespace retirement, initialization generates entropy before its
  wrapped backend finally rejects the stale holder.
- `LeasedCryptography<Inner: CatalogueCryptography>` unconditionally acquires
  `OwnerCryptography`, contrary to the typed owner-policy boundary.
- Allocated-catalogue encoding silently removes a non-null binding from invalid
  unallocated input instead of refusing that input.

The independent codec/ledger review additionally reproduced two **P2** failures
on this same frozen source. Parent reran its six probe methods: **25 failed
assertions, 0 unexpected, exit 1**, saved as `independent-codec-probes/` in the
parent scratch root above. That count is not 25 separate defects:

- Retained schema/version/size/material errors do not latch the writer broken;
  it accesses backends again, and the same instance resumes after fixture bytes
  are externally restored. This does not mean corrupt bytes were accepted or
  automatically repaired. Invalid new caller input must remain distinguishable
  from retained-storage integrity failure; only the latter freezes.
- At eight entries `resolveExpired` refuses before invoking the verifier, leaving
  the last attempt unresolved. Capacity must stop new append/sign operations,
  not reconciliation or registry confirmation. No cap increase/pruning is needed.

Catalogue encoder normalization is confirmed, including an escaped invalid name,
but is **P3/API hardening** in the current internal-call-site scope, not a proven
runtime security exploit. The owner encoder's pre-validation allocation is
separate; its invalid/oversized values do refuse. The reviewer report and source
probes are retained under profile scratch
`owner-codec-review-c0719d49-dfe2-49ff-bb19-2aeaec6cf518/`.

The independent coordinator review confirms those same freeze/cap findings,
not additional unique P2s, and expands the authority checks. Parent reproduced
the new pre-sign/final-sync cases on the frozen source: **two methods, three
assertion failures**, exit 1, under `coordinator-boundary-probes/`. Delaying a
successful read-only refresh past the deadline still invokes real Rust
`sponsored_sign` once on a public fixture before returning cancelled. Expiry
inside the final sync still releases a dispatch ticket without freezing. No
network or real owner key was involved. Authority must be rechecked immediately
before protected calls and at final capability release, not only at method entry.

The reviewer also exercised ticket invalidation after errors, revision/phase
changes, deadline, lease retirement and coordinator destruction, and cancellation
of an outstanding verifier after deadline. Its frozen report/probes are under
profile scratch `owner-review-4559fad8-5963-433d-b3c8-7b6cedab96c5/`. Neither
review covers the concurrently changing correction branch; a new exact-SHA
review is required. A single coordinator broken flag does not yet express future
owner/common runtime scope; no global messaging outage was demonstrated here.

These were **blocking deviations at the initial `697bd68` SHA**; its positive
baseline did not establish readiness. The original unrun native policy case
inspected only a memory-backed descriptor, and its "every retained stage" name
overstated coverage. The later corrections and scoped closure are recorded
above; the original failures are not erased or presented as passing tests.
Native/ADR/adoption gates remain separate.

## Initial checkpoint scope and contracts

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

## Initial checkpoint implementation and execution

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
| §4 permits | Private minting and foreign creation/append-permit checks exist; dispatch-ticket lifetime, mid-effect expiry and pre-entropy lease checks fail the parent regressions above. The full invalidation contract is NOT satisfied at this SHA |
| §5 ordering | allocation final sync → `mkdir owner/` → owner protect/readback → sync `owner/` + root → intent create/protect/sync → parent sync → key create once → readback compare → seal → temp → rename → byte-exact readback → parent sync → remove intent → parent sync; catalogue key never created |
| §6 matrix | Existing tests cover empty owner directory, key-only/XOR, links, pending/temp, swapped documents/keys, foreign install and retryable locked reads; injected thrown write failures latch broken. Mid-write expiry/cancellation and remaining integrity cases still require review closure |

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

## Native handoff (implementation still required)

Use the [complete owner Apple implementation handoff](../../../clients/ios/owner-store-mac-handoff.md)
and the exact starting SHA in the parent PR comment. It specifies real native
RED/GREEN, complete catalogue/owner encrypted commit/reopen, typed protection,
additional pending/confirmed/foreign-key cases, separate real-Keychain evidence,
notices and unsigned build prerequisites. It is not a request to rerun unchanged
PR #78/#81/#83 code or build another server.

The four staged `Tests/NativeFirstTests/OwnerNativeAdapterTests.swift` methods
are only an unrun starting blueprint, not full native coverage. Its real-policy
case now explicitly skips until genuine Keychain insertion/readback exists; that
future skip has not executed and is not counted in the portable suite. Native
implementation must preserve the reviewed lease/authority/format contract and
keep old messaging defaults and bootstrap refusals intact.

## Interpretations and remaining integration boundaries

- Scoped source review is closed for `1df9462`, not native storage or app adoption.
  An allocated catalogue missing owner state is loss, never renewed creation
  authority. Pre-effect semantic refusals invalidate that operation without
  freezing valid storage; a stale callback/ticket cannot revoke its successor.
- `OwnerBackendLock.locked` remains an explicit native-adapter responsibility:
  only precisely classified read-only protection lock is retryable. Generic
  permission errors must not masquerade as absence or safe retry.
- An uncooperative external worker may retain its own request copies after the
  caller has timed out. The component revokes authority and frees its issuer;
  it does not force-kill the verifier, promise global worker bounds or guarantee
  Swift-memory erasure. Production verifier/resource policy remains unimplemented.
- Owner/common runtime containment, fresh-Welcome classification and app adoption
  are not delivered by this owner-only component. Eight entries remain a
  non-adopted bounded proposal with no automatic pruning or reset.
- Base58 handling is bounded encoding/consistency, not new cryptography. No
  changes to shared derivation/signing, real keys, server state or phone sessions
  follow from these source checks.
