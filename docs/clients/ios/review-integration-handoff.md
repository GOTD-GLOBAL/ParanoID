---
status: proposed
owner: ios
decision_owner: martadvix-web
last_reviewed: 2026-09-14
---

# PR36 F1–F7 correction: Mac verification handoff

## Scope and authority

Yaroslav requested implementation by the coordinator and offered to run the
result on his Mac (Telegram task authorization, no permalink available). Base:
`f1fbdb28b78e7d5a38d68fd4f833e0661f99b918`, branch `fix/ios-review-integration`,
target `feat/ios-client-20260911`. The findings are the
[full-component review](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#issuecomment-5665274482).
This is not a request to repeat the already closed PR40 storage correction.

Requirements: REQ-CLIENT-001, REQ-ID-005/008, REQ-MSG-002 and REQ-CALL-002/003.
[Voice v1](../../protocol/voice-v1.md), [call v2](../../protocol/call-v2.md),
[voice TURN v1](../../protocol/voice-turn-v1.md),
[RFC-0021](../../rfcs/0021-ios-client.md) and
[proposed ADR-0014](../../decisions/0014-ios-client.md) retain their contracts
and decision status. No server, shared core, Android, key protocol or deployment
code changes. Human risk/decision owner remains `martadvix-web`.

## Final contributor Mac result and integration

Yaroslav's [complete aab9e5d receipt](../../project/evidence/ios-client-20260913/mac-receipt-pr41-aab9e5d.md)
records successful package compilation, full package **293/0**, lazy-key **14/0**,
storage **25/0** and signed-simulator app **64/0**. It supersedes the pending
Mac gate below, not the historical failure record. The coordinator did not run
Swift/Xcode; these remain contributor-reported Mac results.

PR41 was integrated as `cb523306c186e91a6d65e4050bd0b65eb9c7ab77`, a merge commit
with tree equality to `aab9e5dee8fe75c5a3170faac5f12e80819cdb12`, and e642907 plus
aab9e5d preserved as ancestors. Five named CI checks passed on cb52330;
informational legacy remains failed. The receipt applies to the identical
source tree; recording it in docs does not require rerunning unchanged runtime,
tests or workflows. PR36 main merge and all permanent decision/device/live
gates remain separate. The [full cb52330 review](../../project/evidence/ios-client-20260913/pr36-review-cb52330.md)
subsequently identified unbound End/Reject and mute/speaker actions (C1), outside
the now-closed Answer correction. It remains a code gate before main recommendation.
Historical commands and unrun physical-device,
media-stop timing, real-container upgrade, power-loss and export checks below
retain their scope.

## Historical Mac receipt for e642907 and follow-up gate

Yaroslav supplied the full [Mac receipt](../../project/evidence/ios-client-20260913/mac-receipt-pr41-e642907.md)
for exact `e6429070772bed303db109fb42d2ce41064b888b`, run 2026-09-14
14:47–14:50Z on macOS 26.5.2 / Xcode 26.6 / Swift 6.3.3. These are
contributor-reported executions, not coordinator execution:

- App compilation and signed clean-simulator `ParanoIDTests`: **64 tests,
  0 failures**, including Keychain and OpeningRetryTests.
- Python gates and changed-Markdown lint: **PASS**.
- All three `swift test` commands: **exit 1, zero tests executed**. The package
  test target fails compilation at InterruptedOnboardingTests:39: the retained
  `NSDictionary` credential belongs to the region of `resumed`, which is sent
  into StateOwner while that credential remains locally used. The production
  openClient sending-result fix compiled, but source review missed this separate
  fixture ownership error. Package acceptance is **blocked**, not green.

The follow-up replaces retained credential object graphs with sorted JSON `Data`
(a Sendable value). Server fixture objects are decoded from those bytes and
full-credential equality assertions are preserved. No unchecked Sendable client
or actor-isolation waiver is introduced. The source regression was RED before
this correction and GREEN after; **the correction is not compiler-confirmed on
Linux**. The next exact SHA requires the same full Mac run, including both
filtered package commands and the whole signed-simulator app suite.

The optional review observations are dispositioned explicitly:

1. ATS wording now names the directly checked spellings and expressly excludes
   computed `type(of:)` metatypes, generic initialization and reflection. No
   universal metatype/alias coverage is claimed.
2. resumeOnboarding reads one core view and only prepares contact material when
   active enrollment lacks it. A complete checkpoint produces no candidate,
   so this path no longer relies on JSON byte equality to avoid repeat commits.
3. A stale Answer does not cancel another in-flight intent. This is retained
   deliberately: a stale action should not gain authority over a current intent.
4. The opening test still builds the full runtime and uses the internal factory
   seam, with no identity/server account; it is not resource-lifecycle coverage.
   Test-runtime disposal/DEBUG-only seam restructuring is deferred rather than
   bundled into this ownership fix.
5. start() retains its existing return type; its documentation now states that
   a returned old counter does not mean started. `current`/`isCurrent` decide.
6. Baseline RED counts below distinguish the original test version from the
   final source gate; the stale local-only proximity comment is corrected.

Follow-up Linux verification: onboarding source gate **3 PASS** (two expected
assertion failures against e642907 source in the independent baseline probe),
freeze/open **3 PASS**, call review **5 PASS**, pinned mutations **11 PASS**,
UI **20 PASS**, storage bootstrap **5 PASS**; docs consistency and the unchanged
six Rust ABI tests pass. Six changed Markdown documents pass lint; the original
receipt has a file-local MD010 exemption only to preserve its xcodebuild tab.
An independent fresh GPT-6-Astra context found no source-level blocker in the
Data ownership boundary or active/missing-contact guard. This repeats neither
the prior compiler overconfidence nor a Swift test success claim: **new-SHA
compilation and package/app runtime results are still pending on Mac**.

No new Mac result is implied by the e642907 receipt. No merge or decision
acceptance follows from this record.

## Corrections and regression mapping

- **F1:** `StateOwner.perform` synchronously notifies its installed terminal
  handler on storage freeze before returning, including when the operation
  swallowed the commit exception. The coordinator attaches before lanes start;
  it terminates call authority without waiting for a heartbeat or parked receive.
  Frozen owners cannot start/restart. `OwnerFreezeNotificationTests` covers
  notification ordering, swallowed errors, late attachment and ordinary errors.
- **F2:** Answer and microphone refusal carry call ID and generation to the
  controller's owner-side check. Consent for A cannot answer or reject B.
  `CallConsentRegressionTests` exercises the replacement-call boundary.
- **F3:** initial-open retry clears stale UI failure only after successful
  runtime construction. An existing runtime frozen by a failed commit cannot be
  replaced by Retry. `OpeningRetryTests` exercises actual AppModel start/retry
  with an injected failing bootstrap and a synthetic failing sink, no identity
  on any server. Late connection publications cannot overwrite the frozen UI.
- **F4:** valid retained schema-0 creation and active-registration-without-contact
  checkpoints finish through existing core commands before ProofFlow networking.
  Opening stays validation-only; invalid/missing state is not repaired and no
  identity is regenerated. `InterruptedOnboardingTests` reconstructs clients
  from saved intermediate wrappers and verifies identity/contact continuity.
- **F5:** terminal cleanup cancels the call's own request token synchronously;
  only its endpoint is disposed asynchronously. Old cancellation must neither
  cancel B nor deliver A's pending outcome/retry into B.
  `CallRelayCancellationTests` covers held requests and replacement ordering.
- **F6:** proximity excludes local or remote video; audio-only behavior remains.
- **F7:** production Swift session references are checked against a narrow
  allowlist with constructor/delegate structure and negative mutations, not
  four forbidden strings. This is a lexical regression guard, not a Swift
  semantic proof or a demonstrated production MITM fix.

`test_freeze_open_contract.py`, `test_interrupted_onboarding_contract.py`,
`test_call_review_regressions.py` and `test_pinned_session_contract.py` are
Linux source/mutation checks, **not execution of the Swift regressions**.

## Verification scope

The coordinator's Linux host has no Swift/Xcode executable. New Swift tests,
Apple framework type checking, Keychain, audio/media and simulator behavior are
**NOT RUN here**. Prior PR40 Mac receipts remain scoped to their exact runtime
source and do not verify these new changes. The initial two-test F1/F3 source
gate produced two assertion failures on the old code, then GREEN. That is a
historical run of the initial gate, not the final three-test suite: Yaroslav
reports four failures for the final gate against f1fbdb2 in the receipt above.
Linux verification on the original e642907 candidate (before this follow-up):

- Freeze/open contracts: **3 PASS**; call review contracts: **5 PASS**;
  interrupted onboarding: **2 PASS**; pinned-session mutations: **11 PASS**.
- Existing UI contracts: **20 PASS**; storage bootstrap: **5 PASS**.
- Bridge ABI: **6 PASS**; clippy (`-D warnings`) and the real locked
  `aarch64-apple-ios` cargo check: **PASS**. This is Rust type checking, not
  Swift linking. Lock gate: **123 registry + 2 path packages match**.
- Toolchain `--no-xcode`: **PASS** after installing missing Rust clippy/targets;
  Apple tools remain absent. WebRTC dependency suite: **11 PASS** on a synthetic
  offline archive, not a fresh binary download. Notices generation covers
  **91 crates + WebRTC**; notices tests: **30 PASS**.
- Scenario mapping: **94/94 labels**, not runtime calls. Docs consistency:
  **7 facts PASS**. Changed Markdown: **8 files, no lint issues**. Relative
  links in changed documents: **200 checked, no missing targets/anchors**.
- Tree-sitter is supplemental only: version 0.26 crashed, 0.25.2 ran but does not
  understand all Swift 6 `sending` forms. It flags the new sending-result types
  as well as existing sending/if-await syntax; no Swift syntax/compile PASS is
  claimed from that parser.

On the original e642907 source, independent fresh-context **GPT-6-Astra**
reviews reported no remaining
bounded F1–F7 source blockers after correction. The initial F1/F3 review found
that the injected bootstrap factory needed a `sending` result contract; a third
context added it in both factory types, with an extra RED/GREEN source test,
and the final independent review confirmed the correction. Another independent
context reviewed F4/F7 and the actual recursive production-source inventory.
The final exact SHA and review disposition are recorded in the follow-up PR.
Same-model blind spots remain; this is not an Opus review or human audit.

F1 ends controller authority and **initiates** media teardown synchronously on
the owner. Existing WebRTC/audio disposal is queued on its respective executor;
the fake media-port regression does not measure physical capture-stop latency.
The cancellation-after-claim regression drives final owner delivery directly,
not a real socket scheduling race. One non-immediate inferred `.shared` assignment
was intentionally identified as outside the F7 gate's documented data-flow
assurance. Apple runtime and new Swift test compilation remain the Mac gate.

## Mac procedure

Use a separate worktree at the exact PR head SHA provided in the handoff. Keep
existing phone state/keys untouched. Set up the already pinned core/WebRTC
binaries in that worktree using the normal
[build instructions](build-and-testflight.md); do not copy an unverified binary.
Generate the git-ignored notices before the Xcode build:

```sh
python3 clients/ios/notices.py --offline
python3 -B clients/ios/test_freeze_open_contract.py
python3 -B clients/ios/test_interrupted_onboarding_contract.py
python3 -B clients/ios/test_call_review_regressions.py
python3 -B clients/ios/test_pinned_session_contract.py
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

Then use the contributor's existing **signed simulator** destination, not a
physical phone and not a signing-disabled Keychain run:

```sh
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination "$PARANOID_IOS_SIMULATOR" \
  -derivedDataPath clients/ios/out/review-integration-signed \
  -only-testing:ParanoIDTests
```

This includes the app regression tests and existing Keychain tests. Report exact
commit, commands, exit codes and named failures/counts. Do not include secret
keys, sealed/plain snapshots, TURN credentials or provisioning credentials.
Do not claim a package test exercised AVFoundation/WebRTC on a physical device.
No archive, export, TestFlight or provisioning-settings change is requested.

## Rollout, rollback and remaining gates

This is a review branch, not a deployed build. No storage schema, sealed codec,
key attributes, TLS pin or wire version changes. Rollback is source reversal in
the candidate branch, not uninstall/data-clear/key deletion; doing that on a
real phone would destroy continuity and is not part of this task. Independent
source review and Mac execution precede contributor integration. Sergey retains
the decision to merge PR36 into main; ADR acceptance, device evidence, export
compliance, TestFlight and all live-server actions remain separate gates.
