---
status: proposed
owner: ios
decision_owner: martadvix-web
required_reviewers: []
review_mode: closed-alpha-ai
last_reviewed: 2026-09-14
---

# ADR-0014: iOS client as a native SwiftUI shell over the shared Rust core

This record is **proposed**, not accepted. The client described below is built
and its checks run on simulators and a local stand; on 2026-09-13 a signed
build was installed on one physical iPhone (iPhone 16 Pro Max, iOS 26.6.1),
ran the smoke on the local stand, registered on the hosted alpha and sent one
text the server accepted. On 2026-09-14 an unscheduled joint session with the
owner on the hosted alpha exchanged text both ways and carried one call with
both cameras on against his Android; that is the contributor's report,
recorded as `SHOWN (joint, reported)` in the two stage files, and most of both
scenarios stays `NOT RUN`. Three hosted accounts exist (the build Mac and the
iPhone on 2026-09-13, a diagnostic account from the build Mac on 2026-09-14),
no TestFlight build was uploaded, neither joint test is complete, and no
independent human review has happened. It cannot move to `accepted` until the
closed-alpha scope has a permanent owner approval permalink, the independent
AI review of the exact review revision is recorded, and the physical-phone
joint-test evidence the validation plan names exists.
[RFC-0021](../rfcs/0021-ios-client.md) carries the proposal text.

## Required review rationale

`required_reviewers` is empty under the bounded
[closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception):
private alpha, synthetic test data, one contributor device and the owner's
Android phone, the existing hosted endpoint. The human decision and risk owner
is `martadvix-web`. An independent AI review in a fresh context (policy item 2)
is recorded in
[independent-review.md](../project/evidence/ios-client-20260913/independent-review.md)
and never listed as a human reviewer. Independent qualified human review of identity, cryptography,
persistence and application security remains required before any expansion
beyond this scope (policy item 6).

## Context and problem statement

