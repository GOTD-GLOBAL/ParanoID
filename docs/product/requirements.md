---
status: draft
owner: product
last_reviewed: 2026-09-09
---

# Initial product requirements

These requirements capture founder intent for discovery. `Confirmed direction`
means the intent is explicit; it does not mean the acceptance criteria or design
are complete.

| ID | Requirement | State |
| --- | --- | --- |
| REQ-ID-001 | Account creation and authentication must not require a phone number or email address. | Confirmed direction |
| REQ-ID-002 | The initial paranoid-mode recovery model must be seed-only; losing the recovery words loses the account. | Confirmed direction |
| REQ-ID-003 | A human-readable username or nickname must be anchored in a blockchain registry. | Confirmed direction |
| REQ-ID-004 | Identity registration must have sustainable cost and abuse controls that do not allow unlimited founder-subsidized registrations. | Confirmed direction |
| REQ-ID-005 | Create identity inside the phone with locally owned keys and automatic proof-of-possession authentication; no end-user SSH, role selection or manually fetched bearer. | Confirmed user correction; technical design proposed |
| REQ-ID-006 | Key possession alone grants no server admission or legacy-slot ownership; bound closed-alpha enrollment must preserve existing identities and history. | Proposed admission/migration constraint |
| REQ-ID-007 | Add contacts through explicitly verified public QR key bindings; enrollment, server trust and contact verification must remain separate. | Confirmed user direction; technical design proposed |
| REQ-ID-008 | Registration on the common default server must be self-service: create ID in the app, add a contact and message without operator approval or a manually transferred admission code. | Confirmed product correction; clean-candidate registration locally tested |
| REQ-MSG-001 | The product must support text, images, files, video, audio, and voice messages. | Draft |
| REQ-MSG-002 | The first slice must deliver 1:1 E2EE text between two OPPO phones through one server, with persistent history, reconnect and no duplicate display. | Confirmed founder direction; technical contract draft |
| REQ-MSG-003 | One check means durable server acceptance; two mean recipient delivery, not reading. | Confirmed founder direction; receipt authentication design draft |
| REQ-MSG-004 | Server history must persist until an additional explicit deletion request; no automatic expiry or delivery-triggered deletion. | Confirmed founder direction; deletion authority and backup policy draft |
| REQ-MSG-005 | A sender knowing a genuine public recipient contact can send first-contact E2EE text that immediately appears as a normal unverified-identity conversation on a recipient with zero contacts, with reply enabled and no recipient scan/approval; identity verification is a separate optional same-key trust upgrade. | Confirmed user correction; implementation and crypto design not accepted |
| REQ-CALL-001 | The product must support real-time audio and video communication. | Draft |
| REQ-CLIENT-001 | Supported end-user clients must include Android and iOS. | Confirmed direction |
| REQ-DEPLOY-001 | A non-specialist must be able to deploy a server through a guided, near one-click flow. | Confirmed direction |
| REQ-NET-001 | A server and its clients must support useful operation inside a local network without public internet. | Confirmed direction |
| REQ-FED-001 | Independently operated servers must be able to federate under explicit administrator policy. | Confirmed direction |
| REQ-SERVER-001 | Offer the common project server by default, with explicit alternatives to create/self-host a server or join a known existing server; the default must not become permanent central authority. | Confirmed future product direction; not an alpha gate |
| REQ-SERVER-002 | Support server-selection/admission invitations by QR or link, distinct from verified contact pairing; server trust and admission remain explicit. | Confirmed future product direction; design unimplemented |
| REQ-CLIENT-002 | When a server invite opens without the app, guide the user to Google Play/App Store and back to the invitation after installation; provide a reopen-original-invite fallback. | Confirmed future product direction; platform behavior unverified |
| REQ-CLIENT-003 | Provide a user-triggered in-app update button to download a verified same-signer newer APK and invoke the native Android installer without erasing application identity or data. | Confirmed user direction; implementation/review pending |
| REQ-MULTI-001 | A user must be able to connect to or participate through more than one server without creating an incoherent identity model. | Draft |
| REQ-EXT-001 | The platform must support modular extensions with explicit permissions and isolation. | Confirmed direction |
| REQ-ENT-001 | The commercial platform must support configurable enterprise messaging and CRM workflows. | Confirmed direction |
| REQ-AI-001 | AI capabilities must be optional, permissioned, and capable of using self-hosted inference in future deployments. | Draft |
| REQ-SEC-001 | End-to-end encryption scope and metadata guarantees must be specified and verified before any production privacy claim. | Required discovery gate |

