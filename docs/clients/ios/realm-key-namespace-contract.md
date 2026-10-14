---
status: draft
owner: ios
decision_owner: Cooldom66671
product_decision_owner: martadvix-web
review_mode: closed-alpha-ai
created: 2026-10-14
last_reviewed: 2026-10-14
---

# DRAFT realm wrapping-key namespace and readback contract (D87-02)

Supporting contract for [RFC-0030](../../rfcs/0030-ios-identity-v3.md),
[draft ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md) and the
[realm-store preflight](realm-store-preflight.md). **Not implemented, normative,
or an ADR acceptance.** All new interfaces, query recipes, literals and tests
below are proposals. This document supplies the D87-02 design and native
handoff, not a Swift patch or a passing Keychain receipt.

## 1. Scope, authority and evidence boundary

Source baseline: `c66fcbc9961a29245bbbfbcd33ac1292a4338fae`. The parent task
verified the human [D87 technical record](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187)
from `Cooldom66671`, including the request to draft D87-07 and this namespace
contract in parallel. The [delegation](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919)
is bounded; product/risk authority remains with `martadvix-web`. The parent's
verified [scope confirmation](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046)
answers [the bounded request](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6153528785).
The older baseline statements that #73 has no authenticated confirmation are
stale, not a new blocker reintroduced here. Integration of those provenance and
current-state corrections belongs to the parent documentation change.

