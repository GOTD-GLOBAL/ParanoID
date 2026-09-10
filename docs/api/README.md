---
status: draft
owner: api
last_reviewed: 2026-08-09
---

# API documentation

No public API has been accepted. The [development transport](../../server/README.md)
implements bounded development HTTP and an explicit TLS-only closed-alpha mode
(see the [deployment runbook](../operations/linux-alpha-deployment.md)); it is not a
public compatibility contract.

[Key enrollment v1](../protocol/key-enrollment-v1.md) describes the proposed
RFC-0010 route/auth boundaries and the exact local candidate schemas. The shared
strict Rust types and public canonical signature vectors accompany the implemented
routes; no production API or new hosted capability is accepted by the local build.

[Self-service v2](../protocol/self-service-v2.md) is the draft RFC-0012 contract
for the implemented local server: registration/auth challenges and commits, status,
and GET/POST messages. No v0/v1 message routes or bearer fallback exist in its
router. [ADR-0007](../decisions/0007-self-service-messenger.md) and the
[threat/test matrix](../security/self-service-v2-threats.md) remain draft; no public
API acceptance or hosted v2 change is inferred from local verification.

The [clean first-contact channel](../protocol/first-contact-v1.md) changes only
opaque client ciphertext. V2 request-proof, POST/GET schemas, sender derivation,
recipient filtering and exact retry idempotency remain unchanged. No sender
lookup, recovery route, new live endpoint or server schema is introduced by this
client candidate; exact retained-bundle compatibility is checked locally.

When APIs are introduced:

- keep the machine-readable contract canonical;
- use OpenAPI for applicable HTTP APIs and an explicit schema format for events;
- generate human reference from the contract where practical;
- document authentication, authorization, pagination, idempotency, limits,
  errors, privacy, and examples;
- test implementation conformance in CI;
- declare versioning, deprecation, compatibility, migration, and rollback policy;
- separate internal implementation APIs from supported public contracts.

## Overnight realtime candidate

[Signed sessions and long-poll](../protocol/realtime-v1.md) records the current private-alpha scope and its exact review/test gates.
No permanent architecture acceptance or physical-phone result is implied.

## Optional voice relay issuer

[Voice TURN v1](../protocol/voice-turn-v1.md) defines GET `/v2/voice/turn`, its
existing signed-session authorization, limits and exact response. Disabled mode
returns authenticated404; other message/session contracts remain unchanged.
