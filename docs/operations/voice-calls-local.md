---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Voice local implementation and evidence

The [post-PR18 task](../product/voice-calls.md) runs only in clean worktree
`/home/codex/projects/paranoid-worktrees/voice-calls-20260909`, branch
`feat/voice-calls-20260909`, base `366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f`.
Evidence root:
`/home/codex/paranoid-self-service-evidence/voice-calls-20260909T220516Z`.
Its checkpoint/status separate implemented, compiled, media-tested, reviewed,
built and deployed states. The [repository evidence](../project/evidence/voice-calls-20260909/README.md)
contains the completed design reviews and sanitized implementation results.

## Current extension — 2026-09-10

The initial direct-ICE checkpoint below passed fresh exact-source Fable review,
with retained low-severity physical routing limits. That review does not cover
REQ-CALL-006. The current v10 source implements strict issuer retrieval, volatile
credentials and consent-before-media. Server foundation PR21 owns the canonical
contract and offline package; client PR20 depends on it. Signed ARM64 v10 is
built (hash recorded separately); HTTPS/JNI lane10 scenarios, parser49 negatives,
controller gates and unchanged text regression pass. V9→v10 identity/contact/
history continuity passes on the owned emulator. The current retained-signer APK
is `paranoid-0.0.10-voice-arm64-20260910-a44278f46751.apk`, SHA256
`a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`,
15,712,851 bytes, versionCode10. Its independent audit matches44 product inputs
to the exact build and the x86 fixture (only its two public realm/pin constants
differ). It supersedes the earlier f1bcb6 v10 checkpoint without changing signer.

Actual application relay/relay audio passes in both roles with SDK mute/unmute,
two-way text, no capture before Answer and complete local/remote teardown. Fresh
Fable final review identified delayed COMPLETE-gated publication; the reviewed
500 ms relay-only correction now passes real timer/cancellation/redial and late
COMPLETE/context-stability tests. Direct-mode bidirectional tone/mute/cleanup
passes on the same engine. [Current sanitized evidence](../project/evidence/voice-relay-client-20260910/README.md)
retains the actual RED/GREEN, fixture failures and earlier unexplained15-second
incoming failures; no universal reliability claim is made. Fresh Fable exact-source
closure closes VOICE-PUB-01 on this APK; committed-source/CI correspondence is the
remaining local process check. Required relay expiry/race/drain
and ACL packet tests remain NOT RUN after the platform worker rejection.
No public deployment readiness, authorization or physical-phone result is claimed.

## Historical direct-ICE implementation checkpoint

Fresh `claude-fable-5` design review and separate exact-doc closure succeeded
before protected runtime implementation. The original conditional report and
final design closure remain distinct; both actual model-usage records also
contain Haiku. This is independent AI design review, not final code approval or
human architecture acceptance.

The native strict call body/SDP path, transient post-commit event adapter,
volatile Java controller, Android call UI/microphone service and WebRTC audio
adapter are implemented. The local retained-signer ARM64 versionCode9,
`0.0.9-voice`, is built with signature/package/16KiB alignment checks passing.
It remains a local candidate awaiting fresh independent final-source review.

