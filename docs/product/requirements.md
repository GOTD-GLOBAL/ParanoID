---
status: draft
owner: product
last_reviewed: 2026-09-07
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
| REQ-MSG-001 | The product must support text, images, files, video, audio, and voice messages. | Draft |
| REQ-CALL-001 | The product must support real-time audio and video communication. | Draft |
| REQ-CLIENT-001 | Supported end-user clients must include Android and iOS. | Confirmed direction |
| REQ-DEPLOY-001 | A non-specialist must be able to deploy a server through a guided, near one-click flow. | Confirmed direction |
| REQ-NET-001 | A server and its clients must support useful operation inside a local network without public internet. | Confirmed direction |
| REQ-FED-001 | Independently operated servers must be able to federate under explicit administrator policy. | Confirmed direction |
| REQ-MULTI-001 | A user must be able to connect to or participate through more than one server without creating an incoherent identity model. | Draft |
| REQ-EXT-001 | The platform must support modular extensions with explicit permissions and isolation. | Confirmed direction |
| REQ-ENT-001 | The commercial platform must support configurable enterprise messaging and CRM workflows. | Confirmed direction |
| REQ-AI-001 | AI capabilities must be optional, permissioned, and capable of using self-hosted inference in future deployments. | Draft |
| REQ-AI-002 | Project groups should support optional AI-agent automation; agent admission, data access, tool permissions and isolation require explicit design and consent. | Confirmed direction |
| REQ-SEC-001 | End-to-end encryption scope and metadata guarantees must be specified and verified before any production privacy claim. | Required discovery gate |

REQ-AI-002 is a future product direction; acceptance criteria and agent access
contracts remain pending. It does not authorize reading encrypted groups.

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
