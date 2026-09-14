---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# iOS client: calls (call-v2 audio and camera video)

Component documentation for the call half of the candidate iOS client of
[REQ-CLIENT-001](../../product/requirements.md) and REQ-CALL-002/003, proposed
in [RFC-0021](../../rfcs/0021-ios-client.md) and recorded as
[proposed ADR-0014](../../decisions/0014-ios-client.md). It describes what the
code does; what was actually run is [verification.md](verification.md), and
each rule is traced in [protocol-sources.md](protocol-sources.md).

## The contract this client speaks: call-v2, not voice v1

RFC-0021 was written against [voice v1](../../protocol/voice-v1.md) with one
`m=audio` section. Between that draft and this client the owner requested video
calls, and the branch merged with a `main` that had already moved: the call
contract is now [call-v2](../../protocol/call-v2.md)
([RFC-0019](../../rfcs/0019-video-calls.md),
[proposed ADR-0013](../../decisions/0013-video-calls.md)). Everything of voice
v1 — authentication, delivery, freshness, consent, heartbeat, relay
authorization, resource limits — stays in force; this client implements the
deltas rather than the superseded shape:

- `v` is the integer **2** and a body has fifteen fields, the fourteen of v1
  plus a boolean `video`. A fourteen-member v1 body is refused as
  `invalid_request` before validation. **There is no mixed v1/v2 call**; that
  is the owner-accepted alpha break call-v2 declares, and it is why this client
  can never talk to an Android build older than v16.
- The informative `kind: "media"` control announces the sender's own camera
  state. It grants no media authority: the receiving interface shows what the
  peer *claims*, and frames come only from the authenticated DTLS-SRTP
  transport. A forged `media` cannot open a camera.
- A complete description is **two media sections, `m=audio` then `m=video`**,
  both `UDP/TLS/RTP/SAVPF` and both `a=sendrecv`, bundled on the audio
  section's single fingerprint and ICE context. Camera on and off is a
  track-enable flag plus a `media` control, **never** a renegotiation; trickle
  and renegotiation stay rejected.
- Video payload types map only to `H264/90000`, `VP8/90000` and the
  `rtx`/`red`/`ulpfec`/`flexfec-03` helpers, and at least one of H.264 or VP8
  is mandatory. This client offers H.264 first (hardware, constrained
  baseline) and VP8 as the fallback, the owner's decision of 2026-09-11. VP9
  and AV1 exist in this libwebrtc build and are dropped in configuration, not
  in text.

### The frame budget, and why the cap is 9000 bytes

call-v2 raises the core's `MAX_SDP` to 12288 bytes. That is not the reachable
bound: a `call` control travels inside one frame2 envelope, and after Olm and
Base64 overhead the measured ceiling of that envelope is **10040 bytes**. This
client therefore checks a description against `SdpExtract.maxSdpBytes` = **9000
bytes** before handing it to the core, and refuses anything larger instead of
rewriting it — a description that does not fit is a configuration bug on this
side. Measured on the simulator on 2026-09-13, the offer is 3768 bytes of that
cap (93 lines, 6 candidates) and the answer 3664 bytes, so the client runs at
roughly 40 % of its own budget.

## Call controller

`ParanoidKit/Voice/CallController.swift` is the volatile controller, written to
the same state machine as Android's `CallController.java` and holding nothing
across a process restart. The core is clock-free by design, so every deadline
is this client's: a 45-second ring and negotiation window, 10-second ICE
recovery, a heartbeat every 10 seconds with at most one outstanding and
numbered from `seq` 2, 30 seconds of silence terminating a call, a 900-second
maximum, a ±5-second tolerance on a received control's wall clock, the knock
ceilings (6 per peer per minute, 24 globally, at most one live call) and the
bounded table of terminal reasons with the `end` each path does or does not
send.

`CallCoordinator` is the call-shaped half of Android's `TextEngine` in one
place: it lives on the state owner's serial queue with a
`precondition(owner.isOnOwner)` in every member, which is Android's "controller,
interface and SDK callbacks share one thread" expressed with this client's
thread. Each control is enqueued as one `send_call_v1` and resolves only when
the server's acceptance is durable.

### Call-targeted controls (C1 correction candidate)

