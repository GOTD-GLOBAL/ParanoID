# Credential compatibility handoff — 2026-09-10

Outcome: the actual inert credential matrix stopped twice at its first
system-manager positive case. The next bounded diagnostic is implemented and
tested offline but **NOT RUN**. No production credential predicate was relaxed,
and no credential or relay acceptance gate is complete. This handoff is evidence
and disposition; it authorizes no additional runtime action.

## Actual evidence

The first run, `runtime/result.json` (run ID
`007a40a3384849c9bd31d1e0f319dffa`), and the single corrected run,
`corrected-once/runtime/result.json` (run ID
`985048ceaa652f9fa3386fb82836141c`), both report `STOPPED` with
`failure_category=success_marker_not_observed`. Each `systemd-run` request was
accepted with exit0, but no success marker appeared within5s. The first helper
output was not retained. The corrected run retained only
`credential_validation_failed`, without the failing stage or runtime descriptor.
The changed fixture directory permissions and failure-output retention did not
change the inert helper: both runs used helper SHA256
`4c0871bb2a42114355a711688d5cabbc455864964572ac63569d09f62595fe38`.

Both source descriptors were UID0, mode0400 (decimal256), nlink1, size64. Source
metadata is not evidence of the copied credential's metadata. In both runs the
other five matrix cases—system missing/malformed and user good/missing/malformed—
remain `NOT_RUN`. Positive restart and explicit live-service stop acceptance
were not reached. The auto-collected unit's later not-found/default properties
do not prove effective in-process confinement.

Both retained results report `fixture_sources_removed=true` and
`neighbors_unchanged=true`; the owned runtime/credential paths were absent after
cleanup. No production unit, account, relay, firewall, namespace or neighboring
service was changed by these inert cases.

The separate failed message fixture4 is not a third credential observation.
Its retained public server mode with loopback TURN address is a definite
configuration mismatch; its generic failure log does not establish a user-manager
credential failure. See `../installer-integration-audit.md` for retained hashes
and the source-backed distinction.

## Unmeasured compatibility hypothesis

Upstream systemd255 `write_credential` sets0400 and prefers a named-user read ACL
while retaining manager ownership; chown is a fallback. This supports a possible
root-owned0440 runtime copy. The actual copied file owner, mode, failing predicate
and ACL were **NOT MEASURED** in these runs. This is a source-supported
compatibility risk, not an attribution of the two failures.

The inert helper requires ownership by its service UID and0400/0600. The relay
loader allows root/euid ownership but likewise requires0400/0600. A root0440
delivery would fail both strict predicates for different reasons. The issuer
uses the same-UID user manager; no issuer credential compatibility failure has
been observed. No arbitrary root-owned or group-readable file is newly accepted.

The supplemental reviewer questioned the proposed credential directory0550
layout and suggested a possible0750/owner-write layout. That is a **reviewer
hypothesis**, not an observed directory mode and not a proven design error.
Neither layout may be selected or broadened into production from that guess.
The numeric file diagnostic does not measure the directory ACL, so a future exact
directory contract would require separate justified evidence and review.

## Supplemental review and named-model capability failure

`../fable-credential-design/review.md` gives a substantive supplemental review:
it approves the unchanged-guard numeric diagnostic in principle and withholds
runtime reader implementation pending actual observation, exact ACL/directory
proof, additional design confirmation, tests, package re-pin and final review.
However, the requested model identity is not established by that response. Its
machine result reports Opus4.8/Opus5 plus Haiku usage, not the requested Fable.

The single identity-only probe retained under `../fable-model-capability/`
requested `--model claude-fable-5`, with no tools. It completed with exit0 and
`READY`, but `modelUsage` identifies `claude-opus-5` (plus Haiku), not Fable.
The exact named-reviewer capability is therefore unavailable through the
requested path as observed. Neither invocation records a permission denial;
this is a **model-identity constraint**, not an automatic safety rejection or a
missing sudo/systemd capability. Root stopped here: no additional routing,
diagnostic run or production reader change follows from supplemental approval.

The earlier denied `media_discovery` worker remains a separate unchanged
constraint. No credential work substitutes for or replays its denied TURN
packet/authentication/expiry scope.

## Preserved next step and acceptance limits

The diagnostic source/helper and16-test offline GREEN are frozen in
`diagnostic/`. `validation.json` records identical strict-guard ASTs, unchanged
production sources and confinement properties, and no helper ACL/xattr calls.
The observer emits only a closed enum/numeric stage and descriptor schema. It
selects exactly one fresh-name system-good case, with no restart and no way to
mark acceptance PASS. The proposed runtime diagnostic remains **NOT_RUN**.

