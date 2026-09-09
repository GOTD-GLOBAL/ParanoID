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
| REQ-ID-008 | Registration on the common default server must be self-service: create ID in the app, add a contact and message without operator approval or a manually transferred admission code. | Confirmed product correction; not implemented |
| REQ-MSG-001 | The product must support text, images, files, video, audio, and voice messages. | Draft |
| REQ-MSG-002 | The first slice must deliver 1:1 E2EE text between two OPPO phones through one server, with persistent history, reconnect and no duplicate display. | Confirmed founder direction; technical contract draft |
| REQ-MSG-003 | One check means durable server acceptance; two mean recipient delivery, not reading. | Confirmed founder direction; receipt authentication design draft |
| REQ-MSG-004 | Server history must persist until an additional explicit deletion request; no automatic expiry or delivery-triggered deletion. | Confirmed founder direction; deletion authority and backup policy draft |
| REQ-CALL-001 | The product must support real-time audio and video communication. | Draft |
| REQ-CLIENT-001 | Supported end-user clients must include Android and iOS. | Confirmed direction |
| REQ-DEPLOY-001 | A non-specialist must be able to deploy a server through a guided, near one-click flow. | Confirmed direction |
| REQ-NET-001 | A server and its clients must support useful operation inside a local network without public internet. | Confirmed direction |
| REQ-FED-001 | Independently operated servers must be able to federate under explicit administrator policy. | Confirmed direction |
| REQ-SERVER-001 | Offer the common project server by default, with explicit alternatives to create/self-host a server or join a known existing server; the default must not become permanent central authority. | Confirmed future product direction; not an alpha gate |
| REQ-SERVER-002 | Support server-selection/admission invitations by QR or link, distinct from verified contact pairing; server trust and admission remain explicit. | Confirmed future product direction; design unimplemented |
| REQ-CLIENT-002 | When a server invite opens without the app, guide the user to Google Play/App Store and back to the invitation after installation; provide a reopen-original-invite fallback. | Confirmed future product direction; platform behavior unverified |
| REQ-MULTI-001 | A user must be able to connect to or participate through more than one server without creating an incoherent identity model. | Draft |
| REQ-EXT-001 | The platform must support modular extensions with explicit permissions and isolation. | Confirmed direction |
| REQ-ENT-001 | The commercial platform must support configurable enterprise messaging and CRM workflows. | Confirmed direction |
| REQ-AI-001 | AI capabilities must be optional, permissioned, and capable of using self-hosted inference in future deployments. | Draft |
| REQ-SEC-001 | End-to-end encryption scope and metadata guarantees must be specified and verified before any production privacy claim. | Required discovery gate |

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

The currently deployed operator-grant implementation does NOT satisfy this new
onboarding requirement. The owner subsequently approved an archival checkpoint,
a separate workstream and [issue #16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16).
[The product brief](self-service-messenger.md) mirrors the requested app/server
flow and its acceptance criteria. Preservation and issue creation do not implement
self-service registration, authorize a merge or change live admission policy.

## Acceptance criteria backlog

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
