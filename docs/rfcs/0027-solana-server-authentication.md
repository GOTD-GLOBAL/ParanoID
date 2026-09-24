---
status: draft
owner: identity
decision_owner: martadvix-web
last_reviewed: 2026-09-24
---

# RFC-0027: Solana identity login and single-device replacement

## Status and authority

This is a protocol proposal, not implemented behavior or an accepted decision.
Human decision owner: Sergey Maltsev (`martadvix-web`). Independent security and
protocol review, an ADR and owner disposition precede adoption. Reviewer assignment
and disposition date remain open; no approval is inferred from drafting permission.

On 2026-09-24 in Telegram ParanoID thread 2 Sergey confirmed the product sequence:
finish Solana login, then implement owner-operated server deployment from Android.
The target is one app, a registered identity, and a choice of the common server,
an invited independent server, or a self-hosted server. He then instructed:
«Готовь протокол. Если переписка и контакты потеряются ничего страшного.»
The original message permalink is unavailable. This waives migration of CURRENT
TEST chats and contacts for this transition only. It does not authorize deleting
anything now, discarding operational backups, wiping a hosted database, changing
TLS/signing keys, deploying, or weakening future message durability.

The existing [single-device product direction](../project/current-state.md)
requires seed recovery to replace the previous active device. Concurrent devices
are later scope. The author proposes the mechanisms below; they are not owner
approved merely because this document records the product direction.

Requirements: REQ-ID-001/002/003/004/005/006/007/008, REQ-MSG-002/003/004/005,
REQ-SEC-001 and REQ-CLIENT-001. REQ-SERVER-001/002, REQ-MULTI-001 and
REQ-DEPLOY-001 describe the subsequent milestone, not delivery in this RFC.
ADR-0001 and ADR-0003 preserve documentation and independent review gates.

## Scope and current compatibility boundary

Use the existing [RFC-0026 registry](0026-solana-devnet-registration.md), its
Devnet genesis/program/artifact pins and key derivation. No registry deployment,
new instruction, transfer, rename, Mainnet or real-money wallet is needed.
Login signs an off-chain challenge: no transaction, fee or SOL balance required.

Current [v2 credentials](../protocol/key-enrollment-v1.md) derive the transport
account from a separate root; [first contact](../protocol/first-contact-v1.md)
pins the credential/device/Olm keys immutably. Therefore seed recovery CANNOT
silently replace keys under that existing transport account. This proposal adds
a stable server-local identity membership pointing to a current transport account;
a replacement gets a fresh transport account and fresh E2EE keys. These are
internal components of one user account, not two user-facing registrations.
Old first-contact pins remain immutable. Automatic peer key rebinding is excluded.

A later design may offer verified identity-based contact rotation. Until then,
replacement requires sharing the new contact and explicitly adding it as a new
conversation. No automatic transfer of a verified badge, contacts or old history.
This is a disclosed limitation of the first login slice, not completed seamless
account recovery. The owner must see it before approving this design.

## Principals and stored state

- `identity`: (Devnet genesis hash, registry program ID, identity PDA). Never key
  an account by display name alone. Validate the paired name record and owner.
- Registry owner: existing independent Devnet Ed25519 authority. Seed stays local.
- Membership: internal random UUID, unique on (server, identity), with admission
  state, unsigned 64-bit generation and current transport account. Generation
  overflow fails closed; there is no wrapping or reset.
- Transport account: existing independently generated root/auth/Olm credential
  and existing account derivation. Blockchain seed is not reused as an Olm key.
- Server binding: existing saved HTTPS realm and SPKI pin; no automatic trust
  replacement, arbitrary RPC URL or trust learned from a challenge.

Membership and generation are server-local, never on-chain. The common server
can allow bounded self-admission without an operator. Identity possession does
not override bans, capacity or an independent server's invitation policy. This
slice implements only the configured common-server policy; invites are later.

## Proposed login exchange

New routes are `/v3/identity/challenge`, `/v3/identity/commit` and
`/v3/identity/status`. These names do not re-version message encryption. Requests
are strict JSON: reject duplicate/unknown keys recursively, cap body at 16 KiB,
reject query parameters and redirects. Numbers in JSON are exact integers, not
floats. Public Solana addresses use canonical base58; hashes use lowercase hex.
Other keys/signatures and LP encoding follow key-enrollment-v1.

