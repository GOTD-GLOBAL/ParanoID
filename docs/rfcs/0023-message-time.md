---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-09-24
required_reviewers: []
last_reviewed: 2026-09-17
---

# RFC-0023: When a message happened

## Problem

Nothing in this product says when anything was said. A conversation is a column
of bubbles with no time on them, no separator between days and no date in the
list of chats, so a message from three weeks ago and one from a minute ago read
the same. The reason is below the interface: the core's history entry is
`{id, author, text, accepted, delivered}` (`clients/core/src/lib.rs`) and the
server's row is `{sequence, sender, recipient, message_id, ciphertext}`
(`server/self-service-schema.sql`). Neither keeps a time, so no screen can show
one without inventing it, which `REQ-CLIENT-004` forbids.

The owner asked for the time of a message on 2026-09-15.

## Decision this RFC proposes

A history entry gains `local_ms`: milliseconds since the epoch, **as the client
that wrote or received it read its own clock**.

- The core reads no clock. The value arrives with the operation — `send_v2` and
  `receive_v2` gain `now_ms` — and is stored verbatim. This is the trust model
  the call controls already use for `sent_ms` (`clients/core/src/voice_v1.rs`).
- Zero means unknown. Every entry written before this build has none, and the
  screens show nothing for it rather than a guess.
- The field is local. It is not in any envelope, not in `PlainV1`, not in a
  receipt and not in a server row; the peer is told nothing new and the server
  sees exactly what it saw before.
- The clients read it as: the time under a bubble (`14:32`), a pill where the
  day turns («Сегодня», «Вчера», «12 сентября»), and the date on a conversation
  row (the time today, «Вчера», then `12.09`). A call preview has no timestamp
  of its own and therefore shows no date borrowed from the previous message.

What this deliberately is **not**: the sender's time on the receiver's screen.
A receiver stamps with its own clock, so the two devices can disagree by
whatever their clocks disagree by, and a phone with a wrong clock mislabels only
its own copy. Carrying the sender's instant would mean a new in-band field and a
second decision; it is out of scope here and named in the open questions.

## Compatibility

`Entry` is `deny_unknown_fields`, so an older build cannot open a snapshot that
carries `local_ms`, exactly as with the retired history ceiling
([RFC-0022](0022-unlimited-conversation-history.md)). Both phones of the closed
alpha must be updated together. Nothing else changes: the wire, the server
schema, the receipts, the sequence and the cursor are untouched, and a build of
this generation opens an older snapshot unchanged — the entries simply have no
time.

## Privacy

The sealed snapshot now holds a timeline: not what was said and to whom, which
it already held, but when. On a compromised or seized device that is more
information than before. It stays inside the same encrypted state file, with the
same protection, and it is not transmitted to the peer or relay. The local call
log added in PR45 stores outcomes, durations and message anchors, not wall-clock
times. This candidate therefore adds a new durable message timeline; the call
log is not evidence of an existing timestamp-storage boundary.

## Tests

`clients/core/tests/clean_first_contact.rs` asserts that a sent message carries
the clock the client passed, that the receiver stamps with its own, that the
envelope still has exactly three members, and that the value survives a reopen;
it also asserts that a history written without the field opens and stays without
one, while a message sent afterwards gets its own. The clients' formatting has
its own tests on both platforms, each pinning a time zone so the rule — the
phone's own zone — cannot be read differently by the machine that runs them.

## Alternatives considered

- **The server's time.** It has none to give: the row carries a sequence, not a
  clock, and asking the server for one would make it an authority on ordering.
- **The sender's time, in band.** A real improvement for a conversation, and a
  new field in the encrypted body: a separate decision, and it makes a wrong
  clock on one phone visible to the other.
- **Nothing at all.** What we had; the owner asked for the opposite.

## Owner direction and remaining decision boundary

On 2026-09-17 Sergey Maltsev selected client-local timestamps and accepted the
alpha client downgrade incompatibility with coordinated phone updates:
[recorded exact directions](https://github.com/GOTD-GLOBAL/ParanoID/pull/45#issuecomment-5715733752),
also linked from [PR46](https://github.com/GOTD-GLOBAL/ParanoID/pull/46#issuecomment-5715736976).
The original Telegram permalink is unavailable. These settled product choices
are not open questions to ask again, and this relay is not permanent ADR
acceptance evidence under the documentation policy. RFC-0023 remains proposed.

The sender's instant travelling in band is not requested by that choice; any
future proposal needs its own contract review. The sealed local timeline retains
the device-compromise risk above. No key/history reset, phone installation,
publication or server action follows from source integration.

The same owner message requests backup exclusion for iOS names/call logs and
long-lived history beyond cumulative ledgers/snapshot limits. Those are separate
protected persistence follow-ups, not implemented by this timestamp PR. Existing
1000-entry replay/commitment and 8 MiB snapshot safety bounds remain; this PR must
not be called an implementation of unlimited lifetime history.
