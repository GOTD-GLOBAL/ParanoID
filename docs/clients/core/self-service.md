---
status: draft
owner: client
last_reviewed: 2026-09-09
---

# Self-service client compatibility proposal (issue #16)

Companion to [RFC-0012](../../rfcs/0012-self-service-messenger.md). Written before
client implementation. This is a local candidate proposal, not an accepted ADR,
production crypto adoption, rollout authorization or physical-phone evidence.

The later [voice extension](voice-calls.md) retains the current core3 text state
and documents its actual old/current JNI compatibility checks separately. It
does not implement the historical migration proposal below.

## Active clean-install candidate (RFC-0014)

The owner's 2026-09-09 scope amendment selects mandatory signed account-ID channels
for all new text/receipts with zero-contact incoming plaintext/reply. See
[the exact new protocol](../../protocol/first-contact-v1.md), proposed
[ADR-0009](../../decisions/0009-clean-first-contact.md) and [current-state](../../project/current-state.md).
This candidate uses core schema3, one retained `legacy` Account identity holder
and new channel sessions/trust/commitments; Android sealed outer schema4 explicitly
requires core3. Unsupported older snapshots fail clearly without replacing their
bytes. Historical migration and old-message recovery are outside this build's gate.

Trust is `network_unverified` on authenticated first-contact text;
`out_of_band_verified` requires exact same-key QR comparison. Immediate plaintext,
reply and wrapped channel-bound receipts require no recipient approval. No new
peer survives invalid ciphertext/unknown receipt/capacity rejection; full Account
and peer state roll back together. Persist immutable frame2 outbox and complete
candidate before UI/network; retain outgoing receipt target after server acceptance.

The canonical strict ContactV2 definition below remains reused unchanged. Every
new text/receipt instead uses intro-v2 and strict PlainV1, regardless of bundle
labels or trust status. Historical context/adapters below remain historical code
and separate tests, not the current clean receive dispatcher. Their existing
asymmetric retained-context failure is not fixed or hidden by fresh-state tests.

## Historical v2 compatibility experiment (prior scope)

The remainder records the earlier core2 migration experiment, its exact contact
format and dated tests. Its migration, unknown-contact deferral/rewind and
hosted-v1 statements describe that earlier work only. They do not override the
clean-install protocol above or assert the live endpoint's present version.

## Narrow recommendation and impossibilities

The archived client has one Account, one published one-time prekey and one peer.
Simply making peer/session vectors larger fails after another peer consumes that
prekey. Copying the Account into each conversation would intentionally reuse a
one-time secret and is NOT proposed. Rotating the credential's original prekey
binding would change the installed signed credential; generating a new root is
forbidden. Reusing consumed keys or resetting sessions to make a test pass is not
an acceptable compatibility bridge.

Propose one retained shared vodozemac Account and separate conversation ratchets.
Add a **vodozemac fallback key**, generated and persisted once, for *new* v2 QR
contacts. Its reusable-prekey semantics are explicit, not disguised one-time
keys. A v2 contact carries the unchanged root credential and original bundle
binding PLUS the current fallback public key, all bound by a new device-signed
`paranoid-contact-v2` transcript. Verify the original credential/Olm digest and
signature before trusting the fallback. Never rotate the credential or replace
an existing pinned peer. This is the smallest implementation using the library's
existing Olm protocol rather than a new interactive invitation protocol.

**Threat delta:** a long-lived fallback secret has weaker initial forward secrecy
than independently consumed one-time keys; compromise can affect sessions begun
with that fallback before ratchet deletion. This is an explicit candidate tradeoff
requiring protected-domain review/owner disposition, not a production claim.
An expiring per-pair invitation/prekey exchange is a future alternative, not an
invisible implementation assumption. QR is not a public directory; users compare
full fingerprints over a trusted channel. One device per account remains a limit.

## State and migration contract

