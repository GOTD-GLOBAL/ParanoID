---
status: accepted
owner: maintainers
last_reviewed: 2026-09-14
---

# Current project state

## iOS lazy wrapping-key correction — local candidate (2026-09-14)

At Yaroslav's request, the coordinator implemented a separate candidate based on
PR36 revision d96cea1: no key on Welcome, key acquisition at first commit, strict
key/file XOR, and no pending-defaults recovery authority. Existing state/codec
and reinstall-marker meaning are unchanged. Partial first-commit key creation
can freeze the installation; no key is deleted as rollback. Source-contract
RED/GREEN and UI checks ran on Linux. Yaroslav reported Mac execution of exact `0709212`: package 273/0,
lazy-key 9/0, storage 25/0 and signed-simulator Keychain 11/0, with baseline RED.
The [receipt](evidence/ios-client-20260913/lazy-storage-mac-0709212.md) records the
initial missing-notices failure and setup. The subsequent key-readback/direct-
commit follow-up still needs its own Mac run; physical device, upgrade and power
loss remain NOT RUN. Earlier evidence
below remains revision-scoped, not proof for this candidate. See
[handoff](../clients/ios/lazy-storage-handoff.md). No merge, ADR acceptance,
TestFlight or live-server action is implied.

## APK ceiling removal — local Android candidate (2026-09-13)

Sergey requested removal of the arbitrary APK cap on both components, while
avoiding unnecessary binary growth. Android candidate removes parser/provider
ceilings, keeps signed-long length and overflow-safe streaming checks, and checks
available cache space before transfer. Local JVM/pinned-TLS tests pass with a
23,400,000-byte synthetic transport fixture, plus unchanged integrity/trust
rejections. This is not signed-APK installation or phone evidence. The separate
server RFC-0013 amendment/PR owns the shared contract and server resource changes;
the reviewed server candidate is integrated here; installed clients still enforce
the old ceiling until updated.
Review additionally moved fallback PackageInstaller allocation/copy/fsync off UI,
with eight host-adapter lifecycle/fault cases and full SDK35 Java compilation
passing. Commit remains foreground-gated and user-confirmed. Independent fallback AI review
closed the UI-thread-copy and acquisition/close exception findings with APPROVE;
Opus was unavailable, so no Opus or human-audit claim is made.
A reviewed retained-signer bridge within the legacy ceiling must precede larger
feed publication, unless manually installed in place. No release/deploy/merge.

## APK ceiling removal — local server candidate (2026-09-13)

Owner direction is recorded in RFC-0013 and draft ADR-0008: no fixed APK size
ceiling, no unnecessary binary growth. Server candidate uses fixed-memory hashing
and anonymous disk snapshots, retaining two permits through response lifetime.
Local update unit/integration checks pass, including above-old-cap transport and
source mutation after verification. Android is a separate PR; installed clients
still require a bridge within the old ceiling. No merge, deployment, feed change
or phone acceptance is implied. Independent fallback AI review approved the final
bounded-channel implementation after fixing cancellation/I/O permit coupling;
Opus CLI could not authenticate, so this is not an Opus or human audit. Rollout
and physical-phone acceptance remain gates.

## Automatic same-key TLS maintenance installed — 2026-09-13

The [bounded same-key automation](../rfcs/tls-same-key-automation.md) is installed
on the existing host with a daily persistent user timer. It renews within 30 days
for 90 days, preserves key/pin/profile, journals public certificates and recovers
pending transactions before any not-due shortcut. Independent review is APPROVE;
13 crypto/file/control tests, four installer gates and actual local systemd/TLS
renewal/no-op/rollback checks pass. The [runbook and hosted receipt](../operations/tls-auto-renewal.md#observed-installation--2026-09-13)
record successful first `not_due` execution and enabled/active timer. Current
certificate expiry remains `2026-12-12T07:38:09Z`; renewal becomes due on
`2026-11-12T07:38:09Z`. Installation did not restart messaging or change its
certificate/config/package. Sergey explicitly authorized automatic **same-key**
renewal in this task; original Telegram permalink is unavailable. No permanent
ADR acceptance, key rotation, Telegram failure alert or phone/iOS acceptance is
claimed. The prior one-off record below remains historical evidence.

## Same-key TLS certificate renewed — 2026-09-13

The hosted alpha now serves a renewed self-signed certificate, valid through
`2026-12-12T07:38:09Z`, with the original TLS private key and SPKI unchanged.
The [operation and evidence](../operations/tls-renewal-2026-09-13.md) record
owner-scoped authority, independent review, synthetic rollback tests and actual
host/external checks. Only the dedicated messaging user service was stopped and
started; configuration, package, PostgreSQL identity and neighboring services
were preserved. Android `PinnedTls` on the JVM accepts the actual renewed
endpoint; physical phones and iOS were not tested. This retained 90-day renewal
is not automation: another renewal is needed before December 12. Key rotation
and any contact/channel migration still require a separate RFC.

## Native iOS client candidate — 2026-09-13

A second client exists as a pull request: a native SwiftUI application over the
**unchanged** shared Rust core, reached through a C-ABI bridge crate beside it.
[RFC-0021](../rfcs/0021-ios-client.md) and
[ADR-0014](../decisions/0014-ios-client.md) are `proposed`, not accepted;
`server/`, `clients/core/src/`, `clients/android/`, `key-protocol/` and
`deploy/` are untouched and a boundary gate enforces it.

**CLAIMED (simulator, host or local stand — the unchanged server binary against
a private PostgreSQL 16 on the build Mac).** Registration, QR contact exchange,
E2EE text with one-check and two-check receipts, block and unblock, the
first-contact story for a receiver with zero contacts, a reinstall that starts
a new identity, the injected transport and storage faults, the nine pinned-TLS
leaf checks, the call state machine against the Android smoke scenarios
(`94/94` labels), the TURN credential lane over a real pinned socket, and two
simulators placing and answering calls in both directions over direct ICE with
about 2300 RTP packets per side per call. Since 2026-09-14 the lanes also
**reconnect when the network changes**, which they did not before: a change of
the default path mints a generation with the lanes left enabled, cancels what
is on the socket and relaunches them, so a long poll over an interface the
device no longer has ends there instead of at its own 30-second bound plus the
backoff after it, while a change seen with the lanes stopped starts nothing;
«Повторить подключение» does the same restart unless a call is live or the
client is already connected, where it keeps Android's harmless half; and a
start or a restart says «Подключение · подробнее» rather than leaving the
previous caption standing, inventing no connected state. It is the port of
`TextEngine.watchNetwork()` and `RealtimeLoop.restart()` (Android's own fix of
2026-09-12, `2cdb850`), it adds no dependency, no background mode and no
`URLSession` outside the pinning delegate, and it is `CLAIMED`: a real path
change was never produced, because a simulator has no network of its own — the
rule was driven through the shipped watcher, runner and policy instead
([evidence](evidence/ios-client-20260913/README.md)). The 261 package tests
pass, six of them the reconnect rule's and five the storage and camera answers
to the review of 2026-09-14, with fifteen more in the application bundle and
eleven on the signed simulator's real Keychain; the
application test bundles and the local-stand scripts were run by the steps that
delivered them, and their output stays under `clients/ios/out/`, which is not
committed.

**SHOWN (physical phone).** On 2026-09-13 a signed Debug build ran on an
iPhone 16 Pro Max (iOS 26.6.1, Developer Mode on, team `5RPGVC566Q`, bundle
`global.paranoid.messenger`, installed with `xcodebuild` and `devicectl`)
against the local stand, bound to the Mac's LAN address so the phone could
reach it: identity creation on the device, the client's own QR, a contact read
off the Mac screen with the real camera, the fingerprint sheet, two texts
device→peer and one peer→device with receipts, and a call to a simulator that
connected and carried video from the device (the simulator has no camera;
whether audio was heard is not recorded). Two defects surfaced there, neither
on the device: an empty entitlements file made the simulator's Keychain answer
`errSecMissingEntitlement` (fixed by declaring `keychain-access-groups`), and
the fixture peer kept its key in memory only (a persistent peer replaced it —
harness, not product). Later that day a Release build signed with the same
team reached the hosted alpha, once App Transport Security was switched off:
the iPhone registered, paired the owner's Android from his QR image (scanned
off a screen) and sent one text the hosted server accepted — one check.
Delivery to the owner's Android was still pending because his phone had not
polled, and no reply exists. That pairing and that one accepted text were the
only contact with the owner's Android until the joint session below.

