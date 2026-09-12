---
status: draft
owner: ios
decision_owner: martadvix-web
decision_deadline: 2026-10-15
required_reviewers: []
review_mode: closed-alpha-ai
last_reviewed: 2026-09-11
---

# RFC-0019: Native iOS client on the shared Rust core (track A)

This proposal is a **draft**. It describes a candidate second client for
[REQ-CLIENT-001](../product/requirements.md); nothing in it is accepted
architecture, and no iOS build, phone result or hosted registration exists at
the time of writing. The behavioural reference is the Android v15 client on
`main` `fe9c26c` as delivered by the owner; owner decisions take precedence over
every preference recorded here. The decision deadline in the front matter is a
placeholder that will be re-set when the client pull request is opened
(plan step 44, at least fourteen days after the review revision is ready).

## Required review rationale

`required_reviewers` is empty because the bounded
[closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception)
is requested for this private synthetic-data alpha (`review_mode:
closed-alpha-ai`). No independent qualified human domain reviewer is available
to the contributor; the human decision owner remains `martadvix-web` and is
never replaced by AI. The independent AI review required by policy item 2 will
be run in a fresh context, separate from the implementing context, and recorded
in the client pull request; it is not a human audit and does not appear in the
reviewer list. Protected domains touched by this proposal are listed in
[Proposed design](#proposed-design) and recorded in
[draft ADR-0013](../decisions/0013-ios-client.md). Before real sensitive
communication, public release or any production claim, independent qualified
human review of identity, cryptography, persistence and application security
remains required (policy item 6).

## Summary

Build a native SwiftUI iOS application that reuses the unchanged shared Rust
client core (`clients/core`) through a thin C-ABI bridge crate, speaks exactly
the wire contracts the Android client speaks (self-service v2, realtime v1,
first-contact v1, voice v1, voice TURN v1) against the existing hosted alpha,
and reproduces the Android screens and Russian UI strings for registration,
QR contact exchange, E2EE text with receipts and E2EE voice calls while the
application is open. No server change, no core change, no new key material
format and no new trust anchor are proposed. The client is delivered as a
pull request; merge, hosted registration and TestFlight distribution are owner
decisions taken separately.

## Motivation

- REQ-CLIENT-001 names iOS as a supported end-user client; today only Android
  exists.
- A second, independently written client is the first real test of the
  protocol documents as a contract rather than a description of one
  implementation. Preparing this client already surfaced twelve places where
  `docs/protocol`, `docs/clients` and code disagree; they are reported to the
  owner as findings, not silently resolved (open question 10).
- The owner confirmed on 2026-09-11 (Telegram, relayed by the contributor; no
  permalink retrieved, therefore not approval evidence) that the contributor
  works as a full developer delivering pull requests only, that documentation
  discrepancies may be corrected in a separate docs-only pull request, and that
  test accounts on the hosted alpha are permitted within a joint test. Live
  actions still require an explicit per-action owner "go".

## Goals and non-goals

### Goals

- Same identity, contact, channel and call semantics as Android v15: the
  core decides, the platform only stores, transports and renders.
- Registration, own-ID QR, scanning and pasting a `paranoid-contact-v2`
  contact, fingerprint confirmation, E2EE text with one/two check receipts,
  block/unblock, and foreground voice calls with mute/speaker.
- Pinned TLS to the same server leaf SPKI as Android, evaluated on
  `Security.framework` with the same nine checks as `PinnedTls.java`.
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
  2026-12-07; that is a deploy-trust decision for a separate RFC (question 7).
- Media attachments (images, files, video, voice messages): not present on
  Android either (REQ-MSG-001 is draft); track C.
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
Voice: WebRTC.xcframework 150.7871.01 <-> peer DTLS-SRTP/Opus; relay only via /v2/voice/turn
```

### Protected domains touched (recorded in ADR-0013)

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

Compared in [draft ADR-0013](../decisions/0013-ios-client.md): the Kotlin
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
- A dedicated threat delta (`docs/security/ios-client-threats.md`) is written
  with the client pull request, not in this skeleton.

## Compatibility and migration

- Same wire versions as Android v15; no version negotiation change. A 404 on
  session or events routes triggers pinned `/health` rediscovery exactly as
  Android does; a 404 `turn_disabled` on `/v2/voice/turn` follows Android
  parity unless the owner answers question 5 differently.
- No migration: there is no previous iOS state. Reinstall is a clean install
  (see install marker rule). Rollback is removing the TestFlight build; the
  hosted account created for the iPhone stays on the server (REQ-MSG-004: no
  deletion path).
- The Android client is not modified; interoperability is proven only by the
  joint tests in the validation plan.

## Operations and observability

- No server-side change, configuration or deployment. Exactly one additional
  hosted account for the contributor's iPhone (question 4); simulators use
  only a local stand (unchanged server binary plus local PostgreSQL 16 on the
  build Mac).
- Build outputs, logs and evidence JSON live under `clients/ios/out/`
  (ignored); durable evidence goes to `docs/project/evidence/ios-client-<date>/`.
- CI on Ubuntu covers the bridge crate, lock-file drift, dependency digests,
  notices and the boundary gate; an iOS build in CI needs a macOS runner
  (question 6). The existing informational-red `legacy-client-history` job is
  unrelated and stays as it is.
- The app logs no snapshot bytes, no credentials and no plaintext.

## Validation plan

The requirement-to-test mapping with honest `NOT RUN` rows is
[docs/clients/ios/verification.md](../clients/ios/verification.md); the
rule-to-source table used to write and review behaviour is
[docs/clients/ios/protocol-sources.md](../clients/ios/protocol-sources.md).
Acceptance for delivered behaviour follows policy item 4: simulator and
dependency builds are recorded as `CLAIMED`, physical-phone results as
`SHOWN`, and missing phone evidence stays `NOT RUN`. Two joint tests with the
owner (text and QR both ways; voice both ways with the apps open) are the only
live tests, both on a real iPhone, both after an explicit owner "go".

## Closed-alpha scope (policy item 1)

- Features: self-service registration on the hosted alpha, QR contact
  exchange in both directions, E2EE text with receipts, E2EE voice calls
  while both applications are open.
- Devices: the contributor's iPhone (TestFlight internal group) and the
  owner's Android phone running the build he chooses (recorded in evidence).
- Data: synthetic test messages only; no real or sensitive communication.
- Environment: the existing hosted alpha `https://157.180.49.125:38443` with
  the retained pin, and TestFlight internal testing; no other endpoint.
- Human risk owner: `martadvix-web`.
- Permanent owner approval of exactly this scope: **pending** (permalink to be
  recorded here before the ADR can move to `proposed`; a blanket instruction to
  proceed is not scope approval).
- Independent AI review (policy item 2): to be run in a fresh context on the
  exact review revision; reviewer model, revision, findings and resolutions
  will be recorded in the client pull request.

## Open questions

| # | Question | Owner | Proposed deadline |
| --- | --- | --- | --- |
| 3 | Keychain class for the wrapping key: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (needed so a locked screen during a call does not turn a heartbeat commit into a terminal freeze). Confirm. | martadvix-web | 2026-09-18 |
| 4 | Hosted account budget: exactly one new account for the contributor's iPhone, no reserve; a reinstall on the phone means a new registration and a new authorization; simulators never register on the host. Confirm and name who registers. | martadvix-web | 2026-10-01 |
| 5 | `404 turn_disabled` on `/v2/voice/turn`: disclosed direct-ICE mode with Android parity (`voice-turn-v1.md:131-135`) or refuse the call? Default is parity. | martadvix-web | 2026-09-25 |
| 6 | Paid macOS CI runner for the iOS build: yes or no? Default no: Ubuntu checks plus local `build.sh` and an evidence directory. | martadvix-web | 2026-10-01 |
| 7 | Pin/certificate rotation before 2026-12-07 is a separate deploy-trust RFC; who opens it and when, tied to the TestFlight build date so the first build already carries both pins. | martadvix-web | 2026-10-15 |
| 8 | Apple export compliance (`ITSAppUsesNonExemptEncryption`, E2EE/Olm) and the legal entity filing the self-classification report; decided before the first upload. | martadvix-web | 2026-10-15 |
| 10 | Which of the twelve doc-to-code discrepancies may be fixed in a docs-only pull request and which are waived until the client pull request; without one of the two answers the client pull request cannot merge. | martadvix-web | 2026-10-01 |
| 11 | JDK 21 on the build Mac (Homebrew, tests only) for Java cross-checks; without it those cross-tests stay `NOT RUN` locally. | martadvix-web | 2026-09-18 |

Questions 1, 2 and 9 are closed by owner decision (bundle id
`global.paranoid.messenger`, reinstall is a clean install, Android v15 at
`fe9c26c` is the reference). Deadlines are proposals to be confirmed with the
client pull request.

## Decision and follow-up

- Disposition: open (draft); this RFC moves to `proposed` only with a
  confirmed decision deadline, the validation plan above and the closed-alpha
  scope approval permalink.
- Decision-owner approval permalink: pending.
- Delegation evidence permalink, if applicable: not applicable.
- Required-review evidence permalinks: independent AI review pending (recorded
  separately from human reviewers).
- Resulting ADR: [draft ADR-0013](../decisions/0013-ios-client.md).
- Closure rationale for `completed`, `rejected`, `withdrawn`, or `superseded`:
  none yet.
- Replacement RFC for `superseded`: not applicable.
- Implementation issues: the findings issue "Findings from iOS-client
  preparation" (to be opened; number recorded here once it exists); the client
  pull request; the docs-only pull request if question 10 allows it.
