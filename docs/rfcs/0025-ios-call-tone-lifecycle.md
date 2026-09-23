---
status: proposed
owner: ios
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
decision_deadline: 2026-09-25
last_reviewed: 2026-09-18
---

# RFC-0025: iOS call-tone and audio-session lifecycle

## Scope and authority

Yaroslav requested fixing PR50 and preparing it for review. This proposal
records the audio/session design required by the corrections; it is not an
accepted ADR, release permission or physical-device evidence. The closed-alpha
review boundary remains ADR-0003 and proposed ADR-0014. Requirements:
REQ-CALL-002/004/005, the existing call-v2 consent/generation boundaries and
foreground-only incoming delivery. Core, wire, server, Android and persisted
state are unchanged.

## Problem

The first candidate ran player construction/play on MainActor, raced session
activation/deactivation against UI publication, ignored play's failure result
and described playAndRecord as respecting the silent switch. Its allocated
player fields and constant-only timer test did not prove playback or cleanup.

## Proposed ownership

- The call coordinator forwards the same authenticated CallPresentation directly
  to the audio-control queue before its independent MainActor UI publication.
  AppModel does not own a tone player.
- CallTones serializes policy, bounded monotonic deadlines and session ownership.
  It distinguishes requested sound from confirmed play acceptance. Neither is
  a claim that a person heard a speaker.
- QueuedCallToneOutput owns player construction/play/stop on a separate serial
  executor. Its lock protects only token/audibility metadata, not platform I/O.
  A candidate starts at volume zero and is unmuted only after play succeeds and
  its token/deadline still match. Late start/stop callbacks and timers are fenced.
- Session switches wait for player-stop acknowledgement; activation succeeds
  before a new player starts. Call/Answer awaits actual preparation through a
  cancellable single-reply gate. The audio and network setup share the existing
  ten-second intent deadline; no control is sent after a failed/expired wait.
- Capture revocation is requested on the audio-control queue independently of
  player I/O. A stopped/blocked silent keep-alive need not delay connected media
  when the call session is already active: after token invalidation the backend
  must conservatively prove it has no audible work. An audible tone does not
  receive that fast path. Camera/engine disposal remains the coordinator's job.

## Incoming versus caller audio

Incoming alerts use **ambient/default**, only while the application is active.
They do not acquire recording mode. The system silent switch applies to ambient
output. This deliberately replaces the earlier pre-Answer playAndRecord silent
keep-alive: an incoming alert does not keep an inactive application alive.
There is still no push, CallKit or background incoming-delivery promise.

Explicit Call/Answer, after microphone permission, prepares the existing
playAndRecord/voiceChat/HFP session. Ringback belongs only to outgoing ringing.
Connected state enables media and has no progress tone. Cancelling a pending
Answer can restore the still-current incoming alert, with its original deadline.

Busy is only for a caller ending from outgoing on busy/reject/timeout. It may
retain an **already-owned** caller output session for at most the two-second
policy window, with the media unit disabled and the engine being closed. It
never acquires a new input-capable session solely for a terminal beep. The PCM
pattern is exactly two seconds. Stop acknowledgement precedes session release.
Caller tones follow call routing; incoming ambient follows the system output
route instead of claiming call-HFP routing before Answer.

Haptics are UIImpactFeedback on the main actor while the current incoming player
request is accepted and the app is active. They follow OS haptic availability
and settings, **not an inferred silent-switch position**. Exact Android ringer-
mode/haptic equivalence and acoustic volume equivalence are not claimed.

## Failure, interruption and counted leases

A rejected play is not reported as started. Incoming/terminal output is released
on failure rather than retaining an allocated player as false evidence. A new
explicit call or foreground recovery can retry a missed interruption-end;
capture stays disabled until an authorized connected event. Old busy/ring
callbacks cannot release a replacement generation.

The pinned [RTCAudioSession implementation](https://github.com/webrtc-sdk/webrtc/blob/73cb8180f7258ee292878d6edd05177f41883962/sdk/objc/components/audio/RTCAudioSession.mm)
was inspected: setActive(false) decrements activationCount even when the native
operation fails, and media-services reset does not clear that count. The adapter
and policy retire the logical lease on every attempted balanced deactivation,
but report the physical failure. Reset balances an existing lease before a fresh
activation; treating activation as idempotent or blindly clearing ownership
would leak counts. Readiness/release callbacks are completed on failure too.

A wedged platform API can delay physical teardown. The code does not claim hard
real-time OS guarantees: UI/state-owner threads remain free of player I/O,
cancellation invalidates pending work and stops later unmute, and native/device
fault testing remains required. Historical review's claim that a player object
means audible output is explicitly rejected.

## Validation and disposition

Prepared app tests cover every terminal reason, exact WAV/sample boundaries,
failed activation/play, stop acknowledgement ordering, held silent versus
audible player handover, cancellation during blocked play, old timer/new call,
foreground pause/resume without extending deadlines, interruption/reset lease
balance and readiness cancellation/timeout races. Existing call-audio-session,
call-control targeting, permission, bootstrap, route/screen-policy and full app
suites remain gates. Source checks are not Swift execution.

Mac compilation, new XCTest execution, fresh simulator/bundle checks and
physical silent-switch/speaker/headset/interruption/haptic acceptance must be
reported separately. Original 4db2f8c results do not validate this revision.
The contributor's Mac results for the final head `4066f36` are recorded in the
[4066f36 receipt](../project/evidence/ios-client-20260918/mac-receipt-pr50-4066f36.md)
(added 2026-09-23). They cover compilation, the new XCTests on the simulator and
a fresh device-bundle check on the Mac. The physical acceptance items above
remain NOT RUN.
No owner architecture acceptance, merge, installation or deployment follows.
