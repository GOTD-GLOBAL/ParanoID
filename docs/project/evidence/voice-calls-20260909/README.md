---
status: draft
owner: maintainers
last_reviewed: 2026-09-09
---

# Voice implementation evidence — 2026-09-09

Issue [#19](https://github.com/GOTD-GLOBAL/ParanoID/issues/19),
[REQ-CALL-002–005](../../../product/voice-calls.md),
[RFC-0017](../../../rfcs/0017-voice-calls.md) and proposed
[ADR-0011](../../../decisions/0011-voice-calls.md). Work starts from independently
verified PR18 merge `366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f` on the separate
`feat/voice-calls-20260909` branch. These are local private synthetic-data results.
The [operations record](../../../operations/voice-calls-local.md) separates the
implemented, tested and signed local candidate from the remaining final-review gate.

## Independent design review

- [Initial Fable report](fable-design-review.md.txt): successful 30-turn invocation,
  session `33cd8569-f6c8-4dfb-a074-48f88d8f4d56`; conditional design verdict with
  blocking F-01 heartbeat exhaustion of the text Event ledger.
- [Exact-doc closure](fable-design-closure.md.txt): successful 21-turn fresh
  invocation, session `21ce2a92-0acf-43aa-a904-be10ba07f767`; implementation gate
  opened after reviewing the canonical contract and actual vodozemac source.
- [Actual invocation/model provenance](review-provenance.json): both outputs
  have `subtype: success`, `is_error: false`, and model usage for
  `claude-fable-5` plus `claude-haiku-4-5-20251001`. Raw-result hashes and report
  hashes are retained. Failed invocations are not substituted for review.

The initial report was completed while the canonical voice documents were being
created; its statement that they did not yet exist is historical. The closure
actually reviewed all six documents. Its accepted design uses no call Event rows,
refuses recreation of retained Olm sessions from replayed prekeys, reserves text
outbox capacity, and states the delayed-revocation bound honestly. The flat wire
body in [voice-v1](../../../protocol/voice-v1.md) is canonical; the initial nested
example was superseded before implementation.

One closure prose arithmetic error is preserved transparently: existing outbox
count `<16` before enqueue permits **16** pending call-added envelopes and
reserves 384 of 400 text slots; the report says 15. The canonical contract and
tests use the correct pre-enqueue limit. Later readiness-only cancellation
clarification/fix has a separate RED/GREEN regression and remains within the
final implementation review scope. Active-call nonce matching stays strict.

Later final-review scope also includes confirmed authorization failure after
the retained single fresh-nonce HTTP401 retry, initial microphone permission
grant during network reconnection, and mute-state preservation when prior media
disposal delays a new engine. Each requires concrete code and regression evidence;
these design reports do not claim those implementation corrections were reviewed.

These are design reviews, not final-code acceptance, a human audit or permanent
ADR approval. Final-source review is still pending at this checkpoint.

## Actual implementation checks

| Evidence | Result and scope |
| --- | --- |
| [Native validation](core-implementation-validation.json) | 62 supported native tests PASS, including 14 voice tests; clippy/format PASS; 20 simulated maximum calls exchange 3700 real Olm controls without consuming the text Event ledger |
| [Actual v8/current JNI compatibility](v8-compatibility-result.json) | PASS: old/new state reopening, old-client call rejection, bidirectional text/receipts after the ratchet gap; no network or phone operation |
| [JNI adapter output](adapter-green.log) | PASS: post-commit-only event, duplicate/reopen, unknown/block, no text/receipt, save-failure freeze |
| [Controller checkpoint](controller-result.json) and [JVM output](controller-green.log) | PASS lifecycle/consent tests and Android35 javac; mock Port counters are not real audio |
| [Reconnecting presentation RED](controller-reconnecting-red.log) | The expected missing-field failure is retained before its GREEN correction |
| [Pre-ready cancel result](controller-pre-ready-cancel-result.json), [RED](controller-pre-ready-cancel-red.log), [GREEN](controller-pre-ready-cancel-green.log) | PASS delayed-ready cancellation followed by immediate fresh knock; active-call nonce matching remains strict. This supersedes the earlier controller checkpoint source hashes |
| [Real media aggregates](media-validation-summary.json) | PASS direct and isolated local TURN relay, bidirectional decoded synthetic audio, mute/unmute and capture/route teardown through redial |
| [Exact real-media SDP validation](native-real-sdp-captures.json) | PASS all four captured offers/answers through native outgoing and real Olm/frame2 receive; substitutions rejected without text/receipt |
| [Maven restamp verification](maven-restamp-verification.json) | 433 Java class headers differ only by upstream major65-to61 restamp; native bytes are identical |
| [Authorization retry TDD](realtime-authority-tdd.json) | Real TLS RED→GREEN recoverable401→200 no false stop, actual isolated revoke401→401 exactly one stop callback and pending preserved |
| [Resume readiness TDD](realtime-readiness-tdd.json) | RED no authenticated callback within3029 ms; GREEN70.14 ms using existing signed messages before long poll, after guarded commit |
| [Actual app update/text/consent subset](app-upgrade-continuity-summary.json) | PASS in-place v8→v9 identity/contact/history continuity, delivered new text, permission denial and incoming ring without capture; historical subset checkpoint; full lifecycle PASS recorded below |
| [Native media restart](media-engine-restart.json) | PASS initially muted decoded frames near silence, unmute tone, callback-immediate redial, capture2/2 and route restoration |
| [Repository relay runner](repository-wrapper-summary.json) | PASS 336 decoded host frames, relay candidate, mute/capture/route cleanup; owned listener/mappings/secrets/emulator removed |
| [First microphone grant](app-permission-green.json) | PASS first grant proceeds to actual app/E2EE/Android-media connection after confirmed readiness |
| [Deferred mute same-oracle GREEN](deferred-mute-sdk-green.json) and [app run](deferred-mute-app-green.json) | PASS current controller/SDK both muted and actual track disabled after deferred creation, correcting the retained SDK RED |
| [Full app acceptance](app-acceptance-result.json) | PASS 14 steps: incoming consent/reject, bidirectional RTP, mute/speaker, stale notification, text during call, background active call, hangup/cancel and retained history |
| [Actual process restart](app-process-restart-summary.json) | PASS identity/contact/history unchanged, idle call, no media/recording or pending close |
| [Final text regression](realtime-final-regression.log) | PASS real TLS/JNI text and receipts, exact retry/save-failure/restart gates;24 warm samples P50 105.92 ms/P95 122.99 ms |
| [Final fixture5 app acceptance](app-acceptance-2-result.json) | Repeated PASS 14 steps on corrected call-dialog insets; four inspected screenshots below |
| [Signed ARM64 artifact](signed-apk-artifact.json), [source manifest](signed-apk-source-sha256.json), [code correspondence](artifact-code-correspondence.json) | PASS local version9 retained signer, exact APK hash, code unchanged by post-build docs |
| [Build environment](build-environment.json), [gate log](signed-apk-build.log), [attempts](candidate-build-attempts.json) | Final build3 PASS; earlier cancelled build1 and stale-version-assertion build2 preserved honestly |
| [Independent artifact audit](independent-artifact-verification.json) | PASS 42 product inputs, compiled production TLS defaults, no fixture pin/test entry classes, actual native ZIP/ELF 16KiB alignment |
| [Supplemental integration review](integration-review-agent-final.json) | Four integration findings closed against real evidence; reviewer authored some code, so this is explicitly not the fresh Fable final review |
| [Public links checkpoint](links-network-summary.json) | 593 successful, zero errors; only exact verified private URLs excluded |

The 62 supported tests comprise 52 main native tests plus 10 supported
`self_service` cases. The unchanged 14 historical names are filtered in that
second invocation. The [separate historical run](core-historical14-final.json)
actually fails all 14 with the exact PR18 baseline names; [raw output](core-historical14-final.log)
remains visible. This does not claim those failures were fixed. See the operations
record for exact reproduction and remaining checks.

The media results exercise the real native Android SDK and aiortc with synthetic
PCM at actual AudioRecord cadence. Their control socket is separate from the app
E2EE path. Both direct/relay runs receive no forward frames during mute; the zero
RMS placeholder therefore does not represent a measured decoded silent frame.
The newer native-engine initial-mute test receives 95 actual frames with maximum
RMS 0.544 before unmute, then unmuted median RMS 1028.16. That is separate from
the zero-frame mute result above. The preliminary deferred TextEngine mute
frame-count oracle was INVALID; it is not counted as a successful RED/GREEN
regression. The [actual SDK-property RED](deferred-mute-sdk-red.json) now confirms
controller-muted state with an enabled, unmuted current SDK track after deferred
creation. The same-oracle GREEN now passes with SDK mute true and track enabled
false. This closes the actual defect; the preliminary invalid oracle remains
invalid. Full app acceptance passes 14 steps separately and repeats on final
fixture5 after correcting the call-dialog system-bar insets.

## Final app screenshots and signed candidate

These are visually inspected actual Android35 screenshots with synthetic contacts
and test messages only: [incoming before capture](app-incoming-no-capture.png),
[connected](app-connected.png), [muted](app-muted.png) and
[delivered text during call](app-text-during-call.png). The heading and controls
remain inside the system-bar insets. The app fixture uses only isolated
`KeyClient` realm/pin constants and x86_64 packaging; the release retains production
trust and ARM64. Instrumentation RPC and synthetic capture remain test-only.

The local signed APK is version9 `0.0.9-voice`, 15,712,851 bytes, SHA256
`4a2744de3427917098db252ec8b8919abd0b07731315e847a47f8e8a63c3066f`.
[Signature](signed-apk-signature.log), [package](signed-apk-badging.log) and
[16KiB alignment](signed-apk-alignment.log) checks pass. The exact build source
manifest, SHA256 `ee21f04393d7186dec132dd033069fd2d5b8859a659124b07a689b0028509b62`,
is retained independently of later documentation edits. Its build-time head
remains the PR18 base because voice changes had not been committed. The upcoming
final review must name its actual frozen commit and compare packaged code.
The APK itself and signing material are kept outside Git.

The supplemental review records a physical routing limitation: if a previous
API31+ communication device disappears during the call, cleanup does not
explicitly fall back after `setCommunicationDevice(previousDevice)` returns
false. Existing emulator route-restoration results do not prove that physical
headset/Bluetooth unplugging case. It remains visible to final review.

Physical microphone/speaker quality and independent final code review have no
PASS record here yet. No deployment, new public TURN/firewall/DNS listener, physical OPPO automation
or PR merge occurred in this scope.

## Copy and privacy boundary

[Copy provenance](copy-provenance.json) records allowlisted byte-exact copies of
review text and aggregate checks. Local source paths are provenance only; the
relative copies make findings/results reviewable from GitHub. Private keys,
encrypted client snapshots, full generated SDP, PCM/audio captures, credentials
and APK signing material are excluded. The `.md.txt` review copies retain exact
historical wording without treating their sketches as canonical specifications.
