---
status: draft
owner: android
last_reviewed: 2026-09-09
---

# Android self-service candidate: actual local evidence

Issue #16; REQ-ID-001/005/006/007/008, REQ-MSG-002/003/004, REQ-CLIENT-001,
REQ-SEC-001. This component belongs in the **client/Android PR**, separately from
the server PR and its shared wire library. No accepted ADR, live write/deployment,
commit, push, merge, physical installation or production security claim is made.

The later [Android voice implementation](voice-calls.md) builds on the retained
v8 messenger. Its current tests, media/permission boundaries and pending signed
artifact are separate from the historical APK evidence below.

## Active clean-install candidate (RFC-0014)

The 2026-09-09 owner clarification authorizes an actual local APK candidate and
isolated testing for clean installations. [The exact protocol](../../protocol/first-contact-v1.md)
requires signed account-ID intro-v2 on every text and receipt; a zero-contact
receiver immediately gets plaintext and can reply with an unverified-identity
badge. Optional same-key verification is separate. The default root-proof
registration flow remains self-service; recipient QR at the sender is enough.

`SelfServiceClient` uses explicit clean core3 in sealed outer4 (with only a
pristine native0 creation intermediate allowed before completing upgrade),
persist complete candidate state before any network/UI effect, show trust/block
state and refuse unsupported older snapshots without destroying them. Historical
migration/recovery is not this candidate's gate; clean reopen, exact retry,
negative crypto/context, resource and block behavior remain mandatory tests.

Actual new test/build results are recorded in [the local candidate runbook](../../operations/clean-first-contact-local.md)
and [current-state](../../project/current-state.md). The previous evidence below
remains historical, including old APK hashes; it is not proof of the new candidate.
Physical phone installation/Keystore/camera/messaging remains NOT RUN. This task
performs no phone wipe, SSH, live database or server action, upload or publication.
The owner handles uninstall himself; independent parent code review is the next
gate before delivery. Building before that review is explicitly authorized.

## Historical version-5 self-service evidence

The following records the previous migration candidate's scope, dated outputs and
artifact identity. References to core2/outer3, operator migration and an unupgraded
hosted v1 endpoint are historical observations, not current candidate behavior or
new live verification. No historical tests or outcomes are erased.

## What runs

`TextEngine` selects `SelfServiceClient`, not the archived operator-dependent
`KeyClient`. Create ID saves local keys and upgrades the local state before its
first v2 request; registration, key proof and status checks are automatic. Lost
registration state can retry the identical saved credential; an already-active
client never falls back to v1/grants/bearers or tries to bypass a rejected status.
The unchanged compiled public origin/SPKI are defaults only; saved trust wins.

Russian screens provide **Диалоги**, **Контакты**, **Мой ID**, verified contact QR,
text, retained history and queued sending. There is no operator/grant/role/manual
URL/pin/service-JSON form. Dialogs use account IDs, with full fingerprint comparison
before pinning a contact. There is no public user directory or claimed nickname
lookup. Legacy root-unbound history remains visible read-only until its matching
contact QR establishes a real account route. One check is server persistence;
two require the peer's encrypted authenticated receipt, never reading. Under each
bubble stands the instant this phone wrote or received the message, with a pill
where the day turns and the same instant on the conversation row; the core stores
it, nothing transmits it, and an entry written before this candidate has none
([RFC-0023](../../rfcs/0023-message-time.md), proposed).

The process-wide worker retains existing encrypted atomic storage, fsync/readback,
`text-state.enc`, `paranoid-text-state-v0` Keystore alias, package and signing key.
Versions 0/2 import to outer snapshot 3 / core state 2 without resetting identity,
Olm keys, ratchets, history or pending ciphertext. Missing/corrupt storage fails
closed. See [core contract and threat tradeoff](../core/self-service.md).

## Reproduce

```sh
cargo test --locked --manifest-path clients/core/Cargo.toml
cargo clippy --locked --manifest-path clients/core/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path clients/core/Cargo.toml -- --check
python3 clients/android/test_ui_contract.py
python3 scripts/check-pinned-tls.py
python3 clients/android/test_self_service.py --server-root /path/to/separate/server-feature-checkout
```

The server checkout must implement its v2 local mode and shared ChallengeV2 library.
The client feature worktree uses that library as an explicit server-PR dependency;
it does not own or independently redesign the wire proof. The fixture creates its
own private PostgreSQL 16 cluster with Unix-socket-only database access, a fresh
loopback TLS certificate, and synthetic encrypted phone snapshots. No default
public server connection, host mutation, existing database or service is used.
Only owned fixture processes are stopped and temporary fixture data is removed.

