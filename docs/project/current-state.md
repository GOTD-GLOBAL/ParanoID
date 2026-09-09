---
status: accepted
owner: maintainers
last_reviewed: 2026-09-09
---

# Current project state

## Current product priority

The active workstream is [issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16)
and its [English product brief](../product/self-service-messenger.md). The
`feat/self-service-registration` branch starts from the preserved archive; no
self-service runtime change has been implemented or deployed by this setup task.

The owner rejected operator-dependent onboarding and approved preserving the
current implementation in an [archival checkpoint](operator-approval-checkpoint.md),
without merging it wholesale into main. The next deliverable is the self-service
app/server flow in [REQ-ID-008](../product/requirements.md#default-server-self-registration-correction-2026-09-09):
create ID, automatically register on the common server, add a contact, message.
It is not implemented by the current operator-grant code. Blockchain registration
and public/private server choice remain the later direction, with identity and
history continuity required. No new runtime or hosting change follows merely
from the archive/issue task. Historical implementation/rollout observations below
remain evidence, not the target user experience.

## Phase

**Inception and architecture discovery.** This repository is a clean reboot. It
contains documentation, Android diagnostics and a development transport
increment, but no usable messenger or accepted production architecture.

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
