---
status: draft
owner: ios
last_reviewed: 2026-09-11
---

# iOS client documentation (candidate, RFC-0019)

Component documentation for the native iOS client proposed in
[RFC-0019](../../rfcs/0019-ios-client.md) and recorded as
[draft ADR-0013](../../decisions/0013-ios-client.md) for
[REQ-CLIENT-001](../../product/requirements.md). Everything here describes a
**candidate**: no iOS build, simulator result, phone result, hosted account or
TestFlight upload exists at the time of writing, and no architecture is
accepted. The source entry point is [`clients/ios/README.md`](../../../clients/ios/README.md).

## What the candidate is

A native SwiftUI shell over the unchanged shared Rust core (`clients/core`),
reached through a thin C-ABI bridge crate, speaking exactly the contracts the
Android v15 client speaks: [self-service v2](../../protocol/self-service-v2.md),
[realtime v1](../../protocol/realtime-v1.md),
[first-contact v1](../../protocol/first-contact-v1.md),
[voice v1](../../protocol/voice-v1.md) and
[voice TURN v1](../../protocol/voice-turn-v1.md). Screens and Russian UI strings
follow Android word for word (`Создать ID`, `Чаты`, `Контакты`, `Мой ID`,
`Отпечаток совпадает`); the Android client is the behavioural reference, and
the shared [core contract](../core/self-service.md) and
[core voice controls](../core/voice-calls.md) apply unchanged.

## Differences from Android (by design)

- No in-app updates: distribution is TestFlight.
- No background delivery, no push, no CallKit: incoming messages and calls
  arrive only while the application is open. The connection screen states
  this in full; the chat list shows the short hint.
- Reinstalling the application is a clean install with a **new** identity,
  detected by an install marker, because the Keychain outlives the app
  container while the state file does not. With the marker present, a missing
  or unreadable state file freezes the application exactly as Android does;
  keys are never regenerated over an existing file and a stale Keychain key
  is never reused. This platform note is reported as a doc-to-code
  discrepancy against [`self-service.md`](../core/self-service.md) and is
  not an owner-approved change to the fail-closed rule.
- Voice relay: `/v2/voice/turn` is used when the server issues credentials;
  the `404 turn_disabled` behaviour follows Android parity unless the owner
  decides otherwise (RFC-0019 question 5).

## Documents in this directory

- [verification.md](verification.md): requirement-to-test mapping with honest
  `NOT RUN` status; the validation plan referenced by RFC-0019.
- [protocol-sources.md](protocol-sources.md): each behaviour rule mapped to
  its `docs/protocol` line, the core/server line, the Java cross-check and any
  discrepancy. Filled in as the client is written.
- Planned with the client pull request, not present yet: `self-service.md`
  (storage, registration, contacts and text on iOS), `voice-calls.md`
  (call controller, audio session, WebRTC dependency), `build-and-testflight.md`
  (pinned toolchain, manual build, signing and upload gates), and the security
  delta `docs/security/ios-client-threats.md`.

## Boundaries and rules

- The client pull request changes only `clients/ios/**`, documentation,
  `README.md`, `CHANGELOG.md` and its own workflow; `server/`,
  `clients/core/src/`, `clients/android/`, `key-protocol/` and `deploy/` are
  never modified. Any bug found there is reported to the owner as an issue
  with a proposed fix.
- Live actions (installing on a phone through the company Apple account,
  registering on the hosted alpha, uploading to TestFlight) happen only after
  an explicit owner "go" whose permalink is recorded in evidence; without it
  the corresponding rows in [verification.md](verification.md) stay `NOT RUN`.
- English is the canonical language of these documents; Russian appears only
  inside quoted UI strings.
- Evidence directories are named `docs/project/evidence/ios-client-<YYYYMMDD>/`;
  build outputs and logs stay under `clients/ios/out/` and are not committed.
