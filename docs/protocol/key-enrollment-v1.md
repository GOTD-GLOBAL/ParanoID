---
status: draft
owner: protocol
last_reviewed: 2026-09-08
---

# Key enrollment v1: proposed closed-alpha contract

Companion to [RFC-0010](../rfcs/0010-phone-key-registration.md), REQ-ID-005/006/007.
The bounded local candidate now implements the routes below. It remains draft:
local implementation/build authorization is not ADR-0006 acceptance, deployment
permission or a production security claim. The exact profile and public vectors
below concretize RFC-0010 in the same change as implementation.

## Exact local implementation profile

The shared `key-protocol` crate uses pinned vodozemac 0.10.0 Ed25519 secret keys
and strict Ed25519 verification (internally ed25519-dalek `verify_strict`). Root
and authentication keys are independently generated, not the Olm account's keys.
The client and server Cargo.lock files pin the actual dependency graph.

`LP(fields)` encodes each field, including the first domain field, as its UTF-8
byte length in unsigned 32-bit big-endian followed by those bytes. There is no
separator, terminator, Unicode normalization, JSON canonicalization or BOM.
Hashes are SHA-256, lowercase 64-hex. Ed25519 public keys (32 bytes) and signatures
(64 bytes) use standard alphabet, unpadded canonical Base64; alternate padding is
rejected. IDs generated here are lowercase canonical UUIDv4 strings. Integers
inside signatures are base-10 strings without leading zeroes. Protocol version
and algorithm are fixed by the domain and QR type; no algorithm negotiation.

Credential JSON has exactly `root`, `account`, `device`, `auth`, `realm`, `pin`,
`olm`, `signature`. All are strings. The root signature covers:

```text
LP("paranoid-credential-v1", root, account, device, auth, realm, pin, olm)
account = SHA256(LP("paranoid-account-v1", root))
olm = SHA256(LP("paranoid-olm-v1", curve, one_time_key))
credential fingerprint = SHA256(credential signature input above)
```

`realm` is the saved HTTPS origin including port, without a path or trailing
slash; `pin` is SHA-256 of server leaf SPKI DER. The outer TLS policy is unchanged.
Public request JSON is exactly `{type: "paranoid-request-v1", credential: {...}}`.
Only the local operator supplies the public credential to PostgreSQL. Public
challenge requests supply its fingerprint, not arbitrary new-key pending rows.

Public grant JSON has exactly `type` (`paranoid-grant-v1`), `id`, `credential`
(fingerprint), `realm`, `pin`, `slot` (integer 0/1), `expires` (integer Unix seconds).
It is not signed by a new server key or a bearer: authenticated pinned TLS lookup
and the matching device private-key proof establish its authority. A false
unconfirmed descriptor can be replaced without changing local keys; a confirmed
mapping cannot be replaced. Expiry is enforced by the server, not phone time.

Challenge request JSON has exactly six strings: `grant`, `credential`, `purpose`,
`method`, `path`, `body` (SHA-256 of exact request bytes). Enrollment uses its own
challenge route; all other purposes use `/v1/auth/challenge`. Control bodies are
exactly the two UTF-8 bytes `{}`. GET has an empty body. POST messages use the
existing envelope JSON contract. No auth challenge query parameters are accepted.

Challenge response has exactly the fields, in signature order, shown below.
`expires` and `slot` are JSON integers; all others are strings. `nonce` is 32
OS-CSPRNG bytes in padded standard Base64. Expiry is at most 60 seconds and is
checked against server Unix time and a monotonic issuance timer. Epoch is a fresh
UUIDv4 per server process/router. The device signs:

```text
LP("paranoid-proof-v1", id, nonce, epoch, expires, realm, pin,
   account, device, credential, grant, slot, purpose, method, path, body)
Authorization: Paranoid <challenge UUID>.<unpadded device signature Base64>
```