**SHOWN (joint, reported) — the owner's Android on the hosted alpha,
2026-09-14.** Yaroslav (contributor, iPhone 16 Pro Max on iOS 26.6.1, the
signed Release build of branch head `adb56be`) and Sergey (owner, Android)
held an **unscheduled** session on the hosted alpha at `157.180.49.125:38443`.
Yaroslav scanned Sergey's QR with the iPhone camera and the contact was
paired. Text went both ways: Yaroslav's message reached Sergey and **both**
checks appeared on the iPhone — the first time this client has seen the second
check, which is the acknowledgement from a real Android client — and Sergey's
reply appeared on the iPhone. Sergey then called the iPhone from his Android,
Yaroslav answered and they spoke, so audio carried both ways, and both sides
turned their cameras on and each saw the other. That call is the first this
client has carried against the Android client rather than a simulator, and the
first picture it has received from a real camera over call-v2. The contributor
is the only participant this record has: every result of that session is **his
report**, given immediately afterwards, not an observation by whoever writes
this file and not a recording, which is why the stage files mark those rows
`SHOWN (joint, reported)` rather than `SHOWN`. No owner "go" permalink exists
for it, because the session was not planned. Sergey did not scan Yaroslav's
QR, so the Android side of the pairing and the fingerprint compared aloud stay
`NOT RUN`, and so does the outgoing direction — this client dialling an
Android — which has been exercised only against a simulator on the local
stand.

