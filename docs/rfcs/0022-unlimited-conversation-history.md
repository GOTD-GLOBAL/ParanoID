---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-09-24
required_reviewers: []
last_reviewed: 2026-09-17
---

# RFC-0022: Conversation history without an entry ceiling

## Problem

A conversation stopped at 200 entries. The core refused the 201st text on send
(`clients/core/src/clean_service.rs:401`), refused it again after decrypting it
on receive (`:557`), and refused to open a stored snapshot that held more than
200 entries at all (`:255`); the legacy profile carried the same two refusals
(`clients/core/src/lib.rs:388,613`). Nothing in the clients warned that the wall
was coming, and nothing explained it once it arrived: a send failed with a
generic sentence and an inbound message became a capacity notice, while the
server kept the ciphertext the recipient could no longer see.

The owner's direction on 2026-09-17 is that there is no message ceiling.

## Decision this RFC proposes

Remove the per-conversation history ceiling in both profiles. The refusals that
bound network and replay state stay exactly as they are: 400 queued envelopes,
1000 receipt commitments, 1000 seen identifiers, eight sessions, 64 contacts,
2048 UTF-8 bytes of text.

Two refusals still stand between a conversation and unbounded growth, and this
RFC keeps both. A text send is refused once 1000 retained receipt commitments
have accumulated for that peer — the `local_history_full` code now means exactly
that and nothing else — and a commit whose snapshot would exceed 8 MiB is refused
as `local_state_full` (`snapshot_size`). What this RFC removes is the ceiling on
the **count of stored entries**, not every bound; question 2 below is whether the
commitment ledger should move with it.

This supersedes the 200-entry development limit of
[RFC-0008](0008-executable-text-development-slice.md) for the conversation
history. RFC-0008 is not rewritten and every other budget it names is unchanged.
`docs/protocol/first-contact-v1.md` and `docs/security/threat-model.md` describe
this candidate and say that it is proposed rather than accepted.

No wire format, no server route, no schema column and no sealed-snapshot field
changes. The snapshot's *contents* may now be larger than a previous build was
willing to open, which is the whole of the compatibility question below.

## Why this is not a quiet constant change

The ceiling was enforced inside snapshot validation, so it decided which stored
states are valid. Three consequences follow, and all three are for the decision
owner rather than for an implementer:

1. **Downgrade is a freeze, not a degradation.** A phone that passes 200 entries
   on this build and is then rolled back to an older one cannot open its own
   state: validation refuses it as `invalid_state`, which the clients surface as
   the unsupported-snapshot path. Keys and history are not deleted, but the
   installation stops until it is updated again.
2. **A mixed pair loses messages silently.** A sender on this build can push a
   receiver still on the old one past its ceiling. That receiver rejects the
   message after decrypting it, sends no receipt, and advances its cursor past
   the event; the sender remains at server acceptance (one mark), not peer
   delivery, and the text is not shown on the old receiver. Both phones must
   be updated together.
3. **The binding constraint moves.** 64 conversations of 200 maximal messages
   already exceed the 8 MiB snapshot bound, so a heavy account now meets the
   commitment ledger or the snapshot bound rather than a count of entries. The
   snapshot refusal arrives on a commit rather than on a message, which is a
   worse moment; bounding it belongs to a separate decision about eviction or
   archival, which `docs/protocol/first-contact-v1.md` still forbids.

## Cost this does not remove

Every committed operation re-serializes, seals and rewrites the whole snapshot,
and every inbound message deep-copies the state before applying anything. Both
costs grow with the history. The Android chat also re-inflates every bubble on
each publish (`MainActivity.renderHistory`), which a very long conversation will
make visible before any correctness bound does; the iOS chat is already
virtualized. Windowing the Android history is follow-up work, not part of this
change.

## Tests

`clients/core/tests/clean_first_contact.rs` now asserts that a snapshot far past
the retired ceiling loads and that real decrypted text is still committed and
visible; the receipt-outbox capacity refusal it shared a table with is unchanged
and still asserted. `clients/core/tests/sync_recovery.rs` asserts the same for
the legacy profile and that a later delivery receipt still applies to an older
own message. The 8 MiB snapshot refusal keeps its own test.

## Alternatives considered

* **Raise the number.** Any number is either far below the snapshot bound (and
  therefore still a wall people hit) or above it (and therefore not the real
  limit). It also carries the same downgrade and mixed-pair consequences.
* **Evict old entries.** Rejected by the protocol documents as they stand, and a
  larger product decision: it changes what "history" means on a device.
* **Bound in the clients instead.** The clients cannot refuse what the core has
  already committed, and a second ceiling in two places is the drift this
  repository's tests exist to prevent.

## Open questions for the decision owner

1. Accept the downgrade freeze for the closed alpha, where both phones are
   updated together?
2. Should the 1000-commitment bound move with this, given it shares the
   `local_history_full` error and caps an effective conversation length anyway?
3. Is eviction or archival now on the roadmap, given that history shares the
   8 MiB snapshot budget with every other conversation and the commitment
   and replay ledgers still impose their own limits?
4. For the accompanying local call-log UI, should iOS call records **and local
   contact names** move from UserDefaults to backup-excluded container files,
   with reviewed migration/failure behavior, or is the documented OS-backup
   exposure acceptable for this alpha? See the [client limitation](../clients/ios/self-service.md#local-names-and-call-log-backup-limitation).
   This is an unresolved privacy/storage decision, not a migration approval.
