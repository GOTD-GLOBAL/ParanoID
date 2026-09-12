---
status: draft
owner: ios
decision_owner: martadvix-web
required_reviewers: []
review_mode: closed-alpha-ai
last_reviewed: 2026-09-11
---

# ADR-0013: iOS client as a native SwiftUI shell over the shared Rust core

This record is a **draft**: the decision below is a candidate, not an accepted
architecture. It cannot move to `proposed` until the closed-alpha scope has a
permanent owner approval permalink and the open questions marked blocking are
answered. Nothing described here is built, reviewed or deployed at the time
of writing; [RFC-0019](../rfcs/0019-ios-client.md) carries the proposal text.

## Required review rationale

`required_reviewers` is empty under the bounded
[closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception):
private alpha, synthetic test data, one contributor device and the owner's
Android phone, the existing hosted endpoint. The human decision and risk owner
is `martadvix-web`. An independent AI review in a fresh context (policy item 2)
is recorded separately in the client pull request and never listed as a human
reviewer. Independent qualified human review of identity, cryptography,
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
[RFC-0019 Proposed design](../rfcs/0019-ios-client.md#proposed-design): the
install marker rule (Keychain outlives the container, so an absent marker means
a fresh install and stale keys are deleted, while marker-present ambiguity
freezes exactly like Android `StorageGuard`), `Security.framework` leaf-SPKI
evaluation with the same pin as Android, and WebRTC.xcframework `150.7871.01`.

## Decision

Candidate: adopt option 3, a native SwiftUI application over the unchanged
shared Rust core through a thin C-ABI bridge crate, with Keychain plus Data
Protection storage under the install marker rule, `Security.framework`
leaf-SPKI pinning to the retained server pin, and the digest-pinned WebRTC
iOS xcframework `150.7871.01`, for the bounded private synthetic-data alpha
only. The decisive reason is that it is the smallest boundary that keeps every
protected domain except the four named ones untouched and keeps the core the
single owner of protocol and cryptography.

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
  user-visible limitation stated on the connection screen.
- Every clock-dependent rule (session renewal, call timeouts, +5 s skew) is
  provided by the platform because the core is clock-free; parity with
  `CallController.java` must be proven by cross-checks, not assumed.
- The TLS pin baked into a TestFlight build is immutable; the current leaf
  expires on 2026-12-07 and there is no rotation path (question 7).
- iOS builds cannot run on the existing Ubuntu CI; a macOS runner is a cost
  decision (question 6).

### Risks and mitigations

- The core may not link for iOS, or its SDP validator may reject
  iOS-generated SDP: stop, report to the owner as an issue with a proposed
  fix, never patch the core; if voice fails the pull request ships text-only
  and this ADR's scope narrows.
- Reinstall semantics differ from Android (clean install by marker): stated
  in the frozen screen and in the platform note; the fail-closed rule is not
  weakened when the marker is present.
- Keychain class too strict (device locked during a call turns a heartbeat
  commit into a freeze): question 3 fixes the class before storage code is
  written.
- WebRTC binary supply chain: archive and per-slice digests verified before
  extraction; notices bundled; no runtime download.

## Validation

[docs/clients/ios/verification.md](../clients/ios/verification.md) maps
REQ-CLIENT-001, REQ-ID-005/007/008, REQ-MSG-002/003/005 and REQ-CALL-002/003
to planned checks and their status (`NOT RUN` until evidence exists);
[protocol-sources.md](../clients/ios/protocol-sources.md) maps each behaviour
to its protocol line, core/server line and Java cross-check. Simulator and
dependency builds are `CLAIMED`; only physical-phone joint tests with the owner
are `SHOWN`. The independent AI review of the exact review revision, the
boundary gate output and the CI run are recorded in the client pull request.

## Compatibility and migration

Same wire versions as Android v15; no server or core change; no data to
migrate. Rollback is removing the TestFlight build and the application; the
single hosted account created for the iPhone remains on the server because
REQ-MSG-004 provides no deletion path. Same-data rollback of the server is
unaffected because nothing on the server changes.

## What is needed from the owner for Apple (checklist)

- App Store Connect team invitation: done (access granted 2026-09-11, relayed
  by the contributor; no permalink). Bundle id `global.paranoid.messenger` per
  the v15 owner decision. Open: who creates the App ID (without the push
  capability), the owner or the contributor.
- App Store Connect API key (`.p8`, Key ID, Issuer ID) supplied only through
  the environment (`PARANOID_ASC_KEY_PATH`, `PARANOID_ASC_KEY_ID`,
  `PARANOID_ASC_ISSUER_ID`), file outside the repository, never in git or
  process arguments; Team ID through `PARANOID_IOS_TEAM_ID`.
- An internal TestFlight group containing the owner; the export-compliance
  decision (question 8); an explicit "go" with a permalink for each live
  action (install on the contributor's iPhone, the single hosted registration,
  the TestFlight upload).
- One GUI step the contributor performs by hand: the contributor's Apple ID in
  Xcode Accounts.

## Open questions with deadlines

The same table as [RFC-0019 Open questions](../rfcs/0019-ios-client.md#open-questions);
questions 3, 4, 5 and 8 block `proposed`, the others block specific steps.

| # | Question | Owner | Proposed deadline |
| --- | --- | --- | --- |
| 3 | Keychain class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for the wrapping key. Confirm. | martadvix-web | 2026-09-18 |
| 4 | Hosted account budget: exactly one account for the contributor's iPhone, no reserve, reinstall means a new authorization; who registers. | martadvix-web | 2026-10-01 |
| 5 | `404 turn_disabled` on `/v2/voice/turn`: disclosed direct-ICE parity with Android or refuse the call. | martadvix-web | 2026-09-25 |
| 6 | Paid macOS CI runner: yes or no (default no). | martadvix-web | 2026-10-01 |
| 7 | Pin/certificate rotation RFC before 2026-12-07: who and when, tied to the TestFlight build date. | martadvix-web | 2026-10-15 |
| 8 | Apple export compliance (`ITSAppUsesNonExemptEncryption`) and the filing entity, before the first upload. | martadvix-web | 2026-10-15 |
| 10 | Docs-only pull request versus waiver for each of the twelve doc-to-code discrepancies. | martadvix-web | 2026-10-01 |
| 11 | JDK 21 on the build Mac for Java cross-checks (tests only). | martadvix-web | 2026-09-18 |

## Disposition and acceptance evidence

- Disposition: none (draft)
- Disposition rationale: pending
- Decision owner and identity: martadvix-web (GitHub)
- Pull request URL: pending (client pull request not yet opened)
- Permanent disposition or approval evidence URL: pending
- Withdrawal author statement URL, if applicable: not applicable
- Delegation evidence URL, if applicable: not applicable
- Required-review evidence URLs: independent AI review pending; recorded
  separately from human reviewers
- Telegram message ID, sender mapping, timestamp, and exact approval text, if
  used: none recorded; the 2026-09-11 owner replies relayed by the contributor
  are not approval evidence
- Disposition date: pending
- Known limitations and follow-up: foreground-only delivery; no pin rotation
  path before 2026-12-07; voice scope may narrow to text-only if the core SDP
  validator rejects iOS SDP; twelve doc-to-code discrepancies await the
  owner's answer to question 10

## Links

- Requirement: [REQ-CLIENT-001](../product/requirements.md), REQ-ID-005/007/008,
  REQ-MSG-002/003/005, [REQ-CALL-002/003](../product/voice-calls.md)
- RFC: [RFC-0019](../rfcs/0019-ios-client.md)
- Threat model: [threat model](../security/threat-model.md); iOS threat delta
  `docs/security/ios-client-threats.md` is written with the client pull
  request, not yet present
- Experiment or benchmark: not applicable — bridge link, SDP and pinning spikes
  are recorded in the client pull request evidence when run
- Supersedes: none
- Superseded by: none
