---
status: draft
owner: ios
last_reviewed: 2026-09-14
---

# iOS client: storage, registration, contacts and text

Component documentation for the candidate iOS client of
[REQ-CLIENT-001](../../product/requirements.md), proposed in
[RFC-0021](../../rfcs/0021-ios-client.md) and recorded as
[proposed ADR-0014](../../decisions/0014-ios-client.md). It describes what the
code in `clients/ios/` does; what has actually been **run** is in
[verification.md](verification.md), and every rule here is traced to its
protocol line in [protocol-sources.md](protocol-sources.md). The source-level
reference is [`clients/ios/README.md`](../../../clients/ios/README.md).

The core decides; the platform stores, transports and renders. Nothing in this
document changes [the core contract](../core/self-service.md),
[self-service v2](../../protocol/self-service-v2.md),
[realtime v1](../../protocol/realtime-v1.md) or
[first-contact v1](../../protocol/first-contact-v1.md).

## Bridge

`ParanoidKit/Core/CoreBridge.swift` calls the two C symbols of the
`clients/ios/bridge` static library and frees every reply. A reply carrying an
`error` member rejects the operation and changes nothing; a NULL or non-object
reply is a native failure; an interior NUL in either argument is refused before
the call, because a C string would truncate it silently. The core's own limits
(8 MiB state, 65536-byte request) stay in the core.

`JsonSpan.state(in:)` slices the top-level `state` member out of the reply byte
for byte, so the snapshot that is persisted is exactly the text the core
produced and `next == current` is a text comparison. The Android client
compares after an `org.json` round trip; the two are equivalent because every
core reply is serialised through `serde_json::Value` with sorted keys.

## Storage

The sealed snapshot is an AES-256-GCM envelope under a Keychain-held key:

- key: `kSecClassGenericPassword`, account `paranoid-text-state-v0`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. The
  class is the answer to RFC-0021 question 3: a locked screen during a call
  must not turn a heartbeat commit into a terminal freeze. The item lives in
  the application's own keychain group, which `ParanoID.entitlements` names
  under `keychain-access-groups`: with an empty entitlements file the
  simulator's Keychain answered `errSecMissingEntitlement` (-34018) and the
  storage guard froze the launch; a device build inherits the same group from
  its provisioning profile, so its behaviour did not change.
- file: `Application Support/paranoid/text-state.enc`, owner-only,
  `.completeUntilFirstUserAuthentication`, excluded from backup, 9 MiB read
  ceiling.
- commit: write `text-state.enc.tmp`, `F_FULLFSYNC`, `rename(2)`, read the
  committed file back and compare it byte for byte, `F_FULLFSYNC` the
  directory. Any failure sets `isBroken` for the rest of the process, so
  nothing derived from that candidate is adopted or sent.

The backup exclusion is set on the candidate **before** the rename, because
the flag lives on the inode: setting it on the committed name alone would
cover the first commit only, and a later iCloud restore would hand back a stale
ratchet while the Keychain key still worked.

### Local names and call log at rest

`ContactNames` and `CallLog` live in `Application Support/paranoid/` as
`contact-names.v1.json` and `call-log.v1.json`, owner-only,
`.completeUntilFirstUserAuthentication`, 16 MiB read ceiling, each excluded from
OS backup ([RFC-0024](../../rfcs/0024-local-metadata-at-rest.md), proposed).
They use the state file's commit sequence for the reason it has one: the flag
lives on the inode, so it is set on the candidate before the rename — and here
while that candidate is still empty, so no interruption leaves rows in an
unflagged file — and it is read back from the committed name afterwards. A file
whose readback differs or whose backup flag is explicitly false is removed.
A throwing verification or directory sync preserves the remaining copy and
reports failure. One `LocalMetadataStore` implements this for both.

An inconclusive I/O failure does not delete the retained table. A file that exists and will not open seals the
store rather than becoming an empty table that the next write replaces; a
committed, verified, provably excluded file is kept even when the directory sync
that follows fails; and the preference behind a file is retired only against a
read that both parses and proves the exclusion. The ceiling clears the largest
admissible log — 64 conversations of 500 rows, about 7.1 MiB — so no legal table
is refused migration and left in the backup-eligible preference.

After successful migration the current files are excluded and legacy preference
removal is requested. Failed/deferred migration can leave old preferences
eligible for backup; asynchronous UserDefaults removal is not proof of durable
backup erasure. Historical OS backups are not changed. The files remain plain
JSON inside the container: this is backup exclusion, **not** application-level
encryption. Android disables application backup in its manifest. No physical
backup/restore experiment is claimed; host tests cover inode flags and injected
failure paths, including explicit false flags versus throwing flag queries.