1. Client validates pinned TLS and explicitly selects first enrollment, resume
   or replacement. It persists any candidate device keys and operation UUID
   before network use. No automatic replacement merely because a request fails.
2. POST challenge fields: `target` (`commit` or `status`), `operation` (UUIDv4), `action` (`enroll`, `resume`,
   `replace`), `genesis`, `program`, `identity`, `owner`, `name`, `credential`
   (complete existing Credential object). Credential self-signature, account
   derivation, realm/pin and field bounds must validate before storage.
3. Server validates admission and reads BOTH canonical registry PDAs in one
   finalized RPC context; validate all RFC-0026 layout/link/owner/name/padding
   rules, genesis and pinned program/ProgramData artifact and authority. Never
   accept client-supplied RPC results. No stale-cache fallback for new commits.
4. Server returns exactly `id`, `nonce`, `epoch`, `expires`, `realm`, `pin`,
   `target`, `operation`, `action`, `genesis`, `program`, `identity`, `owner`, `name`,
   `account`, `device`, `credential`, `expected_generation`. Here credential is
   the existing credential fingerprint. All are strings except expires and
   expected_generation. Nonce is 32 OS-random bytes in canonical padded Base64;
   id and per-process epoch are UUIDv4. TTL is 60 seconds, enforced by both wall
   and monotonic server time. Generation zero means absent membership.
5. Client compares every field against saved intent/server/registry/credential;
   it never signs an arbitrary supplied transcript. It signs the following bytes
   with both registry-owner and candidate device-auth keys, with distinct domains:

   ```text
   T(domain) = LP(domain, id, nonce, epoch, expires, realm, pin,
     target, operation, action, genesis, program, identity, owner, name,
     account, device, credential, expected_generation,
     "POST", "/v3/identity/commit")
   owner_signature = Ed25519(owner, T("paranoid-identity-owner-v1"))
   device_signature = Ed25519(auth, T("paranoid-identity-device-v1"))
   ```

6. POST commit contains exactly `id`, `operation`, `owner_signature`,
   `device_signature`. Server uses the stored challenge, not reconstructed client
   fields. Strict verification of both signatures precedes mutation. Invalid
   signatures do not consume legitimate challenges. Recheck registry and policy
   before commit; results must be obtained during this challenge lifetime.
7. In one serializable transaction lock identity membership; compare expected
   generation and admission state; consume challenge; publish credential and
   transport mapping; revoke previous generation if replacing; store operation
   result. All succeed or none succeed. No success response before durable commit.
8. Response: `operation`, `membership`, `generation`, `account`, `device`,
   `credential`, `mode` (`active`). No reusable bearer token. Client commits the
   result durably before starting message/push/call workers.

`enroll` only creates absent membership (generation 1). `resume` requires the
exact active credential and does not advance generation. `replace` requires
existing membership, a fresh root/account/device/auth/Olm bundle and explicit UI
confirmation; it advances generation once. Two concurrent replacements using the
same expected generation cannot both commit. Loser must show conflict, not
silently retry with a new generation and evict the winner.

## Retries, restart and errors

Store `(identity, operation)` result and complete intent digest atomically with
commit. An exact retry can recover its result after lost replies, but only after
a fresh dual-signature challenge; never disclose credentials/results by operation
ID alone. Different intent under the same operation is `operation_conflict`.
A result whose generation has since been replaced reports `device_revoked`, never
reactivates old state. Restart invalidates outstanding challenges, not operation
results, mappings, generations or revocations. Retain operation tombstones for the
lifetime of membership in this alpha; capacity exhaustion rejects new operations
rather than dropping replay protection.

`/v3/identity/status` uses the same challenge fields with action `resume`, signed
with separate domains `paranoid-identity-status-owner-v1` and
`paranoid-identity-status-device-v1`, method POST and that exact status path. It
returns the active result or revoked/conflict, without creating or replacing state.
Challenge issuance therefore also takes an exact `target` field, restricted to
`commit` or `status`; it is stored and returned, and selects the signed path and
domain above. Other combinations are rejected; status only allows resume.

Return bounded errors: `invalid_proof`, `expired_challenge`, `registry_unavailable`,
`identity_invalid`, `admission_denied`, `capacity`, `generation_conflict`,
`operation_conflict`, `device_revoked`, `unsupported_version`. Registry uncertainty
is unavailable, not unregistered. No implicit clear-data/rekey or v2 registration
fallback. Bound in-flight challenges and RPC concurrency, apply per-source and
identity rate limits before RPC, and never create permanent user rows from an
unsigned challenge. Exact limits are deployment configuration reviewed before use.