| Check | Actual result | Limit |
| --- | --- | --- |
| Supported native suites | 62 passed, including 14 voice tests; clippy and format pass | Includes 3700 real Olm controls across 20 simulated maximum calls, not audio |
| Actual v8/current Java/JNI | PASS: unchanged reopen, pending/accepted call state, rejected old-client controls, then bidirectional text/receipts | No physical installation or network in this fixture |
| Java receive adapter with actual JNI/Olm | PASS: save before event, duplicate/reopen, block/unknown, no text/receipt, failed-save freeze | Does not create WebRTC endpoints |
| Controller JVM tests | PASS: consent, freshness, replay, clocks, cleanup, heartbeat, crossing, delayed callbacks and pre-ready cancellation | Media Port callbacks test state authority only |
| Android35 compilation | PASS for application classes | Not Android UI/audio execution |
| Actual Android M150/aiortc decoded media | PASS direct and isolated local TURN relay: bidirectional tones, mute/unmute, capture/route cleanup, redial | Synthetic PCM injection at real AudioRecord cadence; physical acoustics not tested |
| Exact successful-media SDP through native/Olm | PASS all four captured offers/answers; binding substitutions rejected | Separate encrypted-control validation, not full app signaling/media acceptance |
| Actual Android v8→v9 update and text | PASS unchanged identity/credential/contact/dialog history, delivered new text after update | Owned emulator fixture; final ARM64 artifact and physical phones are separate |
| Actual Android permission denial / incoming before Answer | PASS no media object and zero active recordings | Separate 14-step integrated result recorded below |
| Pinned-TLS authority retry | RED→GREEN genuine401→200 with zero false stop callbacks; revoked401→401 gives one stop callback | Isolated synthetic account revocation only; peer media silence bound remains separate |
| Authenticated resume readiness | RED no callback within3029 ms; GREEN70.14 ms after signed response/commit | One drained empty-inbox fixture, not a general latency guarantee |
| Engine restart / repository relay wrapper | PASS initial mute, callback-immediate redial, capture cleanup; wrapper relay336 decoded frames and fixture cleanup | Separate native media fixture, not deferred TextEngine intent proof |
| Full application interaction/permission/lifecycle | PASS 14 actual app/E2EE/media steps repeated on final fixture5, corrected insets visually inspected, first grant and deferred mute GREEN | Owned Android35 emulator and real peer; physical acoustics separate |
| Actual process restart | PASS unchanged identity/contact/history; call idle and no media/recording | Owned emulator process operation, no data reset |
| Final real TLS/JNI text regression | PASS 24 samples P50 105.92 ms/P95 122.99 ms plus text/receipt/retry/save/restart gates | Local warm receiver-commit timings, not physical rendering |
| Signed ARM64 APK | PASS retained signer, version9/package, notices, dependency payloads and 16KiB alignment | Local candidate, not deployed or installed on phones |
| Independent final code review | Pending | Required before candidate handoff |

Existing historical pre-v7 exclusions remain the unchanged CI list. The 62-test
result is the supported scope; it is not an unfiltered historical-suite pass.
A separate exact run of those 14 historical names exits101 with 0 PASS/14 FAIL;
the names match the retained PR18 baseline exactly, with no new failure names.
The [historical record](../project/evidence/voice-calls-20260909/core-historical14-final.json)
is separate from the passing supported suite; none of these failures is fixed.

## Signed local artifact and build provenance

[Artifact](../project/evidence/voice-calls-20260909/signed-apk-artifact.json):
`paranoid-0.0.9-voice-arm64.apk`, package `org.paranoid.devtext`, version9
`0.0.9-voice`, 15,712,851 bytes, SHA256
`4a2744de3427917098db252ec8b8919abd0b07731315e847a47f8e8a63c3066f`.
The retained certificate is
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
[Source manifest](../project/evidence/voice-calls-20260909/signed-apk-source-sha256.json)
SHA256 `ee21f04393d7186dec132dd033069fd2d5b8859a659124b07a689b0028509b62`
identifies the exact uncommitted feature source at build time. The base/head field
therefore still names PR18; it must not be mistaken for a committed voice revision.
[Code correspondence](../project/evidence/voice-calls-20260909/artifact-code-correspondence.json)
confirms the later documentation/evidence update did not alter packaged code.
The coordinator freezes the final review commit separately.

[Build environment](../project/evidence/voice-calls-20260909/build-environment.json),
[full build gate output](../project/evidence/voice-calls-20260909/signed-apk-build.log),
[signature](../project/evidence/voice-calls-20260909/signed-apk-signature.log),
[package metadata](../project/evidence/voice-calls-20260909/signed-apk-badging.log)
and [alignment](../project/evidence/voice-calls-20260909/signed-apk-alignment.log)
retain actual results. Local build uses Rust1.97.1, Java21 and Android build-tools35;
CI separately pins Rust1.98.1. Native build tests use the release profile matching
the shipped JNI.

[Earlier attempts](../project/evidence/voice-calls-20260909/candidate-build-attempts.json)
remain distinct: build1 was intentionally stopped before artifact creation after
the verified call-dialog inset defect; build2 failed an obsolete test expecting
version8 rather than the intended9. Updating that assertion changed no production
version or runtime behavior. Build3 passes all gates. These earlier attempts are
not substituted for successful builds.

## Reproduce the completed checks

The 52-test main native invocation is:

```sh
cargo test --offline --locked --release --manifest-path clients/core/Cargo.toml \
  --lib --bins --test clean_first_contact --test key_vectors \
  --test realtime_signing --test registration --test state \
  --test sync_recovery --test voice_calls
python3 clients/android/test_call_controller.py
```

