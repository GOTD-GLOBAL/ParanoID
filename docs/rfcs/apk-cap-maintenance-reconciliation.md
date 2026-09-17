---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# RFC: one-off audited APK-cap maintenance reconciliation

## Owner direction and scope

Sergey Maltsev explicitly instructed: “По серверному пакету чекни, что нужно
сделай. Надо развернуть” after being told the installed coordinator blocked
config/cert/unit drift. This authorizes checking and repairing this specific
maintenance mismatch before the same-data server update. No original Telegram
permalink is available. This is a scoped private-alpha operation under ADR-0003,
not a permanent architecture acceptance or a generic accept-drift capability.
REQ-MSG-004, REQ-DEPLOY-002/003 and RFC-0013 remain applicable.

## Evidence and bounded proposal

Read-only audit compared the original transaction's `config.before`/`unit.before`
with the currently running installation. Both before-file hashes exactly match
recorded identity. Current JSON differs ONLY by `push: {v:1, provider:fcm}`; the
unit differs ONLY by the known fixed LoadCredential line. Removing that key/line
reproduces the original config/unit identity. The old certificate matches the
original transaction; the new certificate hash exactly matches the accepted
operation evidence in `tls-renewal-2026-09-13.md`. Release, package manifest, PG
identifier, private-key hash and SPKI match the original. No secret material is
exported. This establishes the complete observed three-field delta, not merely
permission to ignore a mismatching hash.

Use a one-off, exact-state-hash-bound reconciliation script, not an alternate
updater and not a changed status check. Acquire the coordinator operator lock and
message maintenance lock, rerun current worker preflight/loaded-unit checks and
all unchanged coordinator network/system-artifact checks. Require precisely the
three approved target fingerprints and all proof comparisons before any write.

Preserve exact original current-pointer and transaction-journal bytes as immutable
private before-images with checksums. The mutable current pointer and matching
active transaction journal receive only the three current identity values and an
explicit maintenance-adoption annotation referencing that preserved provenance.
Their original plan/acceptance/transaction IDs and all other fields remain intact;
annotation distinguishes later maintenance from the original apply result. Do
not claim the original acceptance receipt approved new values. No old archived
record, runtime file, TLS material, config, service unit or database is modified.

Audit images are written/fsynced under exclusive private temporary names and
published with Linux renameat2(RENAME_NOREPLACE), so final image names never expose
partial bytes or replace an existing image. Incomplete preparation can resume
from live files only while BOTH still equal the exact pinned original bytes;
unknown or tampered final images still stop. Private orphan staging files from
abrupt termination are not authoritative before-images.

Both metadata files are replaced atomically from durable before/after images.
A crash between their replacements is recoverable only when each file equals its
exact recorded before or after image and the same live proof still passes; any
third value stops. Resume completes the annotated baseline, never resets runtime
or rolls back a certificate. The original coordinator status then runs unchanged.
The next ordinary update records its own actual before-config/certificate/identity
and preserves current-data rollback. Rolling the earlier historical transaction
back across later TLS maintenance remains fail-closed and is not authorized.

## Threats and review

Risk: laundering unauthorized runtime changes into a trusted baseline. Controls:
exact original-state hash, immutable before-images, exact delta/provenance checks,
unchanged key/pin/PG/release checks, loaded-unit/network verification, two locks,
explicit annotation and independent source/operation review. Unknown drift,
unsafe files, partial foreign writes, mismatched before snapshots or a newer
coordinator transaction must stop. No universal bypass flag or background adopter.
The proof digest commits to the pinned original state, observed identity, kit hash
and fixed check-name list after successful guards. It is not a transcript of
individual observations or independent attestation of execution; safety still
depends on rerunning those guards under both locks before every write.
The dedicated root operator remains trusted; this is not protection against root
compromise. Crash/fault tests use disposable metadata fixtures; no live fault
injection or database reset. Independent review precedes running write mode.

## Subsequent deployment

Build a kit from the reviewed message package and byte-identical retained relay
and coordinator components. Preserve previous acceptance evidence for unchanged
relay components; new design/offline/artifact/final-review gates must reference
fresh actual evidence, not invented PASS. Run original preflight, then same-data
update with its verified encrypted dump/restore and readiness/current-data
rollback controls. The Android v26 public feed and all existing trust remain.
