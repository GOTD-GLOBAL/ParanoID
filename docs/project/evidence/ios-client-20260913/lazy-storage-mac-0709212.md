---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# Contributor Mac receipt for lazy storage at 0709212

## Provenance and scope

Reported by Yaroslav in the ParanoID Telegram discussion, 2026-09-14, with
commands, exit codes and test output. This document transcribes that participant
report; the coordinator did not execute Apple tools or independently fetch raw
xcresult bundles. No stable message permalink was available to the tool context.
This is test evidence, **not** a decision-owner approval or acceptance of ADR-0014.

Exact tested revision: `0709212187373fa894e402f2f138ab3cc178ee07` (PR #40).
Base: `d96cea12bca3efd88ee633f63ef51948413c2a7d` (PR #36 author branch).
Window: 2026-09-14 12:40–12:45 UTC. Separate worktree, tested commit unchanged.
Host reported: macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3.

Git-ignored xcframeworks were symlinked from the contributor's main checkout;
ParanoidCore was built 2026-09-13 from the same unchanged core sources. This is
not a fresh dependency rebuild or independent artifact-hash attestation.
The signed tests used a separate fresh iPhone 17 Pro simulator on iOS 26.5,
not simulators holding existing test accounts. Signature: ad hoc, without
DEVELOPMENT_TEAM. The sole compiler warning, ContactFlowError.swift:91, was
reported present on base too.

## Reported results

| Command / scope | Result |
| --- | --- |
| `python3 -B clients/ios/test_storage_bootstrap_contract.py` | exit 0, 3 tests |
| `python3 -B clients/ios/test_ui_contract.py` | exit 0, 20 tests |
| `python3 -B clients/ios/test_docs_consistency.py` | exit 0, 7 checks, 3 registration records |
| `python3 clients/ios/test_component_boundary.py --base origin/feat/ios-client-20260911` | exit 0, 23 paths, 0 outside allowlist; base resolved to d96cea1 |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests` | exit 0, 9 tests, 0 failures |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter SnapshotStoreTests` | exit 0, 25 tests, 0 failures |
| `swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm` | exit 0, 273 tests, 0 failures |
| markdownlint-cli2 0.18.1 on 11 changed Markdown files | exit 0, 0 errors |
| Signed simulator KeychainStoreTests, after generating notices | exit 0, 11 tests, 0 failures, TEST SUCCEEDED |

The reported full-package count reconciles as 266 base tests minus 27 old storage
tests plus 25 revised storage tests and 9 lazy-key tests. This describes the
actual tested revision, not the next revision's expected count.

### Preserve the failed setup attempt

The first command below exited **65**: `THIRD_PARTY_NOTICES.txt` could not be
opened. The fresh worktree lacked the git-ignored output of `notices.py --offline`.
After running `python3 clients/ios/notices.py --offline`, the contributor repeated
only this step, unchanged source, and obtained exit 0 / 11 tests passing:

```sh
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,id=7BE0F7D0-54AA-4B07-8895-61FFDAA5B1DC' \
  -derivedDataPath clients/ios/out/lazy-key-signed \
  -only-testing:ParanoIDTests/KeychainStoreTests
```

The failed setup is not erased by the successful repeat. The handoff is corrected
to include notices generation before the signed simulator step.

## Behavioral RED on base

In a disposable worktree at d96cea1, only the `XCTExpectFailure` wrapper was
removed; the expected result remained `.frozen`. Command:

```sh
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm \
  --filter SnapshotStoreTests/testTheRemainderAWithdrawalThatNeverPersistedAndAFileLostBeforeAnyLaunchSawIt
```

Reported exit **1**:

```text
XCTAssertEqual failed: ("fresh") is not equal to ("frozen")
```

The named test passed as part of the 25 storage tests on 0709212. This supplies
contributor-executed behavioral RED/GREEN in addition to the coordinator's
separately recorded Linux source-wiring RED/GREEN.

## Review and remaining gates

Yaroslav reported no source-review blocker and suggested: read back a newly
created key before sealing, remove the unused eager helper, exercise direct
commit guards without a prior failing load, and document terminal error wrapping.
The next revision addresses those items and needs its own Mac run. This receipt
must not be relabelled as execution of code written after 0709212.

NOT RUN: physical device, upgrade on a real retained container, actual power loss,
archive/export and hosted probe. No merge, ADR acceptance or live changes were
performed by the contributor in this run. The simulator does not prove a physical
Data Protection class or power-loss behavior.
