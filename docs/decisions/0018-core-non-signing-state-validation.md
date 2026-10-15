---
status: accepted
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
risk_owner: martadvix-web
approved_change: bounded private-alpha non-signing core validation design and local implementation/tests; no adoption or live authority
approved_revision: 9eb6527a6ed6090c9213a4663677e67d9ad03339
approval_date: 2026-10-15
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/88
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887
approval_request_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6178371133
created: 2026-10-14
last_reviewed: 2026-10-15
last_reviewed_scope: verified human acceptance of the frozen contract; runtime/native evidence remains unrun
technical_direction_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187
delegation_record: https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919
source_scope_approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046
---

# ADR-0018: Non-signing full core-state validation and public projection

**Accepted decision in this review branch; not yet normative on `main`.**
Human technical decision owner Cooldom66671 [accepted the exact boundary](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887)
at `9eb6527a6ed6090c9213a4663677e67d9ad03339` on `2026-10-15T07:01:36Z` and explicitly authorized only the
scoped local implementation/tests. The linked [RFC-0032](../rfcs/0032-core-non-signing-state-validation.md)
is completed as proposal history, not a normative API specification or delivered
operation. Canonical publication still requires a separately authorized merge.
No runtime implementation, passed V01–V14 test, lifted schema-3 reopen blocker,
adoption, native measurement or live authority is claimed.

The history records `draft` → `proposed` → `accepted`, without a direct transition
or invented earlier approval date. The proposed checkpoint changes status only;
the human-approved eight-item contract below is retained verbatim from `9eb6527`.
Number 0018 was rechecked against published heads/pull heads before proposing.

## Authority and work boundary

- Technical authority is [delegated to Cooldom66671 by martadvix-web](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919);
  product scope, priorities and residual-risk ownership remain with martadvix-web.
- The [D87 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187)
  chooses direction A for D87-07 (an RFC for non-signing validation) with
  direction B, blocked general schema-3 reopen, as the interim default. It
  explicitly withholds permission to modify `clients/core` (including
  `clean_service`), `key-protocol` or the shared JSON command contract before
  RFC → ADR → required owner approval. The [later explicit approval](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887)
  now satisfies that design/source gate only for the frozen contract and scope;
  it does not authorize unrelated shared-code changes or adoption.
