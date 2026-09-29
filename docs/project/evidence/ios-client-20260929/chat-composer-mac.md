---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the iOS chat composer and bubbles

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is `eaa9ee2` on
`feat/ios-chat-composer-20260929`; the pull request records the SHA of the
commit that adds this file, which changes Markdown only. During the run the only tracked file with uncommitted
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
| `PresentationTests` on `main` | The trimming and counter tests do not compile there (`trimmed`, `bytesToSend`, `showsCounter`, `Ticket.draft` do not exist); `canSend(limit + " ")` is asserted false on `main` by its own test and true here. The behavioural RED is the mutation table below. |
| `test_ui_contract.py` with the new check on `main` | 25 tests, 1 failure: the new check fails at its first rule (`self.text = MessagePresentation.trimmed(draft)` is absent). |
| The bubble width in the simulator flow | The first mutation below: with the text's full-width frame put back, the sent bubble measures the whole row and the new step fails. |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 367 tests, 0 failures (365 on `main` plus the two new `PresentationTests` checks) |
| `PresentationTests`: the limit measured on the trimmed text, Java's trim on the ends and nothing inside, the counter from 1800 bytes, the ticket carrying the trimmed text and the draft as typed, a failed send putting the draft back | 16 tests, 0 failures |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 91 tests, 0 failures (the count on `main`: this change adds no app unit test); ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 25 tests, OK |
| iOS static Python gates and `test_component_boundary.py --base origin/main` | all 17 passed; `test_component_boundary.py`: 0 files outside the allowlist |
| `test_sim_text.py --scenario text`, with the new step after «08-sent»: the sent bubble's frame is narrower than the row's room by more than 40 points and wider than 60 | PASS: 17 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap; the sent bubble hugs «sim-text-first-message» with the time and mark at its right (`08-sent.png`) |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| `test_docs_consistency.py`, `markdownlint-cli2` on the changed documents | PASS; no findings in the changed files |

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| The text asks for the row's width again (`.frame(maxWidth: .infinity)` put back on the bubble's text) | `test_sim_text.py`: the new step failed — «the bubble stretches to the row» — and the flow ended RED; `test_ui_contract.py`: the frame is back. |
| The counter always shown (`showsCounter` bypassed) | `test_ui_contract.py`: the rule is missing. |
| The limit measured on the untrimmed text | `PresentationTests`: `canSend(limit + " ")` and the leading-newline case failed; `test_ui_contract.py`: the rule is missing. |
| A failed send puts the trimmed text back, not the draft | `PresentationTests`: the restore assertion failed («  четвёртое \n» expected); `test_ui_contract.py`: the rule is missing. |
| The keyboard no longer follows a drag (the modifier removed) | `test_ui_contract.py`: the modifier is missing. |
| The ticket carries the draft untrimmed | `PresentationTests`: `slip.text` is not «четвёртое»; `test_ui_contract.py`: the rule is missing. |
| The footer placed at the leading edge (`BubbleLayout` places it at `bounds.minX`) | `test_ui_contract.py`: the trailing placement is missing. The simulator flow does not measure the footer's position. |

## What is not run

- A physical iPhone: `NOT RUN`.
- The keyboard following a drag is not driven by a UI test; the contract
  checks the modifier.
- The counter's appearance at 1800 bytes is not driven by a UI test; the rule
  is tested in the kit and the contract checks that the screen asks it.
