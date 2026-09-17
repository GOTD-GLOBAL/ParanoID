---
status: proposed
owner: protocol
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# First-contact v1: clean-install signed account-ID channel

REQ-MSG-005, REQ-ID-004/005/007/008, REQ-MSG-002/003/004, REQ-SEC-001;
[RFC-0014](../rfcs/0014-first-contact-incoming.md), proposed
[ADR-0009](../decisions/0009-clean-first-contact.md). Written before runtime
implementation. This is the selected bounded private-alpha contract, not accepted
production architecture. The owner explicitly excludes old-history migration and
recovery from this clean-install candidate; unsupported snapshots are preserved
and rejected. Historical protocol/tests are not silently reinterpreted.

## Reused strict ContactV2

ContactV2 JSON contains exactly `type: "paranoid-contact-v2"`, `credential`,
`bundle`, `fallback_key`, `signature`. Credential is the unchanged root-signed
[server-owned credential](key-enrollment-v1.md); bundle contains exactly original
`device`, `realm`, `curve`, `one_time_key`. The contact device-auth signature signs
this transcript; contact fingerprint is SHA256 of the same transcript:

```text
LP("paranoid-contact-v2", credential fingerprint, bundle.device,
  bundle.realm, bundle.curve, bundle.one_time_key, fallback_key)
```

Verify credential root/account/Olm binding, realm/SPKI, canonical curve/prekey/
fallback encodings and device contact signature. Bundle labels `unassigned`,
`alice`, `bob` are allowed only as signed historical bundle metadata; they never
choose the channel or encrypted from/to context. The sender and recipient cannot
have the same account or original curve key. A genuine QR comparison installs
immutable out-of-band trust; network signature validation alone does not.

## Immutable channel and framing

