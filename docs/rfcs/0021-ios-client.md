---
status: proposed
owner: ios
decision_owner: martadvix-web
decision_deadline: 2026-10-15
required_reviewers: []
review_mode: closed-alpha-ai
last_reviewed: 2026-09-14
---

# RFC-0021: Native iOS client on the shared Rust core (track A)

This proposal is **proposed**, not accepted: it is the client pull request's
statement of intent for [REQ-CLIENT-001](../product/requirements.md), and
nothing in it is accepted architecture. The decision deadline in the front
matter is 2026-10-15, at least fourteen days after this revision is offered for
review.

What exists at the time of writing, and what does not, is stated once here and
measured row by row in [verification.md](../clients/ios/verification.md):

- the client **is built**, and its checks run on simulators and a local stand
  (the unchanged server binary against a private PostgreSQL 16 on the build
  Mac). Those results are `CLAIMED`;
- **a signed build ran on a physical iPhone** on 2026-09-13 (iPhone 16 Pro
  Max, iOS 26.6.1, team `5RPGVC566Q`, installed with `xcodebuild` and
  `devicectl`): against the local stand it created an identity, showed its
  own QR, read a contact off the build Mac's screen with the real camera,
  confirmed the fingerprint sheet, exchanged text with receipts in both
  directions and placed one call to a simulator that connected with video
  from the phone. Those rows are `SHOWN`; no archive, `.ipa` export or
  TestFlight build exists;
- **the two joint tests with the owner are partly run.** In an unscheduled
  session on the hosted alpha on 2026-09-14 the iPhone scanned the owner's QR
  and paired his Android, text went both ways — the first time this client has
  seen the second check, which is the acknowledgement from a real Android
  client — and the owner called the iPhone from his Android: the call
  connected, both sides spoke and both turned their cameras on, the first call
  this client has carried against the Android client rather than a simulator
  and the first picture it has received from a real camera. The contributor is
  the only participant that record has, so those rows read
  `SHOWN (joint, reported)` — his report given immediately afterwards, not a
  capture — and no owner "go" permalink exists for the session, because it was
  not planned. Every row the report does not cover stays `NOT RUN`. After the
  session the iPhone stopped connecting and has not recovered;
- **two hosted accounts exist** — `hosted_registrations` is 2: one
  `service-bridge` registration from the build Mac while diagnosing the
  phone's TLS failure, and one from the physical iPhone once App Transport
  Security was switched off, both under the owner's answer to question 4 (no
  fixed budget). The iPhone then paired the owner's Android from his QR image
  and sent one text the hosted server accepted (one check); delivery to his
  phone was still pending then, and happened in the joint session of
  2026-09-14, which used that same account and consumed no further
  registration. Before that, the only contact with the hosted
  server was a TLS handshake that compared the live SubjectPublicKeyInfo
  digest with the pin this client carries;