End, explicit Reject/Hangup, Mute and Speaker carry original call ID/generation
and validate them in CallController before mutation, as Answer already does.
The UI captures its presentation before scheduling work; the owner check is
still required even if the UI refreshes before that work executes. Legacy
synchronous owner-local overloads are not used across production UI hops.
[Call-control handoff](call-controls-handoff.md) records held-dispatch tests,
old-tree behavioral RED and the executed dad2f7d Mac receipt, applicable to the
identical runtime/tests/workflows integrated in 96298cd. This changes no wire
contract, media consent rule, state schema or architecture status.

### Review corrections (2026-09-14 candidate)

Answer permission results, including refusal, carry the presented call ID and
generation through the final owner hop. A stale action cannot answer or reject
a replacement call. Confirmed storage freeze synchronously ends call authority
on that same owner before the failed operation returns, not on a later tick.
Terminal cleanup cancels only that call's pending TURN request; cancellation is
sticky before the actor hop and cannot cancel a replacement request.
Proximity blanking is disabled for local **or remote** video.

These are candidate corrections to existing call-v2/voice-v1/voice-turn-v1
contracts, not wire changes. New regression execution and Mac commands are in
[review-integration-handoff.md](review-integration-handoff.md); previous device
receipts do not prove the new interleavings.

## Media engine

`App/ParanoID/Voice/WebRtcAudioEngine.swift` is the media of one call: one
`RTCPeerConnection` (unified plan, max-bundle, RTCP mux required, TCP
candidates disabled, gather-once, candidate pool 0), one audio track with echo
cancellation, gain control and noise suppression, and one video track that
exists from the first description and stays **disabled, with no capture session
at all**, until an explicit camera toggle. Codec policy is applied through
`RTCRtpTransceiver.setCodecPreferences`, never to finished SDP text.

With a validated TURN credential the connection is `iceTransportPolicy = .relay`
and carries exactly the two issued URLs; without one it carries **no ICE server
at all**, because this client has no STUN server and asks no third party where
it lives.

The local description is published **exactly once** per call by
`PublicationGate`: the direct lane publishes when gather-once reports
`complete`; the relay lane publishes once the first usable relay candidate
exists (component 1, UDP, `typ relay`, a literal IPv4 address) after a 500 ms
coalescing window, or at once if gathering completes first, and publishes
nothing without such a candidate even when gathering completes — the
controller's 45-second window is what ends that attempt. Both lanes require at
least one `a=candidate:` line, at most 9000 bytes and the call-v2 shape.

## Relay credentials

`VoiceRelayLane` asks `GET /v2/voice/turn` over the signed session and
validates the answer exactly as [voice TURN v1](../../protocol/voice-turn-v1.md)
demands: six fields, no duplicate and no unknown name, `v` 1, `ttl` 1200, the
two literal `turn:` URLs on the host of the **retained** origin so no response
can move media to another host or ask for a DNS lookup, and a remaining
lifetime of 1000–1205 s re-checked on the monotonic clock immediately before
the peer connection is created. Credentials are volatile: the type is not
`Codable`, its description is `VoiceRelayConfig[redacted]` and it never reaches
the snapshot.

A live session is required and is never downgraded on failure. A valid
authenticated `404 turn_disabled` from the pinned origin is the **only** answer
that permits the pre-disclosed direct-ICE mode; a TLS failure, a timeout, a
malformed 200 or a relay failure does not. That is the owner's answer to
RFC-0021 question 5, recorded by the owner's agents in
[issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27).

## Consent and the audio session

The microphone is requested **only** from an explicit `Позвонить` or `Ответить`
and never on knock, ready or ring. The privacy sentence stands above
`Ответить` while the call is ringing and is the message of the outgoing
confirmation, so it is read before a microphone is asked for and never after. A
refused microphone cancels the intent, tells the peer only when it was an
Answer for the call the dialog was raised for, and shows the Settings hint.

`AudioSessionController` owns the one `AVAudioSession` of the process, which is
the part of Android's engine that iOS keeps outside libwebrtc. A call needs the
session running **before there is any media at all**, because the `audio`
background mode holds nothing without one. libwebrtc is put into manual audio
with the audio unit off, `.playAndRecord` / `.voiceChat` / `.allowBluetoothHFP`
is activated, and one silent looped WAVE of zeroes keeps it alive; only
`connected` hands the audio unit to libwebrtc and stops the loop. There is **no
ringtone**: Android rings from a background notification and this client has no
background.

