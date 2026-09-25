---
status: draft
owner: ios
last_reviewed: 2026-09-26
---

# Contributor Mac receipt for the iOS new-message marks

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-26. The contributor ran them,
not a coordinator. The tree is the commit that adds this file on
`feat/ios-unread-markers-20260925`; the pull request records its exact SHA.
The environment:

- Xcode 26.6 and Apple Swift 6.3.3;
- Rust 1.98.1 through `clients/ios/toolchain.sh`;
- the iPhone 17 Pro simulator on iOS 26.5;
- the local stand from `clients/ios/local_stand.py`, running the prebuilt macOS
  `paranoid-server` from 2026-09-13. The server does not build on macOS, and
  this change does not touch it.

## RED before the change

| Check | Result |
| --- | --- |
| `SeenMarksTests` against a stub that counts nothing | 10 tests, 10 failed (16 assertion failures). Every test pairs a zero with a positive case. |
| The new `test_ui_contract.py` check, run on an `origin/main` tree with only the new test file | Failed: `SeenMarks.swift is missing`. |
| `test_sim_text.py --scenario text`, first run of the new steps | Failed. The baseline was read through `ClientView.read`, and `contactText()` throws before registration, so the marks were off for the whole run on a fresh install. Fixed by reading `publicDialogs()`. |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 375 tests, 0 failures (365 on `main` plus `SeenMarksTests` 10) |
| `UnreadTimelineTests` | 7 tests, 0 failures |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 98 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 25 tests, OK |
| iOS static Python gates and `test_component_boundary.py --base origin/main` | all passed |
| `test_sim_text.py --scenario text` | PASS |

The new simulator steps:

- **16.** A peer message that arrives while the chat is open at its bottom is
  not counted: back in «Чаты» the row shows no count.
- **17.** Twelve peer messages arrive while «Чаты» is on the screen, which is
  more than one screen of history. The row shows «12 новых сообщений».
- **18.** Opening the chat shows the «Новые сообщения» divider on the screen,
  with the newest message below it and «↓ 12» displayed. «↓» leads to the
  newest message.
- **19a.** With the history scrolled up, the next peer message leaves the view
  where it was and brings up «↓ 1»; «↓» leads to it.
- **19.** Leaving after the bottom was on the screen clears the count.

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| No divider row inserted in `AppModel.timeline` | `UnreadTimelineTests`: 5 of 7 failed. The two wording tests stayed green. |
| A message counts as seen only at the first positioning, not on every change | Simulator step 16: «a message read in the open chat is still counted … 2 новых сообщения» |
| The scroll view is never asked: "at the bottom" is always true | Simulator step 18: «↓ is missing below unread messages» (the chat opened at the divider was taken as read at once) |

## Approaches that failed on the simulator

Two ways of telling that the bottom is on the screen were tried and failed on
the simulator:

- the appearance and disappearance of a marker row;
- the marker's measured frame.

A lazy stack keeps rows it has built after they scroll away and does not
re-measure them. The first way therefore stayed "at the bottom" after
scrolling up. The second reported the marker 38 points below the edge while
it was five messages below. The shipped rule asks the scroll view for its own
offset on iOS 18 and later. On iOS 17 it falls back to the marker's
appearance, which is an approximation and was not run.

## Observed, not part of this change

A long chat that had been fully read and was then reopened was once shown
scrolled up by several messages rather than at its very end. The chat uses the
same `.defaultScrollAnchor(.bottom)` over a `LazyVStack` as `main`, so this is
probably pre-existing. It was not checked on `main`, and the flow no longer
depends on it.

## NOT RUN

- a physical iPhone;
- the iOS 17 path;
- spoken VoiceOver;
- a signed or exported build;
- Android.