The remaining 10 supported tests use `--test self_service` with the unchanged
14 exact historical names in `scripts/ci-legacy-client-tests.txt` excluded,
matching the established CI separation. The evidence records 10 PASS/14 filtered;
no new voice test is excluded. Use the real old/current JNI fixture with
`python3 clients/android/test_voice_v8_compatibility.py --help` and separate
retained v8/current JNI directories. Keep its generated states private.

The media harness is `clients/android/test_voice_media.py`, using a separately
installed instrumentation APK on the owned emulator and an aiortc endpoint.
Its test control socket is not application E2EE signaling; native/application
control tests are separate evidence. A successful media run must report actual
ICE/DTLS/SRTP/Opus, decoded tone energy, mute and teardown before it is marked
PASS. [Actual media aggregates](../project/evidence/voice-calls-20260909/media-validation-summary.json)
record 360/341 decoded host frames for direct/relay and 492960/495840 decoded
Android sample frames. Both runs have zero forward frames during mute with
reverse audio continuing, decoded tone recovery after unmute, three capture
starts/stops and two completed closes through redial. Zero received mute frames
is not a measured zero-energy decoded sample. The relay used isolated coturn
and was stopped; production TURN remains unconfigured. Do not publish synthetic
private snapshots, full SDP or PCM captures.

## Invariants and local execution

Read [the contract](../protocol/voice-v1.md) and [test mapping](../security/voice-v1-threats.md).
Use owned isolated PostgreSQL/TLS and Android fixtures, synthetic identities and
test tones. Never automate/reset physical phones or hijack an unrelated emulator.
Never print/copy signing private keys or passwords into source, evidence or argv.
Keep package `org.paranoid.devtext`, versionCode greater than delivered v8,
retained certificate SHA256
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
Freeze source and dependency manifests and verify actual signed APK correspondence.

No live v8 server, TLS/pins, DB, firewall/DNS, public TURN or neighboring service
change is authorized. The [bounded relay proposal](voice-turn-request.md) records exact proposed
host/listeners/port range, credential isolation and rollback. Its issuer/client/package are now implemented locally; missing relay packet gates,
separate final review and authorization are required before public scope can proceed. No service action follows a successful
APK build. Same-package updates preserve data; rollback is a reviewed newer
same-signer build, never app deletion or a stale snapshot restore.

## Authorization retry and final review scope

The existing signed-session transport retries a first ambiguous HTTP401 once
with a fresh nonce on the same immutable request. Calls terminate on confirmed
failure after that retry, or immediately for authorization failures outside that
retry path. No new re-attestation loop or call/heartbeat deadline extension is
authorized. [Actual pinned-TLS RED/GREEN](../project/evidence/voice-calls-20260909/realtime-authority-tdd.json)
confirms recoverable401→200 produces no false authority-loss callback; actual
revocation401→401 produces one callback, no delivery and preserved pending data.

[Resume readiness RED/GREEN](../project/evidence/voice-calls-20260909/realtime-readiness-tdd.json)
uses an empty inbox after draining the previous backend waiter. The first fetch
per receive generation is the existing signed `messages` operation, followed by
normal long polling. Readiness is published only after authenticated guarded
processing/commit. The wire contract and authorization checks are unchanged.

Final review also covers the initial permission-grant race: a generation-bound
Call/Answer intent has one 10-second readiness/service deadline, with checks again
at the service callback. Delayed engine creation must apply the current mute and
route intent after old disposal. The preliminary deferred-mute frame-count oracle
was INVALID and is not RED/GREEN proof. The [actual SDK track-property RED](../project/evidence/voice-calls-20260909/deferred-mute-sdk-red.json)
confirms controller-muted intent with a current unmuted/enabled SDK track after
deferred creation. The [same-oracle GREEN](../project/evidence/voice-calls-20260909/deferred-mute-sdk-green.json)
now passes with the current SDK muted and track disabled. The [full app run](../project/evidence/voice-calls-20260909/app-acceptance-result.json)
passes 14 actual consent/media/lifecycle/text steps. First microphone grant and
actual process restart also pass. Separate engine initial-mute and
callback-redial media PASS does not establish deferred TextEngine correctness.

## Remaining gates

Freeze the final review commit and its artifact correspondence; obtain fresh
independent exact-source final Fable review and resolve findings;
publish sanitized GitHub PR/evidence referencing issue19. Real network revocation
timing needs its own exact result. Public TURN deployment needs a separate
reviewed authorization; the completed isolated relay fixture grants none.
Physical OPPO acoustic quality, Bluetooth, mobile handover, Doze/force-stop and
live relay deployment are NOT RUN. No new public listener is authorized here.