REQ-CLIENT-001 requires Android and iOS clients. Android v15 (`fe9c26c`) is a
native Java shell over the shared Rust `clients/core` reached through JNI. The
iOS client must reach the same core without changing it, speak the same wire
contracts against the same hosted alpha, and keep the same E2EE, identity and
trust properties, while the platform storage and TLS primitives differ. The
decision is how to bind Swift to the core, how to store sealed state on iOS,
how to pin TLS, and which media dependency to accept; it is needed before the
first line of client code so that later review compares against a stated
boundary. It touches four
[protected domains](../governance/documentation-policy.md#protected-decision-domains):
foundational dependency, storage boundary, security boundary and protocol
compatibility.

## Decision drivers

- Zero changes to `clients/core/src`, `key-protocol`, `server` and `deploy`
  (red zones; owner approval required for any change).
- One binary artifact dependency at most, digest-pinned, with bundled notices,
  matching the Android WebRTC release line (`150.7871.01`).
- Reproducible manual build with the pinned toolchain (Xcode 26.6, SDK 26.5,
  Swift 6.3.3, Rust 1.98.1), no generated projects, no package managers
  beyond SwiftPM for local targets.
- Behaviour written from `docs/protocol/*.md` and the core, with Java used
  only as a cross-check; discrepancies reported, not silently resolved.
- Fail-closed storage identical in spirit to Android, adapted to Keychain
  persistence across application removal.
- Component boundary enforceable by one script in CI and locally.

## Considered options

1. **Kotlin Multiplatform shared client (closed PR #1).** The unmerged
   "identity foundation and mobile conformance" pull request scaffolded a
   Gradle/KMP module (`clients/shared/identity-conformance`) with an iOS
   simulator target. Abandoned: the pull request was closed on 2026-09-08
   without merge, ADR-0002 was never accepted, the shipped Android client is
   plain Java over Rust, and a KMP layer would add a JVM/Kotlin toolchain and
   a second implementation of core logic on iOS.
2. **UniFFI-generated Swift bindings.** Generates a typed Swift API from the
   Rust crate. Excessive here: the core exposes exactly one function,
   `command(state, request) -> Result<String, &str>` (`clients/core/src/lib.rs:418`),
   with JSON in and JSON out; UniFFI would add a code generator, a build-time
   binary and a scaffolding crate to wrap one call.
3. **Thin C-ABI bridge crate (selected candidate).** A new crate
   `clients/ios/bridge` depends on `paranoid-client-core` by path, exports
   `paranoid_core_command` and `paranoid_core_free` with `catch_unwind`, null
   and UTF-8 checks, and is built as a static library into an xcframework;
   Swift calls it through a module map. The core's own 8 MiB / 65536-byte
   input limits stay inside `command`. The rlib crate type is kept only for
   host tests and clippy. This mirrors the Android `CoreBridge` JNI shim in
   size and responsibility.
4. **Pure-Swift reimplementation of the core.** Rejected: it would duplicate
   identity, Olm, intro-v2, PlainV1 and validation logic, a protected domain,
   and would need its own independent cryptographic review.
5. **XcodeGen-generated project.** Rejected: an additional unpinned binary in
   the build path; the checked-in `.xcodeproj` plus a SwiftPM package is
   sufficient and reviewable as text.

Storage, pinning and media sub-decisions within option 3 are recorded in
[RFC-0021](../rfcs/0021-ios-client.md#proposed-design). The current correction
creates the wrapping key only at first commit; marker-present key/file XOR has
no defaults-based exception. The existing install.v1 reinstall distinction,
Security.framework pinning and WebRTC dependency remain. See
[the correction handoff](../clients/ios/lazy-storage-handoff.md) for exact crash
cost, transition matrix and pending Mac tests. This is a candidate requested by
the contributor, not an accepted architectural decision.

## Decision

Candidate: adopt option 3, a native SwiftUI application over the unchanged
shared Rust core through a thin C-ABI bridge crate, with Keychain plus Data
Protection storage under the install marker rule, `Security.framework`
leaf-SPKI pinning to the retained server pin, and the digest-pinned WebRTC
iOS xcframework `150.7871.01`, for the bounded private synthetic-data alpha
only. The decisive reason is that it is the smallest boundary that keeps every
protected domain except the four named ones untouched and keeps the core the
single owner of protocol and cryptography.

The call contract this client implements is
[call-v2](../protocol/call-v2.md) — two media sections, audio then video, both
`a=sendrecv`, H.264 first with VP8 as the mandatory fallback, camera on/off as
a track flag plus an informative `media` control and never a renegotiation, and
a 9000-byte description cap below the measured 10040-byte frame2 ceiling.
RFC-0021 was drafted against voice v1; `main` moved to call-v2 under RFC-0019
and proposed ADR-0013 while this client was being written, and the client
follows `main`. call-v2 rejects v1 bodies, so this client cannot call an
Android build older than v16.

The delegation of technical decision authority to the contributor is recorded
at
[issue #27, comment 5651949919](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
It settles the technical open questions below. It does not waive independent
review, does not convert a simulator result into evidence, and does not accept
this ADR — acceptance remains the human decision owner's.

**App Transport Security.** The bundle turns ATS off (`NSAllowsArbitraryLoads`).
On a device ATS blocks a self-signed leaf on a public IP before the pinning
delegate runs, and it offers no exception keyed by an IP literal, so a pinned
server without a domain name is unreachable with it on. The client relies on its
own pin, never on a CA chain, and a contract test forbids any session outside
the pinning delegate; the threat delta records the measurement. This is a
security-boundary detail of this decision, not a widening of it.

## Consequences

### Positive

- One protocol implementation (the core) for both clients; iOS cannot drift
  in identity, channel or E2EE semantics.
- The bridge crate is auditable in one screen; the boundary gate script can
  reject any diff outside `clients/ios/**` and documentation.
- Storage and TLS behaviour are testable without a network or a device
  (DER fixtures, injected file-system failures).

### Negative

- Foreground-only delivery: no push, no background delivery, no CallKit;
  messages and calls arrive only while the application is open. This is a
  user-visible limitation stated on the connection screen, and it makes a call
  to a locked or closed iPhone end in the caller's expected 45-second
  `timeout` rather than in a ring.
- Screen capture is not parity with Android: `FLAG_SECURE` has no iOS
  equivalent, so the client covers the video stage while the screen is being
  recorded, mirrored or AirPlayed, and a screenshot and the app-switcher
  snapshot remain outside what it can refuse.
- CI covers only what Ubuntu can prove: `.github/workflows/ios.yml` lands with
  this pull request and runs the iOS-target `cargo check`, the bridge lint and
  host tests, the lock, toolchain and WebRTC pins, the source-only contracts,
  the full notices run and the boundary gate. Its first execution was on the
  client pull request (#36, opened as a draft on 2026-09-14), where
  `ios-static` passed; there is no macOS runner, so no simulator, app bundle,
  stand or device result can ever come from it. Those checks were run locally
  on the pinned build Mac and the evidence directory records them.
- Every clock-dependent rule (session renewal, call timeouts, +5 s skew) is
  provided by the platform because the core is clock-free; parity with
  `CallController.java` must be proven by cross-checks, not assumed.
- The TLS pin baked into a TestFlight build is immutable; the current leaf
  expires on 2026-12-12 after the same-key renewal of 2026-09-13; the pin
  survives a same-key renewal, and only a key change would break enrolled
  contacts (question 7).
- iOS builds cannot run on the existing Ubuntu CI; a macOS runner is a cost
  decision (question 6).

### Risks and mitigations

- The core may not link for iOS, or its SDP validator may reject
  iOS-generated SDP: stop, report to the owner as an issue with a proposed
  fix, never patch the core; if voice fails the pull request ships text-only
  and this ADR's scope narrows.
- Reinstall semantics differ from Android (clean install by marker): stated
  in the frozen screen and in the platform note. Since 2026-09-14 a missing
  marker beside a state file also fails closed and deletes nothing — the
  reviewer's P1 — at the deliberate cost that lost defaults with a surviving
  file now need a person, which the owner should confirm rather than inherit.
- Welcome creates no persistent wrapping key. The first commit creates it
  before the candidate file is written. Keychain and filesystem are not one
  atomic transaction; a failure after key creation may freeze key-without-file
  on all later launches. This is an explicit availability cost and never
  permission to delete the key or start over automatically.
- Earlier valid key/file pairs remain usable; eager-key-only installations
  from previous candidates freeze. Old pending/commit defaults are ignored,
  removing their authority to turn lost history into a fresh client.
- Complete rollback/removal of both halves cannot be distinguished from an
  empty installation. No local anti-rollback or backup recovery is promised.
  The rejected expected-failure bookkeeping scenario is an ordinary regression
  in the correction; contributor Mac receipts for 0709212 and 628958b now
  record passing host and signed-simulator checks. Physical-device/upgrade/
  power-loss checks and human decision acceptance remain outstanding.
- Keychain class too strict (device locked during a call turns a heartbeat
  commit into a freeze): question 3 fixes the class before storage code is
  written.
- WebRTC binary supply chain: archive and per-slice digests verified before
  extraction; notices bundled; no runtime download.

## Validation

[docs/clients/ios/verification.md](../clients/ios/verification.md) maps
REQ-CLIENT-001, REQ-ID-005/007/008, REQ-MSG-002/003/005 and REQ-CALL-002/003
to the check that was actually run and its status;
[protocol-sources.md](../clients/ios/protocol-sources.md) maps each behaviour
to its protocol line, core/server line and Java cross-check. Simulator, local
stand and dependency results are `CLAIMED`; only physical-phone results are
`SHOWN`. Since the device smoke of 2026-09-13 the `SHOWN` rows are what one
iPhone did against the local stand (identity, a QR read off a real camera,
text with receipts, one call with video) and against the hosted alpha (one
registration, the owner's Android paired from his QR image, one text the
server accepted). The two joint-test scenarios were written in advance and are
now **partly run**: an unscheduled session with the owner on 2026-09-14
exercised stage 1 steps 4, 5 and 6 and stage 2 steps 4, 8 and 9, which read
`SHOWN (joint, reported)` — the contributor was the only participant this
record has, so each of those is his report given immediately afterwards, not
an observation by whoever writes the file and not a recording. Every other
`Result` stays `NOT RUN`, and no owner "go" permalink exists for that session,
because it was not planned:
[stage 1](../project/evidence/ios-client-20260913/stage1-text.md) and
[stage 2](../project/evidence/ios-client-20260913/stage2-voice.md); stage 1
carries a note that its steps 1, 2, 4 and the first half of 5 were pre-run
solo by the contributor on 2026-09-13, which is not the joint test. The
independent AI review of the exact review revision and the boundary gate output
are recorded in the client pull request, together with the `ios-static` run
of `.github/workflows/ios.yml`. The platform trust delta is
[docs/security/ios-client-threats.md](../security/ios-client-threats.md).

## Compatibility and migration

Same wire versions as Android v15; no server or core change; no data to
migrate. Rollback is removing the TestFlight build and the application; the
three hosted accounts this branch created — the build Mac and the iPhone on
2026-09-13, and a diagnostic account from the build Mac on 2026-09-14 while
issue #38 was being measured — remain on the server because REQ-MSG-004
provides no deletion path. The 2026-09-13 Mac account is registered but dead:
its fixture held the wrapping key in process memory only, so its state file no
longer opens; the diagnostic account of 2026-09-14
(`240060ebc49a9b7394f6fe4ccc30922e62dac9ae9a04ae89415423950ae16776`) keeps its
wrapping key beside its state in the git-ignored build output, has no messages
and no contacts, and is why a third registration exists at all.
Same-data rollback of the server is unaffected because nothing on the server
changes.

## What is needed from the owner for Apple (checklist)

- App Store Connect team invitation: done (access granted 2026-09-11, relayed
  by the contributor; no permalink). Bundle id `global.paranoid.messenger` per
  the v15 owner decision. An App ID for it exists on the team since the signed
  install of 2026-09-13, which went through `xcodebuild
  -allowProvisioningUpdates` with the team on the command line; the bundle
  gate read the signed entitlements that day and found no `aps-environment`.
- App Store Connect API key (`.p8`, Key ID, Issuer ID) supplied only through
  the environment (`PARANOID_ASC_KEY_PATH`, `PARANOID_ASC_KEY_ID`,
  `PARANOID_ASC_ISSUER_ID`), file outside the repository, never in git or
  process arguments; Team ID through `PARANOID_IOS_TEAM_ID`.
- An internal TestFlight group containing the owner; the export-compliance
  decision (question 8); an explicit "go" with a permalink for each live
  action (install on the contributor's iPhone, each hosted registration, the
  TestFlight upload). The install on the contributor's own iPhone and two
  hosted registrations happened on 2026-09-13, and a third, the diagnostic
  account registered from the build Mac on 2026-09-14 for the issue #38
  measurements; all three registrations fall under the owner's answer to
  question 4 (no fixed budget), with no separate permalink recorded; the
  TestFlight upload has not.
- One GUI step the contributor performs by hand: the contributor's Apple ID in
  Xcode Accounts.

## Open questions with deadlines

The same table as [RFC-0021 Open questions](../rfcs/0021-ios-client.md#open-questions).
Questions 3, 4, 5, 6, 10 and 11 are answered — 5 and 10 by the owner's agents
in [issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27) on 2026-09-12,
the rest by the contributor under the recorded delegation. Questions 7 and 8
stay partly open and are the two that still gate live actions: a key rotation
needs its own deploy-trust RFC, and **no TestFlight upload may happen until the
export-compliance gate is answered**. Acceptance of this ADR is blocked by the
missing scope-approval permalink and by the joint tests with the owner being
only partly run — the physical-phone evidence so far is the contributor's solo
device smoke and pre-run of 2026-09-13 plus his report of the unscheduled
session of 2026-09-14, which no owner permalink authorised and which left most
of both scenarios `NOT RUN` — not by the table below.

| # | Question | Owner | Proposed deadline |
| --- | --- | --- | --- |
| 3 | Keychain class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for the wrapping key. Confirm. | martadvix-web | 2026-09-18 |
| 4 | Hosted account budget: exactly one account for the contributor's iPhone, no reserve, reinstall means a new authorization; who registers. Answered 2026-09-13: as many as the tests need, no fixed budget; three consumed so far — the build Mac and the iPhone on 2026-09-13, and a diagnostic account from the build Mac on 2026-09-14 (no messages, no contacts) registered to measure the hosted server from a second identity while issue #38 was diagnosed, a third being needed because the 2026-09-13 Mac account kept its wrapping key in process memory only and can no longer be opened — each recorded in the evidence directory because the server cannot delete an account. | martadvix-web | 2026-10-01 |
| 5 | `404 turn_disabled` on `/v2/voice/turn`: disclosed direct-ICE parity with Android or refuse the call. | martadvix-web | 2026-09-25 |
| 6 | Paid macOS CI runner: yes or no (default no). | martadvix-web | 2026-10-01 |
| 7 | Key rotation RFC: who and when, tied to the TestFlight build date. The certificate itself was renewed with the same key on 2026-09-13 (valid to 2026-12-12), so this is no longer an outage deadline; the open part is what happens when the key changes. | martadvix-web | 2026-10-15 |
| 8 | Apple export compliance (`ITSAppUsesNonExemptEncryption`) and the filing entity, before the first upload. | martadvix-web | 2026-10-15 |
| 10 | Docs-only pull request versus waiver for each of the twelve doc-to-code discrepancies. | martadvix-web | 2026-10-01 |
| 11 | JDK 21 on the build Mac for Java cross-checks (tests only). | martadvix-web | 2026-09-18 |

## Disposition and acceptance evidence

- Disposition: open (`proposed`)
- Disposition rationale: the client exists, its behaviour is measured, one
  physical iPhone has run it against the local stand and registered on the
  hosted alpha, and an unscheduled joint session with the owner on 2026-09-14
  carried text both ways and one call against his Android as the contributor
  reports it, but the evidence that would justify acceptance — the
  physical-phone joint tests completed, under an owner approval, and an
  independent review — does not exist yet
- Decision owner and identity: martadvix-web (GitHub)
- Pull request URL: <https://github.com/GOTD-GLOBAL/ParanoID/pull/36> (draft,
  opened 2026-09-14)
- Permanent disposition or approval evidence URL: pending
- Withdrawal author statement URL, if applicable: not applicable
- Delegation evidence URL:
  <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919>
  — technical decision authority for the contributor; it is not scope approval,
  not acceptance of this ADR and not a substitute for independent review or
  evidence
- Required-review evidence URLs: the independent AI review is recorded in
  [independent-review.md](../project/evidence/ios-client-20260913/independent-review.md),
  separately from human reviewers; no human reviewer permalink exists yet
- Telegram message ID, sender mapping, timestamp, and exact approval text, if
  used: none recorded; the 2026-09-11 owner replies relayed by the contributor
  are not approval evidence
- Disposition date: pending
- Known limitations and follow-up: one physical iPhone has run the client
  (local-stand smoke and one hosted registration with one accepted text on
  2026-09-13, then the unscheduled joint session of 2026-09-14), but the joint
  tests with the owner are only partly run and `hosted_registrations` is 3 —
  the build Mac and the iPhone on 2026-09-13, and the diagnostic account
  registered from the build Mac on 2026-09-14 for the issue #38 measurements —
  all three accounts permanent, that session consuming none of them; the
  network-drop item of 2026-09-13/14 — after a network drop on the phone the
  application stayed at «Нет подключения» while the server answered from the
  Mac and the pinned key was unchanged — has a cause and a fix on the branch
  since 2026-09-14 (this client had no connectivity-change restart), but its
  proof is `NOT RUN`: no real change of network path was produced on any device
  and no device log was ever collected for that drop; separately, after the
  session of 2026-09-14 the phone stopped
  connecting and has not recovered, and a Debug build on the same device
  logged the signed read of `/v2/messages` timing out four times in 45 seconds
  while the pinned handshake stood and the route answered from the build Mac —
  measured in the pull request, and no relaunch clears it; the Data Protection
  class on the device, a real screen recording over the call stage, a relayed
  call and TestFlight are `NOT RUN`;
  foreground-only delivery, so a call to a locked or closed iPhone ends in the
  caller's 45-second `timeout`; screen capture is not parity with Android's
  `FLAG_SECURE`; no pin rotation path before the renewed leaf expires on
  2026-12-12; the export-compliance gate is closed, so no TestFlight upload is
  authorised; the Android cross-test is a host comparison (both stacks as
  processes on the Mac) and proves agreement of the checked scenarios at the
  checked revisions, not acceptance on devices — contact with the owner's
  Android on its own hardware is the reported session of 2026-09-14: his QR
  scanned with the iPhone camera, text carried both ways with both checks seen
  on this client for the first time, and one call in which both cameras were
  on, so his build is v16 or later because call-v2 rejects v1 bodies, though
  the exact version was not asked for; he did not scan the iPhone's QR, so the
  Android side of the pairing and the fingerprint compared aloud stay
  untested; twelve doc-to-code discrepancies are answered in issue #27 and are
  corrected in a separate docs-only pull request, not in this one

## Links

- Requirement: [REQ-CLIENT-001](../product/requirements.md), REQ-ID-005/007/008,
  REQ-MSG-002/003/005, [REQ-CALL-002/003](../product/voice-calls.md)
- RFC: [RFC-0021](../rfcs/0021-ios-client.md)
- Threat model: [threat model](../security/threat-model.md) and the
  [iOS client trust delta](../security/ios-client-threats.md)
- Component documentation:
  [storage, registration, contacts and text](../clients/ios/self-service.md),
  [calls](../clients/ios/voice-calls.md),
  [build and TestFlight](../clients/ios/build-and-testflight.md),
  [export compliance](../clients/ios/export-compliance.md)
- Experiment or benchmark: the bridge link, the call-v2 SDP spike against the
  core validator, the pinned-TLS leaf checks and the 2026-09-13 device smoke
  were run locally; their summaries are in the client pull request and the
  evidence catalogue, and their raw output stays under `clients/ios/out/`,
  which is not committed
- Supersedes: none
- Superseded by: none
