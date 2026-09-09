---
status: draft
owner: client
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# RFC-0016: Asymmetric retained conversation context — blocked compatibility proposal

Numbering correction2026-09-09: this unaccepted Android proposal formerly used
local RFC-0013, which was also allocated to the server updater proposal.
Integration assigns this proposal RFC-0016; its technical content and blocked
status are unchanged. Historical tests retain their original RFC-0013 comments,
and the old document path remains an alias. This is not decision acceptance.

Companion to [RFC-0012](0012-self-service-messenger.md) and the
[client compatibility contract](../clients/core/self-service.md). This is not an
accepted ADR, implementation authorization for a new crypto protocol, or a phone
fix. The local investigation reproduced the defect on synthetic identities; its
attribution to the owner's phones remains unknown.

## Observed contradiction

A retains B's original bundle and genuine root credential; B has never pinned A.
After identity-preserving v2 migration, A encrypts legacy `alice`/`bob` context.
B verifies A's genuine v2 QR, opens an account-ID adapter, successfully decrypts
Olm, and rejects `context_mismatch`. Unknown-contact deferral followed by scanning
also fails on the same retained ciphertext. Strict rejection is correct for the
selected profile; the asymmetric selection is not compatible.

## Missing information and stop condition

The contact transcript signs the credential fingerprint, original bundle fields
and fallback key. It contains neither a retained peer fingerprint/account nor a
per-pair context profile. Credential `olm` binds curve/prekey, not relationship
history. V2 status and message routing contain no authenticated legacy mapping.

Consider the SAME keys, fallback, QR and receiver B state in two synthetic worlds:

1. A retains the original verified B; compatibility requires legacy context.
2. A has no retained B; A and B start a new v2 conversation, requiring account IDs.

A's signed QR is identical in both worlds. Opposite original labels only establish
that two identities carry those labels, not that they were this retained pair.
B cannot deterministically select the right send/receive profile from these
identical inputs. The same ambiguity exists if A retained some other `bob`.
Hardcoding the real testers or trusting server account counts is not a client
credential-bound criterion. Global legacy eligibility for all opposite labels
silently changes new conversations between upgraded identities and is excluded.

Authenticated plaintext can reveal which context the sender used AFTER decryption,
but using it to select/lock a profile is new in-band profile negotiation, not the
existing exact-context verification contract. It also does not solve B sending
first or crossing initial messages without a reviewed transition rule. Do not
silently add try-both-context acceptance to make the regression pass.

## Minimal options for owner/domain disposition (none selected)

1. **Pair-specific signed compatibility statement.** A retained endpoint produces
   a separately domain-separated statement binding both complete credentials /
   original bundle digests, realm/pin, both account IDs, legacy labels and an exact
   profile version. B explicitly verifies it against its own retained identity
   and already verified A, then durably installs a per-conversation profile.
   Specify acknowledgment, replay/idempotency, conflict refusal and crossing sends.
   Prefer a separate typed statement to changing already pinned v2 QR fields:
   rescans currently require exact contact equality. This adds public relationship
   metadata to the statement and needs a versioned local-state transition.
2. **Authenticated in-band profile handshake.** Specify an explicit per-pair
   negotiation and deterministic conflict policy, defaulting unrelated dialogs
   to account-ID context. No user text/receipt is accepted before profile binding.
   Historical legacy ciphertext could be admitted only through a separately
   reviewed narrow compatibility rule. Extra round trips and old-client behavior
   need specification; decrypt-and-guess is not already such a protocol.

Neither option resets keys, sessions, history or outbox, silently repins contacts,
rewrites stored ciphertext, or requires a server crypto change. Review must decide
whether existing QR authenticity plus authenticated exact original-key plaintext
can safely serve as a restricted bootstrap signal; this task does not accept that
new negotiation architecture.

## Security delta and replay boundary

Assets: verified account/Olm binding, strict realm/from/to/id context, retained
ratchets, exact outbox, delivery truth and rejection/cursor history. Threat actors
include malicious relay, substituted QR and malicious verified peer. Required
controls remain full credential verification, explicit contact confirmation,
exact existing-pin equality and no receipt until authenticated acceptance commits.

- Label-based inference risks cross-conversation profile confusion/downgrade.
- Opportunistic dual-context acceptance expands authenticated plaintext semantics
  and can make profile choice depend on adversarial delivery order.
- Changing a populated adapter's context can strand previously accepted history,
  queued account-ID ciphertext and crossing sessions; it is not a scalar toggle.
- Classified `context_mismatch` rolls back candidate crypto state, but its bounded
  notice stores only id/sequence/reason, not a verified peer/profile or ciphertext
  commitment. It can also mean wrong realm, message ID, from/to, or version.
  The reason alone is NOT authenticated authorization to retry or clear a notice.

No persisted failure replay is implemented here. A future design must bind exact
re-fetched ciphertext to the verified peer and approved profile, preserve all seen
conflict checks, commit history/ratchet/receipt atomically, and reconcile ONLY the
matching successfully accepted notice. It must handle later cursor/ratchet progress
and ledger eviction explicitly; recovery of all old failures cannot be promised.
Never clear a general ledger/cursor, reset identity/ratchet, restore stale state,
or mass-resend messages. Existing unknown-contact replay is a different mechanism.

## Invariants, verification and gates

- SS-01/05, REQ-ID-005/006: unchanged identity, credentials, pins, shared Account;
  migration and retained-state regression tests.
- SS-03, REQ-ID-007, REQ-SEC-001: explicit binding and strict context; QR ambiguity
  characterization, all-new upgraded peers, tamper/wrong-context tests.
- SS-04, REQ-MSG-002/003/004: both directions, genuine receipts, exact replay,
  unknown-contact deferral, symmetric retained peers and persisted failure replay.

The focused acceptance regression is intentionally RED and must not be ignored,
marked expected-failure, or described as a working fix. Existing positive tests
are baseline evidence, not proof of asymmetric compatibility. No production source
change is proposed until the missing profile signal is resolved. Independent
fresh-context security review and human disposition are outstanding. No APK build,
version/signing change, publication, deployment or phone acceptance occurs here.
