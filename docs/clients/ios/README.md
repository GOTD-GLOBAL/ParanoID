---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# iOS client documentation (candidate, RFC-0021)

Component documentation for the native iOS client proposed in
[RFC-0021](../../rfcs/0021-ios-client.md) and recorded as
[proposed ADR-0014](../../decisions/0014-ios-client.md) for
[REQ-CLIENT-001](../../product/requirements.md). Everything here describes a
**candidate**: no architecture is accepted. The source entry point is
[`clients/ios/README.md`](../../../clients/ios/README.md).

What exists and what does not, once and plainly: the client is built and its
checks run on simulators and a local stand, which makes those results
`CLAIMED`. On 2026-09-13 a signed build ran on a physical iPhone 16 Pro Max
(iOS 26.6.1) against the local stand — identity created, own QR shown, a
contact read off a screen with the real camera, the fingerprint sheet
confirmed, text with receipts in both directions and one call that connected
with video — so those rows are `SHOWN (phone, local stand)`. **Three hosted
accounts exist** (`hosted_registrations: 3`: one from the build Mac on
2026-09-13 while diagnosing the phone's TLS failure, one from the iPhone the
same day, and one diagnostic account from the build Mac on 2026-09-14; all
three under the owner's answer to RFC-0021 question 4, no fixed budget, and
all three permanent, because the server has no deletion path). The first is
registered but dead — that fixture kept its wrapping key in process memory
only, so its state file no longer opens — which is why a third had to be
registered rather than reused; that third carries no messages and no contacts
and exists only to read the hosted server from a second identity while
issue #38 is diagnosed, its key kept beside its state so the diagnosis needs
no further registration. The iPhone's account is the contributor's own and
still in use: it paired the owner's Android from his QR image and sent one
text the hosted server accepted, delivery to his phone still pending at that
point. On 2026-09-14 an unscheduled session with the owner on the hosted
alpha, using that same account, carried text both ways with his Android — both
checks on the iPhone for the first time — and one call he placed to it, on
which both sides turned their cameras on; the contributor is the only
participant that record has, so those rows read `SHOWN (joint, reported)` and
no owner "go" permalink exists for the session. **Both joint tests are only
partly run**, and everything neither covered stays `NOT RUN`. No archive, no
`.ipa` export and no TestFlight build exist. Two open items: after a network
drop the phone stayed at «Нет подключения» while the server answered and the
pinned key was unchanged, the cause under investigation on the branch; and
after the session of 2026-09-14 the phone stopped connecting altogether and
has not recovered — a separate failure, measured in pull request #36 and
tracked as issue #38. [verification.md](verification.md) says it row by row.

## What the candidate is

A native SwiftUI shell over the unchanged shared Rust core (`clients/core`),
reached through a thin C-ABI bridge crate, speaking exactly the contracts the
Android client speaks: [self-service v2](../../protocol/self-service-v2.md),
[realtime v1](../../protocol/realtime-v1.md),
[first-contact v1](../../protocol/first-contact-v1.md),
[voice v1](../../protocol/voice-v1.md) with its
[call-v2 deltas](../../protocol/call-v2.md) and
[voice TURN v1](../../protocol/voice-turn-v1.md). Calls are call-v2 — two media
sections, audio then video, H.264 or VP8 — so this client cannot call an
Android build older than v16. Screens and Russian UI strings
follow Android word for word (`Создать ID`, `Чаты`, `Контакты`, `Мой ID`,
`Отпечаток совпадает`); the Android client is the behavioural reference, and
the shared [core contract](../core/self-service.md) and
[core voice controls](../core/voice-calls.md) apply unchanged.

## Differences from Android (by design)

- No in-app updates: distribution is TestFlight.
- No background delivery, no push, no CallKit: incoming messages and calls
  arrive only while the application is open. The connection screen states
  this in full; the chat list shows the short hint.
- Reinstalling remains a proposed clean-install distinction using install.v1.
  Missing marker with a surviving file freezes before key deletion. With the
  marker present, key/file XOR always freezes; no pending defaults flag excuses
  missing history. Welcome creates no key; first commit acquires it before the
  unchanged file commit. Failure after key creation may freeze an incomplete
  first commit, preserving its key. Existing valid state is unchanged; old
  eager-key-only installations stay frozen. See [the storage contract](self-service.md)
  and [correction handoff](lazy-storage-handoff.md); Apple verification of this
  correction is pending, not inherited from earlier device evidence.
- Voice relay: `/v2/voice/turn` is used when the server issues credentials; a
  valid authenticated `404 turn_disabled` from the pinned origin is the only
  answer that permits the pre-disclosed direct-ICE mode (RFC-0021 question 5,
  answered by the owner's agents in
  [issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27)).
- Screen capture: Android's `FLAG_SECURE` has no iOS equivalent. This client
  covers the video stage while the screen is recorded, mirrored or AirPlayed
  and leaves the controls reachable; a screenshot and the app-switcher snapshot
  cannot be refused at all. That is a gap, not parity — see
  [voice-calls.md](voice-calls.md).

## Documents in this directory

- [verification.md](verification.md): the requirement-to-test mapping. Every
  row says what was actually run, on what, and every `NOT RUN` names its
  reason. This is the only place a status claim is authoritative.
- [self-service.md](self-service.md): storage, trust, registration, contacts
  and QR, text and receipts, and the foreground-only lifecycle.
- [voice-calls.md](voice-calls.md): the call-v2 contract this client speaks,
  the call controller, the media engine, relay credentials, consent and the
  audio session, and the screen-capture difference from Android.
- [build-and-testflight.md](build-and-testflight.md): pinned toolchain, the
  one-command build, the bundle gate, the `ios-static` CI job (first run on
  the pull request), signing and the upload gates.
- [protocol-sources.md](protocol-sources.md): each behaviour rule mapped to
  its `docs/protocol` line, the core/server line, the Java cross-check and any
  discrepancy. The Java client was read, not executed.
- [export-compliance.md](export-compliance.md): what cryptography the client
  contains, what the bundle declares, and the gate that stays closed until the
  owner records a classification.
- The platform trust delta is
  [docs/security/ios-client-threats.md](../../security/ios-client-threats.md);
  the two joint-test scenarios, written in advance and now partly run (the
  contributor pre-ran part of stage 1 alone against the hosted server on
  2026-09-13, which fills no `Result` cell; the unscheduled session of
  2026-09-14 filled stage 1 steps 4, 5 and 6 and stage 2 steps 4, 8 and 9 with
  `SHOWN (joint, reported)`, and every other cell still reads `NOT RUN`), are in
  [docs/project/evidence/ios-client-20260913/](../../project/evidence/ios-client-20260913/README.md),
  together with the evidence catalogue of that directory: every command with
  what it printed, the digest of every artifact and screenshot it wrote, the
  versions, the list of what was not run, and the permalinks of the owner's
  recorded decisions.

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
