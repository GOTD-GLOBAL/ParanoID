---
status: draft
owner: ios
last_reviewed: 2026-10-14
---

# Apple catalogue adapter: native RED/GREEN receipt

**Component delivery on the build Mac, not a durable-store, app or phone
result.** The narrow Apple file/crypto adapter that the
[transaction-core checkpoint](catalogue-store.md) left unimplemented now exists
(`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/CatalogueAppleAdapters.swift`)
and is exercised by the four staged native cases, moved into the active
`ParanoidKitTests` target, plus twenty-one native-seam cases. `CatalogueStore`,
`IdentityCatalogue`, the legacy `SnapshotStore`/`SnapshotCodec`/`StorageGuard`/
`InstallMarker`/`KeychainKey`, the package manifest, pins, the application,
the Rust bridge and every other component are unchanged.

Base: `a19a980976d0c4e410696423028e31c385df5e73` (PR #82 checkpoint); branch
`feat/ios-catalogue-apple-adapter-20261013`, worktree
`../paranoid-ios-catalogue-apple`, created without touching other worktrees,
simulators or keys. Host: macOS (Darwin 27.0.0), Xcode 26.6 (17F113), iOS SDK
26.5, Swift 6.3.3, Rust 1.98.1, pinned WebRTC 150.7871.01 from the verified
cached archive. Implementer: Yaroslav's Mac agent (Claude Fable 5.1 through
Claude Code), per the execution split recorded in the checkpoint.

## What the adapter does

`CatalogueAppleFileIO(fileSystem:)` (no default argument):

- `inspect`: `lstat(2)`, never following a link; only `ENOENT` is `.absent`,
  `ENOTDIR`, `EACCES` and every other error throw; regular file, directory
  and everything else (`.other`: link, FIFO, device) are distinguished.
- `writeExclusive`: `open(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)`;
  an existing name of any kind is refused (`EEXIST`), never truncated; the
  write loop completes short writes and retries `EINTR`; a zero-length write
  fails with `EIO`; errors leave whatever reached the inode as evidence (no
  unlink); a failing `close` is reported.
- `protectAndExclude`: Data Protection class `completeUntilFirstUserAuthentication`
  (compiled for iOS only; the macOS host has no such attribute), then the
  shipped backup exclusion, read back on the inode before the rename.
- `fullSync` / `rename`: the shipped `fcntl(F_FULLFSYNC)` and `rename(2)` steps
  of `DataProtectionFileSystem`, including their inode-type check; no fallback.
- `read`: no-follow inspection first (so a FIFO is refused before any `open`
  could block), regular file required, `open(O_RDONLY|O_NOFOLLOW|O_CLOEXEC)`,
  `fstat` must show the same device/inode and a regular file, size above the
  limit refused before allocation, then a descriptor read loop into at most
  `maximumBytes + 1` bytes with `EINTR` retry; more than `maximumBytes` bytes
  (including growth under the reader) is refused with `EFBIG`.
- `removeIntent`: `unlink(2)` only when the no-follow inspection shows a
  regular file; a missing marker is an error, not a no-op.

`CatalogueAppleCryptography(catalogue:owner:fi:ru:)` (explicit backends only):

