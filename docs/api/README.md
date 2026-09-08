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

When APIs are introduced:

- keep the machine-readable contract canonical;
- use OpenAPI for applicable HTTP APIs and an explicit schema format for events;
- generate human reference from the contract where practical;
- document authentication, authorization, pagination, idempotency, limits,
  errors, privacy, and examples;
- test implementation conformance in CI;
- declare versioning, deprecation, compatibility, migration, and rollback policy;
- separate internal implementation APIs from supported public contracts.
