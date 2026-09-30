---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the chat composer on the integrated stack

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is the exact head the coordinator published for
PR #65 after the stack integration:
`6d197cfb0ed416feec5512d2feb7e396fc79dba1`, a two-parent merge of `37e8b5d`
(this PR's earlier head) and `e43cc96` (PR #66's integrated head, the base
branch). The earlier [receipt](chat-composer-mac.md) describes `eaa9ee2` alone
and does not cover this tree. The pull request records the SHA of the commit
that adds this file, which changes Markdown only. The checkout was clean
before and after every run below. The environment:

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
| `swift test --package-path ParanoidKit` | 379 tests, 0 failures; `PresentationTests` 16/0 |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 109 tests, 0 failures; ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `KeychainStoreTests`, separate run with the default simulator signature | 11 tests, 0 failures |
| `test_sim_text.py --scenario text` | PASS: 19 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap; the sent bubble measured narrower than the row (`08-sent.png`), and PR #66's paste control and blocked section in the same run |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| The 17 Python gates of `ios-static` | all passed; `test_ui_contract.py` 28 tests OK; `test_call_controller_parity.py` 105/105 labels; `test_component_boundary.py --base origin/feat/ios-contacts-20260929`: 13 files changed, 0 outside the allowlist |

## Mutation checks

The seven mutations of the earlier receipt, on this head. Each was applied,
run and reverted from a copy, and the checkout was clean afterwards.

| Mutation | What turned RED |
| --- | --- |
| The text asks for the row's width again (`.frame(maxWidth: .infinity)` put back on the bubble's text) | `test_sim_text.py`: «the bubble stretches to the row» (338 pt against a bound of 270) and the flow ended RED; `test_ui_contract.py`: the frame is back. |
| The counter always shown (`showsCounter` bypassed) | `test_ui_contract.py`: the rule is missing. |
| The limit measured on the untrimmed text | `PresentationTests`: the composer's measure test failed; `test_ui_contract.py`: the rule is missing. |
| A failed send puts the trimmed text back, not the draft | `PresentationTests`: the restore test failed; `test_ui_contract.py`: the rule is missing. |
| The keyboard no longer follows a drag (`.scrollDismissesKeyboard(.never)`) | `test_ui_contract.py`: the modifier is missing. |
| The ticket carries the draft untrimmed | `PresentationTests`: the restore test failed on `slip.text`; `test_ui_contract.py`: the rule is missing. |
| The footer placed at the leading edge (`BubbleLayout` places it at `bounds.minX`) | `test_ui_contract.py`: the trailing placement is missing. The simulator flow does not measure the footer's position. |

## What is not run

- A physical iPhone: `NOT RUN`.
- A signed or exported build: `NOT RUN`.
- The trimmed send and the restored draft together with the new-message
  markers are checked on the top of the stack (PR #59), where both are in
  one source.
- PR #60 is not part of this tree. A later merge of it needs its own run.
