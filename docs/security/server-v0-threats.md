---
status: draft
owner: security
last_reviewed: 2026-09-08
---

# Single-server text threat-model delta

Companion to the [base threat model](threat-model.md) and
[RFC-0006](../rfcs/0006-single-server-text-contract.md). Recommendations below
include implemented development controls and outstanding target gates, distinguished
below. Residual-risk triage owner is martadvix-web until an independent
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
bounds and static error redaction are implemented. The initial transport did not
include client state, TLS or ingress limits; later client and explicit alpha-mode
controls are described below and in RFC-0009. A reverse proxy
must not bypass the development-only boundary. See the server README for the
explicitly opted-in disposable CI database exception.

## IP TLS pin provisioning and rotation boundary

The development Android adapter now implements per-connection pinned HTTPS.
The operator-generated trust input is SHA-256 over leaf SPKI DER, not a bearer
credential or peer identity. Verify it out of band before enrollment; a pin
copied from an unauthenticated endpoint provides no first-contact protection.
Do not reuse one private TLS key across independent servers. TLS-key compromise
exposes transport credentials/metadata; it does not provide client Olm content keys.

The adapter requires a matching self-signed leaf, validity, server-auth usage,
adequate key strength and exact SAN; default hostname verification stays enabled.
Only TLS 1.2/1.3; redirects and global/trust-all overrides are absent. Saved pin
changes are refused. Renewing a certificate with its key is distinct from rotating
the key; key loss/change requires explicit re-enrollment, not remote auto-repin.
The generator refuses existing destinations and prints only public connection data.

JVM TLS tests cover correct pin and wrong pin/IP/expiry, with no HTTP request on
rejected peers. Android TLS/Keystore behavior, IPv6 and further negative certificate
fixtures remain unverified. These changes deploy no service or public port and
accept no production trust model. The [client README](../../clients/android/README.md)
records the subsequent sync corrections and remaining runtime/deployment gates.

## Rejected-event and outbound-failure recovery

For well-formed newer transport events, classified payload/capacity errors restore
the original client state before atomically saving only rejection metadata and
cursor progress. Failed account/session/history/outbox candidates and false
receipts are never committed. Notices are bounded (last 64 plus count/earliest
sequence) and visible; this does not delete server ciphertext or existing history.
Deferred messages have no automatic replay UI or guarantee of later decryption.
Structural transport/order/replay conflicts and local-state errors are not skipped.

HTTP 409/507 does not make receiving depend on successful sending, nor starve
later outbox entries. Exact failed bytes remain queued; auth/network failures
stop that send batch and remain visible. Any uncertain local commit freezes the
whole cycle. Cancellation is propagated. Rust recovery tests and a JVM HTTP
409/507 fixture verify the distinction; Android filesystem/lifecycle evidence
and final device acceptance remain separate.

## Native alpha deployment delta

[RFC-0009](../rfcs/0009-isolated-linux-alpha-package.md) explicitly changes the
network boundary without proxying development HTTP: Rustls serves TLS directly
on 38443 only in opted-in alpha mode. Private PG16 socket/data and systemd
resource caps isolate neighboring workloads; global 20-request/second ingress
and 10-second handler timeout bound application work, not volumetric/handshake
DoS. No logs of credentials, payloads, DB URLs or SQL error statements.

Release checksums are integrity checks, not signatures. Same-account/root
compromise exposes bearer/TLS credentials and metadata. Dedicated account and
trusted artifact provisioning remain required. Update/rollback first quiesces
writes, verifies dump restore/data equality and refuses changed schema hashes;
code rollback preserves current history, never restores a stale dump over it.
Restricted dumps and retained verification DBs still contain routing metadata
and need disk monitoring. No client content keys enter the package. Backup
encryption/transfer, host loss, reboot and OPPO use remain unverified. The
[runbook](../operations/linux-alpha-deployment.md) records limits; risk owner
martadvix-web, independent parent review pending under ADR-0003.

### Observed hosted rollout boundary

The [authorized attempt](../operations/linux-alpha-rollout-2026-09-08.md) used the
reviewed package on the dedicated host account and passed host-local authenticated
TLS/DB health. External 38443 timed out; default-deny UFW had no allow rule. The
operator did not widen firewall policy: the new unit was stopped/disabled, linger
reverted, and private configuration/TLS/data retained. No external TLS/SPKI or
phone acceptance is claimed. Public network exposure remains an explicit scoped
authorization and verification gate, not an implicit consequence of a free port.
The linked record also captures completed independent package review and CI;
preparation-time pending-review language above is historical.

### Filesystem fail-closed controls

A reproduced packaging flaw allowed stale ignored secrets into rebuilds; builds
now use fresh 0700 staging/output and exactly six regular nonsymlink members.
Unknown prior build files are neither archived nor deleted. Installation roots
and ancestors must be real directories, with no traversal or symlink aliases;
ancestors are root/account-owned and not group/other-writable except root-owned
sticky temporary directories. Persistent data/socket/releases/backups/TLS are
private same-owner real directories. Config, TLS and existing lock files must
be private same-owner single-link regular files; config and lock opens use
O_NOFOLLOW/O_NONBLOCK and descriptor validation. Configuration has exactly
`ip`, `alice`, `bob`: canonical IPv4 and distinct 64-hex tokens.

The current symlink must select a verified direct child of releases with matching
ID, not dot/dotdot or a redirected directory. Candidate collisions and invalid
installation state fail before lifecycle writes or service stops. These controls
address accidental/restored redirection, not a hostile root or concurrent
same-account attacker: the dedicated account and trusted artifact/controller
remain prerequisites. PG cluster contents and the executing controller remain
trusted; this is not a general filesystem sandbox or publisher authentication.
Tests use only synthetic files/databases and preserve client-only content keys.

## Residual limits

The malicious server can drop/delay messages, lie about its own commit, withhold
history or correlate traffic. Recipient-authenticated receipts reduce false
peer-delivery claims but do not attest a compromised peer's behavior. Deletion
cannot erase recipient copies. Seed recovery does not reconstruct forward-secret
ratchet history. Local plaintext markers not appearing in a DB dump is limited
evidence, not a cryptographic proof. iOS secure storage and bindings remain untested.
