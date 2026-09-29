---
status: draft
owner: ios
last_reviewed: 2026-09-29
---

# Contributor Mac receipt for the iOS contacts

## Provenance

These checks ran on Yaroslav's Mac on 2026-09-29. The contributor ran them,
not a coordinator. The tree is `d8ce798` on `feat/ios-contacts-20260929`,
which stands on `feat/ios-chat-list-20260929` (PR #64); the pull request
records the SHA of the commit that adds this file, which changes Markdown
only. During the run the only tracked file with uncommitted changes was
`docs/clients/ios/verification.md` (the row for this receipt); every Swift and
Python source was that commit's. The environment:

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
| `ContactOrderTests` and `ContactsListTests` on the base | Do not compile there: `ContactOrder`, `groupedFingerprint`, `Dialog.fingerprint`, `orderedContacts` and `blockedContacts` do not exist. The behavioural RED is the mutation table below. |
| `test_ui_contract.py` with the new check on the base | 26 tests, 3 failures and 1 error: the new check errors on the missing `ContactOrder.swift`, #64's list check fails on `ForEach(model.orderedContacts)`, and the two new captions have no Swift literal («Вставить из буфера», «Заблокированные (»). |
| The paste control in the simulator flow | The mutation below that removes it: the new step finds no `paste-clipboard` and the flow ends RED. |

## GREEN on the change

| Check | Result |
| --- | --- |
| `swift test --package-path ParanoidKit` | 377 tests, 0 failures (370 on the base plus `ContactOrderTests` 7) |
| `ContactOrderTests`: the named first in Russian order, Latin after; each collation option on a pair only it decides (case, diacritics, numbers by value); equal names and the unnamed by account; the grouped fingerprint loses no digit; a dialog carries the core's fingerprint | 7 tests, 0 failures |
| App target, unsigned, `-skip-testing:ParanoIDTests/KeychainStoreTests` | ParanoIDTests 97 tests, 0 failures (94 on the base plus `ContactsListTests` 3); ParanoIDUITests 4, 3 skipped by design, 0 failures |
| `ContactsListTests`: a production `AppModel` over a real registered client with three verified contacts — names given through `rename` order the list, an emptied name goes back among the unnamed, a blocked contact leaves the list for its section and comes back on unblock while staying in «Чаты», every contact carries a 64-digit fingerprint | 3 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| `test_ui_contract.py` | 26 tests, OK |
| iOS static Python gates and `test_component_boundary.py` | all 17 passed; `test_component_boundary.py --base origin/feat/ios-chat-list-20260929`: 0 files outside the allowlist |
| `test_sim_text.py --scenario text`, with the new step: the pasteboard is set, the system's paste control is tapped, the fingerprint sheet shows the peer's fingerprint (`04a-pasted-from-clipboard.png`), then the field path as before; «Вы: …» read off «Мой ID»; with the peer blocked, «Контакты» has no row for it and a folded «Заблокированные (1)» that opens with «Разблокировать контакт» inside (`12a-blocked-section.png`); the fingerprint labels are read as 64 digits off the grouped texts | PASS: 19 screenshots, 6 stored envelopes, 0 plaintext rows, one bubble per tap |
| Release build for a device, unsigned, and `test_app_bundle.py` | BUILD SUCCEEDED; 23 checks, 1 skipped |
| `test_docs_consistency.py`, `markdownlint-cli2` on the changed documents | PASS; no findings in the changed files |

## Mutation checks

Each mutation was applied, run and reverted, and the reverted tree was checked
for leftover markers.

| Mutation | What turned RED |
| --- | --- |
| No alphabetical order (`alphabetical` returns the core's order) | `ContactOrderTests`: three of six failed; `ContactsListTests`: the named order failed. |
| The blocked contacts left in the main list (the filter dropped) | `ContactsListTests`: the section test failed; `test_ui_contract.py`: the rule is missing. |
| The grouping drops half the digits (`prefix(32)`) | `ContactOrderTests`: «loses nothing» failed twice. |
| No paste control in the sheet (the control removed) | `test_sim_text.py`: the new step found no `paste-clipboard` and the flow ended RED; `test_ui_contract.py`: the control is missing. |
| The fingerprint not decoded from the core's view | `ContactOrderTests`: the decode test failed; `ContactsListTests`: every contact's fingerprint was empty. |
| The unnamed contacts first | `ContactOrderTests`: two failed; `ContactsListTests`: the named order failed. |
| No case folding in the collation (`.caseInsensitive` dropped) | `ContactOrderTests`: «аня» and «Аня» no longer one name. |
| No diacritic folding (`.diacriticInsensitive` dropped) | `ContactOrderTests`: «еж» and «ёж» no longer one name. |
| No numbers by value (`.numeric` dropped) | `ContactOrderTests`: «Сергей 10» before «Сергей 2». |
| No Russian locale (`locale: nil`) | `ContactOrderTests`: the Latin name sorted before the Cyrillic ones. |

## What is not run

- A physical iPhone: `NOT RUN`.
- The folded section's opening and «Разблокировать контакт» inside it are
  not driven by a UI test; the model's partition is, and the contract checks
  the screen.
- The system's paste control on a device whose pasteboard holds no text (it
  stands disabled by the system): `NOT RUN`.