**NOT RUN, with reasons.** No archive, no `.ipa` export and no TestFlight
upload: the device installs above were direct `xcodebuild` installs,
`build.sh`'s signed-archive gate did not run, there is no owner "go" for an
upload, and the
[export-compliance gate](../clients/ios/export-compliance.md) is closed —
`ITSAppUsesNonExemptEncryption = YES` is prepared, not satisfied, and Apple
applies the requirement to TestFlight too. The Data Protection class on the
device was not measured, no real screen recording was made over the call stage,
a screen lock during dialling moves to the joint test, and no relayed call was
placed, so all of those stay `NOT RUN`. The open item of 2026-09-13/14 — after
a network drop on the phone the application stayed at «Нет подключения» while
the server answered from the Mac and the pinned key was unchanged — now has a
cause and a fix (the connectivity restart above), but what stays `NOT RUN` is
the proof: no real change of network path was ever produced, on a simulator or
a phone, and no device log was ever collected for that drop.
Interoperability with the Android client on its own hardware is shown
only as far as the reported joint session above reaches; everything beyond it
rests on the protocol comparison, which ran with both stacks as processes on
the build Mac, where the real Android facade is compiled and agrees with the
Swift client on identities, text with receipts, call-v2 bodies, the sealed
snapshot codec and a QR contact, with twenty-one malformed bodies refused
identically by both sides.
The expectations are recomputed in Python from the protocol documents, so an
agreement cannot come from the two clients sharing one core. `build.sh` runs
that comparison and its Java host side as ordinary steps.
`.github/workflows/ios.yml` ran on
[pull request #36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36), opened
as a draft on 2026-09-14: `ios-static` passed, the docs workflow passed, and
the server workflow's `client-core-and-tls` and `native-package` passed.
Question 6 answered "no macOS runner", so nothing needing Xcode, a simulator,
a phone or the local stand is in it, and every such check was run locally on
the pinned build Mac. The two joint-test scenarios with the owner,
[stage 1](evidence/ios-client-20260913/stage1-text.md) and
[stage 2](evidence/ios-client-20260913/stage2-voice.md), are **partly run**:
the session of 2026-09-14 turned stage 1 steps 4, 5 and 6 and stage 2 steps 4,
8 and 9 into `SHOWN (joint, reported)`. Every other `Result` cell stays
`NOT RUN` with its reason — stage 1 step 3 (Sergey scanning Yaroslav's QR and
the fingerprint compared aloud) and steps 7-15 (closed-application delivery,
screen lock, Wi-Fi to LTE, blocking, renaming, ten-minute idle), and stage 2
steps 1-3, 5-7 and 10-17 (the outgoing call, the two-minute hold, hang-up
behaviour, mute, speaker, screen recording, lock while dialling and during a
call, background and closed-application calls, LTE, busy). Stage 1 steps 1, 2,
4 and the first half of 5 were also exercised solo on 2026-09-13 against the
hosted server with the owner's QR image, and stage 1 records that as a pre-run,
not as the test.

**Open since the joint session: the iPhone does not connect.** Measured on
2026-09-14 at 07:06 (Europe/Moscow) and posted to
[pull request #36](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#issuecomment-5658890864):
after that session the phone shows «Нет подключения» and has not recovered;
relaunching the application does not clear it. A Debug build was installed on
the same device and launched with its console attached — the first direct read
of this client's failure, since device logs otherwise need root on the build
Mac — and the log says, four times in 45 seconds:
`realtime: lane failed: NSURLError Code=-1001 "The request timed out." URL: https://157.180.49.125:38443/v2/messages?after=1259&limit=20`.
The pinned handshake did **not** fail (`PinnedSessionDelegate` logged no
refusal and the connection was established) and App Transport Security is not
involved (that was `adb56be`); the route is alive — the same URL unsigned
answers `401` from the build Mac in 0.19 s and `/health` in 0.2 s with the pin
unchanged, which is also why Safari on the phone reaches `/health`, a route
that needs neither a signature nor the database. What hangs is the **signed**
read for that account, on the first cycle of a generation, which asks for
`messages` rather than `events` (`ReceiveLane`, mirroring
`RealtimeLoop.java:254`), so the lane never reaches the long poll and never
publishes a connected state. The client gives that request 8 s
(`RealtimeTransport.readTimeout`) while the server's own budget for a
non-`/v2/events` route is 10 s before it answers `408 request_timeout`; that is
**not** an iOS divergence, because
`clients/android/src/org/paranoid/text/RealtimeTransport.java:36` sets exactly
`path.startsWith("/v2/events?") ? 30000 : 8000` for both clients, and this
branch does not change it. This is a **different** failure from the
connectivity-change parity gap above, whose fix is now in the branch: that gap
left a lane parked after a network change, while this symptom was a signed read
that did not return while the server was otherwise healthy, which no
client-side restart fixes and which the fix does not address.

**Hosted accounts spent: three.** `hosted_registrations` is 3: a
`service-bridge` registration from the build Mac on 2026-09-13, made while
diagnosing the phone's TLS failure to prove the client stack registers on the
hosted server while the phone could not; the physical iPhone's registration
once App Transport Security was switched off, which is the contributor's own
account and is still in use; and a diagnostic registration from the build Mac
on 2026-09-14 at 08:26:45.596+03:00 (`POST /v2/registration/commit`, 200 in
50.7 ms, its challenge at 08:26:45.396+03:00, 200 in 198.0 ms), public account
id `240060ebc49a9b7394f6fe4ccc30922e62dac9ae9a04ae89415423950ae16776`, opened
to answer the owner agent's request for a comparative signed read while
diagnosing the hosted server's intermittent failure (issue #38). That third
account is diagnostic: no messages, no contacts, and no relation to the
contributor's own account or to the owner's — it exists only to measure the
hosted server from a second identity. A third exists at all because the
2026-09-13 Mac account is permanently unreachable: that fixture kept its
wrapping key in process memory only, so its state file no longer opens and the
account is registered but dead. The diagnostic account is persistent instead —
its wrapping key is kept beside its state in
`clients/ios/out/evidence/hosted-probe-20260914/` (build output, not
committed; key file mode 0600) — so this diagnosis needs no further
registration. All three fall under the owner's answer to RFC-0021 question 4
(as many accounts as the tests need, no fixed budget). The joint session of
2026-09-14 consumed none: it used the account the iPhone registered on
2026-09-13. The phone's failure was a defect that only the hosted server could
show: ATS refused the self-signed leaf on a public IP before the pinning
delegate ran (`NSURLErrorDomain -1200`), which a LAN stand never shows and
`NSPinnedDomains` cannot exempt for an IP literal.
`adb56be` sets `NSAllowsArbitraryLoads = YES`, `test_ui_contract.py` holds the
contract "exactly that key and no `URLSession` outside `PinnedSessionDelegate`",
and [the trust delta](../security/ios-client-threats.md) and ADR-0014 record
why that removes nothing. Before those registrations the only contact this
branch had with the hosted alpha was a single TLS handshake with no HTTP
request, which confirmed that the pin this client carries still equals the
live SubjectPublicKeyInfo digest after the owner renewed the certificate **with
the same key** on 2026-09-13; the renewed leaf is valid to
2026-12-12T07:38:09Z. A same-key renewal must repeat before that date — the
[same-key automation](../operations/tls-auto-renewal.md) installed on the host
on 2026-09-13 does that — and a key *change* needs its own deploy-trust RFC,
because the pin feeds the first-contact channel transcript and would invalidate
enrolled contacts, not only the transport. The server has no account-deletion
path, so every future registration is permanent and is counted in the evidence
directory.

**Calls are call-v2, not voice v1.** RFC-0021 was drafted against voice v1;
`main` moved to [call-v2](../protocol/call-v2.md) under RFC-0019 while the
client was being written, and the client follows `main`: two media sections,
audio then video, both `a=sendrecv`, H.264 first with VP8 as the mandatory
fallback, camera on/off as a track flag plus an informative `media` control and
never a renegotiation, and a 9000-byte description cap below the measured
10040-byte frame2 ceiling. call-v2 rejects v1 bodies, so this client cannot
call an Android build older than v16 — and the call carried on 2026-09-14
therefore places the owner's Android at v16 or later; the exact version was
not asked for and is not recorded.

**Two differences from Android are permanent, not defects.** Delivery is
foreground-only — no APNs, no PushKit, no background refresh, no CallKit — so a
call placed to a locked or closed iPhone ends in the caller's expected
45-second `timeout`, and threat-model boundary 8 stays unused by this client.
And screen capture is not parity: Android's `FLAG_SECURE` has no iOS
equivalent, so the client covers the video stage while the screen is recorded,
mirrored or AirPlayed, while a screenshot and the app-switcher snapshot cannot
be refused at all. Both are written into
[the iOS trust delta](../security/ios-client-threats.md).

**Governance.** The owner delegated technical decision authority to the
contributor and recorded it at
[issue #27, comment 5651949919](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919);
the owner's agents answered RFC-0021 questions 5 and 10 in the same issue on
2026-09-12. The delegation settles technical choices; it does not waive
independent review, does not turn a `CLAIMED` row into evidence and is not the
ADR acceptance the human decision owner still has to give. The doc-to-code
discrepancies found while writing this client are **not** corrected in the
client pull request; they go to a separate docs-only change. Seven of them —
A.3, A.4, A.5, A.7, A.8, A.12 and B.5 — are carried as recorded waivers in
[protocol-sources.md](../clients/ios/protocol-sources.md), one per affected
row. That is the number this repository can show: the full findings report
("Findings from iOS-client preparation",
[issue #27](https://github.com/GOTD-GLOBAL/ParanoID/issues/27)) is not a file
in this repository, so any larger count of it cannot be checked from here and
is not claimed here.

**CI note.** The `Server transport` workflow runs on `clients/**`, so this
branch triggers it, and its `legacy-client-history` job is **deliberately red**
and informational (the fourteen archived failures are retained on purpose).
That workflow being non-green is therefore not a signal about this client, and
"all checks green" is never the right phrase for this repository.

## Video calls candidate (v16) and server f65254ab rollout — 2026-09-11

The owner (Сергей Мальцев, Telegram) requested video calls and resolved the
RFC-0019 questions (H.264 first with VP8 fallback; speaker on video unless a
headset is active). [RFC-0019](../rfcs/0019-video-calls.md) is proposed,
[ADR-0013](../decisions/0013-video-calls.md) is proposed and
[call-v2](../protocol/call-v2.md) plus the [video threat delta](../security/video-v1-threats.md)
are written. The native validator, `CallController`, media engine, call UI and
foreground service implement call-v2 (`0.0.19-video`, versionCode 19, retained
signer; v19 adds a PackageInstaller-session fallback for the in-app update; v16 was the first candidate, v17 fixed the video-call start permission
result and installer visibility, v18 adds screen-on during video, local contact
names, audible ring/ringback/busy and immediate reconnect on network change).
Push wake (RFC-0020, proposed): the server gateway is in PR #28 and the
client half ships in `0.0.20-push` (versionCode 20) — a content-free FCM wake
only reconnects the E2EE channel. Until the gateway is deployed with the
Firebase credential no wake is sent and behaviour equals v19. The OEM-killed
foreground connection remains the residual risk for devices without Google
services. call-v2 rejects v1 bodies: both alpha phones must update; text is
unaffected. v16 (`5041ca95…`) is published on `/v2/updates/android`
(2026-09-12). The first phone download failed because the relay egress policy
dropped orphaned TCP tails of the 16 MB response; that policy fix (PR #26, kit
`fa371be1`) was deployed the same day and a real v15 client verified the full
download against the live host. Physical two-phone video acceptance is
outstanding.

Earlier the same day, under explicit owner authority, the existing host was
updated by the unified kit (`c7d9205b`, transaction `e7f3b9a6`) to messaging
release `f65254ab` built from `main` `fe9c26c`, same data/TLS/PG identity,
relay unchanged; `/v2/updates/android` now serves v15 for
`global.paranoid.messenger` and the owner directed that later versions ship
through the in-app updater.

## v15 review follow-up — 2026-09-11

The realtime threat delta now describes the actual opt-in START_STICKY/inexact
watchdog behavior and Android/OEM limitations, not non-sticky or visible-only
restarts. This corrects documentation, not device-level reliability evidence.
The host APK verifier requires a same-package older APK, includes WebRTC in
fresh Java/DEX compilation and runs policy against freshly compiled classes.
Full retained-signer v14-to-v15 artifact verification and explicit old-package
v13 rejection are exercised locally; this does not install or publish an APK.

## v15 QR candidate and update publication status — 2026-09-11

The built v15 (`0.0.15-voice`, `global.paranoid.messenger`) retains the v14
signer and supports an in-place v14 update without resetting data. The scanner
selects the largest supported preview within 1280px; six synthetic dense-QR
frames pass the host regression. Physical-phone QR acceptance remains unverified.
Active RFC-0013, draft ADR-0008 and update runbooks now name the current package;
no permanent architecture acceptance is implied. Historical artifact evidence
retains its original package names.
The live update endpoint was checked with the retained TLS certificate and still
advertises old-package v13. The current Android parser rejects that metadata.
Source merge is separate from reviewed server rollout and APK/feed publication;
none of those live changes is performed by this naming correction.

## Application rename and background watchdog candidate — 2026-09-10

By owner decision the Android application ID changes from
`org.paranoid.devtext` to `global.paranoid.messenger` as a new application
identity: testers install v14 (`0.0.14-voice`) fresh; the retained signing
certificate is unchanged. Client manifest/provider/intents, RFC-0013 client
package pinning and the server `android_updates.rs` metadata pinning now use
the new package; the live server publication metadata still carries the old
package and was intentionally not republished in this change. The
user-enabled background channel additionally gets `START_STICKY` plus a
non-exported inexact ~15-minute `AlarmManager` watchdog receiver that
restarts the foreground service after firmware kills; no boot start and no
exact-alarm permissions. Historical `org.paranoid.devtext` references below
this section describe earlier releases and remain accurate for them.

## Voice deployed to the existing host; first real phone call — 2026-09-10

The unified kit (release `35ce8e7946f4879fd0a7`) was applied to the existing
host in transaction `440fd9fc` (phase `active`, existing-v8 mode, same data):
messaging updated to release `4eba2afd` with the `voice_turn` config, the
coturn relay (credential build `948cec15`, turnserver `e13597df1855`) runs on
the authorized TCP/UDP 34781 and UDP 40000–40015 scope, and the owner
completed a real two-phone call with good audio (both apps foregrounded).
External TURN reachability and a bidirectional relay media echo were verified
from outside. Eight live-deployment installer defects were found and fixed
with tests (`7c25d80..4974bdd`). Known remaining defects: the client drops
durable call signaling (`knock`/`ready`) when its online flag flickers, the
server forces reconnects (8s idle close, 120s connection kill), and background
delivery requires the opt-in foreground connection; a client fix and APK v11
are in progress. See issue #19 for the running record.

## Voice acceptance simplification and VM-stand freeze — 2026-09-10

The owner (Сергей, Telegram) decided: the isolated VM/KVM full-rehearsal stand
is frozen and is no longer a production acceptance prerequisite. Acceptance for
the one-host voice rollout is replaced by three real gates: local loopback
coturn acceptance (expiry, invalid HMAC, quota, denied-peer ACL, relayed media,
lifetime), a controlled journaled installation on the existing `157.180.49.125`
host within the authorized port scope, and the owner's physical two-phone call.
Details: [voice-single-host.md](../operations/voice-single-host.md#owner-acceptance-simplification--2026-09-10-telegram-сергей).
The frozen VM material remains preserved in branch history. The reviewed
installer change landed: production `GATES` now carry
`local-loopback-acceptance` instead of the frozen rehearsal gate, and the
executed loopback acceptance (6/6 PASS, TURN-RT01/TURN-ACL02, evidence in
`docs/project/evidence/voice-local-acceptance-20260910/`) satisfies it after
independent review; the verifier additionally binds the report to the exact
kit turnserver digest and required case set. The owner's physical two-phone
call remains the final product acceptance; no security property is weakened.

## One-host installer candidate — 2026-09-10

The owner confirmed the existing host and one unified installer. The
[exact authority and remaining gates](../operations/voice-single-host.md)
supersede earlier absence-of-host-permission statements for the bounded reviewed
deployment only. Initial sources/evidence and the signed v10 APK are preserved.
The coordinated offline kit implements plan/preflight/apply/status/update/rollback;
real owned messaging/private-PG/TLS fixtures pass fresh and retained-v8 updates,
idempotence, same-current-data rollback and one injected failure recovery.
Those fixtures keep the issuer disabled and do not prove relay integration.
A later targeted fresh-start run completed but has INVALID_RECEIPT acceptance:
its prior offline report had an import error. The original records are preserved;
a later passing offline run does not retroactively validate that receipt.

Production activation is explicitly refused: the full-relay fixture runner and
acceptance are unavailable, and TURN expiry/ACL/credential/lifecycle and CALL-CURRENT01 remain
unrun. The parent then executed the separately approved one-unit credential
diagnostic exactly once: root0440 rejection at `credential_descriptor` was observed,
with owned cleanup and unchanged scoped neighbors. The separately reviewed metadata measurement then observed exact root0550
directory and root0440 file ACLs: five entries granting only the service UID,
with owning-group/other permissions zero. Cleanup passed. After Opus5 design confirmation and its corrections, a dedicated
reader now implements the measured pair and private0400 fallback. Twenty-two
offline tests pass; generic/source/issuer guards remain unchanged. Fresh independent
Opus5 code review found no blocking runtime issue. After its required fixture
corrections, all six actual inert system/user-manager cases completed, including
planned restarts, missing-source243 failures, malformed-value rejection and verified
cleanup. User cases are informational; persistent production-unit/static-UID and
relay acceptance remain pending. No relay or deployment gate has passed. Initial Fable architecture review is
valid historical evidence. The owner explicitly accepts fresh independent Opus
review recorded as Opus; model branding is no longer a gate. All substantive
security findings, actual tests and final source/artifact review remain mandatory.
[The continuation record](evidence/voice-ready-20260910/README.md) supersedes the
prior unrun-diagnostic and named-reviewer-availability statements.
[Durable evidence](evidence/voice-single-host-20260910/README.md) preserves the
failures, exact model provenance, candidate artifacts and remaining next steps.
A reviewed disposable RAM-only development VM has now booted and verified live
no-NIC/no-disk isolation, loopback-only guest routes and clean poweroff. Official
pinned tools were extracted without a host installation. This establishes an
isolation capability only; exact full guest fixture/packet scripts still need
implementation, review and actual execution.
The [new VM-profile contract](../operations/voice-vm-rehearsal.md) now has candidate
dispatch, a separate current-boot boundary and real report/kit/log verification;
19 offline regressions pass after independent Opus5 review corrections. Production
availability stays empty while the full runner is implemented. Signed205-package
guest acquisition completed, including OS/JRE/media dependencies. A base RAM image
was then assembled and all17100 cpio records independently read back and verified;
The first KVM prerequisite run stopped before guest continuation when its
descriptor auditor rejected the observed read-only vCPU statistics object. The
owned process stopped; no guest or relay executed. A narrow metadata-aware
correction has thirteen passing offline tests and awaits independent review.
Android's documented nested-emulator restriction
is recorded as an unresolved compatibility limit, not current-call acceptance.
One authorized read-only host check confirmed message UID1003/GID1004 and enp5s0;
relay UID/GID1902 are free. The temporary SSH agent was cleaned up. No host account,
credential source, service or firewall was changed by that check.
CALL-CONNECT01 stays OPEN. No hosted deployment, firewall change, relay listener,
public release or PR merge occurred.

## Owner-confirmed one-host delivery — 2026-09-10

The owner's [existing-host and one-touch installation confirmation](https://github.com/GOTD-GLOBAL/ParanoID/issues/19#issuecomment-5613364943)
authorizes a coordinated messaging, private PostgreSQL and TURN installer on the
existing host, with deployment conditional on mandatory acceptance tests, fresh
independent review and rollback readiness. Retain the existing TLS, data, identity
and neighboring services. This supersedes older no-deployment-authority statements
only for that bounded same-host delivery; it does not authorize PR merge or accept
the proposed ADRs. TURN expiry/ACL and actual relay CLI/lifecycle gates remain
NOT RUN; full credential/lifecycle acceptance remains unestablished. No new
deployment or relay exposure is established by this authority record.

CALL-CONNECT01 remains OPEN for the unknown historical first cause. Initial
genuine Fable design review C conditionally permits the separate three-case
[CALL-CURRENT01 acceptance plan](../../clients/android/test/CALL-CONNECT01.md#current-build-acceptance-plan--2026-09-10):
incoming first microphone grant and retained-permission redial each with at least
30 seconds connected decoded audio, then an outgoing decoded-media call on the
same candidate, after relay gates pass in the owned disposable installer fixture.
All three cases remain NOT RUN. The source-time seam is deferred; the reviewed
v10 APK is retained with no new build or runtime instrumentation. The [client
handoff and review provenance](evidence/voice-single-host-client-20260910/README.md)
distinguish that genuine initial review from the later Fable request that returned
Opus models and Haiku, with no actual Fable usage. The one no-tool probe also
returned no Fable. These responses do not supply required fresh Fable approval;
final code/artifact review and technical acceptance remain outstanding.

## Bounded incoming-call diagnostic — 2026-09-10

One fresh ordinary baseline/fixed comparison used the same reviewed test observer
and unchanged local fixture. The baseline naturally failed through SDK safe error
`connection` then controller `mediaState`, 16.496 seconds after accepted Answer
with 23.357 seconds of setup budget remaining. The fixed arm published once,
installed the answer and decoded relay/relay Opus with complete normal cleanup.
[The evidence](evidence/call-connect-ordinary-20260910/README.md) preserves the
setup-only correction, partial native coverage, differing pre-Answer timing and
unmeasured Android process start/maps. Final Fable evidence review approved the
test-only publication and kept CALL-CONNECT01 OPEN; this does not
establish the native cause or identify every historical failure. Only test/docs
changes occurred; production sources and retained ARM64 APK are unchanged.
Missing TURN/phone gates and deployment/merge blocks remain unchanged.

## Current voice relay extension — 2026-09-10

The direct-call checkpoint below passed fresh final Fable review. The original
scope also requires REQ-CALL-006: issuer, Android integration and isolated relay
package. Server foundation draft PR21 is implemented/tested independently;
client draft PR20 now adds strict volatile credential retrieval, authorizing
state and dual metadata disclosure. V10 retained-signer ARM64 is built;
49 parser negatives, ten HTTPS/JNI scenarios and the stale401 race fix pass.
The full server85-test matrix and24-sample text regression pass (P50 102.04 ms,
P95 144.30 ms). Owned v9→v10 update retains identity/contact/history. Strict
full-app relay audio passes in both roles, but a measured43.05-second outgoing
setup exposed delayed SDP publication despite early usable relay candidates.
Fresh Fable final review found this functional blocker and conditionally approved
a500 ms relay-only publication window. The fix passes actual both-role relay
media, mute/two-way text, cancellation/redial and late-COMPLETE tests: publication
while still gathering has a0.545-second conservative upper bound after relay
arrival, one callback and unchanged fingerprint/ICE. Direct-mode bidirectional
tone/mute/cleanup also passes. Signed ARM64 v10 SHA256
`a44278f46751216fdb37519ae6f66a2966e678bbba11b13529d0777669ff4c7d`
passes independent44-input artifact correspondence. Fresh Fable exact-source
closure succeeded and closed VOICE-PUB-01; it requires the reviewed bytes committed
and refreshed CI correspondence. [Current evidence](evidence/voice-relay-client-20260910/README.md)
retains failures and separate scopes. Earlier15-second incoming failures
remain unexplained. All supported CI gates pass on the preceding exact commits;
the separate legacy job retains exactly14 historical failures.
Retained-allocation expiry/race/drain and ACL packet tests are NOT RUN after a
platform worker rejection; those operations were not retried. No live deployment
is authorized or performed. Proposed ADRs remain proposed. The dated checkpoint
below retains its original artifact and test scope.

## Voice relay foundation — 2026-09-10

PR18 was independently verified merged at `2026-09-09T22:01:42Z`, exact commit
`366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f`. This separate server branch starts
from that commit under the [component policy](component-boundaries.md).
[REQ-CALL-006](../product/voice-relay.md) now has a default-disabled authenticated
issuer, strict local secret loader, locked binding recheck, quotas and a versioned
offline coturn/controller package. Fourteen focused issuer tests, two quota unit
tests, controller/package tests and native offline build checks pass. The full
server matrix passes85 tests with one pre-existing APK-environment skip; the
text/JNI/pinned-TLS regression passes24 warm samples, P50 102.04/P95 144.30 ms.
[Durable evidence](evidence/voice-turn-20260910/README.md) separates these results
from the pending final independent review.

The actual direct-ICE client checkpoint is in [draft PR20](https://github.com/GOTD-GLOBAL/ParanoID/pull/20);
its relay integration will depend on this exact foundation commit. A successful
direct-ICE final review does not cover this extension. Required retained-allocation
expiry and ACL packet tests remain **NOT RUN** after a platform worker rejection.
[The runbook](../../deploy/turn/README.md) retains the exact proposed network
scope and rollback; no public TURN/firewall/DNS or existing-server changes were
authorized or performed. RFC-0018/ADR-0012 remain proposed.

## Voice implementation after verified PR18 merge

GitHub independently reports PR18 MERGED at `2026-09-09T22:01:42Z`, merge
commit `366ceeda8e88d47e4a9dcbb8e7d5f13387b6ec9f`. The clean feature worktree
`feat/voice-calls-20260909` starts from that exact commit. The owner's
[voice scope](../product/voice-calls.md) now authorizes local actual 1:1 voice
implementation, real tests, retained-signer APK and a GitHub PR for issue19.
[RFC-0017](../rfcs/0017-voice-calls.md) and [ADR-0011](../decisions/0011-voice-calls.md)
remain proposed. Fresh independent design review and exact-doc closure succeeded
before runtime implementation. Strict encrypted controls, post-commit dispatch,
the volatile consent/lifecycle controller, Android call UI/microphone service
and pinned WebRTC/Opus adapter are implemented. The [durable evidence](evidence/voice-calls-20260909/README.md)
records 62 supported native tests including 14 voice tests, actual old/current
Java/JNI compatibility and controller/adapter checks passing. Twenty simulated
maximum calls exchange 3700 real Olm controls without consuming the text Event
ledger; this is signaling evidence, not decoded audio.

Real Android M150/aiortc direct and isolated local TURN relay media pass with
decoded synthetic tones in both directions, mute/unmute and complete capture/route
cleanup. Exact captured SDP also passes real native/Olm validation and binding
substitution rejection. These are separate media and encrypted-control fixtures;
the owned Android v8→v9 in-place update also retains identity/contact/history and
passes new delivered text, microphone denial and incoming-without-capture checks.
Actual TLS retry/revocation and authenticated resume RED/GREEN pass. Full app
acceptance passes 14 steps, first microphone grant and deferred SDK mute corrections
pass, and actual process restart preserves identity/contact/history without media
resurrection. Final text regression passes 24 warm samples at P50 105.92 ms and
P95 122.99 ms. The final fixture5 app run repeats all 14 steps and visually
verifies corrected call-dialog system-bar insets. The retained-signer ARM64
`org.paranoid.devtext` version9, `0.0.9-voice`, is now built and verified:
SHA256 `4a2744de3427917098db252ec8b8919abd0b07731315e847a47f8e8a63c3066f`,
15,712,851 bytes. The [artifact/source record](evidence/voice-calls-20260909/signed-apk-artifact.json)
retains the frozen uncommitted feature-source manifest; post-build documentation
updates leave packaged code unchanged. Fresh independent exact-source final
Fable review remains required before candidate handoff.
Working v8 text/identity/pins/history remain protected. Live TURN/firewall/DNS
or existing-server changes need separate concrete reviewed authorization. See
[the current gates](../operations/voice-calls-local.md). Physical OPPO audio,
Bluetooth, Doze/force-stop, public relay and production claims remain unverified.

## Owner phone feedback and PR 18 merge direction

After receiving v8, Sergey reports: "Работает отлично. Текст летает туда сюда".
This is qualitative owner-observed responsive bidirectional phone messaging,
not an instrumented latency measurement or proof of background/Doze/audio behavior.
[The GitHub record](https://github.com/GOTD-GLOBAL/ParanoID/issues/16#issuecomment-5609070441)
retains that distinction. It supersedes only the earlier absence of phone-text
feedback, not the other NOT-RUN limits below.

The owner explicitly requests testing/fixing/merging PR #18 and then implementing
voice calls. [The scoped merge record](pr18-merge-scope.md) supersedes the PR's
initial archival-only restriction for this one reviewed integration. Final CI and
review gated that integration; its verified merge is recorded above.
Voice calls are the next stage, not an implemented v8 feature. Existing identity,
E2EE, TLS trust, history and working text remain protected.

## Overnight realtime implementation and rollout — 2026-09-09

The [current owner scope](../product/overnight-realtime.md) authorizes a tested
in-place v7 improvement and safe existing-service update after independent Fable
review and rollback readiness. Initial dirty sources are preserved; TLS, phone
identity, v7 history and existing server data remain compatibility boundaries.
The signed-session long-poll transport, independent network/state lanes, native
messenger UI and optional visible background connection are implemented.
Matched optimized JNI measurements improved from P50 3043.98/P95 3057.50 ms (v7,
20 messages) to P50 102.94/P95 122.01 ms (24 messages). These are actual pinned-TLS/PG
receiver commit/listener timings, not physical display-frame measurements.
Populated-v7 upgrade continuity and all 14 realtime server tests pass. Android 35
emulator real messaging, keyboard and background permission/delivery checks pass.

[The dated rollout](../operations/realtime-rollout-2026-09-09.md) records successful
independent final Fable review and bounded closure, the signed ARM64 version 8 APK,
and the attended same-data update to release `3ed25173ad978e6b417c`. The existing
unit is active/enabled; TLS, configuration, cluster and scoped neighbor checks
match. An authenticated restore-verified encrypted backup preceded cutover.
Actual hosted product Java/JNI messaging passed with two synthetic identities:
12 sends measured P50 76.51/P95 85.74 ms to durable receiver notification, separately
from the local benchmark and physical rendering. Final postflight passed at
2026-09-09 20:59:04 UTC. The original packaged readiness failure remains UNKNOWN
(13 PASS/1 FAIL); subsequent diagnostic passes and review closure do not fix it.
The [runbook](../operations/overnight-realtime.md) retains attended recovery limits.
RFC-0015/ADR-0010 remain proposed, with direct scoped task authority distinguished from permanent ADR
acceptance. Physical phones, Doze/force-stop, voice, second-server operation and
provider push remain unrun or unimplemented. Historical pre-v7 failures remain
separately visible. Older dated sections below retain their original scope;
the current task supersedes their no-deploy boundary only for this reviewed update.

## Clean-install first-contact candidate — scoped implementation authorized

The current **2026-09-09 Telegram implementation task** is quoted in
[REQ-MSG-005](../product/requirements.md#first-contact-incoming-correction-2026-09-09)
and [RFC-0014](../rfcs/0014-first-contact-incoming.md). No permalink/message ID
was supplied. The selected recommendation is the mandatory signed deterministic
account-ID channel for all new text/receipts, with immediate plaintext/reply for
a recipient with zero contacts and visibly unverified identity.

Exact current task excerpt (2026-09-09); earlier owner approval is reported by
this task, not independently retrieved as a permanent message in this context:

> DELIVER implementation + actual built APK candidate for CLEAN-INSTALL first-contact messenger now. User explicitly approved review recommendation and discarded old teststate/migration/recovery as release gates (see context).

The human owner selected the first independent design-review recommendation:
mandatory deterministic signed account-ID channels for all newly created text
and delivery receipts, within the existing bounded private test-data alpha.
Fresh app installations are the acceptance scope. Historical test-message
preservation, migration and exact old-event recovery are explicitly NOT gates
for this candidate. Historical failing tests remain present, run separately and
reported honestly; this scope amendment does not make their bugs fixed.

The owner will uninstall applications himself. This task authorizes local source,
TDD, isolated PostgreSQL/pinned-TLS/JVM/JNI testing and retained-signer APK build
before independent code review. It authorizes no phone action, snapshot reset,
live database wipe, SSH, deploy, upload, publication or delivery to phones.
Unsupported older client snapshots must fail clearly while preserving their
bytes; clean installation is not an automatic migration or reset implementation.
Permanent architecture disposition remains proposed, with independent review
and durable approval provenance still outstanding. No additional permission
question is required for this exact local implementation/testing/build scope.

The clean Rust matrix actually passes **15 tests / 0 failures / 0 ignored,
exit0**, plus a separate passing stripped-new-frame/historical-v0-decoder check;
final additional boundary-suite results are in the external evidence record.
The real exact-retained-server + generated
pinned-TLS + isolated PostgreSQL + Android Java/JNI final fixture passes **exit0**:
five automatic registrations, zero initial receiver contacts, immediate
plaintext/unverified reply, genuine receipts, database frame2 comparison, exact
lost-response retry, injected receipt-save rollback/freeze, same-key verification,
block/unblock, unrelated progress, crossing and encrypted snapshot/server/JVM
reopen. Native/Java/fixture sources were unchanged across that final run.
Clean creation/reopen and genuine populated-old-state/pristine-interrupted-creation
JVM boundary checks also pass. These are local results, not phone acceptance.

Historical tests are retained and run separately: frozen initial core **39 passed /
2 failed / 0 ignored, exit101**; final unchanged historical core **27 passed /
14 failed / 0 ignored, exit101**. Two old JVM schema/migration smokes exit1;
the original reciprocal-contact real fixture exits0. No old failure is suppressed
or called fixed. [The local candidate record](../operations/clean-first-contact-local.md)
identifies exact commands/results and the unique external source/build/APK
verification record. Artifact hashes live in that evidence README, avoiding a
circular hash in the source snapshot. Independent code review remains the next
gate before any publication or phone delivery; no live action was performed.

All older implementation/deployment sections below describe their dated scope;
where they called historical recovery an immediate release blocker, this explicit
clean-install amendment now controls this candidate only. Existing live state and
previous authority records are preserved without new live verification/actions.

## Historical self-service product priority — before the later implementation

The active workstream is [issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16)
and its [English product brief](../product/self-service-messenger.md). The
`feat/self-service-registration` setup started from the preserved archive and
did not itself implement or deploy self-service. The subsequent local server
candidate is recorded below; the complete application journey is not delivered.

The owner rejected operator-dependent onboarding and approved preserving the
current implementation in an [archival checkpoint](operator-approval-checkpoint.md),
without merging it wholesale into main. The next deliverable is the self-service
app/server flow in [REQ-ID-008](../product/requirements.md#default-server-self-registration-correction-2026-09-09):
create ID, automatically register on the common server, add a contact, message.
It was not implemented by the historical operator-grant code. Blockchain registration
and public/private server choice remain the later direction, with identity and
history continuity required. No new runtime or hosting change follows merely
from the archive/issue task. Historical implementation/rollout observations below
remain evidence, not the target user experience.

## Historical fresh v2 preparation — before the live rollout above

Sergey explicitly requested a new database in place of the disposable old server
database and no preservation/backup. The [fresh-v2 runbook](../operations/fresh-self-service-v2.md)
records that supplied task provenance without a fabricated permanent approval.
Only the isolated `data` cluster is the discard target; TLS, phone state, socket/
locks, neighbors and other root contents remain protected. No live worker action.

The local candidate adapts the existing bundle/controller: explicit exact-reviewed
IPv4:38443 TLS v2 runtime, fresh initialization, stopped one-shot cluster replacement
without dump/import, sticky v2 config, readiness and existing autostart/supervision.
The separate retained `sr01-independent-rereview.md` reports `sr01_closed: true`
for the original documentation-only correction. Earlier pending-SR-01 wording
below is historical; that closure does not review these later deployment changes.
V0/v1 remain separate; legacy backup/update/switch cannot operate on v2. Independent
candidate review precedes any coordinator cutover. V2 update/restore and physical
two-phone acceptance are not established by this fresh-only slice.

Independent final candidate review found FV2-R01: SIGINT could falsely return
success during destructive replacement. The local correction makes interrupted
`replace-v2`/`fresh-v2`/`install-v2` operations exit 130 with a redacted fail-stopped
diagnostic, preserving sticky state and legacy/graceful-run behavior. Regression
and rebuilt-package evidence require bounded independent re-review before cutover;
this correction accepts no ADR and performs no deployment.

## Historical RFC-0013 bundle integration — before final review and rollout

The optional read-only Android feed and v2-only controller environment are now
combined locally after FV2-R01's independent bounded closure. The controller
selects `ROOT/updates` without creating it; missing publication stays unavailable,
and legacy modes do not inherit the feed. Strict RED/GREEN controller coverage
checks that selection and preserved legacy authority. See the
[publication contract](../operations/android-update-publication.md).
The final combined bundle still requires independent review; this is not live
publication, phone installer evidence or acceptance of draft ADR-0007/0008.

## Historical self-service v2 local verification — before live rollout

The `feat/self-service-server` worktree now implements the server part of issue #16:
automatic device-proof registration, v2 exact-request one-use authentication,
general accounts/devices/account-pair conversations, recipient cursor inboxes and
commit-ordered idempotent ciphertext storage with non-evicting limits. Explicit
offline initialization/migration preserves verified legacy ownership/history and
revocation; downgrade guards reject old authority. The original runtime requires loopback TLS,
a private PostgreSQL socket and single-worker ownership. The later explicit
exact-IP candidate above adds a separate mode; it has not been deployed.

[RFC-0012](../rfcs/0012-self-service-messenger.md), draft
[ADR-0007](../decisions/0007-self-service-messenger.md),
[the versioned contract](../protocol/self-service-v2.md) and
[dedicated threat/test matrix](../security/self-service-v2-threats.md) accompany
this implementation. No accepted historical decision was rewritten.

[Independent server evidence](../server/self-service-local.md#independent-server-review-evidence)
records 19 targeted and 43 full server tests passing, including populated DB
dump/restore, plus independent Python Ed25519/TLS/PostgreSQL probes and actual
historical executable downgrade tests. Review found no runtime blocker but failed
overall on missing documentation (SR-01). This documentation correction supplies
the artifacts; independent coordinator re-review remains pending. These are prior
local runtime results, not a new runtime run, CI result or architecture approval.

Major residual risks: shared budgets are not Sybil resistance/fairness; copied
public credentials can starve challenges; no mutual-contact ACL prevents unsolicited
messages to known IDs; authenticated recipient probing and server-visible metadata
remain. Startup checks the v2 metadata row, not full schema attestation; health is
liveness. Human residual risk/disposition owner is martadvix-web, pending acceptance.

No client completion, multi-peer Olm/receipt interoperability, physical phones,
installed snapshot migration, v2 package/controller lifecycle, public deployment
or production readiness is established here. The historical hosted operator-grant
rollout below is not a v2 rollout. Complete issue #16 acceptance, owner architecture
disposition, separately authorized deployment and two-phone evidence remain open.

## Phase

**Inception and architecture discovery, with a locally tested messenger candidate.**
The repository contains documentation, Android diagnostics, development transport
and the clean-install signed first-contact Android/core candidate described above.
Actual physical two-phone acceptance and production architecture are not yet
established. Local JVM/JNI messaging is evidence within its documented scope.

The earlier proof of concept is preserved in the private
`GOTD-GLOBAL/ParanoID-legacy` repository. It may be mined for lessons, UX ideas,
and experiments, but it is not a dependency or source of current architecture.

## Experimental device evidence

A disposable Android packaging diagnostic exists in
`spikes/002-android-bootstrap`. The owner supplied a screenshot of installation
and launch on OPPO CPH2671 (Android 16/API 36). It displays device information
locally, has no network permission and is not a messenger or stack acceptance.

## Present facts

- The new repository is private and intentionally starts from a clean history.
- The product vision is documented as a draft.
- Initial product requirements are traceable but do not yet have complete
  acceptance criteria.
- Documentation-as-code is the first accepted project decision.
- No production application stack, blockchain, identity protocol, messaging protocol,
  cryptographic construction, database, hosting platform, or token model has
  been selected.
- No production security or privacy claims are valid yet.

## Experimental Android evidence (not a production capability)

The isolated [Android probe](../../spikes/002-android-bootstrap/README.md) builds
an ARM64 APK using vodozemac with a JNI boundary for a local synthetic self-test.
Host tests and cross-compilation pass. The session handoff records owner-reported
local diagnostic PASS on OPPO CPH2671 and CPH2659 (Android 16 ARM64); this is not
a new physical-device run or proof of phone-to-phone messaging. No server, real
conversation, account recovery or production stack is introduced. RFC-0004
(closed PR #6) is historical proposal context only.

## Active single-server implementation boundary

The founder now prioritizes one server and two OPPO phones exchanging E2EE text
with history, reconnect and no duplicates. One check means server acceptance;
two mean peer delivery, not reading. Server history remains until an additional
explicit deletion request. iPhone and multiple-server support remain future
scope; a second server is not an acceptance gate for this slice.

[RFC-0006](../rfcs/0006-single-server-text-contract.md) records concrete assistant
recommendations and their [acceptance matrix](../protocol/server-v0-acceptance.md).
It is draft, not an accepted architecture. Identity/E2EE, delivery/persistence
and stack still require their own disposition and durable owner approval
evidence under the now-accepted ADR-0003 process. Absence of a second human
is not itself a closed-alpha blocker. Earlier PRs #1, #2, #5, #6 and #10 were
closed without merge during owner-requested cleanup. Their branches and research
are retained, not accepted architecture. PR #12 published ADR-0003. This
contract, native crypto evidence and host-access documentation are separate
artifacts, not prerequisites requiring another broad research phase.

A [dependency-only stack check](../research/2026-09-08-server-stack-check.md)
compiled pinned Axum/Tokio/SQLx dependencies on Linux. It implements no server,
API, message store or client. No phone-to-phone message has been demonstrated.
The local Docker daemon was inaccessible to this invocation; no production host
was changed. No iOS build or protected-domain implementation was performed.

The older discovery list below is background, not a request to restart broad
research. The immediate gate is disposition of the narrow contract, then the
TDD implementation order in RFC-0006.

## Closed-alpha review policy

The founder requested removal of the mandatory second-human reviewer after
reporting that none is available. [RFC-0007](../rfcs/0007-closed-alpha-review-policy.md)
records a bounded private test-data alpha exception with independent AI review
and retained human decision-owner approval, approved by martadvix-web in PR #12.
[ADR-0003](../decisions/0003-closed-alpha-review-policy.md) records acceptance;
the policy is normative on main. It accepts no application architecture,
authorizes no deployment and makes no security claim.

## Executable transport increment in development

RFC-0008 and draft ADR-0004 accompany `server/`: a loopback HTTP process with
PostgreSQL ciphertext append, idempotent retry, recipient cursor sync and
non-evicting quotas. Real tests include killing/restarting the binary and Olm
fixture ciphertext exchange. Fixture identities are trusted inside the test
process, not two phones. This initial transport increment alone did not provide
the subsequent Android client described below or a hosted rollout. The full
RFC-0006 acceptance matrix remains unfulfilled; architecture is not accepted.

A fresh owner-authorized read-only host inventory confirmed Docker, Nginx and
PostgreSQL active and HTTP/HTTPS ports occupied. No remote mutation occurred.
ParanoID deployment must be isolated from existing services. The local test
runner creates/removes its own private PostgreSQL cluster; it does not connect
to that host. Simple reproducible Linux deployment remains a product requirement.

## Development client and IP-TLS work

`clients/core` and the Android adapter now contain peer-pinned Olm text/receipt
logic, an encrypted atomic local snapshot and IP-based pinned HTTPS. An ARM64
APK builds; Rust, Linux JVM JNI/codec, packaging and local TLS smoke checks pass.
These do not prove runtime behavior on OPPO. The [client README](../../clients/android/README.md)
records the corrected synchronization cases, rejection/progress semantics and
the bounded device-test sequence. Code regression results are not device evidence.
No hosted TLS endpoint, new production process or public port is created by this
increment. Full two-phone acceptance is still pending.

## Locally verified deployment preparation

`deploy/` now builds a native Linux alpha bundle with a separate explicit direct-TLS
server mode on 38443, private PostgreSQL 16 data/socket, systemd user autostart and
restart, authenticated DB readiness, and same-schema update/rollback retaining
history. Real local systemd/PostgreSQL/TLS and dump/restore comparison tests pass;
no Docker runtime test, host login/change, reboot or two-phone acceptance occurred.
The [runbook](../operations/linux-alpha-deployment.md) records operator commands
and remaining limits. RFC-0009 and ADR-0005 are draft; parent independent review
is pending. The owner [authorized the bounded alpha](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
and isolated deployment after safety/rollback checks; no new broad research or
second-human gate is inferred within that already approved scope. This task is
local preparation only. Production architecture/privacy claims remain unaccepted.

The independent package review reproduced stale-file bundling and redirected
persistent-directory writes. Local fixes add fresh allowlisted build output,
no-follow/private installation checks and exact IPv4/token configuration validation.
Negative regressions and real native PG/TLS update/rollback checks pass; CI now
includes non-systemd package coverage. Independent re-review is still pending;
no hosted rollout or new architecture approval is inferred.

## Authorized hosted attempt and narrowly scoped resume

PR #15 merged as `f8131cd92e9e5945667b0257944552676885455d`; independent
fresh-context review reported no package blockers and all four PR checks passed.
These supersede preparation-time pending-review statements above, not the draft
architecture disposition. The [actual rollout record](../operations/linux-alpha-rollout-2026-09-08.md)
records matching artifact provenance, target ABI/prerequisites, disposable native
retry/history/update/restore tests, and successful final-unit host-local TLS/DB
readiness. External TCP/38443 timed out; read-only UFW inspection found incoming
default-deny and no 38443 rule. No firewall or neighboring service was changed.

The first attempt stopped/disabled the unit and restored `Linger=no`. The owner
then explicitly authorized, in the current 2026-09-08 Telegram turn, inbound TCP
38443 from any IPv4 source on the public IPv4 interface and resume of the retained
service. No Telegram permalink is available. One precise UFW allow on `enp5s0`
to `157.180.49.125` was added; other rules and neighboring services were preserved.
The retained unit is now enabled/running with scoped linger. External verified
certificate/IP/SPKI health and wrong-pin/missing/invalid-auth rejection passed,
including the real Android TLS adapter on the Linux JVM. Explicit restart and
child-crash recovery preserved original config/TLS and ordered database rows.
The enrollment database still has zero envelopes; populated retry/restore evidence
comes only from disposable fixtures. **The hosted alpha endpoint works; physical
OPPO acceptance remains NOT RUN.** Parent independent endpoint verification and
reviewed APK/signature/private enrollment precede device acceptance. Do not treat
the old diagnostic APK as a messenger or reset any retained identity.

## Registration UX correction — locally built candidate, not deployed

The 2026-09-08 user input rejects manually obtaining a bearer and requests
Threema-inspired on-phone identity creation, locally owned keys, automatic key
proof and verified QR contacts, without phone/email. Baseline `7bef87b` had
URL/pin/alice-or-bob/token fields and copied pairing codes. The local candidate
replaces them rather than hiding those bearers in QR.

[RFC-0010](../rfcs/0010-phone-key-registration.md), proposed
[ADR-0006](../decisions/0006-phone-key-registration.md) and the
[draft contract](../protocol/key-enrollment-v1.md) recommend exact-key maintainer
approval for only the existing two testers, explicit legacy mapping and one-use
request proof. A public TLS listener is not permission for anonymous public signup
or first-free-slot assignment. Blockchain is later; no recovery redesign.
The Telegram follow-up accepts Create ID -> one-time operator approval -> messaging
for this alpha (“Пока что пойдет”); it does not approve the manual-token UI or prove
the proposed flow works. Durable exact-scope/architecture evidence and independent
review remain pending; ADR-0006 is still proposed, with no new rollout permission.
The subsequent implementation-worker CLI instruction explicitly authorized only
local implementation/build and isolated fixtures. It corrected a delegation typo:
the actual application package stays `org.paranoid.devtext`, while Java/JNI remains
`org.paranoid.text`. A signed ARM64 API26+ 0.0.4-dev/versionCode4 APK is built with
the original signing identity. Independent root/device keys are saved before
requests; known-phone approval explicitly maps the verified credential/old Olm
digest to slot 0 or 1. No arbitrary-key registration rows or reusable key-login
bearer are created. Active slots reject v0 bearers on every message route.

`KeyClient` is exercised on the real Linux JVM/JNI against isolated Rust TLS and
PostgreSQL: registration, login, QR encoding/decoding, E2EE text, receipts,
restart, populated v0 state preservation and dump/restore. The client retains
`text-state.enc`, the Keystore alias, old Olm state/history/pins/outbox and saved
TLS trust. A missing snapshot with a retained wrapping key also fails closed.
The [local runbook](../operations/key-registration-local.md) records commands,
limits and evidence. This is a working local candidate, not a phone-test result.

No live service, database, secret, firewall or other worktree was changed. The
key-server mode intentionally binds only loopback and cannot be substituted into
the existing deployment controller. The public APK default remains the supplied
origin/SPKI, but the hosted endpoint was NOT upgraded to key registration here.
Existing same-schema deployment gates remain intact. Parent independent review,
separately authorized migration/deployment and physical OPPO acceptance remain
outstanding; ADR-0006 is still proposed.

## Authorized two-phone registration rollout preparation

On 2026-09-09 Sergey supplied screenshots labelled phone 1 and phone 2 showing
local ID creation/pending status, followed by the two labelled public registration
requests. Both root signatures, account derivations, expected realm and SPKI were
verified locally. This is user-supplied device/UI and credential evidence, not
server activation, full Android Keystore acceptance or demonstrated messaging.

Sergey then explicitly answered “Разрешаю” to the bounded isolated-server update
and activation request after independent checks and history-preserving recovery.
[The authority record](../operations/key-rollout-authorization-2026-09-09.md)
supersedes the prior local-only task's no-deploy restriction for this exact scope;
production architecture acceptance, neighboring changes and merge remain excluded.

A fresh read-only host check found the retained v0 service and exact pinned TLS
healthy, zero envelopes/sequence/usage, no key schema, unchanged neighboring
service PIDs/activation times and private root/config/TLS permissions. That check
made no mutation. The subsequent migration-capable package passed populated
native/JNI/restore tests and independent review. The
[actual rollout](../operations/key-rollout-2026-09-09.md) now records successful
history-preserving migration and the reviewed ALPN correction, unchanged TLS and
neighbors, working external key-auth routes, and two exact-key operator grants.
The grants are `approved`, not yet proof of phone activation or messaging. Public
phone inputs and grant descriptors remain outside Git. No phone reset or new APK
was needed; physical activation/contact/message acceptance awaits the user's scan.

## Future server onboarding direction — recorded, not implemented

Sergey's supplied 2026-09-08 Telegram input prioritizes preserving the product idea
rather than rebuilding today's implementation: default to the common project
server, offer create/self-host or join a known existing server, and share server
invites by QR/link. Without the app, guide to Google Play/App Store and resume the
invite after user/platform-mediated installation. Deferred continuation is
platform-dependent and unverified; fallback is to reopen the original invite.
[Requirements REQ-SERVER-001/002 and REQ-CLIENT-002](../product/requirements.md#server-onboarding-direction-future-production-ux)
and [RFC-0010](../rfcs/0010-phone-key-registration.md#future-server-onboarding-boundary)
capture this direction without a new broad RFC or current implementation gate.
Server invites are not verified contact pairing; independent server trust/admission
and existing identities/history remain intact, with no permanent default-server
authority, secret grants in app/store URLs or auth bypass. Simultaneous multi-server
operation, iOS and store publishing are not two-OPPO alpha acceptance requirements.
This is Telegram product provenance, not fabricated GitHub approval or delivered UX.

## Confirmed client compatibility risk (2026-09-09)

A synthetic reproduction confirms asymmetric retained-contact migration can
select incompatible authenticated message contexts after genuine v2 QR pairing.
This has not been attributed to the owner's phones.
[RFC-0016](../rfcs/0016-asymmetric-retained-context.md) records why existing signed
QR fields cannot distinguish a retained pair from a new conversation between
original labelled identities. Focused acceptance is RED; no production client
patch, general rejection replay, APK delivery or deployment follows. Existing
symmetric/new-dialog tests are not evidence that the asymmetric case works.
Independent review and disposition of the missing profile signal remain gates.

## Next decision gates

1. Validate and prioritize the initial requirements with the founder.
2. Define assets, adversaries, metadata exposure, recovery, and trust boundaries.
3. Specify identity and nickname lifecycle, including cost and abuse resistance.
4. Compare protocol and implementation strategies, including open-source prior art.
5. Select the first vertical slice and its measurable acceptance criteria.
6. Accept the initial architecture and stack through RFCs and ADRs.

## Update trigger

Update this document whenever a gate is completed, a production capability is
added, a major risk changes, or an accepted decision changes what a newcomer
should believe about the project.