A phone updating from an earlier build migrates each preference once: the file
is written first and the preference cleared only after that file is committed,
read back byte for byte and proven excluded, so an interrupted migration
repeats instead of losing the table. Failure never reaches a screen — the table
stays in memory for the run and the chat opens either way, unlike the snapshot,
where a failed commit is terminal.

`AppModel` initially holds in-memory-only names and calls. It loads/migrates
persistent metadata once after successful stand/bootstrap/runtime construction,
before exposing the running UI. A no-stand or failed bootstrap leaves those
files and preferences untouched; screen reads never trigger the migration.
[The bootstrap follow-up](../pr47-bootstrap-followup.md) records its verification
limits. Its app tests later compiled and ran within the contributor's
[4066f36 full app-target run](../../project/evidence/ios-client-20260918/mac-receipt-pr50-4066f36.md),
which is simulator evidence, not device evidence.

`ReceiptHint` (`paranoid.receipt-hint.v1`) stays in UserDefaults: one boolean
that names no contact and no call. Whether these files should additionally be
sealed, and with which key, is RFC-0024 question 2 and remains open; acceptance
of the storage rule is the decision owner's.

### Install marker and lazy wrapping key

The application creates no wrapping key on Welcome or empty-state load. The
persistent `SnapshotStore(keyStore:)` adapter creates it only during the first
commit. `paranoid.install.v1` retains its proposed reinstall meaning; all old
pending/commit defaults are ignored.

| Marker | Key | File | Result |
| --- | --- | --- | --- |
| absent | any | present | frozen, nothing deleted or recorded |
| absent | stale | absent | stale key deleted, install marker recorded, fresh with no new key |
| present | absent | absent | fresh Welcome; key waits for commit |
| present | present | absent | frozen, key kept |
| present | absent | present | frozen, no regeneration |
| present | present | present | retained state |

First commit acquires a key and verifies it with a separate load/equality check
before sealing or the unchanged five file-commit steps. A failed readback never
writes a candidate or deletes the key. Load/commit always throw terminal `.broken`
on failure, with the underlying reason (including `.frozen`) in `brokenCause`. A
failure after key creation can leave key-without-file, which deliberately
freezes on relaunch. No automatic key deletion disguises an interrupted commit.
The normal Welcome/relaunch path has neither half and remains usable.

Existing key/account attributes and snapshot bytes are unchanged. Older builds
left on Welcome with an eager key remain frozen: a pending defaults flag is not
recovery authority. Lost install marker plus surviving file still freezes before
any destructive action. Full rollback/removal of both halves is not detectable;
no recovery or anti-rollback promise is added.

The explicit-key initializer remains for isolated CLI fixtures, not application
persistence. Its old `marker:` argument is ignored for source compatibility.
No commit reads or writes pending-first-run defaults. See
[lazy-storage-handoff.md](lazy-storage-handoff.md) for source checks, new strict
regressions, known crash cost and the pending Mac run. RFC-0021 and ADR-0014 stay
proposed; no new device result or permanent acceptance is claimed.

### Snapshot wrapper

`Snapshot` is the stored version-4 wrapper
(`{"version":4,"realm":…,"tls_pin":…,"token":"","state":…}`) with the core
state inlined verbatim. A wrapper version other than 4 is `unsupportedSnapshot`
and the retained bytes are left exactly as they are; `token` is empty or 64
hexadecimal digits; a schema-0 state left by a crash is validated by running
`upgrade_v2` as a dry run that commits nothing; the wrapper realm must be the
realm the core state was created for. Before any connection, `ProofFlow` asks the
owner to resume valid onboarding checkpoints: commit a schema-0 upgrade and, for
active registration, prepare any missing own contact material. A single read-only
core view gates preparation on absent contact material; completed onboarding
issues no candidate and no no-op commit depends on JSON text byte equality. This uses the
existing core commands; it creates no replacement identity and does not repair
invalid/missing storage. Opening itself remains validation-only.
Every transition goes through one
`apply`, which commits the candidate **before** it is adopted in memory, handed
to a listener or acted on.

### Freeze propagation and retry opening

Every operation through `StateOwner.perform` checks for a storage freeze on exit,
even if its closure caught the commit error. The owner disables generations and
synchronously notifies the call coordinator before returning to the UI. It does
not wait for a parked receive or heartbeat; start/restart cannot revive a frozen
owner. Retry opening clears stale UI failure flags only after an initial runtime
has been built successfully. A failed-commit runtime stays terminal.

See [review-integration-handoff.md](review-integration-handoff.md) for the F1–F7
regressions and the separate Mac verification gate.

## Trust

`ParanoidKit/Tls` evaluates the server leaf on `Security.framework` primitives
rather than delegating to system trust: exactly one self-signed certificate,
SHA-256 of the SPKI DER equal to the saved pin in constant time, validity
window, no unknown critical extension and no CA basic constraint, signature
verified with the leaf key, server-auth key usage and EKU, EC ≥ 256 or
RSA ≥ 2048, SAN-only host match, TLS 1.2 minimum, no client certificate. Saved
trust always wins over a compiled default, and a fixture that disagrees with a
saved pair is refused.

