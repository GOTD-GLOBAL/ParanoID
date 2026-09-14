---
status: proposed
owner: ios
decision_owner: martadvix-web
last_reviewed: 2026-09-14
---

# Lazy wrapping-key correction: handoff for Mac verification

## Scope and authority

Yaroslav requested that the coordinator implement the remaining storage P1 in
PR #36, and selected a split workflow: the coordinator writes code/tests on a
separate branch, the contributor executes Apple tests and returns results.
This is task authorization in Telegram, not a permanent ADR approval permalink.
[RFC-0021](../../rfcs/0021-ios-client.md) and
[ADR-0014](../../decisions/0014-ios-client.md) remain proposed. No server, Android,
core, live device, TestFlight, merge or deployment change is included.

The candidate starts from `d96cea12bca3efd88ee633f63ef51948413c2a7d` on
`fix/ios-lazy-wrapping-key`. Previous simulator/device/package evidence applies
to those previous revisions, not to this correction.

## Contract

- Welcome constructs the persistent-key `SnapshotStore` adapter but creates no
  Keychain item. Empty-store load creates no key either.
- Only an actual first commit can create the wrapping key, before sealing/writing
  the candidate. Subsequent commits load the same retained key and never replace it.
- The five file steps and inode-bound backup exclusion are unchanged.
- Keychain plus file are not one atomic transaction. A failure after key creation
  may leave a key without a committed file. That freezes on the next launch,
  preserving the key; no automatic rollback deletes it. This is an explicit
  availability cost, not crash-transparent first registration.
- With `install.v1` present, key XOR file always freezes. All old pending/commit
  defaults are ignored, including stale `paranoid.firstrun.pending.v1`.
- With no install marker and a surviving file, freeze before any mutation.
  With no marker and no file, retain the existing proposed reinstall rule:
  delete the stale reinstall key, record install.v1, leave key creation for commit.
- Existing key/account attributes, codec/version, state bytes and saved trust do
  not change. An earlier build abandoned on Welcome with an already-created key
  still freezes; its ambiguity is not silently migrated.
- Complete rollback/removal of both key and file cannot be distinguished from an
  empty installation. There is no new recovery or anti-rollback guarantee.

The ignored `marker:` argument of the explicit-key fixture initializer remains
source-compatible for existing tools. That initializer is not the application's
persistent-key path. The new application path is `keyStore:`.

## Verification state

**Executed on Linux:** source-wiring regression was RED with three failures on
base code, then GREEN after correction; the existing UI source-contract suite
passes 20 tests. These inspect real source wiring, not Apple runtime behavior.
Bridge lock validation and six Rust ABI tests also pass; the bridge/core were
not changed. Changed Markdown files pass markdownlint-cli2 (11 files). A full
repository run with locally available markdownlint-cli2 0.23.2 reports existing
MD060 issues in two unchanged documents; those are not silently called green.
Tree-sitter parsing finds no new syntax errors in changed Swift files; its one
baseline limitation on Swift `sending` syntax remains and this is not compilation.
An isolated native gpt-6-astra source review found no high-confidence code blocker;
this does not supply the missing Apple runtime verification.

**NOT RUN here:** all changed/new Swift tests, CryptoKit execution, Keychain,
Xcode app build, simulator, physical-device lifecycle and real filesystem power
loss. No Swift/Xcode toolchain is present on the coordinator host. The contributor
agreed to execute these on the Mac; no runtime closure is claimed until receipt.

`SnapshotStoreTests` retains the lost-bookkeeping/lost-file regression as an
ordinary assertion, not `XCTExpectFailure`. Legacy pending facts are explicitly
seeded and ignored. `LazySnapshotKeyTests` exercises key creation at commit,
Welcome/relaunch, key/file loss, unreadable keys and first-commit failures.
The pre-existing five-step/codec/file-fault tests remain. Obsolete pending-marker
policy tests are replaced by strict-XOR and lazy-commit tests, not silently skipped.

`KeychainStoreTests` uses a unique test account instead of borrowing the live
application account; interrupted tests must not destroy an installed identity.
Only test-local defaults and temporary files are removed. Actual crash/cut-power
certification remains outside simulator fault injection.

## Mac commands

Use a separate worktree at the provided commit, with the already pinned binaries
from the contributor's normal build setup. Do not reset the real application or
run this on a physical phone yet. From the repository root:

```sh
python3 -B clients/ios/test_storage_bootstrap_contract.py
python3 -B clients/ios/test_ui_contract.py
python3 -B clients/ios/test_docs_consistency.py
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter SnapshotStoreTests
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm
```

Then run the normal **signed simulator** Keychain suite (the signing-disabled run
cannot exercise Keychain). Use the simulator destination already used by the
contributor, and the project's normal `ParanoID` scheme:

```sh
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination "$PARANOID_IOS_SIMULATOR" \
  -derivedDataPath clients/ios/out/lazy-key-signed \
  -only-testing:ParanoIDTests/KeychainStoreTests
```

No archive/export/provisioning update or TestFlight command is requested. Send
command, exact commit, exit code and failing test diagnostics, without key or
snapshot contents. A successful package run is not physical-device proof.

To show behavioral RED on the old guard, use a disposable scratch checkout with
only the original expected-failure wrapper removed; keep the assertion `.frozen`.
Do not weaken any expectation to make the suite green.
