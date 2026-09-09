---
status: proposed
owner: architecture
decision_owner: martadvix-web
required_reviewers: []
review_mode: closed-alpha-ai
last_reviewed: 2026-09-09
---

# ADR-0010: Retained-stack signed sessions and foreground long-poll

Proposed only. [RFC-0015](../rfcs/0015-overnight-realtime.md) records direct task
scope/provenance and alternatives; [the exact protocol](../protocol/realtime-v1.md)
defines wire authorization, replay, revocation, persistence and resource bounds.
No permanent owner acceptance permalink is available; this record is not accepted.

The proposed bounded private test-data alpha choice is to preserve existing E2EE,
root identity, pinned endpoint, v2 schema and APK signer, adding device-signed
five-minute sessions and bounded long-poll. Public session context never acts as
a bearer token. Full active immutable credential authorization occurs per operation
and final wait query. Terminal revocation remains; future reactivation needs a
durable generation. Legacy v2 remains for same-data code rollback.

This removes per-message challenge round trips and foreground polling delay while
keeping ratchet ownership and durable save-before-publish/receipt discipline.
It does not select the future mature OSS stack, implement multi-server federation,
groups/calls, identity recovery, or guarantee background/physical-phone delivery.

Human risk owner is martadvix-web. Independent fresh-context Fable design and final
implementation reviews, actual tests, source/artifact provenance and narrowly
authorized deployment/rollback verification are required. ADR-0003 permits the
second-human substitution only in this private synthetic-data scope; AI review
is not a human audit or permanent owner acceptance. Production/sensitive-data
expansion requires the canonical independent qualified human review.

Applicable requirements: REQ-ID-004/005/008, REQ-MSG-002/003/004/005,
REQ-SEC-001 and REQ-MULTI-001, plus
[REQ-MSG-006, REQ-CLIENT-004, REQ-MULTI-002, REQ-SERVER-003 and REQ-DEPLOY-002](../product/overnight-realtime.md).
The local server implementation now passes its complete 14-test realtime matrix
and retained server regressions; [the exact evidence](../server/realtime-local.md)
distinguishes those tests from the separately completed final combined-source
review, signed APK and [actual attended rollout](../operations/realtime-rollout-2026-09-09.md).
Hosted product Java/JNI acceptance passed; physical-phone acceptance remains
unrun. No accepted historical decision is rewritten and this ADR remains proposed.

## Current scope provenance and independent design review

The direct current user task requests “execute complete overnight implementation,
real tests, independent Fable security review, signed APK and narrowly authorized
safe existing-service deployment” while retaining hard no-destructive/no-secret/
no-unreviewed-deploy boundaries. The supplied exact owner clarifications are
retained at
`/home/codex/paranoid-self-service-evidence/realtime-architecture-fable-20260909/owner-clarifications.md`;
the adjacent `overnight-implementation.md` defines the precise technical and live
scope. The unique current evidence directory retains copies. No Telegram message
permalink/ID or canonical architecture approval is invented from this task.

Fresh design review and bounded correction closure exist in
`/home/codex/paranoid-self-service-evidence/overnight-realtime-20260909T191524Z`:

- `fable-design-result.json`, successful report session
  `5e915ec4-bd2b-4ee8-8ac4-9cea0e38676c`, SHA256
  `37f00b32313f5eaf5a1feccf22d0a30d4b1d95a9a49c1388a2641836c73b4381`;
- `fable-design-closure.json`, successful bounded closure session
  `2792bfb0-0bb9-40d4-b6bf-823c6cb0c551`, SHA256
  `d3707340110d5c0c94eb35faf229335620730d6e3b2986beffcafedca313e627`.

Both report records identify `claude-fable-5`; their raw modelUsage also records
`claude-haiku-4-5-20251001`, preserved without presenting a sole-model run.
The read-only review found OR-B1 (both TLS deadlines/keep-alive), OR-H1 (idle
database-lock contention) and OR-H2 (native arbitrary-body signing). The amended
contract, native RED evidence and bounded closure address those design conditions;
the exact final code, APK and deployment needed separate independent review.
These reports neither satisfy human decision-owner acceptance nor mark this ADR
accepted; canonical governance and private-alpha exit conditions remain in force.

The later final Fable product/script reviews and bounded closure passed before
the authorized same-data update. The dated rollout records their exact evidence,
preserved artifact/source hashes and hosted result. The original 13 PASS/1 FAIL
packaged sequence and UNKNOWN readiness-failure cause remain visible despite
the successful requested diagnostic; no fix or unattended-rollout assurance is
claimed. Task-specific deployment completion supplies no permanent ADR approval.
