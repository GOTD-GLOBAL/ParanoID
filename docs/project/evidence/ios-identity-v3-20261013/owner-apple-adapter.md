---
status: draft
owner: ios
last_reviewed: 2026-10-14
---

# Apple owner-store adapter: native RED/GREEN receipt

**Component delivery on the build Mac, not durable-store adoption, app startup,
login or a phone result.** The Apple backends the
[portable owner-store checkpoint](owner-store-core.md) left unimplemented now
exist in `clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerAppleAdapters.swift`
and are exercised by the four staged native cases (moved into the active
`ParanoidKitTests` target: three pass on the host, the real-Keychain policy
case is a host skip), eight owner native-stage cases, eight lock-classification
cases, five follow-up cases on the catalogue adapter, and — separately, on an
ad-hoc signed simulator — two real-Keychain cases in the application test
bundle. `OwnerAllocationCoordinator`, the owner/catalogue codecs, the
lease, `CatalogueStore`, the legacy stores, `KeychainKey`, `Package.swift`,
pins, the application sources, the Rust bridge and every other component are
unchanged. The catalogue adapter received only the two follow-ups the earlier
receipt recorded (read-budget arithmetic/allocation; shared framing helper).

Base: `2ed901ddf5fd5441578392aa7a6a2380c5130108` (PR #84 head); branch
`feat/ios-owner-apple-adapter-20261014`, worktree
`../paranoid-ios-owner-apple`, created without touching other worktrees,
simulators or keys. Host: macOS (Darwin 27.0.0), Xcode 26.6 (17F113), iOS SDK
26.5, Swift 6.3.3, Rust 1.98.1, pinned WebRTC 150.7871.01 from the verified
cached archive. Author/model provenance: Yaroslav's Mac agent (Claude Fable 5.1
through Claude Code), per the execution split recorded in the handoff. This is
not a human audit.

## What the adapters do

`OwnerAppleFileIO(fileSystem:)` — `OwnerFileIO`, composing the tested
`CatalogueAppleFileIO` for the seven catalogue operations, plus:

- `createOwnerDirectory`: `mkdir(2)` with mode `0700`. The final path component
  is never followed, so an existing link, file or directory is `EEXIST` and left
  untouched; then `open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`, `fstat`
  (must be a directory) and `fchmod(0700)` if the created mode differs (a
  umask only ever removes bits; the check is defensive, not a widening).
- `protectOwnerAndExclude(_, policy: .ownerComplete)`: no-follow inspection
  first (a link or foreign inode is refused with `EFTYPE`, absence with
  `ENOENT`); Data Protection `.complete` set and read back (iOS only — the host
  has no such attribute), then backup exclusion set and read back on the inode.
- `read`: the catalogue adapter's bounded read in its internal stages
  (no-follow inspection; the `open(2)` syscall alone; `fstat` with inode
  confirmation; bounded descriptor read). Exactly one classified exception:
  `EPERM` **from the open syscall itself**, **of `owner/state.enc`**, **while the
  platform reports protected data unavailable** (`protectedDataAvailable()` is
  `false`, sampled after the failure) is `OwnerBackendLock.locked`. The `fstat`
  that follows the open, the inode confirmation and the descriptor read run
  outside that catch (review follow-up). `EACCES`, any other stage, the
  catalogue or any other path, and `EPERM` with protected data available or
  with no signal at all are failures the store freezes on. The plain
  `init(fileSystem:)` has no signal, so it never classifies a lock; the
  application supplies `UIApplication.shared.isProtectedDataAvailable` through
  `init(fileSystem:protectedDataAvailable:)` when it integrates.