Purpose/method/path mappings are `enroll/POST /v1/enrollment/commit`,
`status/POST /v1/auth/verify`, `activate/POST /v1/enrollment/activate`, and
`message/GET or POST /v1/messages`. GET cursor query bytes are signed in their
exact order; changing order/value/path/body/purpose fails. Only generated stored
challenges are accepted; responses never contain a reusable session token.
Successful control responses contain exactly `mode`, `slot`, `grant`, `credential`.
Modes are `pending` or `active`; approved-but-unconsumed grants cannot obtain
status proof yet. A lost commit reply is resolved using fresh status, not new keys.

Public contact JSON is exactly `type` (`paranoid-contact-v1`), `credential`,
`bundle` (existing `device`, `realm`, `curve`, `one_time_key`), `signature`.
Device signature and full displayed contact fingerprint respectively cover and
hash `LP("paranoid-contact-v1", credential fingerprint, bundle.device,
bundle.realm, bundle.curve, bundle.one_time_key)`. Root signature, realm/pin,
Olm digest, device signature, alias and existing peer pins must all validate.
The user must explicitly compare the full fingerprint on the other phone.
Old verified Olm pins continue to protect existing conversations; adding the
new root binding neither rotates those pins nor proves historical root ownership.

Raw QR JSON enters Rust's strict typed parser before Android JSONObject can
collapse duplicate keys. Unknown/duplicate fields and QR-type confusion fail.
ZXing core 3.5.3 encodes/decodes locally, with a 2048-byte QR payload limit and
bounded camera frames. A 4096-byte native/text-import cap is additional protection.
QR images and grant descriptors contain public data only. No camera upload,
external scanner, secret URL, directory, or deferred-link flow is implemented.

[Public vectors](key-enrollment-v1-vectors.json) were generated independently by
`scripts/key-enrollment-vectors.py` using Python cryptography/OpenSSL, then checked
against Rust's exact bytes, signatures and one-bit mutation at each transcript
byte position in `clients/core/tests/key_vectors.rs`. Deterministic fixture seeds
in the generator are public test inputs, not application credentials.

The [local operator/test runbook](../operations/key-registration-local.md) records
actual scope, commands, bounds, migration/rollback limitations and device gates.

## Principals and admission

Account root key, device auth key, Olm keys, storage wrapping key and server TLS
key are independent. A domain-separated root-public-key digest identifies the
account. A root-signed credential binds version, account ID, device ID, auth
public key, server realm and digest of the E2EE public-key bundle (identity and
prekey, excluding the legacy routing alias). For an empty install create/persist
these keys in an unassigned wrapper before admission; attach the explicitly
granted transport alias later without new key generation. Existing installs
reuse their exact keys. Server stores only
public auth material and the binding digest, not content keys. Changing the
credential or device is not supported by this increment.

A maintainer-local tool records grant ID (random public identifier), exact account
and device credential digest, named legacy slot, realm, expiry and status. The
phone request QR is verified before this tool acts. The grant descriptor returned
to the phone contains no secret. It confers no authority without the bound private
key. No remotely reachable grant-creation API; no first-come slot allocation.
Recommended hard ceiling: two accounts, one device each, one active grant per
slot, 15-minute grant lifetime; replacement needs explicit operator action.

## Route intent and state machine

| Proposed route | Authentication / effects |
| --- | --- |
| `POST /v1/enrollment/challenge` | Grant ID plus credential fingerprint and request digest; only a matching unexpired approved grant can allocate a challenge. No account creation. |
| `POST /v1/enrollment/commit` | Root credential verification and device signature over a one-use enrollment challenge; atomically reserve exact grant/account/device/slot mapping in pending-activation state. No supplied sender authority. |
| `POST /v1/enrollment/activate` | Fresh activation-purpose key proof after local migration readiness; atomically set assigned slot key-only and persist activation status. |
| `POST /v1/auth/challenge` | Only known active or pending-activation device; purpose and exact intended request digest required. Unknown or revoked device gets generic denial, not durable pending state. |
| `POST /v1/auth/verify` | Signed login/status proof; returns own grant/migration/auth-mode status, no reusable bearer. After lost enrollment reply this confirms already committed identical mapping without re-consuming grant. |
| `GET`, `POST /v1/messages` | Signed one-use request proof for active device maps to its existing 0/1 transport principal; same envelope/history semantics as v0. Pending activation cannot send/sync through this route. |

