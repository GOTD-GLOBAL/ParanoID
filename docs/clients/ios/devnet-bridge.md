---
status: draft
owner: ios
last_reviewed: 2026-10-13
---

# Devnet C ABI and Swift facade: component prerequisites

This implements only the bridge prerequisite of [RFC-0030](../../rfcs/0030-ios-identity-v3.md#the-native-bridge-question-5)
under [draft ADR-0017](../../decisions/0017-ios-concurrent-identity-v3.md#authority-and-work-boundary).
ADR-0014/0016 remain proposed; no architecture acceptance is implied.

The end goal is iOS using the **current configured identity-v3 servers** and
interoperating with existing Android clients on the same server, including the
requested concurrent-realm behavior. This is not a new server/instance/stand
workstream. These offline unit/negative tests are component evidence, not
end-user acceptance or a substitute for current-server compatibility. No endpoint,
pin, server/DB configuration, persistent account, app installation, RPC call,
registration or Apple operation was added or performed.

## Contract and ownership

The existing `ParanoidCoreFFI` module and `paranoid_core.h` expose two additional
symbols in the same static library:

```c
char *paranoid_devnet_command(const char *request);
void paranoid_devnet_free(char *reply);
```

- Input is a readable NUL-terminated UTF-8 JSON string, valid throughout the call.
  NULL/non-UTF-8 input returns `{"error":"invalid_request"}`.
- The maximum is 16384 bytes, excluding NUL. The bridge scans at most 16385 bytes
  and rejects an oversized request with `{"error":"input_limit"}` before copying
  or UTF-8 decoding. Exactly 16384 bytes may reach the unchanged Rust command.
- Valid input is copied into `Zeroizing<String>` and passed unchanged to
  `paranoid_devnet_client::command`. No cryptography, derivation, transaction
  construction, pin, name normalization or error translation is reimplemented.
- The command's JSON response is returned unchanged. An unwinding panic becomes
  `{"error":"native_failure"}`; an interior NUL in a response also fails with that
  fixed error. Normal responses, including errors, are allocated and non-NULL.
- The original Rust response is zeroized after copying into an exact-sized C
  allocation, without resizing a secret-bearing buffer. `paranoid_devnet_free`
  overwrites the C allocation, including NUL, before releasing it. NULL free is
  a no-op. The caller must not modify any reply byte, free it twice, use `free()`,
  or use `paranoid_core_free` for Devnet replies.
- Caller-owned input is never modified. Swift must minimize the lifetime of its
  own copies and must always pair the call with the Devnet free, including on
  parse/error paths. Neither Swift strings nor all upstream serializer/crypto
  intermediates are claimed to be zeroized by this shim.
- Raw pointers still require the documented C safety contract. Invalid pointers,
  concurrent mutation, double-free, allocation failure and aborting panics cannot
  be repaired by `catch_unwind`. Rust's process-wide panic hook is not replaced;
  this shim never logs requests, replies, words, entropy, keys or signatures.
- The old core exports and their allocation/free behavior are unchanged.

The JSON contract remains [the existing Rust implementation](../../../blockchain/solana/client/src/lib.rs):
`program_info`, `identity`, `recover`, `export_mnemonic`, `lookup`, `verify`,
registration/sponsored transaction operations and `identity_owner_proof_v3`.
`identity` exposes only public owner/PDA/program/genesis/RPC information;
`recover` and `export_mnemonic` return secret material. Public test words are not
real wallet credentials and must not be replaced with real wallet words in tests.

## Implemented Swift facade contract (component candidate)

[`DevnetBridge.command(request:)`](../../../clients/ios/ParanoidKit/Sources/ParanoidKit/Core/DevnetBridge.swift)
now returns a `DevnetReply` with verbatim UTF-8 `text` and the decoded top-level
`object`. It is exercised as an isolated Swift/Rust component; full Mac package,
application and device validation of this new Swift code remain NOT RUN.
There is no new wire version: the JSON operations remain the unchanged Rust
`Command` contract, and the facade is not an owner-authentication policy.

- The Swift request must contain no embedded NUL and no more than 16384 UTF-8
  bytes. Refuse before creating the temporary C string or invoking native code;
  character count is not a byte bound. The mirrored cap must remain covered by
  exact-limit/over-limit/multibyte tests against the real Rust ABI.
- Invoke only `paranoid_devnet_command` for these operations. Every non-NULL
  result is paired exactly once with `paranoid_devnet_free`, including decoding
  and error paths. Neither `free()` nor the core's release function is valid.
- Decode native UTF-8 strictly, without replacement characters, and require a
  JSON object. NULL, invalid UTF-8/JSON, a non-object or a non-string `error`
  member is `CoreError.nativeFailure`. A Rust string error is forwarded as
  `CoreError.rejected(code)`, including Rust's fixed `native_failure` code;
  no request, response or recovery material is appended to that error.
- Keep successful response text verbatim rather than reserializing it. Swift
  values must own their copies before the native allocation is released.
  The native allocation is erased by Rust; Swift strings/dictionaries and
  their serialization copies are **not** guaranteed to be zeroized. Minimize
  their lifetime; do not log them, retain them in diagnostic/unbounded caches
  or place them on a clipboard. Reviewed encrypted owner persistence is a
  separate layer, not a cache of raw native replies.
- Public recovery/identity/program-info tests must call the real Rust library.
  Explicit internal native-fault fixtures may exercise impossible NULL or
  malformed-response paths and exact-once release, but cannot substitute for
  positive cryptographic vectors or native linking.
- A successful `recover` returns candidate entropy, not a registry-confirmed
  nickname, server membership, message keys or chat history. Registry checks,
  preservation/freeze, durable intents, owner-operation admission, persistence
  and UI remain separate work. This facade performs no RPC or server call and
  writes no owner state; it cannot itself authorize enrollment or replacement.

The existing `CoreBridge` and core allocation semantics are unchanged. Full
ParanoidKit/Xcode/Keychain/application and phone checks remain the selected Mac
and physical-device gates; an isolated component compile is not that receipt.

### Swift evidence and next native check

[`DevnetBridgeTests`](../../../clients/ios/ParanoidKit/Tests/ParanoidKitTests/DevnetBridgeTests.swift)
has 19 XCTest methods. The [TDD receipt](../../../clients/ios/bridge/evidence/swift-adapter-tdd.txt)
records nine vertical RED/GREEN slices and labels the additional passing
regressions as regressions, not manufactured REDs. Public 12/24-word recovery,
owner derivation and program information use the actual Rust library. Explicit
terminated-buffer fault fixtures check NULL, invalid native UTF-8/JSON/error
types, unmodified native bytes, exact-once release and surviving Swift copies.

On Swift 6.3.3 / Rust 1.98.1, x86_64 Linux, the exact repository sources/tests
were symlinked into a disposable scratch-only component manifest. Product and
test targets use Swift 6 language mode. Debug and Swift-release runs passed
19 new tests plus 10 unchanged CoreBridge tests. The coordinator repeated these,
then linked a rebuilt **release Rust staticlib** for an additional optimized
Swift/release-Rust run: 29/0 again. Source/test-target warnings-as-errors passed.
No repository package target, dependency, SDK pin, CI gate or Linux runner was
added or changed. This does not run the full ParanoidKit package on Linux.

The receipt retains failed optional global Swift-version flag experiments in
SwiftPM-generated Linux discovery; they are not TDD REDs or successful runs.
Manifest-driven product/test compilation stayed Swift 6. Do not carry those
diagnostic flags into the canonical Mac commands or edit generated discovery
to claim a pass.

On the exact reviewed new source SHA, in a clean dedicated worktree with pinned
tools and cached WebRTC, regenerate the native bridge, verify dependencies,
and execute the new feature before the complete existing package:

```sh
bash clients/ios/build-core.sh
bash clients/ios/toolchain.sh python3 clients/ios/webrtc_dependency.py --offline
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm \
  --filter DevnetBridgeTests
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm \
  --filter CoreBridgeTests
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
```

Return the actual new-head compiler/test results. The old `4aac29c` receipt
does not cover this facade. No phone installation, registration, login, owner
replacement, signed export or server action is included. Gate 11 and the QR
flake remain open, not made green by passing these targeted tests. A caller
still needs the reviewed storage/registry/login flows before app integration.

## Dependency and build integration

The bridge adds a path dependency on the unchanged Devnet crate, exact
`zeroize = 1.9.0`, and exact `blake3 = 1.8.7` with `pure` enabled through feature
unification. `serde_json` remains pinned by the committed lock as before.
No shared manifest or lock was changed.

The executable [two-lock gate](../../../clients/ios/test_bridge_lock.py) implements
RFC-0030's candidate rule:

1. Every core-lock registry entry retains name, version, source and checksum.
2. Every added registry entry must match the Devnet lock on all those fields.
3. The only path packages are core, key-protocol, Devnet and bridge. Core path
   versions are retained; Devnet's path version matches its own lock.

The measured combined graph has **123 retained core registry entries, 58 added
Devnet registry entries, and four path packages**. These are package-version
entries, not distinct names or the historical feasibility snapshot's counts.
Six shared pins retain the core versions: `cfg-if 1.0.4`, `syn 3.0.5`,
`toml_edit 0.25.13+spec-1.1.0`, `unicode-ident 1.0.24`, and
`zerocopy`/`zerocopy-derive 0.8.56`. The seven compatible additional major/minor
lines already in the Devnet lock coexist. `cc 1.4.7` and `find-msvc-tools 0.1.13`
match the Devnet lock; no forced update of either shared lock was needed.

Resolution was seeded from the existing bridge lock with:

```sh
cargo +1.98.1 check --offline --manifest-path clients/ios/bridge/Cargo.toml
python3 clients/ios/test_bridge_lock.py
```

Future resolution must preserve that rule. If Cargo selects newer added pins,
constrain only the bridge resolution to the exact source-lock versions and rerun
the gate. If the combined graph cannot satisfy the rule, stop and report the
conflict; do not weaken the gate or update a shared lock to hide it.

`build-core.sh` already packages the entire `bridge/include` directory with all
three static archives, so its generated xcframework headers now include these
exports without a second library or header generator. Rebuild it on Mac: stale
xcframeworks do not acquire symbols by updating source headers alone.

The notices graph remains rooted at the bridge and filtered for the Apple device
triple. It now renders **146 linked registry packages plus WebRTC**. Missing
Devnet license texts use the existing read-only
[Android provenance/texts](../../../clients/android/licenses/devnet/sources.json),
with declared-license equality and SHA-256 enforcement. Existing core fallback
rules are retained. No license download or silent omission occurs; legal review
and any upstream NOTICE gaps are not represented as resolved by packaging.

## Invariants and evidence

| Requirement / boundary | Executable evidence | Limit |
| --- | --- | --- |
| REQ-CLIENT-001, D3: same Rust implementation behind C | Rust ABI tests and compiled/linked `tests/abi.c` | Host component only |
| REQ-ID-002/003: unchanged recovery and owner derivation | Public 12/24-word vectors, fixed owner keys, identity output compared to the crate | Not recovery of chats or proof of registry membership |
| REQ-SEC-001: copied secrets erased at FFI ownership boundary | Allocator observes bytes before actual deallocation; debug and optimized tests | Not Swift/upstream-memory or physical-device assurance |
| RFC-0030 resource/ABI boundary | NULL, invalid UTF-8/JSON, invalid mnemonic/entropy, exact/oversized byte limits, independent allocations, injected unwind | Does not validate arbitrary invalid pointers |
| RFC-0030 two-lock and pure Apple graph | Nine lock negative tests, real lock comparison, resolved features and three Apple checks | No SDK linking or iOS runtime on Linux |
| Old core ABI retained | Six existing core ABI tests, C consumer regression | Not the complete core/Android acceptance suite |

[Initial RED/GREEN receipts](../../../clients/ios/bridge/evidence/tdd.txt) retain
actual command output: initially missing exports, then unwiped request/reply,
oversized input copied before rejection, missing C declarations, lock-allowlist
and missing-license failures. The Apple device check initially failed in BLAKE3's
native compiler path (`clang`/`xcrun` unavailable), then passed with `pure`.
Identity and other unchanged command cases are regression tests, not newly
implemented crypto features. The unwind path uses one private injected closure;
crypto, allocation/free and C-link tests use the real implementation.

[Final Linux receipt](../../../clients/ios/bridge/evidence/host-checks.txt), Rust
1.98.1 on x86_64 Linux:

- `cargo fmt -- --check` and `cargo clippy --all-targets -- -D warnings`: pass.
- Bridge Rust tests: 15 passed, none failed/ignored; the allocator test also
  passes under `--release`.
- Existing Devnet crate's own `--lib` suite: 10 passed under its **own unchanged
  lock**, not the combined bridge graph. Cargo refuses `-p paranoid-devnet-client`
  tests from the bridge because it is not a workspace member; the script uses
  the original manifest rather than altering workspace membership.
- C header/staticlib consumer: public recovery, identity, allocation/free and
  core error ABI pass.
- `cargo check --locked` for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and
  `aarch64-apple-darwin`: pass. Resolved BLAKE3 features include `pure`.
- Lock gate and nine negative tests: pass. Notices and 32 notice tests: pass.
- No iOS app, simulator, native Swift or physical-device result is claimed.
- Changed Python files: `ruff check` passes; local Markdown links resolve.
  The child's unpinned markdownlint-cli2 0.23.3 / markdownlint 0.41.1 invocation
  reported 24 MD060 errors in four untouched files
  (older voice evidence, PR51/54 review, RFC-0029 and push-wake threats). None
  comes from this document; these unrelated baseline files were not changed.
  The parent reran the CI-pinned markdownlint-cli2 0.18.1 over the integrated
  repository: 250 files, zero errors. The unpinned result is not a CI failure.
- Independent CLI code review: **NOT RUN**; the attempt failed with HTTP 401.
  No authentication/provider/sandbox retry or credential operation followed.
  The parent will perform fresh-context review after this stable handoff; the
  the candidate commit is not review approval, merge authority or architecture acceptance.

The subsequent source review found no C-ABI blocker. It identified a Mac-runner
fail-open on Git-status error and stale lock reseeding instructions; both were
corrected with negative tests/documentation. Duplicate path names in any source
or bridge lock are now rejected (ten lock tests). Mac runner regression coverage
is now nine tests, including a real corrupted Git index with retained dirty
source. [Scoped review closure](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6146347252)
records B1/B2 closure on `7a39897`, not whole-app or architecture acceptance.
The allocator test directly observes the request copy and returned C
buffer; extra assertions for original Rust response capacity/unwind cleanup are
a non-blocking follow-up, not claimed coverage.

The [threat delta](../../security/ios-identity-v3-threats.md#secret-at-rest) remains
draft. This component evidence covers only its FFI memory and supply-chain rows;
owner storage, authentication prompt, RPC trust, runtime realm isolation and
current-server/Android interoperability remain unverified. This scoped child
changes no global current-state, threat-model or changelog record; integration
must link these receipts without marking the broader gates passed.

## Reproduce and hand off to the Mac

From the exact reviewed repository revision, with Rust 1.98.1, its rustfmt/clippy,
the three Apple standard-library targets, cached locked crate sources, Python
3.11+ and a C compiler:

```sh
bash clients/ios/bridge/check.sh
```

This runner is offline and fails on missing prerequisites; it never provisions
servers, contacts RPC, installs an app or operates Apple credentials. Its Linux
branch was exercised here. The [contributor's Mac receipt](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6147113616)
on `7a39897f83511d368358f606e88193bf4a6594ad` now reports Darwin C-link/run,
three regenerated xcframework slices and 389 passing package tests. Its full
wrapper stopped at gate 9; later individually run simulator/device checks are
not a successful wrapper or a working identity-v3 application. The [integrated
PR76-head receipt at 4aac29c](https://github.com/GOTD-GLOBAL/ParanoID/pull/75#issuecomment-6150129691)
now reports the focused native checks passing; full-wrapper gate 11 remains
blocked and the QR gate is flaky (1 PASS / 3 FAIL). The [handoff](identity-v3-mac-handoff.md)
records these limits without requiring a server port or a repeat of unchanged
native code just for a documentation correction.

On Yaroslav's pinned Mac, regenerate native artifacts and run native regressions:

```sh
bash clients/ios/toolchain.sh bash clients/ios/bridge/check.sh
bash clients/ios/build-core.sh
bash clients/ios/toolchain.sh python3 clients/ios/webrtc_dependency.py --offline
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --scratch-path clients/ios/out/spm
```

The pinned WebRTC archive must already be cached for offline extraction;
follow the existing [build prerequisites](build-and-testflight.md) if absent.
SwiftPM needs the verified extracted xcframework even for the host package run.
Do not replace these commands with a Linux `cargo check` receipt, reuse a stale
native library, or infer permission to upload/sign/install anything.

The Swift adapter imports `ParanoidCoreFFI`, invokes
`paranoid_devnet_command` with the complete UTF-8 JSON request, parses the reply
and uses `defer` to call `paranoid_devnet_free` once. Use the existing core ABI
for independently scoped messenger device credentials. Preserve current compiled
profiles and saved full realm/pin bindings; derive owner/program information
through this Rust API, not new Swift literals or a new endpoint. ABI calls alone
perform no connection: login intents, directory verification, storage and
concurrent runtimes still require implementation, negative/native tests and
review. Successful live operation against the current configured servers with
existing Android peers remains the end-user acceptance target, separately
scoped and **NOT RUN** here.

Return an exact-head Mac receipt naming the commit, tool versions, regenerated
archive/header hashes, test counts, failures and skips. This enables the next
Swift integration step; it does not certify server admission or phone acceptance.
Rollback of this prerequisite is a source revert and rebuild of the library;
it creates no persistent state to migrate or delete.
