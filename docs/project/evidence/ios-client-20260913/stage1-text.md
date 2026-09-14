# Stage 1 — identity, QR and text on real phones (NOT RUN)

Joint test of the candidate iOS client ([RFC-0021](../../../rfcs/0021-ios-client.md),
[REQ-CLIENT-001](../../../product/requirements.md), REQ-ID-005/007/008,
REQ-MSG-002/003/005) against the Android client on the hosted alpha.

**This test has not been run as a joint session.** The scenario is written in
advance; every `Result` cell reads `NOT RUN` and changes only after the step has
actually been performed by both participants together. Participants:
**Yaroslav** (contributor, iPhone 16 Pro Max on iOS 26.6.1, a direct signed
install — TestFlight is `NOT RUN`) and **Sergey** (owner, Android).

**Pre-run, 2026-09-13.** Before the joint session, Yaroslav alone exercised
steps 1, 2, 4 and the first half of step 5 on the physical iPhone against the
hosted server: the identity was created on the device, the own QR shown, the
owner's Android paired from a QR image the owner sent (scanned off a screen with
the real camera), and one text sent that the hosted server accepted — one check,
«Сохранено сервером». Delivery to the owner's Android was still pending (his
phone had not polled) and no reply exists. That is a solo pre-run, not this
test: the rows below keep `NOT RUN` and carry a note where the pre-run touched
them.

## Preconditions

| Precondition | State |
| --- | --- |
| Owner "go" for this live test, permalink recorded here | missing |
| Signed build installed on Yaroslav's iPhone | present — Release build signed with the Apple team, installed on 2026-09-13 with `xcodebuild` and `xcrun devicectl` (branch head `adb56be`); no archive, no `.ipa`, no TestFlight |
| Android build on Sergey's phone, version recorded here | not recorded |
| Hosted registrations consumed by this stage (the server has no deletion path) | 1 for the iPhone, consumed on 2026-09-13 in the pre-run, before the stage itself; the branch total is 2 (the other is the build Mac's `service-bridge` registration while diagnosing the phone's TLS failure), both under the owner's answer to RFC-0021 question 4 (no fixed budget) |

## Scenario

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 1 | Yaroslav: fresh install, opens the application, taps «Создать ID» | The identity is created and saved before any request; the welcome screen gives way to «Чаты»; the connection screen states in full that messages arrive only while the application is open | NOT RUN — pre-run 2026-09-13: done solo on the iPhone against the hosted server |
| 2 | Yaroslav: opens «Мой ID» | The contact QR is shown together with the 64-digit account; the code is dense and readable at arm's length | NOT RUN — pre-run 2026-09-13: shown solo on the iPhone |
| 3 | Sergey: scans that QR with the Android scanner; both see: the full fingerprint | Sergey compares the fingerprint aloud with what Yaroslav's screen shows and confirms «Отпечаток совпадает»; the contact appears as verified on Android | NOT RUN |
| 4 | Sergey: opens his own «Мой ID»; Yaroslav: scans it with the iPhone camera | The iPhone scanner opens in-app, decodes the dense code without leaving the application, shows the full fingerprint and requires «Отпечаток совпадает». Nothing is imported until Yaroslav confirms | NOT RUN — pre-run 2026-09-13: the owner's QR was scanned from an image he sent, off a screen, not from his phone in the room. The contact was paired, which this client does only after «Отпечаток совпадает» is tapped on the confirmation sheet (`App/ParanoID/Screens/ConfirmContact.swift`); the fingerprint itself was not read aloud against the owner's screen, which is what step 3 and this step are for |
| 5 | Yaroslav: sends the first message to Sergey; both see: the bubble on each side | One check appears on the iPhone only after the server accepted the envelope, two only after Sergey's client acknowledged it; Sergey sees the text | NOT RUN — pre-run 2026-09-13: one text sent, one check («Сохранено сервером»); delivery to Sergey's Android pending, second check not observed |
| 6 | Sergey: replies; both see: the reply | The reply appears on the iPhone while the application is open, with the same one-check/two-check meaning in reverse. No read receipt appears anywhere | NOT RUN |
| 7 | Yaroslav: closes the application completely (swipes it out of the app switcher). Sergey: sends a message. Yaroslav: waits at least one minute, then opens the application | Nothing arrives while the application is closed — there is no push and this is the documented limitation. On opening, the message arrives and its receipt leaves; Sergey's second check appears then, not before | NOT RUN |
| 8 | Yaroslav: opens the application, locks the iPhone screen without closing it, waits one minute; Sergey: sends a message; Yaroslav: unlocks | The application stays in the foreground behind the lock screen or is suspended by the system; on unlock the message is present exactly once and the connection status recovers without a duplicate bubble | NOT RUN |
| 9 | Yaroslav: switches the iPhone from Wi-Fi to LTE with the application open; both send one message each way | The lane reconnects on its own, both messages arrive exactly once, and no message is duplicated by the reconnection | NOT RUN |
| 10 | Both: exchange three messages each way on LTE | All six arrive, each with one check then two; order is preserved on both screens | NOT RUN |
| 11 | Yaroslav: relaunches the application (closes and opens it) | The history is still there after the relaunch, read from the sealed state file, with no re-pairing and no duplicate | NOT RUN |
| 12 | Yaroslav: «Заблокировать контакт»; Sergey: sends a message | The composer is disabled on the iPhone; the incoming message is acknowledged with nothing and does not appear; Sergey sees no second check | NOT RUN |
| 13 | Yaroslav: «Разблокировать контакт»; both: send one message each way | The same channel resumes: no re-pairing, the pin and the history are intact, and both messages arrive | NOT RUN |
| 14 | Yaroslav: «Переименовать» in the contact details, types a name; Sergey: sends a message | The name is shown in the dialogs list, the contacts list, the chat title and the details sheet on this iPhone only. It is never sent: Sergey sees no change | NOT RUN |
| 15 | Both: leave the applications open for ten minutes without sending anything, then Sergey sends one message | The session renews on its own and the message arrives without a manual reconnect | NOT RUN |

## Observations to record when it runs

- Android build version and iOS build version, exactly as the two screens
  report them.
- Whether each incoming message arrived before or after the iPhone screen was
  unlocked, and how long after (step 7 and step 8).
- Each hosted registration consumed, with the reason it was needed. The server
  has no deletion path.
- Any screen where a Russian caption differs from Android's wording.
- Screenshots on both phones for steps 3, 4, 5, 7 and 12, named by step number.

## What this stage does not cover

Calls are stage 2. Nothing here proves anything about audio, video, the relay,
or the behaviour of a call placed to a locked iPhone.
