---
status: proposed
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
created: 2026-10-14
last_reviewed: 2026-10-14
technical_direction_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187
delegation_record: https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919
source_scope_approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046
---

# ADR-0018: Non-signing full core-state validation and public projection

**Proposed lifecycle checkpoint, not yet recorded as accepted.** This records the candidate decision of
[RFC-0032](../rfcs/0032-core-non-signing-state-validation.md) for D87-07: one
additive, read-only `validate_state_v3` operation on the shared Rust core. It
asserts no implemented operation, passed test, lifted schema-3 reopen blocker
or live authority. Number 0018 was rechecked against published heads and pull
heads on 2026-10-15; no other ADR-0018 allocation was found.

## Authority and work boundary

- Technical authority is [delegated to Cooldom66671 by martadvix-web](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919);
  product scope, priorities and residual-risk ownership remain with martadvix-web.
- The [D87 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187)
  chooses direction A for D87-07 (an RFC for non-signing validation) with
  direction B, blocked general schema-3 reopen, as the interim default. It
  explicitly withholds permission to modify `clients/core` (including
  `clean_service`), `key-protocol` or the shared JSON command contract before
  RFC → ADR → required owner approval. This ADR is that step, not the approval.
- The [bounded source/local-test confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
  by martadvix-web covers private alpha with synthetic/non-sensitive data and
  local component/native tests. It is not approval of this API.
- The [independent AI closure review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5522716241)
  of the RFC in PR #88 is advisory, covers only the RFC revision it names and
  is not human approval.

## Required review rationale

Protected domains: shared identity/key handling, cryptographic verification,
local persistence admission, public JSON API compatibility and native memory
boundaries. The proposed `closed-alpha-ai` mode uses the bounded exception of
accepted [ADR-0003](0003-closed-alpha-review-policy.md); the empty reviewer
list is not completed review or exemption. [Independent fresh-context ADR review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5523363288)
returned **scoped DRAFT PASS** on `15e86b96658009cd452e4343809c057d15b3c04b` with no blocking defects.
Reviewer/model: gpt-6-astra, provider openai-codex; model diversity is not claimed.
This later citation/status-only update preserves the reviewed substantive boundary;
it is parent-verified, not a second independent review. Completing
the record and review makes it eligible for `proposed`, meaning ready for human
disposition, not already approved. Human decision-owner approval of the exact
boundary, any required product/risk-owner approval and complete governance
acceptance evidence are required for `proposed` → `accepted`, not prerequisites
to merely proposing the record. This lifecycle checkpoint records `status: proposed`; the following acceptance
record incorporates the already received human disposition of the frozen boundary.
Neither label itself authorizes shared-core changes; the required owner approval
and scoped RFC/ADR process must precede source modification. Default qualified
human review remains the exit gate before sensitive data, public release or
production/security/privacy claims.

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

These are candidate assessments, not completed human dispositions.

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

**Proposed, pending ratification:** adopt option A, with option B as the
default until A is approved, implemented, tested and reviewed. Only a
shared-core path gives the realm reader full admission without a signing oracle
or a second rule set. The exact boundary to be approved:

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

**V01–V14 of RFC-0032 are NOT RUN**; this draft adds and executes no test.
Design disposition and runtime/adoption acceptance are different phases. The
existing source probes and design reviews are the available research evidence;
a human decision must explicitly record the approved design/implementation
boundary, limitations and future gates under the canonical policy. This draft
supplies no such approval. Do not create a circular requirement that future
implementation tests already pass before deciding whether to authorize their
implementation, or relabel those unrun tests as passed design evidence.

**Implementation/adoption acceptance** requires behavioral RED → GREEN on the
subsequently approved implementation;
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

- Disposition: pending (draft; not accepted, rejected or withdrawn)
- Disposition rationale: pending
- Decision owner and identity: Cooldom66671 (technical, under the linked
  delegation); product/risk owner martadvix-web
- Pull request URL: <https://github.com/GOTD-GLOBAL/ParanoID/pull/88>
- Permanent disposition or approval evidence URL: pending
- Withdrawal author statement URL, if applicable: not applicable
- Delegation evidence URL: <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919>
- Required-review evidence URL: [exact-revision ADR draft review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5523363288)
  on `15e86b96658009cd452e4343809c057d15b3c04b`; the older RFC review remains separate. This is not human
  decision approval or an implementation/native review.
- Telegram message ID, sender mapping, timestamp, and exact approval text: not used
- Disposition date: pending
- Known limitations and follow-up: no implementation, test, harness or native
  memory evidence exists; open choices (operation name, projection
  version/fields, error mapping, output cap, discriminator, counting-sink
  design, entropy category, peak/latency budget, caller scheduling) await
  ratification; realm-reader integration and D87-06 remain separate decisions;
  shared current-state, threat and index documents are reconciled by the
  owning change, not by this file.

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
  on the RFC contract at `55364d7`; answers are not fabricated by this draft.
- Source baseline: [core lib.rs](../../clients/core/src/lib.rs), [clean_service.rs](../../clients/core/src/clean_service.rs), [C ABI](../../clients/ios/bridge/src/lib.rs), [key-protocol](../../key-protocol/src/lib.rs)
- Governance: [ADR-0001](0001-documentation-as-code.md), [ADR-0003](0003-closed-alpha-review-policy.md),
  [closed-alpha exception](../governance/documentation-policy.md#closed-alpha-review-exception)
- Supersedes: none
- Superseded by: none
