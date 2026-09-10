---
status: proposed
owner: operations
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice relay: local proof and bounded deployment request

The issuer, strict Android credential client and isolated offline coturn package
are implemented locally for [REQ-CALL-006](../product/voice-relay.md). The server
foundation is [draft PR21](https://github.com/GOTD-GLOBAL/ParanoID/pull/21);
client [draft PR20](https://github.com/GOTD-GLOBAL/ParanoID/pull/20) depends on it.
[Voice TURN v1](../protocol/voice-turn-v1.md) owns the exact API, quotas and privacy
contract. [The package runbook](../../deploy/turn/README.md) owns the concrete
file/unit/secret/network proposal and rollback. Do not use the earlier direct-only
checkpoint below as evidence of the new issuer or public deployment readiness.

Fresh design review passed with corrections. Issuer, client HTTPS/JNI and offline
package checks pass; strict full-app relay integration and final review are still
being completed. Retained-allocation expiry/race/drain and ACL packet tests are
NOT RUN after a platform worker rejection. No rejected action was retried.
Public deployment remains unauthorized and blocked on those missing gates.

## Executed local scope

The owned Android 35 emulator and aiortc 1.15.0 exchanged decoded 880 Hz and
440 Hz tones through coturn 4.18.0. The selected Android candidate was `relay`.
Mute/unmute, continued reverse audio, microphone stop, audio-route restoration,
and acknowledged close followed by a fresh call/cancel passed. The sanitized
[media evidence](../project/evidence/voice-calls-20260909/README.md) records
measurements and their limits.

The fixture listened only at `127.0.0.1:34781/TCP`; relay sockets used
`127.0.0.1:40000-40015/UDP`. An owned emulator `adb reverse` connection reached
the TCP listener. Synthetic HMAC credentials expired after 600 seconds. The
fixture allowed loopback peers for this test, denied all other IPv4 peers, used
no third-party STUN/TURN, and stopped after testing. No live host, firewall, DNS,
TLS pin, messaging service, neighboring service, or production DB changed.

Source release: [coturn 4.18.0](https://github.com/coturn/coturn/releases/tag/4.18.0).
Downloaded source archive SHA256:
`28d55294ac596fbd129b293a85e7bb1c5dc4bd15b7fb55c500f355149e5f4e28`.
The local build used extracted build dependencies without installing system
packages. Exact build logs and dependency hashes remain in the private evidence
directory `voice-calls-media-discovery-20260909T220410Z/coturn`.

## Reproduce locally

Use an explicitly owned emulator with audio enabled and an existing authorized
signer. The fixture builder requires the same `ANDROID_SDK_ROOT`,
`PARANOID_ANDROID_KEYSTORE` and `PARANOID_ANDROID_KS_PASSWORD` environment as the
application build. It generates separate x86_64 lab and instrumentation APKs;
it does not install anything or modify the application package.

```sh
python3 clients/android/build_voice_media_fixture.py
```

Install the resulting `clients/android/out/voice-media-fixture/target.apk` and
`test.apk` only on that owned emulator. Grant the lab's `RECORD_AUDIO` permission,
forward host TCP 18869 to emulator TCP 8869, and start instrumentation
`org.paranoid.voicemedialab.tests/org.paranoid.text.VoiceMediaInstrumentation`.
After instrumentation starts, launch activity
`org.paranoid.voicemedialab/org.paranoid.text.VoiceMediaFixtureActivity` so Android
35 permits foreground audio focus. Keep the lab visible throughout testing.

In an isolated Python environment install the tested versions `aiortc==1.15.0`,
`av==17.1.0` and `numpy==2.5.3`. The complete dependency lock and installation
hashes remain in the private evidence root. Run the direct harness:

```sh
python clients/android/test_voice_media.py --evidence-dir /tmp/voice-direct-result
```

Restart the instrumentation to reset counters before each run. With a locally
built coturn 4.18.0 executable and its runtime libraries available, run:

```sh
python clients/android/test_voice_turn.py \
  --turnserver /path/to/local/coturn-4.18.0/bin/turnserver \
  --emulator emulator-5582 --evidence-dir /tmp/voice-relay-result
```

Replace the emulator serial with the specifically owned fixture. The runner
refuses an occupied listener, creates a new private directory and random
short-lived credentials, binds only loopback, and removes its own reverse mapping
and process on exit. Raw results include synthetic SDP and must remain private.
The repository builder and runner also passed end to end on a second fresh
owned Android 35 emulator: 336 decoded host frames, selected relay candidate,
mute/unmute and close/redial cleanup. The runner removed its private secret
files and local listener; the second emulator was stopped afterward.

## Exact proposed public scope and remaining gates

The single current proposal is in [the package runbook](../../deploy/turn/README.md)
and [canonical contract](../protocol/voice-turn-v1.md): host157.180.49.125 only,
TCP/UDP34781 and UDP40000–40015, a dedicated relay user/unit, isolated issuer and
relay credential files, four allocations per credential and sixteen total. A
reviewed same-data messaging update would enable issuance; existing data/TLS/pins
and DNS remain unchanged. Egress must allow this host's own relay range while
denying its other destinations. The coturn address list alone cannot enforce
that port boundary. Raw relay logs are suppressed; aggregate counters are not
implemented. These statements replace the initial unimplemented proposal.

Actual binary/config/unit/firewall hashes, missing packet/lifecycle/expiry gates,
port ownership, rollback and explicit owner deployment authorization are required
before exposure. No deployment request is ready for approval while those tests
are missing. APK signing or a PR never supplies public network authorization.
