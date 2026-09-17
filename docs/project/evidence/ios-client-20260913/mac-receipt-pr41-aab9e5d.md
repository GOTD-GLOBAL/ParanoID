<!-- markdownlint-disable MD010 -->
<!-- Verbatim contributor receipt; preserve original tabs in xcodebuild output.
     Attachment SHA-256: a2ad993863941d226dfd81b46c6a401a2dc0ec9de3b4f27beb60dba88d541a54 -->

# Mac receipt для PR #41 — aab9e5dee8fe75c5a3170faac5f12e80819cdb12

От Ярослава, 2026-09-14, прогон 15:24–15:26Z. Для HermeS и координатора.

## Итог одной строкой

Всё зелёное. Пакет ParanoidKit компилируется вместе с тестовым таргетом; полный
`swift test` — 293 теста, 0 падений (278 на f1fbdb2 + 15 новых из PR #41);
LazySnapshotKeyTests 14/0, SnapshotStoreTests 25/0; весь ParanoIDTests на
подписанном симуляторе — 64/0; все python-гейты, включая четыре новых, — зелёные;
граница 31/0; markdownlint 9 файлов, 0 ошибок. Ошибка компиляции из e642907
(`sending 'resumed'`, InterruptedOnboardingTests.swift:39) устранена.
Код я не менял.

## Окружение

Тот же набор и то же окружение, что для e642907: macOS 26.5.2, Xcode 26.6
(17F113), swift 6.3.3; отдельный worktree на вашем SHA без изменений; xcframework
подлинкованы из основного чекаута (ParanoidCore собран 2026-09-13, ваш диф
core/bridge не трогает); `notices.py --offline` выполнен до xcodebuild; отдельный
чистый симулятор iPhone 17 Pro / iOS 26.5, ad hoc подпись без DEVELOPMENT_TEAM.
Данные и ключи установленных приложений не трогались.

## Дословный вывод

```text
=== fix/ios-review-integration @ aab9e5dee8fe75c5a3170faac5f12e80819cdb12 | base origin/feat/ios-client-20260911 @ f1fbdb2 | 2026-09-14T15:24Z ===
host: 26.5.2, Xcode 26.6 Build version 17F113 , swift 6.3.3

--- storage bootstrap source contract ---
$ python3 -B clients/ios/test_storage_bootstrap_contract.py
exit=0
Ran 5 tests in 0.001s
OK

--- UI source contract ---
$ python3 -B clients/ios/test_ui_contract.py
exit=0
Ran 20 tests in 0.066s
OK

--- docs consistency ---
$ python3 -B clients/ios/test_docs_consistency.py
exit=0
PASS: 7 facts checked across 14 documents (hosted_registrations=3, one record each, device run=recorded, joint steps shown=True)

--- component boundary ---
$ python3 clients/ios/test_component_boundary.py --base origin/feat/ios-client-20260911
exit=0
base: origin/feat/ios-client-20260911 (f1fbdb28b78e), merge-base: f1fbdb28b78e, head: aab9e5dee8fe
PASS: 31 files changed, 0 outside allowlist

--- новые гейты PR #41 ---
$ python3 -B clients/ios/test_call_review_regressions.py
exit=0
Ran 5 tests in 0.002s
OK
$ python3 -B clients/ios/test_freeze_open_contract.py
exit=0
Ran 3 tests in 0.001s
OK
$ python3 -B clients/ios/test_interrupted_onboarding_contract.py
exit=0
Ran 3 tests in 0.002s
OK
$ python3 -B clients/ios/test_pinned_session_contract.py
exit=0
Ran 11 tests in 2.269s
OK

--- swift test --filter LazySnapshotKeyTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests
exit=0
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.004 (0.007) seconds

--- swift test --filter SnapshotStoreTests ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm --filter SnapshotStoreTests
exit=0
	 Executed 25 tests, with 0 failures (0 unexpected) in 0.013 (0.015) seconds

--- swift test (full package) ---
$ swift test --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
exit=0
	 Executed 293 tests, with 0 failures (0 unexpected) in 10.202 (10.223) seconds

--- markdownlint-cli2 0.18.1, changed .md (9 files) ---
$ npx --yes markdownlint-cli2@0.18.1 --no-globs CHANGELOG.md docs/clients/ios/review-integration-handoff.md docs/clients/ios/self-service.md docs/clients/ios/voice-calls.md docs/decisions/0014-ios-client.md docs/project/current-state.md docs/project/evidence/ios-client-20260913/mac-receipt-pr41-e642907.md docs/rfcs/0021-ios-client.md docs/security/ios-client-threats.md
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
Test Suite 'ParanoIDTests.xctest' passed at 2026-09-14 18:25:25.673.
	 Executed 64 tests, with 0 failures (0 unexpected) in 27.082 (27.100) seconds
** TEST SUCCEEDED **
```

Сверка чисел: 293 = 278 (полный пакет на f1fbdb2/628958b) + 15 новых тестов пакета
из PR #41 (OwnerFreezeNotification, CallFreezeIntegration, CallConsentRegression,
CallRelayCancellation, InterruptedOnboarding). 64 симуляторных теста — как на
e642907, состав тот же. Onboarding-гейт 2 → 3 теста за счёт проверки Sendable
credential.

## Ревью дифа e642907..aab9e5d

12 файлов. По существу:

- Тест InterruptedOnboardingTests: credential хранится как `Data`
  (`credentialBytes`/`decodeCredential`), объекты для fake server восстанавливаются
  из байтов; регион `resumed` после `StateOwner(client:)` не удерживается.
  Компилятор подтвердил: единственная ошибка e642907 ушла, новых нет.
- `SelfServiceClient.resumeOnboarding` (`:173-183`): один read-only `view()`,
  `prepare_contact_v2` только при `enrollment.mode == active` и отсутствующем
  `contact`; повторный `active()` убран. Моё замечание про побайтовое равенство
  JSON снято.
- `StateOwner.start()`: семантика возвращаемого токена задокументирована, поведение
  не менялось — приемлемо.
- Доки: ATS-гейт честно перечисляет, что не ловит (`type(of:)`, generic `T.init`,
  `NSClassFromString`); комментарий про proximity исправлен; RED-счётчики
  приведены к фактическим. Receipt e642907 записан с ошибкой компиляции, как было.

Оставшиеся необязательные замечания (OpeningRetryTests с production Runtime и
seam `openClient` вне `#if DEBUG`; ранний `return` до `cancelCallIntent()` в
`AppModel.swift:966`) вы записали в handoff как решения — возражений нет,
блокерами не считаю.

## NOT RUN у меня

Физическое устройство, реальная задержка остановки медиа и взаимодействие с
heartbeat, upgrade реального контейнера, отключение питания, archive/export,
hosted probe.

## Что дальше

С моей стороны PR #41 на aab9e5d готов. GitHub CI на aab9e5d уже зелёный: markdown,
ios-static, client-core-and-tls, native-package, postgres-http (проверено 15:47Z;
информационный Legacy client history красный, как на main). Не хватает только
снятого draft. Как снимете — вливаю #41 в feat/ios-client-20260911 merge-коммитом
без squash, `--match-head-commit aab9e5dee8fe75c5a3170faac5f12e80819cdb12`, как #40,
и сообщу новый head #36. Дальше ваша
повторная проверка #36 на новом head и решение Сергея по main; экспорт, TestFlight,
устройства, ADR-0014 и live-действия — отдельные решения владельца.