Client: `local identity saved -> awaiting grant -> enrollment pending -> active`.
Migration adds `pending activation -> explicit activation -> active` as below.
Timeouts retain keys and candidate state; duplicate create never regenerates keys.
Status requests cannot grant enrollment, change a slot or override a credential.
A consumed-grant retry never creates a second account; authenticate status with a
fresh challenge instead. Key/credential/slot conflicts fail closed.

## Challenge and request proof

Recommendation: per-request proof rather than adding session/refresh bearer
semantics in this slice. Login is an automatic signed status proof; every message
request is independently authenticated. This adds a round trip, acceptable for
two alpha devices, and avoids pretending that a hidden old token is key login.

Each server challenge uses 32 CSPRNG bytes and a random challenge ID; server-issued
expiry at most 60 seconds, no reliance on client wall clock. Bind protocol version,
domain/purpose (`enroll`, `status`, `activate`, `message`), configured realm/origin,
server SPKI digest, account ID, device ID, credential digest, grant ID when relevant,
HTTP method, exact path/query and SHA-256 of exact request body bytes (empty for
GET). Signature verification covers the entire canonical transcript, including
challenge ID, nonce and expiry. No ambiguous JSON serialization, implicit field
concatenation, alternative query ordering, duplicate fields or unknown fields;
review canonical encoding and fixed vectors before adding a network handler.
Reject inconsistent account/key digests and unsupported algorithms/versions.

Issue challenges only after bounded input parsing and eligibility lookup. Keep
at most four outstanding challenges per allowed device and sixteen globally;
reject new allocations when full rather than evicting another valid challenge.
Auth body cap is 8 KiB, with two challenge issuances/second per eligible device,
eight auth requests/second globally before lookup, plus the global 20-request/second
and 10-second handler bound. Budgets are fixed one-second windows, not strict
sliding-window guarantees. No attacker-indexed IP map is allocated. Sixteen
concurrent TLS sockets (including handshakes) and an eight-second handshake
deadline bound transport work. These are not volumetric DoS protection: shared
budget starvation remains possible. No storage allocation for arbitrary keys.

Successful signature verification must atomically consume the challenge before
any authorized effect. Concurrent reuse has at most one winner. A bounded
single-process challenge store may discard all outstanding challenges at restart:
never reconstruct a challenge from client data; fresh random boot epoch included
in each transcript prevents old-boot proof reuse. Persisted grants, activation,
auth mode and unique mappings remain transactional in PostgreSQL across restart.
Before supporting multiple server workers, replace local consumption with a
shared atomic store; deployment must reject unsupported multiple-worker mode.

A crash after consuming proof but before DB commit loses only that request's
challenge, not admission or message history. Client obtains fresh proof and retries
identical enrollment intent or exact queued message bytes. Existing message ID
idempotency handles lost successful responses; altered retry remains conflict.
Revocation/expiry/auth-mode checks are repeated inside the state-changing DB
transaction, not only at challenge issuance. Revocation racing an operation is
ordered by the same account/slot lock: later operations fail. Invalid signature
gets no authority; do not let attackers invalidate a legitimate challenge merely
by guessing its ID. Rate-limit failures without echoing submitted values.

