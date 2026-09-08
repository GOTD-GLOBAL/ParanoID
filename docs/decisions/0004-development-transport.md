---
status: draft
owner: development
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-08
---

# ADR-0004: Development transport increment (not adopted)

## Context and proposed decision

Implement and exercise a bounded loopback-only Rust/Axum/PostgreSQL transport in
the feature branch under the founder's direct request to start coding send/receive.
[RFC-0008](../rfcs/0008-executable-text-development-slice.md) precedes this work.
Retain ciphertext, fixture-device isolation, stable IDs, commit-before-ACK and
cursor sync. RFC-0006 remains the full-alpha target, not implemented behavior.

The later [RFC-0009](../rfcs/0009-isolated-linux-alpha-package.md) and
[draft ADR-0005](0005-isolated-linux-alpha-package.md) add explicit alpha TLS and
packaging under the owner’s bounded PR #14 authorization. This historical initial
transport proposal remains draft; no production acceptance is inferred.

## Alternatives and consequences

Mocks cannot test database durability. Exposing unfinished client authentication
would risk the existing host and misrepresent progress. Real local PostgreSQL and
HTTP tests supply executable evidence while phone clients and hosted installation
are completed separately. Bearer credentials are disposable test admission, not
the proposed root/device challenge or recovery model. vodozemac is test-only;
server runtime never receives content keys. No public compatibility promise.

## Validation, security and disposition

[Server README](../../server/README.md) records configuration, bounds and actual
checks. [Threat analysis](../security/server-v0-threats.md) retains the full target
and distinguishes this development increment. REQ-MSG-002/004 and REQ-SEC-001 drive
transaction, retry, isolation and error tests. No runtime/host deployment occurred.

Decision owner: martadvix-web. This record remains draft; no approval permalink or
production architecture acceptance is invented from a general request to proceed.
Independent AI code-review findings and resolutions belong in the PR. Exact owner
scope/architecture disposition, full client E2EE and bounded deployment permission
remain necessary before adoption/hosted phone use. Documentation publication and
implementation review are not full-alpha acceptance.
