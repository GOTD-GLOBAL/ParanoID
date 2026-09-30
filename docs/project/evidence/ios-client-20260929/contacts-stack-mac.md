---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the contacts on the integrated stack

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is the exact head the coordinator published for
PR #66 after the stack integration:
`e43cc9641204e73736524406a5a9c987fd249a3c`, a two-parent merge of `6ea333a`
(this PR's earlier head) and `53866c8` (PR #64's integrated head, the base
branch). The earlier [receipt](contacts-mac.md) describes `d8ce798` alone and
does not cover this tree. The pull request records the SHA of the commit that
adds this file, which changes Markdown only. The checkout was clean before
and after every run below. The environment:

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
| `swift test --package-path ParanoidKit` | 377 tests, 0 failures; `ContactOrderTests` 7/0 |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 109 tests, 0 failures, among them `ContactsListTests` 3/0, `ChatListTests` 3/0 and `CallScreenLifeTests` 12/0; ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `KeychainStoreTests`, separate run with the default simulator signature | 11 tests, 0 failures |
| `test_sim_text.py --scenario text` | PASS: 19 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap; the paste control (`04a-pasted-from-clipboard.png`), «Вы: …» on «Мой ID», the folded «Заблокированные (1)» with «Разблокировать контакт» inside (`12a-blocked-section.png`) and the fingerprints read as 64 digits off the grouped texts |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| The 17 Python gates of `ios-static` | all passed; `test_ui_contract.py` 27 tests OK; `test_call_controller_parity.py` 105/105 labels; `test_component_boundary.py --base origin/feat/ios-chat-list-20260929`: 22 files changed, 0 outside the allowlist |

## Mutation checks

The ten mutations of the earlier receipt, on this head. Each was applied,
run and reverted from a copy, and the checkout was clean afterwards.

| Mutation | What turned RED |
| --- | --- |
| No alphabetical order (`alphabetical` returns the core's order) | `ContactOrderTests`: four failed; `ContactsListTests`: the named order failed. |
| The blocked contacts left in the main list (the filter dropped) | `ContactsListTests`: the section test failed; `test_ui_contract.py`: the rule is missing. |
| The grouping drops half the digits (`prefix(32)`) | `ContactOrderTests`: «loses nothing» failed. |
| No paste control in the sheet (the control removed) | `test_sim_text.py`: «no paste control in the sheet» and the flow ended RED; `test_ui_contract.py`: the control is missing. |
| The fingerprint not decoded from the core's view | `ContactOrderTests`: the decode test failed; `ContactsListTests`: every contact's fingerprint was empty. |
| The unnamed contacts first | `ContactOrderTests`: two failed; `ContactsListTests`: the named order failed. |
| No case folding in the collation (`.caseInsensitive` dropped) | `ContactOrderTests`: the collation test failed. |
| No diacritic folding (`.diacriticInsensitive` dropped) | `ContactOrderTests`: the collation test failed. |
| No numbers by value (`.numeric` dropped) | `ContactOrderTests`: the collation test failed. |
| No Russian locale (`locale: nil`) | `ContactOrderTests`: «Latin follows Cyrillic» failed. |

## What is not run

- A physical iPhone: `NOT RUN`.
- A signed or exported build: `NOT RUN`.
- The folded section's opening is driven by the simulator flow only; no unit
  test drives the disclosure itself.
- The system's paste control on a device whose pasteboard holds no text:
  `NOT RUN`.
- PR #60 is not part of this tree. A later merge of it needs its own run.