- Keep Android package `org.paranoid.devtext`, signing certificate, `text-state.enc`,
  SnapshotCodec, and `paranoid-text-state-v0` Keystore alias. Saved HTTPS origin
  and SPKI override defaults. No uninstall, data clear, trust bypass or new alias.
- At `upgrade_v2`, retain old Client fields verbatim. A versioned outer multi-contact state contains
  the entire legacy Client and new conversations, not a guessed lossy conversion.
  Legacy root/auth/Olm keys, peer pins, history, sessions, seen IDs, cursor and exact
  ciphertext outbox survive. New fields are rejected by old strict decoders.
- Legacy conversations retain their encrypted `alice`/`bob` from/to context.
  Wire routing maps only to the verified peer credential's account ID. Do not
  rewrite ciphertext or acknowledged IDs. Unbound legacy peers must be explicitly
  linked through a verified matching v2 QR before sending on account-ID routes.
- New conversations use account IDs in encrypted context. One shared Account owns
  private prekeys; each conversation owns its own peer pin/ratchets/history/outbox.
  The server inbox fetch cursor is global, not a cursor per conversation.
  `prepare_contact_v2` adds the fallback secret to the same `legacy.account` pickle;
  original identity/signing/prekey material is not replaced. New conversation
  adapters serialize `account: null`: the single shared Account is moved into a
  transient adapter and moved back after successful processing, never cloned into
  independent per-contact accounts. Legacy ratchets remain in `legacy.sessions`.
- State transformations are candidate snapshots. Persist atomically before any
  request using new keys, queued ciphertext, or delivery receipt. Failed/ambiguous
  storage freezes the process. Corrupt or incompatible state gives a visible error,
  never a fresh identity. No automatic history eviction.
- Migration cannot recover a lost wrapping key, missing snapshot, unknown legacy
  root binding or server history that has never been authenticated. Fail closed.

## Invariants and intended executable checks

SS-01 / REQ-ID-005/008: same credential across creation/retry/migration, v2 proof
context substitution rejection, real JVM JNI durable-before-network path.
SS-03 / REQ-ID-007 / REQ-SEC-001: three users, two independent conversations to
one recipient, contact tamper/pin rejection, real Olm text/receipt verification.
SS-04 / REQ-MSG-002/003/004: exact outbox retry, dedup, history/reload, global cursor,
no synthetic delivery checks, no destructive error recovery.
SS-05 / REQ-ID-006: populated legacy snapshot, ratchets and exact queued envelopes
preserved before/after migration, corrupt-state refusal and stable APK signature.
SS-07 / REQ-CLIENT-001: Russian create-ID/contacts/dialog/chat screens, no operator,
grant, raw diagnostic JSON, role or manual trust configuration in ordinary UI.

## Exact client contact and local-state profile

The implemented candidate uses the unchanged server-owned Credential and
ChallengeV2 from [the server wire contract](../../protocol/self-service-v2.md).
Client and server changes belong in separate PRs; the shared protocol library is
an explicit server-PR dependency, not another client-owned protocol definition.

Contact JSON has exactly `type: "paranoid-contact-v2"`, `credential`, `bundle`,
`fallback_key`, `signature`. The bundle is the original `device`, `realm`, `curve`,
`one_time_key`, including historical/unassigned labels. The device-auth signature
and displayed SHA256 fingerprint respectively sign and hash:

```text
LP("paranoid-contact-v2", credential fingerprint, bundle.device,
   bundle.realm, bundle.curve, bundle.one_time_key, fallback_key)
```

Raw QR strings enter strict native serde parsing before JSONObject can collapse
unknown/duplicate fields. Verify root credential, account derivation, realm/pin,
original Olm digest, canonical curve/fallback encodings and the device signature.
The account ID is the dialog key. Exact rescanning is idempotent; changed existing
credential/bundle/fallback pins are refused. There is no automatic fallback
rotation or re-pair-on-decrypt-error. Reusable bootstrap secrecy is a known
tradeoff, not independently consumed one-time-prekey security.

