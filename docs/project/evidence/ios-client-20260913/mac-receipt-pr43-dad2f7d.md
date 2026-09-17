<!-- markdownlint-disable MD010 -->
<!-- Verbatim contributor receipt; preserve original xcodebuild tabs.
     Attachment SHA-256: 46daa11462afe2b36f68d085952f13b58a165b6e36e806d95effc58eb4ef2489 -->

# Mac receipt для PR #43 — dad2f7d2df96d5ab4cecd21219df1b5538c7164a

От Ярослава, 2026-09-14, прогон 17:45–17:52Z. Для HermeS и координатора.

## Итог одной строкой

Всё зелёное, поведенческий RED на cb52330 показан. Полный `swift test` —
300 тестов, 0 падений (293 на cb52330 + 7 новых CallControlDispatchTests);
LazySnapshotKeyTests 14/0, SnapshotStoreTests 25/0, CallControlDispatchTests 7/0;
весь ParanoIDTests на подписанном симуляторе — 64/0; все python-гейты, включая два
новых, — зелёные; граница 13/0; markdownlint 5 файлов, 0 ошибок. Ваш
`test_call_control_baseline.py` на cb52330: 7 тестов, 13 падений, все на
`stale control must not change B` / `either mismatched field must reject the
action`, классификатор вернул PASS (exit 0). Код я не менял.

PR #42 (docs-only, cba4c19, обе проверки зелёные) я уже влил: merge-коммит
e9c767b в feat/ios-client-20260911. Merge-base #43 при этом остался cb52330,
дерево ваших правок это не затрагивает.

## Окружение

Тот же набор и окружение: macOS 26.5.2, Xcode 26.6 (17F113), swift 6.3.3;
отдельный worktree на вашем SHA без изменений; xcframework подлинкованы из
основного чекаута (ParanoidCore собран 2026-09-13, диф core/bridge не трогает);
`notices.py --offline` выполнен до xcodebuild; отдельный чистый симулятор
iPhone 17 Pro / iOS 26.5, ad hoc подпись без DEVELOPMENT_TEAM. Данные и ключи
установленных приложений не трогались. Baseline-скрипт сам создал и удалил
временный worktree на cb52330 (`/var/folders/.../paranoid-c1-red-*`).

## Дословный вывод