`OwnerAppleCryptography(owner: any OwnerKeyBackend)` — `OwnerCryptography` over
one explicit owner-policy backend: 29-byte shipped framing, `seal` through
`SnapshotCodec.seal` after an exact-UTF-8 check, raw `AES.GCM.open` with the
version byte as associated data (never the lossy String decoder), load/create
delegated to the backend and followed by a `storedPolicy()` readback that must
be the canonical owner policy (a weaker retained item is refused, never deleted
or migrated), no foreign namespaces (that query is refused), no key export or
deletion. `OwnerKeyBackend` is `WrappingKeyStore` plus `storedPolicy()`; the
messaging `KeychainKey` does not conform and does not type check here (review
follow-up). Host memory fixtures conform behind a labelled FIXTURE-ONLY seam. `seal`/`open` are the shared `AppleFramedBox` routine the
catalogue adapter now uses too.

`OwnerKeychainKey(account:)` — the owner-policy Keychain backend, a separate
type from the messaging `KeychainKey`, whose `AfterFirstUnlockThisDeviceOnly`
default is untouched. No default account and **no policy parameter**: the
canonical policy (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable = false`) is a static constant and `OwnerKeyPolicy`'s
initializer is file-private, so a weaker value cannot be constructed anywhere
(review follow-up). `create()` writes that policy, reads the stored attributes
back and refuses a mismatch; a duplicate is `errSecDuplicateItem`, never
replaced. `load()` refuses a retained item whose stored policy is not canonical
(`StorageError.keychain(errSecDecode)`: not absence, not a lock, nothing
deleted or migrated). `load()`/`exists()` map `errSecInteractionNotAllowed` to
`OwnerBackendLock.locked` and every other status to `StorageError.keychain`.
`deleteRetained()` refuses: the owner store never deletes a retained key.

## RED/GREEN record (Mac host, real temporary roots, real CryptoKit)

Logs under the worktree's ignored `clients/ios/out/logs/tdd/`. Snapshot hashes
are SHA-256 prefixes of `OwnerAppleAdapters.swift` / `CatalogueAppleAdapters.swift`.

| Step | Snapshot | Command / result |
| --- | --- | --- |
| RED, case 1 | stub owner adapters `b299eacd…`, commit `9b4e939` | `swift test --filter OwnerNativeAdapterTests.testRealReservationOwnerCommitAndReopenWithOwnerArtifactsPresent` → **1 test, 1 failure**: `caught error: "backendFailure"` (every stub throws `ENOSYS`); exit 1 |
| GREEN, case 1 | real adapters `88edbf12…` / catalogue `28b8e0e9…`, commit `aa128a5` | same filter → **1 test, 0 failures**; exit 0 |
| case 3 first run | same | `testOwnerDirectoryCreationIsCreateOnlyNoFollowAndNeverCleansUp` → 1/0 on first run (regression coverage, no RED manufactured) |
| case 4 first run | same | `testUnregisteredBackupReopenWithRealBoxAndTamperedTagRefusal` → 1/0 on first run |
| case 2 | same | `testOwnerKeyPolicyIsWhenUnlockedThisDeviceOnlyAndNotSynchronizable` → **skipped** on the unsigned host (no Keychain); its real evidence is the simulator case below |
| suites | same | `OwnerNativeAdapterTests` 4 (1 skipped)/0; `CatalogueNativeAdapterTests` 4/0; `CatalogueAppleFileIOTests` 21/0 (with the read-budget change); `OwnerStoreTests` + `OwnerStoreRegressionTests` 37/0; `CatalogueStoreTests` + `IdentityCatalogueTests` 51/0 |
| follow-ups + stages first run | same + new tests, commit `b9854d4` | `CatalogueAppleFileIOTests` **26/0** (5 new); `OwnerAppleNativeStagesTests` **8/0** on first run — regression coverage |
| mutation probe A | catalogue adapter with the pre-follow-up budget arithmetic restored (not committed) | `testReadLimitAtIntMaxIsRefusedInsteadOfTrapping` → the test process **died with signal 5** (the `maximumBytes + 1` overflow trap); source restored to `28b8e0e9…` |
| mutation probe C | owner adapter with the no-follow inspection removed from `protectOwnerAndExclude` (not committed) | `testOwnerDirectoryCreationIsCreateOnlyNoFollowAndNeverCleansUp` → 1 test, **1 failure**; source restored to `88edbf12…` |

Owner native-stage coverage (8 cases): synthetic verified recovery → confirmed
owner commit → binding publication → reopen of the matching pair with no
entropy draw; ownerSigned (real Rust `sponsored_sign` on the public all-zero
vector), assembled (synthetic structural assembly, never signature-valid),
one send reservation and registry confirmation each reopen with exact saved
bytes and counters; **FIXTURE-ONLY** publication interrupted before the
catalogue intent (clean intermediate on reopen; only an explicit
`publishConfirmedBinding` completes it) and after the intent (leftover intent
freezes the catalogue with `artifactsPresent`, every byte kept); leftover owner
intent/temp, foreign owner key (`authenticationFailed`), foreign installation
context (`contextMismatch`), missing owner file or directory under an allocated
catalogue (`continuity`, nothing recreated) all refuse without modifying
evidence; a read-only owner lock before any effect is `locked` and retryable
without latching, a lock right after key creation (write begun) is terminal,
the intent stays and the key is kept; **FIXTURE-ONLY** failed full sync of the
owner candidate latches the writer and keeps temp, intent and key; the owner
cryptography refuses foreign-namespace queries and, on the host, a permission
error on read stays `EACCES`, not a lock. Synthetic verifier/signer/assembler
fixtures are trusted input, not live registry or signature verification.

Catalogue follow-up coverage (5 cases): `Int.max` limit refused with `EINVAL`
instead of trapping, `Int.max - 1` reads a small file (buffer follows the
inspected size, not the budget), negative limit refused; **FIXTURE-ONLY**
growth within the budget is still refused; `open` on a `Data` slice with a
nonzero start index; a box sealed under foreign associated data refused; the
upper framing limit (8 MiB + 29) accepted and one byte more refused.

## Review correction (PR #85, P2): lock classification

The first native head `b9854d4` turned any `EPERM` labelled `.read` into
`OwnerBackendLock.locked` on iOS, without evidence that protected data was
unavailable, without distinguishing the `lstat`/`open`/`read` stages, and for
the catalogue as well as the owner file — so an ordinary permission error
could bypass the store's freeze. Corrected on `3c8cbab` through actual
RED/GREEN, with the platform state injected and labelled FIXTURE-ONLY:

| Step | Snapshot (`OwnerAppleAdapters.swift`) | Result |
| --- | --- | --- |
| RED | `d2cc5f83…` — old classifier, only the `protectedDataAvailable` seam added so the new tests compile | `OwnerAppleLockClassificationTests` **8 tests, 4 failures**, all in the positive case `testConfirmedUnavailabilityAtOpenOfTheOwnerFileIsARetryableLock` (the old code classified nothing on the host); the seven negative/terminal cases already held |
| GREEN | `011eba8b…` (owner) / `f39f8a99…` (catalogue read split into `inspectRegular` → `openRegular` → `readBounded`) | **8 tests, 0 failures** |

Cases: positive — confirmed unavailability at open of `owner/state.enc` →
`locked`, coordinator `loadRetained` is `.locked` and not latched, retry after
the signal returns succeeds; negative — same `EPERM` with protected data
available → failure and the coordinator freezes; `EACCES` with the signal
unavailable → failure; `EPERM` at the descriptor-read stage → failure; `EPERM`
at the inspection stage → failure; `EPERM` opening the catalogue
(`text-state.enc`) → failure and freeze, never an owner lock; the plain
initializer (no signal) → failure; and the confirmed lock surfacing in the
readback of an owner write is terminal (writer latched, renamed candidate,
intent and key kept, reopen refuses with `artifactsPresent`).

Verification on code head `3c8cbab` (RED commit `584adad` rebuilt byte-exact
from the tested snapshot `d2cc5f83…`; GREEN commit `3c8cbab`), each step
separate: the nine focused suites **138 tests, 1 skipped, 0 failures**; the
complete package **548 tests, 1 skipped, 0 failures** — the core timing case
below happened to pass in this run, which does not change its intermittent
record; `notices.py --offline` 146 crates + WebRTC; `test_notices.py` 32 PASS;
`xcodebuild … -sdk iphoneos … CODE_SIGNING_ALLOWED=NO build` `** BUILD
SUCCEEDED **` (unsigned binary SHA-256 `e290981337601918…`); simulator
`KeychainStoreTests` rerun on this head: see the section below.

## Review correction 2 (PR #85 follow-ups): open-only classification, owner-policy admission

Base for this round: our `98f58b0` merged by ordinary history with the
coordinator's watchdog test fix `4b041ac` (PR #86 head `af82b9c`) as merge
commit `2694d3e`; native blobs unchanged by the merge. Two findings, one RED/GREEN
loop (platform state injected, FIXTURE-ONLY; the compile probes are source
checks on the native compiler, not committed):

| Step | Snapshot (`OwnerAppleAdapters.swift`) | Result |
| --- | --- | --- |
| RED `cf2b48e` | `ee6ecd1b…` — `OwnerKeyBackend` protocol and the `fstat` injection hook added, classifier and admission unchanged | `OwnerAppleLockClassificationTests` **11 tests, 3 failures**: `testEPERMAtTheFirstFstatAfterOpenIsAFailureNotALock` (the first `fstat` after a successful open became `locked`, the reviewer's trace) and `testABackendReportingAWeakerStoredPolicyIsRefusedBeforeUse` (the key was returned); the later-`fstat` negative already held |
| RED compile probe | same | `OwnerAppleCryptography(owner: KeychainKey(…))`, `OwnerKeychainKey(account:policy:)` and `OwnerKeyPolicy(accessible:synchronizable:)` all **compiled** (admitted) |
| GREEN `7322b68` | `8426cc94…` (owner) / `a0f1e5f6…` (catalogue: `openOnly` + `confirmOpened`) | **11 tests, 0 failures**; `OwnerNativeAdapterTests` 4 (1 skipped)/0; `OwnerAppleNativeStagesTests` 8/0; `CatalogueNativeAdapterTests` 4/0; `CatalogueAppleFileIOTests` 26/0 |
| GREEN compile probe | same | the three constructs are **rejected**: `argument type 'KeychainKey' does not conform to expected type 'OwnerKeyBackend'`; `extra argument 'policy' in call`; `'OwnerKeyPolicy' initializer is inaccessible due to 'fileprivate' protection level` — while the canonical control `OwnerAppleCryptography(owner: OwnerKeychainKey(account:))` compiles |

Negative cases now in the lock suite: `EPERM` from the first `fstat` after a
successful open of `owner/state.enc` with protected data unavailable → ordinary
adapter failure and a frozen coordinator (`backendFailure`); `EPERM` from the
later `fstat` → failure; a backend whose retained item reads back a weaker
policy → `loadKey()` refuses, nothing deleted (FIXTURE-ONLY descriptor). The
eight earlier cases and the terminal-after-write preservation case still hold.

**Descriptor ownership (found by a background security review of the GREEN
above, fixed before publication):** the first GREEN registered the owner read's
deferred `close` before `confirmOpened`, which also closed the descriptor on an
`fstat` failure — a double close. RED `6bfe011` added a close-counting hook on
the owner-file descriptor (`"2" is not equal to "1"` on the first-`fstat`
failure); GREEN `17d8d88` makes `confirmOpened` never close (the caller
owns the descriptor) while `openRegular` closes once on a failed confirmation.
The lock suite now asserts exactly one close on the first-`fstat` failure, on
the later-`fstat` failure and on success.

### Final acceptance on code head `17d8d88`

Prerequisites rerun: `bridge/check.sh` rc 0, `build-core.sh` 3 slices, WebRTC
verified. Then, each step separate:

| # | Command | Result |
| --- | --- | --- |
| 1 | the repaired timing test `OwnerStoreRegressionTests.testExternalWaitIsBoundedAndCancellationDoesNotDependOnVerifierCooperation`, ten consecutive runs | **10 of 10 passed**, exit 0 each (watchdog variant from PR #86) |
| 2 | focused filter (lock, owner native, owner stages, owner store and regressions, catalogue native, catalogue seams, catalogue store, catalogue codec) | **141 tests, 1 skipped, 0 failures** |
| 3 | complete package | **551 tests, 1 skipped, 0 failures** (548 before this round + 3 new classification cases); no compiler warnings beyond the pre-existing ContactFlowError one |
| 4 | `notices.py --offline` / `test_notices.py` | 146 crates + WebRTC 150.7871.01 / PASS 32 |
| 5 | `xcodebuild … -sdk iphoneos … CODE_SIGNING_ALLOWED=NO build` | `** BUILD SUCCEEDED **`, unsigned binary SHA-256 `9ca4aebb11a71a05…` |
| 6 | ad-hoc signed simulator `KeychainStoreTests` (fresh test namespaces) | **14 tests, 0 failures**, `** TEST SUCCEEDED **` — owner policy readback, real-key framing and the legacy-item refusal included |

## Real Keychain policy — ad-hoc signed simulator

`KeychainStoreTests` in the application test bundle, run ad-hoc signed on the
disposable simulator `ParanoID-pr75-7a39897` (iPhone 17 Pro, iOS 26.5,
`BFC5BCA0-BFDD-4F3B-8E57-E9025729FB50`) the way `build.sh` runs its Keychain
step — `xcodebuild test … -only-testing:ParanoIDTests/KeychainStoreTests`
without `CODE_SIGNING_ALLOWED=NO`, after `notices.py --offline` (a fresh
worktree fails the bundle copy phase without it; first attempt recorded as such):

- `testTheOwnerItemIsWhenUnlockedThisDeviceOnlyAndNotSynchronizable`: an
  `OwnerKeychainKey` under a fresh `paranoid-test-owner-<UUID>` account is
  absent before `create()`, present after; `storedPolicy()` and a direct
  `SecItemCopyMatching(kSecReturnAttributes)` both read back
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable =
  false`; 32-byte material; `load()` equals the created key; a second `create()`
  is `errSecDuplicateItem`; `deleteRetained()` refuses and the item stays; the
  messaging `KeychainKey` test item keeps its own, different key. **passed**.
- `testARealKeychainOwnerKeySealsAndOpensTheShippedFraming`: the Keychain-backed
  owner key seals and opens the shipped framing (`SnapshotCodec`), tampering
  refused. **passed**.
- Suite: **13 tests, 0 failures** (11 existing + 2 new); `** TEST SUCCEEDED **`.
  Each test removes only its own unique account afterwards. No existing account,
  key or simulator was touched. The package-level host case stays an explicit
  `XCTSkip` that names this simulator case; the adapter types are internal to
  the package, so the bundle exercises the public `OwnerKeychainKey` and the
  shipped codec, while `OwnerAppleCryptography` itself runs in the package tests.

Rerun on the corrected code head `3c8cbab`: `KeychainStoreTests` **13 tests,
0 failures**, `** TEST SUCCEEDED **` (the owner-policy case included).

Admission round: a third simulator case,
`testALegacyMessagingItemUnderTheOwnerAccountIsRefusedNotUsedOrDeleted`,
creates a legacy `KeychainKey` item (`AfterFirstUnlockThisDeviceOnly`) under a
fresh owner-test account and shows that `OwnerKeychainKey(account:)` reports
it present, reads its weaker policy back, refuses `load()` with
`StorageError.keychain(errSecDecode)`, refuses `create()` as a duplicate, and
leaves the legacy item intact for its own owner. Suite on the final head: see
the acceptance table above.

A simulator Keychain is not a device: on-device `.complete`/lock behaviour and
power loss remain separate physical checks.

## Final acceptance sequence on the returned head

Code head `b9854d4bd179051f2a54a2e74aa3dc44af3e03d8` (the documentation commit
that follows changes no Swift source or test; `git diff --stat b9854d4 --
clients/ios/ParanoidKit clients/ios/App` is empty). Commands as published in
the handoff, each step logged separately under the worktree's ignored
`clients/ios/out/logs/final*/`. During these runs the only uncommitted paths
were this receipt (untracked) and, from the second run on, the documentation
edits of the next commit; no Swift source or test changed.

| # | Command | Result |
| --- | --- | --- |
| 1 | `bash clients/ios/toolchain.sh bash clients/ios/bridge/check.sh` | rc 0 (44 s): lock tests 10, 123 core pins + 58 Devnet additions, clippy clean, bridge tests 2+6+6+1, upstream Devnet 10, release memory 1, three Apple type checks, C smoke PASS, notices 146 crates, rules 32 |
| 2 | `bash clients/ios/build-core.sh` | rc 0: 3 slices, arm64; `bridge/Cargo.lock` and `paranoid_core.h` unchanged |
| 3 | `webrtc_dependency.py --offline` | rc 0: "Verified WebRTC 150.7871.01: 2 slices" |
| 4 | `swift test …` with the handoff's eight-suite filter (owner native, owner stages, owner store and regressions, catalogue native, catalogue seams, catalogue store, catalogue codec) | run 1 (right after the Rust bridge compile): **130 tests, 1 skipped, 1 failure** — the pre-existing core timing case below; run 2 (idle): **130 tests, 1 skipped, 0 failures** (26 + 4 + 23 + 28 + 8 + 4 + 22 + 15) |
| 5 | `swift test …` (complete package) | three runs: **540 tests, 1 skipped, 1 failure each time** — always the same core case below; the other 538 pass in every run (523 at the base `2ed901dd` + 4 moved owner cases + 8 stage + 5 follow-up = 540). **Not reported as green.** |
| 6 | `notices.py --offline` | rc 0: 146 crates + WebRTC 150.7871.01 (1705627 B) |
| 7 | `test_notices.py` | rc 0: PASS 32 tests |
| 8 | `xcodebuild … -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath clients/ios/out/derived-data CODE_SIGNING_ALLOWED=NO build` | rc 0: `** BUILD SUCCEEDED **`, 0 error lines; unsigned `ParanoID.app` binary SHA-256 `2a9b840a3430f0de…`; no signing/team flags, no device, no installation |

### Core finding, reported not repaired: a timing test of the portable core flakes on this Mac

`OwnerStoreRegressionTests.testExternalWaitIsBoundedAndCancellationDoesNotDependOnVerifierCooperation`
(`OwnerStoreRegressionTests.swift:306`, PR #84 core, unchanged here) fails
intermittently with `caller must finish without waiting for verifier: deadline`.
Its "deadline" branch starts an operation with a 1 s deadline, sleeps until
50 ms past it and asserts the awaiting caller has already finished. On this Mac
the MainActor deadline timer frequently lands later than that 50 ms margin:
observed fail/pass/fail in three isolated runs, fail in 3 of 3 complete-package
runs, pass in 1 of 2 focused runs. It drives the portable `OwnerFixture`
doubles, not the Apple adapters, and it passed 109/0 on the coordinator's Linux
hosts. The adapter branch does not touch it; widening the margin or waiting on
the task rather than a fixed sleep is a core change for the coordinator. Every
other package test passed in every run.

## Limitations and what this is not

- Host execution: iOS Data Protection `.complete` is compiled under
  `#if os(iOS)` and read back only there; the host run proves the invocation
  order and the backup flag. The simulator run proves Keychain attributes, not
  on-device lock/unlock behaviour or power loss.
- No app startup, install marker, runtime, RPC, sponsor, server, phone,
  Android, Rust/core/ABI or dependency change. No existing data migrated.
- Core assumptions unchanged: one exclusive serialized non-reentrant caller per
  root/key namespace; trusted backends; a lost final-sync acknowledgement can
  leave a pair a later instance opens while the failed writer stays broken;
  no anti-rollback claim. The eight-entry ledger cap stays a component proposal.
- `fullSync` reuses the shipped `open(O_RDONLY)` without `O_NOFOLLOW` on paths
  the transaction itself just inspected or created (existing contract).
- Independent review of this adapter, integration into
  `feat/ios-owner-store-20261014`, #73 authenticated scope evidence, ADR
  acceptance, MR gates and every live action remain separate. Nothing was
  merged, installed or deployed.
