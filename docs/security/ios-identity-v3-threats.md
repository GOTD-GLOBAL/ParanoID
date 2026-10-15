---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-10-15
last_reviewed_scope: recorded bounded ADR-0018 design/source approval; controls and native evidence still unimplemented
---

# iOS identity v3 threat delta (RFC-0030)

## Proposed full-state validation boundary (RFC-0032)

[Completed RFC-0032](../rfcs/0032-core-non-signing-state-validation.md) is proposal
history for the non-signing Rust validation/public projection, not a delivered
control. [ADR-0018](../decisions/0018-core-non-signing-state-validation.md) records
[human approval](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#issuecomment-6186443887) of `9eb6527` in the review branch and bounded
local implementation/tests, distinct from [scoped design review](https://github.com/GOTD-GLOBAL/ParanoID/pull/88#pullrequestreview-5523363288)
on `15e86b9` and its verified citation tail. No canonical merge or live permission
is inferred, and no runtime/native acceptance gate is lifted. Both validation
and result construction must avoid signing while preserving peer signature
checks, transcripts and every existing state/serialized-size check.
A private non-buffering sink may count the same serializer without retaining or
exporting an encoded secret-state buffer; equality/limit evidence remains required.

[Existing-code probes](../project/evidence/core-state-validation-20261014/README.md)
show that Account restoration may draw OS entropy for runtime hash-table seeding.
An absolute zero-syscall promise is therefore false, and warm-only measurements
can hide first use. Protocol RNG, signing and key/nonce/UUID generation remain
forbidden; permitted runtime seeding needs evidenced call-path attribution, not
an arbitrary syscall whitelist or a production bypass flag. Never disable hash
randomization or Account checks to satisfy a counter. All new V01–V14 and Apple
resource tests remain NOT RUN; this research grants no shared-core implementation
or live authority, and a local projection is not membership/login proof.

## Realm-store preflight proposal — 2026-10-14

The [new preflight appendix](../clients/ios/realm-store-preflight.md) maps the next
isolated slice to proposed R01-R12 tests: allocation before key/core creation,
exclusive writer/lease handoff, full-context/sibling isolation, bounded raw
snapshot admission, immutable login intent/result bookkeeping and scoped/global
freeze with preservation. These are proposed checks, **all NOT RUN**, not new
implemented controls or closed MR gates. Its successor catalogue reader, exact
parser limits and owner-locked retained-read classification need disposition
and independent review; existing owner/bootstrap refusal tests stay intact.

Exact-bound refinement keeps duplicate/type/length checks outside the opaque
core grammar, and prioritizes verbatim retained Snapshot preservation over
canonical reserialization. It exposes two unresolved guarantees: device UUIDv4
in the v3 document versus canonical-UUID admission in the shared credential
verifier, and full schema-3 state validation versus possible device-auth contact
signing in `view`. Neither implies a proof/registry/admission bypass. A public
credential projection is not complete state validation; a signing call is not
a silently acceptable storage guard. Tightening a shared verifier or adding a
pure validation API needs explicit scope, compatibility analysis and review;
this draft implements neither. The closed #85 findings are not reopened by it.

Verified D87 technical dispositions narrow the draft, not the accepted safety gates:
namespace identity must be checked separately from key policy, using a proposed
typed realm backend and actual Keychain attributes linked to the loaded item.
Pre-create namespace/absence checks and post-create readback are distinct; mismatch
never permits cleanup. Exact default/missing-attribute semantics still need an
Apple-backed contract. New realm metadata forbids escapes, but opaque core and
existing owner/catalogue/legacy grammars remain unchanged; retained bytes are not
normalized. Verified B is explicitly local read-only admission, not live server
membership. Owner-locked writes, including bookkeeping/cleanup, are excluded from
this slice; general schema-3 reads remain blocked on the full non-signing validator.
A successful simulator xcodebuild run or net memory delta cannot substitute for a measured
peak across the actual native path. No new native measurement has been performed.

No app startup, network verifier, secret operation, legacy-state migration or
live action is introduced. The [human #73 source-scope record](https://github.com/GOTD-GLOBAL/ParanoID/pull/73#issuecomment-6172556046) and
[human D87 disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/87#issuecomment-6173228187) now exist; they do not accept ADR-0017, widen
private-data limits or remove independent review and exact tests. Shared-core
changes wait for their own RFC → ADR and required owner approval. D87-07's pure
validator is a critical-path dependency, not a permission to use a partial or
signing validator meanwhile. A future server UUID inventory requires separately
authorized live access; no DB/network application probe follows from source scope.

## Open native review findings — 2026-10-14

**Historical at `98f58b0`; corrected and source-reviewed on `17d8d88` / `09eac34`.**
The first `fstat` in `openRegular` could be classified as retryable lock on
`EPERM` plus unavailable protected data; the crypto initializer admitted a
messaging-policy `WrappingKeyStore`, and the key allowed noncanonical policy.
These were two component-boundary P2 findings, not demonstrated app exploits.
The [correction receipt](../project/evidence/ios-identity-v3-20261013/owner-apple-adapter.md)
and [scoped source closure](https://github.com/GOTD-GLOBAL/ParanoID/pull/85#pullrequestreview-5517351127) record their resolution and the
additional exact-once descriptor cleanup fix. No new P1/P2 was found in those
corrections under the trusted-backend/exclusive-lease contract.

Native RED/GREEN, compiler admission probes and signed-simulator results are
contributor-reported Mac evidence. Linux review verified source and provenance,
not native execution, on-device `.complete`, physical lock lifecycle or power
loss. The watchdog changes no production deadline. App adoption, #73, ADR and
MR gates remain separate. A direct weak-policy `createKey()` fixture regression
is a nonblocking test follow-up; the canonical guard is already in that path.

## Apple owner adapter — 2026-10-14

The native owner backends the delta below left unimplemented are exercised on
the build Mac ([receipt](../project/evidence/ios-identity-v3-20261013/owner-apple-adapter.md)):
the four staged cases (three host passes and one real-Keychain host skip),
eight native-stage cases and eleven classification/policy cases against the
real file system and CryptoKit, with labelled fixture-only fault injections.
The signed-simulator suite includes the two original owner cases and the later
legacy-policy refusal/preservation case; its final total is 14/0.
These rows update the "required check / residual" cells below; they do not
close #73, ADR, MR or application gates.

| Threat | Native control now tested | Remaining boundary |
| --- | --- | --- |
| `owner/` is created through a link or over an existing inode | `mkdir(2)` never follows the final component; any existing inode is `EEXIST` and untouched; `O_DIRECTORY` and `O_NOFOLLOW` open then `fchmod(0700)` | Same-process caller trusted; hostile co-writers out of scope |
| Owner files carry messaging protection or are protected through a link | No-follow inspection before protection; `.complete` set and read back (iOS), backup exclusion set and read back on the inode; a link or foreign inode is `EFTYPE` | `.complete` is compiled for iOS and read back there; host runs prove invocation order and the backup flag only |
| The owner key lands under the messaging policy or is replaced/deleted | Separate `OwnerKeychainKey(account:)` with a non-configurable canonical policy (`OwnerKeyPolicy` cannot be constructed outside its file); attributes read back after `SecItemAdd` and refused on mismatch; a retained item with a weaker policy refused on `load()`, never deleted or migrated; duplicate refused; deletion refused; `OwnerAppleCryptography` admits only an `OwnerKeyBackend`, so the messaging `KeychainKey` is rejected by the compiler (native compile probe) and its defaults are untouched (simulator cases incl. a legacy item under an owner account) | Simulator Keychain, not a device; lock/unlock lifecycle and power loss not reproduced |
| A locked key or file is taken for absence or for failure | `errSecInteractionNotAllowed` maps to `OwnerBackendLock.locked`; for files only `EPERM` from the `open(2)` syscall itself on `owner/state.enc` while the platform reports protected data unavailable does — the `fstat` after the open, the inode confirmation, the descriptor read, other paths including the catalogue, `EACCES`, an available or absent signal are all failures the store freezes on (eleven classification cases); read-only lock before effects is retryable without latching; a lock after the write began is terminal with intent and key kept | The protected-data signal is injected on the host (FIXTURE-ONLY); the application supplies the platform's own at integration |
| Reopening repairs, republishes or rewrites | Every reopen compares exact saved bytes; interrupted publication before the intent leaves a clean intermediate that only explicit publication completes; after the intent the leftover marker freezes the catalogue with all bytes kept; foreign key/context, leftover temp/intent and missing halves refuse without modification | Lost final acknowledgement remains undetectable to a later instance (unchanged) |
| Pre-sponsor evidence or send counters drift across restarts | ownerSigned (real Rust `sponsored_sign` on the public vector), assembled and one send reservation each reopen byte-exact; confirmation marks `ownerBound` and publishes once | Synthetic assembly/verification are trusted input, not signature or live-chain verification |

## PROPOSED allocation-aware owner-store delta — 2026-10-14

The [byte/transaction appendix](../clients/ios/owner-store-format.md) remains a
non-adopted component proposal. This section preserves the earlier portable
checkpoint, when native owner protection/durability had not been run. The
subsequent native component receipt is recorded above; application controls
remain **NOT RUN**. Neither checkpoint closes #73/ADR/MR gates.

The initial source at `697bd68` failed additional authority/retained-integrity
reviews despite its passing baseline. Corrected source `1df9462` is independently
replayed by the parent: **109/0 in debug and release**, including 22 regression
methods. Those tests cover cancellation/close/late results, pre-sign and
post-effect deadlines, stale leases/tickets, retained-origin freeze and full
ledger reconciliation without new append authority. Conditional owner-policy
conformance is also checked by an expected compile rejection. The
[receipt](../project/evidence/ios-identity-v3-20261013/owner-store-core.md) records
old failures and new results separately; both exact-head component reviews
closed without remaining P1/P2. Cancellation fences the caller and late callback
authority, not forced termination of an uncooperative verifier or a global task
pool; production resource/secret-copy lifetime policy remains separate. These
are non-cryptographic storage fixtures plus real Rust public
vectors, not proof of Apple Keychain, file protection, power-loss or a live
trusted verifier. Owner/common runtime containment is not implemented here.

| Threat | Proposed control | Required check / residual |
| --- | --- | --- |
| Old/new writers race, or allocated loss is treated as fresh | Exclusive namespace-lease handoff, serialized non-reentrant coordinator; creation permit only after allocation final sync, consumed before owner effects | Stale handles/reentry/cancel/restart faults; no permit reconstructed on reopen, no cleanup; hostile co-writers outside scope |
| Creation of the owner directory/key escapes journaling or uses messaging protection | Create-only/no-follow directory, owner policy plus parent sync, then intent and parent sync before key; explicit WhenUnlockedThisDeviceOnly/complete seams | Directory/key/sync fault ordering; host doubles do not prove Keychain or device protection, legacy defaults unchanged |
| Sponsor can land a forgotten signature, or reopening silently signs | Retain exact ownerSigned and assembled stages, full sponsor target, immutable bytes and pre-send counter; bounded append-only evidence | Both stages survive reopen with zero signing calls; eight-entry cap refuses new attempts, never prunes; parsing/framing is not signature or live-chain verification |
| Caller labels recovery verified, or crash publishes a tentative identity | Private operation/context-bound capabilities from explicitly trusted external verifier seam; owner-confirmed commit precedes matching catalogue publication | Failed/no-name/cancelled pre-allocation verification writes nothing; intermediate preserved without auto-publication; Rust verify alone is not live RPC/program/finality authentication |
| Owner secret or hostile input escapes bounds | Separate opaque owner key, strict 64 KiB raw admission, exact fields/encodings, bounded ledger, fixed errors, no payload logs | Parser/limit/swapped-store negatives; Swift copies are not guaranteed zeroized, no anti-rollback or runtime-global revoke claim |

## Apple catalogue adapter — 2026-10-14

The native adapter the checkpoint below left unimplemented is now exercised on
the build Mac ([receipt](../project/evidence/ios-identity-v3-20261013/catalogue-apple-adapter.md)):
the four staged cases in the active target plus twenty-one native-seam cases
against the real file system and real CryptoKit, with five labelled
fixture-only POSIX fault injections for transfers the file system does not
interrupt on demand. These rows update the "remaining boundary" cells below;
they do not close MR-02/06/07/14 or any application gate.

| Threat | Native control now tested | Remaining boundary |
| --- | --- | --- |
| A link, FIFO or foreign inode is followed or opened | `lstat` no-follow inspection; `O_NOFOLLOW` on adapter create/read opens; FIFO refused before opening; reader checks the opened inode is the inspected one | Reused `fullSync` retains `open(O_RDONLY)` without `O_NOFOLLOW`; caller owns inspected/created paths exclusively, and hostile co-writer races remain out of scope |
| An unreadable or missing parent is taken for absence | Only `ENOENT` is absence; `ENOTDIR`/`EACCES` throw (tested with a mode-0 directory and a file used as a directory) | Permission cases skip when running as root |
| Candidate or intent replaces or truncates an existing name | `O_CREAT` with `O_EXCL` create-only, owner-only mode; existing link refused and its target untouched | — |
| Partial transfer passes as success or is tidied away | Short writes completed, write `EINTR` retried, zero-length write → `EIO`; write-close errors other than `EINTR` are reported; partial bytes stay as evidence, no unlink | The adapter treats Darwin close `EINTR` as a closed descriptor without retry; fault injections are fixture-only and power loss is not reproduced |
| Oversized or growing file is decoded | Size refused before allocation; at most `maximumBytes + 1` bytes read through the descriptor; growth past the limit → `EFBIG` | — |
| Backup or protection flag silently missing | Backup exclusion set on the inode and read back before rename | iOS Data Protection class is compiled for iOS only and not executed on the host |
| Authenticated bytes are repaired on the way to the strict codec | Raw `AES.GCM.open` on the shipped framing returns the stored bytes; the lossy legacy String decoder is not used; the old reader still parses the same box | Catalogue plaintext must be exact UTF-8 to be sealed (`EILSEQ` otherwise) |
| Key material leaks or is replaced through the adapter | Opaque `SymmetricKey` through the existing `WrappingKeyStore`/`RetainedKey` seams; create-only; no export, byte comparison or deletion | Real `KeychainKey` was not instantiated; in-memory backends only |

## Isolated catalogue transaction-core checkpoint — 2026-10-13

The [non-adopted first-store clarification](../clients/ios/concurrent-realms-design.md#proposed-isolated-first-store-contract)
now has executable production orchestration (`CatalogueStore`) behind explicit
file/opaque-key seams. The [receipt](../project/evidence/ios-identity-v3-20261013/catalogue-store.md)
records actual Linux Swift unit execution, not native encryption or durability.
The Apple adapter is **not implemented**: its native-first tests are an unrun
checkpoint outside the existing test target, not a passing or skipped gate.
The base `ea93dafe` [Mac receipt](../project/evidence/ios-identity-v3-20261013/native-mac-receipts.md)
covers the earlier codec only, not this new transaction code or adapter.

| Threat | Component control / test evidence | Remaining boundary |
| --- | --- | --- |
| Missing state is reclassified as fresh | Separate instance-bound fresh inspection and retained load; retained missing halves, including both, refuse | Caller supplies trusted classification; Welcome/lost-install distinction is still open |
| Uncertain commit is retried or evidence deleted | Intent and parent sync before key/candidate; exact key/readback checks; both directory syncs before success; terminal failure latch; no key/temp cleanup API | Fault doubles cover before/after-effect exceptions, not Darwin power loss or Keychain atomicity |
| Foreign or v4 state is overwritten | All named ancestor/artifact/key inspections before effects; full installID/ownerRef/fi/ru context; strict retained decoding before replacement | Throwing native inspection, no-follow/exclusive writes, bounded reads and native v4 refusal still need their adapter tests |
| Secret copies escape through portability seams | Generic opaque `Equatable` key, no raw-key export/deletion API; fixed-category errors | Fake keys/tokens are unit doubles, not cryptography; actual `SymmetricKey`/CryptoKit handling remains native work |
| Recovery claims exceed the evidence | Explicit test: removal-then-throw/final-sync failure can leave a pair a new instance opens, while failed instance cannot retry | Total loss/rollback and lost acknowledgement are not universally detectable; no anti-rollback guarantee |

The explicit pre-existing isolated directory and key namespaces must be owned
exclusively by one serialized, non-reentrant caller. Multiprocess/adversarial
concurrent mutation is unsupported. Backends are trusted to implement their
throwing/opaque/bounded contracts; no synthetic fake is an application default.
No allocation, owner entropy, real Keychain, app startup, install marker,
network, migration or legacy-store changes occur. #73 provenance, independent
review, native tests, ADR acceptance and all full MR gates remain open.

## In-memory catalogue component — 2026-10-13

The [bootstrap codec proposal](../clients/ios/concurrent-realms-design.md#proposed-in-memory-bootstrap-encoding)
now has isolated executable syntax/context controls: raw 64 KiB admission before
parser copies, strict UTF-8, nonrecursive schema-directed parsing with bounded
strings/containers, duplicate decoded-key refusal, and expected install ID plus
both complete realm trust tuples. Fixed error categories do not echo payloads.
A deterministic encoder only accepts immutable validated public metadata.
Twenty-eight native XCTest methods pass in isolated debug and release runs;
new-head Mac/full-package execution and independent source review are separate.

These controls do not authenticate caller context, prove a fresh installation,
check owner-reference continuity beyond UUID grammar, seal data, enforce durable
allocation or detect rollback. Only unallocated/null-binding catalogues are
supported. There is no new cryptography, key/entropy generation, filesystem,
Keychain, network, migration or app-startup integration. Legacy storage and
codecs are unchanged. Formal #73 provenance, ADR/adoption and every full MR gate
remain open; parsing success is not authority to create or replace an identity.

## Swift facade component evidence — 2026-10-13

The [new Swift facade contract](../clients/ios/devnet-bridge.md#implemented-swift-facade-contract-component-candidate)
refuses embedded NUL and over-limit UTF-8 requests before the C call, strictly
decodes native replies, rejects Foundation's trailing-comma extension outside
quoted strings, and delegates each non-NULL allocation to the Devnet
free exactly once, including thrown error/parse paths. Its XCTest coverage uses
real Rust public vectors for positive behavior and explicit terminated buffers
only for native contract faults. Isolated Swift/native component runs pass.
The later [exact c1e9b90 Mac receipt](../project/evidence/ios-identity-v3-20261013/native-mac-receipts.md)
records the full package and unsigned iOS compilation for that facade, not this
new catalogue component; application/device execution remains NOT RUN.

The facade neither normalizes/signs cryptographic bytes in Swift nor performs
network or persistence actions. Swift text/dictionary copies are not guaranteed
zeroized; caller lifetime/logging discipline remains necessary. Invalid native
pointers, nonterminated allocations and process abort/OOM remain outside the
valid C contract. Passing recovery vectors does not verify a registered nickname,
membership or message history and does not implement owner-operation consent,
registry trust or state-preservation controls. No MR gate is upgraded to passed.

Delta for [RFC-0030](../rfcs/0030-ios-identity-v3.md), the proposal that the
iOS client adopt identity v3. It extends [the iOS client delta](ios-client-threats.md),
[the identity-login v3 delta](identity-login-v3-threats.md) and the RFC-0028
section of [the threat model](threat-model.md), and everything in those
remains required. The identity-login contract is
unchanged. This document adds what is specific to iOS: a second secret at
rest on Apple's storage, one system-trust session, the words on an Apple
screen, contacts added by nickname, and the move of iOS users to other
servers.

Until an ADR is accepted, the recorded state of
[the iOS client delta](ios-client-threats.md) stays as written: no change to
realm or pin, and no automatic recovery, is authorized there
(`ios-client-threats.md:70-71`).

Human residual risk owner: `martadvix-web`. Private synthetic data only. No
human audit, no production assurance and no completed independent review is
claimed here. Independent qualified human review of identity, cryptography,
persistence and application security remains required before this client
carries real communication
([policy item 6](../governance/documentation-policy.md#closed-alpha-review-exception)).

```text
Unchanged: core identity/Olm/frame2 -> pinned TLS -> server; first contact; calls
New realms: two concurrently joined compiled identity-v3 realms, fresh scope
New stores: install catalogue + independently wrapped realm state/intent
Shared owner: nickname entropy -> separate Keychain wrapping key
  (WhenUnlockedThisDeviceOnly) + sealed file (protection complete) + markers
Shared physical boundary: one application-wide call/media/resource owner
New signer: paranoid-devnet-client (BIP39, SLIP-0010, Ed25519) behind the C ABI
New trusted source: the Devnet RPC, one system-trust TLS session, one host
New observers: the Devnet RPC operator; the public Devnet registry
Contacts: by nickname through the directory and the registry; the existing
  QR exchange stays only until question 18 removes it
Not used: background owner signing, background tasks, push, faucet
```

## Concurrent-server expansion — 2026-10-12

The owner's product request now has a
[design candidate](../clients/ios/concurrent-realms-design.md) dated 2026-10-13.
It replaces the original single-snapshot matrix, not the shared wire/core
cryptography. The controls below are proposals, not implemented mitigations;
every MR execution gate remains NOT RUN.

| Threat | Proposed control | Verification / residual |
| --- | --- | --- |
| Cross-realm proof, message, cursor or delayed callback confusion | Full RealmKey and runtime/credential target; independent core/store/session; final UI/renderer fence | MR-02/03/09; malicious/compromised app remains trusted failure |
| State from A overwrites B, or lost allocated state appears fresh | Per-realm keys/envelopes plus authenticated catalogue with monotonic allocation; intent/fsync/readback before adoption | MR-06; ambiguous writes freeze, shared catalogue failure stops all |
| An older build ignores new stores and creates a v2 identity | Intact catalogue v5/key occupy old path/account; audited v4 reader refuses; v5 continuity scan handles surviving realm files after legacy-pair loss | MR-06/07 intact and combined-loss tests; v4-only readers remain unsupported for operational rollback |
| Locked owner store blocks unrelated traffic, or global revoked flag stops both | Realm-local intents/terminal state; owner gate affects owner operations only | MR-04/05/06/13; common OS/disk failure can still stop both |
| Two audio controllers or a stale call callback capture/control the wrong realm | One app-wide owner-operation/call admission state, revocable CallTarget lease and acknowledged cleanup; realm-scoped fixed post-call drain | MR-05/10/11/12/15; late auth cannot sign during a call; a stuck teardown denies new calls, not independent text |
| A flooded directory or unbounded waiters starve text/lifecycle safety | Bounded per-realm scheduling, cancellation/deadline removal, coalescing; lifecycle overflow stops/fences | MR-03/12; server-side availability and shared host contention remain |
| Same nickname or short link ID causes a mistaken pair/send/share | Explicit textual realm targeting; proof plus registry check; reject ambiguous/unknown short-ID routing | MR-08/09; RPC trust/stale-card residuals remain |
| One shared owner makes memberships linkable; its compromise affects both | Disclose the selected correlation consequence; retain scoped foreground signing and separate random transport keys | MR-14; common-owner variant selected in comment 6150510664, not an open question 19; no anonymity, seed-theft recovery or owner-key rotation claim |

[Yaroslav's technical disposition](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150510664)
selects a common owner and treats cross-server correlation as an accepted
consequence of "nickname is identity", not an unresolved alternative. This
does not erase observability or owner-compromise/replacement risks, assert
cross-server anonymity or supply missing product/scope approval in PR #73.
The first joint phone session is planned on VDSina; Android's second-realm
capability and owner-confirmed Hetzner admission remain D5 dependencies.
MR-16 is not satisfied by one realm, and each phone action needs its own go.

Human risk owner remains `martadvix-web`. Permanent exact-scope approval,
independent design review, implementation tests and device evidence are separate
gates. "Maximum rights" does not accept these residual risks or authorize
production changes, resets, real sensitive data or release. Owner signing,
RPC, words-screen and sponsor residuals below still apply to both realms.

## Secret at rest

| Threat | Proposed control | Residual |
| --- | --- | --- |
| The entropy is read from a backup or another device | A sealed file excluded from backup on its own inode; the wrapping key is `ThisDeviceOnly` and not synchronizable | A forensically opened, unlocked phone reads it, as on Android |
| The entropy is read while the phone is locked | Keychain class `WhenUnlockedThisDeviceOnly` and file protection `complete`; `errSecInteractionNotAllowed` means "retry when unlocked" | none beyond the platform's |
| A Keychain item survives deletion of the application and silently restores a nickname | The install marker: on a fresh install, stale items are deleted before anything is created; a nickname returns only from the words | none beyond the existing marker limits |
| A torn write loses or forks the owner material | Write-intent marker synced first, `F_FULLFSYNC`, rename, byte-exact readback, directory sync, marker removal and another sync; a leftover marker or key XOR file freezes the owner functions only; a key is never regenerated | Power loss NOT RUN |
| The words or entropy stay in freed native memory | Devnet requests are copied into zeroizing buffers, and replies are overwritten by `paranoid_devnet_free` | Swift-managed copies cannot be guaranteed zeroized (RFC-0026:177-178) |
| The words reach a log, the clipboard or a crash report | No logging of words, entropy, keys or signatures; no clipboard by default | as above |

## Owner signing

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A background or hostile code path signs as the owner | Owner operations only from an explicit foreground screen, behind a device-owner prompt (question 7); never during a call | A compromised, unlocked phone can still sign; a phone without a passcode gets a tap or a refusal (question 7) |
| Swift signs bytes it built | Swift passes typed requests only; Rust builds and signs (RFC-0026:174-178, draft) | none |
| A wrong program or cluster is signed for | The live genesis, Program/ProgramData and record checks run in Swift, ported from Android's Java with its negative cases, against pins that come only from Rust `program_info` | A consistent RPC lie, or a program upgrade between verification and execution (RFC-0026:205-206) |
| Whoever holds the words or the old phone's key takes the login back | Disclosed in the replacement confirmation; one replacement per 24 hours, at most eight generations including the enrollment (seven replacements) | A private-alpha limit that awaits human risk acceptance (ADR-0016:28-35, proposed) |
| Real wallet words are entered | A warning before entry; `m/44'/501'/0'/0'` is the usual Solana wallet path, so such words would put that wallet's key into the application. Recovery stores nothing when the words hold no ParanoID nickname, so such words never reach registration | The warning can be ignored; the RPC learns which wallet address was looked up |

## The words on screen

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A screenshot captures the words | Shown only after an explicit tap; after `userDidTakeScreenshotNotification`, a notice that the picture may be in Photos and iCloud and how to delete it | **Open gap**: iOS cannot refuse a screenshot |
| Recording, mirroring or AirPlay captures the words | Covered while the scene's capture state reports capture; checked again before each display | Frames drawn before a capture starts can be recorded |
| The app-switcher snapshot holds the words | Covered whenever the scene resigns active; never restored from scene state | not measured on a device |
| A third-party keyboard, dictation or writing tools learn the words | Third-party keyboards refused app-wide; autocorrection, spell checking, prediction, dictation and writing tools off | System keyboard behaviour NOT RUN |

## Network trust

| Threat | Proposed control | Residual |
| --- | --- | --- |
| An interceptor on the phone's path holds a certificate the trust store accepts (a mis-issued certificate, or a user- or MDM-installed root) | One host, one reviewed session, TLS 1.2 or later, no proxies, redirects, cookies or caches, a method allowlist and size limits; the RPC's answers are checked for consistency, not proven | **A false registration success or a false recovered name**; a false directory confirmation only together with a dishonest server. The v3 server checks the registry over its own connection before `commit`, so no false membership |
| The RPC provider itself is dishonest | The RPC is a trusted source (ADR-0016:32-33); the same consistency checks | **All of the above, plus a false membership and a false directory add on an honest server**, because both v3 servers read the same provider unless `PARANOID_REGISTRY_RPC` is set (`server/src/main.rs:299-309`; `server/src/identity_v3.rs:649`) and the installer does not set it |
| The v3 server lies about membership | Owner and device proofs; the result must match the phone's own credential; nothing is automatic on error | A malicious server can refuse or ban |
| A v3 pin is substituted | Compiled in, confirmed explicitly, never learned from a challenge or a link | none |
| A server registered its own key for a nickname | The directory add checks the finalized registry before pairing (`clients/core/src/clean_service.rs:174-180`) | Defeated by a dishonest RPC provider alone, or by an interceptor together with that server; the stale-card residual in the RFC-0028 section of `threat-model.md` |

## The sponsor and the servers

| Threat | Proposed control | Residual |
| --- | --- | --- |
| The sponsor, which is the v3 server, front-runs a name with its own key, withholds or delays the transaction, or misreports its limits | The pending attempt is sealed before the signature leaves the phone; success only from the registry | **Can block registration**; the server learns the name before the chain does |
| The sponsor is drained, or the 128 memberships are filled | Server-side caps of 20 per hour, 60 per day and 3 distinct names per owner (`server/src/sponsor.rs:25-30`) | The caps live in process memory and reset on restart (`threat-model.md`, section «Fresh Solana Devnet identity boundary»); the realms and pins are public in the repository, so anyone can reach the servers; this can block D5 |

## Supply chain

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A dependency drifting from the Android builds | The bridge lock keeps every core-lock entry with its name, version, source and checksum, and every other entry must match the Devnet crate's lock | Measured combined lock: 123 core registry entries retained, 58 matching Devnet additions; six shared pins use core versions. Host ABI/public-vector checks pass; no full application assurance |
| C or assembly compiled for an Apple target on a CI host without its SDK | `blake3/pure` through feature unification | All three Apple-triple type checks with `pure` pass on Linux; Mac C-link/xcframework and old-app regression results are reported separately below; new v3 runtime and phone acceptance are NOT RUN |

## New observers

- **The Devnet RPC operator** sees the phone's IP address and which owner and
  nickname it reads or registers.
- **The Devnet registry** makes the nickname-to-owner binding public and
  enumerable (RFC-0026:182); the deployed program has no rename, transfer or
  close (RFC-0026:131-132).
- **The v3 server** sees the owner and the nickname in addition to everything
  the v2 server saw, sees a chosen name before the chain as sponsor, and
  learns who searched for whom.
- **Other active members of the same server** see a visible member's
  nickname, owner key, identity PDA, credential and contact card. Members are
  visible by default (RFC-0028), so iOS shows the visibility switch before
  the first publication.

## Move and coexistence

| Threat | Proposed control | Residual |
| --- | --- | --- |
| A saved v2 identity is silently moved to v3, or the reverse | Saved trust wins; the core refuses a realm change; no fallback in either direction | none |
| A user believes v2 contacts moved with them | No automatic migration/reset; explicitly authorized fresh transition creates independent device state for each realm (question 9) | v2 accounts stay on a stopped server without a deletion path |
| A replaced phone keeps retrying | `revoked` stops only that realm and its media lease, records realm-local terminal state independent of the owner store; inaccessible persistence immediately fences the runtime and requires status before restart traffic | The owner key on that phone can still move the login back |
| A v3 database reset leaves the phone in an unexplained state | `absent` leads to an explicit login, never an automatic enrollment or rekey | Untested on Android too |

## Verification status

The [local Devnet ABI receipt](../clients/ios/devnet-bridge.md) now provides
component evidence for bounded request handling, request/C-reply erasure,
unchanged Rust recovery/identity operations, two-lock preservation and the
pure Apple dependency graph. Original Rust intermediate/Swift-memory erasure
is not directly proved by the allocator test. No host check proves iOS storage,
authentication UI, live RPC trust, native linking or current-server interop.

The [exact-head Mac receipt](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6147113616)
for `7a39897` adds reported native C smoke, xcframework regeneration and
ParanoidKit 389/0. Its separately run simulator/Keychain and unsigned device
checks exercise the unchanged old application, not owner storage/login or v3
realm isolation. A [second Mac receipt for 4aac29c](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150129691)
now covers the integrated PR76 head: focused native and supplementary app checks
passed, but full-wrapper gate 11 still stops and QR was 1 PASS / 3 FAIL. Neither
receipt proves the new storage/runtime; no mitigation becomes phone assurance.

The remaining controls and MR-01..16 execution remain proposed/NOT RUN. The
older [feasibility record](../project/evidence/ios-identity-v3-20261006/feasibility-mac.md)
is retained separately; neither record is physical-phone acceptance.
