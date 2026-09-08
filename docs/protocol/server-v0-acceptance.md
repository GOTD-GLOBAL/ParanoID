---
status: draft
owner: protocol
last_reviewed: 2026-09-08
---

# Single-server text acceptance matrix

This is a proposed executable-contract checklist for
[RFC-0006](../rfcs/0006-single-server-text-contract.md), not implemented behavior
or a normative API. Full end-to-end rows remain NOT RUN. The
[local deployment evidence](../operations/linux-alpha-verification.md) provides
a bounded envelope/sequence backup-restore subset of V0-14, not full phone
receipt-state or disaster-recovery acceptance. Use synthetic accounts and
unique plaintext markers; never include real seed material in evidence.

| ID | Requirement | Experiment and required result |
| --- | --- | --- |
| V0-01 | REQ-MSG-001, REQ-SEC-001 | Send 50 messages each way between two real OPPO phones. All decrypt once; DB and service logs contain no known plaintext marker or content key. Inspection alone is not a proof of complete E2EE security. |
| V0-02 | REQ-MSG-002 | Drop the acceptance response after DB commit. Retry exact bytes/ID, including concurrently. One server row, original sequence, one client message and one check only after confirmed acceptance. |
| V0-03 | REQ-MSG-002 | Reuse the ID with changed bytes or routing context. Explicit conflict, no overwrite or second event. |
| V0-04 | REQ-MSG-003 | Keep recipient offline. Sender gets one check, never two. Reconnect and commit validated recipient history; only a verified recipient receipt produces two checks. |
| V0-05 | REQ-MSG-003, REQ-SEC-001 | Inject server-forged receipt, wrong sender, wrong room, changed message ID and repeated receipt. No false delivery, duplicate UI entry or receipt loop. |
| V0-06 | REQ-MSG-002 | Queue 20 messages while recipient is offline. Kill/reopen sender and recipient, reconnect repeatedly. All delivered once and ordered by server sequence. |
| V0-07 | REQ-MSG-002 | Kill server before commit, after commit/before response, and during concurrent sequence allocation. No lost acknowledged message or cursor skipping an earlier delayed commit. |
| V0-08 | REQ-MSG-002, REQ-SEC-001 | Inject client crashes around outbox/ratchet and inbox/ratchet/cursor/receipt commits. Restart recovers one complete state, retries exact bytes, never reuses an advanced ratchet incorrectly. |
| V0-09 | REQ-ID-001, REQ-SEC-001 | Unknown device, expired/replayed challenge or invitation, wrong server/room, revoked session and peer key substitution all fail closed. No phone/email dependency. |
| V0-10 | REQ-MSG-004 | Deliver, acknowledge, disconnect, logout and restart. Ciphertext remains. Fill quota: new send fails visibly, old history survives and no automatic TTL job deletes it. |
| V0-11 | REQ-ID-002, REQ-MSG-004 | Lose client history key in synthetic account. Old server ciphertext remains; UI says unavailable, no fake plaintext recovery or silent identity reset. Seed recovery and peer reverification are independently tested before enabling recovery. |
| V0-12 | REQ-CLIENT-001, REQ-NET-001 | Both OPPO phones exchange on LAN without RPC, then Wi-Fi/mobile-data reconnect on authorized hosted endpoint. Reopening a killed app catches up; no untested background delivery guarantee. |
| V0-13 | REQ-CLIENT-001, REQ-MULTI-001 | Shared core has no Android/server-only dependency; versioned fixtures specify platform-neutral bytes and server-scoped local keys/cursors. iOS simulator/device tests are a later milestone, not falsely marked passed on Linux. |
| V0-14 | REQ-DEPLOY-001, REQ-MSG-004 | Isolated backup/restore verifies retained envelopes, IDs, receipt state and sequence. Report data lost since backup explicitly. Never equate restart durability with zero-RPO disaster recovery. |
| V0-15 | REQ-SEC-001 | Corrupt ciphertext and reorder/replay events. Do not emit delivery receipt, corrupt ratchet state or permanently prevent sync of unrelated valid messages. |

## Required evidence

Record exact revision, commands, environment, observed failure before behavior
implementation, passing regression output, and limitations in each implementation
PR. Never replace a failed phone or network run with simulated screenshots.
Real device evidence must distinguish local synthetic self-test from two phones
exchanging messages through a server. One successful online send is not completion.

No application implementation is authorized by this checklist. Refer to the
[governance policy](../governance/documentation-policy.md) for disposition.
