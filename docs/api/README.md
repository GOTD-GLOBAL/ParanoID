---
status: draft
owner: api
last_reviewed: 2026-08-11
---

# API documentation

No public API has been accepted.

Candidate registration and signed-challenge operations are described
non-normatively in
[RFC-0002](../rfcs/0002-identity-registration-authentication.md). Machine-readable
contracts do not exist yet.

When APIs are introduced:

- keep the machine-readable contract canonical;
- use OpenAPI for applicable HTTP APIs and an explicit schema format for events;
- generate human reference from the contract where practical;
- document authentication, authorization, pagination, idempotency, limits,
  errors, privacy, and examples;
- test implementation conformance in CI;
- declare versioning, deprecation, compatibility, migration, and rollback policy;
- separate internal implementation APIs from supported public contracts.