`Info.plist` turns App Transport Security off — `NSAllowsArbitraryLoads = YES`,
exactly that key and nothing else — because on a physical iPhone ATS refuses a
self-signed leaf on a public IP address before the pinning delegate is
consulted (`NSURLErrorDomain -1200`, stream error -9802), `NSPinnedDomains`
does not match an IP literal, and a stand on a private LAN address never shows
it. The currently reviewed session factories install `PinnedSessionDelegate`.
`test_ui_contract.py` refuses that ATS key in any other shape and invokes the
finite lexical constructor/wiring allowlist in `pinned_session_contract.py`.
Negative mutation tests cover known bypass forms; arbitrary Swift data flow,
macros and other networking APIs still require review. The measurement
and its threat delta are in
[ios-client-threats.md](../../security/ios-client-threats.md) and ADR-0014.

The pin is the same value the Android client carries. The owner renewed the
hosted certificate **with the same key** on 2026-09-13, so the pin did not
change and both clients keep working; the new leaf is valid until
2026-12-12T07:38:09Z. A same-key renewal must be repeated before that date —
the [bounded same-key automation](../../operations/tls-auto-renewal.md)
installed on the host on 2026-09-13 does that, outside this client — and
rotating the key itself is a separate deploy-trust decision, because the pin
is part of the first-contact channel transcript and a new key would
invalidate enrolled contacts, not only the transport
([RFC-0021](../../rfcs/0021-ios-client.md) question 7).

## Registration

`Создать ID` creates and durably saves the identity before the first request
exists: `create_identity{realm,pin}`, then `upgrade_v2` to core schema 3, each
committed. Registration is then the unchanged self-service v2 flow —
`/v2/registration/challenge` with the exact intent
`{credential, purpose:"register", method:"POST", path:"/v2/registration/commit",
body: SHA256("{}")}`, and `/v2/registration/commit` under
`Authorization: ParanoidV2 <id>.<signature>` produced by the core. The
registration response must match the local credential or the operation is
`status_conflict`; `prepare_contact_v2` then publishes the fallback key.

There is no operator, no grant, no role, no invitation and no manual URL or pin
form anywhere in the interface (REQ-ID-008). A Debug build names a local stand
through the `-paranoid-realm` / `-paranoid-pin` launch arguments (Xcode and
`xcodebuild test` on a simulator) or the `PARANOID_REALM` / `PARANOID_PIN`
environment variables (`devicectl` starts a build on a physical phone without
relaying launch arguments, so there the environment is the only channel); both
go through the same `checkedRealm` / `checkedPin` as a Release build. A Debug
build with neither pair has no realm at all and creates no identity: the
hosted defaults apply only in a Release build, which reads neither channel, or
under `-paranoid-allow-hosted`.

## Contacts and QR

`Мой ID` renders the `contact` member the core produced, byte for byte, through
`CIQRCodeGenerator` at error-correction level M with one module of quiet zone
plus the three Android adds in white, scaled by a whole number to 640 px. That
scaling is the iOS form of the v15 dense-QR fix: a ~900-byte contact code lost
its modules at 480p.

The scanner is in-app only: one `AVCaptureSession` with a single
`AVCaptureMetadataOutput` restricted to `.qr` at `.hd1920x1080` (`.high` if the
session refuses it), with the lens told to look near. There is no photo,
video-data or movie output, so a camera frame never reaches the process — what
arrives is the decoded string. A payload above 2048 bytes is refused and the
session keeps scanning; cancelling touches neither the identity nor the
snapshot nor the network. A denied or restricted camera offers the paste field
and the Settings link instead, and leaves the identity untouched.

Pairing requires the user's explicit `Отпечаток совпадает` confirmation
(REQ-ID-007). The core verifies the root credential, the account derivation,
the Olm binding, the realm and pin, the canonical encodings and the device
signature; a contact with the same account or the same curve key as self is
refused. Block is orthogonal to trust: pins and history are preserved and the
same channel resumes on unblock.

## Text, receipts and the lanes

`StateOwner` is an actor on one serial queue holding the client, every bridge
call, every commit, the realtime session and the discovered capability — the
port of Android's single-threaded `TextEngine.worker`. No member of it is
`async`, so it cannot wait on a socket; a lane awaits the network in its own
task and hands the finished answer back through `perform`.

- **Receive.** One cycle is one page: a page above twenty events is refused,
  the receive cursor is re-read on the owner and must still be the one the
  request was signed with, the connection is published *before* the page so
  that call signalling sees an online client, and every event goes through
  `receive_v2` one at a time — each candidate sealed, renamed and read back
  before the notification that follows it. The first cycle of a generation
  asks for `messages` and every later one for `events`; a 429 `waiter_busy`
  reads the inbox instead of queueing for the account's one wait slot.
