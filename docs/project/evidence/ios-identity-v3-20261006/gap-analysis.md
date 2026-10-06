---
status: draft
owner: ios
last_reviewed: 2026-10-06
---

# iOS against Android v48: gap analysis

How far the iOS client is behind the Android client on `main`
`2470dca711929fb4575c75cd61578d77acdd3102` (Android `0.0.48-solana-id`,
`clients/android/AndroidManifest.xml:1`), and what could break while it
catches up. This analysis is the motivation for
[RFC-0030](../../../rfcs/0030-ios-identity-v3.md). It decides nothing.

## Method and limits

- Three independent read-only inventories at `438c79e`: Android features
  against iOS; identity v3 and what an iOS client needs; breakage risks and
  pull requests in flight.
- An adversarial pass at `62e50e4`, after PR #67 and PR #69 had merged. Each
  claim group went to one or two skeptics with different lenses (code;
  history and documents; owner authorization on GitHub), told to refute it.
  Separate agents inventoried Android v36 to v42, ran the iOS static gates,
  and looked for what everyone had missed.
- A pre-publication review of these documents: four citation checkers and
  three reviewers (governance, identity and platform security, a fresh
  reader on another model).
- Six more Android commits arrived on `main` that evening (v43 to v48). Every
  Android fact below was re-checked at `2470dca`; only Android files changed.
