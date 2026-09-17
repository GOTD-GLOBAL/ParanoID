---
status: draft
owner: clients
last_reviewed: 2026-09-17
---

# PR45 integration with current main

Sergey requested finishing PR45 against the latest main in project Telegram on
2026-09-17. This is source integration and local validation, not permission to
publish an APK, install on phones, deploy, merge main or accept RFC-0022.

## Inputs and preserved boundaries

- PR45: `ee8d043aeaf12e256aa6cbaaeb5405f27cd2454d`.
- Main after PR34/35: `6b428c8`.
- Separate worktree/branch; no edits to the main worktree or PR46.
- REQ-MSG-003: genuine device delivery, never read receipts.
- REQ-MSG-002/005 and first-contact-v1: unchanged signed E2EE channels, immutable
  pins, transactional state, replay/commitment/outbox and snapshot budgets.
- REQ-CALL-002–005: unchanged media consent, transient wire controls and main
  call-owner thread. Local call rows are not core/server messages.
- REQ-SEC-001 and RFC-0022: local metadata remains outside the encrypted snapshot;
  iOS OS-backup exposure and downgrade/mixed-pair risks remain proposed owner
  decisions, not silently accepted by source integration.
- ADR-0001/0003: canonical evidence and independent AI review, not a human audit.

Four textual conflicts were resolved: retain both dated documentation sections,
both call-log and crash-exit build gates, and combine TextEngine's terminal
callback with the explicit main-looper owner. Main's structured off-UI crash
report, acknowledgement, split Firebase-only R8, complete input DEX retention,
Android version and PR35 maintenance gates are preserved. Server/deploy sources
are identical to main; iOS/core sources and tests are identical to `ee8d043`.

The iOS-only boundary is applicable to `feat/ios-*` PR branches; within them it
still rejects mixed-component changes and fails on missing base. The inherited
no-iOS-diff shortcut remains. Cross-client PR45 instead runs affected component
checks. A source-contract test now checks the workflow condition in addition to
executing the real shell body in disposable repositories. It fails against main's
old unconditional PR condition. This is not a security sandbox or a claim that
GitHub's expression evaluator ran locally. Android call-log, presentation, UI and
crash-exit checks now run in CI; their wiring regression was RED before addition
and GREEN afterwards. All commands are fixed; no PR text enters shell source.

## Executed coordinator checks

- Core Rust 1.98.1 fmt and clippy all-targets with warnings denied: PASS.
- Release integration suites: clean_first_contact 18, key_vectors 1,
  realtime_signing 6, registration 7, state 3, sync_recovery 6, voice_calls 14:
  all PASS, including real long voice crypto stress. Library/doc targets have
  zero cases, not extra coverage.
- Full historical self_service: 10 PASS, 14 FAIL, raw cargo exit 101. Compared
  actual failing names with `scripts/ci-legacy-client-tests.txt`: exact match.
  The historical CI job remains red; failures were not masked or removed.
- Full `bash clients/android/build.sh`: PASS from this merged source, including
  fresh Android35 SDK compilation, call controller/owner/call-log host checks,
  JNI/storage/QR, split R8/D8, package/signer, update and pinned-TLS fixtures.
- SDK compiles every application Java source. Actual packaged DEX definitions
  include MainActivity, TextEngine, VoiceCallService, CallLog and CrashLog;
  packaged DEX and Rust native library match this build's output bytes.
- Android UI contracts: 11 PASS. Structured crash-exit JVM adapter: PASS.
- iOS source checks: UI 22, targeting 4, storage 5, freeze 3, interrupted
  onboarding 3, call-review 5, pinned session 11: PASS. Docs consistency PASS.
  Parity 105/105 is label coverage, not Swift execution.
- CI wiring 5 and iOS boundary scope 5: PASS. Markdown with CI-pinned
  markdownlint-cli2 0.18.1: PASS, 195 files including this record.
- `git diff --check`: PASS.

The [Mac receipt](pr45-validation.md#anchor-fix-mac-gate-closed-on-ee8d043)
records Yaroslav's CallLogTests 16/0, ParanoidKit 321/0 and unsigned simulator
build. Unchanged iOS/core source identity preserves its scope; it is not a fresh
coordinator Mac run or physical VoiceOver evidence.

## Local artifact, explicitly not a release

The integrated manifest inherits versionCode26 / `0.0.26-update` from main. This
APK has different bytes from the already published v26 and must **not** be
published or delivered as v26. A device release needs a separately selected newer
version, reviewed build, compatibility disposition and explicit publication scope.

- Package: `global.paranoid.messenger`, ARM64, API26+.
- Local APK size: 16443022 bytes.
- SHA256: `212bca7380fe3b446d27bc7abe8719d9e16781059ca4ff490965495f055e0ef1`.
- Retained signer SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- apksigner: one signer, v2/v3 verified.

No migration, phone action, feed update or hosted operation occurred. After a
candidate exceeds 200 entries, reverting to the old client can freeze access to
its retained state. Do not use source reversion as an automatic device rollback;
never clear data/keys to hide incompatibility. Both endpoints need coordinated
updates under the RFC-0022 disposition. PR46 stays a separate dependent review.

## Independent review

Fresh Claude Opus 5 read-only review found no integration code blocker and
confirmed preservation against both parents. It requested explicit artifact
version boundaries, final-tree verification and current documentation; those are
addressed above. Its remark that the anchor Mac tests were unrun was stale: the
linked contributor receipt closes that compilation gate, not physical testing.
Final fresh-context staged-tree follow-up by Claude Opus 5 returned **APPROVE**,
with no blocking findings, after checking both parent diffs and final gates.
The coordinator checked its status-field threading suggestion against
`RealtimeLoop.publish`: callbacks are queued on `owner`, supplied as TextEngine's
worker; no new volatile-field patch was justified by that suggestion.
Hosted CI is reported separately in the PR, not inferred from this review.
The exact private Mac-receipt URL is excluded from unauthenticated lychee, like
other private provenance links, and was read back with the authenticated GitHub
API; this adds no broad link-check bypass.

## Remaining owner/runtime gates

RFC-0022 remains proposed: downgrade/mixed-pair consequences and iOS local names/
call-log backup exposure still need explicit owner disposition. The retained
1000-commitment and 8 MiB budgets are not removed; archival/eviction is not added.
No main merge, architecture acceptance, device UI/missed-notification test,
physical VoiceOver, signed iOS export or production security claim follows.