## Revocation and ordinary traffic

Owner key is needed for enrollment/recovery, not every message. Existing device
request proofs continue only after a server-side active-membership/generation
check. Every authenticated entry point is covered: REST messages, status, events,
realtime writes, push registration and TURN credential issuance. A saved transport
account cannot bypass this through legacy v2 registration/auth routes.

Revocation linearizes with the membership transaction: message reads/writes and
replacement serialize against the same membership guard; no old-device operation
may commit after replacement. Long-lived connections recheck generation for every
authorized operation and close when revoked; queued event output is fenced too.
An old device cannot re-enroll its retired transport credential through v2.
Cutover policy must prevent ungated legacy accounts contacting the new cohort;
use an isolated auth-required deployment/cohort rather than an accidental mixed
mode. Existing old service remains unchanged until explicit deployment authority.

Already downloaded data cannot be recalled. Existing TURN allocations and direct
WebRTC media cannot be stopped solely by revoking server login. Stop new signaling
and relay grants; require tested relay expiry/termination bounds before claiming
bounded media revocation. Immediate termination of every ongoing old-device call
is NOT promised by this RFC and remains a release disclosure/review item.

Old transport inbox remains inaccessible to the new device; it has different keys.
Do not move pending ciphertext or re-sign queued messages under new identity.
Retention/deletion is a separate scoped operation; revocation is not deletion.

## Security delta and test gates

Residual risks: server knows public identity/name and membership; servers can
correlate the identity. Trusted RPC can lie; finalized HTTPS RPC is not a light
client. Upgrade authority remains a trust boundary. Seed theft permits takeover
and repeated replacement; there is no operator recovery or seed rotation in the
current registry. Devnet resets/outages can prevent new login. Already authorized
devices may continue bounded ordinary service during RPC outage: admission uses
committed membership, not a live RPC lookup for every message. Policy revocation
still applies. No social graph, device list or server list is written on-chain.

Required executable checks, all NOT RUN for this new proposal:

- AUTH-01: independent signature vectors; mutate every field/domain/target; reject
  noncanonical encodings, duplicate fields, unknown fields and oversized bodies.
- AUTH-02: wrong genesis/program/authority/artifact, fake PDA/name/owner, malformed
  or partial records, RPC outage/stale responses; no mutation or bypass.
- AUTH-03: replay, expiry, server restart, stolen challenge, wrong device proof,
  cross-server/cluster/endpoint substitution; challenge budget saturation.
- AUTH-04: real PostgreSQL concurrent enroll/replace, lost response and crash at
  transaction boundaries; unique mapping, monotonic generation, exact retries.
- AUTH-05: revoked REST/event/realtime/push/TURN paths, legacy bypass attempts,
  concurrent message/replacement and old operation retry after later replacement.
- AUTH-06: real core/JNI E2EE first contact, reply, receipts, text and calls after
  login; no silent contact-pin replacement; old ciphertext remains inaccessible.
- AUTH-07: Android restart/pending operation/Keystore errors; no silent reset;
  physical two-phone enrollment and seed recovery on a fresh install, then
  rejection of the old device. Fresh contact exchange after replacement is explicit.
- AUTH-08: expiry/termination behavior for existing relay allocations and calls;
  distinguish measured server revocation from impossible remote data erasure.

## Alternatives and disposition blockers

Do not reuse the blockchain key as an Olm key, derive chat history from the seed,
trust nickname strings as authentication, require an on-chain transaction per
login, or replace immutable peer keys behind existing ContactV2. These shortcuts
break existing separation, recovery expectations or peer verification.

Before implementation freeze, independent review must close: exact schema/vectors
(including target field), all server authorization entry points, operation-result
retention budgets, strict cutover isolation, registry freshness timeout, and media
revocation disclosure. Owner disposition must explicitly cover fresh transport
accounts/new contact exchange after replacement and the resulting UX. A draft ADR
must record the reviewed choice before acceptance; RFC0026/ADR0015 are not silently
promoted or rewritten. No owner-server installer, SSH credential collection,
invitation protocol, federation, iOS implementation or deployment is delivered here.
