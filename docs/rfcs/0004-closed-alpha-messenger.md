---
status: draft
owner: architecture
decision_owner: martadvix-web
decision_deadline: pending founder scheduling before this RFC moves to proposed
required_reviewers:
  - <qualified-independent-e2ee-and-identity-reviewer>
  - <qualified-independent-stack-and-deployment-reviewer>
last_reviewed: 2026-09-07
---

# RFC-0004: Closed-alpha messenger slice

## Required review rationale

This RFC touches protected domains: E2EE semantics, identity and key derivation,
the primary stack, and deployment topology. Each placeholder above must become a
qualified human GitHub login independent of the author and decision owner before
this RFC moves to `proposed`. The RFC authorizes no implementation by itself;
work starts only after disposition per the
[documentation policy](../governance/documentation-policy.md#decision-authority-and-acceptance-evidence).

## Summary

Define the first usable ParanoID closed alpha: two real phones as two separate
users, one hosted server, a private end-to-end encrypted 1:1 text conversation
with persistent history, reliable reconnect, no duplicate messages, and a
reproducible server deployment to a second machine. Voice messages, then 1:1
audio/video calls, are subsequent slices; groups and blockchain come later. One
concrete candidate stack is proposed with fallbacks. The alpha is controlled
test use with no production security claim, but it must not ship plaintext
disguised as E2EE: if real E2EE cannot be established, the slice is blocked.

## Motivation

`REQ-MSG-001`, `REQ-CLIENT-001`, and `REQ-DEPLOY-001` in
[requirements](../product/requirements.md) need a first vertical slice with
measurable acceptance criteria (current-state gate 5). The founder's priority
order is: two real phones, one hosted server, text first, reproducible
deployment, then voice messages and calls, blockchain later. `REQ-SEC-001`
blocks production privacy claims, so the alpha must establish the E2EE and
key-separation skeleton rather than retrofit it. Noncanonical prior art: the
landscape study (`docs/research/2026-08-17-oss-architecture-landscape.md`,
branch `oss-research-identity-direction`) and the paused foundation RFC
(`docs/rfcs/0003-foundation-stack.md`, branch `foundation-stack-rfc`).

## Goals and non-goals

### Goals

- Slice A1: 1:1 E2EE text between two phones via one hosted server, with history
  after restart, reconnect recovery, and exactly-once display.
- Slice A2: reproducible deployment to a second machine from documentation
  alone; backup and verified restore. Slice A3: E2EE voice messages. Slice A4:
  E2EE 1:1 audio/video calls (own RFC).
- Identity verification contract as a stable seam: local key generation,
  proof-of-possession login, QR contact verification. Threema's identity UX is a
  reference for these three properties only; its protocol, server-assigned
  global IDs, Safe recovery, and cryptography are not adopted.
- Root/device key separation so a later blockchain registry binds the root
  public key without re-keying accounts. No custom crypto constructions.

### Non-goals

- Groups, federation, multi-server use, plugins, nickname registry, blockchain,
  multi-device per account, push notifications, production security claims.
- Metadata privacy: the alpha server sees who talks to whom, when, and
  ciphertext sizes; this is documented, not hidden.

## Proposed design

Identity: the client generates a seed locally (standard wordlist, e.g. BIP39;
choice open) and derives, via a standard KDF, a root Ed25519 signing key and a
device signing key with a root-signed device credential. The server stores
public keys only; nothing secret leaves the device. Login signs a single-use,
server-bound, expiring nonce (proof of possession) — no phone number, email, or
password. QR verification compares the peer's root-key fingerprint out of band
and hard-warns on mismatch. The durable principal is the root public key, never
a server-assigned ID.

Messaging (A1): WebSocket for live delivery plus HTTP fetch/ack over TLS
(transport security is additional to, not a substitute for, E2EE). Message
bodies reach the server only as opaque ciphertext envelopes produced by an
established Double Ratchet implementation. Deduplication: sender-generated
message UUID with a server unique index on (conversation, sender device, message
ID) and idempotent insert; clients render exactly once by ID. Reconnect resumes
from the last acknowledged server-assigned sequence. History persists in a local
store protected by platform key storage; the server retains ciphertext for
offline delivery (retention rules open).

Proposed candidate stack (no candidate is accepted by this RFC):

| Component | Candidate | Evidence status | Fallback |
| --- | --- | --- | --- |
| Server | Rust: Tokio, Axum, Tower | Mature, widely deployed | Kotlin/Ktor |
| Persistence | PostgreSQL + SQLx | Mature, widely deployed | SQLite (dev only) |
| E2EE library | [vodozemac](https://github.com/matrix-org/vodozemac) (Rust, Apache-2.0, audited 2022) | Proven inside Matrix; standalone use is unverified feasibility | [OpenMLS](https://github.com/openmls/openmls) |
| Crypto bridge | Rust core via [UniFFI](https://mozilla.github.io/uniffi-rs/) bindings | Unverified feasibility; requires spike | Platform-native use of same library |
| Mobile client | Android first, two OPPO phones; native Kotlin UI candidate | OS scope confirmed by founder; exact models, Android versions and bridge feasibility pending | Flutter Android shell over the Rust core |
| Deployment | Container + Docker Compose: one server process + PostgreSQL | Tooling mature; ParanoID runbook unproven | Bare systemd units |

Narrow rationale: aligns with the paused RFC-0003 server direction, keeps one
memory-safe language for the security core, and uses only permissive-license
E2EE candidates. libsignal has the strongest Double Ratchet evidence but is
AGPL, outside the confirmed permissive embedded-core boundary; reference only.
Every candidate must be pinned, rebuilt, and license-scanned before any
implementation PR depends on it.

Confirmed earlier inputs preserved but unresolved for the alpha — each needs an
explicit recorded resolution before or during implementation:

1. Seed-only recovery (`REQ-ID-002`): backup/restore UX deferred to A2; decide
   the minimum day-one behavior (must the seed be exportable at creation?).
2. Pairwise/server pseudonyms: the alpha exposes one server-scoped account key;
   decide whether the derivation must already be pseudonym-ready.
3. Independent/multi-server identity: deferred; root/device separation is the
   preserved seam.
4. LAN without live RPC (`REQ-NET-001`): no RPC exists yet, but LAN-only
   deployment is untested; nothing may hard-code public endpoints.
5. Mandatory call E2EE: binds slice A4; the call stack (e.g. LiveKit per the
   landscape study) needs its own RFC with key-distribution evidence.

## Alternatives

- Adopting Matrix/Synapse or SimpleX wholesale: Matrix identity is
  homeserver-bound, conflicting with the portable root; references only.
- libsignal end to end: best-proven protocol code, excluded by the AGPL boundary.
- TypeScript server + React Native: fastest delivery, weakest reuse with a Rust
  crypto core, resembles the legacy prototype; reference only.

## Security and privacy

Assets: seed and derived keys (device only), ciphertext history, server
metadata. The server, host, and network observe full conversation metadata;
alpha testers must be told so explicitly. Logs must never contain key material
or plaintext. Threat-model updates for the identity, key-derivation, and E2EE
boundaries are required in the same PRs that implement them.

## Compatibility and migration

The alpha protocol is development-only `v0` and may break without migration.
The one deliberate commitment is the identity seam: the root public key is the
durable principal so a later blockchain nickname registry attaches without
re-keying. Alpha accounts may otherwise be reset.

## Operations and observability

One server process plus PostgreSQL, containerized, with documented
configuration, a health endpoint, privacy-safe structured logs, `pg_dump`
backup, and a rehearsed restore. The A2 deliverable is a second-machine
deployment performed from the runbook alone, with evidence recorded.

## Validation plan

Executable acceptance tests, run on the two real phones with evidence captured:

1. Fresh install on both phones creates identities without phone number or
   email; a server-side assertion proves no private key or seed was received.
2. QR verification succeeds; a tampered-key test shows the mismatch warning.
3. 50 online messages arrive exactly once, in order; a database dump contains no
   known plaintext marker.
4. Receiver offline for 20 messages, then reconnects: all arrive exactly once;
   app kill/restart still shows full history.
5. Forced reconnect loop with resent identical message IDs yields no duplicates.
6. Server restart loses no acknowledged message; clients recover unaided.
7. A2: clean deployment on a second machine from documentation alone; backup on
   machine one, verified restore on machine two.

Ordered implementation PRs (small, each with tests and docs; no schedule
estimates are made because none are evidenced):

1. Server scaffold: Rust workspace, health endpoint, CI, container image,
   compose dev deployment.
2. Migrations, ciphertext envelope store, idempotent insert with dedup tests.
3. Challenge–response device login (`v0`) with negative-path tests.
4. Identity core crate: seed → root → device derivation, signed device
   credential, test vectors.
5. E2EE feasibility spike: two headless Rust clients exchange Double Ratchet
   messages through the server; go/no-go evidence for the candidate library.
6. Android mobile shell for two OPPO phones: build, install,
   register, QR verify on the two real phones.
7. Messaging UI, local history, reconnect/dedup; acceptance tests 1–6 recorded.
8. Deployment runbook, second-machine reproduction, backup/restore; test 7
   recorded.

Installed apps on both phones and the reproduced server are deliverables, not
simulator output.

## Open questions

- UI-1: both initial phones are Android OPPO devices, confirmed by the founder.
  Exact models and Android versions remain needed for installation and compatibility
  testing. iOS is outside this first slice, not removed from the product scope.
- H-1: the founder selected the existing production server for alpha work, not
  a separate test VPS. Its exact host, domain, access path, existing workloads,
  isolation and rollback requirements must be verified before deployment. This
  hosting choice does not constitute acceptance of the architecture or a claim
  that the alpha is production-ready.
- Minimum alpha seed-backup behavior (input 1). Owner: founder.
- Pseudonym-readiness of the derivation (input 2). Owner: founder + reviewer.
- Server-side ciphertext retention rules. Owner: architecture.
- Assignment of both required reviewers. Owner: decision owner.

## Decision and follow-up

- Disposition: pending; RFC is `draft` and non-normative.
- Decision-owner approval permalink: pending.
- Delegation evidence permalink, if applicable: not applicable unless delegated.
- Required-review evidence permalinks: pending reviewer assignment.
- Resulting ADR: pending; no ADR is accepted by this RFC.
- Closure rationale for `completed`, `rejected`, `withdrawn`, or `superseded`:
  pending disposition.
- Replacement RFC for `superseded`: not applicable.
- Implementation issues: create only after disposition; the PR list above is a
  proposed order, not authorization.
