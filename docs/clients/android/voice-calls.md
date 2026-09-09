---
status: draft
owner: android
last_reviewed: 2026-09-09
---

# Android voice implementation

This component implements [REQ-CALL-002–005](../../product/voice-calls.md) on the
retained native messenger. [Voice-v1](../../protocol/voice-v1.md) is the canonical
control contract; [core voice](../core/voice-calls.md) owns cryptographic parsing
and persisted state. The current source is configured as `org.paranoid.devtext`,
versionCode9, `0.0.9-voice`, API26+. The ARM64 retained-signer artifact now passes
build/signature/package/alignment gates in
[the operations record](../../operations/voice-calls-local.md).

## State and platform ownership

`SelfServiceClient` forwards a native `call_event` only after sealed state commit.
`TextEngine` retains its independent network lanes and single native state worker,
then posts immutable events to the main-handler `CallController`. The controller
owns volatile readiness slots, nonces, consent, sequences, heartbeat/time limits
and callback generations. A send completion means both durable local enqueue
and validated server acceptance, so only one heartbeat remains outstanding.

`RealtimeLoop` preserves its existing one fresh-nonce retry for a signed-session
request whose first HTTP401 may reflect a consumed nonce after a lost pooled
response. That ambiguous first rejection must not end a call. A second HTTP401,
or an authorization failure outside this existing retry path, ends local call
authority immediately. The retry does not reset call/heartbeat deadlines or add
indefinite re-attestation; later text reconnection cannot revive ended consent.
Actual pinned-TLS RED/GREEN confirms first401→fresh200 without a false call-stop
callback and revoked401→401 with one authority-loss callback, no plaintext
delivery and preserved pending bytes. On resume, an existing signed `messages`
fetch confirms readiness before the usual `events` wait. This preserves the wire
contract and strict response/commit checks; no optimistic connection is published.
The drained empty-inbox fixture improved from no authenticated callback within
3029 ms to a committed callback in 70.14 ms, not a universal latency guarantee.

The native call UI provides explicit Call/Answer permission, reject/cancel/end,
mute and speaker controls, identity trust and direct-IP disclosure. Incoming
ringing creates no microphone or PeerConnection. Connected state follows the
actual SDK callback; an ICE disconnect exposes a reconnecting state until the
bounded recovery deadline. An explicit Call/Answer intent after microphone
permission grant waits up to 10 seconds for confirmed network readiness, retaining
a generation token and the original deadline through service startup. The service
callback rechecks resumed state, generation and deadline before starting the call.
A delayed new media engine applies the current call's mute and route intent after
old disposal completes and before capture may start. The actual first-grant and deferred SDK-property
RED/GREEN checks pass; their exact code remains in final review scope. A late ready, SDK or acceptance callback cannot
restore ended consent or mutate a subsequent call generation.

`VoiceCallService` starts its microphone foreground type only from visible user
intent and granted permission, with an ongoing hangup control. Incoming
background notification requires opening the app to answer. The existing
opt-in messaging connection is not reliable Doze/force-stop delivery. Service,
permission, audio focus and disposal failures must terminate capture; physical
platform behavior remains an acceptance gate rather than a compilation claim.

`WebRtcAudioEngine` owns the WebRTC audio source/track/PeerConnection, audio
focus and communication routing. It uses the mature SDK Opus/APM path, with
supported hardware AEC/noise suppression and the library's remaining defaults.
Speaker selection, platform-managed nonspeaker routing and supported earpiece
proximity behavior restore prior audio state during cleanup. Bluetooth/headset
and acoustic effectiveness require physical-device evidence; they are not
proven by the existence of these Android APIs. If an API31+ previous communication
device disappears during a call, cleanup currently ignores a false return from
restoring that device and has no explicit fallback for that case. Physical
headset/Bluetooth unplugging restoration remains unverified and in final review
scope.

## Dependency and build

`webrtc_dependency.py` pins
`io.github.webrtc-sdk:android:150.7871.01`, Maven AAR SHA256
`0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0`.
The manual build verifies the archive and selected payloads before extracting
Java and native ARM64/x86_64 libraries. The Maven Java17-restamped artifact is
the build input; local bytecode rewriting is not used. Dependency tests reject
corrupt archives and restore a tampered extraction from verified bytes.

The upstream source revision is
`73cb8180f7258ee292878d6edd05177f41883962`; packaging tag `v150.7871.01` points to
`7b6390fb098303b31af76906bf15f7decaa4ef95`. The `webrtc-build` archive contains
build outputs plus VERSIONS/NOTICE, not proof of a reproducible selected binary.
Upstream/Maven native and Java API correspondence, exact source/license hashes,
packaged notices, ABI/alignment and retained APK signer pass actual artifact
verification. The final independent source review remains separate. [Design-review provenance](../../project/evidence/voice-calls-20260909/README.md)
records the selection and these limits. See [the retained-key build](../../../clients/android/README.md#build).

## Evidence boundaries

Actual JNI/Olm commit tests and JVM controller tests pass. Application classes
compile against Android35. Controller test ports model asynchronous media
callbacks to test authority; their counters are not decoded audio.

The separate Android libwebrtc/aiortc instrumentation harness passes actual direct
and isolated local TURN relay ICE/DTLS/Opus, decoded synthetic tone energy in both
directions, mute/unmute, capture termination and audio-state restoration through
redial. Its test control socket is distinct from the application's E2EE signaling;
the exact media SDP separately passes native encrypted-control validation. App UI
acceptance passes 14 steps, first-grant/deferred-mute corrections and actual
process restart. Final fixture5 repeats the 14-step run with corrected system-bar
insets visually inspected. The signed ARM64 artifact passes package/signature/
alignment gates; independent final code review remains pending.
Physical OPPO audio, Bluetooth, mobile handover, Doze and
force-stop remain NOT RUN. Production media uses no arbitrary public STUN/TURN;
new public relay operation needs separate reviewed authorization.
