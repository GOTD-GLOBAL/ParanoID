---
status: draft
owner: security
last_reviewed: 2026-09-08
---

# Single-server text threat-model delta

Companion to the [base threat model](threat-model.md) and
[RFC-0006](../rfcs/0006-single-server-text-contract.md). Recommendations below
are unimplemented. Residual-risk triage owner is martadvix-web until an independent
qualified human reviewer is assigned. This is not a completed security review.

## Assets and data flow

```text
Root seed, device keys, ratchet state and encrypted local history
  remain inside Android client A or client B (future iOS has the same boundary).
Client A -- TLS / authenticated ciphertext --> server access + delivery
Server -- transaction --> PostgreSQL envelopes, sequence, dedup and receipt events
Server -- TLS / ciphertext sync --> client B
Client B -- authenticated receipt after local commit --> server --> client A
PostgreSQL -- controlled backup --> private operator storage
```

Trust boundaries: client OS/secure storage; client/server; server/database/backup;
peer credential verification; future mobile FFI. The operator can inspect routing,
IPs, sizes, timing and relationship metadata. E2EE does not hide them or guarantee
availability. OS/root compromise can expose content at endpoints.

## Threats and enforcement proposals

| Threat | Initial risk | Mitigation proposal | Verification |
| --- | --- | --- | --- |
| Server substitutes peer key or invents delivery receipt | High | Out-of-band root verification, authenticated prekeys/device credential and peer-authenticated receipts | V0-05, V0-09 |
| Attacker replays challenge, invite or cross-room request | High | Atomic one-use challenges/invitations with recipient, server, expiry and authority binding; device/room authorization | V0-09 |
| Crash advances ratchet but loses message or cursor | High | Transactional local outbox/inbox/ratchet/cursor state; exact encrypted-byte retries | V0-08 |
| Lost response or racing commits duplicate/skip history | High | Unique logical IDs, conflict detection and serialized per-room commit sequence | V0-02, V0-03, V0-07 |
| Replay attacks ratchet receiver or corrupt event stalls sync | High | Inbox dedup before decryption; explicit invalid-event handling without receipt | V0-08, V0-15 |
| Operator/log/backup receives keys or plaintext | High | Client-only content keys, no sensitive payload logs, ciphertext-only server history | V0-01 plus code/data-flow review |
| Retention exhausts storage or hides deletion | High | Quotas reject new writes, no acknowledged history eviction; explicit deletion authority/tombstones before deletion API | V0-10 |
| Lost local key makes retained ciphertext unreadable | High | Explicit irrecoverability warning; root recovery separated from history; no escrow or deterministic ratchet rewind | V0-11 |
| Stale restore resurrects deleted data or forgets dedup/receipts | High | Restore consistency checks, deletion ledger policy before deletion feature, explicit RPO | V0-14 |
| Native boundary or platform backup leaks keys | High | Minimal separate JNI/C adapters, redacted errors, platform-protected local key and backup exclusions | Mobile security review; Android/iOS evidence separately |
| Existing hosting services harmed by alpha deployment | High | Explicit bounded authorization, isolated service identity/volumes/resources, inspected rollback | Deployment runbook gate |

## Executable development transport boundary

The `server/` increment uses two disposable bearer credentials, loopback binding
and a private development DB. It is not root/device admission or peer verification.
Test fixture crypto keys are trusted inside one test process. Payload/row/body/page
bounds and static error redaction are implemented; ingress rate limits, full
client state and public TLS remain gates before network exposure. A reverse proxy
must not bypass the development-only boundary. See the server README for the
explicitly opted-in disposable CI database exception.

## Residual limits

The malicious server can drop/delay messages, lie about its own commit, withhold
history or correlate traffic. Recipient-authenticated receipts reduce false
peer-delivery claims but do not attest a compromised peer's behavior. Deletion
cannot erase recipient copies. Seed recovery does not reconstruct forward-secret
ratchet history. Local plaintext markers not appearing in a DB dump is limited
evidence, not a cryptographic proof. iOS secure storage and bindings remain untested.
