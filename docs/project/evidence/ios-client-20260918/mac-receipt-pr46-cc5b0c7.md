---
status: draft
owner: ios
last_reviewed: 2026-09-23
---

# Contributor Mac receipt for PR46 at cc5b0c7

## Provenance

Yaroslav ran the final-head Mac gate for exact
`cc5b0c711090729cb53690a526722a5d86edd6f4`, the PR #46 message-time integration
head, and reported it in the ParanoID Telegram thread on 2026-09-18. The
coordinator had requested it in
[PR46 comment 5727481543](https://github.com/GOTD-GLOBAL/ParanoID/pull/46#issuecomment-5727481543)
and relayed the report in
[PR46 comment 5727872437](https://github.com/GOTD-GLOBAL/ParanoID/pull/46#issuecomment-5727872437)
at 2026-09-18T09:13:51Z. PR46 merged as
`c9ca067bf747b7b3046fcfdf1986a46c0418ff21` at 09:18:19Z. The report gives no run
times. No Telegram permalink exists, and raw logs and screenshots were not
retrieved for this record.

The contributor's text is in Russian. Below it is translated into English, and
the original follows verbatim. The translation adds nothing to the original. The
SHA-256 of the Russian text as it was supplied for this record (3885 bytes) is
`2efbe7b98df64b815e797bf13ae834071f0e6a5edd765dccafb4b30f27da13a1`.

These are contributor-reported Mac results. They are not a coordinator Mac run,
not human architecture approval and not ADR acceptance.

## Translation

```text
Mac gate on cc5b0c711090729cb53690a526722a5d86edd6f4 — done, everything green.

Host: macOS 26.0, Xcode 26, Swift 6.3.3, Rust 1.98.1, iPhone 17 Pro simulator,
iOS 26.5. Working tree at the exact SHA, clean.

1. Core rebuilt from this tree
   bash clients/ios/build-core.sh
   -> OK: ParanoidCore.xcframework, 3 slices (arm64 device / sim / macOS),
   core slice in the run below: 119cd7dde4b6fb761865565af8c710822d1e08a2219106b58be1e5421a9adbdb

2. Package tests on the pinned toolchain
   swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter MessageTimeTests
   -> 7 tests, 0 failures. By name: testTheTimeUnderABubbleIsTheDevicesOwnZone,
   testAMessageWithoutATimeIsShownWithoutOne, testASeparatorStandsWhereTheDayChanges,
   testTheSeparatorNamesTheDayTheWayItIsSaid, testAConversationRowSaysWhenItsLastEventWas,
   testTheCoreValueReachesTheDecodedMessageAndZeroMeansUnknown and your new
   testCallPreviewDoesNotBorrowTheLastMessagesTime.

   swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
   -> 328 tests, 0 failures.

3. The app and the simulator flow
   xcodebuild build -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
     -destination "platform=iOS Simulator,id=6B4EF202-6D01-49E9-ABE1-EF3140184D08" \
     -derivedDataPath clients/ios/out/dd-icon CODE_SIGNING_ALLOWED=NO
   -> BUILD SUCCEEDED (unsigned build).

   python3 clients/ios/test_sim_text.py \
     --server-binary clients/ios/out/server-target/release/paranoid-server --scenario text
   -> text: PASS. 15 screenshots, 6 retained envelopes, 0 plaintext rows
   in the cluster, one bubble per tap, the peer's history has 3 messages.
   Checked in the live app: the bubble's accessibility label contains HH:mm, the
   chat shows the «Сегодня» ("Today") pill, and the marks read as the words
   «Сохранено сервером» ("Stored by the server") and then «Доставлено»
   ("Delivered"). The stand was started with the prebuilt server binary
   a4a65d123ee06f6e8b6e6ab63da4e23cd4eb6fa3c8f8ea15f5898ee407880e93 (the server
   does not build on macOS because of the Linux-only O_TMPFILE; the branch does
   not touch it).

4. Also, in the same run
   The five original iOS gates: test_ui_contract, test_docs_consistency,
   test_call_control_targeting, test_storage_bootstrap_contract — OK;
   test_call_controller_parity — 105/105 labels (104 verbatim, 1 nested).
   Android host tests: test_call_controller, test_call_log, test_message_time,
   test_message_presentation, test_ui_contract — all OK.

NOT RUN, with caveats
- The call preview's date behaviour was checked only at unit level, by your new
  test: the simulator scenario has no call, so the call row and its preview were
  not observed in the live app.
- Physical phone, spoken VoiceOver, signed build, export and TestFlight.
- The APK and everything that needs the Android SDK: this machine has no SDK.
- The production server and two-phone acceptance.
- No merge, no rollout, no publication and no ADR acceptance.
```

## Notes for the record (2026-09-23)

- `git diff cc5b0c7 c9ca067 -- clients/ios clients/core key-protocol` is empty:
  PR46's merge carries the tested iOS and core trees unchanged.
- `test_sim_text.py --scenario text` runs
  `ParanoIDUITests/TextFlowUITests/testTextFlowOnTheLocalStand`, so its PASS is an
  execution of that UI test on the simulator. It is not phone evidence.
- Call-preview date suppression is verified here only by the unit test. This
  receipt does not observe it in a running app, and that live-UI observation
  remains a runtime follow-up.
- The PR46 relay comment says only a shortened server identifier was supplied.
  The text supplied for this record carries the full digest above. That digest
  equals the stand binary recorded by gate 11 in the
  [2026-09-13 iOS evidence catalogue](../ios-client-20260913/README.md).
- In item 4, the "five original iOS gates" are the four named source gates plus
  the parity label gate. The parity result is label coverage, not a Swift runtime
  call.
- The later [4066f36 receipt](mac-receipt-pr50-4066f36.md) was run on a
  descendant of `cc5b0c7`. Its ParanoidKit 362/0 run includes `MessageTimeTests`
  again. It adds no live-UI call-preview observation.

## Original (Russian, verbatim)

```text
Mac-гейт на cc5b0c711090729cb53690a526722a5d86edd6f4 — выполнен, всё зелёное.

Хост: macOS 26.0, Xcode 26, Swift 6.3.3, Rust 1.98.1, симулятор iPhone 17 Pro,
iOS 26.5. Рабочее дерево на точном SHA, чистое.

1. Пересборка ядра из этого дерева
   bash clients/ios/build-core.sh
   -> OK: ParanoidCore.xcframework, 3 среза (arm64 device / sim / macOS),
   срез ядра в прогоне ниже: 119cd7dde4b6fb761865565af8c710822d1e08a2219106b58be1e5421a9adbdb

2. Тесты пакета на закреплённом тулчейне
   swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter MessageTimeTests
   -> 7 тестов, 0 падений. Поимённо: testTheTimeUnderABubbleIsTheDevicesOwnZone,
   testAMessageWithoutATimeIsShownWithoutOne, testASeparatorStandsWhereTheDayChanges,
   testTheSeparatorNamesTheDayTheWayItIsSaid, testAConversationRowSaysWhenItsLastEventWas,
   testTheCoreValueReachesTheDecodedMessageAndZeroMeansUnknown и ваш новый
   testCallPreviewDoesNotBorrowTheLastMessagesTime.

   swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
   -> 328 тестов, 0 падений.

3. Приложение и симуляторный поток
   xcodebuild build -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
     -destination "platform=iOS Simulator,id=6B4EF202-6D01-49E9-ABE1-EF3140184D08" \
     -derivedDataPath clients/ios/out/dd-icon CODE_SIGNING_ALLOWED=NO
   -> BUILD SUCCEEDED (неподписанная сборка).

   python3 clients/ios/test_sim_text.py \
     --server-binary clients/ios/out/server-target/release/paranoid-server --scenario text
   -> text: PASS. 15 скриншотов, 6 сохранённых конвертов, 0 строк открытого текста
   в кластере, один пузырь на нажатие, история собеседника 3 сообщения.
   Проверено в живом приложении: в метке доступности пузыря есть HH:mm, в чате
   появляется плашка «Сегодня», отметки читаются словами «Сохранено сервером» и
   затем «Доставлено». Стенд поднят готовым бинарником сервера
   a4a65d123ee06f6e8b6e6ab63da4e23cd4eb6fa3c8f8ea15f5898ee407880e93 (сервер на
   macOS не собирается из-за linux-only O_TMPFILE, ветка его не трогает).

4. Дополнительно, тем же прогоном
   Пять исходных гейтов iOS: test_ui_contract, test_docs_consistency,
   test_call_control_targeting, test_storage_bootstrap_contract — OK;
   test_call_controller_parity — 105/105 меток (104 дословно, 1 вложенная).
   Host-тесты Android: test_call_controller, test_call_log, test_message_time,
   test_message_presentation, test_ui_contract — все OK.

NOT RUN, с оговорками
- Поведение даты у превью звонка проверено только модульно, вашим новым тестом:
  в симуляторном сценарии звонка нет, поэтому строка звонка и её превью в живом
  приложении не наблюдались.
- Физический телефон, VoiceOver голосом, подписанная сборка, экспорт и TestFlight.
- APK и всё, что требует Android SDK: на этой машине SDK нет.
- Боевой сервер и приёмка на двух телефонах.
- Ни мержа, ни выката, ни публикации, ни приёмки ADR.
```
