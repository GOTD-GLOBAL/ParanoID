---
status: draft
owner: ios
decision_owner: Cooldom66671
last_reviewed: 2026-10-14
---

# Owner-store Apple adapter: implementation handoff

## Objective and exact source

Implement and actually exercise the Apple backends for the isolated owner-store
component. This is **implementation plus native RED/GREEN**, not merely another
build of the unchanged app. The core source reviewed and replayed is
`1df946251b4338fef6de8edbc0b22dd56cc97858` (code `985b30b20bdf896813410262fecbeb68ec256b4b`).
The parent PR comment supplies the exact full starting SHA including its
subsequent documentation-only tail. Verify that SHA and a clean worktree before
starting; do not guess it from a short hash or silently use latest main.

Create a separate Mac worktree/feature branch from that parent SHA. Target the
resulting draft PR at `feat/ios-owner-store-20261014`, **not main**. Preserve the
reviewed source, raw TDD receipts and ordinary commit history; no squash/rebase
of the parent stack. Read AGENTS and required sources, especially:

- [Owner format and transaction contract](owner-store-format.md).
- [Core implementation/review receipt](../../project/evidence/ios-identity-v3-20261013/owner-store-core.md).
- [Threat delta](../../security/ios-identity-v3-threats.md).
- [Existing Mac workflow and known wrapper limit](identity-v3-mac-handoff.md).

The portable 109-test suite and independent reviews do **not** prove native
storage. No owner Apple adapter exists at this checkpoint. The four tests in
`clients/ios/ParanoidKit/Tests/NativeFirstTests/OwnerNativeAdapterTests.swift`
are excluded/NOT RUN; one is an explicit future real-Keychain skip. Prior #83
results apply to the catalogue adapter only, not this task.

## Scope and boundaries

Use newly created synthetic temporary directories and public Rust test vectors
only. All root/key backends remain explicit; do not use the installed app's
container or existing account/key namespaces. Do not touch app startup, install
markers, runtime, RPC, sponsor/server endpoints, existing phone state, Android,
Rust/core/ABI, dependency pins or the bootstrap codec/store/refusal tests.
No server stand, relocation, reset, deployment, enrollment/replacement, phone
installation, Apple-account/provisioning change, TestFlight, main merge or ADR
acceptance is authorized by this handoff.

Expected production changes stay in iOS storage adapters and their matching tests.
Names `OwnerAppleFileIO` and `OwnerAppleCryptography` are proposed by the staged
blueprint; minimal necessary API adjustments must preserve the reviewed contract.
Any real core/contract defect is reported to the coordinator, not hidden by
loosening a gate or silently changing the schema. Eight ledger entries remain
an isolated component proposal, not approved product policy.

## Implement with one runtime RED/GREEN behavior at a time

1. Move the native checkpoint into `Tests/ParanoidKitTests` and make its setup
   compile against minimal inert adapters. First execute
   `testRealReservationOwnerCommitAndReopenWithOwnerArtifactsPresent` and record
   a genuine runtime failure for missing behavior. SDK/linker/test-discovery
   failures are setup failures, not feature RED. Use async XCTest entrypoints if
   required by the pinned toolchain without weakening assertions.
2. Implement `OwnerFileIO` with create-only/no-follow `owner/` creation (0700),
   complete protection and backup exclusion on owner directory/intent/temp,
   attribute readback, bounded regular-file reads, full sync and rename. The
   coordinator already orders reservation, directory creation, intent/parent sync,
   key creation/readback and candidate adoption; adapters must not duplicate that
   state machine or clean up keys/files on error.
3. Implement `OwnerCryptography` with the existing version-1 AES-GCM framing,
   strict raw opening and separate opaque owner key. Owner policy is
   `WhenUnlockedThisDeviceOnly`, non-synchronizable, files `.complete`.
   Explicitly parameterize or add the owner-specific Keychain backend while
   preserving all existing messaging defaults. Merely changing account/path or
   returning a policy descriptor is not owner-policy enforcement.
4. Map only precisely identified protected-data/Keychain lock conditions to
   `OwnerBackendLock.locked`; ordinary permission/I/O errors are not absence or
   automatically retryable lock. Native exceptions must propagate into the core's
   preservation/freeze behavior. No delete/rekey/repair fallback.
5. Respect the mandatory lease handoff in the corrected blueprint: retire old
   bootstrap handles, acquire a new holder and create the coordinator's three
   concrete wrappers with the same lease/holder/root. Close before reconstructing
   a coordinator. Do not revive a retired writer merely to make a test pass.

### Required additional native cases

The staged four cases alone are not the whole acceptance target. Add meaningful
runtime tests for:

