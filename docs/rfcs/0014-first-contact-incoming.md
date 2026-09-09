---
status: proposed
owner: client
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: parent independent code review pending
decision_deadline: before publication or delivery
last_reviewed: 2026-09-09
---

# RFC-0014: Clean-install first-contact text with a signed account-ID channel

## Authority and exact scope

REQ-MSG-005 is the owner-confirmed receive/reply correction. The owner explicitly
selected the first recommendation from the independent design review and amended
the current candidate to fresh app installations, as reported in the current
**2026-09-09 Telegram implementation task** quoted below. The earlier exact
approval message/permalink was not independently retrieved in this context:

> DELIVER implementation + actual built APK candidate for CLEAN-INSTALL first-contact messenger now. User explicitly approved review recommendation and discarded old teststate/migration/recovery as release gates (see context).

The human owner selected the first independent design-review recommendation:
mandatory deterministic signed account-ID channels for all newly created text
and delivery receipts, within the existing bounded private test-data alpha.
Fresh app installations are the acceptance scope. Historical test-message
preservation, migration and exact old-event recovery are explicitly NOT gates
for this candidate. Historical failing tests remain present, run separately and
reported honestly; this scope amendment does not make their bugs fixed.

The owner will uninstall applications himself. This task authorizes local source,
TDD, isolated PostgreSQL/pinned-TLS/JVM/JNI testing and retained-signer APK build
before independent code review. It authorizes no phone action, snapshot reset,
live database wipe, SSH, deploy, upload, publication or delivery to phones.
Unsupported older client snapshots must fail clearly while preserving their
bytes; clean installation is not an automatic migration or reset implementation.
Permanent architecture disposition remains proposed, with independent review
and durable approval provenance still outstanding. No additional permission
question is required for this exact local implementation/testing/build scope.

[ADR-0009](../decisions/0009-clean-first-contact.md) remains proposed, never
accepted by AI. Human decision/risk owner is martadvix-web. This scoped direct
instruction permits implementation/build now; it is not invented permanent
approval evidence, a publication gate pass or production architecture adoption.
The independently reviewed recommendation retains the fallback-key initial
forward-secrecy, transferable device-signature and relay metadata tradeoffs.

Allocation at proposal creation: both worktrees had distinct local RFC-0013
files. Integration on2026-09-09 preserves the asymmetric proposal as
[RFC-0016](0016-asymmetric-retained-context.md) and its old path as an alias; the
updater keeps RFC-0013. RFC-0014 continues to denote this mirrored proposal;
ADR-0009 was unused in both decision directories.

## Selected recommendation and exact contract

[First-contact v1](../protocol/first-contact-v1.md) specifies the new channel,
intro-v2 transcript, strict PlainV1, receipt target, state/replay and budgets.
That specification is written before runtime changes and is still a proposed
private-alpha contract, not an accepted production protocol.

All new text and receipts use mandatory signed frame2 even after verification.
Both endpoints derive the same channel by sorting their immutable ContactV2
endpoints by full account ID. No legacy-label negotiation, trial contexts,
silent repinning or independent per-dialog private Olm Accounts are permitted.
The server v2 API/schema continues to transport immutable opaque ciphertext;
no directory or sender lookup is introduced. Fresh registration retains the
existing root/device proof flow without operators. A genuine recipient QR at
the sender is sufficient for first contact.

Receiver flow:

```text
untrusted bounded frame
  -> strict signatures + exact recipient/channel + immutable pin/block checks
  -> whole-state transient candidate using the single Olm Account
  -> real Olm decryption + exact PlainV1 + genuine receipt target + all budgets
  -> atomic candidate snapshot with pin/history/ratchet/replay/wrapped receipt
  -> persist complete sealed state before UI delivery or any network send
  -> ordinary visible conversation, network_unverified trust, reply enabled
```

Typed accepted/duplicate/rejected results govern candidate adoption. A generic
successful command is not acceptance: invalid ciphertext, wrong inner context,
unknown receipt target or capacity failure after decryption must restore the
entire prior Account/pin/session/history/outbox/replay state before bounded
rejection/cursor metadata. Unknown receipt allocates no peer. Exact duplicates
queue no additional receipt; receipts never produce receipt loops.

## Clean-state compatibility boundary

Use an explicitly new validated client schema. Preserve unsupported older
snapshot bytes and report an error; do not reset, convert, negotiate, recover
old events or consume time implementing historical migration for this candidate.
Fresh-state persistent reopen and exact retry remain mandatory. There is one
shared Account in persistent state and per-peer sessions, immutable credentials,
original bundles and fallback pins; same-key verification changes only trust.

