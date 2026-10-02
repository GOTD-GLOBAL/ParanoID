---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the top of the integrated stack

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is `f65072734ec7b4651c912ce55e01c40641db358e`
on `feat/ios-unread-markers-20260925` (PR #59, the top of the stack): the
coordinator's integrated head `2b695bb` plus one commit of test code, which
adds the two checks of the next section. `2b695bb` itself holds every change
of PRs #63, #64, #66, #65 and #59 over `main`. The earlier
[receipt](../ios-client-20260926/unread-markers-mac.md) describes `0f9d6e9`
alone and does not cover this tree. The pull request records the SHA of the
commit that adds this file; everything after `f650727` changes Markdown only.
The checkout was clean before and after every run below. The environment:

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

## The markers and the composer together

The coordinator asked for the unread divider and «↓» to be run together with
the trimmed send and the draft put back after a failure, not only as separate
feature tests. Before this receipt each was tested on its own: the trim and
the restore on `Drafts` alone (`PresentationTests`), the markers in
`UnreadTimelineTests`, `SeenMarksTests` and the simulator flow. `f650727`
adds two checks, test code only:

- `ComposerSendTests`, over the production `AppModel` with a real registered
  client and one verified contact: «  привет \n» reaches the core as
  «привет»; with the snapshot store refusing to write, the send is not
  committed, the client freezes and «  второе \n» comes back into the
  composer as typed; the reader's own messages, sent or refused, count
  nothing as new and draw no divider. An incoming message cannot be put into
  this model without a server — the client is handed to its owner as
  `sending` — so the peer's half is the next check.
- A step of the simulator text flow: the reader scrolls up a second time, the
  peer writes, and with «↓» on the screen the reader answers with blanks at
  both ends. The bubble and the peer's own core hold the trimmed text exactly
  once, the history goes down to the reply, and «↓» goes
  (`19c-reply-while-scrolled-up.png`). The harness now also refuses a peer
  history that holds the reply with its blanks.

Both check behaviour that is already on `2b695bb`; they are green there as
they are here. What they catch is the mutation table below.

## GREEN on the top of the stack

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 389 tests, 0 failures; among them `SeenMarksTests` 10/0, `PresentationTests` 16/0, `ContactOrderTests` 7/0, `DialogOrderTests` 5/0 |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 117 tests, 0 failures; among them `ComposerSendTests` 1/0, `UnreadTimelineTests` 7/0, `ContactsListTests` 3/0, `ChatListTests` 3/0, `CallScreenLifeTests` 12/0; ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `KeychainStoreTests`, separate run with the default simulator signature | 11 tests, 0 failures |
| `test_sim_text.py --scenario text` | PASS: 25 screenshots, 38 stored envelopes, 0 plaintext rows, one bubble per tap; in one run the paste control, the blocked section, the bubble width, a message seen while open, twelve new messages with the divider and «↓», a message while scrolled up, and the trimmed reply while scrolled up; the application sent 3 messages, the peer 16 |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| The 17 Python gates of `ios-static` | all passed; `test_ui_contract.py` 29 tests OK; `test_call_controller_parity.py` 105/105 labels; `test_component_boundary.py --base origin/feat/ios-chat-composer-20260929`: 22 files changed, 0 outside the allowlist |

## Mutation checks

Every mutation of the five feature receipts, and five of the combined source,
on this one tree. Each was applied, run and reverted from a copy, and the
checkout was clean afterwards.

### The markers and the composer together

| Mutation | What turned RED |
| --- | --- |
| The reader's own reply does not take the history down (the clause for one's own message dropped from the follow rule) | `test_sim_text.py`: the new step found no bubble of the reply on the screen («the reply written while scrolled up never reached «Сохранено сервером»») and the flow ended RED; the follow rule is the only change, so the reply was not brought into view. |
| The core is given the draft as typed (`ticket.draft` instead of `ticket.text`) | `ComposerSendTests`: the core held «  привет \n»; `test_sim_text.py`: the reply's bubble began with blanks and was never found as the trimmed text. |
| A failed send puts back the trimmed text (`Drafts.finished` restores `ticket.text`) | `ComposerSendTests`: «второе» came back instead of «  второе \n». |
| The model puts nothing back after a failure (the restore line in `AppModel.send` removed) | `ComposerSendTests`: the composer stayed empty. |
| The reader's own messages counted as new (`SeenMarks.unseenCount` counts both sides) | `ComposerSendTests`: «the reader's own message counted as new», 1 against 0, after the first send. A first form of this mutation (`$0 + 1`) did not compile and is not counted. |

### The earlier receipts, again on this tree

| Receipt | Mutations | Result |
| --- | --- | --- |
| [Call screen](../ios-client-20260928/call-screen-mac.md) | the ten of that receipt: no countdown; a countdown that closes a live call; one restarted by every republication; «Перезвонить» for an incoming call, after a connected call, or for a peer blocked since; «Перезвонить» that leaves the countdown running; the return line over the call screen; the interruption not named; the empty-string sentinel | 10 of 10 RED, each in `CallScreenLifeTests` and in `test_ui_contract.py` |
| [«Чаты»](chat-list-mac.md) | the five of that receipt | 5 of 5 RED (`DialogOrderTests`, `ChatListTests`, `test_ui_contract.py`) |
| [Contacts](contacts-mac.md) | the ten of that receipt, the paste control through the simulator flow | 10 of 10 RED (`ContactOrderTests`, `ContactsListTests`, `test_ui_contract.py`; the simulator flow: «no paste control in the sheet») |
| [Composer](chat-composer-mac.md) | the seven of that receipt, the bubble width through the simulator flow | 7 of 7 RED |
| [New-message marks](../ios-client-20260926/unread-markers-mac.md) | the three of that receipt, two of them through the simulator flow | 3 of 3 RED in that receipt's own forms: no divider row (`UnreadTimelineTests`: 5 of 7 failed); a message counted as seen only at the first positioning (`if condition.isSeen, !old.positioned`; the simulator flow at step 16: «a message read in the open chat is still counted … 1 новое сообщение»); «at the bottom» always true (the simulator flow: ««↓» is missing below unread messages») |

One mutation survived. With the message count taken out of the condition
the chat asks «seen?» on (`SeenCondition(messages: 0, …)`), the simulator
flow still passed: once as it runs, and once more with the simulator's
`ReduceMotionEnabled` set to true, where the real code passed as well. Some
other part of that condition changes when a message arrives at the open
bottom on the simulator; which one was not established, and whether the
setting reached the application was not checked on its own. The count stays
as a guard that no check here exercises. The setting was put back to false
after the two runs.

In all: 40 mutations RED on this tree (five of the combined source, 35 of the
earlier receipts), one survived, and one invalid form (it did not compile)
is not counted.

## What is not run

- A physical iPhone: `NOT RUN`.
- A signed or exported build: `NOT RUN`.
- The iOS 17 path of the markers (no scroll geometry): `NOT RUN`.
- A failed send in the simulator: the only failure a send has on the device
  is a local commit that cannot be written, which the simulator flow cannot
  produce; it is `ComposerSendTests`' alone.
- PR #60 is not part of this tree. A later merge of it needs its own run with
  the core it brings.
