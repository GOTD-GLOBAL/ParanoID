---
status: draft
owner: client
last_reviewed: 2026-10-02
---

# Remaining iOS work: refusal integration and regression gates

## Source candidate, not runtime acceptance

PR62 is integrated with frozen main `438c79ed1239a110c829fd21eafdc4b87f2ba57a`,
which includes the iOS UI stack and PR60. The separate APNs documentation PR58
now uses RFC-0029 to leave RFC-0028 with Sergey's server-directory/links PR67.
Neither this integration nor the draft renumbering changes any RFC/ADR disposition.

Only `clients/ios/**`, documentation and CHANGELOG differ from main. Core,
server, Android, blockchain, bridge and deployment sources remain main's exact
contents. In particular this does not add iOS Solana login, switch saved realms,
rekey contacts, change capacity budgets, or implement APNs. PR67 is not included
or modified. Merge needs Sergey's explicit instruction; no device/live operation
or publication is implied.

## Refusal reconciliation

- Preserve both main's trimmed wire text/raw failed-draft restoration and PR62's
  per-dialog in-memory refusal notes. Notes are associated with the restored raw
  draft, not trimmed Ticket.text. A restoration echo is not a user edit.
- The merged composer measures `bytesToSend(draft)` for the same text actually
  sent. Counting raw padding could hide a real refusal behind a false over-limit
  hint; the source regression was observed RED before this correction and GREEN
  afterwards. The 1800-byte warning and 2048-byte limit remain unchanged.
- Outbox/registration/block state can retire a stale note. Other refusals remain
  until a real edit/new attempt; no artificial byte-count staleness rule is added.
- A refusal completed off screen is stored for its own conversation but cannot
  announce through VoiceOver over a different selected conversation's note.
  The account-and-visibility predicate has a source RED/GREEN regression and a
  native same/different/nil-account matrix awaiting Mac execution.
- Frozen/commit-failed state belongs to the existing frozen screen. Unknown error
  codes keep the conservative fallback. No raw exception becomes user-visible
  protocol authority or a reset instruction.
- Contact refusals retain the actual immutable-key meaning of
  `peer_already_pinned`; a repeated identical contact is not fabricated as an error.

## Coverage follow-up from f650727

The earlier Mac receipt reported 40 RED mutations and one survivor,
`SeenCondition(messages: 0, ...)`. That history is not rewritten as full coverage.
Message count participates in Equatable invalidation even if visibility booleans
stay unchanged; it is not redundant merely because one simulator path also
changes geometry.

This candidate extracts a small internal `makeSeenCondition` value factory,
used by the production computed property with exactly its existing visibility
inputs. It still obtains message count from the real current dialog. No seen
predicate, scheduling rule, persistence or network action changes. The native
ComposerSendTests fixture calls that same factory before/after a real core send
with fixed visibility inputs, asserting only count changes and Equatable differs.
It does not read a detached SwiftUI environment or claim actual callback timing.

Other prior review gaps are narrowed:

- close/reopen the chat before asserting that an own message creates no divider;
- check down-button navigation and list-count clearing before an own reply can
  hide a missing seen update, then reopen for the combined reply scenario;
- assert the trimmed reply appears exactly once in the UI, separately from the
  existing peer/core-history exact-once check.

These native changes are **NOT RUN** here. A new Python source guard passed on
production and rejected the count-zero mutation; that does not prove the new
native test also kills it. Real short-history incoming-message geometry,
iOS17 fallback, ReduceMotion and physical lifecycle remain runtime checks.

## Exact-head Mac handoff

Use the pushed PR62 commit named in its latest integration comment, not original
`e534ee6` or the old pre-PR60 stack receipt. Clean tracked tree; regenerate the
core xcframework and notices in that checkout; clean DerivedData.

Through `clients/ios/toolchain.sh`:

1. Rebuild the core, then full ParanoidKit (including SendRefusalTests and
   presentation cases) on the pinned toolchain.
2. Run RefusalPresentationTests, especially the new padded-draft refusal and
   account-bound announcement matrix, and ComposerSendTests, including count-only
   invalidation and reopen checks. Removing account equality from the announcement
   predicate must fail the different-account/shown case; restore and rerun GREEN.
3. Run the full app target and separately signed Keychain tests.
4. Run the stand-backed text scenario with the strengthened down-button and
   exact-one-bubble assertions, plus existing unread/composer/contact/call cases.
5. Re-run the count-zero mutation in the shared factory: the new native test
   must fail, then restore source and show GREEN on the exact clean head. Record
   any survivor honestly. Also mutate raw-byte counting and raw-draft restoration.
6. Build the fresh device bundle and run its verifier; state any skipped signing
   check. Physical phone, VoiceOver, iOS17 and distribution remain separate.

Report SHA, commands, toolchain, destination, counts and skips. Distinguish injected
SnapshotSink failure from a physically full disk; these tests prove production
transaction ordering, not new filesystem power-loss evidence. A real v3 login or
v2/v3 cross-realm interaction is not established by the local registration fixture.

## Linux evidence and rollback

Exact local command results and fresh CI are recorded in the PR. Source checks,
Markdown, boundary, lock and native Rust/JVM gates have narrower scope than an
Apple app build. No missing native test is marked passed by an offline source
check. Current-state and prior dated receipts preserve the distinction.

Rollback is a reviewed revert of this client-only candidate, not a rollback of
main's Solana work or an erasure of phone state. APNs decisions, incoming-refusal
presentation/507 wording, and iOS v3 login remain separate work; they are not
silently included in the completed send/contact-refusal scope.
