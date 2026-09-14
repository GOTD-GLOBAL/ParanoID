---
status: accepted
owner: maintainers
decision_owner: martadvix-web
approved_change: RFC/ADR lifecycle, decision authority, durable evidence, and protected-domain review governance
approval_date: 2026-08-17
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/4
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/4#issuecomment-5311797500
last_reviewed: 2026-08-15
---

# Documentation map

This is the entry point and navigation contract for ParanoID documentation.

## Project and product

- [Current state](project/current-state.md): what exists now, what does not, and
  the next decision gates.
- [Clean first-contact candidate](operations/clean-first-contact-local.md): local
  test/build evidence, exact signed channel, clean-install scope and review gate.
- [Vision](product/vision.md): intended users, value, and product boundaries.
- [Requirements](product/requirements.md): traceable product requirements and
  open acceptance criteria.
- [Self-service messenger target](product/self-service-messenger.md): application/server
  acceptance scope for issue #16, not a completed implementation.
- [Glossary](product/glossary.md): canonical project vocabulary.

## Architecture and decisions

- [Architecture map](architecture/README.md): C4 views and architecture scope.
- [Architecture principles](architecture/principles.md): constraints that guide
  design work.
- [Quality attributes](architecture/quality-attributes.md): measurable scenarios
  used to compare designs.
- [Decision log](decisions/README.md): accepted, draft/proposed and historical ADRs.
- [Self-service v2 decision draft](decisions/0007-self-service-messenger.md):
  RFC-0012 server candidate, not accepted application architecture.
- [RFC process](rfcs/README.md): proposals under discussion.
- [User-triggered Android updates](rfcs/0013-user-triggered-android-updates.md) and
  [draft ADR-0008](decisions/0008-user-triggered-android-updates.md): Update button
  with pinned distribution/signer checks and native installation consent; in progress.

## Contracts and operations

- [Voice scope](product/voice-calls.md), [wire contract](protocol/voice-v1.md),
  [threat/test mapping](security/voice-v1-threats.md) and
  [local evidence](operations/voice-calls-local.md): implemented controls and
  Android adapter; design/native/JNI/controller and actual direct/isolated-relay
  audio checks pass. Full app acceptance passes 14 steps; final inset UI and signed APK checks pass, with final review pending. [Durable reviews/results](project/evidence/voice-calls-20260909/README.md)
  distinguish each gate; [core](clients/core/voice-calls.md) and
  [Android](clients/android/voice-calls.md) document their component boundaries.

- [Protocol documentation](protocol/README.md): wire formats, state machines,
  federation, and compatibility.
- [API documentation](api/README.md): machine-readable and human-readable APIs.
- [Fresh-only v2 deployment candidate](operations/fresh-self-service-v2.md): explicit
  exact-IP mode and scoped old-server-DB discard without backup; the
  [actual authorized rollout](operations/self-service-v2-rollout-2026-09-09.md)
  records installed v2, retained boundaries and verified live readiness.
- [Operations](operations/README.md): deployment, upgrades, backups, observability,
  incidents, and recovery.
- [Threat model](security/threat-model.md): assets, actors, boundaries, and threats.
- [Self-service v2 contract](protocol/self-service-v2.md),
  [server-local evidence/runbook](server/self-service-local.md) and
  [threat delta/test mapping](security/self-service-v2-threats.md): locally verified
  server behavior; client, physical phones and deployment remain separate gates.

## Documentation by reader need

As content grows, classify developer, administrator, and user documentation using
the Diataxis model:

- `tutorials/` for guided learning;
- `how-to/` for task-oriented instructions;
- `reference/` for exact facts and contracts;
- `explanation/` for concepts and trade-offs.

Do not mix these purposes in a single document without a clear reason.

## Governance

- [Documentation policy](governance/documentation-policy.md)
- [External standards and methods](references.md)
- [Contributing rules](../CONTRIBUTING.md)
- [AI agent rules](../AGENTS.md)
- [Security policy](../SECURITY.md)

## Status vocabulary

Every durable design or governance document should include metadata:

- `draft`: incomplete and non-normative;
- `proposed`: ready for decision or review;
- `accepted`: normative until superseded; reserved for artifacts that are sources
  of truth, including ADRs, requirements, policies, and specifications;
- `deprecated`: retained for context but should not guide new work;
- `superseded`: replaced by a linked document.

Proposal processes may also use terminal, non-normative states:

- `completed`: review concluded and any accepted decision is recorded elsewhere;
- `rejected`: reviewed but not selected, with the reason preserved;
- `withdrawn`: closed by the author without a decision.

An RFC never uses `accepted`: even a completed RFC remains proposal history. Only
a linked accepted ADR makes an architecture decision normative. Artifact-specific
process documents define which subset of this vocabulary is valid.

`last_reviewed` describes when the document was checked against reality, not when
its spelling was last edited.

## Overnight realtime implementation and rollout

[Overnight realtime scope](product/overnight-realtime.md) records the private-alpha
requirements. The [dated actual rollout](operations/realtime-rollout-2026-09-09.md)
records signed artifacts, completed independent review/closure, preserved
existing-service update and hosted product Java/JNI acceptance. The
[runbook](operations/overnight-realtime.md) retains recovery, test and risk boundaries.
No permanent architecture acceptance or physical-phone result is implied.

## Local voice relay foundation

[REQ-CALL-006](product/voice-relay.md), [canonical issuer contract](protocol/voice-turn-v1.md),
[threat delta](security/voice-turn-threats.md) and [server checks](server/voice-turn-local.md)
cover the default-disabled issuer and offline relay package for issue 19.
Android integration is a dependent client PR. Retained-allocation expiry and ACL
packet tests are NOT RUN; no deployment or permanent decision approval is implied.

## One-host voice delivery

[Exact owner authority and REQ-DEPLOY-003](operations/voice-single-host.md) track
one unified installer on the existing host, preserved state and mandatory missing
runtime/review gates. No relay deployment has occurred.

## iOS client candidate

[RFC-0021](rfcs/0021-ios-client.md) and [proposed ADR-0014](decisions/0014-ios-client.md)
propose a native iOS client on the unchanged shared core for REQ-CLIENT-001.
The [iOS component documentation](clients/ios/README.md) records the intended
differences from Android, the [requirement-to-test mapping](clients/ios/verification.md)
(rows `CLAIMED` on simulators, the host or the local stand; rows `SHOWN` on a
physical iPhone against the local stand since 2026-09-13; the joint tests with
the owner partly run, their covered rows `SHOWN (joint, reported)` and the rest
`NOT RUN`), the
[rule-to-source table](clients/ios/protocol-sources.md)
used to write behaviour from the protocol documents and the core, and the
[device evidence](project/evidence/ios-client-20260913/README.md). A signed
build ran on an iPhone 16 Pro Max on 2026-09-13; two hosted accounts exist
(one from the build Mac, one from the phone, both under the owner's answer to
RFC-0021 question 4, no fixed budget), and the phone sent one text to the
owner's Android that the hosted server accepted. On 2026-09-14 an unscheduled
session with the owner carried text both ways and one call he placed to the
iPhone, with both cameras on, reported by the contributor and not captured. No
TestFlight build, completed joint owner test, owner "go" permalink for that
session or architecture acceptance is implied.