Core state version 2 wraps `legacy`, `enrollment`, `fallback_key`, `legacy_contact`,
`conversations`, a global `cursor`, and an optional `first_unverified_sequence`.
The original version-0 decoder and v1 API remain for migration/compatibility
fixtures. New Android snapshots use outer version 3; versions 0/2 still import.
Old binaries reject this state; rollback cannot mean replacing it with a stale
snapshot or uninstalling the app.

Existing verified peer credentials immediately retain an account-ID route without
readding the contact. A root-unbound legacy peer remains a visible read-only old
dialog until the user verifies a v2 QR with the **same** original curve/prekey and
legacy context. Routing is not guessed. Old pending `id`/`ciphertext` values stay
exact in sealed state; only their exported transport `recipient` changes from a
legacy label to its authenticated account route. Receipts and encrypted from/to
remain in the old profile for that conversation. New conversations use account
IDs inside the existing encrypted Plain/Olm profile.

Unverified inbound senders are not decrypted, auto-pinned or receipted. They
produce bounded visible deferred-event notices, preserving ciphertext server-side
and allowing other dialogs to progress. Adding a verified contact durably rewinds
the fetch cursor to the first deferred unknown-contact event; exact seen-event
checks prevent duplicate display/ratchet changes during catch-up. This is cursor
replay, **not** a crypto/session reset. Other classified malformed/capacity events
retain the inherited bounded-notice behavior and no delivery receipt. Automatic
later recovery of capacity/decryption failures is not promised. Notices older than
the bounded ledger may leave aggregate warning counts after recovery.

Limits: 64 new verified contacts plus a retained legacy conversation, 200 history
entries, 400 queued envelopes, eight sessions and 1000 seen IDs per conversation;
2048 UTF-8 text bytes. Core snapshots are at most 8 MiB. Oversized candidate
snapshots are refused before persistence, not written and then made unreadable.
No eviction/deletion, account recovery, multi-device, attachments, push or iOS is
implemented. Large-history catch-up may take multiple foreground polling cycles.

## Known asymmetric retained-contact defect

The existing profile selection fails when only one endpoint retained the other
original peer. Genuine reciprocal v2 verification does not resolve the encrypted
legacy/account-ID context mismatch. [RFC-0016](../../rfcs/0016-asymmetric-retained-context.md)
records the missing per-pair signal, draft security delta and minimal negotiation
options. No compatibility fix or classified-failure replay is implemented; the
new focused regression intentionally remains RED. Opposite original labels do
not prove a retained relationship. Do not recommend deleting/readding contacts
or promise that rescanning repairs previously rejected ciphertext.

## Actual local evidence

Vertical RED→GREEN tests were executed for missing v2 proof/status, migration,
contact extension, multi-dialog E2EE, legacy consumed-prekey preservation, exact
acceptance, retained verified contacts, damaged state, unknown-contact progress /
after-verification replay, snapshot budget and visible unbound legacy history.
The baseline v0/v1 vectors and tests remain passing. Additional characterization
checks exercise simultaneous crossing sessions through the shared Account and
both rootless/rooted populated migration over the real Linux JVM/JNI boundary.

The Android adapter's actual pinned TLS/PostgreSQL/JVM/JNI fixture registered
three synthetic users automatically, verified QR bindings, exchanged Cyrillic
text and authenticated receipts in two independent dialogs, and preserved
queued messages, encrypted snapshots and IDs across JVM/server restart. Early
runs honestly failed while the separate server lacked its v2 local startup mode;
the complete fixture subsequently passed against the implemented server checkout.

See [Android candidate evidence](../android/self-service.md) for commands,
packaging and limitations. Hosted server remains v1; v2 signup there is unavailable
until separately authorized migration/deployment. Physical-phone tests are
**NOT RUN**. No accepted ADR, commit, push, merge or live deployment occurs here.