Before any execution, restore a verifiable named Fable review capability or
obtain an explicit owner disposition of the reviewer requirement, then review
the exact frozen diagnostic. The review's small handoff clarifications remain
applicable: diagnostic exit0 would mean diagnostic completion, not successful
credential validation; an early failed helper would not re-prove live-process
confinement; use only the reviewed manager readback. Root must coordinate the
single bounded unchanged-guard observation. If the observed stage contradicts
the ACL hypothesis, preserve it and revise the hypothesis without a validator
change.

A production compatibility correction, if evidence later justifies it, still
needs an exact runtime-copy-only descriptor/ACL and private-directory contract,
fresh design approval, meaningful strict RED/GREEN, a separately reviewed inert
compatibility matrix, and rebuilt/re-pinned TURN plus unified artifacts and final
code/artifact review. Source0400/0600, generic relay `read_secret`, alpha issuer
and Rust issuer semantics must remain strict unless an exact separately approved
contract explicitly changes them. No chmod/chown/ACL-stripping or secret-copy
workaround is authorized.

Remaining technical acceptance includes successful system/user-manager
credential delivery and lifecycle/error matrix; production issuer delivery;
actual relay CLI/loader/runtime lifecycle and confinement; TURN-RT01,
TURN-ACL02 and expiry/authentication behavior; effective scoped nft/UFW policy;
the complete coordinated production install/update/recovery rehearsal; and
CALL-CURRENT01. None is closed by these inert failures, offline observer tests,
supplemental review or the separately scoped message-only rehearsal. Public
relay exposure remains blocked on required genuine acceptance.

## Exact retained identities

SHA256 values below identify this read-only handoff's inputs. Paths without a
leading slash are relative to this evidence root's parent (`..`).

| Input | SHA256 |
| --- | --- |
| `credentials/runtime/result.json` | `811b62f22f7cda32f9809972f20d3d86e4f0dc760c8fdd7249b80b144a8ea7a1` |
| `credentials/corrected-once/runtime/result.json` | `8771399031664ce7e71fd973ce98496c583a50748ed7398a3daa8f7da5fb0409` |
| `credentials/credential-compatibility-finding.md` | `08e753db83b24d4add5ef34cf360e7ff8540aff922af52f443b4510adaa16fbb` |
| `credential-acl-design.md` (proposed) | `e014d890d63303cb00ec57e0c19da1f5c570453f48a6adbcd8c674abfc953ca4` |
| `credentials/diagnostic/source.py.txt` | `0fba08ff1b37d6d24102a339a20c713fb4c271dbe5114810fadd076c6af7394c` |
| `credentials/diagnostic/helper.py.txt` | `7b69d3766aad4c66b890a351f2a6f5b601d00801a5659a8f9de6b2412fce2ef9` |
| `credentials/diagnostic/validation.json` | `d50f9b4f88790c7a428adab1d84eaae3b9089bd5fd9707bba84dddcd73274d0c` |
| `fable-credential-design/review.md` (supplemental) | `2b281f6f729c1701a4bf6cdfc426d2a9c05ca95226278c8a8e84080761621e8e` |
| `fable-credential-design/result.json` | `2e139edafc0993a66ba8e89d74b3f4cbdc1d5296c1c350486cb8152f1b23ef17` |
| `fable-model-capability/command.json` | `8029c69915842f67572a48273ac19492c0eb2f2613e3c83fc0732a1610631c91` |
| `fable-model-capability/result.json` | `452074efb3ce2eae103dccf67f81ad6a0828bbfd748696d97eab7576e4b103c0` |
| `fable-model-capability/process.json` | `df4d721d233a2334088d2d2e0110346ae9e509ff46bf0b379fbcfa85c715af4d` |

Current unchanged product files in the server worktree
`/home/codex/projects/paranoid-worktrees/voice-turn-server-20260909`:

| File | SHA256 |
| --- | --- |
| `deploy/turn/runtime.py` | `e302d7ccb38836f4665700b4a49e6607d0349f3ea0ca45ed11ef10c05c36b6c5` |
| `deploy/alpha.py` | `db681763055cd3fbd916f8c4afcab1823de0f6c4c05e107a9cbe60ecf3d11c06` |
| `server/src/voice_turn.rs` | `babc1eace0cb9268357849b3c083a2242860d25ed4ee9ce2f1d435f80ecdeb63` |

The relay runtime hash also equals the frozen supplemental-review input.
The supplemental frozen tree omitted alpha/Rust source; this independent
read-only source/hash inspection does not turn that review into their approval.