`Громкая связь` is `overrideOutputAudioPort(.speaker)` and yields to a wired or
Bluetooth headset already carrying the call. The proximity sensor runs only
while the call is connected, the earpiece has it and **this device's** camera is
off — Android's `!speaker && connected && !videoEnabled` — so a ringing call
never blanks the screen. One difference is deliberate and written down in the
source: Android releases the sensor for the length of a `disconnected`
transition and this client keeps it through a reconnection. The screen stays
awake while **either** camera is on.

The camera is opened by `Включить камеру` or an explicit video-call intent and
by nothing else. A refusal never ends a call: the video section was negotiated
`a=sendrecv` and stays `a=sendrecv`, carrying no frames, while a `media`
control tells the peer what this camera is doing.

## Screen capture: what this client cannot match

Android puts `FLAG_SECURE` on the call window and on no other
(`MainActivity.java:478`, Android v16), which takes that window out of
screenshots, screen recordings and mirroring. **iOS has no equivalent flag**
and no way to give a recorder different pixels from the ones the user sees.
This client does the one thing the platform allows: while `UIScreen.isCaptured`
reports a screen recording, AirPlay or a wired mirror, the video stage is
covered with «Видео скрыто: идёт запись или трансляция экрана.» — covered
rather than removed, so the renderers stay attached to their tracks — and the
controls are left reachable, because hiding them would take the call away from
the person on it.

Two gaps remain, recorded here rather than left to be discovered:

- a **screenshot** cannot be refused on iOS (there is no API; a client only
  learns afterwards);
- the **app-switcher snapshot** the system takes as the application leaves the
  screen is not covered either.

Neither is parity with Android, and neither is claimed as such. That a cover
actually appears when a real recording starts is owner evidence for
`stage2-voice.md`; no simulator can start a screen recording, and none was
started on the physical iPhone of 2026-09-13 or in the joint session of
2026-09-14 either.

## Dependency

`WebRTC.xcframework` `150.7871.01`, the same upstream release line as the
Android AAR, pinned by archive and per-slice digests, verified before
extraction, with its licence text bundled into
`THIRD_PARTY_NOTICES.txt`. Nothing is downloaded at runtime, and the bundle
gate weighs the embedded framework against the pinned slice.

## Status

Two simulators have placed and answered calls in both directions over direct
ICE on the local stand, with about 2300 RTP packets per side per call. That is
`CLAIMED`, not `SHOWN`: two applications on one Mac negotiated, connected and
carried packets to each other; no audio was decoded to a speaker, no camera saw
a face and nothing crossed a real network.

On 2026-09-13 a signed Debug build on a physical iPhone (iPhone 16 Pro Max,
iOS 26.6.1) placed one call to a simulator on the same local stand, reached
over the Mac's LAN address: the call connected, with video visible from the
iPhone; the simulator has no camera, so video went one way only. Whether audio
was actually heard is not recorded in that evidence and is not claimed here.
That is one phone against the contributor's stand, not the joint test: screen
lock during dialling, a real screen recording over the call stage and any
relayed call were not run on the device either.

On 2026-09-14 the owner called this client from his Android on the hosted
alpha and the contributor answered on the signed Release build of `adb56be`
(iPhone 16 Pro Max, iOS 26.6.1): they spoke, so audio carried both ways, and
both sides then turned their cameras on and each saw the other. That is the
first call this client has carried against the Android client rather than a
simulator, and the first picture it has received from a real camera over
call-v2; the Android build was therefore v16 or later, because call-v2 refuses
a v1 body, though the exact version was not asked for.

The session was unscheduled, so no owner "go" permalink exists for it, and the
contributor is the only participant this record has: those results are
`SHOWN (joint, reported)` — his report given immediately afterwards, not an
observation by whoever writes this file and not a recording. Everything the
report does not cover stays `NOT RUN`, and that is most of the stage: the
outgoing direction, this client dialling an Android, has been exercised only
against a simulator on the local stand, and no duration, hang-up, mute,
speaker, screen recording, lock during dialling or during a call, background
or closed-application call, call over LTE or busy peer was reported.
REQ-CALL-002/003 therefore still need the rest of the joint test on physical
phones, which is
[stage2-voice.md](../../project/evidence/ios-client-20260913/stage2-voice.md)
and is `PARTLY RUN`.
