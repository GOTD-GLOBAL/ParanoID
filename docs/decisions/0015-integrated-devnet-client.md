---
status: proposed
owner: identity
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-22
---

# ADR-0015: Integrated Devnet registration candidate

## Context and proposal

The owner requests one ParanoID APK supporting its existing messaging/calls and
registration of a nickname in the deployed Solana Devnet registry. A separate
registrar is not the deliverable. Follow the integrated amendment in
[RFC-0026](../rfcs/0026-solana-devnet-registration.md).

Preserve `global.paranoid.messenger`, its signer, messenger identity and E2EE.
Add an internal screen and domain-separated Devnet key/store; never equate the
registered name with verified messenger contact/route/server authority. No
Mainnet, migration/wipe, recovery of chat history or public release is implied.

## Alternatives and consequences

A standalone APK is rejected by the owner. Immediate blockchain-only server
login is deferred because it changes identity/admission/recovery boundaries.
A same-app registration screen exercises the real registry without inventing
that binding. Devnet reset, RPC trust, seed loss and program upgrades remain risks.

## Acceptance and review

REQ-ID-001..005, REQ-CLIENT-001 and REQ-SEC-001 apply. Preserve documented
chat/call/update invariants. Verify pending retries, durable writes and recovery,
actual chain records, main APK/signature contents and independent code/artifact
review. No human approval evidence for accepting this ADR has been recorded;
status remains proposed. Private test delivery requires the bounded owner scope.
