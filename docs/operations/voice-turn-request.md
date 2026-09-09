---
status: proposed
owner: operations
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice relay: local proof and bounded deployment request

The local voice candidate uses `iceServers=[]` in its production constructor.
It has no production TURN credential endpoint, credential client, relay setting,
or hardcoded TURN password. The package-private test constructor supplies an
isolated relay solely to the separately packaged media instrumentation. A passing
relay test establishes native engine interoperability, not public-network call
availability. This request connects [REQ-CALL-005](../product/voice-calls.md) to
the explicit [deployment boundary](voice-calls-local.md).

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

## Exact proposed public scope

This section is a reviewable proposal, not authorization or a claim that the
production package is ready to execute. A reviewed credential endpoint/client
implementation and owner approval are prerequisites. The known host comes from
the [owner inventory](production-access.md); no fresh access check was performed.

| Item | Proposed scope |
| --- | --- |
| Host | `157.180.49.125` only; verify current inventory and port ownership under explicit access authority |
| Allocation listeners | Bind that IPv4 address on TCP and UDP 34781; no wildcard or IPv6 listener |
| Relayed media | UDP 40000-40015 on that IPv4 address; inbound/outbound media for authenticated allocations only |
| Client URLs | `turn:157.180.49.125:34781?transport=udp` and `turn:157.180.49.125:34781?transport=tcp` |
| DNS and TLS | No new DNS, certificate, TLS listener, or application pin change in this scope |
| Unit and user | New `paranoid-turn.service`, dedicated unprivileged `paranoid-turn` user; no existing unit restart |
| Files | Versioned `/opt/paranoid-turn/4.18.0/`, root-owned `/etc/paranoid-turn/`, isolated `/run/paranoid-turn/` and `/var/log/paranoid-turn/` |
| Initial limits | Two allocations per temporary credential, four total, 128000 bytes/second per allocation, 60-second allocation lifetime |
| Network denial | Deny relay peers in loopback, private, link-local, multicast, reserved and host-local ranges; no CLI, unauthenticated STUN or TCP peer relay |
| Observation | Aggregate allocation/error/byte counters; bounded private logs without credentials, SDP, PCM, or stable account labels |

The proposed non-TLS TURN transport forwards endpoint DTLS-SRTP packets; the
relay operator still observes endpoint addresses, timing and volume. It does not
hold media keys. TCP 34781 is a restricted-network fallback, not a promise that
all carrier or enterprise networks permit it. TURN/TLS on another listener is a
separate scope if later required. Public UDP and remote connectivity were not
tested by the loopback TCP fixture.

The credential issuer must be implemented and reviewed before deployment. It
must authenticate the retained account/device through the existing pinned HTTPS
authority, reject blocked/revoked access, rate-limit issuance, and issue a random
per-request username with a bounded expiry and HMAC password. A 1200-second
credential lifetime is proposed for the v1 15-minute maximum call. The client
holds credentials only in memory and supplies them only after call consent;
neither signaling nor logs contain the issuer secret. This is a proposed
contract, not an existing API. Any update to the existing HTTPS service to add
it needs explicit reviewed server-change authority.

Keep the issuer secret separate from messaging database, TLS, update-signing,
Android-signing and identity keys. Generate it at installation into a root-owned
0600 credential file; provide it read-only to the two authorized components.
Do not put it in the APK, command arguments, source repository or a public
configuration. Bound secret rotation and revocation behavior in the credential
endpoint tests. The [upstream configuration reference](https://github.com/coturn/coturn/blob/4.18.0/examples/etc/turnserver.conf)
describes the coturn options; the local loopback allowlist must never become the
public peer policy.

## Required authorization and rollback

After the missing credential work passes independent review and actual tests,
present the exact binary/config/unit/firewall hashes, port-conflict check and
endpoint diff together for owner authorization. The approval must name the host,
new unit, both listener protocols, relay range, credential issuer change and
rollback. A client PR merge or APK signature supplies none of that authority.

Rollback disables further credential issuance, stops only `paranoid-turn.service`,
removes only its recorded firewall rules for TCP/UDP 34781 and UDP 40000-40015,
and revokes its isolated secret. Preserve sanitized incident evidence and the
existing messaging service, TLS/pins, data and neighboring workloads. A client
rollback, if needed, is a reviewed newer version with the retained signer and
unchanged data; app deletion and old-state restoration are excluded. The public
configuration, credential expiry/denial tests, exposure checks and rollback drill
remain NOT RUN until separately authorized and exercised.
