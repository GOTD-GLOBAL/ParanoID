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
source and do not verify these new changes. Initial F1/F3 source tests were RED
with two assertion failures on the old code, then GREEN after correction.
Final Linux verification on the candidate:

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

Independent fresh-context **GPT-6-Astra** source reviews found no remaining
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