- The [bounded source/local-test confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
  by martadvix-web covers private alpha with synthetic/non-sensitive data and
  local component/native tests. It is not approval of this API.
- The [independent AI closure review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5522716241)
  of the RFC in PR #88 is advisory, covers only the RFC revision it names and
  is not human approval.

## Required review rationale

Protected domains: shared identity/key handling, cryptographic verification,
local persistence admission, public JSON API compatibility and native memory
boundaries. `review_mode: closed-alpha-ai` uses accepted [ADR-0003](0003-closed-alpha-review-policy.md)
under the [human #73 scope confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
and [exact request](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785): private informed
alpha, synthetic/public/non-sensitive test data, coordinator local source checks
and the selected Mac component/native path. Human residual-risk owner is
martadvix-web. No sensitive-user data or production/privacy/security claim is
covered. No second qualified human is asserted; the empty list is not an exemption.

[Independent fresh-context ADR review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5523363288)
(`deleg_6a0bf028`, `sa-0-cf6cfdd4`) returned scoped DRAFT PASS on
`15e86b96658009cd452e4343809c057d15b3c04b`, with no blocking findings to resolve.
Reviewer/model as reported: gpt-6-astra, provider openai-codex. Model diversity is
not claimed; shared-model blind spots remain a bounded-alpha residual risk.
The owner-approved `9eb6527` citation/status tail preserves that reviewed decision;
this acceptance record changes lifecycle/provenance, not the frozen contract.
Neither tail is falsely represented as a fresh independent substantive review.

Human [approval](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887) of points 1–3 in the [explicit scope request](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6178371133)
is the acceptance event, not CI, the AI review or the earlier Telegram relay.
It authorizes the described local feature-branch implementation/tests only after
recording this decision. Preserve E2EE, identity/history, all unchanged ABI/old
command/transcript/peer-verification/size/RNG boundaries and actual tests. Scope
expansion needs separate disposition. No merge/main, deploy/release, server/DB/
RPC/login/registration/replacement, installed-app or retained-Keychain changes,
new Keychain probes, phone installation, Apple signing/export or TestFlight is
included. Default independent qualified human review remains required before
sensitive data, public release, production claims or expansion beyond this scope.

## Context and problem statement

[Verified-B admission](../clients/ios/realm-store-preflight.md#verified-b-means-local-read-only-admission)
item 5 requires full non-signing Rust validation before a realm reader returns
retained schema-3 state. At baseline `c66fcbc` no such path exists: `view`'s
`validate` recomputes each channel through `local_contact`, which calls
`ContactV2::create` and signs with device authentication; `reply` signs when a
fallback key is retained and reserializes secret state and plaintext;
`identity_credential_v3` validates only the legacy identity. General schema-3
reopen is therefore blocked, blocking the D1–D3 goal (recover a test nickname,
log in, restart with login retained). Relevant requirements: REQ-CLIENT-001,
REQ-MULTI-001, REQ-ID-002/003/005/007, REQ-MSG-002/003/004/005 and
REQ-SEC-001; none is claimed fulfilled. No deadline is assigned.

## Decision drivers

- One semantic authority for state admission: the shared Rust core, not Swift.
- Zero signing, key/nonce/UUID generation or protocol RNG on reopen, while every
  existing peer signature, transcript and collection check is preserved.
- Unchanged C ABI, JNI, old operations, wire formats, server and dependencies.
- Bounded, allowlisted output; preserved existing serialized-size gate.
- Verifiable evidence: differential tests, call instrumentation, native peak
  memory, rebuilt artifacts; honest NOT RUN reporting.

## Considered options

These proposal-stage assessments underpin the human-approved selection of A;
B remains the operational default until implementation/adoption gates pass.

1. **A: additive pure Rust validation plus minimal projection** — preferred
   under D87-07; one authority, but real refactoring, dispatch/size
   equivalence proof and protected approval are required.
2. **B: keep arbitrary retained schema-3 reopen blocked** — required interim
   default and rollback; safe and honest, leaves restart-keeps-login open.
3. Call `view` and discard the result — rejected: validation and reply can
   sign; reply reserializes secrets; discarding output undoes neither.
4. Use only `identity_credential_v3` — rejected: misses conversation, session,
   event and enrollment checks.
5. Mirror checks in Swift or inspect JSON shape only — rejected: divergent
   authority; no real Account/session validation.
6. Temporary signing on reopen or a "no-sign" runtime guard — rejected:
   violates D87-07, obscures call-graph safety, adds a bypass/failure mode.
7. Dummy unsigned `ContactV2` with skipped verification — rejected: confuses
   local transcript inputs with authenticated peers; verification bypass risk.
8. Return the full old view or add a new C ABI — rejected: unnecessary; more
   secret copies or integration surface.

## Decision

**Human-approved design:** adopt option A; option B remains the operational
default until A is implemented, tested, reviewed and admitted for use. Only a
shared-core path gives full admission without a signing oracle or a second rule
set. The following eight items preserve the exact approved `9eb6527` boundary;
proposal-stage ratification language is satisfied by the recorded human approval,
not by a test result or this status edit. Implementation evidence is still required:

1. **Operation and dispatch.** One request `{"op":"validate_state_v3"}` over
   the existing `clients/core::command(state, request)`, unchanged
   `paranoid_core_command`/`paranoid_core_free` and JNI signatures. A bounded,
   duplicate-aware top-level discriminator recognizes it before the old
   whole-state `Value` peek or any old handler; an exact typed decoder runs on
   the original request bytes. Preserve the existing raw limits: state 8,388,608
   bytes and request 65,536 bytes, before parsing. The new request has exactly one
   decoded `op` string member; malformed/duplicate/unknown fields refuse, including
   escaped-key duplicates, while valid escapes retain their decoded meaning.
   Duplicate `op` mentioning this operation refuses `invalid_request` in either
   order without invoking an old handler. Other requests keep existing dispatch;
   unknown operations stay `invalid_request`.
2. **Full validation without signing.** A bounded root/version probe requires
   complete JSON object syntax and one unsigned u64 integer `version`, without
   string/negative/fraction/exponent/Boolean/null coercion. Missing, duplicate,
   invalid or out-of-u64-range version is `invalid_state`; a syntactically valid
   unique unsigned integer other than 3 is `unsupported_state`. Parser recursion
   protection remains; no new realm-metadata depth/ASCII rule is imposed on core.
   Version 3 is decoded from the original bytes into the
   current typed `State` and receives the entire existing schema-3 admission
   surface (RFC-0032 §3): legacy/self-service checks, clean identity,
   cursor/count limits, enrollment match, fallback binding, unchanged
   `ContactV2::verify` for every peer, identical channel recomputation and
   session/commitment/outbox/event checks. Local transcript inputs come from
   the validated credential, original bundle and fallback public key;
   `ContactV2::create` is never called. No signing, key/nonce/UUID generation,
   protocol RNG, protocol/persisted-state transition, persistence, clock, network
   or file/Keychain access on any success or refusal path. A seeded protocol RNG
   is forbidden even if it would make no fresh OS entropy call.
3. **Runtime hash seeding.** The narrow proposed category covers only evidenced,
   required runtime hash-table seeding during reconstruction/validation, such as
   `Account::from_pickle` → `HashMap` `RandomState`. No seed is exported, persisted
   or repurposed as protocol material. Ratification, pinned call-path attribution
   and cold-process/fresh-worker/warmed/optimized controls are required; syscall
   size/flags do not establish a whitelist. New/unclassified entropy, including
   crypto-verification RNG, requires separate investigation/disposition. No
   production bypass flag, warm-up, disabled hash randomization or skipped
   Account validation workaround.
4. **Size semantics.** The same pinned `serde_json::Serializer` writes into a
   private, checked, non-buffering counting sink; above 8,388,608 bytes refuse
   `local_state_full`; other counting failures are `state_error`. Transient
   borrowed chunks must not be retained, logged, returned, persisted or forwarded.
   No complete encoded-state buffer, `to_vec`/`to_string` of `State` or old `reply`;
   exact equivalence with the baseline serializer remains to be proven.
5. **Projection and limits.** Success returns exactly `validation_version` 1,
   `state_version` 3, the eight retained public `Credential` fields (`root`,
   `account`, `device`, `auth`, `realm`, `pin`, `olm`, `signature`), existing
   `Credential::fingerprint()` as `fingerprint`, and `enrollment` (explicit null
   or retained `mode,account,device,credential`). No `state` member or extra
   field; no credential normalization or new signature. Output cap 8,192 UTF-8
   bytes excluding C NUL, supported by the 7,105-byte shape bound and 29-byte
   maximum error object. Errors are fixed, payload-free `input_limit`,
   `invalid_request`, `unsupported_state`, `invalid_state`, `local_state_full`,
   `state_error`, `output_limit`, `native_failure`; semantic sub-failures collapse
   to `invalid_state` only for this operation. Precedence: transport arguments →
   raw caps → exact request → state syntax/version → typed validation → size
   count → output bound. No error implies safe reset or missing identity.
6. **Caller lifetime.** At most one in-flight validation per installation root
   across both slots, enforced by the caller, not a Rust global lock. Run the
   synchronous call off the main executor; keep input buffers and slot until
   return, free exactly once, discard cancelled/stale results, and fence context/
   revision/lease before dispatch and publication. No unbounded replacement calls,
   in-call cancellation, hard CPU deadline or immediate zeroization is promised.
7. **Unchanged.** Global `Credential::verify`, `key-protocol` transcripts and
   digests, old operations and responses, wire formats, server/registry
   behavior, dependencies and device-UUID admission.
8. **Not lifted.** General schema-3 reopen stays blocked until the real
   approved, implemented, tested and reviewed path exists. D87-06's future v3
   enforcement/compatibility and separately authorized server inventory are not
   prerequisites to this validator or the current namespace slice.

## Consequences

### Positive

- Rust-owned validation and public coherence values for the realm reader,
  without signing or a second interpretation of state rules.
- Old commands, ABI, wire and server contracts untouched; rollback is option B
  with no persisted marker to remove.
- An explicit entropy category replaces an untestable absolute promise.

### Negative

- Real refactoring of `clean_service` validation and contact-transcript inputs,
  with differential proof that old behavior is byte-identical.
- Residual memory copies remain: Swift-to-C NUL-terminated copies, cloned
  secret-bearing pickle `Value`s, Rust/C reply allocation and Foundation
  decoding. Not zero-copy; no guaranteed secret erasure.
- No CPU deadline or native peak-memory bound follows from byte caps.
- A successful projection is local evidence, not membership or login proof.

### Risks and mitigations

- Signing oracle survives in validation or result construction — separate
  signing/protocol-generation instrumentation, positive controls and
  deliberately failing forbidden-call probes (V07).
- Instrumentation misses a wrapped signer or seeded protocol RNG — review the
  pinned dependency call graph; unclassified entropy stays unresolved.
- Helper extraction alters transcripts or old admission — independent
  LP/channel vectors and old-suite regressions on rebuilt artifacts (V04/V13).
- Duplicate or escaped keys reach a mutating handler — raw entry-point
  negatives in both orders (V06).
- Old binary receives the new verb — `invalid_request`, no fallback (V14).
- Counting sink diverges from baseline size — equivalence at exact/+1
  boundaries, defaults, escapes and Unicode (V09).

## Validation

**V01–V14 of RFC-0032 are NOT RUN**; this documentation change adds and executes
no runtime test. Design/source approval is now recorded; runtime/adoption
acceptance is a separate phase. Existing source probes and design reviews are
research evidence, not tests of an implemented validator. The numeric peak/
latency budget is deferred to measurement and remains mandatory before adoption.
Do not create a circular demand for future implementation tests to pass before
authorizing their code, or relabel those unrun tests as passed evidence.

**Implementation/adoption acceptance** requires behavioral RED → GREEN on the
authorized implementation;
differential equivalence against baseline `view` admission and the baseline
serializer; signing/protocol-generation instrumentation with attributed runtime
entropy under cold/warm/optimized controls; rebuilt C/JNI artifacts with exact
source correspondence; and an exact-head `xcodebuild test` simulator harness
recording `XCTMemoryMetric` plus justified actual numeric peak over
decrypt/parse/transfer/Rust/projection, with a technical-owner-ratified budget.
No such harness, budget or measurement exists today. The
[existing-API probe receipt](../project/evidence/core-state-validation-20261014/README.md)
is research, not acceptance.

## Compatibility and migration

- Additive verb only; existing contracts, schema-3 bytes, fingerprints,
  contacts, channels and pending frames unchanged.
- Old binary: `invalid_request`; core versions 0/1/2/future: `unsupported_state`.
  The clean schema-0 discarded `upgrade_v2` dry-run stays a separate preflight
  path, not generalized here.
- No server, wire, registry or data migration. Rollout only after approved
  contract and tests, rebuilt artifacts, an isolated typed iOS consumer with
  native evidence, then separately reviewed realm-store adoption.
- Rollback disables the new consumer and preserves retained data under the
  preflight's compatible-reader or stopped-installation rule; no deletion,
  reinstall, old-ratchet restore or lowered server generation.

## Disposition and acceptance evidence

- Disposition: accepted in the review branch; not normative until canonical merge
- Disposition rationale: select full non-signing Rust validation/public projection
  while retaining full existing admission and separate runtime/adoption gates
- Decision owner and identity: Cooldom66671, human GitHub `User`, under the
  [founder's technical delegation](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)
- Product/residual-risk owner: martadvix-web, with verified bounded #73 scope
- Approved revision: `9eb6527a6ed6090c9213a4663677e67d9ad03339`; numbered decision items preserved verbatim
- Pull request URL: <https://github.com/GOTD-GLOBAL/ParanoID/pull/88>
- Permanent disposition or approval evidence URL: <https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887>
- Exact request defining points 1–3 and exclusions: <https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6178371133>
- Approval timestamp: `2026-10-15T07:01:36Z`; disposition date: 2026-10-15
- Required-review evidence: [independent exact-revision ADR review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5523363288)
  on `15e86b96658009cd452e4343809c057d15b3c04b`, with the verified citation-only
  correspondence to the approved revision; no implementation/native review claimed
- Withdrawal author statement URL: not applicable
- Telegram evidence: not used for acceptance; the human GitHub record supersedes
  the earlier unverified relay, which never supplied authority
- Validation/limitations: source probes and document/design checks only; no
  implemented validator, V01–V14, native harness/result, budget or adoption evidence
- Follow-up: implement/test only the approved contract; obtain exact-source review,
  rebuilt artifact/regression/native evidence and a ratified budget before adoption;
  realm-reader integration, D87-06 and all excluded live actions remain separate

Exact human approval text (original language, not a bot-authored approval):

> Подтверждаю пункты 1–3: D88/D89 согласованы; ADR-0018 по 9eb6527 принимаю в указанном private-alpha scope; разрешаю только описанные локальную реализацию и тесты. Численный бюджет — отдельный обязательный gate до adoption. Исключения и непройденные проверки сохраняются.

### Technical follow-up inputs, not new implementation evidence

The earlier [D88 technical response](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186309504)
was expressly direction-only; the later explicit approval above accepts `9eb6527`
and grants the bounded local source scope. D88-02 requests explicit R09/R10
freeze-and-report fixtures for `output_limit`, `state_error` and `native_failure`,
never treating them as no saved login. D88-04/06 propose target-specific Apple
entropy interposition and footprint sampling. Those target/API assertions and
instrumentation coverage require source/native verification; they are not
promoted to measured facts or silently substituted for the approved V07/peak
acceptance obligations. A sampled maximum or net delta is not automatically the
actual transient peak. No numeric budget is inferred.

[D89 choices/amendments](https://github.com/GOTD-GLOBAL/ParanoID/pull/89#issuecomment-6186309968) are recorded
as separate namespace follow-up inputs. This ADR does not adopt a Swift permit
implementation, assumed signed entitlement, legacy population claim or a new
Keychain probe scope. Preserve native unknowns and review those details against
actual target/source evidence; do not rewrite this approved decision to absorb them.

## Links

- Requirement: [requirements](../product/requirements.md) — REQ-CLIENT-001,
  REQ-MULTI-001, REQ-ID-002/003/005/007, REQ-MSG-002/003/004/005, REQ-SEC-001
- RFC: [RFC-0032](../rfcs/0032-core-non-signing-state-validation.md);
  parent [RFC-0030](../rfcs/0030-ios-identity-v3.md);
  related draft [ADR-0017](0017-ios-concurrent-identity-v3.md)
- Threat model: [iOS identity-v3 threat delta](../security/ios-identity-v3-threats.md#proposed-full-state-validation-boundary-rfc-0032);
  [trust boundaries](../security/threat-model.md#trust-boundaries-to-define)
- Experiment or benchmark: [source-probe receipt](../project/evidence/core-state-validation-20261014/README.md)
- Consumer contract: [realm-store preflight](../clients/ios/realm-store-preflight.md#verified-b-means-local-read-only-admission)
- Contract questions: [D88-01–06](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6175640412)
  on the RFC contract at `55364d7`; the human answers and later explicit approval
  are linked above, with technical inputs separated from implementation evidence.
- Source baseline: [core lib.rs](../../clients/core/src/lib.rs), [clean_service.rs](../../clients/core/src/clean_service.rs), [C ABI](../../clients/ios/bridge/src/lib.rs), [key-protocol](../../key-protocol/src/lib.rs)
- Governance: [ADR-0001](0001-documentation-as-code.md), [ADR-0003](0003-closed-alpha-review-policy.md),
  [closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception)
- Supersedes: none
- Superseded by: none
