---
status: draft
owner: ios
last_reviewed: 2026-09-18
---

# PR50 audio lifecycle correction: Mac handoff

This candidate follows review of `4db2f8c`. The original contributor's 68/0 app,
12/12 tone tests and 362/0 package receipt is historical evidence, not a native
result for this rewrite. Yaroslav requested implementation; merge, deployment,
physical-device installation and ADR acceptance are not part of this task.

## Current disposition after contributor Mac execution

Update recorded 2026-09-23: Yaroslav ran the native checks this handoff requests
on exact `4066f36`, and they are recorded in the
[4066f36 Mac receipt](../../project/evidence/ios-client-20260918/mac-receipt-pr50-4066f36.md).
The five focused suites passed 42/0. The app target without Keychain passed 90/0
and the ad-hoc-signed Keychain suite 11/0. ParanoidKit passed 362/0. A freshly
built device bundle passed 23 checks with 1 skipped, and all 16 ios-static Python
gates were green. These are contributor results quoted in the owner's merge-gate
review, not coordinator execution. PR50 merged as `02baeb2`. At main `c735f94`
the iOS tree is still byte-identical to `4066f36`. The statements below that nothing is
claimed passing describe the coordinator's Linux host and are historical. The
**Important runtime cases** below remain NOT RUN on a physical device, including
audibility, the silent switch, speaker/headset routing, haptics and real
interruptions.

## What changed

- Player creation/play/stop moved from MainActor into QueuedCallToneOutput.
  Generation and monotonic deadline checks surround startup; play starts muted,
  its Bool result matters, and cancelled work cannot later claim success.
- Session policy and tones are driven together by the coordinator's ordered
  presentation on the audio-control queue, not by an independent UI callback.
  Switching sessions waits for player-stop acknowledgement. Capture revocation
  does not wait for player I/O. An already-active connected session can bypass
  a held silent player only after token invalidation and the conservative
  audible-work fence; audible ringback must stop first.
- Incoming is active-app ambient (system silent policy, no recording category).
  Explicit Call/Answer uses voiceChat/HFP; a terminal busy tail can retain only
  an already-owned caller route, with capture off, for its two-second budget.
  The old incoming background keep-alive is intentionally not retained.
- AudioPreparationReply arbitrates readiness, timeout and cancellation once.
  AppModel awaits activation before the first control and shares the existing
  setup deadline with network readiness. Late replies cannot resume a cancelled
  continuation or allow a control after the deadline.
- Failed SDK deactivation retires the logical lease even on failure. This was
  checked against pinned RTCAudioSession.mm, not guessed: the SDK decrements
  activationCount regardless of native deactivation success. Media reset keeps
  that count, so refresh balances the retained lease before reacquiring.
- Interruption BEGIN marks the session for refresh even if its stop-ACK apply
  is superseded by resume/foreground/new-intent work. Tests assert new event
  deltas, not the presence of an activation from before the interruption.
- Exact busy duration, real deadline expiry, failed play/activation, stale
  callbacks and completion cleanup replace allocated-player/constant-only tests.

[RFC-0025](../../rfcs/0025-ios-call-tone-lifecycle.md) and the threat delta record
policy changes and limitations. Additional native/physical evidence is required;
the proposal is not accepted architecture.

## Local checks versus native checks

The Python lifecycle fences were observed RED before the relevant fixes, then
GREEN. The full Linux source/pin/notices set passed, including the new lifecycle
fences, UI contracts, freeze/open and call-control targeting. Independent source
review identified the counted-lease and coalesced-interruption cases; a further
closure review marked its remaining B-INT finding CLOSED after the sticky
refresh flag and event-delta regressions. A terminal activation guard additionally
prevents an interrupted/reset busy tail from acquiring a new session.
No Swift compiler, XCTest or Xcode execution is available on the coordinator's
Linux host. New app tests are code prepared for Mac, NOT claimed passing here.

Run the following **on the exact handed-off commit**, in an isolated worktree,
after the normal core/framework preparation for device/simulator/macOS. Do not
reuse a prior default `out/ParanoID.app` as evidence for this source.

```sh
python3 clients/ios/notices.py --offline
python3 clients/ios/test_notices.py
cd clients/ios/ParanoidKit && swift test
```

From the repository root, focused app tests:

```sh
cd clients/ios
bash toolchain.sh bash -c \
  "xcodebuild test -project App/ParanoID.xcodeproj -scheme ParanoID \
   -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
   -derivedDataPath out/DerivedData-tone-review CODE_SIGNING_ALLOWED=NO \
   -only-testing:ParanoIDTests/CallTonesTests \
   -only-testing:ParanoIDTests/CallTonePlaybackTests \
   -only-testing:ParanoIDTests/AudioPreparationReplyTests \
   -only-testing:ParanoIDTests/CallAudioSessionTests \
   -only-testing:ParanoIDTests/CallScreenPolicyRegressionTests"
```

Then the full app target (excluding Keychain for the unsigned run), the separate
ad-hoc-signed Keychain suite, and a fresh simulator/device bundle check using
its explicit path. Preserve failures as well as successful reruns.

## Important runtime cases

- incoming with the silent switch, app inactive/active, wired/Bluetooth routing;
- answer after interruption, missing interruption-end, media-services reset;
- outgoing ringback -> connected -> end, and busy/reject/timeout tails;
- cancel while player construction/play is held, then a replacement call;
- stale busy/ring deadline must not stop a new call;
- no capture before authorized connection or during terminal busy output;
- full two-party audio remains usable while the silent keep-alive backend is slow.

The fake-port and held-player tests verify application ordering, not acoustic
output, real OS interruption timing or hardware mute behavior. A physical run
needs its own explicit authorization; no server operation follows from this PR.