That scope is private, non-sensitive alpha source/local-test work. It does not
approve these new details as a permanent architecture or grant live RPC,
server/DB/user/phone operations, Apple-account actions, deployment or main merge.
Initial authoring wrote this document only; publication adds explicit documentation
pointers. No Keychain call, Apple-native test or fixture
cleanup is performed. Accepted [ADR-0001](../../decisions/0001-documentation-as-code.md),
[ADR-0003](../../decisions/0003-closed-alpha-review-policy.md) and the
[protected-domain review policy](../../governance/documentation-policy.md#protected-decision-domains)
remain in force. Independent exact-revision review and human technical
disposition of unresolved choices precede implementation/adoption.

D87-07's parallel **RFC-0032, `docs/rfcs/0032-core-non-signing-state-validation.md`**,
proposes the pure full-schema-3 observer. It is not present in this baseline;
refer to the [existing validation blocker](realm-store-preflight.md#structural-coherence-not-proof-authority)
until the sibling document is integrated. A draft RFC is not the implementation
needed to unblock general schema-3 reopening. Shared `clients/core`,
`key-protocol` and `clean_service` changes require separately scoped
RFC → ADR → required owner approval; this document authorizes none.

### Existing source facts, not new defects in the closed owner review

| Source at the baseline | Established fact and limit |
| --- | --- |
| [OwnerAppleAdapters.swift](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerAppleAdapters.swift), `OwnerKeyBackend`, lines 31–40 | Refines `WrappingKeyStore` with `storedPolicy()`: accessibility and synchronizable only. It does not expose complete namespace evidence. |
| Same file, `OwnerKeychainKey.identity/load/storedPolicy/create`, lines 70–154 | Identity query contains generic-password class, account and `kSecUseDataProtectionKeychain = true`; service/access group are omitted. `load` and attributes are separate `kSecMatchLimitOne` queries. Missing synchronizable readback falls back to false. Creation uses the canonical owner policy. These facts are not a complete item/cardinality proof. |
| [CatalogueAppleAdapters.swift](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/CatalogueAppleAdapters.swift), lines 332–362 | Four explicitly supplied backends, but no assertion that their effective Keychain queries are disjoint. Distinct Swift values do not prove that. |
| [KeychainKey.swift](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/KeychainKey.swift), `identity/load/create/deleteRetained` | Legacy messaging account is `paranoid-text-state-v0`; account-only selector within class/domain, messaging accessibility, non-synchronizable creation. Existing deletion broadens to synchronizable-any. It is not a new realm backend. |
| [OwnerNamespaceLease.swift](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/OwnerNamespaceLease.swift), `acquire/claim/retire`, leased wrappers | One holder/coordinator per supplied lease instance. No OS-global namespace registry, multiprocess exclusion or defense against a trusted caller creating another lease for the same root. |

The #85 P2 corrections remain closed within their reviewed trusted-backend
scope. This is a stricter **successor realm boundary**, not a claim that #85
promised this API, and not a request to change old methods, defaults, errors,
refusal tests or retained items. No automatic conformance, migration or reset.

## 2. Separate namespace, policy and authorization

Use three distinct concepts:

1. **Query namespace**: what items the actual operation can select. It includes
   class, service/account predicates, access-group selection, synchronizable
   selection and platform/keychain domain. The exact query builder, not a label
   returned by an arbitrary backend, supplies the evidence.
2. **Stored policy and material observation**: attributes associated with the
   item whose key was actually loaded, with opaque material continuity checked
   inside the trusted backend. It is not inferred from the requested policy.
3. **Authority**: the live lease/holder/incarnation and one-use operation permit.
   A namespace descriptor, key, allocation flag or successful read creates no
   signing, mutation, server-membership or cleanup authority.

Apple documents generic-password uniqueness as a composite primary key of
access group, account, service and synchronizable; accessibility is a
non-primary attribute.[11] Thus different accessibility, backend object IDs,
Swift types, paths or slot labels cannot establish distinct Keychain items.
A full `(origin, pin, protocol)` remains the realm trust identity; neither a
Keychain account nor `fi`/`ru` replaces it.

### Proposed typed boundary

These are **semantic signatures**, not existing Swift declarations. A future
implementation must make evidence/permit constructors private to their trusted
issuers; do not translate the notation into public structs with arbitrary
memberwise initializers.

```text
RealmKeyBackend                         // standalone, not RetainedKey inheritance
  intendedNamespace: RealmNamespacePlan // immutable, tied to actual query builder
  inspect(scope) -> Absent | PresentMetadata | Unavailable | Ambiguous | Invalid
  loadBound(scope) -> Absent | BoundRealmKey | Unavailable | Ambiguous | Invalid
  createOnly(consuming permit, journalReceipt) -> UnverifiedCreatedKey
  readBack(created, scope) -> BoundRealmKey | Failure

RealmNamespacePlan = (role, installID, ownerRef, fullRealm, queryPlan,
                      explicitCreationAttributes, resolvedAccessGroup)
BoundRealmKey = (opaqueKeyHandle, actualIdentity, actualPolicy,
                queryEvidence, observationScope)
ObservationScope = (sameLease, holder, coordinatorIncarnation, operation,
                    retainedRevision, namespacePlanRevision)
```

`PresentMetadata` is not a usable key and does not grant adoption. `Absent`
has no stored policy/identity. `UnverifiedCreatedKey` cannot seal, decrypt,
construct core state or leave the backend verification path. The only proposed
realm-crypto admission is a `RealmKeyBackend` plus the validated four-role
namespace context; it accepts no generic `WrappingKeyStore`/`RetainedKey` or
`OwnerKeyBackend` overload, cast fallback or default factory. A leased wrapper
preserves realm conformance **only when its inner backend already has it**.

The new boundary has no delete, update, upsert, load-or-create, policy repair,
key export, raw-byte comparison or digest API. Opaque key equality, where
needed for creation/retained continuity, stays inside the trusted crypto
boundary and emits only success/failure. No key-derived identifier is stored
or logged. Existing APIs that expose different capabilities are not renamed
or retroactively tightened by this proposal.

An internal native implementation and separately named test-only factory are
proposed. Typed memory/fault fixtures are explicitly **untrusted test
simulations of native claims**, not production defaults or Keychain evidence.
A Swift protocol cannot prove that its conformer tells the truth, that a query
ran, or that the OS enforced policy. Access control, actual query construction,
trusted backend review and native tests all remain necessary.

## 3. Intended query identities and disjointness

### Plan vocabulary and new-realm recipe

A predicate is `exact(value)` or explicitly `unconstrained`; a missing query
attribute must not be serialized as an invented exact default. Domain is the
operation selection `dataProtection` (DP), not a purported stored item field.
`E` is the effective set of access groups granted to the signed process;
`G` is one explicitly selected, nonempty member of `E`. Resolve `G` from the
approved signed test/app context before allowing a new realm write, not from a
hardcoded team prefix, guessed bundle ID or the first item returned.

Proposed new-realm recipe, subject to disposition and native probes:

- Class: exactly `kSecClassGenericPassword`.
- Service: exactly `paranoid.realm-state.v1`.
- Account: exactly `paranoid.realm-state.v1.<installID>.<slot>`, with the retained
  canonical lowercase installation UUID substituted verbatim and slot exactly
  `fi` or `ru`. No nickname, secret, URL normalization or key digest is encoded.
- Access group: explicitly `G` on add and every exact read; no empty-string,
  implicit-default or any-group creation mode.
- Domain selection: `kSecUseDataProtectionKeychain = true` on every operation;
  no fallback to the macOS file-based keychain.
- Synchronizable selector and creation attribute: explicit CFBoolean false.
- Policy: non-configurable `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  and non-synchronizable. This is independent of namespace comparison.

These are draft literals, not a production namespace reservation or a request
to create these accounts now. Existing root/install/owner/full-realm context
binds each recipe at the coordinator; another ownerRef or changed full realm
cannot adopt the same account merely because the spelling is unchanged.
Future probe runners substitute an explicitly test-only namespace prefix and
fresh run identifier; they must never use an installed app's account.

### Four-role selector inventory

The successor must inventory the real selectors of **all four** supplied
backends, including broader observation guards. A backend with unknown or
dynamically changing selectors is inadmissible, even if it reports a nice name.

| Role | Intended lookup predicate at this boundary | Creation and policy |
| --- | --- | --- |
| Catalogue C | DP, generic password, exact supplied retained catalogue account `aC`; service unconstrained and access group any of `E` for the unchanged legacy selector; non-sync lookup | Retained only here, no creation. Application design uses `paranoid-text-state-v0`; synthetic roots use their explicitly supplied fixture account. Messaging policy must be verified for the actual loaded item. |
| Owner O | DP, generic password, exact supplied retained owner account `aO`; service unconstrained and access group any of `E` for the unchanged `OwnerKeychainKey` selector; non-sync lookup | Retained only here. No invented owner default. Existing `WhenUnlockedThisDeviceOnly`, non-sync policy unchanged. |
| Realm F | DP, generic password, exact proposed service, exact generated fi account `aF`, exact `G`, non-sync | Create-only under live permit; fixed messaging policy. |
| Realm R | DP, generic password, exact proposed service, exact generated ru account `aR`, exact `G`, non-sync | Same, independently generated material. |

Omitting access group on a lookup searches all the app's groups; omitting it
on insertion chooses the first group, and an explicitly empty group is invalid.
Those are different operations, not one interchangeable default.[1]
Omitting synchronizable on lookup/add selects non-sync behavior according to
Apple, but that does not describe the shape of returned attributes.[4]
Service/account are CFString attributes; Apple identifies service as part of
the primary key, but the cited service page does not settle the stored shape
when service was omitted on insertion.[2], [3], [11] Legacy omitted service is
therefore **not** silently rewritten as `exact("")`.

Define `Qx` as the set of possible items matched by role x's actual selector,
not the set currently observed. Define `Hx` as the conservative guard selector:
DP, generic password, exact `ax`, unconstrained service, every group in `E`,
`synchronizableAny`, attributes only. `Hx` detects unexpected aliases of that
role's account without reading unrelated account material. It is read-only;
it does not inherit legacy `deleteRetained` authority.

The proposed admission rule is stronger than necessary but simple to audit:
**all four account selectors must be pairwise disjoint**, with matching semantics
confirmed for the admitted spelling grammar and native query recipe. In the
following table, `!=` means inequivalence under those selection semantics, not
just Swift `String` inequality. Case/normalization aliases cannot supply a
separator; if the actual matching rule is unknown, this proof is unavailable
and admission refuses. Native probes are evidence for the tested recipe, not
proof for arbitrary Unicode or other search options. Also require unchanged
class/domain builders and explicit sync selection. Then every pair of `Hx`
sets, and therefore the contained `Qx` sets, is disjoint regardless of
service/group defaults:

| Pair | Required separator |
| --- | --- |
| C/O | `aC != aO` |
| C/F | `aC != aF` |
| C/R | `aC != aR` |
| O/F | `aO != aF` |
| O/R | `aO != aR` |
| F/R | `aF != aR` |

If accounts collide, service-only or access-group-only separation is **not**
a fallback in this slice: legacy C/O selectors would still be broad. Refuse
before effects even if a particular current lookup finds nothing. Do not
change a retained account, append a suffix on error, narrow an old API silently,
or infer disjointness from different policy. If any actual query escapes its
inventoried `Hx`, invalidate the whole namespace proof and stop common use.

An empty query result cannot prove future disjointness. Conversely disjoint
queries do not prove absence, uniqueness within one role, material inequality,
policy or correct file binding. Native independently generated keys plus
cross-decryption negatives test material isolation without exporting keys.
The proof covers these admitted selectors under the trusted exclusive caller,
not other entitled apps, arbitrary Keychain users or hostile OS mutation.

## 4. Native attributes, defaults, absence and ambiguous results

### Attribute evidence rules

| Dimension | Evidence required for the proposed successor | Missing/default/mismatch handling |
| --- | --- | --- |
| Class | The reviewed query specifies generic password. If the returned dictionary includes class, it must agree. | Do not require or fabricate an always-returned `kSecClass`; retain query evidence separately. A contradictory returned class refuses. |
| Domain | Actual API call selects DP. Apple says this key affects macOS; other platforms behave as true and ignore it.[5] | No invented stored `dataProtection=true` attribute or fallback domain. An unsupported/erroring path refuses; native platform/entitlement receipt required. |
| Account | Returned CFString equals exact intended account, byte-for-byte under the admitted ASCII grammar. | Missing, wrong type or differing spelling refuses; no case folding, coercion or URL/name normalization. |
| Service | New realm: returned CFString equals explicit service. Retained C/O: singleton legacy observation must return a concrete CFString, including empty only if actually returned. | Absent is `unknown`, not empty. No inferred service default. Unsupported legacy omission representation blocks admission until the empirical question is resolved and reviewed. |
| Access group | Returned nonempty CFString in `E`; for new realms exactly `G`. Legacy C/O's concrete group is obtained only from the sole candidate's actual observation. | Never replace missing group with app ID, first entitlement or creation default. Unexpected/unavailable group refuses. An explicitly selected group not granted to the process refuses without fallback. |
| Synchronizable | Explicit false selector/add attribute and actual returned CFBoolean false. | Missing is unknown, not `?? false`; strings/numeric coercions are not Boolean evidence. Returned true, wrong type or omitted field refuses under this conservative draft. Probe any platform omission before proposing an exception. |
| Accessibility | Actual returned CFString equals canonical role policy. | No configurable weakening or filtering by expected accessibility to hide a mismatching retained item. Missing/wrong policy refuses, never repairs. |
| Material | Backend-private data from the same combined result as those attributes, exactly the wrapping-key length, converted to an opaque handle. | Wrong type/length, readback inequality or AEAD failure refuses. No export, digest, payload error, key bytes or persistent-reference logging. |

The inspected owner fallback for absent synchronizable attributes remains an
old implementation fact, not precedent for this successor's decoder. These
new refusal rules can reduce availability for otherwise usable legacy items;
that is an explicit unresolved compatibility cost, not permission to migrate.
No newly observed field becomes persisted authority merely because it is
plausible: catalogue/owner AEAD, retained context and phase checks still apply.

Apple distinguishes unencrypted attribute returns from secret password data;
requesting multiple return types yields a dictionary containing them.[6], [7], [9]
Use that association, not `load()` followed by an unrelated `storedPolicy()`.

### Proposed bounded read algorithm

All steps run off the UI executor, serialized under the same admitted scope;
check the live holder/incarnation before and after each call. A read may block,
and logical cancellation does not prove immediate release of OS/Swift copies.

1. Execute the account-scoped `Hx` guard with attributes only and numeric
   `kSecMatchLimit = 2`. Zero means absent only on `errSecItemNotFound` for
   this valid query. One well-typed record is a candidate, not adoption. Two
   records are enough to declare ambiguity; never choose the first or request
   an unbounded enumeration. Validate returned selector dimensions. For an
   admitted existing role, any candidate outside `Qx` is a shadow/inconsistency,
   not evidence that `Qx` is safely absent.
2. Require that candidate to belong to `Qx`, with concrete service/group and
   role policy under the table above. Derive a **narrow exact composite-key
   lookup** from those actual attributes plus DP/class and explicit false sync.
   For C/O this is a successor observer, not a modification of the old API.
3. Issue one `SecItemCopyMatching` with that full selector,
   `kSecReturnAttributes = true`, `kSecReturnData = true`, and
   `kSecMatchLimitOne`. The primary-key constraint, not `matchLimitOne` itself,
   is the documented uniqueness basis.[11] Validate shape, all identity/policy
   fields and agreement with step 1 **in this result** before making its
   material usable. Native tests must confirm this recipe on the supported
   target; until then it is a proposed algorithm, not guaranteed behavior.
4. Recheck the bounded attributes-only guard and compare the candidate identity
   and policy; reject unexpected cardinality, change or loss. Check retained
   opaque-key equality for an already observed key in this live instance.
   For a new reader, authenticated file/full-context validation is still
   mandatory; it cannot claim an earlier process's in-memory key comparison.
5. Return a scoped observation only while the lease and plan revision still
   match. No creation, signing, reconciliation, intent removal or network.

Apple documents that `SecItemCopyMatching` normally returns only the first
match; match limits bound results, they do not make an under-specified query
unique.[8], [9] In particular, **do not use `kSecMatchLimitAll` with password
`kSecReturnData`**: Apple disallows that combination.[9] The bounded
attributes-only `2` recipe and its CF result shapes still require native
verification; do not quietly substitute two independent `matchLimitOne`
queries if a supported target rejects it. A two-record limit bounds cardinality,
not the byte size of OS-allocated attribute dictionaries or returned material.
Post-return field/type/length checks do not prove a pre-allocation memory bound;
trusted OS/backend assumptions and real native peak evidence remain necessary.

The combined result binds attributes to the actual loaded key in one API
result. It is **not** an atomic snapshot spanning the preliminary/final guard,
Keychain add, filesystem or all four roles. Trusted exclusive ownership excludes
cooperative co-writers during this sequence; native swap fixtures test detected
changes, not a universal TOCTOU defense. A same-primary-key replacement by a
hostile entitled process remains outside that trust model.

Only an exact successful absence check can yield `Absent`. Permission,
entitlement, decode, lock, unavailable service, cancellation, unexpected result
shape and arbitrary OS errors are not absence. `errSecDuplicateItem` from add
is refusal/uncertainty, never a signal to load or replace the winner. Public
errors are fixed categories, not query dictionaries, account/path strings,
OS payloads or secrets. Synthetic receipts may record sanitized attribute
presence/types and categorical comparisons, never material.

## 5. Pre-effect validation, one-use creation and actual readback

Use the same caller-owned isolated root and **same `OwnerNamespaceLease`
instance** across handoff. Quiesce/cancel old work, retire its holder, then
acquire one successor holder with a new coordinator incarnation. Reentry is
busy, including across awaits. A new lease object over the same root is not
exclusion; app-wide enforcement and hostile/multiprocess writers remain out
of scope. The successor is the sole full-state catalogue writer. Existing
bootstrap/owner writers continue refusing allocated realms.

Before **each** mutation check the monotonic allocation flag, every known
parent/file/temp/intent and relevant key continuity, full context, lease and
operation state. Apply those checks by phase, not an unconditional rule that
would reject the current permitted creation intermediate. A proposed
`journalReceipt` is minted only after the actual intent and parent-sync
acknowledgements; it binds the same live scope, target path, marker contents,
namespace-plan revision and consumed creation operation. It is not a Boolean,
persistable token or authority transferable from another slot. Revalidate it
immediately before add; merely finding a marker on disk cannot mint one.

| Stage | Required evidence/order and allowed next effect |
| --- | --- |
| Read-only preflight | Validate four real query plans and pairwise disjointness, matched durable confirmed owner/catalogue, all known artifacts and selected unallocated slot's absence under its guard. Resolve intended group/service/account/policy. Owner lock, unknown namespace, alias, inaccessible or stray item means no allocation. No item exists to supply stored attributes yet; do not manufacture a pre-create readback. |
| Durable allocation | Commit only the selected allocation bit using the successor writer, preserving owner/sibling bytes and bindings. After final directory sync privately mint one creation permit bound to lease/holder/incarnation, installID/ownerRef/full realm, exact namespace plan/group, operation, retained revision and finite monotonic deadline. Failure never rolls the flag back. |
| Begin creation | Recheck phase/absence and live authority. Consume the permit before the first creation-side effect; the current executing operation may hold its nontransferable consumed-permit state, not a reusable token. Create-only/no-follow and protect/exclude/sync required directories and parents. Write/protect/full-sync `realm-write-v1\n` to the selected `write.pending`, then sync its parent **before key/core creation**. |
| Create-only key | After journal acknowledgement and another phase/authority/absence check, generate independent material and invoke add once with exact new-realm attributes. No update, duplicate fallback, delete or second generation. An add success is not readback success.[10] Keep the new handle quarantined. |
| Actual readback | Run the bounded read algorithm against the real created item; compare actual identity and policy with the intended plan and opaque loaded material with the just-created handle inside the backend. Require all checks **before any seal/open for candidate use, core identity creation or adoption**. A caller-reported descriptor cannot satisfy this. |
| Commit and adopt | Only then create the local core candidate, validate bounded raw envelope, seal, create-only/protect/exclude/full-sync temporary file, rename, bounded byte-exact ciphertext readback, directory sync, remove this transaction's intent, and final directory sync. Check authority at consuming boundaries. Only the final success permits state adoption; this component never sends network traffic. |

Stored identity/policy, actual chosen group on an implicit legacy add, material
readback and add/cardinality outcomes **cannot be known before creation**.
Preflight knows only the intended recipe, current entitlements/query behavior,
absence observation and authority. Keychain/filesystem are not one transaction;
a race or failure can still leave a durable allocated slot and retained key.

Any post-begin error, cancellation, expiry, lease loss, readback mismatch or
unknown add outcome terminally breaks the affected writer. Retain the key,
allocation, temporary files and remaining intent; no cleanup, fix, recreate,
policy update or adoption. If an effect completed before an error, the same
preservation rule applies. A mismatch that undermines the four-role namespace
proof or common catalogue stops common use, not just one slot.

`allocated` with missing key/file is permitted **only within this current live
one-use creation operation's expected phase**. At restart, or with a new
coordinator, consumed/expired/cancelled/foreign permit, both-missing and XOR are
loss/uncertainty. Neither a durable flag nor `write.pending` reconstructs
creation authority. Lost final acknowledgement can leave a clean pair that a
new reader opens while the failed writer remains broken; no universal crash
or anti-rollback detection is claimed.

Realm files/directories/intent/temp use
`.completeUntilFirstUserAuthentication` and backup exclusion on the actual
inode before content/publication, with readback. Realm keys use
`AfterFirstUnlockThisDeviceOnly`, non-sync. Owner key/file policy remains
`WhenUnlockedThisDeviceOnly`/`.complete`, non-sync and backup-excluded files.
Apple's after-first-unlock rule requires an unlock after restart; it does not
mean available before the first unlock. Its documented `ThisDeviceOnly`
guarantee is no migration to another device, not a blanket proof that every
same-device backup contains no Keychain record.[12] File backup exclusion and
native physical backup/restore acceptance remain separate; no stronger backup
claim is inferred from the key's name or old source comments.

## 6. Locked owner and verified-B local read-only admission

The [preflight's six conditions](realm-store-preflight.md#verified-b-means-local-read-only-admission)
remain conjunctive. This contract refines their namespace evidence rather than
promising B availability:

1. Same valid exclusive lease/holder/incarnation; complete real selector plans
   and disjointness proof, not object IDs.
2. Valid catalogue/install key-file continuity, AEAD and full-state schema;
   exact expected installation/ownerRef and both full realm tuples; owner and
   B allocated with confirmed non-null binding; no common pending artifact.
3. No-follow inspection of known parents/files and B halves; actual B namespace
   and policy readback; no B temp/intent or observed key substitution. Any A
   failure must be provably local; common uncertainty refuses B.
4. B envelope caps/schema/context/binding match catalogue and any **available
   validated** owner binding. Inaccessible owner is not freshly verified;
   observed owner contradiction is not benign lock.
5. Full non-signing Rust semantic validation plus public credential/trust/
   fingerprint and intent/result/enrollment/terminal coherence. RFC-0032's
   implementation/approval is still a critical-path dependency for arbitrary
   schema-3 state; `identity_credential_v3` alone and a potentially signing
   `view` are not substitutes.
6. Zero mutation, creation, signing, network, candidate adoption, reconciliation
   or cleanup. Result means local storage read only, not current registry or
   server membership, active runtime, login or UI authorization.

**Owner attributes unavailable is not owner selector unknown.** If the trusted
current adapter's real owner selector is known to require `aO`, its service and
group may remain unconstrained. Distinct accounts can still prove O/B selector
disjointness without loading the owner key or inventing its stored attributes.
That proves only non-overlap of query sets, not owner policy, material,
existence, integrity or fresh binding. A precisely classified read-only owner
lock may leave those owner observations unavailable while the six conditions
above are independently satisfied for catalogue/B. No cached owner observation
is relabelled fresh, and a persisted descriptor alone is not runtime proof.

If that proof depends on an unreadable owner attribute (for example accounts
collide and somebody proposes using its group/service as the separator), or
the actual owner query builder/entitlements are unknown, refuse B. Likewise
refuse for common integrity uncertainty or a generic backend error that cannot
be classified as owner-local. Owner-frozen does not mean every failure is
local. Retry a precisely classified **read-only** lock only after unlock and
revalidation; it grants no mutation permit. Do not reuse the whole bootstrap
or old owner coordinator as this full-state retained-reader path.

When owner is locked/frozen at write admission, refuse **all realm writes**
before their first effect: allocation, core/state changes, login bookkeeping,
intent/result/terminal changes, durable reconciliation and journal cleanup.
A lock discovered after writing began is terminal, never a cleanup/retry
exception. Observations cannot atomically fence OS lock transitions across
Keychain/filesystem. This narrower slice does not implement the later design's
independent device-only traffic. An unavailable B read is an honest result,
not a reason to weaken the namespace or validation conditions.

## 7. Compatibility, trust and rollback

Preserve the [preflight's byte/format contract](realm-store-preflight.md#parser-admission-and-opaque-core-boundary):
ASCII/no escapes applies only to new realm metadata/wrapper fields, not opaque
core or legacy owner/catalogue formats. Core delimiter scanning stays
escape-aware; retained admitted Snapshot spans remain verbatim. No legacy
import, normalization, pruning or expanded old codec cap. Retained device UUID
admission remains canonical UUID text as in Rust while D87-06's separate RFC
resolves v4 enforcement and retained-credential compatibility. No live DB
inventory is performed; it requires Sergey's specific live authorization.

| Threat or limit | Proposed control and residual |
| --- | --- |
| Policy or Swift object identity masquerades as isolation | Actual selector inventory, all six account-separation checks and native alias fixtures. Entitled hostile code/compromised OS is still trusted failure. |
| Attributes describe a different key | One combined attributes/data result after bounded cardinality guard; exact identity/policy comparison and opaque continuity. No atomic multi-call or filesystem guarantee. |
| Missing defaults hide an alias or policy weakness | Distinguish omitted selectors from missing returned attributes; fail unknown/ambiguous, never synthesize defaults. Availability/legacy compatibility can be lost. |
| Key created before durable intent or reused after failed creation | Phase-bound live one-use permit, parent-synced intent, create-only, actual readback before use, terminal preservation. Partial allocation/key loss may require separately designed recovery. |
| Owner lock becomes absence or permission to mutate B | Six-condition local read admission only; all locked-owner writes excluded. Common uncertainty may stop both realms. |
| Key data escapes through diagnostics or test evidence | Opaque boundary, fixed errors, no raw key export/digest/log, no whole Keychain dump; fixture assertions log only types/counts/comparison outcomes. Swift/OS copies are not guaranteed zeroized. |
| False native assurance from typed doubles or a green build | Explicit fixture/native/physical attribution and NOT RUN gates; native evidence on exact source/SDK/signing context. No production privacy or anti-rollback claim. |

This adds no cipher, Swift signing/transcript hashing, owner derivation or
server protocol. It does not repair third-party callers or change legacy
`KeychainKey.standard`, `OwnerKeychainKey`, codecs, refusal APIs or app startup.
The stricter successor observer may refuse a legacy singleton with unavailable
attributes; do not make compatibility appear green by rewriting the item.

Rollout is disabled app adoption until namespace probes, typed/native tests,
full-validator dependency, independent review and protected decisions are
resolved. First execution is only separately authorized synthetic fixtures.
App adoption still needs trustworthy fresh/lost classification, enforced
single-lease factory, owner-mutation integration and exact-head native evidence.
Physical lock/backup/restart and server/phone acceptance require their own scope.

Rollback means a compatible full-state reader or a stopped preserved install.
An intact legacy-path v5 catalogue/key can make the old reader refuse, but loss
of both with surviving realm files makes a v4-only reader unsafe/unsupported.
Never delete a key/catalogue, reinstall, restore old ratchets, lower generations
or revert allocation to make a rollback work. Test-owned cleanup below is not
an operational rollback mechanism.

## 8. Native probe plan — all probes NOT RUN

These are exact future fixture experiments, not instructions executed by this
document. Start only with separately authorized Mac/signed-simulator test scope
and the repository's [pinned native workflow](owner-store-mac-handoff.md#reproducible-final-mac-verification).
No Apple login/provisioning change, physical phone, application key, user item,
iCloud synchronization or hosted service is needed or authorized.

For **every** probe use a fresh synthetic account containing a random run UUID
and case ID, isolated test service and a caller-owned test root. Check that the
account-scoped attributes-only guard is absent first; on any collision/error
stop and choose no destructive repair. Never query by class alone, enumerate
an existing user's namespace, or borrow `paranoid-text-state-v0`. To simulate
legacy, use a fresh test account and omit only the dimension being measured.
Keep iCloud off for the disposable simulator; no `synchronizable=true` item is
created by this plan. Tests of impossible/malformed attribute results are
explicitly fixture injection, not native observations.

The runner privately records exact objects it successfully added. Only a
separately owned test teardown may remove those **known test-created exact
items**, after preservation assertions, and must verify their scoped absence.
If ownership is uncertain, retain the fixture and report it; never broad-delete
by a prefix, account wildcard or role. No production backend cleanup API follows.
For default-attribute experiments whose exact stored identity cannot be
resolved, preserve the fixture rather than expand deletion. Never erase an
existing simulator to tidy a failed run.

| Probe | Synthetic setup and exact observations required | Unresolved empirical question |
| --- | --- | --- |
| P01 `explicitRealmRoundTrip` | Add one unique realm-style item with explicit class/service/account/group/false sync/messaging accessibility. Bounded attributes guard then combined exact attributes/data read; assert material equality only inside backend. Record CF types and presence of class/service/account/group/accessibility/sync, not data. | Does the supported signed target return all required fields with the expected types, and does the exact combined recipe work? |
| P02 `legacyOmittedService` | Two fresh accounts: one add omits service, the other explicitly uses empty service. Read each with the account-scoped guard; record whether service is absent, empty CFString or another representation. On the first test account only, attempt the explicit-empty duplicate and record status; preserve the original. | Omitted-versus-empty storage, query and duplicate semantics; no assumed normalization. An omitted returned field remains refusal in this draft. |
| P03 `groupDefaultAndUnion` | With already authorized test entitlements, omit group only on a new test insertion; read actual returned group and compare with signed entitlements. If two test groups are already available, add same synthetic account/service in each; omitted-group guard must report ambiguity, exact-group reads must remain separate. | Default add group, multi-group lookup and returned group; if a second group is unavailable, that leg is NOT RUN, not a reason to provision one. |
| P04 `boundedCardinalityAndAssociation` | Same unique account in two test services, non-sync and same group. Attributes-only numeric limit 2 must report both; broad first-match load is never admitted. Test zero/one/two, exact composite narrowing and combined result field association using backend-private comparisons. | Numeric limit/CFArray/dictionary behavior; the plan must reject on any unexpected shape. No data-plus-matchLimitAll call. |
| P05 `duplicateAndPolicy` | Same explicit composite identity added twice, with different accessibility on the second attempt; expect documented duplicate refusal and unchanged first item. Separate fresh items use canonical messaging and owner policies; wrong-role policy must refuse without delete/update. Omitted-sync add uses only non-sync behavior, never sync true. | Actual duplicate/policy readback and explicit/omitted false attribute shape; this does not infer missing returned false. |
| P06 `domainAndMatching` | On separately authorized signed Mac test scope, use unique synthetic accounts to compare explicit DP behavior with a separately test-owned file-keychain fixture if available; never search a user's default keychain broadly. Probe exact service/account matching, including two fixture accounts differing only by case, and ensure production generated accounts remain ASCII exact. | Platform domain selection and effective string matching; macOS evidence is not an iOS/device result. Unavailable file-keychain fixture leg stays NOT RUN. |
| P07 `observationChanges` | Under a fixture-only hook pause between metadata guard and combined read; the test owner changes/removes its own test item. Detect changed identity/policy/material, no adoption or regeneration. Separately inject a mismatched attributes/data pair and mark it simulated. | Detection at named boundaries, not an OS-global atomicity claim. Native same-call association and injected violation must be reported separately. |
| P08 `creationFaultPreservation` | Use only newly owned realm fixture keys/files; fail before/after allocation sync, intent-parent sync, add, actual readback and every commit sync. Assert no pre-journal key, no use before readback, at most one creation and retained evidence on mismatch/error. | Native effect ordering versus labelled injected failures; real power loss remains NOT RUN. |
| P09 `lockedOwnerReadOnly` | Inject precisely classified owner lock in an explicit typed test backend; exercise known-disjoint versus unknown/colliding owner selectors, valid/invalid B and every forbidden B write. Future real lock experiment requires separately scoped physical evidence. | Can locked-owner attributes be observed on supported platforms? No simulator/injection result promises physical availability; missing proof still refuses. |

No probe result is supplied here. In particular, P02/P03/P04/P05 must resolve
returned-field/default behavior before native successor admission is called
ready. If the conservative decoder cannot admit required legacy records,
record the result and seek an explicit compatibility decision; do not invent
fields, weaken tests or modify the old backend to hide the gap.

## 9. RED → GREEN and acceptance handoff — all new rows NOT RUN

Proposed package suite `RealmKeyNamespaceContractTests`; proposed signed-
simulator suite `RealmKeyNamespaceTests`. Neither exists at this baseline.
Use the existing package/app test targets, not a new Linux native harness.
Advance one behavior at a time: executable inert seam → expected assertion
RED → minimal implementation → GREEN and regressions. Missing SDK, unresolved
symbols, undiscovered tests or compiler setup errors are not behavioral RED.
Compile-negative admission is a separate gate with its expected diagnostic and
positive control; an already-refusing old backend is a regression, not new RED.

| Gate | Required oracle / negative and positive controls | Traceability |
| --- | --- | --- |
| K01 `typedAdmission` | Proposed realm crypto rejects ordinary `WrappingKeyStore`, bare `RetainedKey`, messaging `KeychainKey`, `OwnerKeychainKey`/`OwnerKeyBackend`, and generic leased/type-erased wrappers around each, for the expected missing realm boundary. Positive native realm backend and explicitly test-only typed fixture compile. Positive old owner and messaging constructors remain valid in their original APIs; no cross-conformance retrofit. | D87-02; R12; REQ-CLIENT-001, MR-02/14 |
| K02 `querySetSeparation` | All six role pairs reject equal/overlapping accounts even with different objects, policies, services or groups; deliberately same backend twice also refuses. Distinct synthetic accounts with broad C/O selectors and explicit F/R succeed. Unknown query builder, domain fallback or plan revision change refuses before effects. | R02/03/04; REQ-MULTI-001, MR-01/02 |
| K03 `actualBoundRead` | P01–P07; missing/wrong-type/defaulted attributes, two matches, shadow sync/service/group item, wrong policy, wrong material length or attributes from another key never yield usable handles. Exactly one native canonical item passes. Injected shadow-sync cases never create cloud-synced items. | R06/11/12; MR-02/06 |
| K04 `creationOrderAndFaults` | P08 plus before/after-effect faults at every stage in §5. Wrong/expired/reused/cancelled/foreign permit and stale holder cause zero subsequent effects. Allocated missing halves allowed only in the live authorized phase; same state after restart cannot recreate. Mismatch keeps key and intent, terminal writer never retries. | R03/05/06; MR-06/09/13 |
| K05 `ownerLockAndB` | Each of the six B conditions has a failing negative; known owner-selector disjointness with unavailable owner attributes is distinguished from unknown namespace. All owner-locked writes, including bookkeeping and cleanup, refuse before effects; read-only positive needs real full non-signing validator, not a stub renamed validation. | D87-05/07; R09/10; MR-06 |
| K06 `compatibilityAndMaterialIsolation` | Old codecs/writers/refusal APIs and legacy bytes unchanged. New accounts never alias C/O; native A ciphertext cannot open with B or owner key and reverse cases refuse, without key export/digest. Intact-v5 refusal and combined legacy-pair loss retain the documented rollback limitations. | R04/06/10/11; REQ-ID-002, REQ-SEC-001, MR-02/06/07 |
| K07 `nativeMemoryAndBounds` | Exact limits/refusal fixtures across decrypt/parser/transfer/bridge/Rust/reply on iOS simulator, including full opaque-core handling; measure actual numeric peak separately from net delta. No blanket memory claim from namespace types, package build or source checks. | D87-03/07; R07/11; MR-14 |

`R01–R12` refer to the [realm preflight matrix](realm-store-preflight.md#7-red--green-acceptance-matrix--all-new-rows-not-run);
`MR` refers to the [concurrent-realm acceptance matrix](concurrent-realms-design.md#requirement-and-acceptance-mapping).
These are refinements of existing [requirements](../../product/requirements.md),
not new accepted product requirements or closed full MR gates.

After the separately authorized future implementation, run focused package
tests in debug/release, existing owner/catalogue/Devnet/core regressions, full
package, strict-concurrency/type probes, notices and unsigned build using the
pinned Mac handoff. Then exercise the real signed-simulator Keychain tests in
fresh accounts, following the [existing signing workflow](lazy-storage-handoff.md).
A proposed command shape, **not runnable acceptance until the named suites
are implemented and discovered**, is:

```sh
bash clients/ios/toolchain.sh xcodebuild test \
  -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -configuration Debug -destination "$PARANOID_IOS_SIMULATOR" \
  -derivedDataPath clients/ios/out/realm-namespace-signed \
  -resultBundlePath clients/ios/out/realm-namespace-signed.xcresult \
  -only-testing:ParanoIDTests/RealmKeyNamespaceTests \
  -only-testing:ParanoIDTests/RealmStoreMemoryTests
```

Use a fresh result-bundle path for each run and an explicitly authorized
disposable simulator. Do not disable signing for the Keychain leg or add
provisioning/login flags. Reject a zero-test result; record exact discovered
methods, source SHA, toolchain/SDK/runtime, simulator destination and test
entitlements, exit codes, skips, raw RED/GREEN and native-versus-fixture labels.
An existing owner's receipt cannot certify these future changed adapters.

Memory acceptance specifically requires **`xcodebuild test` on iOS simulator
with `XCTMemoryMetric` and an actual numeric transient peak measurement**.
Apple describes `XCTMemoryMetric` as a before/after memory difference; that
alone is not peak evidence.[13] The future harness must name the measured
process, interval covering the entire native path, peak metric/instrumentation,
sampling/high-water limitations, units and numeric values per boundary fixture,
alongside the XCTest delta. Instrumentation choice and threshold remain OPEN;
no harness or native performance run is supplied here. A Linux RSS measurement,
passing build, net-zero delta or simulator result relabelled physical-device
proof does not pass K07. Keep known wrapper limitations visible, not waived.

## 10. Open choices and integration exit

- **Empirical native blockers:** actual omitted-service/empty-service behavior,
  access-group/default/entitlement observations, numeric-2 result shape and
  combined-read attribute completeness, CFBoolean false representation,
  supported exact matching/domain behavior and locked-owner visibility. Resolve
  P01–P09 with actual receipts, not source constants or fixture assertions.
- **Technical disposition:** draft realm service/account recipe, explicit-group
  resolution, account-distinct conservative guard policy, successor observation
  of broad legacy selectors, and availability cost when legacy attributes are
  unprovable. No implicit key move, policy migration or alternate query fallback.
- **Critical dependencies:** actual approved/implemented RFC-0032 full-schema-3
  non-signing validation; successor full-state coordinator and phase-bound
  authority; independent exact-revision review. This contract alone cannot reopen
  arbitrary schema-3 or run login. Current retained `device` admission follows the
  verified interim canonical-UUID rule, not new v4 enforcement.
- **Separate future v3 change:** D87-06 enforcement/compatibility disposition and
  any separately authorized server inventory are **not prerequisites** for this
  namespace slice, its drafting/local tests or RFC-0032. They become relevant to
  changing v3 validation, not to the already selected retained-read grammar.
- **Later adoption:** production factory/lease enforcement, retained root/fresh
  classification, full native memory evidence, physical protection/backup checks,
  owner operations and application/runtime/transport acceptance. None follows
  from documentation lint or a typechecking fixture.

The parent integration owns navigation, current-state/provenance and canonical
threat pointers. This document's trust analysis supplements the
[iOS identity-v3 delta](../../security/ios-identity-v3-threats.md) and
[threat-model boundary 2](../../security/threat-model.md#trust-boundaries-to-define);
it does not change their status. No accepted ADR is rewritten. Native tests,
probes, physical acceptance and performance results are **NOT RUN**.

## Sources

Apple documentation was read through its public documentation JSON during this
draft. These sources establish API semantics, not execution on the project
SDK/entitlements; empirical gaps above remain open.

1. [kSecAttrAccessGroup](https://developer.apple.com/documentation/Security/kSecAttrAccessGroup)
2. [kSecAttrService](https://developer.apple.com/documentation/Security/kSecAttrService)
3. [kSecAttrAccount](https://developer.apple.com/documentation/Security/kSecAttrAccount)
4. [kSecAttrSynchronizable](https://developer.apple.com/documentation/Security/kSecAttrSynchronizable)
5. [kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/Security/kSecUseDataProtectionKeychain)
6. [kSecReturnData](https://developer.apple.com/documentation/Security/kSecReturnData)
7. [kSecReturnAttributes](https://developer.apple.com/documentation/Security/kSecReturnAttributes)
8. [kSecMatchLimit](https://developer.apple.com/documentation/Security/kSecMatchLimit)
9. [SecItemCopyMatching](https://developer.apple.com/documentation/Security/SecItemCopyMatching(_:_:))
10. [SecItemAdd](https://developer.apple.com/documentation/Security/SecItemAdd(_:_:))
11. [kSecClassGenericPassword](https://developer.apple.com/documentation/Security/kSecClassGenericPassword)
12. [kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/Security/kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
13. [XCTMemoryMetric](https://developer.apple.com/documentation/xctest/xctmemorymetric)

[1]: <https://developer.apple.com/documentation/Security/kSecAttrAccessGroup>
[2]: <https://developer.apple.com/documentation/Security/kSecAttrService>
[3]: <https://developer.apple.com/documentation/Security/kSecAttrAccount>
[4]: <https://developer.apple.com/documentation/Security/kSecAttrSynchronizable>
[5]: <https://developer.apple.com/documentation/Security/kSecUseDataProtectionKeychain>
[6]: <https://developer.apple.com/documentation/Security/kSecReturnData>
[7]: <https://developer.apple.com/documentation/Security/kSecReturnAttributes>
[8]: <https://developer.apple.com/documentation/Security/kSecMatchLimit>
[9]: <https://developer.apple.com/documentation/Security/SecItemCopyMatching(_:_:)>
[10]: <https://developer.apple.com/documentation/Security/SecItemAdd(_:_:)>
[11]: <https://developer.apple.com/documentation/Security/kSecClassGenericPassword>
[12]: <https://developer.apple.com/documentation/Security/kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly>
[13]: <https://developer.apple.com/documentation/xctest/xctmemorymetric>
