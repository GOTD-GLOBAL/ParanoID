---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# Contributor Mac receipt for storage follow-up at 628958b

## Provenance

Yaroslav supplied commands, exit codes and XCTest output in the ParanoID Telegram
thread for exact `628958b83d3c7c4a28d1c196811d0c40130c5cde` (PR #40), run beginning
2026-09-14 12:59 UTC. The coordinator transcribes the participant's execution;
Apple tooling was not run by the coordinator and raw xcresult artifacts were not
independently retrieved. No stable original-message permalink was available.
This receipt is not human decision approval, ADR acceptance or merge permission.

Reported host: macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3. Git-ignored
xcframeworks were symlinked from the main checkout; ParanoidCore was built
2026-09-13 from unchanged core sources, not rebuilt by this receipt.
The signed simulator destination was
`platform=iOS Simulator,id=7BE0F7D0-54AA-4B07-8895-61FFDAA5B1DC`.
The preceding [0709212 receipt](lazy-storage-mac-0709212.md) records the fresh
simulator/ad-hoc setup, notices prerequisite and baseline RED; it is retained
separately rather than relabelled as this run.

## Results reported for 628958b

| Check | Exit / result |
| --- | --- |
| `python3 -B clients/ios/test_storage_bootstrap_contract.py` | 0; 5 tests, OK |
| `python3 -B clients/ios/test_ui_contract.py` | 0; 20 tests, OK |
| `python3 -B clients/ios/test_docs_consistency.py` | 0; 7 checks, 3 registration records |
| `python3 clients/ios/test_component_boundary.py --base origin/feat/ios-client-20260911` | 0; base d96cea1, 24 changed paths, 0 outside allowlist |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests` | 0; 14 tests, 0 failures |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter SnapshotStoreTests` | 0; 25 tests, 0 failures |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm` | 0; 278 tests, 0 failures |
| markdownlint-cli2 0.18.1 on 12 changed Markdown files | 0; 0 errors |
| Signed simulator `KeychainStoreTests` | 0; 11 tests, 0 failures; TEST SUCCEEDED |

Signed simulator command:

```sh
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,id=7BE0F7D0-54AA-4B07-8895-61FFDAA5B1DC' \
  -derivedDataPath clients/ios/out/lazy-key-signed \
  -only-testing:ParanoIDTests/KeychainStoreTests
```

The Keychain output explicitly includes passing tests for missing file/key,
missing marker preserving key/file, legacy upgrade refusal, stale pending fact,
reinstall, key attributes, Welcome without key creation, and per-commit backup
exclusion. The expanded host suite exercises fresh-instance direct commit and
new-key readback failures/order. `loadOrCreate` is no longer a production API.

## Bounded closure

The original strict regression was RED on d96cea1 (only the expected-failure
wrapper removed) and GREEN in the revised storage suite. Source review plus the
0709212 and 628958b contributor Mac receipts close the reviewed storage findings
at host/simulator scope. Readback and direct-commit follow-up tests now have their
own execution receipt, not an inherited green result.

No physical-device, real retained-container upgrade, power-loss, media-runtime,
real NWPath, archive/export or hosted validation is added by this receipt. Existing
residual costs remain: an interrupted first commit after key creation can freeze
while preserving its key; rollback/loss of both key and file is not detectable.
No server/firewall change, TestFlight, merge or ADR-0014 acceptance follows.

The commit recording this receipt changes documentation only; its runtime source
must remain identical to the tested 628958b before carrying this closure forward.