```text
=== fix/ios-call-controls-generation @ dad2f7d2df96d5ab4cecd21219df1b5538c7164a | base origin/feat/ios-client-20260911 @ e9c767b | 2026-09-14T17:45Z ===
host: 26.5.2, Xcode 26.6 Build version 17F113 , swift 6.3.3

--- storage bootstrap source contract ---
$ python3 -B clients/ios/test_storage_bootstrap_contract.py
exit=0
Ran 5 tests in 0.001s
OK

--- UI source contract ---
$ python3 -B clients/ios/test_ui_contract.py
exit=0
Ran 20 tests in 0.060s
OK

--- docs consistency ---
$ python3 -B clients/ios/test_docs_consistency.py
exit=0
PASS: 7 facts checked across 14 documents (hosted_registrations=3, one record each, device run=recorded, joint steps shown=True)

--- component boundary ---
$ python3 clients/ios/test_component_boundary.py --base origin/feat/ios-client-20260911
exit=0
base: origin/feat/ios-client-20260911 (e9c767b90761), merge-base: cb523306c186, head: dad2f7d2df96
PASS: 13 files changed, 0 outside allowlist

--- новые гейты PR #43 ---
$ python3 -B clients/ios/test_call_control_targeting.py
exit=0
Ran 4 tests in 0.001s
OK
$ python3 -B clients/ios/test_call_control_baseline_harness.py
exit=0
Ran 4 tests in 0.000s
OK

--- swift test --filter CallControlDispatchTests (GREEN на dad2f7d) ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter CallControlDispatchTests
exit=0
Test Case '-[ParanoidKitTests.CallControlDispatchTests testBothTargetFieldsAreRequiredAndMatchingActionsStillWork]' passed (0.012 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedEndDoesNotRejectReplacement]' passed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedHangupDoesNotEndReplacement]' passed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedMuteDoesNotChangeReplacement]' passed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedRejectDoesNotRejectReplacement]' passed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedSpeakerDoesNotChangeReplacement]' passed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testMatchingEndPreservesCancelHangupAndMatchingMediaControls]' passed (0.001 seconds).
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.024 (0.025) seconds

--- swift test --filter LazySnapshotKeyTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests
exit=0
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds

--- swift test --filter SnapshotStoreTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter SnapshotStoreTests
exit=0
	 Executed 25 tests, with 0 failures (0 unexpected) in 0.011 (0.013) seconds

--- swift test (full package) ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
exit=0
	 Executed 300 tests, with 0 failures (0 unexpected) in 9.804 (9.827) seconds

--- markdownlint-cli2 0.18.1, changed .md (5 files) ---
$ npx --yes markdownlint-cli2@0.18.1 --no-globs CHANGELOG.md docs/clients/ios/call-controls-handoff.md docs/clients/ios/voice-calls.md docs/project/current-state.md docs/security/ios-client-threats.md
exit=0
Summary: 0 error(s)

--- xcodebuild test ParanoIDTests (signed simulator, id=182526D9-9A20-4C3D-84A2-9B2C013B49F2) ---
$ xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID -destination platform=iOS Simulator,id=182526D9-9A20-4C3D-84A2-9B2C013B49F2 -derivedDataPath clients/ios/out/lazy-key-signed -only-testing:ParanoIDTests
exit=0
Test Suite 'BridgeSmokeTests' passed — Executed 2 tests, with 0 failures
Test Suite 'CallAudioSessionTests' passed — Executed 5 tests, with 0 failures
Test Suite 'CallScreenPolicyRegressionTests' passed — Executed 3 tests, with 0 failures
Test Suite 'ConnectivityRestartTests' passed — Executed 15 tests, with 0 failures
Test Suite 'KeychainStoreTests' passed — Executed 11 tests, with 0 failures
Test Suite 'OpeningRetryTests' passed
Test Suite 'QrTests' passed — Executed 8 tests, with 0 failures
Test Suite 'SdpCompatibilityTests' passed — Executed 3 tests, with 0 failures
Test Suite 'SdpPublishGatingTests' passed — Executed 16 tests, with 0 failures
Test Suite 'ParanoIDTests.xctest' passed at 2026-09-14 20:46:24.114.
	 Executed 64 tests, with 0 failures (0 unexpected) in 13.458 (13.491) seconds
** TEST SUCCEEDED **

--- baseline RED на cb52330 ---
$ python3 -B clients/ios/test_call_control_baseline.py
exit=0
BASELINE: cb523306c186e91a6d65e4050bd0b65eb9c7ab77
COMMAND: swift test --package-path .../paranoid-c1-red-24s3lokg/baseline/clients/ios/ParanoidKit --scratch-path .../paranoid-c1-red-24s3lokg/spm -Xswiftc -DC1_LEGACY_BASELINE --filter CallControlDispatchTests
Test Case '-[ParanoidKitTests.CallControlDispatchTests testBothTargetFieldsAreRequiredAndMatchingActionsStillWork]' failed (0.132 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedEndDoesNotRejectReplacement]' failed (0.003 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedHangupDoesNotEndReplacement]' failed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedMuteDoesNotChangeReplacement]' failed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedRejectDoesNotRejectReplacement]' failed (0.002 seconds).
Test Case '-[ParanoidKitTests.CallControlDispatchTests testDelayedSpeakerDoesNotChangeReplacement]' failed (0.002 seconds).
Test Suite 'CallControlDispatchTests' failed at 2026-09-14 20:50:34.845.
	 Executed 7 tests, with 13 failures (0 unexpected) in 0.145 (0.146) seconds
BASELINE SWIFT EXIT: 1
PASS: expected behavioral RED against old unbound controls; current-SHA GREEN is separate
```