- the calls this client speaks are **call-v2**, not the voice v1 this RFC was
  first drafted against; see [call-v2 migration](#call-v2-migration).

The behavioural reference is the Android client on `main`; owner decisions take
precedence over every preference recorded here.

## Required review rationale

`required_reviewers` is empty because the bounded
[closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception)
is requested for this private synthetic-data alpha (`review_mode:
closed-alpha-ai`). No independent qualified human domain reviewer is available
to the contributor; the human decision owner remains `martadvix-web` and is
never replaced by AI. The independent AI review required by policy item 2 ran
on 2026-09-13 in two fresh contexts, separate from the implementing context,
and is recorded in
[independent-review.md](../project/evidence/ios-client-20260913/independent-review.md); it is not a human audit and does not appear in the
reviewer list. Protected domains touched by this proposal are listed in
[Proposed design](#proposed-design) and recorded in
[proposed ADR-0014](../decisions/0014-ios-client.md). Before real sensitive
communication, public release or any production claim, independent qualified
human review of identity, cryptography, persistence and application security
remains required (policy item 6).

## Summary

Build a native SwiftUI iOS application that reuses the unchanged shared Rust
client core (`clients/core`) through a thin C-ABI bridge crate, speaks exactly
the wire contracts the Android client speaks (self-service v2, realtime v1,
first-contact v1, [call-v2](../protocol/call-v2.md) over voice v1, voice TURN
v1) against the existing hosted alpha, and reproduces the Android screens and
Russian UI strings for registration, QR contact exchange, E2EE text with
receipts and E2EE calls with audio and camera video while the application is
open. No server change, no core change, no new key material format and no new
trust anchor are proposed. The client is delivered as a pull request; merge,
hosted registration and TestFlight distribution are owner decisions taken
separately.

## call-v2 migration

This RFC was drafted against [voice v1](../protocol/voice-v1.md) and one
`m=audio` section. Before the client was written the owner requested video
calls, `main` moved to [call-v2](../protocol/call-v2.md)
([RFC-0019](0019-video-calls.md), proposed
[ADR-0013](../decisions/0013-video-calls.md)), and this branch merged with it.
The client implements call-v2 and not the superseded shape:

- fifteen fields with a boolean `video`, `v: 2`, and the informative
  `kind: "media"` camera-state control that grants no media authority;
- two media sections, `m=audio` then `m=video`, both `a=sendrecv`, bundled on
  the audio section's single fingerprint and ICE context;
- H.264 first with VP8 as the mandatory fallback (owner decision 2026-09-11);
  VP9 and AV1 are dropped in configuration, never in SDP text;
- camera on and off is a track-enable flag plus a `media` control, **never** a
  renegotiation;
- the description is capped at **9000 bytes** before it reaches the core,
  below the measured 10040-byte frame2 ceiling, and is refused rather than
  rewritten when it does not fit. call-v2's own `MAX_SDP` of 12288 bytes is not
  reachable through one envelope.

call-v2 rejects v1 bodies, so this client cannot call an Android build older
than v16. That is the owner-accepted alpha break call-v2 already declares, not
a new decision taken here.

## Motivation

- REQ-CLIENT-001 names iOS as a supported end-user client; today only Android
  exists.
- A second, independently written client is the first real test of the
  protocol documents as a contract rather than a description of one
  implementation. Preparing this client already surfaced twelve places where
  `docs/protocol`, `docs/clients` and code disagree; they are reported to the
  owner as findings, not silently resolved (open question 10).
- The owner delegated technical decision authority to the contributor and
  recorded it on GitHub:
  [issue #27, comment 5651949919](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
  That delegation lets the contributor answer the technical open questions
  below; it does **not** waive independent review, does not turn a claim into
  evidence, and does not accept an ADR. Live actions still require an explicit
  per-action owner "go".

## Goals and non-goals

### Goals

- Same identity, contact, channel and call semantics as Android v15: the
  core decides, the platform only stores, transports and renders.
- Registration, own-ID QR, scanning and pasting a `paranoid-contact-v2`
  contact, fingerprint confirmation, E2EE text with one/two check receipts,
  block/unblock, and foreground call-v2 calls with mute, speaker and the
  camera controls.
- Pinned TLS to the same server leaf SPKI as Android, evaluated on
  `Security.framework`: the same eight leaf checks as
  `PinnedTls.java:54-70`, plus a ninth group of session rules — Android's TLS
  1.2 floor and client-certificate refusal, and three challenge rules with no
  Android counterpart that the URL loading system makes possible.
- Storage on the device only: Keychain-wrapped AES key plus a Data
  Protection file, atomic commit with read-back, freeze on ambiguity.
- Reproducible manual build (`xcodebuild`, pinned Xcode 26.6 / SDK 26.5 /
  Swift 6.3.3 / Rust 1.98.1), no XcodeGen, no CocoaPods, no third-party Swift
  packages; the only binary dependency is the WebRTC iOS xcframework
  `150.7871.01`, the same upstream release line as the Android AAR.
- Component-boundary discipline: the client pull request changes only
  `clients/ios/**`, `docs/**`, `README.md`, `CHANGELOG.md` and its own
  workflow; `server/`, `clients/core/src/`, `clients/android/`,
  `key-protocol/` and `deploy/` are never touched.
- Honest evidence: requirement-to-test mapping with explicit `NOT RUN` rows;
  simulator results are never presented as phone results.

### Non-goals

- Push notifications (APNs/PushKit), background delivery, background app
  refresh and any system call UI (CallKit). Incoming messages and calls are
  delivered only while the application is open; this is a documented,
  user-visible limitation (track B, separate proposal).
- In-app updates: distribution is TestFlight only; no `/v2/updates/*` client.
- TLS pin or certificate rotation before the current leaf expires on
  2026-12-12 after the same-key renewal of 2026-09-13; rotating the key itself
  remains a deploy-trust decision for a separate RFC (question 7).
- Media **attachments** (images, files, recorded video, voice messages): not
  present on Android either (REQ-MSG-001 is draft); track C. Camera video
  inside a call is in scope — that is call-v2, not an attachment.
- Multi-device, identity recovery, a second realm, blockchain naming, server
  selection UX, Secure Enclave wrapping of the AES key, Bluetooth device
  route callbacks, a paid macOS CI runner.
- Any change to `clients/core`, `key-protocol`, the server or deployment. If
  the core does not compile or link for iOS without changes, or the core SDP
  validator rejects iOS-generated SDP, the work stops and the finding goes to
  the owner as an issue with a proposed fix; the client does not patch the
  core.

## Proposed design

```text
SwiftUI app (clients/ios/App)
  -> ParanoidKit (Swift package: storage, TLS, transport, realtime, calls, UI model)
  -> C-ABI static library clients/ios/bridge (paranoid_core_command / paranoid_core_free)
  -> paranoid-client-core (rlib, unchanged) -> paranoid-key-protocol (unchanged)
Network: URLSession + pinned-leaf delegate -> https://<realm>:38443 (self-service v2 router)
Calls: WebRTC.xcframework 150.7871.01 <-> peer DTLS-SRTP; call-v2 Opus audio +
  H.264/VP8 camera video, one publication per call; relay only via /v2/voice/turn
```

### Protected domains touched (recorded in ADR-0014)

1. **Foundational dependency.** The WebRTC iOS xcframework `150.7871.01`
   from the same `webrtc-sdk` release line as the Android dependency, pinned
   by archive and per-slice digests, verified before extraction, notices
   bundled. Nothing else is downloaded at build time except Rust crates from
   the locked graph.
2. **Storage boundary.** The core snapshot is sealed with an AES-256 key held
   in the Keychain (`kSecClassGenericPassword`, account
   `paranoid-text-state-v0`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   pending question 3, not synchronizable) and written to
   `Application Support/paranoid/text-state.enc` with
   `.completeUntilFirstUserAuthentication`, excluded from backup, committed as
   temp file, `F_FULLFSYNC`, `rename`, byte-exact read-back, directory
   `F_FULLFSYNC`. Any failure freezes the process terminally, exactly as the
   Android `StorageGuard`/sealed-commit rule.

   **Install marker rule and why it differs from Android.** On Android the
   Keystore alias and the snapshot file die together at uninstall, so
   `StorageGuard.requireContinuity` (key XOR file → freeze) is sufficient. On
   iOS, Keychain items survive removal of the application while the container
   file does not; without an extra rule a reinstalled app would see "key
   without file" and freeze forever, or worse, could be tempted to reuse a
   stale key. The candidate therefore keeps an install marker in
   `UserDefaults` (`paranoid.install.v1`):

   | Marker | Keychain key | Snapshot file | Result |
   | --- | --- | --- | --- |
   | absent | any (stale) | absent | delete the key, write the marker, fresh install with a **new** identity |
   | present | present | absent | frozen (fail closed, no regeneration) |
   | present | absent | present | frozen (fail closed, no regeneration) |
   | present | absent | absent | fresh install (iCloud restore to a new device: marker restored, `ThisDeviceOnly` key and backup-excluded file are not) |

   A stale Keychain key is never used to "recover" anything. This is a
   platform note against `docs/clients/core/self-service.md:99-102`
   ("missing snapshot ... fail closed") and
   `docs/protocol/first-contact-v1.md:173-178`; it is reported as
   discrepancy 12 for the owner and does not change the fail-closed rule when
   the marker is present. Reinstalling the application therefore starts a new
   ID; the frozen screen says so (`Переустановка приложения начнёт с нового
   ID.`).
3. **Security boundary.** Leaf-SPKI pinning is evaluated by the client on
   `Security.framework` primitives, not by delegating to system trust: exactly
   one certificate, SHA-256 of SPKI DER equals the saved pin (constant time),
   validity window, no unknown critical extensions and no CA basic constraint,
   self-signed and signature verified with the leaf key, server-auth key usage
   and EKU, EC ≥ 256 / RSA ≥ 2048, SAN-only host match (IP literal or exact
   dNSName, no CN, no wildcard), TLS 1.2 minimum, no client certificates. The
   pin is the same value Android carries (`KeyClient.java:10`); saved trust
   wins over compiled defaults; no second pin and no rotation path are added.
   App Transport Security is switched off in the bundle
   (`NSAllowsArbitraryLoads = YES`, the only key under
   `NSAppTransportSecurity`): on a physical iPhone, found 2026-09-13, ATS
   refused the self-signed leaf on a public IP address before the pinning
   delegate ran (`NSURLErrorDomain -1200`), a LAN stand never shows it, and
   `NSPinnedDomains` does not match an IP literal. The source contract test
   holds exactly that key and refuses any `URLSession` created outside
   `PinnedSessionDelegate`; the reasoning is recorded in ADR-0014 and the
   [threat delta](../security/ios-client-threats.md).
4. **Protocol compatibility.** A second client on the same contracts. Every
   behaviour is written from `docs/protocol/*.md` and the core; Java is only a
   cross-check. The rule-to-source table is
   [protocol-sources.md](../clients/ios/protocol-sources.md).

### Not touched

Identity derivation, key material, E2EE semantics (one shared Olm Account,
intro-v2, PlainV1, receipts), federation, persistence formats of the core
(schema 3 inside an outer version-4 wrapper identical to Android's), the
server, its routes and limits, deployment topology and the TLS pin itself.
The realm is `https://157.180.49.125:38443` with pin
`8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`, unchanged.

### Behaviour the platform must provide itself

The core is deliberately clock-free and storage-free, so the platform owns:
monotonic session renewal at about 240 s (the documented 300 s clamp is not in
any code; discrepancy 4), the realtime loop with `messages`-before-`events`
resume and one fresh-nonce retry after a first 401, the volatile call
controller (readiness slots, nonces, 45 s ring, 10 s heartbeat, 30 s silence,
15 min maximum, +5 s future-skew rejection; discrepancy 8), microphone consent
before any capture, and the relay credential lane. The iOS call controller is
written to the same state machine as `CallController.java` and cross-checked
against its smoke test scenarios.

## Alternatives

Compared in [proposed ADR-0014](../decisions/0014-ios-client.md): the Kotlin
Multiplatform scaffold from closed PR #1 (abandoned), UniFFI-generated
bindings (excessive for one function), a pure-Swift reimplementation of the
core (would duplicate a protected domain), the selected thin C-ABI bridge, and
XcodeGen for project generation (rejected: an additional unpinned binary).

## Security and privacy

- Assets: the core snapshot (private keys and plaintext history) at rest;
  the AES key in the Keychain; session context in memory; TURN credentials in
  memory only; camera frames during scanning (never written).
- Attackers and observers: the server operator (unchanged metadata), the
  relay operator (address, timing, volume), a device thief (Data Protection
  and Keychain class bound this), Apple as the TestFlight distributor and
  installation observer, the WebRTC binary supply chain (digest pinning).
- No new observer of delivery timing is introduced: no APNs/PushKit. Threat
  model boundary 8 stays unused by this client (discrepancy 11).
- Export compliance: the app ships non-standard E2EE (vodozemac/Olm);
  `ITSAppUsesNonExemptEncryption` and the annual self-classification report are
  an owner decision before the first upload (question 8).
- Screen capture is **not** parity with Android: `FLAG_SECURE` has no iOS
  equivalent, so the client covers the video stage while `UIScreen.isCaptured`
  reports a recording, mirror or AirPlay, and a screenshot and the app-switcher
  snapshot remain open gaps.
- The dedicated threat delta is
  [docs/security/ios-client-threats.md](../security/ios-client-threats.md).

## Compatibility and migration

- Same wire versions as Android v15; no version negotiation change. A 404 on
  session or events routes triggers pinned `/health` rediscovery exactly as
  Android does; a 404 `turn_disabled` on `/v2/voice/turn` follows Android
  parity unless the owner answers question 5 differently.
- No migration: there is no previous iOS state. Reinstall is a clean install
  (see install marker rule). Rollback is removing the TestFlight build; the
  two hosted accounts this branch created (one from the build Mac, one for
  the iPhone) stay on the server (REQ-MSG-004: no deletion path).
- The Android client is not modified; interoperability is proven only by the
  joint tests in the validation plan.

## Operations and observability

- No server-side change, configuration or deployment. Two additional hosted
  accounts exist under question 4 (no fixed budget): one `service-bridge`
  registration from the build Mac while diagnosing the phone's TLS failure
  and one for the contributor's iPhone, both counted in the evidence
  directory; simulators use only a local stand (unchanged server binary plus
  local PostgreSQL 16 on the build Mac), and the phone's local-stand smoke
  used that same stand bound to the Mac's LAN address.
- Build outputs, logs and evidence JSON live under `clients/ios/out/`
  (ignored); durable evidence goes to `docs/project/evidence/ios-client-<date>/`.
- **One Ubuntu job lands with this pull request, and has run on it.**
  `.github/workflows/ios.yml` adds `ios-static`: the iOS-target `cargo check`
  of the bridge and the unchanged core, bridge clippy and host tests,
  lock-file drift, the toolchain and WebRTC pins, the two source-only
  contracts, the full notices run, and the boundary gate on pull requests.
  `server.yml` is not touched, and the existing informational-red
  `legacy-client-history` job is unrelated and stays as it is. `docs.yml`
  gains exactly two lines: lychee `--exclude` entries for
  `.../issues/27` and `.../issues/27#issuecomment-5651949919`, which this
  branch is the first to cite and which lychee cannot resolve in a private
  repository — the same treatment the surrounding list already gives issues 16
  and 19. The workflow's first execution was the draft pull request that
  carries it, [#36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36):
  `ios-static` passed, as did the `markdown` job of `docs.yml` and the
  `client-core-and-tls` and `native-package` jobs of `server.yml`; the
  informational `legacy-client-history` job fails on `main` too. Every check
  in `ios-static` was also run locally on the pinned build Mac with exit 0,
  and the verification table records those local runs. The one `run` line
  that is runner setup rather than a check,
  `rustup toolchain install`, was not re-run on a Mac that already pins
  1.98.1. An iOS *build* in CI would still need a macOS runner, which question
  6 answers with "no".
- The app logs no snapshot bytes, no credentials and no plaintext.

## Validation plan

The requirement-to-test mapping with honest `NOT RUN` rows is
[docs/clients/ios/verification.md](../clients/ios/verification.md); the
rule-to-source table used to write and review behaviour is
[docs/clients/ios/protocol-sources.md](../clients/ios/protocol-sources.md).
Acceptance for delivered behaviour follows policy item 4: simulator, local
stand and dependency results are recorded as `CLAIMED`, physical-phone results
as `SHOWN`, and missing phone evidence stays `NOT RUN`. A simulator never
substitutes for a phone.

What has been run, in one sentence each:

- two clients exchange text, receipts, QR contacts and block/unblock on a local
  stand, including the fault scenarios and a reinstall — `CLAIMED`;
- two simulators place and answer call-v2 calls in both directions over direct
  ICE, about 2300 RTP packets per side per call — `CLAIMED`;
- the pinned-TLS leaf checks, the storage commit and fault matrix, the call
  state machine and the TURN lane run offline — `CLAIMED`;
- the Android cross-test runs: the real Android facade is compiled on this
  machine and exchanges identities, text, call-v2 bodies, sealed snapshots and a
  QR contact with the Swift client, with the expectations recomputed in Python
  rather than taken from the shared core — `CLAIMED`, because it is a host
  comparison and not a device result; contact with the owner's Android on its
  own hardware is the joint session of 2026-09-14, recorded below;
- a signed Debug build on the contributor's iPhone 16 Pro Max (iOS 26.6.1)
  against the local stand reached over the Mac's LAN address: identity, own
  QR, a contact read off the Mac's screen with the real camera, the
  fingerprint sheet, two texts phone→peer and one peer→phone with receipts,
  and one call phone→simulator that connected with video from the phone —
  `SHOWN`;
- a Release build on the same iPhone against the hosted alpha: registration,
  the owner's Android paired from his QR image, one text accepted by the
  server with one check — a solo pre-run of stage 1, not the joint test;
  delivery to the owner's phone and his reply had not yet happened;
- the joint session of 2026-09-14 on the hosted alpha, from that same Release
  build: the owner's QR scanned with the iPhone camera and his contact paired,
  text delivered both ways with both checks on the iPhone, and a call he
  placed from his Android that connected with audio in both directions and
  video from both cameras — `SHOWN (joint, reported)`, the contributor's
  report given immediately afterwards and not a capture, with no owner "go"
  permalink because the session was unscheduled. His Android is therefore v16
  or later, since call-v2 rejects v1 bodies; the exact version was not asked
  for;
- what still needs a device or the owner — the Data Protection class of the
  state file, screen lock during dialling, a real screen recording over the
  call stage, a relayed call, an archive, an `.ipa` export, a TestFlight build
  and the parts of the two joint tests that session did not reach (stage 1
  steps 7-15, and stage 2 steps 1-3, 5-7 and 10-17, among them an outgoing
  call from this client to an Android on real phones) — `NOT RUN`. One open
  item from 2026-09-13: after a network drop the phone stayed at «Нет
  подключения» while the server answered and the pinned key was unchanged; the
  cause is under investigation on the branch and no device log was collected for
  that drop. A second and different failure followed the joint session, at
  07:06 (Europe/Moscow) on 2026-09-14, measured and posted to
  [pull request #36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#issuecomment-5658890864):
  the iPhone shows «Нет подключения» and does not recover, and a Debug build
  on the same device with its console attached — the first direct read of this
  client's failure — logged `realtime: lane failed: NSURLError Code=-1001 "The
  request timed out."` four times in 45 s for
  `/v2/messages?after=1259&limit=20`. The pinned handshake did not fail and
  the route is alive (the same URL unsigned answers 401 from the build Mac in
  0.19 s and `/health` in 0.2 s with the pin unchanged), so what hangs is the
  signed read that opens a generation, before the lane ever reaches the long
  poll; relaunching the application does not clear it. The 8 s read timeout
  for that route is shared with Android
  (`clients/android/src/org/paranoid/text/RealtimeTransport.java:36`) and is
  not an iOS divergence.

Two joint tests with the owner are the only live tests, both on a real iPhone,
both written in advance with every `Result` column reading `NOT RUN`:
[stage 1, text](../project/evidence/ios-client-20260913/stage1-text.md) and
[stage 2, calls](../project/evidence/ios-client-20260913/stage2-voice.md).
Both are now **partly run**. A live test requires an explicit owner "go"; the
session of 2026-09-14 was unscheduled, so no such permalink exists for it and
none is claimed here. That session covered stage 1 steps 4, 5 and 6 and stage
2 steps 4, 8 and 9, each recorded as `SHOWN (joint, reported)` — the
contributor is the only participant those files have, and the result is his
report rather than an observation or a recording. Every other row keeps
`NOT RUN` with its reason, including the whole Android side of the pairing
(the owner did not scan this client's QR) and the fingerprint compared aloud.
On 2026-09-13 the contributor alone exercised stage 1 steps 1, 2, 4 and the
first half of 5 (one check, no reply yet) against the hosted server with the
owner's QR image; that is a pre-run, not the joint test, and the iPhone's
hosted registration was consumed before the stage, with the session of
2026-09-14 consuming none.

## Closed-alpha scope (policy item 1)

- Features: self-service registration on the hosted alpha, QR contact
  exchange in both directions, E2EE text with receipts, E2EE voice calls
  while both applications are open.
- Devices: the contributor's iPhone (TestFlight internal group) and the
  owner's Android phone (recorded in evidence). For stage 2 that Android build
  must be **v16 or later**: call-v2 rejects v1 call bodies, so an older build
  can exchange text with this client but cannot call it.
- Data: synthetic test messages only; no real or sensitive communication.
- Environment: the existing hosted alpha `https://157.180.49.125:38443` with
  the retained pin, and TestFlight internal testing; no other endpoint.
- Human risk owner: `martadvix-web`.
- Permanent owner approval of exactly this scope: **pending**. The recorded
  [delegation](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)
  gives the contributor technical decision authority; it is not scope approval
  and not acceptance of this ADR, and no live action follows from it.
- Independent AI review (policy item 2): to be run in a fresh context on the
  exact review revision; reviewer model, revision, findings and resolutions
  will be recorded in the client pull request. It is not a human audit.

## Open questions

Answers recorded on 2026-09-13 come from the contributor acting under the
owner's delegation of technical decision authority, recorded at
[issue #27, comment 5651949919](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
The delegation makes these technical decisions; it does not waive independent
review, does not replace evidence, and is not the ADR acceptance
[the documentation policy](../governance/documentation-policy.md) requires from
the human decision owner.

| # | Question | Status |
| --- | --- | --- |
| 3 | Keychain class for the wrapping key: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a locked screen during a call cannot turn a heartbeat commit into a terminal freeze. | Answered 2026-09-13: confirmed. |
| 4 | Hosted account budget for the contributor's iPhone. | Answered 2026-09-13: as many as the tests need, no fixed budget. Each registration is still recorded in the evidence directory, because the server cannot delete an account. Two were consumed on 2026-09-13: one from the build Mac while diagnosing the phone's TLS failure and one for the iPhone. |
| 5 | `404 turn_disabled` on `/v2/voice/turn`: disclosed direct-ICE mode or refuse the call? | Answered 2026-09-12 by the owner's agents in issue #27: a valid authenticated 404 from the pinned origin permits the pre-disclosed direct-ICE mode; a TLS failure, a timeout, a malformed 200 or a relay failure does not. |
| 6 | Paid macOS CI runner for the iOS build. | Answered 2026-09-13: no. Ubuntu checks plus the local `build.sh` and an evidence directory. |
| 7 | Pin and certificate rotation. | Partly answered 2026-09-13: the owner renewed the certificate with the **same key**, so the SPKI pin is unchanged and both clients keep working; the new validity ends 2026-12-12T07:38:09Z. Verified independently from this machine: the live SPKI equals the pin this client carries. A same-key renewal is therefore the safe path and must be repeated before that date; the [bounded same-key automation](../operations/tls-auto-renewal.md) installed on the host on 2026-09-13 does that, outside this client. Rotating the key itself stays open and needs its own deploy-trust RFC, because `clients/core/src/intro_v2.rs:21-44` feeds the pin into the first-contact channel transcript, so a new key invalidates existing contact channels and not only the transport. |
| 8 | Apple export compliance and the entity that files. | Partly answered 2026-09-13: `ITSAppUsesNonExemptEncryption = YES` is prepared in the bundle as the conservative candidate. That key is not compliance: answering yes normally also requires a code Apple issues after reviewing the documentation, and the requirement applies to TestFlight too. The classification, the regime and the filing entity stay open; the publicly-available-source route is not available while the repository is private. Inventory and gate: [export compliance](../clients/ios/export-compliance.md). |
| 10 | Which doc-to-code findings are fixed in a docs-only pull request and which are waived. | Answered 2026-09-12 by the owner's agents in issue #27: a docs-only pull request for the factual corrections, with five items reframed rather than applied verbatim. Recorded in `docs/clients/ios/protocol-sources.md`. |
| 11 | JDK 21 on the build Mac for the Java cross-checks. | Answered 2026-09-13: installed (21.0.12.1, tests only, pinned in `clients/ios/toolchain.json`). |

Questions 1, 2 and 9 were closed earlier by owner decision: bundle id
`global.paranoid.messenger`, a reinstall is a clean install, and the reference
client is the Android build on `main`.

## Decision and follow-up

- Disposition: open (`proposed`); the decision deadline is 2026-10-15. Moving
  further requires the closed-alpha scope approval permalink, the independent
  AI review of the exact review revision, and the phone evidence the validation
  plan names.
- Decision-owner approval permalink: pending.
- Delegation evidence permalink:
  <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919>
  (technical decision authority only; not scope approval, not ADR acceptance).
- Required-review evidence permalinks: the independent AI review is recorded
  in [independent-review.md](../project/evidence/ios-client-20260913/independent-review.md),
  separately from human reviewers; no human reviewer permalink exists yet.
- Resulting ADR: [proposed ADR-0014](../decisions/0014-ios-client.md).
- Closure rationale for `completed`, `rejected`, `withdrawn`, or `superseded`:
  none yet.
- Replacement RFC for `superseded`: not applicable.
- Implementation issues: the findings issue "Findings from iOS-client
  preparation" is
  [issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27), where the
  owner's agents answered questions 5 and 10 on 2026-09-12 and where the
  delegation was recorded on 2026-09-13; this client pull request, opened as
  draft [#36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36); and the
  docs-only pull request question 10 allows, which is a separate change and is
  **not** part of this one.
