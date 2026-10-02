---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the iOS chat list by recency

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is `987d086` on `feat/ios-chat-list-20260929`;
the pull request records the SHA of the commit that adds this file, which
changes Markdown only. During the run the only tracked file with uncommitted
changes was `docs/clients/ios/verification.md` (the row for this receipt);
every Swift and Python source was that commit's. The environment:

- Xcode 26.6 and Apple Swift 6.3.3;
- Rust 1.98.1 through `clients/ios/toolchain.sh`; the core bridge was rebuilt
  from this tree by `build-core.sh` before the runs;
- the iPhone 17 Pro simulator on iOS 26.5;
- the local stand from `clients/ios/local_stand.py`, running the prebuilt macOS
  `paranoid-server` from 2026-09-13. The server does not build on macOS, and
  this change does not touch it.

## RED before the change

| Check | Result |
| --- | --- |
| `DialogOrderTests` and `ChatListTests` on `main` | Do not compile: `DialogOrder`, `AppModel.orderedDialogs` and `isMissedCallPreview` do not exist there. The behavioural RED is the mutation table below, one rule at a time. |
| `test_ui_contract.py` with the new check on `main` | 25 tests: the new check errors at once (`Screens/RowButton.swift` does not exist). |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 370 tests, 0 failures (365 on `main` plus `DialogOrderTests` 5) |
| `DialogOrderTests`: newest first, untimed after in the core's order, equal times stable, only the last message counts, nothing to sort | 5 tests, 0 failures |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 94 tests, 0 failures (91 on `main` plus `ChatListTests` 3); ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `ChatListTests`: a production `AppModel` over a real registered client with three verified contacts; real sends through the core order the list, an empty conversation stands last, a missed call is the red preview and moves nothing, an answered call is not red, a message after the call takes the preview back; equal stamps keep the core's order and an unstamped message sorts with the empty conversations (the client stamps with an injected clock) | 3 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 25 tests, OK |
| iOS static Python gates and `test_component_boundary.py --base origin/main` | all 17 passed; `test_component_boundary.py`: 0 files outside the allowlist |
| `test_sim_text.py --scenario text` (the UI test finds and taps the contact row by `dialog-<account>`, now the button) | PASS: 17 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| `test_docs_consistency.py`, `markdownlint-cli2` on the changed documents | PASS; no findings in the changed files |

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| No sort (`orderedDialogs` returns the core's order) | `ChatListTests`: the order assertions failed; `test_ui_contract.py`: `DialogOrder.byRecency(view.dialogs)` is missing. |
| Oldest first (the comparison reversed) | `DialogOrderTests`: 3 of 5 failed; `ChatListTests`: the order assertions failed. |
| Untimed conversations first | `DialogOrderTests`: «untimed conversations follow in the core's order» failed. |
| A missed call not red (`isMissedCallPreview` always false) | `ChatListTests`: the red assertions failed; `test_ui_contract.py`: the rule is missing. |
| No pressed look (the style's background dropped) | `test_ui_contract.py`: `Screens/RowButton.swift: missing 'configuration.isPressed …'`. |

## What is not run

- A physical iPhone: `NOT RUN`.
- The pressed look of a row is not driven by a UI test; the contract checks
  the style, and the simulator text flow taps the row through the button.
