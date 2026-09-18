---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-09-25
required_reviewers: []
last_reviewed: 2026-09-18
---

# RFC-0024: Local metadata at rest on iOS

## Problem

Two tables on the iPhone say who this phone talks to, and an OS backup carries
both of them off the device.

- `ContactNames` (`paranoid.contact-names.v1`): the account of every contact the
  owner named, and the name they typed.
- `CallLog` (`paranoid.call-log.v1`): for every call this phone watched, the
  peer's account, whether it connected, who ended it, how long it lasted and
  which message it followed.

Neither is message plaintext and neither is sent to a peer or a server, but
together they are the relationship graph of the person holding the phone. Both
live in standard `UserDefaults`, which iCloud Backup and an encrypted local
backup both include. The encrypted state file beside them is excluded from
backup; these are not. So a restore onto a second device — the owner's new
phone, or anyone who can restore that backup — reproduces the contact names and
the call history there, while the messenger's own state stays behind.

`docs/clients/ios/self-service.md` has recorded this as a known limitation since
PR45, deliberately unfixed pending an owner decision, and
`docs/security/threat-model.md` carries the same statement. Android does not
have the problem: its manifest sets `allowBackup="false"`, so the platforms
diverge on a privacy property rather than on a feature.

The owner asked on 2026-09-18 for the iOS side to be closed.

## Decision this RFC proposes

Both tables move out of `UserDefaults` into files in
`Application Support/paranoid/`, next to the encrypted state file, each excluded
from OS backup on its own inode.

- `contact-names.v1.json` and `call-log.v1.json`, owner-only, data protection
  `completeUntilFirstUserAuthentication`, 16 MiB read ceiling.
- The commit sequence is the snapshot's, for the reason the snapshot has it:
  remove any candidate an interrupted run left, create the candidate **empty**,
  **set the backup flag on it before a single row is written and before the
  rename** because the flag lives on the inode the rename moves, write the
  table, `F_FULLFSYNC`, `rename(2)`, read the committed file back and compare it
  byte for byte, read the flag back from the committed name, `F_FULLFSYNC` the
  directory.
- A file that cannot be verified or cannot be proven excluded is **removed**,
  not kept. A table this build promised to withhold from a backup is not left
  behind for the next one.
- One shared `LocalMetadataStore` implements this once for both tables.

The ceiling is set by the largest table the product itself admits, not by a
guess: core contact admission stops at 64 conversations
(`clients/core/src/clean_service.rs:365`) and the log keeps 500 rows per
conversation, which encodes to about 7.1 MiB. A ceiling below that would refuse
a legal table, so the pre-upgrade log would never migrate and would stay in the
backup-eligible preference for ever — the opposite of this RFC's purpose.

### Migration

A phone updating from an earlier build still has the preferences. On the first
launch that reads a table, the store writes the old value into the new file,
and clears the preference **only after** that file has been committed, read back
byte for byte and proven excluded. Every other outcome keeps the old value, so
an interrupted or failed migration repeats on the next launch instead of losing
the names. A preference holding nothing this build would keep is cleared
without writing a file, because an unusable old value is still a value a backup
carried.

### Failure semantics

Nothing here throws into a screen, and no failure freezes the client. These
tables are a convenience: a phone whose disk refuses the write still opens the
chat, shows the messages the core committed and places calls, with the table
live in memory for the rest of the run. This is deliberately **not** the
snapshot's rule, where a failed commit is terminal — the snapshot holds the
ratchet, and these hold labels.

But a convenience may not destroy itself, and three rules exist because the
first implementation of this RFC broke exactly that (PR47 review, 2026-09-18):

- **A file that exists and will not open is not an empty table.** When the read
  fails and no preference stands behind it, the store *seals*: every later write
  and the removal are refused for the life of that instance, so the empty table
  its caller had to start from never replaces the one nobody could read. A later
  load that succeeds unseals it. Where a preference does stand behind the file —
  only possible while a migration is unfinished — that preference is the
  authority and is used instead.
- **A committed, byte-exact, provably excluded file is kept even if the
  directory sync then fails.** That sync makes the rename durable; losing it
  answers `false` and keeps both the file and the preference, because the
  preference is the copy that would survive a power loss there. It is never a
  reason to delete the only copy that is left.
- **A preference dies only against proof.** It is retired after a full commit,
  or after a read that both parses for its caller and proves the file excluded —
  never merely because some bytes came back. A file that this build cannot parse
  counts as absent, so a corrupt file beside a good preference is replaced by it
  rather than mistaken for an empty table.

An adversarial pass over that revision on the same day found three more, and
they are closed the same way:

- **Only a proven failure deletes.** Bytes that come back different, or a backup
  flag that reads definitely false, are evidence the committed file is wrong,
  and it goes. A verification step that merely *throws* proves nothing — and by
  then the rename has already unlinked the copy it replaced, so deleting would
  destroy the only table there is. This is the directory-sync rule one line
  further on, and it was missed the first time.