Reuse strict [ContactV2](#reused-strict-contactv2)
and the existing root/device credential, SHA256, canonical encodings and LP
transcript: each UTF-8 field has its existing 4-byte big-endian byte-length prefix.
Contact fingerprint binds the original credential/bundle/fallback. Verify full
root signature, derived account, original Olm binding, device-auth contact
signature, realm/SPKI and canonical keys before admitting its authority.

Let low/high be the two distinct validated endpoints sorted lexicographically
by full account ID. SHA256 outputs lowercase hex:

```text
channel = SHA256(LP("paranoid-first-contact-channel-v1",
  low.account, low.device, low.credential.fingerprint, low.contact.fingerprint,
  high.account, high.device, high.credential.fingerprint, high.contact.fingerprint,
  realm, SPKI, "account-id-intro-v1"))
```

Local values must equal the retained local identity/contact. An existing remote
account must equal its immutable credential/device/auth/original bundle/fallback
pin. No key replacement, random epoch, negotiation, legacy label heuristic,
trial-decryption profile choice or retry under an alternate context is allowed.
Both crossing senders derive exactly the same channel and retain both legitimate
Olm sessions within that channel, subject to the shared session budget.

Transport ciphertext is byte **2** followed by strict UTF-8 JSON; decoded total
length at most 16384 bytes. Required fields are exactly:

- `type`: `paranoid-sender-intro-v2`;
- `contact`: strict signed sender ContactV2 object;
- `recipient_account`, `recipient_device`, `recipient_credential`,
  `recipient_contact`: exact local recipient account, device, credential and
  contact fingerprints;
- `id`: canonical envelope UUIDv4 matching the server transport ID;
- `profile`: exactly `account-id-intro-v1`;
- `channel`: exact deterministic lowercase SHA256 above;
- `ciphertext`: canonical padded standard base64 of the inner Olm frame (0/1);
- `signature`: canonical unpadded device-auth Ed25519 signature.

The signature transcript is:

```text
LP("paranoid-sender-intro-v2", sender_contact_fingerprint,
  recipient_account, recipient_device, recipient_credential_fingerprint,
  recipient_contact_fingerprint, id, profile, channel, SHA256(decoded_inner_frame))
```

Server-reported sender must equal signed sender account. Verify exact recipient,
ID/profile/channel and envelope signature before treating metadata as authenticated.
Reject duplicate/unknown fields recursively, malformed/noncanonical base64 and
keys, nested frame2, experimental intro-v1 and every bare frame at this new entry.
Raw encoded frames/contacts stay strings through Java so JSONObject cannot erase
nested duplicate fields. A bounded native routing peek does not confer authority;
strict typed raw parsing is still required before cryptographic acceptance.

All newly created text **and receipts** require this wrapper even after trust
verification. Only core-generated fresh encryption for the selected immutable
recipient/channel may be signed. Persist exact full frame2 before its first
network send. Never rewrap/re-sign an existing pending or server-accepted ID.
Server v2 POST/GET schema and immutable `(sender,id)` idempotency are unchanged;
16 KiB remains the decoded opaque transport limit.

## Encrypted PlainV1 and genuine receipt target

PlainV1 is strict JSON containing exactly `v`, `channel`, `realm`, `from`, `to`,
`id`, `kind`, `body`. `v` is integer **1**; channel is the deterministic value;
realm/from/to/id must exactly equal authenticated channel and transport context.
`from`/`to` are full account IDs, never original bundle labels. No v0/v1 fallback
is permitted. Wrapper stripping cannot produce valid new-channel input and the
historical decoder still demands v0.

For `kind: "text"`, body is a nonempty string of at most 2048 UTF-8 bytes. For
`kind: "receipt"`, body is a strict object with exactly:

```json
{
  "target_channel": "<same channel>",
  "target_sender": "<local original text sender account>",
  "target_id": "<canonical original text UUIDv4>",
  "target_inner_digest": "<SHA256 of original decoded inner Olm frame>"
}
```

Receipt has its own UUID and signed wrapper. Match every target field to the
retained outgoing text commitment, including after server acceptance retires
its pending envelope. Unknown target, other sender/channel/id/digest or wrong
body kind is rejection and cannot allocate an unknown peer. Delivery means
committed peer plaintext, not reading, real-world identity or generic HTTP/core
success. Accepted receipt queues no reply receipt; duplicates do not loop.

## Atomic state, replay and quotas

Core schema **3** contains one retained `legacy` Client/Olm Account identity
holder and clean-channel state; adapters never persist another private Account.
The pristine local identity creation path can enter schema3. Historical core2
and populated v0/v1 inputs fail clearly without modification/reset/migration.
Android uses sealed outer snapshot **4** and explicitly validates core3;
unsupported old snapshot bytes and saved TLS trust remain intact on refusal.

Process one event per complete candidate. Verify cheap lengths/routing/block,
then signatures/pins, then transient peer creation and actual Olm decryption.
Only an explicit accepted text or known-target receipt can commit Account,
contact, ratchet, history, commitments, outbox, accepted replay ledger and cursor.
A generic command success does not mean acceptance. Invalid ciphertext, wrong
PlainV1, unknown receipt or any quota/snapshot failure must discard the **entire**
candidate, including shared Account/prekey mutations and allocated peer. Bounded
classified rejection metadata and forward cursor progress may be applied only
to the original state. Block suppresses plaintext and receipts.

Peer trust is exactly `network_unverified` or `out_of_band_verified`. Valid first
incoming text creates the former and is immediately replyable. Exact same-key
explicit QR comparison upgrades only trust; it cannot repin, reset sessions,
change channel/history, lower cursor or automatically replay old rejections.
Block is orthogonal: preserve pins/history, use the same channel on unblock.

Replay key is `(sender_account,id)`, with server sequence, channel/profile,
exact outer SHA256, inner SHA256, accepted status and receipt bookkeeping.
Exact retained key/sequence/bytes is a no-op, including reload. Changed bytes,
channel, bindings or sequence conflicts before decryption. A retained sequence
cannot name another event. New below-cursor events are refused; exact retained
duplicates are allowed. Sequence is relay ordering, not cryptographic freshness;
server suppression/reordering is still possible.

At most 64 peers and 16 `network_unverified` peers; no slot multipliers or
history/session eviction. Per peer: 400 pending envelopes, 8 sessions, 1000
accepted replay IDs and 1000 retained receipt commitments — the commitments are
what refuse a further text send once they accumulate. Conversation history has no
entry ceiling in this candidate
([RFC-0022](../rfcs/0022-unlimited-conversation-history.md), `proposed`, which
supersedes the 200-entry development limit of RFC-0008 and is not an accepted
decision until its ADR); a long history is bounded by the snapshot instead.
Snapshot at most 8 MiB; native request at
most 65536 bytes; decoded wire at most 16384; Java sync pages at most 20 events.
Blocking applies to existing immutable peers and is stored on those peer records;
there are no delete/readd or independent unknown-account tombstone allocations.
An unknown-account block request is refused. Thus at most 64 peers can be blocked,
with no eviction or separate quota multiplier. Check all limits after
decryption/receipt construction as well as before allocation.
These budgets bound local growth; they do not provide Sybil resistance/fairness.

Java seals/fsyncs/readback-validates the full candidate before adopting UI or
sending any pending frame/receipt. A failed or ambiguous save freezes the process
and transmits nothing from that candidate. Existing encryption-at-rest only
protects keys/plaintext when platform sealing succeeds; raw state must never be
logged. Outgoing acceptance matches exact pending ID; retained receipt-target
commitment survives pending removal. Exact retries reuse original frame2 bytes.

## Validation and compatibility limits

The clean suite must test genuine first-contact plaintext/reply/receipts with
zero receiver contacts, new/new and crossing, fresh registration without an
operator, real persisted reopen, signatures/context/strip negatives, unknown
receipt no allocation, duplicate/reload/conflicts, budgets/block and whole-state
post-decryption rejection. JVM/JNI must run against a real generated pinned-TLS
certificate and isolated PostgreSQL plus the exact retained server bundle locally.
Mocked JNI/server responses do not satisfy that gate.

Historical tests remain present and their real results run/report separately;
old retained-context migration/recovery failure is not fixed by this contract.
No live bundle replacement, phone wipe/install, server database reset, SSH,
upload or publication is authorized here. Independent implementation review is
required before candidate delivery. Physical phones and production guarantees
are outside the local test evidence.
