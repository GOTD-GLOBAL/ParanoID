# Changelog

All notable changes to ParanoID will be documented in this file.

The format is based on [Keep a Changelog 2.0.0](https://keepachangelog.com/en/2.0.0/).
The project will adopt [Semantic Versioning](https://semver.org/) when its first
public contract is declared.

## [Unreleased]

### Devnet merge verification — 2026-09-22

- Add blocking offline Rust/JNI registration-controller and integrated Android
  source/notices CI checks, including blockchain-only path triggers.
- Preserve the separate exact-program artifact and Android runtime gates and
  the visible historical legacy-history failures; no production code, data,
  signing identity, server or update feed is changed by this CI follow-up.

### Android v28 integrated Devnet update candidate — 2026-09-22

- Keep the main messenger package/signer, chats, calls and updater; add private
  My ID -> Devnet nickname registration inside that same APK, not a separate app.
- Bound identical transaction rebroadcasts, reconcile expired attempts, prepare
  fee-checkable unsigned messages before signing and persist write-intent markers.
- Test real Devnet registration/name recovery and Android Keystore in an isolated
  emulator harness. The mnemonic restores the Devnet name key only, NOT the
  messenger account/history. Owner-requested build, not a production release.

### Authorized Solana Devnet deployment — 2026-09-22

- Deploy the reviewed73800-byte registry after explicit owner authorization;
  verify finalized ProgramData/authority and exact bytecode through the actual
  client gate and an independent CLI dump.
- Record same-buffer upload recovery, real transaction handles and0.37702096
  test-SOL total spend in the [receipt](docs/project/evidence/solana-devnet-deploy-20260922/README.md).
- No registration transaction, phone acceptance, Mainnet action or APK publication
  is implied. RFC0026 remains draft and issue52 remains open.

### Solana Devnet registration candidate — 2026-09-21

- Add a native SBF nickname/identity registry, shared Rust signing/recovery client
  and separate Android registration-only candidate under draft RFC-0026.
- Restrict mnemonic export to explicit recovery UI; share public deployment pins
  through JNI and verify ProgramData authority and exact bytecode before signing.
- Record executable local tests, independent recovery-vector reproduction and
  build/signature evidence. No chain deployment, physical-phone acceptance,
  Mainnet action or messenger replacement is claimed by this candidate.

### iOS call tones and lifecycle review corrections — 2026-09-18

- Add synthesized incoming ring, caller ringback and exact two-second busy
  pattern for busy/reject/timeout from outgoing ringing.
- Move player I/O off MainActor/state owner; fence delayed starts/completions and
  timers, wait for stop before switching session, and check actual play success.
- Use foreground ambient incoming alerts; preserve explicit Call/Answer capture
  consent. A terminal busy tail retains output only, not microphone capture.
- Await real audio readiness before controls, with cancellation and the shared
  setup deadline. Recover counted SDK leases after failed deactivation,
  interruption or reset, including coalesced callbacks and missing end events.
- Add deterministic policy/backend/readiness tests. Native validation of this
  revision remains pending; [RFC-0025](docs/rfcs/0025-ios-call-tone-lifecycle.md)
  is proposed, not accepted. No phone audibility or deployment claim.

### Android v27 packaging — 2026-09-18

- Published `0.0.27-timeout`, version code27, from merged main after PR48 plus
  packaging metadata, with retained package/signer and current shared-core/UI.
  Old/current updater downloads and downloaded-artifact checks passed; physical
  phone acceptance remains separate. See the [release receipt](docs/clients/android/v27-release.md).

### iPhone local metadata out of the OS backup — 2026-09-18

- **Local metadata files are excluded after successful migration.** The local contact
  names and the call log move from `UserDefaults`, which iCloud and encrypted
  local backups include, into `Application Support/paranoid/` files excluded from
  backup on their own inode ([RFC-0024](docs/rfcs/0024-local-metadata-at-rest.md),
  proposed). Peer accounts, typed names, call outcomes, durations and message
  anchors in successfully migrated files are excluded. Failed/deferred migration
  can retain legacy preferences; historical backups are not erased.
- **Commit rules are the state file's:** the candidate is created empty and
  flagged before a single row is written and before the rename, the committed
  file is read back byte for byte and its flag read back too. A proven byte
  mismatch or false flag allows removal; throwing verification or directory
  sync preserves the remaining file. A phone updating migrates each preference once
  and clears it only after that proof, so an interrupted migration repeats
  instead of losing the table.
- **Inconclusive I/O does not delete the retained table.** A file that exists and will
  not open seals the store instead of becoming an empty table that the next
  write replaces; a committed, verified, provably excluded file is kept even when
  the directory sync that follows fails; a preference is retired only against a
  read that both parses and proves the exclusion; and the read ceiling clears the
  largest admissible log — 64 conversations of 500 rows, about 7.1 MiB — so no
  legal table is refused migration and left in the backup-eligible preference.
  These five rules come from the PR47 review and each has a regression behind it.
- **Three more of the same class, found by an adversarial pass over that fix.**
  A verification that merely throws after the rename no longer deletes the
  committed file — by then the copy it replaced is already unlinked, and an
  unanswered question is not proof; a preference is never written back over a
  file that will not open, because it may be older than that file; and emptying
  a table retires the preference first, since it is the backup-eligible copy a
  later launch would resurrect the table from.
- **No metadata migration before bootstrap permission.** Names and calls start
  in memory and acquire persistent stores once after successful bootstrap.
  Screen reads and `.noStand` do not migrate preferences. New app-level tests
  require a Mac run; source-only verification is recorded separately.
- **Not encryption.** The bytes stay plain JSON inside the container under
  `completeUntilFirstUserAuthentication`; container access is unchanged. Sealing
  them is RFC-0024 question 2, open.
- Android is unaffected (its manifest already disables application backup), and
  no core, protocol, server, route or snapshot behaviour changes. No physical
  backup/restore experiment on a device is claimed; the evidence is the host
  suite. Acceptance of the storage rule remains the decision owner's.

### Android response timeout — 2026-09-18

- Ordinary self-service v2 reads now wait 15 seconds, above the server 10-second
  handler bound: registration/auth, text, TURN and updates. Connect remains
  8 seconds; realtime events remain 30; legacy v1 KeyTransport remains 8.
  TLS, retry identity and persistence are unchanged. This fixes premature client
  timeout, not the unproven cause of hosted issue #38.

### Message time — 2026-09-17

- **A message says when it happened.** A history entry gains `local_ms`: the
  instant the phone that wrote or received it read **its own** clock. The core
  reads no clock — `send_v2` and `receive_v2` carry `now_ms`, the value is stored
  verbatim, the same trust model the call controls already use — and it never
  enters an envelope, a `PlainV1` body, a receipt or a server row. The peer and
  the server learn nothing new ([RFC-0023](docs/rfcs/0023-message-time.md),
  proposed).
- **On both clients:** the time under every bubble in the phone's own time zone,
  a pill where the day turns («Сегодня», «Вчера», «12 сентября»), and the date on
  a conversation row (the time today, «Вчера», then `12.09`). An entry written
  before this candidate has no time and is shown without one; nothing is invented
  for it (REQ-CLIENT-004).
- **Compatibility:** an older build cannot open a snapshot that carries the new
  field, the same alpha break as the retired history ceiling. Both phones must be
  updated together. A build of this generation opens an older snapshot unchanged.
- Call previews do not borrow a preceding message's date; Android pre-epoch
  clocks become unknown timestamps rather than breaking native request parsing.
  The time smoke now gates CI and APK builds. [Integration evidence](docs/clients/pr46-integration.md)
  separates the Linux result from the still-required final Mac run.
- No wire format, server route, schema column or protocol kind changes. No
  device acceptance, deployment or ADR acceptance is claimed.

### PR45 current-main integration — 2026-09-17

- Preserve PR34 cold-push owner, split-R8/DEX and crash-report fixes while adding
  PR45 call rows; retain PR35 server maintenance gates and dated evidence.
- Gate Android call-log/presentation/UI/crash-exit checks in CI and verify the
  declared-iOS-branch condition plus inherited no-iOS-diff boundary shortcut.
- Record the successful contributor Mac anchor tests and the new local Android
  build separately. The inherited versionCode26 build is review-only, not a new
  device release or republished v26. [Evidence](docs/clients/pr45-main-integration.md).

### Chat marks, call rows in the chat, and history without a ceiling — 2026-09-17

- **No message ceiling.** The core's 200-entry refusals — on send, on receive
  after decryption, and in snapshot validation — are removed in both profiles
  ([RFC-0022](docs/rfcs/0022-unlimited-conversation-history.md)). The 8 MiB
  snapshot bound, the 400-envelope outbox, the 1000-commitment ledger, the eight
  sessions, the 64 contacts and the 2048-byte text limit are unchanged. A build
  older than this one cannot open a snapshot that passed the retired ceiling, and
  a peer still on the old one silently drops what it cannot store: both phones
  must be updated together. RFC-0022 is proposed, not accepted.
- **Delivery marks are drawn, not typed (iOS).** The same three states of
  REQ-MSG-003 — queued, stored by the server, delivered to the peer's device —
  are painted as shapes instead of «…», «✓» and «✓✓» inside the bubble, with the
  existing words kept as the accessibility label. The first time a message of
  this user's reaches the second mark, the chat says once that two marks are
  delivery and not reading. No read receipt exists or is implied. Android keeps
  its typed characters; the wording is identical.
- **A finished call leaves a row in its conversation (iOS and Android).**
  Outgoing or incoming with its duration, missed with «Перезвонить», declined,
  rejected, cancelled, unanswered, busy or failed. It is local bookkeeping
  derived from the terminal transition each device watched: no new in-band
  message kind, no core history, no server record, nothing sent to the peer, and
  each phone keeps its own account of the same call. Rows are anchored to the
  last message the conversation had when the call ended, because the core stores
  no time for a message. Android raises a content-free missed-call notification
  (own channel, id 53) only when no screen is attached; iOS raises none, because
  this client has no notification path at all.
- **The iOS application has an icon and a display name** built from the approved
  mark in `docs/brand`.
- **The iOS component-boundary CI gate now runs for `feat/ios-*` branches only.**
  Unconditionally, it failed every pull request touching the core, Android or two
  clients at once, which is every change of this shape.
- No wire format, server route, schema column, protocol kind or live action is
  part of this change. No device acceptance, deployment or ADR acceptance is
  claimed.

### PR45 iOS anchor parity follow-up — 2026-09-17

- Distinguish unavailable/frozen history from an observed empty chat on iOS,
  matching Android's local `unavailable` anchor. Add persistence/order tests.
- Document OS-backup exposure of iOS local contact names and call logs; file
  migration remains an owner decision, not an implemented storage change.

### PR45 validation fixes — 2026-09-17

- Compile every Android application source against the real SDK before the
  native build; handle checked JSON exceptions missed by host-only tests.
- Correct two pre-existing Maven download sources without changing pinned bytes.
- Keep the previous connection/error status on call-log repaints, place unknown
  history anchors at the end and recheck foreground state before missed notices.
- Keep iOS delivery accessibility labels exposed instead of hiding their element.
  New Mac/VoiceOver verification remains required.
- Record [verification scope and remaining gates](docs/clients/pr45-validation.md).

### PR35 integration checks — 2026-09-17

- Integrate the server rollout evidence with current main without dropping later
  Android/iOS records. Add blocking CI invocations for reconciliation/recovery and
  real packaged v2 encrypted backup, optional FCM coverage and interruption tests.
- No new hosted operation, application schema migration or architecture acceptance.

### Server APK-cap rollout completed — 2026-09-13

- Deployed the reviewed server without the fixed APK ceiling on retained data.
  Live executable, original coordinator status and v26 feed download were verified.
- Reconciled exact already-authorized push/TLS maintenance with immutable old
  records, without weakening status checks. An initial update then safely rolled
  back because backup validation omitted the known optional FCM table.
- Fixed strict optional-schema and encrypted-restore coverage, including push
  tokens. Fifteen packaged maintenance checks passed; the successful live update
  restored/verified all seven tables before switching. Failed history is retained.
  [Operation and evidence](docs/operations/apk-cap-rollout-2026-09-13.md).

### PR34 integration corrections — 2026-09-17

- Restore complete project evidence lost to a truncation placeholder in PR34.
- Restrict native exit reports to structured fields, collect off UI, and defer
  acknowledgement until explicit Copy/Close. Existing Java report limits remain.
- Verify real DEX definitions and reject secondary split inputs before merging.
- Correct two pinned Maven repository selectors without changing artifact bytes.
- This source candidate is not a new v26 publication or a server deployment.

### v26 bridge APK published — 2026-09-13

- Published `0.0.26-update` through the existing in-app feed with the retained
  signer, within the old clients' size ceiling. It removes the client's fixed
  ceiling and preserves the v25 cold-push call-owner and Firebase-only R8 fixes.
- Canonical build and independent artifact review pass; actual old-v25 updater
  downloads the new feed APK over pinned TLS. Phone acceptance is still pending.
- Server rollout was stopped at coordinator identity drift. No server update or
  bypass is implied by APK publication. See the
  [release evidence](docs/clients/android/v26-bridge-release.md).

### iOS call-control targeting candidate — 2026-09-14

- Bind End/Reject/Hangup and mute/speaker UI operations to the original call ID
  and generation inside the state owner, so delayed actions cannot modify a
  replacement call. Add held-owner-dispatch regressions and an old-tree Mac
  behavioral-RED harness. Swift execution remains a new-SHA verification gate.
- No wire/schema, shared core, server, Android or live change.

### iOS PR41 Mac follow-up — 2026-09-14

- Correct a Swift6 region-isolation error in the interrupted-onboarding test
  fixture using Sendable credential bytes, not unchecked client sharing.
- Skip contact-preparation candidates when onboarding is already complete;
  refine ATS lexical-gate coverage and baseline-test evidence wording.
- Record the e642907 Mac receipt: app/simulator 64 PASS, package compile failure
  with zero tests executed. The new revision still requires Mac verification.

### iOS review integration corrections — 2026-09-14

- Candidate fixes owner-ordered call termination on storage freeze, call-bound
  Answer/refusal consent, initial-open retry UI state, interrupted onboarding
  checkpoints, call-scoped TURN cancellation and remote-video proximity.
- Adds targeted regressions and a mutation-tested pinned-session placement gate.
  Linux source checks are not Apple runtime evidence; the
  [Mac handoff](docs/clients/ios/review-integration-handoff.md) retains that gate.
  No state format, core, server, Android, release or architecture acceptance change.

### iOS storage: verify first-key readback — 2026-09-14

- Follow-up candidate verifies newly created Keychain bytes with a separate load
  and equality check before sealing/writing a snapshot. A failed check preserves
  the item and terminally breaks the store. The unused eager helper is removed.
- Fresh-store direct-commit regressions cover missing file/key and unreadable
  keys; error wrapping is documented and tested. Contributor execution of
  `628958b` passed 14 lazy-key, 25 storage, 278 package and 11 signed-simulator
  Keychain tests ([receipt](docs/project/evidence/ios-client-20260913/lazy-storage-mac-628958b.md)).
  Baseline RED remains in the separate 0709212 receipt. No physical-device,
  power-loss, merge or release result is implied.

### Android client: remove fixed APK ceiling — 2026-09-13

- Local client candidate no longer rejects updates/provider files merely because
  they exceed 16 MiB. Declared-size/hash/signer/package/version/TLS checks remain.
  Fixed-buffer download accounting is overflow-safe; insufficient cache space
  fails before APK transfer, without touching message data or identity.
- PackageInstaller fallback now allocates/copies/fsyncs on the worker, preserving
  BUSY through the UI handoff; lost focus/errors abandon the session safely.
- Dependency optimization remains, not a fixed APK budget. Server change and a
  legacy-compatible bridge are separate release gates; no phone install claimed.

### Android update server: remove fixed APK ceiling — 2026-09-13

- Local server candidate accepts positive signed-64-bit APK lengths instead of a
  16 MiB cap. Fixed-buffer hashing and anonymous disk snapshots preserve exact
  verified response bytes; two permits cover complete response lifetimes.
- Metadata, TLS/path/hash checks remain; publication needs disk headroom and
  O_TMPFILE support. Separate Android bridge and reviewed rollout remain required.
  No live server/feed change is claimed.

### Automatic same-key TLS maintenance — 2026-09-13

- Installed standalone daily persistent renewal with unchanged TLS key/pin/profile,
  30-day threshold, certificate-only journal/recovery and bounded user-service
  restart when due. Independent review, 13 unit/fault tests, four installer gates
  and actual local systemd/TLS renewal/no-op/rollback pass. Hosted first run is
  `not_due`, timer enabled/active, current application/certificate/config/package
  unchanged. See the [runbook](docs/operations/tls-auto-renewal.md).
  No key rotation, database change, phone/iOS or full-history acceptance claim.

### Same-key TLS certificate renewal — 2026-09-13

- The hosted private alpha certificate now expires on `2026-12-12T07:38:09Z`;
  the private key, SPKI pin, SAN and server-auth profile remain unchanged.
  Dedicated-service restart and external Android TLS/JVM checks passed, with
  configuration, server package, PostgreSQL identity and neighbors preserved.
  [Operation, review and rollback evidence](docs/operations/tls-renewal-2026-09-13.md)
  distinguish actual host checks from synthetic fault tests and unrun phone/iOS
  acceptance. That one-off operation did not implement automation or key rotation.

### Native iOS client candidate — 2026-09-13

- A second client, proposed under RFC-0021 and proposed ADR-0014: a native
  SwiftUI application over the **unchanged** shared Rust core through a C-ABI
  bridge crate beside it (`clients/ios/`). No server, core, `key-protocol`,
  Android or deploy change; a boundary gate enforces that.
- Storage uses the unchanged Keychain-held wrapping key and sealed snapshot
  codec. The lazy-key correction creates no key on Welcome and acquires one
  only at first commit; marker-present key/file XOR always freezes, ignoring
  prior pending/commit defaults. Failure after first key creation may freeze an
  incomplete installation rather than delete the key. Missing install marker
  with a surviving snapshot also freezes without deletion. Existing valid
  state reopens unchanged; Apple verification of this correction is pending
  ([handoff](docs/clients/ios/lazy-storage-handoff.md)), not a released fix.
- TLS is leaf-SPKI pinning evaluated on `Security.framework` with the same nine
  checks and the same pin the Android client carries. The hosted certificate
  was renewed **with the same key** on 2026-09-13, so the pin is unchanged and
  the new leaf is valid to 2026-12-12. On a phone against the hosted server the
  delegate never ran: App Transport Security refused the self-signed leaf on a
  public IP first (`NSURLErrorDomain -1200`), which a LAN stand never shows and
  `NSPinnedDomains` cannot cover for an IP literal. `adb56be` sets
  `NSAllowsArbitraryLoads = YES` under the contract that it is the only ATS key
  and no `URLSession` exists outside `PinnedSessionDelegate`
  (`test_ui_contract.py`); the reasoning is in
  `docs/security/ios-client-threats.md` and ADR-0014.
- Calls are call-v2: two media sections, audio then video, both `a=sendrecv`,
  H.264 first with VP8 as the mandatory fallback, camera on/off as a track flag
  plus an informative `media` control and never a renegotiation, and a
  9000-byte description cap below the measured 10040-byte frame2 ceiling. This
  client cannot call an Android build older than v16. Every camera action
  carries the call it was taken in — the toggle, the switch between front and
  back, and the camera the background took away and the return to the screen
  gives back — because a permission dialog or a hop onto the state owner can
  outlive the call that raised it, and a grant says this application may see a
  camera, never which call the user meant. Reports that the application is on
  the screen carry a number for the same reason: they cross the same hop, and
  the flag they set is state that stays.
- Foreground-only by design: no APNs, no PushKit, no background refresh, no
  CallKit and no in-app updates. A call to a locked or closed iPhone ends in
  the caller's expected 45-second `timeout`.
- The lanes reconnect when the network changes (2026-09-14), which they did not
  before: a change of the default path mints a generation with the lanes left
  enabled, cancels the requests in flight and relaunches them, so a long poll
  over an interface the device no longer has ends there instead of at its own
  30-second bound plus the backoff after it. A change seen while the lanes are
  stopped starts nothing, because there is no background delivery.
  «Повторить подключение» does the same restart unless a call is live or the
  client is already connected, where it keeps Android's harmless half, and a
  start or a restart now says «Подключение · подробнее» instead of leaving the
  previous caption standing — no connected state is invented. It is the port of
  `TextEngine.watchNetwork()` and `RealtimeLoop.restart()`, Android's own fix
  of 2026-09-12, and adds no dependency, no background mode, no `Info.plist`
  key and no `URLSession` outside `PinnedSessionDelegate`
  (`NWPathMonitor` observes and never wakes a process).
- Screen capture is **not** parity with Android: `FLAG_SECURE` has no iOS
  equivalent, so the video stage is covered while the screen is recorded,
  mirrored or AirPlayed, and a screenshot and the app-switcher snapshot cannot
  be refused.
- CI gains one Ubuntu job, `.github/workflows/ios.yml` (`ios-static`): the
  iOS-target `cargo check` of the bridge over the unchanged core, bridge
  clippy and host tests, lock-file drift against the Android lock, the
  toolchain and WebRTC pins, the two source-only contracts, the full
  third-party-notices run, and the component-boundary gate on pull requests.
  `server.yml` is untouched; `docs.yml` gains two lychee `--exclude` lines for
  the issue-27 permalinks this branch is the first to cite, and nothing else.
  There is no macOS runner, so no simulator, app bundle or stand result comes
  from CI. The workflow first ran on the draft pull request #36 (2026-09-14):
  `ios-static` passed, `docs.yml` passed, and the server workflow's
  `client-core-and-tls` and `native-package` passed; its "Legacy client
  history" job is informational and fails on `main` too.
- The Android client is the cross-check, and it is now executed rather than only
  read: `clients/ios/test_android_compatibility.py` holds two private pipes open
  at once — the Android facade through JNI and the iOS classes through the C ABI
  — over one shared core, and runs identity, pairing, text with receipts, a full
  call-v2 round, the snapshot codec both ways, a saved wrapper reopened by both
  adapters, 21 malformed call bodies and a tampered envelope; then the two
  **shipped** client stacks register on one local stand and carry a text to each
  other through it, both ways. Because both sides link the same core, every
  scenario also matches an expectation the harness computes in Python without
  calling the core (the account, credential, contact and channel transcripts,
  the sealed-snapshot layout, and a call-v2 validator written from the protocol
  document), and every negative is refused by that validator first.
  `clients/ios/test_qr_cross.py` does the same for pixels: a real 901-byte
  contact crosses the iOS encoder and Android's ZXing in both directions
  unchanged. Both are `CLAIMED`: two client stacks on one Mac. Contact with the
  owner's Android on its own phone is no longer confined to the pairing the
  iPhone made from his QR image on 2026-09-13 and one text the hosted server
  accepted: the unscheduled joint session of 2026-09-14 recorded in the status
  below carried text both ways and one call between the two clients.
- Status: `CLAIMED` on simulators (iPhone 17 Pro and iPhone 17e, iOS 26.5),
  host and local stand, including two simulators calling each other in both
  directions. On 2026-09-13 a signed build (Apple team on the `xcodebuild`
  command line with `-allowProvisioningUpdates`, installed with `devicectl`)
  ran on a physical iPhone 16 Pro Max, iOS 26.6.1. Against the local stand,
  bound to the Mac's LAN address, a Debug build (it takes the DEBUG-only
  `PARANOID_REALM`/`PARANOID_PIN` environment channel, added because
  `devicectl` does not relay launch arguments) created an identity, showed its
  own QR, scanned a contact off the Mac screen with the real camera, confirmed
  the fingerprint sheet, sent two texts and received one with receipts, and
  placed one call to a simulator that connected with video visible from the
  phone (the simulator has no camera). Against the hosted server, after the
  ATS fix, a Release build registered, paired the owner's Android from his QR
  image and sent one text the server accepted (one check); delivery to his
  phone was still pending. On 2026-09-14 an unscheduled joint session on the
  hosted alpha, from that same signed Release build (branch head `adb56be`),
  put this client against the owner's Android on its own hardware: the iPhone
  scanned his QR and the contact was paired, a text reached him and **both**
  checks appeared on the iPhone — the acknowledgement from a real Android
  client, which this client had never seen — his reply arrived, and he then
  called the iPhone from his Android, they spoke, and both sides turned their
  cameras on. That is the first call this client has carried against the
  Android client rather than a simulator and the first picture it has received
  from a real camera over call-v2, so his build is v16 or later, because
  call-v2 rejects v1 bodies; the exact version was not asked for. Every result
  of that session is the contributor's report given immediately afterwards,
  not an observation by whoever writes this file and not a recording, which is
  why the evidence rows read `SHOWN (joint, reported)` rather than `SHOWN`;
  the session was not planned, so no owner "go" permalink exists for it, and
  the owner did not scan the iPhone's QR, so the Android side of the pairing
  and the fingerprint compared aloud stay untested. `hosted_registrations` is
  3, and that session consumed none of it: a `service-bridge` registration
  from the build Mac on 2026-09-13, made while diagnosing the phone's TLS
  failure, whose wrapping key was held in process memory only, so its state
  file no longer opens and the account is registered but dead; the iPhone's
  own, registered on 2026-09-13 after that fix and still in use; and a
  diagnostic account registered from the build Mac on 2026-09-14 at
  08:26:45+03:00,
  `240060ebc49a9b7394f6fe4ccc30922e62dac9ae9a04ae89415423950ae16776`, with no
  messages and no contacts, to answer the owner agent's request for a
  comparative signed read while diagnosing issue #38. It exists as a third
  because the key of the first Mac account is lost; unlike it, this one is
  persistent — its wrapping key is kept beside its state in git-ignored build
  output — so the diagnosis needs no further registration. All three fall
  under the owner's answer to RFC-0021 question 4 (no fixed budget), and the
  server has no delete path, so all three are permanent. The device smoke also
  found an empty entitlements file (the simulator's Keychain answered
  `errSecMissingEntitlement`; fixed by declaring `keychain-access-groups`,
  device behaviour unchanged) and a memory-only fixture peer (replaced by a
  persistent one; harness, not product). Still `NOT RUN`: archive, `.ipa`
  export and TestFlight upload (the export-compliance gate is closed), a
  relayed call, a screen recording over the call stage, the Data Protection
  class on the device, and the
  remainder of the two joint tests with the owner in
  `docs/project/evidence/ios-client-20260913/`, which the session of
  2026-09-14 leaves `PARTLY RUN`: stage 1 steps 7-15 (closed-application
  delivery, screen lock, Wi-Fi to LTE, blocking, renaming, ten-minute idle)
  and stage 2 steps 1-3, 5-7 and 10-17 (the outgoing call from this client,
  the two-minute hold, hang-up behaviour, mute, speaker, screen recording,
  lock during dialling and during a call, background and closed-application
  calls, LTE and busy). The network-drop open item of
  2026-09-13/14 — the phone stayed at «Нет подключения» while the server
  answered from the Mac and the pinned key was unchanged — now has a cause and
  the fix above, but its proof stays `NOT RUN`: no real change of network path
  was produced on any device, so the fix is `CLAIMED` on a simulator against
  the local stand and nothing more. Separately, after the joint session of
  2026-09-14 the phone stopped connecting again and has not recovered. That is
  a different failure, which the restart does not address, and the first
  failure of this client to be read directly:
  a Debug build on the same device, launched with its console attached, shows
  the lane's signed `GET /v2/messages` timing out four times in 45 seconds
  (`NSURLError -1001`) on the first cycle of a generation, while the same
  route unsigned answers 401 in 0.19 s and `/health` in 0.2 s with the pin
  unchanged — so the pinned handshake did not fail and the route was alive.
  Measured at 07:06 Europe/Moscow and posted to the draft pull request #36.
  Row-by-row status is `docs/clients/ios/verification.md`.

### Push wake gateway (server) — 2026-09-12

- RFC-0020 (proposed): `POST /v2/push` registers an opaque FCM token over the
  signed session; after a committed message to a recipient without a live
  long-poll the server sends one content-free FCM wake (`{"t":"wake"}`),
  rate-limited per account; `UNREGISTERED` tokens are deleted. Off unless the
  operator places the Firebase service-account JSON at `<root>/push/` (loaded
  as a systemd credential; the environment carries the path only). The base v2
  schema is unchanged; `ss_push_tokens` is created only on a configured
  gateway. Outbound HTTPS to Google via rustls/webpki roots (`reqwest` moves
  from dev- to runtime dependency). Android registration/wake handling follows
  in the next client release.

### Single-host egress policy: orphaned TCP tails were dropped — 2026-09-12

- `deploy/single_host_network.py`: the relay egress chain now accepts
  established/related **TCP** before the `skuid` dispatch. Segments of a
  socket already closed by the messaging server carry no owner, did not match
  `skuid != relay`, and were dropped by `deny-other`; large responses (the
  16 MB APK on `/v2/updates/android/apk/…`) stalled at ~14.5 MB and the phone
  reported a failed update check. Relay UDP/bogon/local/IPv6 rules unchanged.
  Readback canonicalization handles the ct-state set; regression tests and a
  netns functional reproduction (old: truncated, new: full) in
  `docs/operations/voice-single-host.md`.

### 1:1 video calls candidate — 2026-09-11

- Call signaling moves to call-v2: a boolean `video` field, an informative
  encrypted `media` (camera on/off) control and a bundled `m=video` section
  (H.264 first, VP8 mandatory fallback, 12288-byte SDP). v2 rejects v1 call
  bodies; both alpha phones must update (text unaffected).
- Android: "Видеозвонок" button, in-call camera toggle and camera switch,
  remote/local renderers, `FLAG_SECURE` call window, camera pause when the
  app is not visible, speaker on video unless a headset is active, camera
  foreground-service type only while the camera is on (`0.0.16-video`).
- `0.0.17-video` (versionCode 17, 2026-09-12): a video-call start with the
  microphone already granted no longer cancels on the CAMERA-only permission
  result; the in-app update declares the installer `<queries>` intent and
  falls back from the system-only resolver, fixing "Установщик Android
  недоступен" seen on one alpha phone. No protocol change.
- `0.0.18-video` (versionCode 18, 2026-09-12), owner requests of 2026-09-12:
  - video call view keeps the screen on while local or remote video is shown
    and the proximity sensor no longer blanks the screen with the camera on;
  - local-only contact display names ("Переименовать" in contact details;
    stored in app-private preferences, never sent to the peer or server, not
    part of the encrypted state file);
  - audible call progress driven by the authenticated call state: incoming
    ring with the system ringtone and vibration (respects silent/vibrate
    ringer mode, 60 s cap), outgoing ringback while the peer's phone rings,
    short busy tone on busy/reject/timeout; incoming notification raised to
    maximum priority;
  - delivery: a default-network change (Wi-Fi/mobile switch, connectivity
    restored) restarts the long-poll immediately instead of waiting out the
    30 s poll and backoff. There is still no push provider (no FCM) in this
    build; background delivery relies on the user-enabled foreground
    connection and the OEM battery exception.
- `0.0.22-push` (versionCode 22, 2026-09-12): call setup froze after a crash
  on v21 (owner report). A push wake called `RealtimeLoop.restart()`, which
  bumps the loop generation and abandons an in-flight voice-relay (TURN)
  request and long-poll — exactly during call setup, when the peer's signaling
  triggers a wake. Wakes now only `nudge()` (leave a backoff pause without
  changing generation) and never act while a call is active/draining or the
  loop is already connected. Adds `CrashLog`: the last uncaught stack trace is
  kept in app-private storage and shown (copyable) on next launch; nothing is
  sent anywhere.
- `0.0.21-push` (versionCode 21, 2026-09-12): hotfix — v20 was built from the
  video branch before it contained the core `push` signing operation (main
  `dd072ec`), so the Java token registration hit an unknown core selector and
  the send lane stalled ("В очереди", owner report 2026-09-12 21:30). v21 is
  built after merging main; registration failures of any kind can no longer
  block sending (they are logged and retried on the next session).
- `0.0.20-push` (versionCode 20, 2026-09-12, RFC-0020 client half): Firebase
  Cloud Messaging is embedded through a SHA256-pinned 61-artifact closure in
  the manual javac/d8 build (no Gradle; `firebase_dependency.py`). After the
  signed session exists the FCM token is registered with `POST /v2/push`; a
  content-free `{"t":"wake"}` data message restarts the realtime loop (and the
  user-enabled background service) so the real message/call arrives over the
  E2EE channel. No notification content ever transits Google. Requires the
  server gateway (PR #28) to be deployed for wakes to be sent; without it the
  token registration is answered `push_disabled` and nothing changes. APK
  grows by about 5 MB.
- `0.0.19-video` (versionCode 19, 2026-09-12): in-app update falls back to a
  `PackageInstaller` session when the installer intent cannot be started
  (owner report "Установщик Android недоступен" repeated on one OPPO phone);
  the system confirmation dialog is preserved and the status line now shows
  the intent/session failure classes for diagnosis. No protocol change.
- Server: the existing host runs release `f65254ab` (main `fe9c26c`), which
  serves `global.paranoid.messenger` update metadata; v15 published.

### v15 review follow-up — 2026-09-11

- Corrected the threat model to describe opt-in `START_STICKY` and the inexact
  watchdog, including platform restrictions and unverified physical lifecycle.
- Fixed the standalone APK verifier: require a same-package older APK, include
  WebRTC in fresh Java/DEX compilation, use fresh artifact-policy classes and
  report the actual version rather than a historical constant. Current v14-to-v15
  verification passes; old-package v13 is explicitly rejected. No app runtime,
  signer, phone state or live publication changes are included.

### Dense contact-QR scan fix — 2026-09-11

- Fixed real-phone "add contact via QR does nothing": the in-app scanner
  preferred a ~640x480 camera preview, and a close-filling
  `paranoid-contact-v2` code (~800 bytes) falls below ZXing's module
  resolution at 480p. The scanner now selects the largest bounded preview
  (<=1280px). Host regression `QrDenseSmoke` reproduces the failure at the
  old resolution and gates decoding of dense contact codes at the
  scanner-class resolutions (v15, `0.0.15-voice`).

### Application rename and background watchdog — 2026-09-10

- By owner decision renamed the Android application ID from
  `org.paranoid.devtext` to `global.paranoid.messenger` (versionCode 14,
  `0.0.14-voice`, same retained signing certificate). This is a new
  application identity: testers install it fresh; no in-place upgrade from the
  historical package. Manifest, provider authority, intent actions, the
  RFC-0013 client `UpdateManifest`/`UpdatePolicy` package pinning and the
  server `android_updates.rs` metadata pinning now expect the new package.
  Publication metadata on the live server was intentionally NOT updated here.
- Hardened the user-enabled background channel against firmware kills
  (OPPO class): `BackgroundConnectionService` now returns `START_STICKY` and
  a non-exported `ConnectionWatchdog` `BroadcastReceiver` re-arms an inexact
  ~15-minute `AlarmManager` alarm to restart the foreground service if it is
  dead while the persisted user opt-in flag is on. No `BOOT_COMPLETED`, no
  exact-alarm permissions; the watchdog is cancelled when the user disables
  the background connection.

### Voice acceptance simplification — 2026-09-10

- By owner decision, froze the isolated VM/KVM full-rehearsal programme and
  replaced the production installer gate `coordinated-full-rehearsal` (and the
  separate `current-call-acceptance` receipt entry) with
  `local-loopback-acceptance`: an actually executed loopback TURN acceptance
  report (TURN-RT01/TURN-ACL02, six required cases, all PASS) bound to the
  exact kit turnserver digest and referenced by the `turn-rt01`/`turn-acl02`
  gates. Executed the acceptance for real (6/6 PASS) with the committed
  harness `deploy/turn/local_acceptance.py`;
  [evidence](docs/project/evidence/voice-local-acceptance-20260910/summary.md).
  The owner's physical two-phone call remains the final product acceptance.

### Runtime credential compatibility candidate — 2026-09-10

- Added a dedicated systemd credential-copy reader for the measured root0550/0440
  named-service-UID ACL pair, with exact fd/path/ACL checks and the private0400
  fallback. Generic/source/issuer0400/0600 policies remain unchanged. The former
  temporary-path launcher check recipe is withdrawn. Offline TDD and all six
  actual inert transient-unit cases pass. Persistent production-unit/static-UID
  delivery, relay acceptance and deployment remain pending.
  [Evidence and limits](docs/project/evidence/voice-ready-20260910/README.md).

### Single-host installer candidate — 2026-09-10

- Added candidate VM-profile dispatch and a rehearsal verifier that reads and
  binds actual reports, execution logs, service identities and both kits to the
  production plan. The availability gate remains closed pending the full runner,
  exact artifact review and real acceptance. [Contract and limits](docs/operations/voice-vm-rehearsal.md).
- Added a coordinated offline messaging/private-PostgreSQL/TURN kit with
  plan/preflight/apply/status/update/rollback, separate fresh and retained-v8
  paths, exact artifact/plan acceptance records, scoped network ownership and
  same-current-data recovery. The owner selected the existing host and retained
  TLS/data/identity. [The runbook](docs/operations/voice-single-host.md) records
  implementation, real fixture outcomes, review and remaining gates separately.
  Relay expiry/access-control/lifecycle and full call acceptance are still
  unverified; no hosted deployment or relay exposure has occurred.

### Incoming-call diagnostics — 2026-09-10

- Added test-only controller-first sampling and bounded sanitized SDK/host
  observations. One ordinary baseline failed naturally while its fixed companion
  decoded relay audio; [evidence and remaining unknowns](docs/project/evidence/call-connect-ordinary-20260910/README.md)
  keep CALL-CONNECT01 open. Production source and APK are unchanged.

### Voice relay client — 2026-09-10

- Added strict, volatile relay credential retrieval before media creation, with
  bounded independent I/O and generation-safe cancellation. Call and Answer now
  disclose relay/direct metadata before consent. Signed v10 builds and preserves
  owned-emulator v9 identity/contact/history. Parser, HTTPS/JNI and text checks
  pass; full extension acceptance, final review and missing relay packet gates
  remain explicit in [the local record](docs/operations/voice-calls-local.md).
- Added a reviewed500 ms relay-candidate publication window to prevent unrelated
  gathering delays consuming nearly the entire45-second call setup deadline.
  Actual both-role relay, cancellation/redial, late-callback, direct tone and
  rebuilt-artifact checks pass. Direct mode and authenticated immutable SDP
  retain their existing contracts; missing relay runtime gates remain explicit.

### Voice relay foundation — 2026-09-10

- Added an optional signed-session TURN credential issuer with locked active-device
  checks and bounded quotas. Disabled deployments retain existing messaging
  behavior. A versioned offline package adds isolated secret-file forwarding,
  a patched coturn build and a separate relay unit; [the runbook](deploy/turn/README.md)
  records actual offline checks and missing expiry/ACL packet gates. No live
  server, firewall, DNS, phone or public listener changes were performed.

### Voice implementation checkpoint — 2026-09-09

- Added native authenticated 1:1 call controls on the retained Olm channel,
  Android answer/reject/cancel/mute/routing lifecycle, microphone foreground
  service and pinned WebRTC/Opus integration. Calls retain core3/sealed4 identity,
  history and TLS trust. Fresh design closure and native/JNI/controller checks
  pass, including actual v8 text/receipt continuation and 3700 encrypted controls
  without exhausting the text replay ledger. Real Android/aiortc direct and local
  TURN relay audio pass decoded-tone, mute/unmute and teardown checks. [Exact
  evidence and remaining gates](docs/operations/voice-calls-local.md) record 14 app acceptance steps passing, with final inset UI
  and signed voice APK checks passing; independent final review remains pending. No new live listener,
  server change, physical-phone test or production quality claim is included.

### Realtime rollout — 2026-09-09

- Updated the existing isolated private-alpha service from release
  `346f059914a290be4851` to `3ed25173ad978e6b417c` after independent final Fable
  review and bounded closure. The attended `update-v2` exited 0, retaining the
  current database, TLS/configuration/unit and scoped neighbors; its 22,140-byte
  encrypted backup passed authenticated restore and six-table/schema comparison.
  Final postflight and actual hosted product Java/JNI first-contact, reply,
  receipt and reconnect checks passed. Twelve hosted sends measured P50 76.51 ms
  and P95 85.74 ms to durable receiver notification, not phone rendering.
- Built retained-signer ARM64 `org.paranoid.devtext` versionCode 8,
  `0.0.8-realtime`, with populated-v7 continuity and real Android emulator checks.
  The APK remains a private artifact; feed publication and physical-phone
  installation were not performed. The original intermittent packaged readiness
  failure remains unexplained, with the requested diagnostic and independent
  closure complete; it is not relabeled fixed. [Actual rollout and remaining
  limits](docs/operations/realtime-rollout-2026-09-09.md). Proposed ADRs remain
  unaccepted. The older deployment entry below retains its original scope.

### Deployed — 2026-09-09

- Installed the independently reviewed self-service-v2 release
  `346f059914a290be4851` on the existing isolated hosted alpha under the user's
  explicit live instruction. One-time old-data-only replacement exited 0 without
  backup/import; TLS/config-other-fields/unit/locks/backups/neighbors preserved.
  Existing enabled unit runs v2; external pinned HTTPS health reports
  `paranoid-self-service-v2`, controller SQL/TLS readiness passes and unauthenticated
  message/registration commits fail closed. [Actual rollout evidence](docs/operations/self-service-v2-rollout-2026-09-09.md).
  FPD-D01 documentation-only closure retains the historical pinned self-signed
  leaf and identical artifacts. Feed publication and phone installation/acceptance
  were not included; draft RFCs/ADRs remain unaccepted. This dated deployment
  supersedes earlier preparation-time pending-cutover wording below.

### Fixed

- FV2-R01: interrupted `replace-v2`, `fresh-v2` and `install-v2` operations
  now exit 130 with a static, redacted fail-stopped diagnostic, not false success.
  Real SIGINT regressions cover both sides of the scoped cluster discard and
  fresh initialization; no rollback, backup or retry is introduced. Graceful
  long-running `run` and legacy v0/v1 interrupt handling remain unchanged.

- Independent registration replay exposed intermittent decoding of pristine
  public grant QR images. The ZXing adapter now retains camera detection first,
  then tries its pure-image decoder on reader failure. A deterministic 200-grant
  regression runs in every APK build; typed credential checks remain unchanged.

- Native alpha rebuilds now use fresh private output and an exact regular-file
  allowlist, preserving ignored/stale operator files without shipping them.
  Lifecycle operations reject redirected or unsafe installation paths, invalid
  configuration and unconfined releases before writes or service stops.
  Native package/containment and non-systemd PG/TLS lifecycle tests now run in CI.

- Rejected/capacity-deferred client events no longer indefinitely stall later
  messages or authenticated receipts; failed crypto state is discarded and
  bounded rejection/progress metadata is persisted visibly.
- Outbound 409/507 failures retain exact retry bytes without blocking inbound
  processing or later outbox entries. Local storage uncertainty still stops all
  operations. Regression tests cover the failure paths.

### Added

- Realtime private-alpha candidate: reused pinned TLS, short-lived signed sessions,
  bounded long polling and independent state/network work publish durable text
  before receipt I/O. Native messenger screens and optional visible background
  connection preserve delivered v7 identity/history. Same-v2 maintenance adds
  encrypted restore-verified backup and same-data rollback. Exact local evidence,
  completed reviewed rollout and remaining limitations are in the
  [overnight runbook](docs/operations/overnight-realtime.md); no permanent ADR
  acceptance is implied.

- Clean-install first-contact client path (RFC-0014/REQ-MSG-005): every new text
  and delivery receipt uses a deterministic signed account-ID channel; unknown
  valid senders appear immediately with unverified identity and reply enabled.
  Immutable pins, transactional rejection, bounded peers/block and clean core3/
  snapshot4 persistence accompany the candidate. Unsupported older snapshots
  are preserved and refused; historical migration/recovery is outside this
  owner-selected build gate, with historical failures reported separately.
  Local test/build status is in `docs/operations/clean-first-contact-local.md`;
  publication, phone delivery and live actions remain excluded pending review.

- RFC-0013 local server update distribution: bounded read-only Android metadata
  and digest-named APK routes, with actual hash/size and safe-file checks. Only
  the v2 controller selects `ROOT/updates`; it creates/publishes nothing and
  leaves legacy environments unchanged. Combined-package review, publication
  authorization and Android installer acceptance remain separate gates.

- Fresh-only v2 Linux deployment candidate: explicit exact-reviewed IPv4:38443
  TLS, eight-member optional bundle, fresh install/schema/readiness, and stopped
  one-shot old-server-cluster replacement without migration or backup. Retains
  TLS, config IP/other values and phone state; sticky v2 blocks historical
  controller operations. [Scoped owner correction and runbook](docs/operations/fresh-self-service-v2.md).
  Independent review and coordinator cutover remain pending; no live deployment.

- Local self-service v2 server candidate for issue #16: automatic device-proof
  registration without grants, versioned one-use request authentication, general
  account/device/conversation storage, recipient cursor sync and commit-ordered
  exact retries under non-evicting quotas. Offline migration preserves verified
  legacy bindings/history and revocation, with historical startup/downgrade guards.
  Original runtime is loopback TLS/private PostgreSQL; the later fresh-only
  deployment candidate above is separate and still makes no hosted change. Draft [ADR-0007](docs/decisions/0007-self-service-messenger.md),
  [RFC-0012](docs/rfcs/0012-self-service-messenger.md),
  [wire contract](docs/protocol/self-service-v2.md) and
  [threat/test matrix](docs/security/self-service-v2-threats.md) accompany it.
  Independent local evidence: 19 targeted / 43 full server tests and external
  Python Ed25519/TLS/PostgreSQL probes passed. SR-01 documentation re-review,
  architecture disposition, client/phone acceptance and v2 deployment remain open.

- Migration-capable isolated Linux key-registration package: exact offline schema
  transition after verified restore, retained TLS/config/history, key-aware
  readiness and compatible code rollback. Process ownership now survives PG
  lock-backend loss; TLS keep-alive/idle occupancy is bounded. Populated native
  systemd/PostgreSQL/TLS/JNI tests pass; live cutover and phone acceptance are
  recorded separately, not inferred from local results.

- Local Android key-registration candidate (`org.paranoid.devtext`, 0.0.4-dev,
  versionCode 4): persisted independent root/device keys, exact-slot operator
  grants, automatic one-use key login, typed verified QR contacts and existing
  Olm text/receipts. Real isolated TLS/PostgreSQL/JVM JNI and populated v0
  preservation/restore tests accompany the signed ARM64 APK. No live migration,
  deployment, physical OPPO test or production architecture acceptance is claimed.

- Draft RFC-0010, proposed ADR-0006 and a key-enrollment contract clarify the
  requested phone-created identity/automatic proof/verified QR UX versus the
  existing manual bearer fixture. Recommended two-tester exact-key admission
  preserves legacy identities/history; the subsequent local candidate above
  implements the bounded flow without accepting the proposed ADR.
  Sergey accepts the one-time operator step as bounded Telegram UX input, not ADR
  or deployment approval. Canonical requirements retain future default/own/existing
  server selection and QR/link/store invitation UX, with independent trust and an
  explicit unverified deferred-link/fallback boundary; no alpha scope expansion.

- Authorized target-host rollout and resume: after an initially blocked attempt,
  explicit owner authorization allowed one precise IPv4 UFW TCP 38443 rule and
  retained-service/linger resume. External pinned TLS and negative pin/auth checks,
  Linux JVM Android TLS adapter, final-unit restart/crash recovery, and disposable
  history/restore tests pass. Original identities/data and neighboring services
  are preserved; physical OPPO acceptance remains unrun.

- Native Linux private-alpha package: locked release artifact, explicit direct TLS
  on 38443, isolated PostgreSQL 16, systemd user enable/restart, authenticated DB
  readiness, verified local backup restore and history-preserving code rollback.
  Local real-process tests pass; no production host change or phone test occurred.

- Development Android/Rust text-client code with peer-pinned Olm, encrypted local
  snapshots and explicit self-signed HTTPS SPKI pinning for IP-based connections.
  Local TLS/JVM/packaging checks pass; connected OPPO acceptance and hosted rollout
  remain blocked by the documented client/runtime and deployment gates.

- Development-only Rust/PostgreSQL HTTP transport with durable opaque-envelope
  acceptance, idempotent retries, recipient cursor sync, bounded non-evicting
  storage and real HTTP/database tests. No phone messaging or hosted deployment
  is delivered by this increment.

- Experimental ARM64 Android native crypto diagnostic with a local synthetic
  exchange and tamper/replay checks; no networking or production security claim.

- Draft single-server text contract and acceptance matrix for two OPPO phones:
  durable server/recipient delivery indicators, retained ciphertext history,
  reconnect, key-loss limits and future iPhone boundaries. No messenger shipped.
- Reproducible dependency-only server stack compilation probe; not a runtime
  server or accepted architecture.

- Owner-approved bounded closed-alpha review-policy exception (ADR-0003),
  effective on merge. E2EE, human decision ownership and the external
  security-review gate for sensitive/production use remain required.

- Initial documentation governance, project map, decision process, security
  threat-model skeleton, and contribution workflow.
- Explicit RFC closure states and human authority and evidence requirements for
  accepting ADRs.
