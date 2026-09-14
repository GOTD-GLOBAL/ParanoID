<!-- markdownlint-disable MD010 -->
<!-- Verbatim contributor receipt follows. MD010 is disabled only in this receipt
     to preserve the original tab in xcodebuild output.
     Original attachment SHA-256: 0ecbeed6ef4f8ff7349b54d0281644c4a0159a7976d8ea7e0e196ba08a2f85f3 -->

# Mac receipt для PR #41 — e6429070772bed303db109fb42d2ce41064b888b

От Ярослава, 2026-09-14, прогон 14:47–14:50Z. Для HermeS и координатора.

## Итог одной строкой

Приложение и все 64 теста ParanoIDTests на подписанном симуляторе — зелёные; все
python-гейты, включая четыре новых, — зелёные; **тестовый таргет пакета ParanoidKit
не компилируется** (одна ошибка Swift 6 в новом тесте), поэтому `swift test` —
LazySnapshotKeyTests, SnapshotStoreTests и полный пакет — не выполнялся, 0 тестов.
Это тот `sending`-риск, который считался закрытым в e642907; закрыт не полностью.
Код я не менял: правки и новый SHA за вами, я повторю прогон тем же набором.

## Окружение

- macOS 26.5.2, Xcode 26.6 (17F113), swift 6.3.3.
- Отдельный worktree на вашем SHA без изменений.
- xcframework подлинкованы из основного чекаута (ParanoidCore собран 2026-09-13;
  ваш диф core/bridge не трогает — граница 30/0); `notices.py --offline` выполнен
  до xcodebuild.
- Отдельный чистый симулятор iPhone 17 Pro / iOS 26.5, ad hoc подпись без
  DEVELOPMENT_TEAM. Данные и ключи установленных приложений не трогались:
  тестовое назначение — новый симулятор, не те, где живут аккаунты.

## Дословный вывод

```text
=== fix/ios-review-integration @ e6429070772bed303db109fb42d2ce41064b888b | base origin/feat/ios-client-20260911 @ f1fbdb2 | 2026-09-14T14:47Z ===
host: 26.5.2, Xcode 26.6 Build version 17F113 , swift 6.3.3

--- storage bootstrap source contract ---
$ python3 -B clients/ios/test_storage_bootstrap_contract.py
exit=0
Ran 5 tests in 0.000s
OK

--- UI source contract ---
$ python3 -B clients/ios/test_ui_contract.py
exit=0
Ran 20 tests in 0.061s
OK

--- docs consistency ---
$ python3 -B clients/ios/test_docs_consistency.py
exit=0
PASS: 7 facts checked across 14 documents (hosted_registrations=3, one record each, device run=recorded, joint steps shown=True)

--- component boundary ---
$ python3 clients/ios/test_component_boundary.py --base origin/feat/ios-client-20260911
exit=0
base: origin/feat/ios-client-20260911 (f1fbdb28b78e), merge-base: f1fbdb28b78e, head: e6429070772b
PASS: 30 files changed, 0 outside allowlist

--- новые гейты PR #41 ---
$ python3 -B clients/ios/test_call_review_regressions.py
exit=0
Ran 5 tests in 0.001s
OK
$ python3 -B clients/ios/test_freeze_open_contract.py
exit=0
Ran 3 tests in 0.001s
OK
$ python3 -B clients/ios/test_interrupted_onboarding_contract.py
exit=0
Ran 2 tests in 0.001s
OK
$ python3 -B clients/ios/test_pinned_session_contract.py
exit=0
Ran 11 tests in 2.260s
OK

--- swift test --filter LazySnapshotKeyTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests
exit=1
.../clients/ios/ParanoidKit/Tests/ParanoidKitTests/InterruptedOnboardingTests.swift:39:21: error: sending 'resumed' risks causing data races [#SendingRisksDataRace]
error: fatalError

--- swift test --filter SnapshotStoreTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter SnapshotStoreTests
exit=1
(та же единственная ошибка)

--- swift test (full package) ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
exit=1
(та же единственная ошибка; 0 тестов выполнено)

--- markdownlint-cli2 0.18.1, changed .md (8 files) ---
$ npx --yes markdownlint-cli2@0.18.1 --no-globs CHANGELOG.md docs/clients/ios/review-integration-handoff.md docs/clients/ios/self-service.md docs/clients/ios/voice-calls.md docs/decisions/0014-ios-client.md docs/project/current-state.md docs/rfcs/0021-ios-client.md docs/security/ios-client-threats.md
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
Test Suite 'ParanoIDTests.xctest' passed at 2026-09-14 17:49:18.177.
	 Executed 64 tests, with 0 failures (0 unexpected) in 27.135 (27.155) seconds
** TEST SUCCEEDED **
```

## Ошибка компиляции — полная диагностика

Единственная ошибка во всём тестовом таргете пакета; остальные новые тестовые файлы
(OwnerFreezeNotificationTests, CallFreezeIntegrationTests, CallConsentRegressionTests,
CallRelayCancellationTests) прошли компиляцию. Сам ParanoidKit собирается: приложение
и его 64 теста с ним слинкованы, включая `sending`-замыкание `openClient` в
AppModel.swift:167-169.

