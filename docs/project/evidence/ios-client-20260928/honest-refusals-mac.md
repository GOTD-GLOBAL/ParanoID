---
status: draft
owner: ios
last_reviewed: 2026-09-28
---

# Contributor Mac receipt for the iOS refusals named where they happen

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-28. The contributor ran them,
not a coordinator. The tree is `e534ee6` on
`feat/ios-honest-refusals-20260928`; the pull request records the SHA of the
commit that adds this file, which changes Markdown only. The environment:

- Xcode 26.6 and Apple Swift 6.3.3;
- Rust 1.98.1 through `clients/ios/toolchain.sh`; the core bridge was rebuilt
  from this tree by `build-core.sh` before the runs;
- the iPhone 17 Pro simulator on iOS 26.5;
- the local stand from `clients/ios/local_stand.py`, running the prebuilt macOS
  `paranoid-server` from 2026-09-13. The server does not build on macOS, and
  this change does not touch it.

## RED before the change

The new checks were run on a clean `origin/main` worktree (`866827f`) with only
the test files copied in.

| Check | Result |
| --- | --- |
| `test_ui_contract.py` with the new check and the new `captions.txt` | 25 tests, 14 failures: `AppModel.send(): missing 'refuse(ticket.account, error)'`, every new caption «no Swift literal contains …», and «a screen still says 'Контакт уже добавлен'». |
| The three checks of `ContactFlowError` that compile without the change (the other-keys sentence, no raw code in a named refusal, and the real-core `peer_already_pinned` pairing) | 3 tests, 17 assertion failures, all `("Контакт уже добавлен.")`. |
| `SendRefusalTests` and `RefusalPresentationTests` | Do not compile on `main`: `SendRefusal`, `ContactFlowError.otherKeys` and `AppModel.staleRefusal` do not exist there. The behavioural RED for the composer is the first mutation below, which removes only the line that shows the note. |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 374 tests, 0 failures (365 on `main` plus `SendRefusalTests` 7 and the two new `PresentationTests` checks); the kit run takes about 2.5 minutes because of the two real-core ceiling tests |
| `SendRefusalTests` alone: real core, 400 unaccepted envelopes → `outbox_full` with no commit; 1000 texts each accepted by a synthetic `accepted_v2` → empty outbox, 1000 messages, `local_history_full`; a blocked contact → `contact_blocked`; no registration; two contacts of one account → `peer_already_pinned` with the stored snapshot unchanged | 7 tests, 0 failures (the 400 case takes about 51 s, the 1000 case about 92 s) |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 95 tests, 0 failures; ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `RefusalPresentationTests`: a production `AppModel` over a real client with a full outbox to a verified contact; the refusal is named above the composer with the text back in the field, the field's echo keeps it, an edit forgets it, leaving keeps it and returning shows it, another conversation does not, and the staleness table | 4 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 25 tests, OK |
| iOS static Python gates and `test_component_boundary.py --base origin/main` | all 17 passed; `test_component_boundary.py`: 15 files changed, 0 outside the allowlist |
| `test_sim_text.py --scenario text` | PASS: 17 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| `test_docs_consistency.py`, `markdownlint-cli2` on the changed documents | PASS; no findings in the changed files |

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| The composer never shows the note (the `refusals[chatAccount]` branch removed) | `RefusalPresentationTests`: 2 of 4 failed (`("") is not equal to ("Сообщение не отправлено: очередь …")`); `test_ui_contract.py`: the composer branch is missing. |
| Any `draftChanged` forgets the note, not only a real edit | `RefusalPresentationTests`: 2 of 4 failed at «the echo is not an edit». |
| Leaving the chat forgets every note | `RefusalPresentationTests`: 1 of 4 failed on return; `test_ui_contract.py`: `closeChat() still carries 'refusals'`. |
| «Контакт уже добавлен.» put back for `peer_already_pinned` | `PresentationTests`: 1 failed (`XCTAssertNotEqual failed: ("Контакт уже добавлен.")`); `test_ui_contract.py`: the other-keys caption has no literal and the retired sentence is back. |
| A full-outbox note is never retired (`staleRefusal(.outboxFull)` always false) | `RefusalPresentationTests`: the staleness table failed. |
| `reloadNow` no longer retires stale notes | `test_ui_contract.py`: `AppModel.reloadNow(): missing 'forgetStaleRefusals(…)'`. |

## What is not run

- A physical iPhone: `NOT RUN`. A refusal needs a prepared state (400 queued
  envelopes, or 1000 sent texts), and no live action is taken without the
  owner's go.
- Spoken VoiceOver: the announcement is posted (`UIAccessibility.post`) and the
  contract checks that it is; nobody listened to it.
- `local_state_full`, `invalid_text` and `introduction_limit` are classified
  from a table over the codes; the real core was not driven to any of them.
- A note retired by a real drain of the outbox or a real registration: the
  rule is tested as a table (`staleRefusal`) and the contract checks that
  `reloadNow` applies it; no test drives the lanes to accept an envelope.