- **Send.** One pass over the outbox, oldest first, each entry sent exactly as
  `sign_session_v2 {operation:"send", id}` described it, never as a route the
  lane composed. `{id, sequence >= 1}` is committed through `accepted_v2`
  before the delivery mark it produces is published. A 409 or a 507 defers that
  envelope and lets the rest of the batch go out; any other status ends the
  pass at once. An idle lane waits on a wake signal instead of polling.
- **Time.** Under every bubble stands the instant this phone wrote or received
  the message, in its own time zone (`14:32`), with a pill where the day turns
  («Сегодня», «Вчера», «12 сентября») and the same instant on the conversation
  row (the time today, «Вчера», then `12.09`). The core stores it and never
  sends it; an entry written before this build has none and is shown without one
  ([RFC-0023](../../rfcs/0023-message-time.md), proposed).
- **Receipts.** One mark appears only after durable server acceptance, two
  only after the peer's authenticated receipt. There are no read receipts
  anywhere in this client (REQ-MSG-003). The three states are drawn
  (`ReceiptMark`) rather than typed as «…», «✓» and «✓✓»; the words behind them
  stay as the accessibility label, so VoiceOver reads the state and not the
  drawing. The first time a message of this user's reaches the second mark, the
  chat says once that two marks are delivery and not reading, and «Понятно»
  retires that sentence for good (`ReceiptHint`, a flag in this application's
  own defaults). The [Android presentation candidate](../android/receipt-presentation.md)
  uses the same drawn-state and one-time-hint semantics; wording stays identical.
- **Session.** Purpose `session`, `POST /v2/session`, strict `SessionV2`
  response, renewed at about 240 s of monotonic age. A first 401 on a signed
  request is retried once with a fresh nonce; a second 401, a 404 or
  `session_exhausted` drops the session, and a 401 or 404 also rediscovers the
  capability through pinned `/health`.

## Foreground-only lifecycle

`LifecyclePolicy` is the whole rule, as pure logic: `didBecomeActive` on
stopped lanes starts them and mints a generation; `didBecomeActive` on running
lanes does nothing, so a permission alert, the Control Center or the app
switcher costs neither a generation nor a round trip; `didEnterBackground`
stops the lanes **unless** a call is live, because a call is signalled over
those very lanes. A call that has ended keeps them for ten more seconds so the
last control and its receipt leave the device.

There is no background delivery, no background app refresh, no push
registration and no CallKit in this client. `PushHook` is the seam a future
background delivery would enter through; `NoPushHook` is what this client
installs. Incoming messages and calls therefore arrive only while the
application is open — a user-visible limitation stated on the connection
screen, not a defect (track B, [RFC-0020](../../rfcs/0020-push-wake.md) is the
Android push wake gateway and no iOS half of it exists).

## What this document does not claim

Everything above is what the code is written to do. What has been executed, on
what, and what has not, is [verification.md](verification.md): simulator and
local-stand results are `CLAIMED`, physical-phone results are `SHOWN`. On
2026-09-13 a signed build ran on a physical iPhone 16 Pro Max (iOS 26.6.1): a
Debug build against the local stand — identity created on the device, own QR
shown, a contact scanned off a screen with the real camera, fingerprint sheet
confirmed, text both ways with receipts, one call to a simulator that
connected with video from the device — and then a Release build against the
hosted server. Three hosted accounts exist (`hosted_registrations` is 3: one
from the build Mac through `service-bridge` on 2026-09-13 while diagnosing the
phone's TLS failure, one from the iPhone on 2026-09-13 after the ATS fix, and
one from the build Mac on 2026-09-14 while diagnosing issue #38; all three
under the owner's answer to RFC-0021 question 4, no fixed budget, and all
three permanent, because the server has no delete path). The first is dead:
that fixture kept its wrapping key in process memory only, so its state file
no longer opens and the account is registered but unreachable — which is why a
third exists at all. The third is a diagnostic account with no messages and no
contacts, registered to measure the hosted server from a second identity; its
wrapping key is kept beside its state, so that diagnosis needs no further
registration. The second is the contributor's own and still in use: the iPhone
paired the owner's Android from his QR image and sent one text the hosted
server accepted (one check), not yet delivered to his phone at that point. On
2026-09-14 an unscheduled session with the owner on that same account carried
text both ways and one call he placed to the iPhone; those rows are the
contributor's report, `SHOWN (joint, reported)` and not a capture, with no
owner "go" permalink. The joint tests with the owner are only partly run, and
no archive, TestFlight upload, relayed call or Data Protection class
measurement has happened.
