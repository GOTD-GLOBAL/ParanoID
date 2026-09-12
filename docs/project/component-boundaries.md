---
status: draft
owner: maintainers
last_reviewed: 2026-09-09
---

# Component boundaries for implementation and documentation

## Owner direction

Sergey Maltsev requested in the ParanoID Telegram discussion on 2026-09-09:
server and client changes must be preserved in separate pull requests, with
component documentation separated for server, Android and later iOS. The source
message has no stable permalink available in this tool context. This records
workflow/product direction, not acceptance of a new application architecture.

## One-off PR 18 merge direction

The subsequent direct owner instruction explicitly requests testing, fixing and
merging PR #18, followed by voice calls. The [exact scoped record](pr18-merge-scope.md)
supersedes the earlier archival-only/split-before-merge restriction for that PR
only. It preserves component layout, independent review, valid release tests,
historical failure evidence and proposed architecture status. Future work still
uses coherent component boundaries; this is not an unrestricted combined-PR rule.

## Repository layout

Keep the current monorepo; this direction does not request separate repositories.

- `server/`: server source and component entry-point README.
- `clients/core/`: shared client source and entry-point README.
- `clients/android/`: Android application and entry-point README.
- `clients/ios/`: native iOS client (RFC-0019; candidate, not accepted).
- `docs/server/`: server-specific implementation, storage and operational guidance.
- `docs/clients/core/`: shared client state, E2EE integration and migration guidance.
- `docs/clients/android/`: Android UI, build, installation and platform verification.
- `docs/clients/ios/`: iOS documentation (RFC-0019).
- `docs/protocol/` and `docs/api/`: one shared versioned wire-contract source of truth.
- `docs/product/`, `docs/rfcs/`, `docs/decisions/`, `docs/security/` and
  `docs/project/`: shared requirements, decisions, threat boundaries and navigation.

Component READMEs link to canonical details rather than duplicating contracts.
Existing historical operational documents remain linkable; move them only with
corrected references, not as unrelated churn during feature implementation.

## Pull request boundaries

Issue #16 has separate server and Android workstreams. Each PR contains its own
code, tests and component documentation. The shared protocol must have one owner
and an explicit dependency: publish it with the server foundation or a separate
contract PR, then reference that revision from client work. Do not copy competing
wire specifications into component directories.

A dependent client PR must show only client changes relative to its declared base;
server changes appearing as inherited history are not a second server submission.
Review and CI evidence are recorded for each PR. Cross-component integration tests
remain necessary: separate PRs do not prove interoperability. An integration
worktree may combine the reviewed revisions for tests and APK generation, but it
must not become an undifferentiated server-plus-client merge PR.

Current local branches: `feat/self-service-server` and
`feat/self-service-android`. No PR, merge, deployment or completed implementation
is asserted by this organizational document.
