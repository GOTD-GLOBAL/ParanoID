---
status: draft
owner: ios
technical_component: shared-client-core
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
created: 2026-10-14
last_reviewed: 2026-10-14
last_reviewed_scope: draft review corrections and existing-API Linux entropy probes; no new validator implementation or Apple acceptance
---

# RFC-0032: Non-signing full core-state validation and public projection

**DRAFT — not an existing API, approved implementation or accepted decision.**
This is the separately scoped D87-07 proposal requested by the delegated
technical owner. It proposes an additive Rust JSON operation over the existing
C ABI, not a Swift state validator or a signing exception. General retained
schema-3 admission remains **blocked** until the RFC → ADR → required owner
approval gates and the real implementation, tests and review are complete.
[RFC-0030](0030-ios-identity-v3.md) and
[ADR-0017](../decisions/0017-ios-concurrent-identity-v3.md) remain `draft`.
No resulting ADR number is allocated here.

## Required review rationale

Protected domains are shared identity/key handling, cryptographic verification,
local persistence admission, public JSON API compatibility and native memory
boundaries. Reusing existing primitives does not make this an editorial or
unprotected refactor. Review must cover the whole call graph, including result
construction, not just a function named `validate`.

### Authority and evidence

- Human technical decision owner: **Cooldom66671**, under
  [martadvix-web's delegation](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
  Product priorities and human residual-risk ownership remain with
  **martadvix-web**; server/production actions require his case-specific approval.
- [Cooldom66671's D87 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187),
  posted on 2026-10-14 against `c66fcbc`, chooses direction A for D87-07 and
  explicitly requests parallel drafting with the namespace contract. Direction B
  (keep general schema-3 reopen blocked) remains the interim default. The record
  explicitly withholds permission to modify `clients/core`, `clean_service` or
  `key-protocol` before RFC → ADR → required owner approval.
- The previously missing bounded iOS source/local-test scope now has a direct
  [human confirmation by martadvix-web](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
  at `2026-10-14T15:59:07Z`, answering the
  [exact scope request](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785).
  That request covers private, informed alpha with public/synthetic/non-sensitive
  data and local component/native tests; it excludes merge, release, Apple-account,
  signing/export/TestFlight, phone, server/DB, live RPC, registration/replacement
  and server-login actions. It is not approval of this new shared-core contract.
- Older statements at the source baseline that #73 confirmation or the D87
  human record is still missing are stale on those two evidence questions.
  They do not negate the records above. Conversely, those records do not accept
  an ADR, pass any test or authorize this shared-core implementation. Canonical
  shared-document reconciliation is separate from this one-file draft.

The proposed `closed-alpha-ai` review mode uses the bounded second-human
exception in accepted [ADR-0003](../decisions/0003-closed-alpha-review-policy.md).
The empty reviewer list is not a claim of completed review or exemption from
review. Before implementation, record independent fresh-context review of the
exact proposal revision, reviewer/model, findings, resolutions and final report,
then the required human decision approval for the shared-core scope. No reviewer
or deadline has been assigned by this draft. A failed or incomplete review stays
open. Default qualified independent human review applies outside the bounded
exception, and remains an exit gate before sensitive use, public release or
production/security/privacy claims. Apply accepted
[ADR-0001](../decisions/0001-documentation-as-code.md) and the
[canonical approval policy](../governance/documentation-policy.md#decision-authority-and-acceptance-evidence).

## Summary

Propose `{"op":"validate_state_v3"}` on `clients/core::command(state, request)`.
For an admitted schema-3 state, perform all existing typed-state and semantic
checks without signing, protocol randomness, protocol-state transitions or
application I/O, and return only a versioned public credential/fingerprint and
retained enrollment projection. Required runtime hash-table seeding is accounted
for separately below; it is never a source of protocol material.
Never return or normalize the core state or produce a complete re-encoded
state buffer. The internal non-buffering serialized-size count defined below is
permitted; the caller retains exact input bytes and remains responsible for
storage authenticity, context, lease ownership and authority fencing.

This closes one necessary dependency of the iOS realm-store read contract. It
would not by itself deliver restart-keeps-login, server membership, owner
recovery, durable login orchestration or either concurrent runtime. Every new
behavioral/native acceptance row below is **NOT RUN**.

## Motivation

### Requirements and immediate dependency

[Requirements](../product/requirements.md) connect this proposal to:

| Requirement | Relevance; not a new claim of fulfillment |
| --- | --- |
| REQ-CLIENT-001 | iOS must use the real shared Rust state rules, not a second Swift interpretation. |
| REQ-MULTI-001 | Each realm must reopen only its own retained state; validation cannot silently transfer identity/trust across realms. |
| REQ-ID-002/003 | Recovering nickname authority is distinct from validating retained transport state or recovering history. |
| REQ-ID-005/007 | Preserve local key ownership, immutable credential/contact bindings and independent contact verification. |
| REQ-MSG-002/003/004/005 | Preserve retained history, replay/receipt rules, first-contact semantics and existing compatibility; no reset, pruning or proof substitution. |
| REQ-SEC-001 | Verify the no-sign/no-mutation boundary and document metadata/memory residuals before any security claim. |

The [realm-store preflight](../clients/ios/realm-store-preflight.md#verified-b-means-local-read-only-admission)
requires full non-signing Rust validation as item 5 of verified-B admission.
D87-05 therefore places D87-07 on the critical path to the D1–D3 goal: recover
a test nickname, log in to an existing server, then restart with login retained.
The namespace contract and this RFC may proceed in parallel. Neither alone
unblocks general schema-3 reopen; preflight R01–R12 and full MR gates remain
NOT RUN. The sibling namespace proposal is tracked through the preflight until
its own document is integrated; no unavailable local-file link is assumed here.

### Source-grounded problem

The source baseline for every range below is
`c66fcbc9961a29245bbbfbcd33ac1292a4338fae`. Ranges aid inspection; the named
symbols and linked files are the evidence. No native execution is inferred.

| Source | Established behavior at the baseline |
| --- | --- |
| [core lib.rs](../../clients/core/src/lib.rs), `command`, 438–454 | State limit is 8 MiB, request limit 65,536 bytes. A `serde_json::Value` request/state peek chooses the adapter; the typed `Request` or clean `Operation` remains authoritative. Adding only a clean-operation variant would not route all versions consistently. |
| [clean_service.rs](../../clients/core/src/clean_service.rs), `local_contact`, 237–242; `validate`, 277–363 | Every conversation verifies its peer contact, then recomputes its channel using `local_contact` at 311–315. That calls `ContactV2::create`, which signs with device auth. |
| Same file, `reply`, 372–405 | Independently of the validation loop, any retained fallback key causes `local_contact` at 382–386. Even a zero-conversation `view` with a fallback can sign. The reply also serializes secret state and plaintext dialogs. |
| Same file, `IdentityCredentialV3` branch, 885–895 | Deserializes the state/legacy identity and invokes `self_service::validate(&legacy)`, then returns credential/fingerprint. It bypasses full schema-3 `validate`; it is not a retained-state validator. |
| [contact_v2.rs](../../clients/core/src/contact_v2.rs), `bytes`/`fingerprint`, 14–26; `create`, 28–41; `verify`, 43–70 | Contact fingerprint excludes the contact signature. Creation signs; peer verification checks credential, bindings, canonical public keys and the actual device signature. |
| [intro_v2.rs](../../clients/core/src/intro_v2.rs), `channel`, 20–45 | Channel uses credential fields/fingerprints and contact fingerprints with fixed domain/profile and account sorting; it does not consume contact signature bytes. |
| [CoreBridge.swift](../../clients/ios/ParanoidKit/Sources/ParanoidKit/Core/CoreBridge.swift), `CoreReply`, 29–43; `command`, 58–77 | Replies without `state` are already representable (`state`/`stateVersion` are nil); the object can carry a new public projection. The bridge is synchronous, rejects interior NUL and copies/parses returned text. |
| [C ABI](../../clients/ios/bridge/src/lib.rs), `paranoid_core_command`, 102–129; `paranoid_core_free`, 139–144 | Two UTF-8 C strings go to the shared Rust command; errors become `{"error":"code"}`, caught unwinds become `native_failure`, and the returned allocation is freed by the caller. No new C export is needed. |

Signature-independent fingerprint inputs make a pure path feasible without a
transcript change. They do **not** prove that extracting it is trivial or that
existing public-view calls are already pure. No local signature may be replaced
with an empty/dummy signature inside a purported verified contact, and no peer
signature check may be skipped.

## Goals and non-goals

### Goals

- Add one read-only schema-3 validation/projection operation, available through
  the unchanged Rust entry point, JNI and C function signatures.
- Preserve every current full-state admission check and cryptographic transcript;
  make the protocol path unable to sign or generate keys, nonces, UUIDs or other
  protocol-random material; distinguish necessary runtime hash-table entropy.
- Return the smallest useful public fields for the existing proposed realm
  coherence checks, with explicit version, size and failure contracts.
- Keep source bytes immutable on success, refusal, cancellation and native failure.
- Provide behavioral differential tests, instrumented no-call evidence and an
  exact-head native memory/bridge acceptance gate before storage adoption.

### Non-goals

- No Swift mirror of Rust state/cryptographic rules; no `allowSigning` flag,
  temporary signing guard, consent bypass or environment switch.
- No state repair, upgrade, migration, pruning, candidate adoption, persistence,
  file/Keychain access, network, clock read, nonce/UUID generation, key generation,
  new protocol-session creation, encryption/decryption transition or receipt creation.
- No changes to global `Credential::verify`, identity-v3 UUID policy, server
  admission, RPC trust, wire formats, E2EE algorithms, pins or dependencies.
- No new app factory, realm writer, namespace identity, lease registry, runtime,
  login/consent policy, live membership proof or production readiness claim.
- No modification or removal of old operations, response shapes or refusal APIs.
  This RFC does not make `view` a safe replacement for the proposed operation.
- No source/runtime implementation, ADR acceptance, main merge, release, Apple,
  phone, server or DB action in this documentation task.

## Proposed design

All identifiers and contracts in this section that are not explicitly labelled
existing are **proposed**. Approval must ratify them before implementation.

### 1. Versioned request and dispatch

The proposed request is exactly one JSON object member:

```json
{"op":"validate_state_v3"}
```

`state` is the separate existing argument containing the exact raw core JSON
object, not a Snapshot wrapper, JSON string, base64 blob or request member.
The `_v3` suffix selects the core schema, not a network identity protocol or
permission to admit a server login. There is no requested projection mode,
expected realm, repair option, allow-sign flag or caller-supplied fingerprint.

Admission for this operation:

1. Apply existing raw UTF-8 byte caps before parsing either document. State and
   request whitespace count. C/Swift argument validity is addressed below.
2. Recognize the new operation independently of `state.version`, **before** the
   old whole-state `Value` peek or any old handler can run. Use a bounded
   duplicate-aware top-level request discriminator, then an exact typed request
   decoder on the original bytes; never deserialize from the peek's `Value`.
3. Require one decoded key `op`, one string value exactly `validate_state_v3`,
   and end of input after permitted JSON whitespace. Reject duplicates (including
   `op`/`\u006fp`), unknown/missing members, null, wrong types, arrays, comments,
   trailing commas/data, BOM and malformed JSON/UTF-8. Ordinary valid JSON escapes
   for the key/value are accepted and compared after decoding; the new realm
   metadata's escape ban is **not** extended to this core request.
4. A duplicate-op request mentioning this operation in **any** top-level `op`
   occurrence must refuse as `invalid_request`, in either order, without invoking
   an old mutating/signing handler. Nested strings containing its name do not
   select it. A malformed request never falls back. Do not use substring routing.
5. Requests not selecting the new operation retain the existing typed-dispatch
   behavior. Do not opportunistically rewrite all old admission semantics.
   Unknown operation names retain `invalid_request`; there is no version fallback.

A strict new unit request alone is insufficient if the outer `Value` peek has
already collapsed duplicate keys or routed by the last `op`. The discriminator
is part of the protected change and must have real entry-point tests.

For the selected operation, a bounded Rust root/version probe over the original
state requires an object and one unsigned integer `version` (no string, negative,
fraction/exponent, boolean or null coercion). It validates complete JSON syntax
and end-of-input without building a whole-state `Value` tree. A duplicate decoded
`version` is `invalid_state`. An otherwise syntactically valid root/version with
any integer other than 3 is `unsupported_state`, including 0, 1, 2 and future
versions; absent/invalid/out-of-u64-range version is `invalid_state`. The probe
is only dispatch admission, never state validity. For version 3, deserialize
**the original bytes** into the current typed `State` and run full validation.

Keep the pinned serde JSON recursion protection in both probe and typed parse;
do not disable it, recurse unboundedly, impose the realm metadata's depth-3 rule
on core state, or first parse the state in Foundation. Equivalent admitted
whitespace, key order, escapes and Unicode history remain usable verbatim.

### 2. Full validation without manufacturing a signed local contact

Proposed internal decomposition (not exported APIs):

```text
bounded request routing + raw state/version admission
  -> existing typed State decode
  -> shared immutable full-state validation
       clean identity + retained keys + enrollment + fallback binding
       each peer: unchanged ContactV2::verify
       local public contact inputs -> existing fingerprint/channel transcript
       all existing collections/session/outbox/commitment/event checks
  -> count-only existing snapshot-size check
  -> allowlisted public projection
```

Extract private immutable contact-transcript inputs from already validated local
`credential`, original `public` bundle and retained fallback public key. An
internal public-input type is not a `ContactV2`, not serializable as a contact,
and not an authentication token. Its construction cannot take an arbitrary
claimed local fingerprint, synthesize a signature or confer remote-peer trust.
A separate verified-peer path continues to call the actual `ContactV2::verify`.

Share the existing transcript encoder rather than maintain two copies. The old
`ContactV2::bytes`/`fingerprint` and channel construction may delegate to the
extracted pure helper, but their bytes/results and old externally observable
behavior must remain identical. Old contact creation continues signing its
actual transcript; only the new validation path avoids creation. No changes to
`key-protocol::transcript`, `digest`, `Credential::bytes/fingerprint/verify`,
`Introduction` signing/verification, frame2 or PlainV1 are proposed.

For a local endpoint, lack of fallback with conversations must still refuse;
no fallback is generated. For zero conversations and no fallback, a valid fresh
schema-3 identity can pass. For zero conversations with a fallback, validate the
retained fallback binding but never call the old reply contact builder. Local
secret/public consistency is still checked by deriving public keys from retained
secrets, not by generating keys or signing a test message. "Non-signing" does
not mean "does not read any private material": full pickle/key consistency
necessarily handles secret-bearing state in memory.

#### Runtime entropy is not protocol randomness

The literal initial zero-OS-RNG promise was contradicted by existing code.
`self_service::validate` calls `account(s)` → `Account::from_pickle`. In pinned
vodozemac 0.10.0, `From<AccountPickle>` converts `OneTimeKeysPickle`, whose
conversion creates a standard `HashMap`; its `RandomState` may obtain OS entropy
for hashing. This is required state reconstruction, not key generation or signing.
The [source-probe receipt](../project/evidence/core-state-validation-20261014/README.md)
records real existing-API Linux debug/release runs: cold workers made an entropy
call, repeated warmed calls did not. It is not new-validator or Apple acceptance.

Proposed corrected boundary:

- Signing, key/nonce/UUID generation, protocol RNG and protocol/persisted-state
  mutation remain forbidden on every success/refusal path, including RNG calls
  served from an already seeded generator without a new OS syscall.
- Runtime-internal entropy may occur only on evidenced, required hash-table
  seeding paths of state reconstruction/validation. It must not be exported,
  persisted or repurposed as protocol/key/nonce/identifier material. This is not
  an `allowEntropy` switch or a blanket allowance for every `getrandom` call.
- Attribute observations to the pinned call graph/call sites; syscall byte count,
  flags, warm-cache behavior or a convenient label alone are insufficient.
  Other randomness, including a new cryptographic RNG used only for verification,
  is outside this narrow runtime category. Unclassified/new entropy paths need
  investigation and explicit disposition,
  not automatic classification as harmless. Revalidate on supported native builds.
- Do not suppress Account validation, disable/change hash randomization or
  deliberately warm the measured worker to make a zero counter pass. Include
  cold-process, fresh-worker and explicitly warmed cases, with optimized builds.
  Instrument signing and protocol/key/nonce/UUID generation separately from OS
  entropy and report the runtime category separately.

This narrows an inaccurate draft promise to a testable application boundary; it
never permits signing on reopen, changes verification or proves that the future
operation already meets V07. The allowed runtime category still needs ratification
with this exact RFC contract and real platform evidence before adoption.

### 3. Exact preservation of existing checks

The following inventory is the minimum differential acceptance surface. Source
is [clean_service.rs](../../clients/core/src/clean_service.rs) unless stated.
It is not permission to replace code with a hand-maintained Swift checklist.

| Existing check / source | Required preservation in the new path |
| --- | --- |
| Typed `State`, `Conversation`, `Status`, `Event`, `Notice`, `ReceiptTarget` and nested `Client`/`Entry` decoding | Preserve current field types, required/default/optional behavior, enum values and `deny_unknown_fields` checks, including duplicate known struct-field rejection. Decode raw input, not a normalized dictionary. |
| `self_service::validate`, [self_service.rs](../../clients/core/src/self_service.rs), 80–124 | Legacy version 0; readable Olm Account, its public curve equals retained bundle; usable public one-time key; readable retained sessions; required identity; unchanged credential signature/account/Olm/realm and peer-credential checks; retained root/auth secrets derive the corresponding public keys. |
| `clean_identity`, 243–275 | Original bundle label `unassigned`; no legacy peer, peer credential, enrollment, grant, sessions, outbox, history, seen or rejection artifacts; zero legacy cursor/rejected count; no first rejected sequence; retain both secret/public checks. |
| `validate`, 277–301 | Outer version 3; cursor 0..100000; at most 64 conversations, 16 network-unverified peers and 64 rejected notices; any enrollment is active and matches own account/device/credential fingerprint exactly. |
| Fallback, 302–310 | When present, decode the retained Account fallback secret and require its derived public key to equal the retained fallback string. No reconstruction, publication or key generation. |
| Conversations, 311–324 | **Verify every peer's root credential and device contact signature**, realm/pin/Olm bindings, non-self account/curve, allowed original label and canonical public-key encodings. Map key equals peer account; channel recomputation identical; at most 8 sessions, 400 outbox entries, 1000 commitments and 1000 events from each peer. Decode each session pickle. |
| Commitments, 325–334 | Map key equals canonical UUIDv4 target ID; target channel equals conversation; sender equals own account; inner digest is hex32. |
| Outbox, 335–344 | Canonical UUIDv4 IDs, matching recipient, no duplicate pending IDs within the conversation, existing canonical bounded frame decoder and first decoded byte 2. Do not substitute ciphertext hashing or re-sign queued frames. |
| Events, 346–362 | Map key equals `sender:id`; canonical ID; sequence in 1..cursor, globally unique; sender has the matching conversation/channel; exact `PROFILE`; hex32 outer/inner digests. |
| `snapshot_size`, 365–370, called by `reply` at 373 | Preserve the 8 MiB **serialized typed-state size** admission check in addition to the raw input limit, without producing a serialized state copy. Defaults/escaping can make these two sizes differ. |

"Full" means the entire existing schema-3 admission surface, not proof that the
baseline implements every conceivable integrity check. For example, history and
rejected notices receive their existing typed decoding but `validate` does not
replay all historical messages or reauthenticate every retained outbox
introduction. Internal `Value` pickles and `BTreeMap` collections do not gain a
new recursive duplicate-key ban just because typed structs reject duplicates.
Preserve those baseline semantics; any discovered code/spec discrepancy or new
hardening requirement must be reported and separately dispositioned, not silently
weakened, tightened or called fixed by this RFC.

**Size-check implementation obligation:** replacing `reply` must not lose
`snapshot_size`. Prefer the existing pinned `serde_json::Serializer` writing
into a private, checked **non-buffering counting sink**. It may visit the same
typed `Serialize` representation and consume transient borrowed byte chunks, but
must not retain, log, return, persist or forward those chunks, allocate a complete
encoded-state buffer, or change the caller's original state. Internal streaming
for exact size counting is permitted; it is not a persisted-state rewrite.
Reuse the serializer's escaping, numeric formatting and field/default handling
rather than introduce a second hand-maintained JSON encoding engine.

Stop above 8,388,608 using checked arithmetic and an internal limit indicator;
map that intentional size refusal to `local_state_full`, not `state_error`.
Other counting/serialization failures remain `state_error`. Differential tests
must compare the count with the baseline serializer on synthetic fixtures,
including omitted defaults, control-character escapes, Unicode, numeric `Value`
cases and exact/+1 boundaries. No `to_vec(State)`, `to_string(State)` or old
`reply` in production merely to measure size. An alternative count-only design
requires the same exact-equivalence proof and explicit disposition. This is a
real implementation/review obligation; without it adoption remains blocked.

### 4. Minimal successful public projection

Proposed success is one UTF-8 JSON object with **exactly** these fields:

```text
{
  "validation_version": 1,
  "state_version": 3,
  "credential": {
    "root": string, "account": string, "device": string, "auth": string,
    "realm": string, "pin": string, "olm": string, "signature": string
  },
  "fingerprint": string,
  "enrollment": null | {
    "mode": "active", "account": string, "device": string,
    "credential": string
  }
}
```

This is a shape description, not an executed response or a usable credential.

| Field | Proposed value and meaning |
| --- | --- |
| `validation_version` | JSON integer 1, version of this local validation/projection contract. Strict consumers reject other versions; not negotiated down. |
| `state_version` | JSON integer 3, the fully checked core schema. No `state` member is returned. |
| `credential` | The exact existing eight-field public `Credential` values retained by `State.legacy.identity`; signature is the **already retained root signature**, verified, never newly produced. Root/auth are canonical unpadded Base64 public keys; account/pin/olm are lowercase hex32; device follows unchanged Rust canonical UUID admission; realm follows unchanged credential rules (HTTPS prefix, at most 512 UTF-8 bytes), not a new URL normalizer. |
| `fingerprint` | Existing `Credential::fingerprint()` lowercase hex32, not a contact fingerprint or raw-state hash. No Swift hashing. |
| `enrollment` | Null or the validated retained four-field `Status` exactly as above. Its `credential` equals `fingerprint`; it is **not** named `credential_fingerprint`. Absence is a local retained condition, not evidence that the server has no membership. |

All success fields are required, including explicit null enrollment; no `error`
member or extra diagnostic field is allowed. Proposed writer order is the shown
order, compact JSON with no BOM or trailing newline. Consumers use field names,
not object order. Only this small allowlisted object is serialized. Existing
credential values are not normalized, re-signed or regenerated.

The projection deliberately excludes `state`, `legacy`, Account/session pickles,
root/auth secrets, owner material, message text/history, dialogs, contacts,
fallback keys, outbox/ciphertext, rejected-event data, cursor, newly generated
signatures/proofs, challenge/session tokens, registry or login-success flags.
There is no generic "include extra fields" mechanism. The retained public root
signature is not a login proof and grants no new signing authority.

This supplies all Rust-owned comparisons required by the current proposed realm
reader: credential realm/pin versus Snapshot/outer context; credential and
fingerprint versus intent/result; enrollment versus the full retained commit
result. Membership UUID, generation, operation, nickname binding, terminal state
and their coherence remain the realm-envelope contract, not invented core fields.

### 5. Limits and error contract

These are proposed additions over existing bounds, not present API guarantees:

| Boundary | Limit / admission |
| --- | --- |
| Raw state argument | Existing maximum **8,388,608 bytes**, inclusive. New operation requires nonempty valid schema-3 JSON. |
| Raw request argument | Existing maximum **65,536 bytes**, inclusive, even though the new request has only one member. |
| Typed state encoded-length count | At most **8,388,608 bytes**, preserving the existing reply size gate independently of raw input size. |
| Successful projection / error JSON | Proposed maximum **8,192 UTF-8 bytes**, excluding C NUL terminator. The conservative shape bound below covers the fixed public fields and escaping of the existing bounded realm; real implementation tests still required. No truncation or partial success. |
| JSON recursion / dynamic state collections | Retain pinned parser recursion protection and every existing collection/frame limit. No larger limits, new dependency or additional per-history-entry ceiling. |
| Concurrent use by future realm reader | Proposed at most one in-flight validation per installation root, across both slots, with no unbounded pending-validation queue; reentry refuses at the caller. This is caller scheduling, not a new Rust global lock. |

**Conservative serialized-shape bound, not a runtime result:** the UTF-8 string
caps are credential `43,64,36,43,512,64,64,86`, fingerprint `64`, and enrollment
`6,64,36,64`: 1,146 value bytes in total. With fixed literal ASCII keys, compact
syntax and the fixed version integers, the non-value overhead is 229 bytes.
Overapproximating every value byte as a six-byte JSON escape gives
`229 + 6 × 1146 = 7105` bytes, below 8192; the finite error objects need at most
29 bytes. The [receipt](../project/evidence/core-state-validation-20261014/README.md)
contains the executed calculation and its deliberately non-credential dummy
values. The global verifier rejects noncanonical signatures by re-encoding,
so padding cannot inflate the admitted 86-byte signature. No new ASCII rule is
imposed on the existing 512-byte realm; valid Unicode/control-character escaping
is covered. Changing the projection/writer or adding fields invalidates this
specific proof and requires a new bound. This is not a peak-memory guarantee.

Return errors as the existing `Result<String, &'static str>` convention in Rust;
C/JNI wrap them into exactly `{"error":"<code>"}`. Proposed codes for this new
operation are finite and never include payload, parser excerpt, field values,
offsets, credential IDs or raw errors:

| Code | Proposed meaning |
| --- | --- |
| `input_limit` | Either raw core/request byte cap exceeded, before parsing. |
| `invalid_request` | New request fails exact admission; unknown operation. Existing C null/non-UTF-8 and Swift interior-NUL checks also use this code. |
| `unsupported_state` | Syntactically valid state object has a unique valid integer outer version other than 3. No upgrade or fallback is attempted. |
| `invalid_state` | Empty/malformed state, invalid version representation, typed decode failure, or any failed full semantic/cryptographic check, including invalid legacy shape/version. For this new operation only, collapse underlying credential/contact/session failure codes to this category. |
| `local_state_full` | Raw state fits but count of its typed serialized representation exceeds the existing snapshot bound. No pruning or serialization returned. |
| `state_error` | Internal count/projection construction failure; not proof of corrupt retained data. Fail closed and preserve input. |
| `output_limit` | Proposed fail-closed internal projection bound violation, never truncated success. Treat as contract/implementation failure, not fresh-install permission. |
| `native_failure` | Existing C/JNI caught panic boundary, not an ordinary invalid-state diagnosis. Swift also has its existing separate `.nativeFailure` for a null/non-object/broken native reply. |

Precedence: valid transport arguments → raw caps → exact request → state syntax
and version → full typed validation → typed-size count → projection/output bound.
C argument failures precede the Rust stages. Semantic sub-failures share
`invalid_state`, so no credential-first error oracle is promised. Old commands
keep their existing specific codes; this mapping does not rewrite those APIs.
No error implies that deleting bytes/keys, re-enrolling or replacing an identity
is safe. Resource failure or unsupported code must not become "no saved login".

### 6. Unchanged ABI and honest memory/cancellation boundary

Use existing `paranoid_core_command(const char *state, const char *request)` and
`paranoid_core_free`, as declared in
[paranoid_core.h](../../clients/ios/bridge/include/paranoid_core.h). No new ABI
symbol, length parameter, callback, handle, cancellation token or ownership rule
is proposed. A rebuilt native library is still necessary: unchanged ABI does
not mean an old binary understands the new operation.

Existing `CoreBridge.command` returns the new object with `CoreReply.state == nil`
and `stateVersion == nil`; `state_version` is a separate projection field, not
an attempt to change those accessors. A future isolated typed consumer must
check the exact projection shape/version and scalar types (no NSNumber boolean
or floating-point coercion), keep the selected raw state separately, and never
feed this reply to a candidate-save/adopt path. Do not weaken generic bridge
checks or change old consumers as a shortcut.

Memory facts from the linked sources matter:

- Swift `String` → C argument conversion creates NUL-terminated copies; raw
  core bytes must already be strictly decoded and bounded by the realm reader.
- The existing C core wrapper uses `CStr::from_ptr` before Rust length checks.
  It assumes readable terminated pointers and does **not** provide the Devnet
  wrapper's bounded pre-scan. Arbitrary invalid/nonterminated pointers are outside
  its safety contract. This proposal cannot claim pre-allocation bounds for an
  untrusted raw C caller or repurpose Devnet zeroization guarantees.
- The typed Rust state contains allocations. Existing
  [account/session helpers](../../clients/core/src/lib.rs), 212–219, clone
  secret-bearing `Value` pickles before reconstructing Account/Session objects.
  Removing whole-state peeks on the new route does not eliminate these copies.
- Rust/C response allocation, Swift response text, Foundation object decoding
  and `JsonSpan` also copy. The small public projection avoids a second secret
  state/dialog reply, but this is neither zero-copy nor guaranteed erasure of
  original Swift/Rust secret-bearing buffers. Existing core free only frees.

The call is synchronous and must run off the UI/main executor. Cancellation
cannot interrupt Rust through this ABI, reclaim its inputs early or prove
immediate secret erasure. A future caller keeps the buffers and in-flight slot
alive until return, then discards a cancelled/stale result and frees the native
reply exactly once. Cancellation must not start unlimited replacement calls.
Caller context/revision/lease checks are required both before dispatch and before
publishing a read result; the pure return is not a transferable authorization
capability. Do not claim a hard CPU deadline or a total-process memory ceiling
from byte caps alone. Measure and approve native peak bounds before adoption.

### 7. Realm-read integration and remaining authority

The new operation would satisfy only the Rust-validation part of
[verified B](../clients/ios/realm-store-preflight.md#verified-b-means-local-read-only-admission).
The realm reader must still establish, and fence through completion:

1. Exclusive lease/holder/incarnation and trusted root; actual distinct key
   namespaces, not Swift object identities.
2. Catalogue/install continuity, exact installID/ownerRef and both full realm
   tuples; allocated owner/B and matching confirmed binding; no common pending
   artifacts or uncertainty.
3. No-follow artifact/parent inspection, B key/file continuity and actual loaded
   namespace/policy identity; no B temp/intent or known key substitution.
4. Authenticated bounded envelope, exact binding/context and any available
   validated owner comparison; an inaccessible owner is not freshly validated.
5. This operation succeeds and its public projection matches wrapper/slot and
   retained intent/result/enrollment/terminal rules. Status alone never supplies
   a missing full result.
6. No creation, signing, network, adoption, cleanup or durable reconciliation
   occurs as part of the read.

These are local storage conditions, not evidence of live membership, fresh
registry finality or UI/transport authority. Under the first-slice precisely
classified owner lock/freeze, **all realm writes remain forbidden**, including
bookkeeping and journal cleanup; a successful pure read changes none of that.
Sibling containment requires verified common/B integrity, not just Rust success.

The existing **clean schema-0 discarded `upgrade_v2` dry-run** remains the
separate narrow path documented by the preflight. It validates the clean
intermediate and discards the returned upgrade; only explicit continuation may
commit it. It is not arbitrary legacy migration and must never be generalized
to schema-3 `view`. This new operation rejects schema 0 rather than silently
upgrading it. Missing this validator in a linked build means schema-3 admission
stays unavailable, not that `identity_credential_v3` or signing is substituted.

## Alternatives

| Alternative | Assessment against full validation, no signing and compatibility |
| --- | --- |
| **A: additive pure Rust validation plus minimal projection** | Preferred direction under D87-07. Keeps one semantic authority and permits useful local coherence checks, but requires real refactoring, dispatch/size equivalence evidence and protected approval. |
| **B: keep arbitrary retained schema-3 reopen blocked** | Required interim default; safe and honest, but leaves the restart-keeps-login dependency unresolved. It remains the rollback behavior when A is unavailable or unverified. |
| Call `view` and discard its result | Rejected: both validation and reply can sign; reply reserializes secrets/history. Discarding output does not undo signing or memory exposure. |
| Use only `identity_credential_v3` | Rejected: legacy identity validation misses full conversation/session/event/enrollment checks. Public output is not full validation. |
| Mirror checks in Swift or inspect only JSON shape | Rejected: creates divergent crypto/state authority and misses real Account/session validation; envelope parsing is not core admission. |
| Temporarily enable signing on reopen or add a "no-sign" runtime guard | Rejected: violates D87-07, obscures call-graph safety and creates a bypass/failure mode. Test-only observation of actual signing is different from a production guard. |
| Build a dummy unsigned `ContactV2` and skip verification | Rejected: confuses local transcript inputs with authenticated remote contacts; permits accidental serialization or verification bypass. |
| Return the full old view or invent a new C ABI | Unnecessary for this narrow projection; increases secret copies or integration surface. A future broader projection/ABI requires its own reviewed contract. |

## Security and privacy

This is a proposed delta to the
[iOS identity-v3 threat analysis](../security/ios-identity-v3-threats.md) and
[threat-model storage boundary](../security/threat-model.md#trust-boundaries-to-define).
Assets are retained root/device/Olm secrets and ratchets, immutable identity and
peer bindings, stored plaintext/history, realm continuity and authority to sign
or adopt state. Inputs can be corrupt, attacker-modified, replayed or maliciously
structured even after AEAD open (for example, compromised producer or stale
valid ciphertext). The OS, trusted local caller/backends and correct native
binary remain trust assumptions; an in-process compromise is not contained by
a read-only JSON verb.

| Threat / source basis | Proposed control and acceptance mapping | Residual / disposition |
| --- | --- | --- |
| Reopen becomes a signing oracle through `local_contact` or `reply` ([clean source](../../clients/core/src/clean_service.rs)) | Separate immutable validation and allowlisted projection; no old reply call; instrument actual device/root signing and protocol/key/nonce/UUID generation, including zero-peer fallback; attribute runtime entropy separately. V01/V07/V08. | Secret/public derivation still reads private state. No approved implementation exists yet. |
| Warm fixture setup hides entropy or OS-only counting misses seeded protocol RNG | Separate forbidden signing/protocol-generation counters from attributed runtime hash seeding; cold-process/fresh-worker and warmed controls in debug/optimized builds. V07. | Required Account reconstruction can seed `HashMap`; no blanket syscall whitelist, weakened validation or disabled hash randomization. |
| Forged peer contact passes because fingerprint excludes signature ([contact source](../../clients/core/src/contact_v2.rs)) | Retain actual `ContactV2::verify` before channel acceptance; corrupt/missing/noncanonical signatures fail even when fingerprints/channel are unchanged. V03/V04. | Signature verification is not out-of-band human identity verification. |
| Local helper changes transcript/order/encoding ([channel source](../../clients/core/src/intro_v2.rs), [protocol](../protocol/first-contact-v1.md#immutable-channel-and-framing)) | Byte-identical LP/domain/profile/account sorting and old/new credential/contact/channel differential vectors. V04/V13. | Duplicate implementations are discouraged; independent vectors must not merely call the same new helper twice. |
| Credential-only success admits corrupt enrollment/session/replay state ([legacy-only branch](../../clients/core/src/clean_service.rs)) | Full inventory above, genuine populated fixtures and one-defect-at-a-time negatives. V02/V03/V05. | Preserves baseline checks, not historical-message reauthentication or repair. |
| Duplicate request fields divert validation into creation/signing ([outer dispatch](../../clients/core/src/lib.rs)) | Duplicate-aware raw discriminator and exact typed request before state routing; both duplicate-op orders and escaped-key collisions. V06/V07. | Old operation admission remains separately tested; no global parser tightening hidden here. |
| Secret state/history escapes in reply or logs ([old reply](../../clients/core/src/clean_service.rs), [Swift reply](../../clients/ios/ParanoidKit/Sources/ParanoidKit/Core/CoreBridge.swift)) | Exact public-field allowlist, fixed errors, no state/dialog serializer, no payload logging; canary and shape tests. V08/V09. | Public credential/account/device/realm/enrollment are linkable metadata, not anonymous or suitable for automatic telemetry. |
| Malformed/large state causes allocation or CPU exhaustion ([input caps](../../clients/core/src/lib.rs), [pickle helpers](../../clients/core/src/lib.rs)) | Preserve raw/encoded-size/collection/depth bounds; bounded public output; one in-flight caller; exact-head caller-lifetime checks and simulator peak measurements. V09/V10/V12. | Byte caps do not prove small peak memory or bounded wall time; C pointer preconditions, OOM/abort and shared-device pressure remain. |
| Stale/cross-realm projection becomes UI/login authority ([verified B](../clients/ios/realm-store-preflight.md#verified-b-means-local-read-only-admission)) | Caller compares full context/credential, checks all six conditions and fences lease/incarnation/revision after return. V11. | Validator cannot verify filesystem/Keychain identity, owner binding provenance, server state or current registry. |
| Cancellation releases buffers or a newer call adopts old success ([synchronous bridge](../../clients/ios/bridge/src/lib.rs)) | Keep buffers/slot until return; exact-once free, no late publication, no unbounded replacement tasks. V10/V11/V12. | No in-call cancellation or immediate zeroization guarantee; caller lifecycle remains a separate integration gate. |
| Old state/binary is normalized, upgraded or reset on refusal ([preflight](../clients/ios/realm-store-preflight.md)) | No state output/rewrites; unsupported version/binary fails preserving bytes; no legacy fallback. V08/V14. | Not anti-rollback. A previously valid state can still be stale; physical-device protection and restore safety are separate. |

No new network observer or server field is introduced. Returning public values
locally does not make them non-sensitive telemetry: no raw request, projection,
credential, fingerprint, signature, snapshot, plaintext, key or proof logging.
Synthetic fixture receipts may identify fixture names and counts, never real
stored data. Human residual-risk owner remains martadvix-web; technical
correctness disposition remains with the delegated owner and required reviewers.
The shared threat documents must be reconciled before adoption; this draft
contains the analysis but does not silently edit or accept those documents.

## Compatibility and migration

| Surface | Proposed compatibility guarantee / refusal |
| --- | --- |
| Existing Rust commands, Android JNI and iOS C entry points | Additive verb only; old command request/response/error contracts remain intact. Test old supported flows against rebuilt native artifacts, not just source. |
| Schema-3 storage and cryptographic material | No version bump, field addition, normalization, ratchet advance, signature replacement or persistence. Input bytes remain caller-owned and byte-identical. |
| Fingerprints, contacts, channels and pending frames | Exact existing LP/SHA256 construction, domain strings, profile and ordering. Existing contact signatures remain mandatory; pending ciphertext/introduction bytes are never rewrapped. |
| Existing serde state admission | Preserve typed defaults/optional forms, map/Value behavior and parser bounds. Strict new request handling does not silently tighten old core or realm-format grammars. |
| Old binary receiving the new verb | Refuses `invalid_request` under existing typed decoders; no fallback to `view`, `upgrade_v2`, credential-only validation or fresh identity. Consumer requires the new native implementation. |
| Core versions 0/1/2/future | New operation refuses `unsupported_state` under the version contract. Clean schema-0 continuation remains a distinct preflight path, not a migration added here. |
| Global credential device UUID admission | **Unchanged**: canonical UUID text, not newly forced v4. `Identity::create` generates v4 ([key source](../../key-protocol/src/lib.rs), 42–56 and 81–104). Preserve non-v4 canonical retained credentials where the current shared verifier admits them. |
| Server/wire/registry | No routes, schemas, login proofs, global verifier rule, server generation or membership policy changes. No deployment or data migration is needed for the local verb. |

**D87-06 remains separate.** The identity-v3 document's UUIDv4 requirement versus
the global verifier's canonical-only device rule requires its own boundary and
retained-credential policy. D87-06's read-only inventory on both existing servers
is Sergey's separately authorized live action. It is **not a prerequisite** to
this RFC's pure validator, the parallel namespace contract or their local tests.
Do not tighten `Credential::verify`, normalize signed IDs, regenerate identities
or fabricate an inventory result here. A regression should distinguish generated
v4 identities from admitted canonical retained non-v4 identities.

Roll out only after the gates below: approved core contract/refactor and tests;
rebuilt C/JNI artifacts with exact-source correspondence; isolated typed iOS
consumer and native evidence; then separately reviewed realm-store adoption.
No core/API-only result closes D1–D3 or MR-16. App/login, current-server peer and
physical restart acceptance retain their own scope and explicit per-action go.

Rollback disables the new consumer and preserves retained data. Once allocated
realm state exists, follow the preflight's compatible full-state reader or stopped
preserved-installation rule. Do not revert to an old reader that might recreate
identity after catalogue loss, delete keys/files, restore older ratchets or lower
server generations. This local verb adds no persisted marker to remove.

## Operations and observability

There is no service deployment, new endpoint, configuration flag, background
worker, telemetry upload or database operation. Build provenance must identify
exact shared-core and bridge revisions, target/configuration and linked native
artifact; an unchanged C signature does not establish artifact compatibility.
Do not provision a new server stand or rerun the unchanged application and call
that progress on this validator.

A future consumer may expose fixed local failure categories and bounded timings
without payload/identity labels. Unsupported validator/build mismatch should be
reported as unavailable admission; preserve the installation rather than infer
corruption or fresh setup. For a suspected invariant violation, stop adoption,
retain encrypted evidence under existing policy and use
[private security reporting](../../SECURITY.md). Do not collect real snapshots
or crash payloads as debugging fixtures. No new backup, key-deletion or recovery
procedure is introduced.

Capacity evidence must distinguish raw state bytes, typed-size count, projection
bytes, elapsed validation time and measured peak memory. Do not claim that
8 MiB state means an 8 MiB working set. Existing validation scans events per
conversation and decodes transient pickle objects; collection limits bound the
input, not a constant-time algorithm. Preserve logic before optimizing it, and
report worst-case synthetic measurements and unresolved resource risks.

## Validation plan

### Evidence discipline

**All V01–V14 below are NOT RUN.** They describe acceptance for later approved
implementation, not tests added or executed by this draft. Existing core/bridge
suites are sources for fixtures and regression scope, not proof of the new verb.
The realm-store R01–R12 and application MR rows also remain NOT RUN.

Use behavioral RED → GREEN: after approval, introduce an inert compiling seam,
observe a discovered test fail because the new behavior is missing, implement
minimally, then rerun regressions. A missing symbol/SDK, failed linker, skipped or
undiscovered test is not behavioral RED. Existing already-green negatives are
regressions. Reverted test-only mutation probes prove sensitivity, not historical
pre-implementation RED. Keep exact revisions, commands, real counts/skips and
unmodified logs; never replace test assertions with source grep.

### Acceptance matrix — proposed, NOT RUN

| ID | Behavioral RED / required GREEN oracle | Coverage and mapping |
| --- | --- | --- |
| V01 | Inert operation fails success assertions → real fresh schema-3 without fallback, zero-peer retained fallback, active enrollment and populated conversations all return exactly the minimal projection; no old reply is used. | D87-07; REQ-CLIENT-001; preflight R07/R09. |
| V02 | Missing full validation is caught → differential corpus agrees with baseline schema-3 `view` admission for valid/invalid fixtures after the new error mapping; each inventory row has individual negative coverage. | Legacy cleanliness, identity/root/auth/account/pickle consistency, cursor, counts/trust, enrollment, fallback, sessions, commitments, outbox and events; REQ-SEC-001. |
| V03 | Removed peer verification makes a specific assertion fail → corrupted, missing, noncanonical or wrong-key contact/credential signature refuses, including tampered contact signature that leaves its fingerprint/channel unchanged; cross-realm/pin/self/bundle substitutions refuse. | Actual cryptographic verification retained; REQ-ID-007; no trust upgrade. |
| V04 | Altered domain/order/fallback/account sorting is detected → old signed-contact and new public-input fingerprints/channel bytes match independent existing LP vectors in both endpoint orders, crossing and original bundle labels; changed bound input changes/rejects as before. | [Independent test helpers](../../clients/core/tests/clean_first_contact.rs) `contact_fingerprint`/`channel`; no new transcript, no fake signed contact. |
| V05 | Omitted collection/state check fails its assertion → exact existing boundaries and +1 cases, duplicate pending IDs, commitment IDs/senders/channels/digests, replay keys/sequence collisions/profile/channel, invalid session/fallback and frame2 checks all match old admission. | REQ-MSG-002/003/004/005; retain unlimited-count history within the state-size bound and optional `local_ms`. |
| V06 | Naive peek/dispatch accepts or misroutes a negative → raw entry-point tests reject duplicate/escaped-duplicate op keys in both orders, including `create_identity`/signing/upgrade alternatives, unknown fields/types/trailing input and unsupported versions; valid escaped operation spelling works. | New route independent of state version; missing/negative/fractional/duplicate/out-of-range version; no effects on refusal; old dispatch regression. |
| V07 | Positive controls observe actual signing and protocol/key/nonce/UUID generation; every new-operation success/refusal invokes those forbidden paths zero times, even when a seeded generator would need no OS call. Cold-process, fresh-worker and explicitly warmed cases separately capture/attribute necessary runtime hash seeding. Deliberate forbidden-call probes must fail. | Cover actual root/device signers and protocol RNG/generation as well as OS entropy in debug/optimized builds; classify only evidenced runtime paths, not every 16-byte draw or syscall flag. Unknown paths remain unresolved; no warm-up workaround, disabled hash randomization, skipped Account validation or production bypass. |
| V08 | A state/reply reuse leaks a canary or changes bytes → exact input bytes equal before/after each success/refusal, repeated call and C/Swift transfer; reply key allowlist and secret/plaintext canaries exclude state, pickles, history and secrets. Source secret buffers are never passed to the result serializer. | No complete encoded-state buffer or state return, no persistence/clock/network invocation; no use of canonicalized fixtures as byte-preservation proof. |
| V09 | Removed raw/typed/output bound or incorrect counter is caught → exact cap/+1/overflow cases, whitespace/escape/default expansion and deep parser refusal; count-only size equals baseline serialization for synthetic corpus; output bound covers maximum admitted public fields and never truncates. | Core 8,388,608; request 65,536; proposed reply 8,192; error precedence and fixed no-payload codes; no broad state grammar tightening. |
| V10 | Wrong ownership or shape fails → real C link/run, Rust result/error/panic mapping, valid terminated null/non-UTF-8 negatives, Swift `state == nil`, strict typed projection/version refusal, no candidate-save path and exactly-once free on success/error/consumer failure. | Unchanged ABI, rebuilt artifact, real Rust call rather than mocked successful response; invalid pointers are not test inputs under the C safety contract. |
| V11 | Missing caller fence accepts stale/foreign success → cancellation/close/lease loss/revision change before and during synchronous validation suppress publication, retain buffers until return and prohibit replacement-call accumulation; full context/intent/result mismatch refuses without writes. | Later isolated realm integration; all six verified-B conditions, owner-locked write refusal, no server-membership assertion. Namespace/storage evidence remains separate. |
| V12 | Native memory measurement is absent or records only net delta → `xcodebuild test` simulator harness records `XCTMemoryMetric` plus justified **actual numeric peak** instrumentation over real decrypt/parse/transfer/Rust/projection, largest admissible success and refusal fixtures, repeated runs and retained sibling state. | D87-03; preflight R07; no test-runner/build success or Linux substitute; approved memory budget and exact-head evidence required before adoption. |
| V13 | A helper extraction changes existing behavior → supported core, key-protocol, identity-v3, directory, first-contact, receipt/replay, time and call suites plus real Android JNI/host and existing iOS core/bridge/package paths pass on rebuilt artifacts. | Old signing operations still sign, old wire bytes/public values/admission/errors unchanged. Historical failing legacy tests run/report separately, never hidden or called fixed. |
| V14 | Fallback or tightening changes retained compatibility → old binary rejects the new verb without state effects; schema 0/1/2/future refusal, separate clean schema-0 dry-run and v4 Snapshot preservation; generated device v4 versus canonical retained non-v4 cases; no global verifier change. | D87-06 separation; no migration, reset, new live inventory dependency or substituted full validator. |

The V02 baseline oracle may sign during **synthetic fixture/baseline execution**;
that does not permit signing in the measured new path. Prepare fixtures outside
the measured worker, then preserve first-use behavior for cold-worker/process
cases; never present fixture-warmed zero OS calls as evidence of no protocol RNG.
Run explicit warmed controls separately. Isolate measurements so parallel tests
cannot hide or inflate counters. Review coverage against the pinned dependency
call graph; a wrapper missing an underlying signer or seeded protocol RNG is not
evidence. Retain positive controls and deliberately failing forbidden-call probes
alongside zero forbidden-call counts and separately attributed runtime entropy.
The existing-API counterexample in the receipt is research, not a passing V07.

### Native memory acceptance

D87-03 selects `xcodebuild test` on an iOS simulator with `XCTMemoryMetric`.
The inspected preflight explicitly reports no current suitable peak-memory
harness; this RFC does not claim one exists. The later handoff must name the
actual test target/filter, simulator/runtime, build configuration, linked Rust
artifact and measured process. Do not publish a guessed runnable command for a
nonexistent test target.

Record numeric transient **peak bytes**, interval, samples/repeats, measurement
method, baseline conditions and limitations. `XCTMemoryMetric` before/after
change alone is not the transient peak: supplement it with justified peak
instrumentation and retain both quantities distinctly. Include decrypt/parser,
Swift-to-C copies, Rust typed/pickle allocations, size counting and reply decode;
a core-only benchmark misses the selected acceptance interval. Include boundary
success/refusal and repeated-call release behavior, not only a small fixture.
The technical owner must ratify the quantitative peak/latency budget before
adoption; no budget or measurement is invented here. Missing harness, peak data
or agreed threshold keeps the resource gate open. Simulator evidence is not
physical-device memory, lock, power-loss or restart evidence.

## Open questions

All deadlines are **unassigned**; `draft` status is intentional. Approval of a
preferred direction is not approval of each detail below.

| Decision still required | Responsible decision / evidence |
| --- | --- |
| Ratify `validate_state_v3`, projection version/fields, error mapping and 8,192-byte output cap, versus another explicitly versioned local contract. | Cooldom66671 within the delegation; required shared-core owner approval and independent design review before code. |
| Select the exact internal transcript-input/verified-peer separation and prove non-buffering counting-sink equivalence without a complete encoded secret-state buffer. | Shared-core implementation/review under the technical owner; no missing-check or secret-buffer shortcut. |
| Ratify the duplicate-aware outer discriminator and compatibility corpus, including probe/parser recursion behavior and unchanged old dispatch. | Technical owner and independent reviewer; source/behavioral evidence required. |
| Ratify the narrow runtime hash-seeding category and specify trustworthy sign/protocol-generation/entropy attribution with cold-process, fresh-worker, warmed and optimized controls. | Implementation review; model/author self-assertion or grep is insufficient. |
| Define simulator peak instrumentation, numeric budget and elapsed-time acceptance for bounded worst-case state, with caller scheduling/lifetime policy. | Cooldom66671 and the selected native test handoff; no current harness/result/deadline claim. |
| Confirm the narrow shared-core implementation scope and resulting ADR disposition under the required human approvals. | Technical owner plus any scope/risk decision reserved to martadvix-web; #73 is source-scope evidence, not this API's approval. |
| Integrate the resulting validator with the independently approved namespace/realm-reader contract and all six verified-B conditions. | Separate storage task/review after the real validator passes; not a reason to serialize the two draft workstreams. |

D87-06's v3-only UUID enforcement/retained policy and Sergey's live inventory
remain separate decisions, not unresolved prerequisites added to this RFC.

## Decision and follow-up

- **Disposition:** DRAFT direction-A design for review; direction B remains the
  operational default. No RFC completion or accepted architecture.
- **Decision-owner approval permalink for this exact contract:** none yet.
  [D87-07 technical direction](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187)
  authorizes this drafting direction, not its shared-core implementation.
- **Delegation evidence:**
  [martadvix-web → Cooldom66671](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919).
- **Bounded iOS source-scope evidence:**
  [human confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
  to the exact request linked above; no live/merge/release authority.
- **Required-review evidence:** not yet available for this RFC or implementation.
  No AI review is recorded as human approval.
- **Resulting ADR:** not created or numbered. Allocate only after checking then-current
  published refs; record exact decision, scope, risks, approval and required review.
- **Closure/replacement RFC:** not applicable while draft; no replacement selected.
- **Implementation issues:** not created by this task. D87-07 is tracked in PR #87;
  preflight R07/R09/R10 and RFC-0030 D1–D3 identify its consumers.

Required sequence, with no gate implied passed:

1. Independent exact-draft design/security review; human disposition of the open
   contract choices; separately scoped ADR and required owner approval **before
   any shared-core/key-protocol/clean-service modification**. No normative decision
   is manufactured by merging this draft.
2. Approved local shared-core implementation with behavioral RED/GREEN, actual
   no-sign/no-protocol-generation instrumentation with runtime entropy attribution,
   differential validation/transcript/size tests,
   bounded response and independent exact-source review. Keep dependencies and
   old commands unchanged; stop and disposition any required scope expansion.
3. Rebuilt C/JNI artifact and existing Android/iOS regression evidence, then
   exact-head native simulator memory evidence under the approved test scope.
   A passing Linux test or unchanged Mac application receipt cannot replace it.
4. Separately reviewed realm-reader/namespace integration and remaining
   preflight acceptance. Only the resulting real validated path can lift the
   schema-3 read blocker; neither this RFC nor an unimplemented ADR can do so.
5. Reconcile shared current-state, API/component reference, threat documents,
   RFC index and eventual decision log through their owning change before
   adoption/publication. Initial authoring created only this RFC; publication adds
   explicit evidence/navigation/status documents, not runtime source changes.
6. Preserve separate application/login, native/phone restart, both-realm peer,
   live-action, merge and release gates. No passing component row is full
   restart-keeps-login or MR-16 acceptance.