- `framingOverhead` = `SnapshotCodec.headerBytes + SnapshotCodec.tagBytes` = 29.
- `loadKey`/`createKey` delegate to the injected `WrappingKeyStore` (create-only
  by that backend's contract); `foreignKeyExists` maps `owner`/`fi`/`ru` to
  their own `RetainedKey`.
- `seal`: exact-UTF-8 check by re-encoding, then `SnapshotCodec.seal`, so the
  bytes are the shipped `[0x01][nonce][ciphertext‖tag]` layout.
- `open`: version/length checks and raw `AES.GCM.open` with the version byte as
  associated data; the result is the stored bytes, never the lossy String of
  `SnapshotCodec.open`.
- No key export, no byte comparison of keys, no deletion.

`CatalogueAppleAdapterError` names the operation and the POSIX/Foundation code
only. A POSIX seam (`CatalogueAppleSyscalls`, internal) lets tests inject
faults; production uses `.darwin`.

## RED/GREEN record (Mac host, real temporary roots, real CryptoKit)

Logs are kept under the worktree's ignored `clients/ios/out/logs/tdd/`.
Snapshot hashes are SHA-256 of `CatalogueAppleAdapters.swift`.

| Step | Source snapshot | Command / result |
| --- | --- | --- |
| RED, case 1 | stub adapters `68f5a663…eebb3`, commit `5c9292d` | `swift test --filter CatalogueNativeAdapterTests.testRealCommitReopenBackupFlagAndOldReaderRefusal` → **Executed 1 test, with 1 failure**: `caught error: "backendFailure"` (every stub throws `ENOSYS`); exit 1 |
| GREEN, case 1 | real adapters `d10a43e7…94e1e`, commit `9a28a16` | same filter → **1 test, 0 failures**; exit 0 |
| case 2 first run | same | `testAuthenticatedInvalidUTF8RemainsRawInsteadOfLegacyRepair` → 1/0 on first run: regression coverage, no RED manufactured |
| case 3 first run | same | `testNativeV4BytesAreNeverMigratedOrOverwritten` → 1/0 on first run |
| case 4 first run | same | `testNativeInspectionExclusiveWriteAndBoundedRead` → 1/0 on first run |
| suite | same | `CatalogueNativeAdapterTests` 4/0; `CatalogueStoreTests` 23/0; `IdentityCatalogueTests` 28/0 |
| seams first run | same + `CatalogueAppleFileIOTests.swift`, commit `943c4a8` | `CatalogueAppleFileIOTests` → **21/0 on first run**: regression coverage |
| mutation probe A | adapters with the `EINTR` retry removed from `writeExclusive` (not committed) | `testShortAndInterruptedWritesAreCompletedNotTruncated` → 1 test, **1 failure**; source restored to `d10a43e7…` |
| mutation probe B | adapters with the post-read growth guard removed (not committed) | `testFileGrowingPastTheLimitDuringReadIsRefused` → 1 test, **1 failure**; source restored |

The compile fix between the stubs and GREEN was Swift 6 strict concurrency
(`CatalogueAppleSyscalls` had to be `Sendable`); it is not RED evidence.

Native-seam coverage (21 cases): lstat kinds including FIFO and dangling link;
unreadable parent → `EACCES`, not absence; exclusive creation refuses an
existing link and keeps its target, empty file, mode `0600`; bounded read
refuses directory, FIFO (before any open), missing (`ENOENT`) and unreadable
(`EACCES`) files, accepts exactly the limit, refuses one byte more (`EFBIG`);
intent removal only unlinks a regular file; backup flag read back; full-sync and
rename inode mismatches; seal/open raw round trip equal to the old reader's
text, non-UTF-8 plaintext refused (`EILSEQ`); wrong key, tampered tag, short
and wrong-version boxes refused; foreign-key slots map to their own backends;
create-only keys. **FIXTURE-ONLY** (injected POSIX seam, labelled in the test
source): short-then-`EINTR` write completes; zero-length write → `EIO` and the
inode is kept; `ENOSPC` after two bytes keeps the two bytes; growth past the
limit under the reader → `EFBIG`; `EINTR` on read retried. Permission cases
skip when running as root (never the case here).

## Final acceptance sequence on the returned head

Commands as published in PR #82; each run separately, stop on first failure:

Run on code head `943c4a8f0a5230465cef517bbfbbec03bd4673e6` (the documentation
commit that follows changes no Swift source or test); logs under the ignored
`clients/ios/out/logs/final/`; worktree clean before and after.

| # | Command | Result |
| --- | --- | --- |
| 1 | `swift test … --filter CatalogueNativeAdapterTests` | 4 tests, 0 failures |
| 2 | `swift test … --filter CatalogueAppleFileIOTests` | 21 tests, 0 failures |
| 3 | `swift test … --filter CatalogueStoreTests` | 23 tests, 0 failures (unchanged core) |
| 4 | `swift test … --filter IdentityCatalogueTests` | 28 tests, 0 failures (unchanged codec) |
| 5 | `swift test …` (complete package) | **486 tests, 0 failures, 0 skipped** (461 at `a19a980` + 4 + 21); no compiler warnings in the log |
| 6 | `python3 clients/ios/notices.py --offline` | 146 crates + WebRTC 150.7871.01 (1705627 B) |
| 7 | `python3 clients/ios/test_notices.py` | PASS: 32 tests |
| 8 | `xcodebuild build … -configuration Release -destination 'generic/platform=iOS' -derivedDataPath clients/ios/out/DerivedData-catalogue-store CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **`, 0 error lines; unsigned `ParanoID.app` binary SHA-256 `213e8ec81f007afa…` (no signing/team flags, no device, no installation) |

`bash clients/ios/build-core.sh` and `webrtc_dependency.py --offline` ran once at
worktree setup (3 slices, "Verified WebRTC 150.7871.01: 2 slices"). The
known-blocked full wrapper (gate 11, issue #37) and the separate QR gate were
not rerun, as the task states.

## Limitations and what this is not

- Host execution on macOS: the iOS Data Protection attribute is compiled under
  `#if os(iOS)` and **not executed** here; backup exclusion is. No simulator,
  device, real Keychain (`KeychainKey`), power loss, process restart, Welcome
  classification, owner/realm stores, recovery, login or application startup
  was exercised. The unsigned iOS build only proves the package compiles for
  the device target.
- The transaction still relies on the core's documented assumptions: one
  exclusive, serialized, non-reentrant caller per root/key namespace; no
  multiprocess or adversarial concurrent mutation; trusted backends.
- A failure between `rename` and the final directory sync, or a lost
  acknowledgement, remains undetectable to a later instance (unchanged from the
  checkpoint); there is no anti-rollback claim.
- `fullSync` reuses the shipped `open(O_RDONLY)` without `O_NOFOLLOW`; the
  transaction only syncs paths it has just inspected or created, so this is the
  existing production contract, not a new one.
- Independent review of this adapter, integration into the feature branch,
  #73 authenticated scope evidence, ADR acceptance, MR gates and every live
  action remain separate. Nothing was merged, installed or deployed.
