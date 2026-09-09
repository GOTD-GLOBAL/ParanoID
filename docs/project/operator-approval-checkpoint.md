---
status: draft
owner: maintainers
last_reviewed: 2026-09-09
---

# Operator-approved alpha: archival checkpoint

This checkpoint preserves the existing experimental Android/server implementation,
its tests, proposed contracts, independent review reports and rollout evidence.
It is **not the desired product onboarding and must not be merged wholesale into
main as a completed messenger**. Preserving a commit is not architecture acceptance.

The owner explicitly approved preservation in a separate remote archive branch,
then a separate self-service-registration workstream. The replacement product
intent is [REQ-ID-008](../product/requirements.md#default-server-self-registration-correction-2026-09-09):
create an ID in the app, register automatically on the common default server, add
a contact and message without operator approval, admission JSON or SSH.
Blockchain registration is later, separate from ongoing message transport.

## What is preserved and what must change

Reuse after appropriate adaptation: client-owned keys and proof of possession,
Olm encryption, encrypted snapshots, durable delivery/receipts, retry/dedup,
pinned TLS, Linux packaging, backup/restore and regression tests. Replace the
manual grant/onboarding path and fixed two-slot/one-room assumptions; simply
removing an approval check would not create safe general registration.

The current prototypes and their historical proposed ADRs remain visible so their
limitations and deployment history are not lost. Their retention does not endorse
them as the new design. New identity/admission/persistence changes still need
scoped contracts, threat analysis and review; no broad research restart is implied.

## Artifact provenance and limits

The [rollout record](../operations/key-rollout-2026-09-09.md) identifies the last
executed server artifact `007fd1812c0dbba9a489`, archive SHA256
`36bbd35237a34d314cefd130e562a84dd6803f2cf240d464dfccd1c4cd090df4`.
[The focused ALPN review](../reviews/2026-09-09-alpn-review.md) is preserved with
the earlier auth/deployment reviews. The artifact's original manifest truthfully
contains the pre-checkpoint base commit and
`source_dirty: true`; this archival commit does not rewrite that history or claim
that a merged main commit was deployed. The final ALPN review links the exact
runtime payload to the reviewed source; no production-ready or physical-phone
messaging claim is added by preserving this tree.

Signing keys, TLS/SSH private keys, live configuration/tokens, actual phone request
or grant descriptors, database data/dumps and generated build outputs remain
outside Git. Fixed public cryptographic test vectors are synthetic test data,
not real device secrets. This preservation task performs no deployment, database
mutation, permission change, key regeneration, uninstall or merge.

Future product changes belong in a separate feature branch and PR. Validate the
actual no-operator two-user flow, review, merge with human permission, then build
and deploy an identified commit rather than an uncommitted working tree.
