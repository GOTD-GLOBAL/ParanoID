---
status: draft
owner: ios
last_reviewed: 2026-10-13
---

# Isolated catalogue transaction-core execution checkpoint

**Partial component delivery, not a native durable-store delivery.**
The real production `CatalogueStore` orchestration is implemented and executed.
The narrow Apple crypto/filesystem adapter is **not implemented or tested**.
Its first native tests are staged separately so the Mac can continue actual
RED/GREEN rather than inherit unexercised adapter code. No app call site,
allocation, login, real data or Keychain operation is added.

Base: `ea93dafe3834ddb57986c55a11fc50294a5b18f4`; isolated branch
`feat/ios-catalogue-store-20261013`. PR #81's worktree/head were not edited.
The parent-owned [base Mac receipt](native-mac-receipts.md) includes the human
report at [comment 6155112817](https://github.com/GOTD-GLOBAL/ParanoID/pull/81#issuecomment-6155112817).
That receipt is **base codec only**, not new-store evidence; no unchanged-base
native rerun was requested or performed here.

## Scope and contracts

- [RFC-0030](../../../rfcs/0030-ios-identity-v3.md) / draft
  [ADR-0017](../../../decisions/0017-ios-concurrent-identity-v3.md), agreed
  technical basis, not formal acceptance; #73 permanent scope evidence remains
  incomplete. This is an unmerged, non-adopted local synthetic-data proposal.
- REQ-CLIENT-001 / REQ-MULTI-001 and MR-02/06/07/14: context, continuity,
  preservation and public-metadata boundaries, **not complete MR acceptance**.
- The [first-store clarification](../../../clients/ios/concurrent-realms-design.md#proposed-isolated-first-store-contract)
  was written before source. Existing schema and historical preflight stay
  intact. The [threat delta](../../../security/ios-identity-v3-threats.md)
  distinguishes tested orchestration from unimplemented native controls.
- Required caller input: existing isolated directory, trusted installID,
  ownerRef and full fi/ru descriptors, explicit opaque-key and file backends.
  No default container/account, no mkdir on load, no delete-key/temp-repair API.
- Reused today: `IdentityCatalogue`, `IdentityCatalogueCodec.encode/decode`.
  Native reuse checkpoint: `WrappingKeyStore.load/create`, `RetainedKey.exists`,
  `SnapshotCodec.seal` and framing constants, CryptoKit AES-GCM raw opening,
  `DataProtectionFileSystem` protection/backup/full-sync/rename operations.
  Existing production storage files and codec behavior are unchanged.

## Actual execution

Swift `6.3.3`, target `x86_64-unknown-linux-gnu`. A **scratch-only** SwiftPM
manifest compiled the actual production codec/store and existing-target XCTest
sources. No repository manifest, package target, dependency, lock or CI edit.
Only owned source/test targets use `.swiftLanguageMode(.v6)`,
`-strict-concurrency=complete`, `-warnings-as-errors`; generated SwiftPM discovery
keeps package Swift 5 mode rather than receiving a global Swift 6 override.

| Run | Actual result |
| --- | --- |
| Final debug | 23 store + 28 codec = 51 XCTest methods, 0 failures; exit 0 |
| Final release | Same 51 methods, 0 failures; exit 0 |
| Fresh commit fault matrix | 35 boundaries, before/after-effect = 70 cases |
| Retained commit fault matrix | 36 boundaries, before/after-effect = 72 cases |
| Native adapter/full package/Xcode for new store | NOT RUN; adapter not implemented |
| Native Keychain/device/power-loss | NOT RUN, outside this checkpoint |

The matrix drives the **same production transaction code**, not a copied store.
Opaque integer-key/token backends deliberately do **not** encrypt. Full paths
are traced, including all named owner/fi/ru paths on an admissible inspection;
a surviving ancestor refuses before descent. No source assertion, missing SDK,
syntax check or synthetic box is claimed as native evidence.

Nine runtime RED/GREEN rounds were observed. Some additional regression tests
passed immediately against already implemented behavior; they are not counted
as new RED rounds. The one test-callback compile error was corrected before
observing its runtime RED and is **not** RED evidence.

| Scratch stage | RED result | Following GREEN full suite |
| --- | --- | --- |
| 01 intent-parent-sync | 1 method / 3 failures | 29 / 0 |
| 02 commit/reopen ordering | 2 / 2 | 30 / 0 |
| 03 authority/latch/key reuse | 5 / 12 | 33 / 0 |
| 04 inspection/continuity | 10 / 133 | 38 / 0 |
| 05 context/retained parsing | 12 / 44 | 40 / 0 |
| 06 exact key/readback | 15 / 15 | 43 / 0 |
| 07 framed write cap | 17 / 1; strengthened focused 1 / 3 | 45 / 0 |
| 08 authority before effects | compile error excluded; final focused 1 / 4 | 46 / 0 |
| 09 extra regression coverage | Already GREEN; no new behavior claimed | 50 / 0 |
| 10 foreign-ancestor descent | 1 / 4 | 51 / 0 |

Counts in RED rows are executed methods and assertion/unexpected failures, not
counts of independent bugs. All exact logs, commands and source hashes remain
in isolated scratch stages. No fabricated console results were substituted.

## Exact local replay

Scratch root (new unique path; earlier catalogue/devnet artifacts untouched):

```text
/home/codex/.hermes/profiles/paranoid/cache/scratch/catalogue-store-7b08bcda-4562-4e96-bd21-e1a47eeb8717
```

Each stage contains read-only source copies, its temporary `Package.swift`,
`execution.log` and `receipt.json` with exact command, exit and SHA-256 values.
`run.py` refuses to reuse a stage directory. Scratch is ephemeral; preserve it
before pruning if full historical RED replay is required.

```sh
S=/home/codex/.hermes/profiles/paranoid/cache/scratch/catalogue-store-7b08bcda-4562-4e96-bd21-e1a47eeb8717
SWIFT=/home/codex/.hermes/profiles/paranoid/cache/scratch/swift-6.3.3-host/toolchain/usr/bin/swift
"$SWIFT" test --package-path "$S/final-debug"
"$SWIFT" test --package-path "$S/final-release" -c release
# To copy the current worktree into a new, immutable-source replay stage:
python3 "$S/run.py" parent-replay-debug
python3 "$S/run.py" parent-replay-release -c release
```

Both final receipts bind these exact files:

| Source | SHA-256 |
| --- | --- |
| `IdentityCatalogue.swift` | `b07cfc66b50041ce083fae47c26383aa615db57b0417dcb87e99897cbaceb30e` |
| `CatalogueStore.swift` | `4a5abcb975244dd346a483d646952919e76a9e89040e2b70e40e6b73a4013adb` |
| `IdentityCatalogueTests.swift` | `059b8d02c4d801bc59feb08d7924850a3aea60c522c30a2b4e5caa90674f4421` |
| `CatalogueStoreTests.swift` | `9226d7fb066beb6c78cf0d287826b0dfc66ed9a60ec9b72fd60e9f3692b00a5a` |

## Concrete native-first checkpoint — still NOT RUN

[Four native XCTest cases](../../../../clients/ios/ParanoidKit/Tests/NativeFirstTests/CatalogueNativeAdapterTests.swift)
are staged **outside** `Tests/ParanoidKitTests` deliberately. They reference the
proposed `CatalogueAppleFileIO` and `CatalogueAppleCryptography` adapter names,
which do not exist yet. They are neither discovered nor counted in the 51 tests,
and must not be presented as compiled, skipped or passed.

On the native implementation branch, put these cases into the existing target.
Begin with the minimum compilable adapter signatures; observe the real
`testRealCommitReopenBackupFlagAndOldReaderRefusal` failing for missing behavior,
then implement the thin adapters and repeat RED/GREEN for the other cases.
An unresolved symbol/missing SDK is a setup failure, **not** the required RED.
The intended native command, after that setup, is:

```sh
swift test --package-path clients/ios/ParanoidKit --filter CatalogueNativeAdapterTests
```

The source fixture uses only distinct temporary roots and injected in-memory
`SymmetricKey` backends. It never instantiates `KeychainKey`, uses a live account,
or deletes retained device keys. Fixture teardown removes only its own root.
Coverage staged: real sealed commit/reopen and backup flag; v4-reader refusal
of v5; authenticated-invalid-UTF-8 raw opening versus unchanged legacy repair;
v4 bytes preserved; exclusive writes, symlink/ENOTDIR refusal and framed caps.
Before claiming the native adapter complete, also add/run its interrupted/short
write, growing-read, permission/protection failure and file-type tests.

Adapter constraints for that continuation:

1. Explicit `catalogue: WrappingKeyStore`, plus `owner/fi/ru: RetainedKey`
   inputs; opaque `SymmetricKey`, no default Keychain/account and no key export.
2. Derive overhead from `SnapshotCodec.headerBytes + SnapshotCodec.tagBytes`.
   Seal with the existing codec/primitive; raw authenticated open feeds the
   strict catalogue codec, not the legacy lossy String opener.
3. Use throwing no-follow inspection, exclusive creation and bounded descriptor
   reads. Existing `fileExists` is not error-aware; existing whole `read` has a
   stat/read growth window. Do not silently inherit those weak semantics.
4. Reuse existing Data Protection/backup and Darwin full-sync/rename operations
   where they meet the contract. No fallback from `F_FULLFSYNC` to weaker sync
   just to obtain a green test. Do not edit existing production files casually.
5. Repeat new-head component and native full-package checks; the base receipt
   cannot close this gate. No app startup/device/Keychain/live action follows.

## Other local checks

`git diff --cached --check` passed. An offline check of all three changed
Markdown files found 26 existing local link targets and no unbalanced code
fences, trailing whitespace or missing final newlines. Added-lines security
regex checks found no embedded credentials, shell/eval or unsafe-deserialization
patterns. These small checks are not a human security review or full Markdown
lint. `markdownlint-cli2`, `lychee`, SwiftLint and Semgrep were not available;
no install/download or external-link/CI/ruleset check was performed. The local
checker and exact output are `check_docs.py` / `offline-checks.log` in scratch.

## Review, residuals and scope postflight

Self-review and local tests are not independent review. A parent/fresh reviewer
still needs to examine this exact source before adoption; no independent-review
or merge gate is claimed closed. Native adapter inability is a real blocker to
calling this the full requested storage component, not a hidden follow-up.

Preserved residuals: caller-trusted fresh classification and context; one
exclusive serialized/non-reentrant owner; no cross-process arbitration;
no rollback/total-evidence-loss detection; removal/final-sync ambiguity may be
invisible after restart; no owner/realm allocation, real entropy, migration,
recovery, app startup or real storage adoption.

Scope: new core, existing-target unit tests, staged native-first tests, narrow
proposed design/threat delta and this receipt only. No legacy source, AppModel,
install.v1, shared Rust/C ABI, server/Android, package/lock/pin/CI changes. Parent
edits to current-state, iOS README and native-mac-receipts are intentional and
must not be staged in this component commit. The implementer performed no
push, PR, merge or publication.

## Parent verification and native execution assignment

The parent inspected the production core, active and staged native tests,
replay script and proposed contract. Independent review of exact source
`98d97efb6be478f1f9ea6b649b0de2159099d1f9` is running; no verdict is claimed yet.
Its production/test hashes were checked against the immutable replay receipts.

Actual parent replays (same scratch root as above):

- `parent-verified-debug-e067f438c2564309a2e63c3d99488a15`: exit 0,
  23 store + 28 codec = 51 individually passed tests; 142 fault cases.
- `parent-verified-release-3f8a82e33e3e4e1fb39355e45b1c77ac`: exit 0,
  the same 51 individually passed tests and 142 fault cases.

The core, tests and codec bytes in those receipts match the committed source.
No staged native adapter test was included in either passing run.

Yaroslav selected this bounded execution arrangement in the current task:
**his Mac agent implements the Apple adapter against the native tests; the
coordinator performs review and integration.** This is not a permanent authority
delegation, ADR acceptance or main-merge/server/phone permission. Use a separate
feature branch from the published checkpoint, preserve existing worktrees and
all real accounts/keys, activate the staged tests in the existing package target,
observe runtime RED after minimum compilable signatures, and implement one
behavior at a time. Do not count missing types/SDKs or zero discovered tests as
RED/GREEN. Complete the native-specific fault tests listed above, then the
normal full-package/notices/unsigned-build sequence. Record actual model/source
provenance and test outputs, return a commit/branch for review, and do not merge
into main or change an existing installation.
