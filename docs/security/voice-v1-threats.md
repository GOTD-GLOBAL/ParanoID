---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice trust delta and acceptance test plan

[REQ-CALL-002–005](../product/voice-calls.md), [RFC-0017](../rfcs/0017-voice-calls.md),
[ADR-0011](../decisions/0011-voice-calls.md), [voice-v1](../protocol/voice-v1.md).
Human residual risk owner: martadvix-web. Private synthetic data only. The
analysis preceded implementation; completed native/adapter/controller checks
and actual direct/isolated-relay media checks are distinguished below from
the remaining independent final-review gate. No human
audit or production assurance is claimed.

```text
Native identity/contact pins -> strict Olm/frame2 call control -> sealed commit
  -> transient validated call state -> explicit answer/permission -> WebRTC
  <-> peer DTLS-SRTP/Opus (direct, or ciphertext-forwarding approved TURN)
Relay: authenticated opaque controls + metadata; no audio/content keys
Android: microphone/audio routing/focus/service is a separate consent boundary
```

| Threat | Required control | Tests before candidate handoff |
| --- | --- | --- |
| Relay substitutes identity/SDP/keys | Existing immutable wrapper/inner bindings plus exact SDP fingerprint/ICE/offer digest | Wrong signature/root/device/recipient/channel/realm/call ID/fingerprint/ICE; whole-state rejection |
| Unknown or blocked caller gains authority | Existing committed peer required, block checked; no trust upgrade | Unknown controls allocate nothing, blocked inputs produce no media/receipt |
| Replay or restart resurrects consent | Persisted ratchet/cursor, no existing-session recreation, fresh volatile knock/ready nonces and state/sequence checks | Duplicates, stale/expired offers, altered IDs, clock rollback, restart before/after timeout |
| Incoming ring captures or transmits | No PeerConnection/audio module before explicit Answer + permission | Real permission denial/ring/reject and instrumented audio-start absence |
| Revoked peer continues media | Authorized heartbeats; confirmed own auth failure immediate stop after the existing single fresh-nonce session retry; silence30s, delayed pre-revoke backlog up to75s plus clock skew | Real first-401 retry without false termination, repeated401 revocation/heartbeat timeout, no deadline extension or call resurrection |
| Crash/save failure publishes uncommitted authority | Persist whole ratchet/cursor candidate before event, freeze on failure | Inject save failure; no callback/media dispatch; old state retained |
| Malicious peer exhausts CPU/storage/media | Frame/SDP/candidate/rate/readiness/call/time limits and existing quotas | Malformed/oversize/duplicate keys, concurrent/crossing, saturation and cleanup |
| Async stale callbacks restart capture | One owner, generation checks, idempotent disposal | Late SDP/ICE/permission callbacks after cancel, remote end, service stop and restart |
| Audio leaks or interrupts other apps | Explicit permission, audio focus/routes, mic foreground service, no recordings | Mute/unmute decoded energy, speaker/earpiece, focus/lifecycle/service cleanup |
| Network metadata or accidental public exposure | Explicit direct-IP disclosure and isolated relay configuration | Local real media only; prepared exact authorization/rollback request, no live actions |
| Dependency substitution or APK drift | Pinned upstream artifact/source/license hashes, stored ABI libs, retained signer | Download hash failure, real d8/build, APK entries/alignment/cert/hash manifest |
| Calls regress working text/upgrade | Same core3/sealed4 shape and independent media/network work | Actual v8 state reopen/update, concurrent E2EE text/receipt, old-client call rejection |

Media evidence must use actual WebRTC endpoints, ICE/DTLS/SRTP/Opus packets and
decoded known synthetic audio, including measured receiver energy and mute. A
mock engine or connected label proves no audio. Android screenshot/interaction
evidence must show actual call states and retained chat. Synthetic emulator
media does not establish acoustic AEC/noise/speaker quality on OPPO. Physical
Bluetooth, mobile handover, Doze/force-stop and production privacy remain separate
NOT RUN items unless actual evidence is obtained. Retained alpha quotas and
server metadata are not fairness, anonymity or long-term call storage scaling.

Independent initial Fable review found F-01: durable heartbeat Event rows would
exhaust the text ledger. The revised contract has no call Event rows, prohibits
recreating existing Olm sessions from replayed prekeys and reserves outbox space.
Fresh [exact-doc closure](../project/evidence/voice-calls-20260909/fable-design-closure.md.txt)
examined the real vodozemac session-ID and fallback paths and opened the native
implementation gate. The higher-sequence replay and budget corrections now pass
actual native tests: 20 simulated maximum calls exchange 3700 genuine Olm
controls, followed by working text/receipts without call Event rows. The actual
old/current JNI fixture passes v8 rejection and ratchet-gap continuation. Java
adapter tests pass commit-before-event, duplicate/reopen, unknown/block,
no-text/receipt and failed-save freeze. Controller tests pass consent, stale
callbacks, timeout, heartbeat, crossing, clock and pre-ready cancellation.

The [retained results](../project/evidence/voice-calls-20260909/README.md) now also
include actual Android/aiortc direct and isolated local TURN relay audio: real
DTLS-SRTP/Opus, bidirectional decoded synthetic tones, zero forward decoded frames
during mute while reverse audio continues, unmute recovery and capture/route
cleanup through redial. The exact captured SDP passes real native/Olm validation
and rejects binding substitutions. These separate media/control fixtures do not
establish full app acceptance or physical acoustics. Actual pinned-TLS regressions
now prove one fresh-nonce retry avoids a false call-stop callback while repeated
401 after isolated account revocation triggers the callback and preserves pending
bytes. A signed nonblocking fetch after resume confirms readiness only after
authenticated processing/commit, without weakening the existing wire contract.
Actual app/E2EE/media acceptance passes 14 steps, including stale notification,
background active call and text during media. First-grant and deferred SDK mute
RED/GREEN and process restart pass. Final fixture5 repeats the 14-step app run
and verifies the corrected system-bar inset appearance. Actual peer media-stop
timing remains separately bounded by the stated heartbeat contract.
Maven/upstream Java restamp and native-byte correspondence, retained-signer ARM64
APK, package/notices and 16KiB alignment are verified. Independent final-source
review remains the candidate handoff gate.
