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
  `completeUntilFirstUserAuthentication`, 4 MiB read ceiling.
- The commit sequence is the snapshot's, for the reason the snapshot has it:
  write the candidate, **set the backup flag on the candidate before the
  rename** because the flag lives on the inode the rename moves, `F_FULLFSYNC`,
  `rename(2)`, read the committed file back and compare it byte for byte, read
  the flag back from the committed name, `F_FULLFSYNC` the directory.
- A file that cannot be proven excluded is **removed**, not kept. A table this
  build promised to withhold from a backup is not left behind for the next one.
- One shared `LocalMetadataStore` implements this once for both tables.

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
