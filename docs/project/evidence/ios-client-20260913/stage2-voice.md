# Stage 2 — call-v2 calls on real phones (NOT RUN)

Joint test of the candidate iOS client ([RFC-0021](../../../rfcs/0021-ios-client.md),
REQ-CALL-002/003) against the Android client, over
[call-v2](../../../protocol/call-v2.md).

**This test has not been run.** The scenario is written in advance; every
`Result` cell reads `NOT RUN` and changes only after the step has actually been
performed. Participants: **Yaroslav** (contributor, iPhone) and **Sergey**
(owner, Android).

**Pre-run (2026-09-13), not this test.** Before any joint session, one call was
placed from the signed Debug build on the physical iPhone (iPhone 16 Pro Max,
iOS 26.6.1) to a simulator peer on the local stand — the unchanged server
binary and a private PostgreSQL 16 on the build Mac. The call connected, with
video visible from the iPhone; the simulator has no camera, so no picture came
the other way. That run did not touch the owner's Android or the hosted server,
whether audio was actually heard was not recorded, and no screen recording,
no lock during dialling (step 11, left for this test) and no relayed call were
tried. Every `Result` cell below therefore stays `NOT RUN`.

## Preconditions

| Precondition | State |
| --- | --- |
| Stage 1 completed on the same pair of phones | not run — a solo pre-run of stage 1 steps 1, 2, 4 and the first half of 5 against the hosted server on 2026-09-13 is recorded in [stage 1](stage1-text.md); it is not a completion |
| Owner "go" for this live test, permalink recorded here | missing |
| Android build **v16 or later** — call-v2 rejects v1 call bodies, so an older build cannot call this client at all | not recorded |
| Whether the server issues TURN credentials for this test, or answers `404 turn_disabled` (the disclosed direct-ICE mode) | not recorded |

## Scenario

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| 1 | Both: applications open. Yaroslav: taps «Позвонить»; both see: the confirmation and then the ringing screen | The privacy sentence is read **before** the microphone is asked for; the microphone is requested only from this tap; Sergey's phone rings; Sergey answers and **both** hear each other | NOT RUN |
| 2 | Both: stay on that call for at least two minutes | The call survives past the 30-second silence deadline on the peer's ten-second heartbeat; audio stays intelligible in both directions | NOT RUN |
| 3 | Yaroslav: «Завершить»; both see: the call ends | Both screens return to the conversation at once; neither side is left ringing | NOT RUN |
| 4 | Sergey: calls Yaroslav; both: applications open. Yaroslav: «Ответить» | The privacy sentence stands above «Ответить» and not after it; the microphone is asked for only at that tap; both hear each other | NOT RUN |
| 5 | Sergey: hangs up | The call ends on both sides; the iPhone shows no stale call screen | NOT RUN |
| 6 | Yaroslav: during a connected call, «Выключить микрофон», then on again; Sergey: says what he hears | Sergey hears nothing while muted and hears the voice again afterwards; the call is not interrupted | NOT RUN |
| 7 | Yaroslav: during a connected call, «Громкая связь», then off | The route changes on the iPhone and the call is not interrupted; with a headset connected, the headset keeps the call | NOT RUN |
| 8 | Yaroslav: during a connected call, «Включить камеру»; both see: the video stage | The camera is requested only at this tap; Sergey sees the picture at full frame; no renegotiation happens; the negotiated video codec is recorded (H.264 or VP8) | NOT RUN |
| 9 | Sergey: turns his camera on; Yaroslav: sees it; then both turn their cameras off | Each side's camera state is announced by a `media` control and shown on the other screen; turning a camera off leaves the call running as audio | NOT RUN |
| 10 | Yaroslav: with the video stage showing, starts a screen recording on the iPhone | The video stage is covered and says «Видео скрыто: идёт запись или трансляция экрана.»; the call controls stay usable and the call is not interrupted. A **screenshot** is not refused, and the app-switcher snapshot is not covered — both are known gaps, not failures | NOT RUN |
| 11 | Yaroslav: locks the iPhone screen **while the call is still dialling**; both see: what happens next | Recorded as observed. This is the one story no simulator could run: `xcrun simctl` has no lock verb and `XCUIDevice` has no lock API | NOT RUN |
| 12 | Yaroslav: locks the iPhone screen **during a connected call**; both: keep talking, then Yaroslav unlocks | The audio continues under the lock screen on the `audio` background mode; there is no CallKit screen, because this client registers none | NOT RUN |
| 13 | Yaroslav: **locks** the iPhone and leaves the application in the background; Sergey: calls him and waits | **Expected behaviour of track A, written here in advance:** the iPhone does not ring, and Sergey's call ends by itself with `timeout` after 45 seconds. This is the foreground-only limitation, not a defect: there is no push, no PushKit and no CallKit | NOT RUN |
| 14 | Yaroslav: **closes** the application completely (swipes it out of the app switcher); Sergey: calls him and waits | The same expected `timeout` after 45 seconds at Sergey's end, and nothing at all on the iPhone | NOT RUN |
| 15 | Yaroslav: opens the application again; Sergey: calls once more | The call rings and connects normally, so the previous two steps left no stuck state | NOT RUN |
| 16 | Both: one call each way over LTE instead of Wi-Fi | Both connect; the candidate pair that carried the media is recorded (direct or relayed), and so is whether `/v2/voice/turn` issued credentials or answered `404 turn_disabled` | NOT RUN |
| 17 | Yaroslav: calls while Sergey is already on another call | Sergey's client answers busy and the iPhone shows that terminal reason rather than ringing out | NOT RUN |

## Observations to record when it runs

- The negotiated video codec on each call (H.264 or VP8) and which side offered
  it.
- Whether media was relayed or direct, and the answer `/v2/voice/turn` gave.
- The exact terminal reason and elapsed time for steps 13 and 14; they are the
  expected `timeout`, and the number is what makes the expectation checkable.
- Any audible artefact, echo or one-way audio, with the route in use at the
  time.
- Screenshots on both phones for steps 1, 8, 10 and 13, named by step number.

## What this stage does not cover

Group calls, call recording, background delivery of an incoming call, and any
system call UI. None of them exists in this client.