## User-triggered Android update direction (2026-09-09)

Sergey requests downloading later versions by pressing Update in the app instead
of receiving every APK through Telegram. [RFC-0013](../rfcs/0013-user-triggered-android-updates.md)
and draft ADR-0008 record the proposed distribution/signature/URI trust boundaries.
The first APK containing Update still needs one external in-place installation.
Native Android confirmation remains required; no silent install, new signer,
uninstall, data clear, downgrade or changed TLS trust is authorized. User reports
both phones still run the operator-registration version; screenshot corroborates
that UI, not exact installed binary identity. This is product provenance, not a
fabricated permanent architecture or public-release approval.

## First-slice clarification

Founder input is recorded in [RFC-0006](../rfcs/0006-single-server-text-contract.md).
One server and Android first do not remove future iPhone or multi-server support.
Multiple servers are a later milestone, not a gate for this slice.
Technical recommendations are delegated to the assistant; protected decisions
still require human disposition. The source Telegram permalink is unavailable
to this tool context, so approval evidence requires owner GitHub confirmation.
The [acceptance matrix](../protocol/server-v0-acceptance.md) is proposed and unrun.

## Registration correction for the private alpha

The 2026-09-08 user correction rejects manual bearer onboarding in favor of the
earlier Threema-inspired UX. [RFC-0010](../rfcs/0010-phone-key-registration.md)
records the supplied provenance, minimal change and REG-01–REG-06 acceptance
mapping; [ADR-0006](../decisions/0006-phone-key-registration.md) is proposed only.
This does not accept Threema protocols or public anonymous registration. REQ-ID-003
is later blockchain naming scope, not an alpha enrollment dependency; REQ-ID-002
recovery intent is unchanged and not implemented by adding local root/auth keys.
The local 0.0.4-dev candidate replaces the token UI with key creation and automatic
proof. The [local evidence](../operations/key-registration-local.md) is not physical
OPPO acceptance, production adoption or permission to migrate the hosted endpoint.

## Server onboarding direction (future production UX)

