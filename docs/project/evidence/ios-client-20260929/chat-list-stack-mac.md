---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for «Чаты» on the integrated stack

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is the exact head the coordinator published for
PR #64 after the stack integration:
`53866c838eff2d5374ce078f3cdda1d6a65ddd31`, a two-parent merge of `78f9d53`
(this PR's earlier head) and `dea6829` (PR #63, the base branch). The earlier
[receipt](chat-list-mac.md) describes `987d086` alone and does not cover this
tree. The pull request records the SHA of the commit that adds this file,
which changes Markdown only. The checkout was clean before and after every
run below: no tracked file carried an uncommitted change. The environment:

- Xcode 26.6 (17F113) and Apple Swift 6.3.3;
- Rust 1.98.1 through `clients/ios/toolchain.sh`; the core bridge was rebuilt
  from this checkout by `build-core.sh` and the notices by
  `notices.py --offline` before the runs;
- fresh derived data for this head: the unsigned tests, the signed Keychain
  run and the device build each started from an empty directory;
- the iPhone 17 Pro simulator on iOS 26.5;
- the local stand from `clients/ios/local_stand.py`, running the prebuilt
  macOS `paranoid-server` from 2026-09-13 (SHA-256 prefix `a4a65d123ee06f6e`).
  The server does not build on macOS, and this stack does not touch it.

## GREEN on the integrated head

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 370 tests, 0 failures; `DialogOrderTests` 5/0 |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 106 tests, 0 failures, among them `ChatListTests` 3/0 and PR #63's `CallScreenLifeTests` 12/0; ParanoIDUITests 4, 3 skipped by design (they need the stand harnesses), 0 failures |
| `KeychainStoreTests`, separate run with the default simulator signature | 11 tests, 0 failures |
| `test_sim_text.py --scenario text` | PASS: 17 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap; the contact row is found and tapped through its button |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| The 17 Python gates of `ios-static` | all passed; `test_ui_contract.py` 26 tests OK; `test_call_controller_parity.py` 105/105 labels; `test_component_boundary.py --base origin/feat/ios-call-screen-20260928`: 15 files changed, 0 outside the allowlist |

## Mutation checks

The five mutations of the earlier receipt, on this head. Each was applied,
run and reverted from a copy, and the checkout was clean afterwards.

| Mutation | What turned RED |
| --- | --- |
| No sort (`orderedDialogs` returns the core's order) | `ChatListTests`: 3 of 3 failed; `test_ui_contract.py`: `DialogOrder.byRecency(view.dialogs)` is missing. |
| Oldest first (the comparison reversed) | `DialogOrderTests`: 3 of 5 failed; `ChatListTests`: 3 of 3 failed. |
| Untimed conversations first | `DialogOrderTests`: «untimed conversations follow in the core's order» failed. |
| A missed call not red (`isMissedCallPreview` always false) | `ChatListTests`: the missed-call test failed; `test_ui_contract.py`: the rule is missing. |
| No pressed look (the style's background dropped) | `test_ui_contract.py`: `Screens/RowButton.swift: missing 'configuration.isPressed …'`. |

## What is not run

- A physical iPhone: `NOT RUN`.
- A signed or exported build: `NOT RUN`.
- PR #63's own ten mutations were not repeated on this head; its unchanged
  head `dea6829` keeps its own [receipt](../ios-client-20260928/call-screen-mac.md),
  and `CallScreenLifeTests` ran green here. They are repeated on the top of
  the stack (PR #59).
- PR #60 is not part of this tree. A later merge of it needs its own run.
