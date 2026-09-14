---
status: proposed
owner: ios
decision_owner: martadvix-web
last_reviewed: 2026-09-14
---

# C1: call-targeted controls — correction and Mac handoff

## Scope

Yaroslav requested this bounded correction after the
[cb52330 full review](https://github.com/GOTD-GLOBAL/ParanoID/pull/36#pullrequestreview-5200511065).
Base: `cb523306c186e91a6d65e4050bd0b65eb9c7ab77`; target branch:
`feat/ios-client-20260911`. No main merge, server, shared core, Android, schema,
pin, wire protocol or live action changes. REQ-CALL-002/003 and the existing
voice-v1/call-v2 owner/generation rules apply. RFC-0021 and ADR-0014 remain
proposed; this is a correction within their existing boundary, not acceptance.

## Implementation

AppModel captures the displayed call before scheduling End, Mute or Speaker.
Both call ID and generation cross CallCoordinator's final owner hop. Controller
entry points `end`, `reject`, `hangup`, `mute` and `speaker` check both fields
against the current live call **before mutation or signaling**. No live call,
wrong ID or wrong generation means no action. End chooses reject/cancel/hangup
only after that check, preserving existing same-call behavior.

Synchronous owner-local legacy overloads remain for controller-internal paths,
host probes and existing tests, just as with Answer. Production coordinator
controls no longer invoke them across an executor hop; the new source gate
checks that wiring. This is not a redesign of signaling or CallGeneration.

## Behavioral regression and honest RED

`CallControlDispatchTests` uses real StateOwner serialization and real
CallControllers whose owner preconditions are active. Signaling/media ports
are fakes; no socket, Keychain, actual media engine or server is used.

- Both peers obtain authenticated readiness slots while the receiver is idle.
  A's offer rings; B's valid offer is held.
- A's user action is queued but held **before** the final owner dispatch, leaving
  the owner free to process remote end A and valid offer B.
- Release the old action; B must stay incoming with identical presentation,
  signal count, close/answer counts and media settings.
- Separate delayed cases cover End, Reject, Hangup, Mute and Speaker; additional
  cases require both binding fields and preserve valid cancel/hangup/media routes.
- The UI/Coordinator forwarding is additionally covered by source assertions;
  the package regression does not instantiate the full production AppModel.

To demonstrate **behavioral RED**, not a missing-overload compilation error,
`test_call_control_baseline.py` creates a disposable worktree at exact cb52330,
copies only the new test, and enables its test-only `C1_LEGACY_BASELINE` adapters.
Those adapters map new signatures to the **old shipped unbound actions**, with
no ID/generation validation. Production baseline sources and the assertions are
unchanged. The same test therefore observes wrong-call behavior. The script
accepts only a nonzero Swift exit with actually executed failed tests and the
stale-control assertion; setup/compilation failure is not accepted as RED.

The script links existing pinned framework directories read-only, uses its own
scratch directory, and removes only its own temporary worktree in `finally`.
It does not modify the active checkout or installed application state. Its
Python classifier tests use explicit synthetic log fixtures, not Apple evidence.

## Verification state

Coordinator Linux source gate was RED on old code (13 assertion failures,
zero test errors after diagnostic cleanup), then GREEN after correction.
Source/wiring and log-classifier tests are executable here. New Swift test
compilation, runtime GREEN and baseline behavioral RED are **NOT RUN here**:
Swift/Xcode are unavailable. Do not close C1 from lexical tests alone.
Prior aab9e5d/cb52330 receipts do not cover the new controls/tests.

Final coordinator checks: C1 source **4 PASS**, baseline-classifier unit tests
**4 PASS**, UI **20 PASS**, prior call **5 PASS**, freeze/open **3 PASS**,
onboarding **3 PASS**, storage bootstrap **5 PASS**, pinned mutations **11 PASS**.
Docs consistency, unchanged Rust bridge **6 ABI tests**, clippy and iOS-target
cargo check pass. WebRTC verification used **11 synthetic offline tests**, not
fresh binary verification; notices tests **30 PASS**. Changed Markdown **5 files**
passes lint and relative links pass. Tree-sitter reports no additional parser
errors over baseline, but retains known Swift6 grammar limitations and is not
a compiler. The Mac-only baseline script was attempted here and explicitly
returned NOT RUN (exit 1); its classifier tests are not behavioral RED.

Independent source reviews inspected the implementation and the test/harness.
One found Boolean-parameter shadowing in the new speaker wrapper and baseline
adapter; both now use explicit `self.speaker(speaker)` and have a source
regression. A fresh final review confirmed that correction and found no remaining
source blocker. All reviewers are GPT-6-Astra in separate contexts, not a human
or Fable audit. Final classifier hardening also rejects crashes and unexpected
errors; its four unit tests pass. No reviewer executed the new Swift suite.

## Mac commands

Use the exact new SHA supplied in the PR, a separate worktree and the normal
pinned framework setup in `clients/ios/ParanoidKit/Binaries`. Keep existing
phone keys/data untouched. From the repository root:

```sh
python3 -B clients/ios/test_call_control_targeting.py
python3 -B clients/ios/test_call_control_baseline_harness.py
python3 -B clients/ios/test_call_control_baseline.py
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter CallControlDispatchTests
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter LazySnapshotKeyTests
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm --filter SnapshotStoreTests
swift test --package-path clients/ios/ParanoidKit \
  --scratch-path clients/ios/out/spm
python3 clients/ios/notices.py --offline
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination "$PARANOID_IOS_SIMULATOR" \
  -derivedDataPath clients/ios/out/c1-signed \
  -only-testing:ParanoIDTests
```

Also rerun the existing UI/storage/onboarding/freeze/call/pinned source gates and
docs consistency from the prior handoff. For the baseline script, preserve the
printed **Swift exit and assertion failures**, separately from the script's
exit zero meaning expected RED. Send exact SHA, commands, exits and actual test
counts/diagnostics, without credentials or stored state contents. Missing build
inputs or compiler failure is a blocker, not a passed negative test.

The same signed simulator scope as the prior receipt is sufficient for this
handoff; no physical phone, archive/export or hosted probe is requested.

## Integration and rollback

Keep the correction draft pending CI, independent review and exact-SHA Mac
GREEN plus baseline behavioral RED. PR42 is separate docs-only reconciliation;
it does not implement C1. Merge into the feature branch remains Yaroslav's
merge-commit/no-squash step after verification. Sergey retains main/ADR/live
decisions. No rollback migration is needed: source reversal only, never
uninstall/reset/key deletion. Physical media timing and other device gaps from
the previous review stay separate.