```text
[3/5] Compiling ParanoidKitTests InterruptedOnboardingTests.swift
InterruptedOnboardingTests.swift:39:21: error: sending 'resumed' risks causing data races [#SendingRisksDataRace]
 37 |             return nil
 38 |         }
 39 |         let owner = StateOwner(client: resumed)
    |                     |- error: sending 'resumed' risks causing data races [#SendingRisksDataRace]
    |                     `- note: sending 'resumed' to actor-isolated initializer 'init(client:clock:hook:)' risks causing data races between actor-isolated and local nonisolated uses
 40 |         let flow = ProofFlow(owner: owner, transport: transport, pacer: RecordingPacer())
 ...
 44 |         XCTAssertEqual(try final.credential() as NSDictionary, credential)
    |                                                                `- note: access can happen concurrently
```

Как я это читаю (подсказка, решение за вами): region-анализ Swift 6 относит
`credential`, полученный из `resumed.credential()` до строки 39, к региону `resumed`;
после отправки `resumed` в актор `StateOwner(client:)` любое использование этого
региона (строка 44) считается гонкой. Варианты: взять `credential` от независимого
клиента (например, `SelfServiceClient(saved: checkpoint, …)`), сделать Sendable-копию
до отправки, либо не использовать производные от `resumed` после `StateOwner(client:)`.
Ваши Linux-проверки исходников такие ошибки не видят — на каждый новый SHA нужен наш
Mac-прогон, это нормально.

## Ревью дифа f1fbdb2..e642907

Source-review без компиляции. Python-гейты на f1fbdb2 без правок красные: freeze-open
4 падения, call-review 5, onboarding 1F+1E — «red without fix» выполнено.

F1–F7 закрыты внутри владельцев состояния, не в вызывающих:

- F1 — `StateOwner.swift:264` defer-уведомление на каждом выходе из `perform`,
  включая проглоченные ошибки, → `CallCoordinator.swift:314-317` →
  `CallController.authorizationLost` (`:413-418`, идемпотентно).
- F2 — `CallController.swift:373-378` проверка live/incoming/callId/generation внутри
  контроллера; AppModel захватывает generation до ожидания разрешения.
- F3 — `AppModel.swift:257-265`.
- F4 — `SelfServiceClient.swift:170-182` `resumeOnboarding` + `ProofFlow.swift:284`.
- F5 — `VoiceRelayLane.swift:415-470` sticky Request, отмена только своего.
- F6 — `AudioSessionController.swift:311-318`.
- F7 — `pinned_session_contract.py`; ваша мутация теперь ловится во всех
  production-файлах.

Регрессии F1/F3/F4/F5/F6 красные без фикса; F2 красная только компиляцией (нет
перегрузки), переход UI→owner покрыт лексически (`test_call_review_regressions.py:11-27`),
не поведенчески. Цитаты `voice-v1.md:117-118`, `call-v2.md:70-72`,
`voice-turn-v1.md:116-127` подтверждены; runtime-overclaims в доках не нашёл, всё Swift
помечено NOT RUN. Блокеров нет.

Замечания по убыванию важности, чините на своё усмотрение:

1. `docs/security/ios-client-threats.md:205-208` заявляет покрытие «direct
   aliases/metatypes», но гейт пропускает
   `type(of: pinned.makeSession()).init(configuration: .ephemeral)`, generic
   `T.init(configuration:)` при `T: URLSession` и `NSClassFromString("NSURLSession")`.
   Либо сузить формулировку, либо добавить мутации.
2. `ProofFlow.swift:284` вызывает `resumeOnboarding` на каждом connect каждой лейны
   (receive/send/voice): два лишних core-вызова за цикл; no-op зависит от побайтового
   равенства текста состояния (`SelfServiceClient.swift:464`), а core гарантирует
   только JSON-равенство — если текст разойдётся, каждый цикл будет коммитить
   snapshot; ловит это только NOT RUN Swift-тест `:86-88`.
3. `AppModel.swift:966` ранний `return` на устаревший callId стоит до
   `cancelCallIntent()` (`:967`): устаревший тап «Ответить» больше не отменяет идущий
   intent, как делал код до PR. Низкий.
4. `OpeningRetryTests.swift:19-22` строит полный production Runtime в тестовом бандле
   приложения (pinned URLSession, RTCAudioSession, тикер без остановки) — первый
   такой тест; seam `openClient` (`AppModel.swift:166-171, 238-239`) — живой
   production-код, не `#if DEBUG`.
5. `StateOwner.swift:154`: замороженный `start()` возвращает старый `run` вместо
   `nil` (в отличие от `restart()` `:193`) — безвредно, но API сообщает «started»
   неверно.
6. Доки: `review-integration-handoff.md:64-65` «RED with two assertion failures», у
   гейта на f1fbdb2 — 3 теста / 4 падения; `test_ui_contract.py:541-548` всё ещё
   описывает proximity как local-only прямо над проверкой `!remoteVideo`.

## NOT RUN у меня

Физическое устройство, реальная задержка остановки медиа и взаимодействие с
heartbeat, upgrade реального контейнера, отключение питания, archive/export,
hosted probe.

## Что дальше

Чините компиляцию и что сочтёте нужным из замечаний, присылаете точный SHA — я гоняю
тот же набор (гейты, полный `swift test`, весь ParanoIDTests на подписанном
симуляторе) и возвращаю дословный вывод. После зелёного Mac-прогона и вашего CI
вливаю #41 в feat/ios-client-20260911 merge-коммитом без squash, как #40. Дальше
ваша повторная проверка #36 и решение Сергея по main; экспорт, TestFlight,
устройства, ADR-0014 и live-действия — отдельные решения владельца.
