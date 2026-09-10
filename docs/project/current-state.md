---
status: accepted
owner: maintainers
last_reviewed: 2026-09-10
---

# Current project state

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
