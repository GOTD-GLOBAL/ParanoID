---
status: draft
owner: ios
last_reviewed: 2026-09-11
---

# iOS client verification: requirement-to-test mapping

Validation plan for [RFC-0019](../../rfcs/0019-ios-client.md) and
[draft ADR-0013](../../decisions/0013-ios-client.md), written before any
client code exists. Every row is `NOT RUN`. Under the
[closed-alpha policy](../../governance/documentation-policy.md#closed-alpha-review-exception)
item 4, acceptance criteria for delivered behaviour must actually pass and
missing phone evidence cannot be replaced by a simulator or dependency build.

## Status vocabulary

- `NOT RUN`: no evidence exists.
- `CLAIMED`: passed on the simulator, the host or the local stand (unchanged
  server binary plus local PostgreSQL 16 on the build Mac); not phone evidence.
- `SHOWN`: passed on a physical iPhone in a joint test with the owner, with the
  evidence file and owner "go" permalink recorded.
- `FAILED`: run and failed; the failure is kept, not hidden.

Only `SHOWN` counts toward the acceptance of [REQ-CLIENT-001](../../product/requirements.md)
on the hosted alpha. Joint tests are recorded in
`docs/project/evidence/ios-client-<YYYYMMDD>/stage1-text.md` (registration,
QR both ways, text, receipts, block, cold start, screen lock) and
`stage2-voice.md` (calls both ways with the apps open, lock during ringing and
during a call, mute/speaker, hang-up from both sides). Those files are created
with the client pull request.

## Mapping

| Requirement | What must hold for iOS (source) | Planned check and evidence | Status |
| --- | --- | --- | --- |
| REQ-CLIENT-001 | Supported clients include iOS ([requirements](../../product/requirements.md)) | Signed Release build installs and launches on a physical iPhone to the welcome screen; TestFlight internal build; `stage1-text.md` | NOT RUN |
| REQ-ID-005 | Identity created on the phone with locally owned keys and automatic proof-of-possession, no operator or bearer ([self-service v2](../../protocol/self-service-v2.md)) | `Создать ID` creates and durably saves identity before the first request, then registers through `/v2/registration/{challenge,commit}` signed by the core; local stand test, then the single hosted registration in `stage1-text.md` | NOT RUN |
| REQ-ID-007 | Contacts added only through explicitly verified QR key bindings ([first-contact v1](../../protocol/first-contact-v1.md)) | Own-ID QR renders a `paranoid-contact-v2` contact; scanning and pasting show the full fingerprint and require `Отпечаток совпадает`; a tampered contact is refused; scan on a real camera in `stage1-text.md` | NOT RUN |
| REQ-ID-008 | Self-service registration on the common server without approval or a transferred code ([self-service v2](../../protocol/self-service-v2.md)) | No operator, grant, role or manual URL/pin form in the UI; registration completes without any out-of-band step; UI contract check plus `stage1-text.md` | NOT RUN |
| REQ-MSG-002 | 1:1 E2EE text through one server with persistent history, reconnect and no duplicate display ([realtime v1](../../protocol/realtime-v1.md)) | Text both ways iPhone to Android; history survives relaunch; forced reconnect and exact-retry produce no duplicates; local stand fault scenarios, then `stage1-text.md` on LTE and Wi-Fi | NOT RUN |
| REQ-MSG-003 | One check means durable server acceptance, two mean recipient delivery, not reading ([first-contact v1](../../protocol/first-contact-v1.md)) | Single check appears only after `{id,sequence}` acceptance; double check only after an authenticated receipt from the peer; no read receipts anywhere; local stand, then `stage1-text.md` | NOT RUN |
| REQ-MSG-005 | First-contact text appears immediately as an unverified conversation on a receiver with zero contacts, reply enabled, no scan or approval ([first-contact v1](../../protocol/first-contact-v1.md)) | Android sends to a fresh iPhone identity with no contacts: conversation appears with the unverified badge and reply works; and the reverse direction; `stage1-text.md` | NOT RUN |
| REQ-CALL-002 | Real 1:1 encrypted Opus audio over a mature WebRTC engine ([voice scope](../../product/voice-calls.md)) | Simulator-to-simulator and local-stand call with decoded audio (`CLAIMED` at best); real audio in both directions iPhone to Android in `stage2-voice.md` | NOT RUN |
| REQ-CALL-003 | Signaling binds immutable account/device/realm/channel, fresh call identity and media fingerprint/ICE context ([voice v1](../../protocol/voice-v1.md)) | iOS SDP passes the core validator unchanged; controller parity checks against the Android smoke scenarios; negative vectors (wrong nonce, stale offer digest, future skew, expired); `stage2-voice.md` | NOT RUN |

## Platform checks without a requirement identifier

These accompany the rows above and are recorded in the client pull request
evidence; they are never a substitute for the `SHOWN` rows.

| Check | Planned evidence | Status |
| --- | --- | --- |
| Core compiles and links for `aarch64-apple-ios` without changes | bridge crate build log and symbol listing | NOT RUN |
| Pinned TLS: nine leaf checks on DER fixtures (wrong pin, CA chain, expired, corrupted signature, wrong SAN) | unit tests, no network | NOT RUN |
| Storage: fsync or read-back failure freezes; key without file and file without key freeze; install marker matrix | unit tests with injected file-system faults; device test for Keychain persistence | NOT RUN |
| Component boundary: no diff outside the allowlist | boundary gate script output in CI | NOT RUN |
| WebRTC dependency: archive and slice digests, bundled notices | dependency test output | NOT RUN |
| Reinstall on the simulator starts a new identity; marker-present missing file freezes | simulator scenario | NOT RUN |