- The rows were checked by AI reviewers and corrected where they disagreed.
  This is AI analysis on the contributor's side: not a human review, and not
  the independent review of
  [policy item 2](../../../governance/documentation-policy.md#closed-alpha-review-exception).
- Nothing ran on a phone. The only network step was the read-only health check
  in §1. The v3 servers' builds, schemas and sponsor balance cannot be read
  from the repository and are unknown.

## Summary

| Area | State | Size for iOS | Blocks communication |
| --- | --- | --- | --- |
| A reachable server | none: the only server iOS knows did not answer | part of identity v3 | **yes** |
| Identity v3: nickname, recovery, login, a v3 server | missing | large, several pull requests | **yes** |
| The nickname directory, now the way to add contacts | missing; needs identity v3 first | medium | **yes** |
| Contact links by tap, invitations | missing | medium each | no |
| Platform items without a protected-domain decision | Dynamic Type, crash report, rotation, video presentation, ringing in silent mode, version string | small to medium | no |
| Recorded Android-only behaviour | updates, background delivery, push, notifications, lock-screen calls | not gaps | no |
| Gates | `java_deps.sh` red since 2026-09-17; the caption contract weakened by PR #69, and red on `main` since v47 until this pull request | small | no, but hides regressions |

## 1. The servers and the split

A read-only pinned health check from the build Mac at 2026-10-05T22:00:46Z,
one request per endpoint:
`curl -sS -k --max-time 10 --pinnedpubkey sha256//<base64 of the pin> https://<endpoint>/health`.

| Endpoint | Pin (prefix) | Answer |
| --- | --- | --- |
| `https://157.180.49.125:38443` (v2, the only server iOS knows) | `8aa594a9…` | connection timed out after 10 s |
| `https://157.180.49.125:38444` (production, identity v3) | `536c1544…` | `{"protocol":"paranoid-identity-v3","realtime":"signed-long-poll-v1","status":"ok"}` |
| `https://138.16.180.53:38444` (test VPS, identity v3) | `427a7046…` | the same |

One timeout is not proof of a permanent stop. Android's source records the
stop and the move:

| Fact at `b422310` | Evidence |
| --- | --- |
| The production host's identity-v3 endpoint is Android's default realm and its sponsor's target; the v2 endpoint is kept "for reference", marked "stopped 2026-10-05". | `clients/android/src/org/paranoid/text/KeyClient.java:9-14`; commit `b488331` |
| The test VPS stays a second v3 realm. | `KeyClient.java:15-18` |
| Android's sponsor calls go to the production host, while its login creates the messenger identity for the test VPS. | `clients/android-devnet/src/org/paranoid/devnet/OnboardingActivity.java:513-516`; `clients/android/src/org/paranoid/text/TextEngine.java:289-290` |
| The commits for v44, v45 and v46 change only the version code. The server-choice screen named in v44's message is not in the repository; the «Мой ID» changes named by v45 and v46 arrived with v47. | commits `e5617fe`, `07d3dc4`, `32da8f6`, `b422310` |
| v47 removes the QR, the key hash and the fingerprint from «Мой ID» and adds a nickname line that reads `solana_nick`, which nothing sets, so the line stays empty; v48 shows «Нет ника». Scanning and pasting a contact remain. | `clients/android/src/org/paranoid/text/MainActivity.java:205-208,226,583-588,956-964`; `TextEngine.java:436`; commits `b422310`, `2470dca`; open PR #70 fixes the nickname line |
| Since v30 «Начать» on a fresh install opens only the nickname onboarding; v29 still offered «Создать ID» on v2. | `MainActivity.java:163-168,927-928`; commits `fba0a34` (v29), `c6eed44` (v30) |
| The iOS Release build starts only on the v2 realm and accepts only the v2 health protocol and `/health` and `/v2/` paths. | `clients/ios/ParanoidKit/Sources/ParanoidKit/Service/Snapshot.swift:94-98,140-145`; `clients/ios/ParanoidKit/Sources/ParanoidKit/Net/Health.swift:14,44-47`; `clients/ios/ParanoidKit/Sources/ParanoidKit/Net/RealtimeTransport.swift:261` |
| A Debug build pointed at a v3 realm fails too: `404` on `/v2/registration/`, then a protocol mismatch. | `clients/ios/App/ParanoID/DebugFixture.swift:21-30,60-66`; `server/src/self_service_http.rs:176-207`; `server/src/identity_v3.rs:160-165` |
| Contacts and directory entries must share realm and pin. | `clients/core/src/contact_v2.rs:50-59`; `clients/core/src/clean_service.rs:199-216,1009-1027`; `key-protocol/src/identity_v3.rs:586-588` |

So the iOS client has no reachable server, including the contributor's iPhone,
which runs a v2 build installed on 2026-10-05. On 2026-09-30 one of the
owner's phones registered `first` and logged in on v3; the other registered a
nickname, but its first login failed with `challenge_mismatch`, fixed in v35
and not re-run (`docs/project/current-state.md`, section «Solana ID login and
sponsored nicknames on the test VPS — 2026-09-30»). No Android peer still on
v2 is recorded.

## 2. Identity v3 and what depends on it

| Android feature | Version | iOS | Evidence (Android, at `b422310`) |
| --- | --- | --- | --- |
| Onboarding: words, nickname, sponsored Devnet registration, server cards, login | v30; reworked in v37 | missing | `OnboardingActivity.java:20,440-451` |
| Recovery from words, then login with an explicit replacement of the other phone | v30+ | missing | `OnboardingActivity.java:361-409,455-486`; `clients/android-devnet/src/org/paranoid/devnet/IdentityLogin.java:71-99`. The screen asks for 12 words; Rust accepts 12 or 24 (`blockchain/solana/client/src/lib.rs:363-372`). |
| ±300 s clock tolerance on login challenges | v35 | missing | `key-protocol/src/identity_v3.rs:17-22`; commit `c9357a7` |
| The login-failure screen and error codes on failures | v34; the wording «Аккаунт создан, но вход не выполнен.» since v37 (`a31c7af`) | missing | `OnboardingActivity.java:481-485,551-558`; commit `d7eade8` |
| «Мой ID» states: no nickname, not logged in, logged in | v40 | different | `MainActivity.java:195-202,937-962`; commit `42b1fcf` |
| «Мой ID» without QR, key hash or fingerprint; a nickname line (empty in v47, «Нет ника» in v48) and a share-link prompt | v47, v48 | different: iOS keeps its QR and fingerprint (RFC-0030 question 18) | `MainActivity.java:205-208,226,956-964` |
| «Ник в Devnet»: show the words again, own-SOL registration, check a nickname, log in | v28; in the menu since v38 | missing | `clients/android-devnet/src/org/paranoid/devnet/MainActivity.java:33-49,64-93`; `MainActivity.java:322` |
| «Скопировать слова» | v39 | missing; contradicts RFC-0026, see §8 | `OnboardingActivity.java:166-171` |
| Directory search on the own server | v36 | missing | `MainActivity.java:579-590,608` |
| Verified add of a found member: core check, the Solana registry, then «Добавить @ник?» with the fingerprint | v36 | missing | `MainActivity.java:671-688`; `clients/android-devnet/src/org/paranoid/devnet/RegistrationFlow.java:28-37` |
| Visibility in search; automatic publication of the own contact card | v36 | missing | `MainActivity.java:214-224`; `clients/android/src/org/paranoid/text/RealtimeLoop.java:246-305` |
| Share and open contact links `paranoid.global/c/…` and `paranoid://c/…` | v36 | missing; iOS has no URL scheme or associated domain, and `paranoid.global` has no `apple-app-site-association` | `MainActivity.java:692-729`; `clients/android/AndroidManifest.xml:72-86`; `deploy/web/paranoid.global/.well-known/` |
| Invitations (RFC-0029, draft) | document only | not applicable yet | `docs/rfcs/0029-invite-sponsored-registration.md:1-9` |

The device side is already in the shared core and reachable from Swift
through the unchanged bridge command: `identity_credential_v3`,
`identity_device_proof_v3`, `verify_directory_entry_v1`,
`pair_directory_entry_v1` and the directory session selectors
(`clients/core/src/clean_service.rs:117-121,171-218,804-842`;
`clients/ios/bridge/src/lib.rs:27-56`), on core state version 3
(`clients/core/src/lib.rs:448-453`). The directory operations reach an iPhone
only after the bridge library is rebuilt on a current base; the contributor's
phone runs `438c79e`. The owner side lives in `blockchain/solana/client`,
which Android ships as a separate JNI library, and Android's live chain checks
are Java (`DevnetRpc.java:42,48-56`; `ProgramPin.java:20-35`); see RFC-0030
and [the feasibility evidence](feasibility-mac.md).

A directory entry must be checked against the finalized Solana registry by the
caller before pairing (`clients/core/src/clean_service.rs:176-180`), so the
directory on iOS needs the same Devnet RPC as registration.

## 3. Gaps that need no identity decision

| Gap | Evidence | Size |
| --- | --- | --- |
| **Dynamic Type.** 137 fixed `.font(.system(size:))` calls in 20 files; no `@ScaledMetric`, `UIFontMetrics` or text styles anywhere in the client. Only system alerts, the navigation title and the share sheet scale. Android sizes text with `setTextSize`, in `sp`. | grep over `clients/ios/App/ParanoID`; `clients/ios/App/ParanoID/Screens/CallScreen.swift:76-92`; `MainActivity.java:1017` | M |
| **Crash report.** Android shows «Отчёт о завершении приложения» on the next launch, with a copy button (Java exceptions; native exits from API 30). iOS has no crash reporting and no MetricKit, and this is not listed as a difference. | `clients/android/src/org/paranoid/text/CrashLog.java:15-29,45-76`; `MainActivity.java:117-126`; commits `d1c094f`, `026096f` | M |
| **Rotation.** iOS is portrait-only and iPhone-only, recorded as a setting but not as a difference from Android. Android's main screen rotates and keeps its state; its onboarding, Devnet and QR screens are portrait-locked. | `clients/ios/App/ParanoID/Info.plist:51-54`; `clients/ios/App/ParanoID.xcodeproj/project.pbxproj:378,435`; `clients/ios/README.md:463-464`; `clients/android/AndroidManifest.xml:67-70`; `MainActivity.java:91` | M |
| **Video presentation.** Android mirrors the local preview and fits the remote frame; iOS fills both and does not mirror, so the remote frame is cropped. | `MainActivity.java:995-996`; `clients/ios/App/ParanoID/Screens/CallScreen.swift:332-335` | S |
| **Ringing in silent mode.** Android plays the system ringtone and vibrates by ringer mode; iOS plays a synthesized tone in the `ambient` category, silent with the switch, plus haptics. Recorded in RFC-0025 (proposed). | `clients/android/src/org/paranoid/text/CallTones.java:16-21,53-84`; `clients/ios/App/ParanoID/Voice/AudioSessionController.swift:10,39` | S, owner's choice |
| **Version string.** Android shows `0.0.48-solana-id`; iOS always shows `0.0.1 (1)`, fixed on purpose and pinned by `test_app_bundle.py`. | `MainActivity.java:335-338`; `clients/ios/App/ParanoID/Strings.swift:36-43`; `project.pbxproj:446,454,466,474` | S |
| **v38 texts.** Android removed «Личные диалоги» and simplified «Мой ID»; iOS still shows the v37 texts. | commit `a66db18`; `clients/ios/App/ParanoID/Strings.swift:109` | S |
| **A contact or link from another server.** iOS says «Не удалось добавить контакт (contact_binding_mismatch).», and a pasted Android link gets «Это не контакт ParanoID…». Android promises «Повторим подключение автоматически» for a refusal that never succeeds. The `/c/` landing page tells an iPhone user to ask for an installation file. | `clients/ios/ParanoidKit/Sources/ParanoidKit/Presentation/ContactFlowError.swift:40-50,60-82,96-118`; `TextEngine.java:301-303,394`; `deploy/web/paranoid.global/c/index.html:21` | S |

## 4. Recorded Android-only behaviour, not gaps

In-app updates, the background connection with its watchdog, FCM push wake,
system notifications, the incoming call over the lock screen, and the
ongoing-call notification. They are recorded as differences by design in
`docs/clients/ios/README.md:67-73`, `docs/rfcs/0021-ios-client.md:177-181`,
`docs/decisions/0014-ios-client.md:162-166` and
`docs/project/current-state.md`. iOS has no `UNUserNotificationCenter`,
PushKit, CallKit or background task. Two tests forbid the push, notification
and background-task symbols
(`clients/ios/App/ParanoIDTests/ConnectivityRestartTests.swift:388-395`;
`clients/ios/ParanoidKit/Tests/ParanoidKitTests/LifecycleTests.swift:274-276`);
no test forbids CallKit. APNs is drafted in PR #58.

Since v42 Android also fetches updates from `paranoid.global` with system CA
trust (`clients/android/src/org/paranoid/text/UpdateClient.java:10-28`). That
is outside iOS scope and is listed in §8.

## 5. Where iOS is ahead

The new-message counts, divider and «↓» button (in memory only); «Чаты»
ordered by the last message, with missed calls in red; «Контакты» in
alphabetical order with a collapsed «Заблокированные (N)»; the fingerprint
in groups of eight; the bubble that fits its text, a byte counter only near
the limit and trimmed sends; the call screen that closes by itself,
«Перезвонить» and the bar that returns to a running call; the
frozen-storage screen; the video cover during screen capture; and the
foreground-only disclosure on «Мой ID». All are proposed and await the owner.
A catch-up must not delete them by copying Android screens.

## 6. Gates and breakage risks

- **The iOS static gates pass** at `62e50e4`, locally and in CI: the iOS
  target check, clippy, the bridge ABI tests (6 of 6), the 14 Python
  contracts, notices (30 tests) and the boundary scope tests. The bridge lock
  still matches the core lock.
- **The caption contract is red on `main` from v47 on.** v47 and v48 removed
  six captions that iOS still shows, and `test_ui_contract.py` requires an
  Android-origin caption to exist in Android. Those pushes touched only
  Android paths, so the iOS workflow did not run on them. This pull request
  attributes the six captions to iOS.
- **`clients/ios/java_deps.sh` fails**, and has failed on every full
  `build.sh` run since 2026-09-17. Its step 3 stops at
  `clients/android/src/org/paranoid/text/CallLog.java is named 0 times`
  (`java_deps.sh:142-153`). `CallLog.java` (PR #45), `ReceiptHint.java` and
  `ReceiptMark.java` (PR #51) are not in its lists (`:68-83`). All three import
  `android.*`, so they belong in `ANDROID_ONLY`. A diagnostic copy with only
  those three names added passed all six steps offline. No workflow runs the
  script, so CI does not see it. The iOS–Android cross-check
  (`test_android_compatibility.py`) depends on it and was last recorded as
  passing on 2026-09-13.
- **PR #69 weakened the caption contract.** It removed ten Android captions
  that iOS still shows from the checked set: nine became comments, which
  `test_ui_contract.py` skips (`clients/ios/test/captions.txt:63,70,74,79-83,149`),
  and «Поделитесь контактом» was replaced by a «Мой ID» line (`:73`).
- **PR #69 inverted a check.** `clients/ios/test_ui_contract.py:894-899` now
  requires Android's call window to lack `FLAG_SECURE`. The iOS cover checks
  (`:900-905`) are unchanged. iOS documents still describe Android's call
  window as protected.
- **The iOS workflow's path filter.** `.github/workflows/ios.yml:4,7` covers
  `clients/ios/**`, `clients/core/**`, `key-protocol/**`, `docs/**`,
  `CHANGELOG.md` and `README.md`, not `clients/android*/**` or `blockchain/**`.
  A change to the Android sources the iOS gates read is caught only when the
  same or a later pull request also touches a filtered path.
- **Server transport is red on `main`** on every push since 2026-09-09
  (`366ceed`), when its informational legacy-history job was added; the other
  jobs pass. Out of iOS scope, recorded so that it is not a surprise.
- **The wire format is closed.** `PlainV1` has eight fields with
  `deny_unknown_fields` and the kinds `text`, `receipt` and `call`
  (`clients/core/src/clean_service.rs:78-108`). An unknown kind gives
  `unsupported_message`, an extra field `invalid_plaintext`, and a foreign
  context `context_mismatch`; all three are recorded as rejected, the cursor
  moves on, and no receipt is sent (`:596-605,715-743`). These formats did not
  change since 2026-09-12, so an iOS client on the same server reads Android
  content.
- **A new v3 error.** Sending to a peer that replaced its phone answers
  `409 recipient_retired` (`server/src/self_service_messages.rs:72-87`). No
  client handles it; both defer every `409` and retry.
- **The v3 schema.** PR #67 changed `server/identity-v3-schema.sql`, which
  initializes only an empty database (`server/src/identity_v3.rs:83-87`). PR
  #67's description says the test VPS's database was re-created and the
  server updated; this is a pull-request statement, not repository evidence.

## 7. Pull requests in flight

| PR | State | Relevance |
| --- | --- | --- |
| #58 (iOS APNs push RFC, docs only) | open; an APPROVED review from `goryanya-deploy[bot]`, which is automation, not an owner approval | Its `0029-ios-background-delivery.md` collides with `main`'s RFC-0029; it renumbers when merged. Its own text says it must be revisited against identity v3 before any implementation on v3. |
| #62 (iOS refusals) | draft, conflicting, base `438c79e` | Touches `AppModel.swift`, `Chat.swift`, `Strings.swift`, `captions.txt` and `test_ui_contract.py`, the same files a catch-up touches. Its Swift changed after its Mac receipt on `e534ee6`, so it needs `main` merged in and a new exact-head receipt. |
| #68 (Android onboarding v37) | draft | Superseded: its patch is identical to `a31c7af`, the first commit of PR #69 (same `git patch-id`). |

## 8. Documentation drift (reported)

Under `AGENTS.md:49-50` these are reported for the owner and his agents:

1. Commits `b488331` to `2470dca` were pushed to `main` without pull
   requests. They point Android's default realm and sponsor at the production
   host's identity v3, while its login stays on the test VPS, and mark v2
   stopped; `docs/` records neither, and no owner permalink authorizes them.
   The server-choice screen named in v44's message is not in the repository.
2. v47 removes the contact QR and fingerprint from «Мой ID», citing an owner
   decision of 2026-10-05 without a permalink, while REQ-ID-007 asks for
   verified QR bindings (`docs/product/requirements.md:34`). The direction
   relayed by the contributor on 2026-10-06 is to remove QR on both clients
   and add contacts by nickname; REQ-ID-007 would then need amending
   (RFC-0030 question 18).
3. `docs/project/current-state.md` and `docs/security/threat-model.md` called
   PR #67 a draft that was not merged; this pull request corrects both
   sentences. Neither `current-state.md` nor
   `CHANGELOG.md` records Android v37 to v47.
4. `docs/rfcs/README.md` had no entries for RFC-0028 and RFC-0029; this pull
   request adds them. Its RFC-0027 line still says "no implementation or
   deployment"; PR #58 carries that correction. RFC-0028 itself still says
   the directory is not merged (`docs/rfcs/0028-server-directory-and-links.md:111`).
5. `docs/protocol/identity-login-v3.md:14-22` says Android login is not
   implemented and that the only server mode is `identity-v3-local`.
6. The words screens: RFC-0026:48-49 and 177-181 require screenshot
   protection and exclude the clipboard, and `docs/security/threat-model.md`
   (section «Fresh Solana Devnet identity boundary») names `FLAG_SECURE` on
   the words screens as the only mitigation. Android clears the flag on its onboarding
   screens, adds a copy button and still promises protection on screen
   (`OnboardingActivity.java:136,365,604-607`); the «Ник в Devnet» dialogs
   still set it (`clients/android-devnet/src/org/paranoid/devnet/MainActivity.java:66,70`).
7. PR #69 moved Android updates to system CA trust at `paranoid.global`
   without an RFC; `docs/protocol/identity-login-v3.md:315` and
   `docs/rfcs/0013-user-triggered-android-updates.md:44,102` describe a pinned
   origin.
8. RFC-0029 is written in Russian, while English is canonical
   (`docs/governance/documentation-policy.md:267-270`), and its links carry a
   16-hex prefix of the pin, against the full-pin trust model.
9. The repository is public (`gh api repos/GOTD-GLOBAL/ParanoID`: `public`),
   while `docs/project/current-state.md` («The new repository is private») and
   `docs/clients/ios/export-compliance.md:44` describe it as private.

RFC-0030 lists fourteen discrepancies that shape its design. Its items 1, 8
and 14 repeat items 6, 5 and 2 above, items 9 and 13 overlap item 1, and item
11 is §9 item 1.

## 9. Android defects to file

Found while comparing; each is an Android issue for the owner's agents, not an
iOS gap:

1. `409 sponsor_used` is shown as a taken name
   (`OnboardingActivity.java:304-305`); it means the key has tried three
   distinct names through this server process (`server/src/sponsor.rs:210-219`).
2. «Временный сбой» computes the address and the balance and hides them
   (`OnboardingActivity.java:338-358`).
3. The recovery screen asks for 12 words, though 24-word identities remain
   recoverable (`OnboardingActivity.java:365`; `blockchain/solana/client/src/lib.rs:363-372`).
4. «Мой ID» reads its nickname from `solana_nick`, which nothing sets; the
   view carries `directory_name` (`MainActivity.java:956-964`;
   `TextEngine.java:436`). Open PR #70 fixes it.
5. A refused contact promises «Повторим подключение автоматически»
   (`TextEngine.java:394`).
6. The login intent is not persisted, and the replacement dialog omits the
   limits and the peer-cap disclosure (RFC-0030 discrepancies 2 and 3).
7. No client handles `409 recipient_retired`.
8. `DevnetWork.java:19` refers to a «Создать ID для входа через Solana» button
   removed in v30, and the «Ник в Devnet» header still says chats use the
   previous ID (`clients/android-devnet/src/org/paranoid/devnet/MainActivity.java:33`).
9. The words go to the clipboard as a plain clip, and `FLAG_SECURE` is cleared
   while the words are shown or typed (`OnboardingActivity.java:166-171,604-607`),
   although the screens promise protection. If the owner keeps the copy
   action, the clip can be marked sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`,
   API 33 and later) and cleared after a short time; if the recorded rule
   stands, the flag returns on those screens (§8 item 6).

## 10. Questions for the owner beyond RFC-0030

- Is the v2 service stopped for good? No decision is recorded. What an
  existing v2 install shows meanwhile is RFC-0030 question 9.
- The state of the v3 server that iOS does not choose; the chosen one is
  RFC-0030 question 14.
- Should RFC-0028's disposition (deadline 2026-10-07) take iOS into account,
  now that the directory replaces QR?
