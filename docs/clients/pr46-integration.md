---
status: draft
owner: clients
last_reviewed: 2026-09-18
---

# PR46 message-time integration

Sergey requested finishing PR46 in project Telegram on 2026-09-18. This record
covers source integration and local validation, not a merge, device update or
hosted operation.

## Inputs, decisions and preserved invariants

- PR46 input: `70938451fdf2f8709e03cc0cdd695476d40f46e4`.
- Main after PR45: `de439206172e36dcb6da0c55e6a886900d53f309`.
- Separate `fix/pr46-integration` worktree; main worktree left untouched.
- REQ-CLIENT-004: only real device-local times, never invented historical dates.
- REQ-MSG-002/003/005: unchanged signed E2EE channel, server acceptance versus
  recipient delivery, replay protection and whole-candidate commit/rollback.
- RFC-0023: timestamps stay inside local sealed history, never wire bodies or
  receipt targets; they do not order, authenticate or admit events.
- ADR-0001/0003: canonical evidence and independent review, not a human audit.
- Owner-selected local-clock semantics and coordinated alpha updates are recorded
  in [RFC-0023](../rfcs/0023-message-time.md#owner-direction-and-remaining-decision-boundary).
  This does not mark the RFC/any ADR accepted or implement the separate iOS
  metadata-backup and scalable-history follow-ups.

The two textual merge conflicts only joined dated sections of CHANGELOG and
current-state. Android runtime merged automatically. Main's call-owner,
crash-report and split-R8/DEX fixes remain. Server/deploy are byte-identical to
main. Core runtime source is byte-identical to PR46's original head. The final
iOS follow-up suppresses a message timestamp when the row previews an untimed
call. Its new XCTest needed a fresh Mac run, which is recorded below.

## Added verification

The Android message-time smoke had not been wired into CI or APK build. A wiring
regression first failed because that command was absent; adding the fixed command
to both paths made it pass. No untrusted event text is interpolated into shell.

Two additional real-core regressions pass:

- server acceptance, authenticated receipt, reopen and exact duplicate replay
  preserve the original timestamp; a receipt creates no history row;
- a backwards local clock neither rejects nor reorders text; relay sequence and
  cursor remain authoritative for processing order.

These characterize existing PR46 behavior; no core runtime change was needed.

Review corrections remove false claims that call rows already store timestamps
and stale claims that messages have none. Both UIs now suppress the preceding
message's date when the preview is an untimed call. Android's three clock reads
clamp negative epoch values to unknown, matching iOS, rather than passing a
negative JSON number to the core's unsigned request field. The JVM formatter
regression and source-wiring regression were RED before their respective fixes
and GREEN afterwards. The Swift regression was added but NOT RUN here.

## Executed on Linux

- Rust 1.98.1 core fmt and all-target clippy with warnings denied: PASS.
- Supported release integration targets: clean_first_contact 22, key_vectors 1,
  realtime_signing 6, registration 7, state 3, sync_recovery 6, voice_calls 14:
  all PASS. Empty library/doc targets are not additional coverage.
- Historical self_service: 10 PASS, exactly 14 known FAIL, raw cargo exit 101.
  Actual failing names match `scripts/ci-legacy-client-tests.txt`; the historical
  CI job remains red, not masked or reported as fixed.
- Full `bash clients/android/build.sh`: PASS, including Android35 SDK compile,
  controller/owner/log/crash checks, real JNI/storage/QR, message time and other
  host tests, split R8/D8, package, signer and updater checks.
- iOS source gates: UI 22, storage 5, freeze 3, interrupted onboarding 3,
  call review 5, targeting 4, baseline harness 4, pinned session 11: PASS.
  Docs consistency PASS; call parity 105/105 is label coverage, not Swift runtime.
- CI wiring 6 and iOS boundary applicability 5: PASS.
- Rust iOS bridge all-target clippy, host ABI test and iOS-device triple
  type-check: PASS after installing the missing local target. This is not a
  Swift/Xcode build.

The original PR description reports ParanoidKit 327/0 and an unsigned simulator
build on the contributor's Mac. That receipt does not verify
the new call-preview suppression fix. It is not fresh coordinator Swift
execution. No Swift/Xcode is available
on this Linux host. The changed simulator text-flow assertions were not executed
here; physical phones, VoiceOver, signed iOS export and TestFlight are NOT RUN.

Update recorded 2026-09-23: the final-head receipt now exists.
[Yaroslav's cc5b0c7 Mac receipt](../project/evidence/ios-client-20260918/mac-receipt-pr46-cc5b0c7.md),
relayed on PR46 before its merge, reports `MessageTimeTests` 7/0 including
`testCallPreviewDoesNotBorrowTheLastMessagesTime`, ParanoidKit 328/0, an unsigned
simulator build, and the `test_sim_text.py` text scenario passing with 15
screenshots. It covers the call-preview fix at unit level only. The text
scenario has no call, so the suppression was not observed in the live UI.
Physical phones, spoken VoiceOver, a signed build, export/TestFlight,
APK/Android SDK checks and the production server remain NOT RUN in that receipt.
It is contributor execution, not a coordinator Mac run.

## Local artifact, not a release

- Path: `clients/android/out/paranoid-text.apk` in the integration worktree.
- Package: `global.paranoid.messenger`, ARM64, API26+.
- Version inherited from main: versionCode26 / `0.0.26-update`.
- Size: 16443022 bytes.
- SHA256: `76b2ba36ba801dd7c209599918f28fcb58281d9068565aeb65fc3ff87955d5b1`.
- Retained signer SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- APK signature v2/v3 verified, one signer. Packaged DEX and native core bytes
  equal the fresh build outputs.

This APK is review-only: it differs from published v26 and must not be delivered
or published under that version. A release requires a new version and explicit
scope. The new client reads untimed old entries without inventing dates; an old
client rejects a snapshot containing `local_ms`. Never clear data/keys or restore
stale history to hide that incompatibility. No hosted DB/server change is needed
for this local-only field, and none occurred.

## Review and remaining gates

Fresh-context Claude Opus 5 [final review](../project/evidence/pr46-message-time-20260918/review.md)
returned **APPROVE**, with no blocking source findings after the privacy/comment
corrections and the call-preview/negative-clock fixes. Two documentation nits
were corrected afterwards without runtime changes. The first review's mid-work
index and test-status observations were not used as final evidence.

Markdownlint-cli2 0.18.1 and `git diff --check` pass. New private provenance links
are excluded individually from unauthenticated lychee and were retrieved through
the authenticated GitHub API; no broad link bypass is added. GitHub returned no
rulesets and no main branch protection, so green checks are not represented as
an enforced repository approval rule.

Hosted CI is recorded on PR46 for the final head. Keep the PR draft until the
new Swift `MessageTimeTests` case, full package and simulator build/text flow have
a final-head Mac receipt. That receipt arrived and PR46 merged as `c9ca067`,
whose iOS and core trees equal `cc5b0c7` (see above). Relative day labels can
remain stale while a screen is idle across midnight until it redraws; no
periodic date-refresh capability is claimed here. Beyond that merge, no
deployment/publication or permanent architecture acceptance is implied.