In the supplied 2026-09-08 Telegram follow-up, Sergey says “Пока что пойдет”
(“This will do for now”) about Create ID -> one-time operator approval -> messaging.
This is bounded alpha UX approval, not approval of the current manual-token UI,
ADR-0006 acceptance, public signup or deployment. Provenance and exact limits are
in [RFC-0010](../rfcs/0010-phone-key-registration.md#follow-up-product-input).

REQ-SERVER-001/002 and REQ-CLIENT-002 preserve the future direction now; they do not
request its implementation in this alpha. Each server retains independent trust
and admission policy; changing selection must not reset identity/history, silently
replace saved trust or require the default server to authorize independent use.
A server invite is not a verified contact QR or an authentication bypass. No secret
grant belongs in an app/store URL. Installation is user/platform mediated, never
silent; deferred deep-link continuation depends on the platform and is unverified.
If continuation fails, reopen the original invite after installation and revalidate
server trust/admission. Simultaneous multi-server use (REQ-MULTI-001), iOS and store
publishing remain later scope, not gates for the current two-OPPO alpha.

## Default-server self-registration correction (2026-09-09)

Sergey explicitly rejects the operator-approval/manual-grant onboarding as the
product path. The requested application flow is local ID creation, automatic
registration on the common server by default, adding a contact and immediate
messaging without an operator, manually transferred admission code or SSH step.
This supersedes the earlier temporary acceptance of an operator gate as product
UX; it does not erase that implementation or its historical rollout authority.

Blockchain registration remains a later separate operation, followed by use of
the common public server or an independently operated private server. Continuity
of identities, contacts and history is retained as a requirement. This is product
intent, not acceptance of a particular chain, directory, wire protocol, recovery
mechanism or unrestricted resource use. Technical admission/abuse controls and
migration from fixed legacy slots require a scoped RFC/ADR before implementation.

The historical operator-grant implementation did not satisfy this new onboarding
requirement. The owner subsequently approved an archival checkpoint,
a separate workstream and [issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16).
[The product brief](self-service-messenger.md) mirrors the requested app/server
flow and its acceptance criteria. Preservation and issue creation do not implement
self-service registration, authorize a merge or change live admission policy.

## One-time old-server-database discard correction (2026-09-09)

Sergey explicitly requests a new database in place of the old disposable ParanoID
server DB and no preservation/archive/pre-cutover backup. This is the additional
explicit REQ-MSG-004 deletion request for that old server cluster, not permission
to evict later v2 messages or erase phones/TLS. The [scoped operational record](../operations/fresh-self-service-v2.md#scope-correction-and-provenance)
retains supplied task provenance and the exact boundary without inventing a
permanent architecture approval. Legacy server migration is not this cutover gate;
client keys/history/signing identity and all neighboring services stay protected.
Current task permits local preparation only; coordinator review precedes cutover.

## First-contact incoming correction (2026-09-09)

REQ-MSG-005 removes reciprocal-contact approval from receiving and replying:
a sender with a genuine public recipient ContactV2 QR can send E2EE text to a
recipient with zero contacts. The recipient immediately sees plaintext in a
normal conversation and can reply, with `network_unverified` identity trust.
Optional same-key QR verification upgrades trust only. REQ-ID-007 remains the
out-of-band verification requirement, not a prerequisite for incoming plaintext.
No public directory, blockchain, label heuristic or plaintext fallback is needed.

The earlier owner instruction “Переделай так, что бы не нужно было второму
абоненту добавлять контакт” established that product correction. The subsequent
current **2026-09-09 Telegram implementation task** reports the owner approval
as quoted below; the earlier exact approval message/permalink was not
independently retrieved in this context:

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

The exact new wire/state contract is in [RFC-0014](../rfcs/0014-first-contact-incoming.md)
and [the first-contact protocol](../protocol/first-contact-v1.md). Every new text
and receipt requires frame 2, signed `paranoid-sender-intro-v2`, deterministic
account-sorted `account-id-intro-v1` channel and strict encrypted PlainV1 context.
One retained Olm Account, immutable sender/recipient bindings, full-state reject
rollback, durable immutable outbox before network, real authenticated receipts,
replay/sequence conflict checks, 16 unverified/64 total peers and existing budgets
remain required. Signature validation by itself is not receive acceptance.

Clean registration/reopen, first-contact text/reply/receipts, crossing sends,
forgery/stripping/wrong-inner rejection, duplicate reload, capacity rollback and
block behavior must be tested against real core/JNI and local server transport.
Candidate implementation and actual test/build outcomes belong in current-state
and the local evidence record; this requirement does not claim completion.

## Overnight scoped amendment (2026-09-09)

[The current overnight requirements](overnight-realtime.md) add REQ-MSG-006,
REQ-CLIENT-004, REQ-MULTI-002, REQ-SERVER-003 and REQ-DEPLOY-002 with exact
authority, in-place v7 continuity, latency/UI and safe-deployment gates.

## Acceptance criteria backlog

The [post-PR18 voice scope](voice-calls.md) adds REQ-CALL-002/003/004/005 with
real audio, immutable E2EE signaling, explicit consent/lifecycle and bounded
network/resource acceptance. It is a local implementation task, not a claim of
implemented calls, approved public TURN or permanent architecture acceptance.

Each requirement must gain measurable acceptance criteria before implementation.
The first pass must define at least:

- supported offline and degraded-network scenarios;
- message delivery, ordering, synchronization, and retention semantics;
- device addition, loss, revocation, and seed recovery behavior;
- username uniqueness, registration, transfer, renewal, and dispute rules;
- federation discovery, authorization, abuse handling, and compatibility;
- plugin capability boundaries and user/admin consent;
- measurable self-hosting time, upgrade safety, backup, and restore objectives;
- mobile performance, accessibility, battery, and bandwidth targets.