Proposed errors: generic 401 for absent/invalid eligibility/proof, 403 for a known
principal lacking operation rights, 409 for conflicting binding or state, 429 for
bounded capacity/rate exhaustion and 503 for storage failure. Do not reveal other
accounts' slot occupancy, fingerprints or precise grant existence. Known devices
learn only their own status after proof. Uniform messages do not prove timing
non-enumerability; tests and residual metadata disclosure remain necessary.

## Migration: preserve identity and history, not bearer authority

Only isolated populated fixtures exercise migration in this change; there is no
live migration or deployment. Existing v0 accounts are only
operator-assigned slots, not cryptographic root identities. A newly added root
cannot retroactively prove ownership of old ciphertext. Never label this as
recovery or root continuity that the old protocol did not have.

1. Use a reviewed migration-capable release with a versioned encrypted snapshot
   reader and explicit DB/config version checks. Verify populated disposable
   backup/restore first. Current deployment update rejects changed schema hash;
   do not weaken it or run ad hoc SQL to bypass that gate.
2. Preserve APK signing identity/package, Android Keystore alias and encrypted
   local state. If the old snapshot is missing, corrupt or its key unavailable,
   stop; do not uninstall, clear app data or call `init` over it. Add independent
   root/auth state alongside unchanged Olm account/session/peer/cursor/outbox/
   dedup/history. Keep legacy alice/bob labels inside historical crypto data.
3. Maintainer verifies exact tester, new credential fingerprint, existing public
   Olm bundle fingerprint and named old slot, then records that mapping. The old
   bearer, already saved on an existing phone, may support private in-app evidence,
   but is never sufficient to claim any slot by itself and is never requested
   from the tester or exported. For an uninitialized phone only the owner's
   explicit assignment proves entitlement; an empty DB is not a free-slot grant.
4. Enrollment transaction creates a unique pending mapping and consumes the grant.
   Phone confirms it with fresh status proof and durably saves candidate identity.
   A lost response is resolved by the same key, never new keys. Existing v0 auth
   stays unchanged during pending state; no messaging via pending key auth.
5. After local readiness, a signed `/v1/enrollment/activate` with its own challenge
   atomically flips that slot to key-only. Gate ALL routes, including v0, by auth
   mode so legacy bearer cannot bypass cutover. Phone records activation; lost
   reply resolves through signed status. Other tester's mode remains unchanged.
6. Compare ordered server envelopes/room sequence/usage, client ratchet/session,
   cursors, outbox bytes, receipt flags and dedup before/after. No history rewrite,
   auto-expiry, automatic slot reuse, key rotation or automatic bearer fallback.

Before activation an explicit maintainer abort can retire the pending mapping
while retaining the new local keys and unchanged old client data; never auto-reset
on network error. After activation rollback must keep key-only auth and all
post-cutover history using a reviewed migration-capable release. Old binaries
ignore new auth-mode state and would revive bearer access: startup/update gates
must refuse them. If no compatible rollback is ready, stop the service and
preserve state; do not restore a stale dump or silently reactivate an old token.
Full account/device revocation, recovery and schema downgrade remain separate
reviewed procedures, not implied by this one-device migration.

## Peer QR verification

Use a versioned, typed contact QR with realm, account public ID/root public key,
root-signed device credential and exact current public Olm bundle. Verify all
bindings locally, then require explicit trusted physical/out-of-band comparison.
The short display ID is not the only comparison input; collision-resistant full
fingerprint/QR comparison is required. Legacy `device=alice/bob` is only a transport
alias. Root binding supplements, never replaces, the existing peer Olm pin.

No public contact directory is added. A server response cannot mark a peer verified.
Migration of an existing contact requires the root binding to match its pinned
Olm key and direct confirmation on the peer phone. A substituted key, unknown QR
type, oversized payload, realm mismatch or conflicting mapping fails with the old
contact/history untouched. QR scanning grants neither server admission nor seed
recovery. REG-01 through REG-06 have bounded local evidence in the runbook;
physical camera, Android Keystore and two-OPPO acceptance remain NOT RUN.
