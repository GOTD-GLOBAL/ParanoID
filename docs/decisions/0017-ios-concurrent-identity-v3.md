---
status: draft
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
technical_disposition_date: 2026-10-13
technical_disposition_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664
last_reviewed: 2026-10-14
source_scope_approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046
realm_appendix_disposition_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187
---

# ADR-0017: iOS identity v3 with independent concurrent realms

**Draft, not accepted.** This records the technical candidate of
[RFC-0030](../rfcs/0030-ios-identity-v3.md) and its
[concurrent-realm design](../clients/ios/concurrent-realms-design.md).
It does not assert a working iOS v3 build, completed MR gates or deployment.
Number 0017 was checked against all 63 fetched published refs before drafting;
recheck before proposing/merging if another branch allocates it first.

## Authority and work boundary

Technical decision authority for bounded private non-sensitive alpha is
[delegated to Yaroslav / Cooldom66671 by martadvix-web](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
Product scope, priorities and case-specific server/production authorization
remain with Sergey. Yaroslav's [verified technical disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664)
agrees with design `efafe798f89b5bef7b411b8aeb9af661f52a39e0` and this draft
at `4aac29c0ecb90c1cca1d49fc934403018779f3f9` as the basis for implementation,
with four non-blocking remarks recorded below. His [cross-reference in PR #74](https://github.com/GOTD-GLOBAL/ParanoID/pull/74#issuecomment-6150515450)
points to the same single source. This is not product/scope approval, ADR
acceptance or live authorization. The separate [direct source-scope confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
by `martadvix-web` now records the [bounded request](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785) in PR #73.
The earlier reported three-remark comment is not relied on. The later
[direct D87-01–07 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187) by `Cooldom66671` agrees with the realm
appendix at c66fcbc, not this ADR's acceptance or new shared-core source changes.

The original Telegram task requested urgent progress toward a working iOS test
version. Work started with locally exercised implementation prerequisites rather
than another request to repeat the same product direction. The initial slice
was bounded to the iOS C ABI over the existing Devnet/core crates, with local
synthetic/public-fixture unit checks. The owner clarified that application
acceptance must use the existing configured identity-v3 instances and existing
Android clients on the same realm. The separately proposed local-stand
workstream is cancelled; it is not a prerequisite for that acceptance. No changed
cryptographic algorithm, live RPC/registration, server login, persistent user
identity, Apple-account action or delivery claim follows from that slice.
The application/runtime portions still need their own native tests and review.

Build execution split, chosen in the current task: this Linux coordinator
prepares and checks source; Yaroslav's agent on his Mac performs the exact-head
Xcode/native build and tests. No reachable Mac or self-hosted GitHub macOS runner
was found here, and no paid runner is provisioned. This is a task-specific
build handoff, not a permanent hosting or staffing policy.

Technical basis and bounded private source/local-test scope are recorded;
implementation and the full acceptance record remain pending. That scope keeps
preservation, E2EE, tests and independent review and authorizes no live actions.
D87-06/07 require separate RFC → ADR and owner approvals for shared-core changes;
the pure validator is a prerequisite of verified-B/restart admission, not an
optional later cleanup. This draft is not blanket protected-domain approval. Merge/release, changes to
either hosted server, phone installation/replacement, Apple account and
TestFlight remain separately scoped; none is performed by drafting this ADR.

## Context and decision drivers

REQ-CLIENT-001 requires iOS; the current app knows the stopped v2 endpoint and
cannot log in using the Android identity-v3 flow. REQ-MULTI-001 now requires
both named v3 servers concurrently. REQ-ID-002/003/004/006/007, REQ-MSG-003/004/005,
REQ-CALL-001 and REQ-SEC-001 retain recovery, admission, verification, receipt,
retention, call-consent and E2EE boundaries.

A second URL does not make the single-realm client multi-realm. One core state
is bound to one realm/pin; app-global UI/media and the legacy storage path need
explicit ownership. Owner words are not messenger history or transport keys.

## Required review rationale

Protected domains: identity/recovery/blockchain; existing signing exposed through
an iOS ABI; persistence and format compatibility; foundational dependency graph;
server trust, scoped transport and physical media authority. No server/wire/core
change is assumed; stop and propose a separately reviewed change if needed.

The closed-alpha AI exception is proposed, not a replacement for the human
owner or permanent scope evidence. Each implementation PR records its exact
features, synthetic data/environment, independent reviewer/model/revision,
findings and actual tests. A failed test or unavailable Mac is not a pass.
The [design review](https://github.com/GOTD-GLOBAL/ParanoID/pull/74#issuecomment-6142060431)
covers design SHA `71eda964b6f41986c0e85c43ed88676807f753df`, not any new code.
Before sensitive data, public release or production/security/privacy claims,
independent qualified human review remains required by ADR-0003.

## Proposed decision and alternatives

Prefer one nickname owner per installation, with independent randomly created
core/device credentials, memberships, encrypted state, session and lanes for
each full realm/pin. Use existing Rust derivation/signing through a thin C ABI;
Swift performs orchestration, not a second cryptographic implementation.

The delegated technical decision owner agreed to this variant as the
implementation basis, not as accepted or completed application architecture.

- An authenticated install catalogue at the legacy path and independent owner/
  realm stores provide explicit allocation, crash/freeze and context checks.
- Immutable realm login intents survive unknown outcomes; mismatches preserve
  bytes and freeze rather than discard evidence or regenerate keys.
- One exclusive application-wide owner-operation/call admission state fences
  late authentication and media callbacks. One media owner arbitrates audio,
  camera and tones; each realm retains independent authenticated signaling.
- Both connections operate in permitted foreground state. Selecting a view
  selects the target, not the sole connected server. The former call realm
  alone retains its bounded post-call drain; there is no new background delivery.
- Directory pairing checks both proof and finalized registry, with explicit
  realm targeting. Short server IDs are hints, never storage/trust identities.

Rejected as the preferred candidate: one mutable active-realm/core state
(does not meet concurrency); unrelated owners for each server (extra recovery
burden; considered alternative not selected in the technical disposition); one aggregate messaging
snapshot (coupled write/failure boundaries); two uncoordinated app runtimes
(shared physical resources and nominally global budgets conflict).

## Consequences and retained risks

One owner simplifies nickname recovery and correlates memberships. In remark 4,
Yaroslav selects the recommended answer to RFC-0030 question 19 and accepts this
correlation as a consequence of the product model "nickname is identity", not
an unresolved choice between shared and unrelated owners. This technical
disposition is distinct from the separately recorded product/source scope in PR #73.
Correlation remains observable and must be disclosed; cross-server anonymity
is not promised. A compromised owner can still compete for replacement on
either server; that security risk is not eliminated by choosing correlation.
Transport revocation
does not erase owner authority or restore history. RPC remains a trusted source;
server-local capacity/cooldown and shared host/disk limits remain real.

Isolated store failure can stop only that realm when sibling/common integrity
is verified; catalogue/common storage failure stops all. Conservative journaling
can freeze on ambiguous writes. No cryptographic anti-rollback is promised.
The first-admitted owner/call policy can refuse an incoming call during a
foreground owner operation; it is explicit, not a claim of call waiting.

## Validation, compatibility and rollback

### Disposition remarks and D5 order

1. First jointly authorized iPhone/Android test: `138.16.180.53:38444`.
   The inspected Android v51 login creates/binds the device to
   `IDENTITY_TEST_REALM` and refuses a different realm
   (`clients/android/src/org/paranoid/text/TextEngine.java:307-318`;
   `KeyClient.java:15-18`). The second iOS realm follows; the first successful
   VDSina session alone never satisfies MR-16.
2. Android currently has one messaging realm. Its onboarding join uses that
   login path (`clients/android-devnet/src/org/paranoid/devnet/OnboardingActivity.java:443-465`),
   while its sponsor uses Hetzner `DEFAULT_REALM` (`:513-517`). Sponsor use is
   not messaging membership or concurrent-server support. Cross-platform
   operation on both servers therefore needs separately scoped Android work,
   outside RFC-0030; this iOS work must not silently modify Android to provide it.
3. Before D5, the owner confirms that `157.180.49.125:38444` actually accepts
   identity-v3 memberships. Source constants or a sponsor response do not prove
   admission, correct deployment or independent live databases. No live
   topology/admission verification has been performed by recording this remark.
4. Common-owner correlation is the selected consequence described above, not
   an open question 19. Other security residuals and approval gates remain.

The accepted **goal** for D1-D3 is: recover a test nickname on iPhone, enter
the existing server, then restart with the identity and login retained. It is
not an achieved test result. Yaroslav performs phone acceptance only after a
separate explicit go for each action; the planned order is not an enrollment,
replacement, installation, server-change or deployment permission. Record each
action's applicable owner authorization and exact test scope before execution.

MR-16 stays unfulfilled until both realms and their required peer scenarios
have actual evidence. If the second Android leg is unavailable, record the
external Android dependency and NOT RUN result rather than weakening MR-16.

The D0-D5 sequence and MR-01..16 in the linked design define implementation and
acceptance. All MR runtime/device gates are NOT RUN at drafting. Initial Linux
bridge/stand results, when available, are only component evidence; Mac receipt
must identify exact source, regenerated native artifacts, test counts and skips.
Phone/Android-peer acceptance remains separate and cannot be replaced by CI.

Existing v2 state is not overwritten or reset. An intact v5 catalogue/key at
the old path makes the inspected v4 reader refuse; if both legacy objects are
lost, that reader can miss surviving namespaced state and is unsupported for
rollback. Only a compatible v5-aware reader or a stopped preserved installation
is a rollback candidate. No lowered generations, old-ratchet restoration,
server DB reset, reinstall or data deletion is authorized by this document.

## Disposition and acceptance evidence

- Technical disposition: agreed as an implementation basis, with four remarks;
  the later D87 record accepts bounded realm directions/qualifications. Source
  scope is confirmed separately; ADR status remains `draft`, not automatically
  accepted by either record or by a future implementation.
- Technical decision owner: Cooldom66671, within the linked delegation only.
- Product/risk owner: martadvix-web.
- Permanent technical-basis evidence: comment 6150510664 above, not ADR acceptance.
- Permanent bounded source-scope evidence: <https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046>,
  confirming the request <https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785>.
- Realm-appendix direction/qualification evidence: <https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187>.
- Independent design evidence: PR #74 closure above; code review is separate.
- Resulting implementation evidence: to be recorded per exact-head PR.
- No accepted ADR is superseded by this draft.
- Acceptance requires human disposition, complete exception evidence, applicable
  test/phone gates and coherent RFC/decision-log publication, not merely a merge.

## Links

- [Requirements](../product/requirements.md)
- [Identity-login v3 contract](../protocol/identity-login-v3.md)
- [iOS identity-v3 threat delta](../security/ios-identity-v3-threats.md)
- [Proposed base iOS ADR-0014](0014-ios-client.md)
- [Proposed identity-v3 ADR-0016](0016-solana-server-authentication.md)
- [Governance / accepted ADR-0003](0003-closed-alpha-review-policy.md)
