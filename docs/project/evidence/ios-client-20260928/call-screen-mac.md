---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the iOS call screen after the call

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-28 and 2026-09-29. The
contributor ran them, not a coordinator. The tree is `99502c7` on
`feat/ios-call-screen-20260928`; the pull request records the SHA of the
commit that adds this file, which changes Markdown only. During the run the
only tracked file with uncommitted changes was `docs/clients/ios/verification.md`
(the row for this receipt); every Swift and Python source was that commit's.
The environment:

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
| `CallScreenLifeTests` on `main` | Does not compile: `callBackOffer`, `callReturnBar`, `returnToCall`, `callInterrupted` and the public `CallPresentation` initializer do not exist there. The behavioural RED is the mutation table below, one rule at a time. |
| `test_ui_contract.py` with the new check and the new `captions.txt` on `main` | 25 tests: the new check errors on its first rule (`callChanged` has no countdown to find), and the four new captions have no Swift literal («Звонок прерван: система забрала звук», «Звонок · », «Вернуться», «Вернуться к звонку»). |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 365 tests, 0 failures (the same count as `main`: the change adds an initializer, no kit test) |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 103 tests, 0 failures; ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `CallScreenLifeTests`: a production `AppModel` over a real registered client with one verified contact, the calls handed to it as the controller publishes them — the two-second and five-second countdowns, one countdown per ended call, «Закрыть» at once, a new call cancelling it, «Перезвонить» opening the confirmation and stopping it, the offer table (12 cases), a peer blocked since the call, a start the controller refused (empty call id), the video kind of an unanswered call, the line over the screens for a connected and a ringing call, and the interruption caption | 12 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 25 tests, OK |
| iOS static Python gates and `test_component_boundary.py --base origin/main` | all 17 passed; `test_component_boundary.py`: 14 files changed, 0 outside the allowlist |
| `test_sim_text.py --scenario text` | PASS: 17 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| `test_docs_consistency.py`, `markdownlint-cli2` on the changed documents | PASS; no findings in the changed files |

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| No countdown at all (`scheduleCallClose` never called) | `CallScreenLifeTests`: the two-second and the five-second tests failed (`XCTAssertFalse failed`); `test_ui_contract.py`: `AppModel.callChanged: missing 'scheduleCallClose(…)'`. |
| The countdown closes the screen even while a call is live (`!self.isCallActive` dropped from its guard) | `CallScreenLifeTests`: «the countdown of c4 must not close the screen on c5» failed; `test_ui_contract.py`: the guard is missing. |
| Every republished ended view restarts the countdown (`closingCall` guard dropped) | `CallScreenLifeTests`: «five seconds from the first publication, not the last» failed. |
| «Перезвонить» offered for an incoming call too (`last.outgoing` dropped) | `CallScreenLifeTests`: the offer table failed on both incoming rows; `test_ui_contract.py`: the rule is missing. |
| «Перезвонить» leaves the countdown running (`cancelCallClose()` dropped from `callBack`) | `CallScreenLifeTests`: «a screen with the confirmation open stays» failed at six seconds; `test_ui_contract.py`: `func callBack() {: missing 'cancelCallClose()'`. |
| The line over the screens shown while the call screen itself is up (`!showsCall` dropped) | `CallScreenLifeTests`: both `XCTAssertNil(callReturnBar)` failed; `test_ui_contract.py`: the rule is missing. |
| The interruption not named (`callLabel` always «Не удалось установить связь» for `failed`) | `CallScreenLifeTests`: the interruption test failed twice; `test_ui_contract.py`: the branch is missing. |
| The sentinel is the empty string again (`interruptedCall: String? = ""`) | `CallScreenLifeTests`: the refused-start test failed (named as an interruption); `test_ui_contract.py`: the optional declaration is missing. |
| «Перезвонить» offered after a connected call dropped (`!last.connected` dropped) | `CallScreenLifeTests`: the offer table failed on both connected rows; `test_ui_contract.py`: the rule is missing. |
| «Перезвонить» offered for a peer blocked since (`DialogPolicy.canReply` dropped from the offer) | `CallScreenLifeTests`: the blocked-peer test failed twice (an offer and a prompt for a blocked contact); `test_ui_contract.py`: the rule is missing. |

## What is not run

- A physical iPhone: `NOT RUN`.
- A real audio interruption (a cellular call, Siri, an alarm during a
  ParanoID call): `NOT RUN`. The caption is driven through
  `AppModel.callInterrupted`, which `CallCoordinator.interrupted` calls; the
  coordinator's path is checked by the contract, not exercised.
- The two-simulator call (`test_voice_sim.py`): `NOT RUN` for this change;
  the screen's own life after a call is tested through the model.
- The return line's tap and the «Перезвонить» button on the screen itself
  are not driven by a UI test; the model actions behind them are.