The original review also recommended additive historical lanes/recovery. The
owner's later explicit clean-install amendment removes those implementation
tranches and old-history preservation from this candidate's acceptance scope.
It does not erase historical tests/results, authorize any local/live reset or
claim the old asymmetric context defect/recovery was fixed. Run clean acceptance
and historical suites separately and publish their real exits.

## Security delta and invariant-to-test mapping

| Requirement / invariant | Required clean-candidate evidence |
| --- | --- |
| REQ-ID-005/008 | Fresh registration without operator; unchanged signed root proof; saved-before-request identity; clean persistent reopen |
| REQ-MSG-005, REQ-ID-007 | Zero-contact recipient gets plaintext/reply without click; network_unverified badge; optional exact same-key trust upgrade |
| REQ-MSG-002/003 | Genuine bidirectional text/reply/receipts, new/new and crossing first sends, durable immutable frame2 before network, retained receipt commitment after server acceptance |
| REQ-SEC-001 | Wrong signature, stripped wrapper, valid signature with wrong inner context rejected; immutable pins/recipient/channel; complete-state rollback including post-decryption capacity |
| REQ-MSG-002/003/004 | Exact duplicate/reload no extra plaintext or receipt; sender/id/sequence/bytes conflicts; cursor monotonicity; no delivery from unknown receipt |
| REQ-ID-004 | At most 16 network-unverified and 64 peers, 8 MiB snapshot, existing history/outbox/session/replay/text/frame limits, bounded block suppressing plaintext and receipts |

Signed contact/fallback/device linkage is visible to the relay. Device signatures
make ciphertext origin transferable, unlike deniable Olm alone. Reusable fallback
prekeys have weaker initial forward secrecy than consumed one-time keys. Endpoint
compromise, spam/Sybil fairness, server suppression/reordering and recovery remain
unresolved. See [threat model](../security/threat-model.md#first-contact-incoming-trust-boundary-draft).
No production privacy/security claim is made.

## Historical offline prototype evidence (before the scope amendment)

The following is the exact prior experiment's scope and result. It is not current
clean-install acceptance or an assertion that the old defect is fixed.

Android core now has two explicitly inspection-only operations:
`prepare_sender_intro_v2 {id}` returns a separately constructed `envelope` only
for an exact pending account-ID conversation; `inspect_sender_intro_v2 {message}`
checks bounded framing, signatures, recipient binding and existing pin/profile
conflicts, returning public metadata with `identity_verified:false`. Neither
returns a candidate state. Android transport/UI and ordinary send/receive paths
DO NOT call them. Do not transmit their output for an existing ID: it would change
immutable pending/server bytes. This prototype is not a delivered messaging flow.

Actual strict TDD observed missing-operation RED then GREEN for construction and
inspection, valid signed replacement-fallback RED then GREEN for pinned-peer
refusal, and signed legacy-adapter profile-conflict RED then GREEN. Additional
negative characterization checks cover every signed recipient field, sender/id/
sequence routing, nested credential/contact tamper, duplicate/unknown JSON,
malformed/oversized frames, real alternate Olm ciphertext with stale signature,
repeat/reload inspection and missing/accepted/retained outbox IDs. Correctly signed
outer frames can still contain wrong INNER context: the tests explicitly show
inspection is not decryption or final receive authorization.

Final offline core run: 39 passed, 2 failed, 0 ignored. The six intro tests pass;
the NEW zero-contact plaintext product test and the EXISTING asymmetric retained
bidirectional text/receipt test remain active RED. Assertions for first-contact
reply/receipt/restart/verification are present but NOT reached after missing
plaintext; they are not green evidence. No new acceptance tests were disabled.
No APK, server runtime change, live access or independent-review pass is claimed.

## Delivery gates and experiment status

Strict TDD produces observed RED then GREEN for vertical behavior slices and
retains actual outputs. Required local integration uses the existing Java/JNI
adapter with a real generated pinned-TLS certificate and isolated PostgreSQL,
zero-contact receiver, text/reply/receipt assertions and real persisted reopen.
The exact retained live server bundle is exercised locally for opaque transport
compatibility; no current remote lookup or action is authorized.

Build a unique stable ARM64 candidate from a full source snapshot, package
`org.paranoid.devtext`, versionCode greater than 6 and the retained signer
`82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
Run actual sha256sum/apksigner/aapt verification. The unique local evidence README
records initial/final source hashes and delta, genuine clean/historical exits,
artifact identity and unresolved checks. Independent code review by the parent
is the next gate before any publication or phone delivery. Building before that
review is explicitly authorized. Physical two-phone acceptance remains NOT RUN.