- Successful synthetic verified-recovery input → owner confirmed commit →
  catalogue binding publication → new coordinator opens the matching pair.
  This uses the explicit trusted fixture seam, not live registry verification.
- Real encrypted reopen of ownerSigned, assembled/sends and confirmed states,
  preserving exact saved bytes/counters; both fi/ru remain unallocated.
  A synthetic assembler may test structural persistence only and must never be
  described as signature-valid transaction verification.
- Confirmed owner with catalogue binding not yet published: preserve it after
  injected interruption; no automatic publication or regenerated material.
- Tampered tag, foreign key/store/context, leftover intent/temp and allocated
  missing halves refuse without modifying original evidence.
- Create-only/no-follow behavior for files and directory; short/error transfers,
  readback/protection/backup/sync failures with clearly labelled injection seams.
  A real filesystem plus injected error is not a reproduced power loss.
- Read-only owner lock can retry, but uncertainty after write begins is terminal.

Complete the two existing #83 follow-ups before general adapter reuse: checked
read-budget arithmetic/allocation bounds (including invalid/overflowing budgets),
and direct new `open` tests for nonzero-index Data, foreign AAD and upper framing
limit. Keep those changes narrow and tested; old native receipts do not cover
modified adapters. Preserve the old catalogue tests and messaging protection.

### Keychain and device evidence stay separate

Host CryptoKit/filesystem tests may use explicitly labelled in-memory opaque key
fixtures. They cannot pass the real-Keychain policy case. Replace its XCTSkip only
with actual owner-item creation and attribute readback in a freshly scoped test
namespace, including accessibility and non-synchronizable attributes. Follow the
existing ad-hoc signed-simulator test workflow; create a disposable simulator if
needed, never erase an existing simulator/account. Teardown may remove only the
new test objects created by that test, never legacy/app keys or broad namespaces.
If that fixture cannot run, report the case as skipped/NOT RUN and retain the
native-policy gap instead of passing on constants. No Apple credentials in chat.

On-device `.complete` behavior, lock/unlock lifecycle and power loss are separate
physical checks, not implied by host attributes or a signed simulator. No phone
action follows from this handoff. Logical cancellation fences caller/authority;
it does not forcibly destroy an uncooperative external verifier continuation.
Production verifier/resource-lifetime policy remains a later integration gate.

## Reproducible final Mac verification

Use a short, clean dedicated worktree and the unchanged pins in
`clients/ios/toolchain.json` (Swift 6.3.3, Xcode 26.6/17F113, iOS SDK 26.5,
Rust 1.98.1). Build through the existing wrappers. At each meaningful new code
checkpoint report the SHA; for the final run commit source first, then verify
that source remains unchanged. Write logs only under ignored `clients/ios/out/`.

The standard prerequisites and checks are, from that worktree:

```sh
set -euo pipefail
bash clients/ios/toolchain.sh bash clients/ios/bridge/check.sh
bash clients/ios/build-core.sh
bash clients/ios/toolchain.sh python3 clients/ios/webrtc_dependency.py --offline
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm \
  --filter 'OwnerNativeAdapterTests|OwnerStoreTests|OwnerStoreRegressionTests|CatalogueNativeAdapterTests|CatalogueAppleFileIOTests|CatalogueStoreTests|IdentityCatalogueTests'
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
bash clients/ios/toolchain.sh python3 clients/ios/notices.py --offline
bash clients/ios/toolchain.sh python3 clients/ios/test_notices.py
bash clients/ios/toolchain.sh xcodebuild \
  -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath clients/ios/out/derived-data CODE_SIGNING_ALLOWED=NO build
```

Do not omit notices before Xcode. Reuse the repository's documented
signed-simulator/Keychain commands for the separate real-policy fixture, not
invented signing flags. The full wrapper's known gate 11 server-build problem is
not solved or relabelled by these focused checks; do not port/redeploy a server.
Separate QR fix #79 is not automatically integrated by this task.

## Return artifact and receipt

Deliver a draft PR against the owner-store branch with exact base/code/receipt
SHAs, actual runtime RED and GREEN logs, all command exit codes, actual counts
and skips, source hashes and clean-tree checks. State author/model provenance
as reported, not a human audit. Include typed-policy/native-fault/retained-stage
coverage and every remaining NOT RUN item. An unsigned build is not a phone
installation or working identity-v3 application.

The coordinator reviews and verifies the result before any feature integration;
this task grants no automatic main merge or deployment. Do not request another
run of unchanged earlier #78/#81/#83 source. This handoff's work is the new owner
Apple backend and complete isolated catalogue/owner native path.