For the APK, follow [the Android README](../../../clients/android/README.md#build).
Signing password is passed by environment name, never printed or placed in argv.
The retained certificate was checked before signing; no replacement key was
created or copied. The existing SDK/NDK and signing setup were discovered locally.

## Executed results

| Check | Actual result |
| --- | --- |
| Vertical Rust RED→GREEN | Missing proof/status, migration, contact extension, multi-dialog E2EE, consumed legacy prekey/pins/outbox, acceptance, damaged snapshots, deferred-contact progress/replay, snapshot growth and visible legacy-history regressions failed first, then passed |
| Final Rust suites | **31 passed**, including 14 self-service tests and unchanged v0/v1 suites |
| Clippy / formatting / diff whitespace | Passed with `-D warnings`, `cargo fmt --check`, `git diff --check` |
| Actual Linux JVM/JNI creation | Saved-before-use identity, v2 upgrade, duplicate create/reopen, failed-write freeze and corrupt-state refusal passed |
| Actual populated JVM/JNI migration | Both v0 rootless and v1 rooted snapshots preserved every original field, consumed OTK, ratchets/history/exact outbox, origin/pin and retained token; same ID after reopen |
| Actual three-user v2 interoperability | Pinned TLS + PostgreSQL + Android Java + JNI vodozemac; self-registration, verified QR, two independent dialogs, Cyrillic E2EE/receipts, offline queue, encrypted snapshot/JVM/server restart and no duplicate history passed |
| Pinned TLS negatives | Real JVM handshakes accepted the correct key and rejected wrong key, SAN and expiry before HTTP |
| Existing adapter tests | JNI string boundary, AES-GCM SnapshotCodec, real-HTTP SyncCycle 409/507 behavior, QR bounds/roundtrip and 200 diverse QR regression cases passed |
| UI source contract | Four checks passed; this is source wiring evidence, **not** a rendered-device/UI usability test |
| ARM64 packaging | Native cross-build, exact payload comparison, API26+/ARM64, expected permissions/private storage, 16-KiB alignment and retained signing-certificate checks passed |

Early integration runs failed honestly because the separate server binary did not
yet start in v2 local mode. After that dependency was implemented, the full fixture
passed twice, including the final client-source version. The build emits existing
Java-8 target-obsolescence and legacy camera-API deprecation warnings; those are
not represented as warning-free Android runtime evidence.

## Exact final candidate

Built from the **uncommitted** `feat/self-service-android` worktree based on
`a76b7c9fc910d0f29d4b9ea7ff15b97ef1c760e0`, plus the separate server-owned v2 library
changes. This is not a deployable identified-commit release or an immutable PR
artifact; a later commit/review must produce its own matching identified build.

- Absolute APK: `/home/codex/projects/paranoid-worktrees/self-service-android/clients/android/out/paranoid-text.apk`
- APK SHA256: `0ef323b423f5f33e5bc38a7f5bd004c3945154c855a464ec43b6c80bf65497ab`
- Package: `org.paranoid.devtext`; versionCode `5`; versionName `0.0.5-self-service`.
- ABI: `arm64-v8a`; minSDK `26`; targetSDK `35`; file size `2683385` bytes.
- Signer SHA256: `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- APK Signature Scheme v2 and v3 verify; signer count 1; same certificate as the
  preserved 0.0.4 candidate. Package/alias/signature continuity is verified, not a
  reason to uninstall existing data.
- Packaged native SHA256: `2647a5a91f56c4223b46652e16e732eb1a3f2e5354a585272db9dd334126c0dd`;
  exactly matches the ARM64 cross-build. ARM64 execution on a phone is **not run**.

## Remaining gates and limits

- The hosted default server is **still v1**. It has not been changed; v2 signup on
  that endpoint is unavailable until separately reviewed/authorized migration and
  deployment. The app reports unsupported/unavailable server without replacing ID.
- Physical Android installation, Keystore/filesystem durability, camera optics,
  rendering/accessibility, battery/background and actual two-OPPO messaging remain
  **NOT RUN**. Linux JVM/packaging tests do not substitute for those gates.
- A shared long-lived library fallback prekey is explicitly reusable, with weaker
  initial forward secrecy than independently consumed one-time prekeys. No rotation
  or recovery redesign is hidden here. Protected-domain review and owner disposition
  are still required; no production/privacy adoption is claimed.
- One device/account, finite contact/history/queue/state caps, foreground polling,
  bounded warning ledger and potentially long deferred-message catch-up remain.
  Other capacity/decryption failures retain the inherited no-receipt/deferred-event
  limitations; no automatic history eviction or guaranteed later decryption.
- Seed recovery, multi-device, media/calls, directory/nicknames, push, iOS,
  blockchain and server-selection UX are not implemented by this candidate.
- Independent review/CI and separate server/client PR integration remain parent
  tasks. Shared server protocol/RFC reference copies must not be staged as another
  client-owned design. No commit/push/merge or accepted ADR was performed here.