Характер падений на baseline (по одному примеру на тип, полный лог у меня):

```text
CallControlDispatchTests.swift:160: testDelayedEndDoesNotRejectReplacement : XCTAssertEqual failed:
  ("... state: ended, generation: call generation 4, reason: Optional(reject), sent: 3, closes: 2 ...")
  is not equal to
  ("... state: incoming, generation: call generation 3, reason: nil, sent: 2, closes: 1 ...")
  - stale control must not change B or emit any signal/media operation
CallControlDispatchTests.swift:161: testDelayedHangupDoesNotEndReplacement : XCTAssertEqual failed: ("ended") is not equal to ("incoming")
CallControlDispatchTests.swift:160: testDelayedMuteDoesNotChangeReplacement : ... muted: true ... is not equal to ... muted: false ...
CallControlDispatchTests.swift:160: testDelayedSpeakerDoesNotChangeReplacement : ... speaker: true ... is not equal to ... speaker: false ...
CallControlDispatchTests.swift:182: testBothTargetFieldsAreRequiredAndMatchingActionsStillWork : ... - either mismatched field must reject the action (5 падений: end/reject/hangup/mute/speaker)
```

То есть на старом коде отложенное действие для A действительно завершало,
отклоняло, мьютило или переключало динамик у уже входящего B и слало лишний
сигнал/закрытие — ровно сценарий C1. Счётчик 13 = 5 тестов «delayed» × (1 сравнение
Effects + для трёх end/hangup/reject ещё 1 сравнение state) + 5 в тесте по
несовпадающим полям.

Сверка чисел: 300 = 293 + 7 новых тестов пакета. 64 симуляторных теста — как
на aab9e5d, состав тот же.

## Ревью дифа cb52330..dad2f7d

13 файлов, все clients/ios + docs + ios.yml. По существу:

- `CallController.swift:404-441`: `matchesCall(callId:generation:)` сверяет ID и
  поколение живого звонка; новые перегрузки `end/reject/hangup/mute/speaker(…,
  callId:, generation:)` делают `own()` и guard до любой мутации, затем зовут
  прежние owner-local методы. Фикс внутри контроллера, не в вызывающих.
- `CallCoordinator.swift:225-235`: только пробрасывает ID и поколение на owner.
- `AppModel.swift:811-835`: `endCall`, `toggleMute`, `toggleSpeaker` захватывают
  `call.callId`/`call.generation` в момент нажатия; `endCall` без живого звонка
  просто закрывает экран, как раньше.
- Старые unbound `reject()`/`hangup()`/`mute(_:)`/`speaker(_:)` остались
  публичными как owner-local вход; гейт `test_call_control_targeting.py` держит
  UI на bound-перегрузках. Приемлемо, замечаний нет.
- Тест: настоящий StateOwner, действие A удерживается до dispatch, owner принимает
  завершение A и offer B, затем A выпускается; проверяется отсутствие изменений
  B и лишних сигналов/закрытий/медиа-операций; отдельно — несовпадение каждого из
  двух полей и работа корректных действий. Baseline-адаптеры под
  `C1_LEGACY_BASELINE` только в тестовом файле.
- Доки и CHANGELOG: всё Swift помечено NOT RUN до этого receipt, overclaims не нашёл.

Блокеров нет, замечаний нет.

## NOT RUN у меня

Физическое устройство, реальная гонка нажатий на iPhone, upgrade реального
контейнера, отключение питания, archive/export, hosted probe.

## Что дальше

С моей стороны PR #43 на dad2f7d готов. Как ваш CI на dad2f7d станет зелёным и
draft будет снят — вливаю #43 в feat/ios-client-20260911 merge-коммитом без
squash, `--match-head-commit dad2f7d2df96d5ab4cecd21219df1b5538c7164a`, и сообщу
новый head #36. Дальше ваша повторная проверка #36 и решение Сергея по main;
экспорт, TestFlight, устройства, ADR-0014 и live-действия — отдельные решения
владельца.