- **A preference is never written back over a file that will not open.** Once a
  save can legitimately keep both copies, the preference may be *older* than the
  file, so the unreadable-file case seals in every shape: the old copy is shown,
  and nothing is written.
- **Emptying retires the preference first.** It is the backup-eligible copy and
  the one a later launch would resurrect an emptied table from, so it goes
  before the file and unconditionally, not after a directory sync that may fail.

Two behaviours are deliberate rather than defects, and are stated here so that
they are reviewed as decisions:

- **A file that opens but does not parse is replaced, not sealed.** It is
  unreadable to every build of this generation, so sealing would trade a
  recoverable state for a permanent one: the owner could never store a name
  again on that phone. Where a preference stands behind it, that preference is
  used and the file is rewritten from it.
- **A seal lasts the process.** The instance unseals on a later successful load,
  but the application builds each store once, in an `AppModel` property
  initializer, so in practice the next launch is the recovery. The table stays
  live in memory for the run; nothing is shown as lost and nothing is written.

One known deviation is recorded rather than fixed here: both tables are property
initializers on `AppModel`, so they load — and may migrate, which writes a file —
before `start()` decides `.noStand`. That path documents leaving the device as it
found it. Closing it means making the two tables lazy, which is a change to the
model's lifetime rather than to this storage rule, and is left for the owner to
direct.

## What this is not

It is not application-level encryption. The bytes are plain JSON inside the
container, exactly as the preferences were; what changes is that a backup no
longer takes them. Anyone with container access still reads them, as they read
the preferences before.

The snapshot's wrapping key is deliberately not borrowed. It is created by the
first commit and lives behind the Keychain continuity rules of
`SnapshotStore`, so sealing these tables with it would make a frozen or absent
key stop a chat from drawing its own contact's name — a worse failure than the
one being fixed, and a new way for storage state to break the interface.
Sealing the two files is a separate decision, stated as question 2 below.

## Scope

In scope: the two iOS tables above.

Not in scope, and unchanged:

- `ReceiptHint` (`paranoid.receipt-hint.v1`) stays in `UserDefaults`. It is one
  boolean — whether the owner has dismissed the sentence explaining the two
  marks — and it names no contact and no call. A backup that carries it
  discloses nothing about who the owner talks to.
- Android, which already excludes the whole application from backup.
- The core, the protocol, the server, and the encrypted snapshot. No wire
  format, route, schema column or serde profile changes; the core is not
  involved in either table.

## Alternatives considered

1. **Keep the preferences and accept the limitation.** It is already written
   down, so nothing would be hidden. Rejected because the product's own claim
   is that a local name is local, and a backup breaks that claim silently, on a
   device the owner may no longer control.
2. **Seal the files with the snapshot's wrapping key.** Stronger at rest, but it
   couples a label to the Keychain continuity rules and lets a frozen key blank
   the names. Deferred to question 2 rather than refused.
3. **Move both tables into the encrypted core snapshot.** It would inherit the
   backup exclusion and the encryption at once, but it puts presentation state
   into the core's serde profiles, needs Android parity and changes a red-zone
   component for a label. Refused for this candidate.

## Privacy delta

After this change, an iCloud or encrypted local backup of the iPhone contains
no contact name, no peer account from the name table and no call outcome,
direction, duration or anchor. Container access, device compromise and the
owner's own phone are unchanged — this closes the backup path only.

No physical backup/restore experiment on a device is claimed. The evidence is
the host test suite: the flag is asserted on the committed file and on the
directory through the real file system, the call order is asserted against an
in-memory one, and a file system that refuses to confirm the flag is asserted to
leave no file behind.

## Compatibility

A build of this generation reads an older installation's preferences once and
migrates them. An older build installed over this one would find its
preferences gone and start with default labels and an empty call log; the files
are not read by it. No snapshot, key, account or protocol compatibility is
affected.

## Owner direction and remaining decision boundary

The owner asked for the backup exclusion. This RFC proposes how, and the code
implementing it is available for review, but nothing here is an accepted
privacy guarantee: acceptance of the storage rule, and of the answers to the
questions below, remains the decision owner's. The threat-model and iOS client
statements are updated to describe what the code now does and to keep the
decision open, not to claim it is settled.

## Questions

1. Is the backup exclusion of both tables accepted as the rule, replacing the
   recorded limitation?
2. Should the two files additionally be sealed, and if so with which key —
   given that reusing the snapshot's key lets a frozen key blank the names?
3. Should a future account-delete or device-reset path be required to clear
   these files explicitly, and where should that requirement live?
4. Does `ReceiptHint` stay in preferences, as this RFC proposes?
