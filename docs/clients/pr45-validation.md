---
status: draft
owner: clients
last_reviewed: 2026-09-17
---

# PR45 coordinator validation and fixes

Base candidate: `ee9d09632fcb8e3587e33de72387b0eebc955b85`, PR45.
Yaroslav authorized local sequential checks and fixes in Telegram. No merge,
feed publication, hosted operation or ADR acceptance was authorized.

## Confirmed defects and corrections

- Android SDK compilation failed on checked `JSONException` in `TextEngine`
  and `MessagePresentation`. Host Maven `org.json` uses an unchecked exception
  and did not catch this. Handle the platform exception and add
  `test_sdk_compile.py`: fresh resources and all application Java sources are
  compiled against Android35, without the host JSON JAR. The test failed before
  the fixes and passes afterwards, explicitly checking `MainActivity`,
  `TextEngine`, `VoiceCallService` and `CallLog`. It now runs in `build.sh`.
- A clean dependency download returned HTTP404 for `error_prone_annotations`
  and `listenablefuture` at Google Maven (pre-existing, not introduced by PR45).
  Maven Central returned the exact pinned sizes and SHA256 digests. Change only
  their repository selector; both regression tests failed before the fix, and
  all five dependency tests pass with all 61 real archives verified.
- The missed-call notice checked foreground state on the worker before posting
  to the UI queue. Recheck inside the UI callback so opening a chat cannot clear
  the notice just before it is posted again. Source regression passes; a real
  Android lifecycle race is not claimed as executed.
- A call-log repaint replaced the previous connection/error status with a
  hard-coded ready sentence. Preserve the worker's last published status.
  An unavailable history anchor is distinct from an observed empty history:
  the existing unknown-anchor ordering places the former at the end. This
  fallback is permanent for that row and cannot reconstruct its original place
  after future messages; no timestamp or ordering fact is invented.
- iOS `ReceiptMark` hid its entire accessibility element, including labels
  supplied by the message/list callers. Expose one labeled element and hide only
  the decorative hint-card mark. Source regression failed before the fix and
  passes after it. A new Mac compile and VoiceOver check are still needed.
- RFC-0022 incorrectly said an old receiver refusing a message produces two
  marks on the sender. No delivery receipt means server acceptance only. Fix
  that wording and the remaining "only ceiling" wording without changing quotas
  or accepting any decision.

## Executed on the coordinator's Linux host

- Rust 1.98.1 `fmt --check`, `clippy --locked --all-targets -- -D warnings`: PASS.
- Debug target suites: clean_first_contact 18, sync_recovery 6, state 3,
  realtime_signing 6, voice_calls 14, registration 7, key_vectors 1: all PASS.
  The actual long cryptographic voice stress case completed, not skipped.
- Android controller, call-log and message-presentation host smokes: PASS.
- Android UI source contracts after fixes: 11 PASS.
- All application Java sources compiled against the real Android35 SDK: PASS.
- iOS UI source contracts after fixes: 21 PASS; docs consistency, call-control
  targeting (4), storage bootstrap (5): PASS. Parity finds 105/105 scenario
  labels; it does not execute the Swift scenarios on Linux.
- Final `bash clients/android/build.sh`: PASS (exit 0), including the release
  native gates, JNI/host checks, fresh Java/R8 packaging, APK checks and update
  TLS fixtures. Existing-signer `apksigner` verification passes v2/v3 with one
  signer; `aapt` confirms package `global.paranoid.messenger`, versionCode22,
  API26+, ARM64. All four requested Java classes have fresh class files and
  descriptors in the packaged DEX; packaged Rust library bytes match this build.
- APK SHA256:
  `6f5b94f94701c6dd6539fa6e2b37f273a2aa8944be0c59fbd61e54056bd91bb6`.
  Size: 16426638 bytes. Signer SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- Markdown with CI's exact `markdownlint-cli2@0.18.1`: PASS on the final
  documentation tree (187 files). Unpinned 0.23.2 reports MD060 errors in two unchanged
  historical documents; no blanket rule weakening or unrelated rewrite.

## Independent review disposition

Claude Opus 5 performed read-only source review; no human approval is implied.
The coordinator independently reproduced SDK failures and inspected findings.
The accessibility, notification race, Android status and unavailable-anchor
findings are corrected above. The first reviewer process exhausted its turn
budget and its attempted resume failed; the fresh review completed successfully.
A subsequent bounded Opus 5 review of the final fixes found **no new blockers**.
It confirmed the source corrections, not runtime Mac/device behavior or an
independent rerun of the coordinator's test results.

The proposed iOS pre-load incoming-call trigger cited CallKit/VoIP, which this
client does not implement: that trigger was not reproduced. This did **not**
resolve the underlying nil-anchor ambiguity. Yaroslav correctly returned that
cross-platform inconsistency; the subsequent iOS follow-up below closes it. The claimed
unlimited single-peer flood also omitted the retained 1000-event replay budget;
it is not established as described. Aggregate snapshot exhaustion remains a
real documented limitation, not authority to change quotas or evict history.

Local call rows classify a never-media-connected incoming hangup as missed,
including cancellation during setup; they are not a shared call-detail record.
A future distinction between local cancellation and remote hangup requires an
explicit UI semantics change and matching platform tests. `forget` is not wired
to a new delete-account operation; this PR adds no such operation. Exceptions
from existing UI observer callbacks are not demonstrated normal call paths.

## Evidence boundaries and next gates

The APK is a local review artifact retaining the candidate's versionCode22 and
signer, not a newly numbered release or authorized update. No automatic phone
installation or feed publication follows.

Yaroslav's Mac receipt (ParanoidKit 318/0 and unsigned simulator build with icon)
is contributor evidence for the pre-fix iOS sources, not a coordinator run or
proof of the modified accessibility view. The Mac owner must recheck that view.
Physical-phone calls, UI call rows, missed-notification runtime, hosted server,
TestFlight, signing/export of iOS and permanent decision acceptance are NOT RUN.
The existing attached emulator was inventoried only; no retained app data was
read, reset or overwritten.

## Contributor Mac receipt and iOS anchor follow-up

Source: Yaroslav, project Telegram thread, 2026-09-17; reported execution, not
coordinator-run Mac tests. At `2ee749d`: core fmt/clippy and all 55 selected
tests pass; self_service remains 10 pass/14 known legacy failures. ParanoidKit
318/0 and unsigned simulator build pass on the corrected accessibility source.
iOS UI contracts 21, targeting 4, storage 5, docs consistency and 105/105 parity
labels pass; Android host smokes and UI contracts 11 pass.

At `ed4e2f8`, Yaroslav reports `test_sim_text.py --scenario text` PASS on
iPhone 17 Pro simulator/iOS 26.5, local stand using server binary `a4a65d12…`
(abbreviated identity supplied; full binary provenance not independently
verified). The simulator test now asserts accessibility **words**, no early
Delivered state before the peer cycle and no duplicate bubble/status after
a double tap: 15 screenshots, 6 stored envelopes, 0 plaintext rows in the
cluster, peer history 3 messages. This closes the reported simulator
text-flow accessibility-label gate, not physical VoiceOver speech, call rows
or cross-device calls. The macOS server O_TMPFILE build blocker is reported
as pre-existing; no server fix or current-server runtime claim follows.

The follow-up based on `ed4e2f8` uses `CallLog.anchor(messages:)`: unavailable
or frozen history yields the same `unavailable` sentinel as Android; an
observed empty array yields nil; available history yields its last ID. Three
new XCTest cases cover sentinel persistence/order, observed-empty placement
and latest-message selection. A source-wiring regression was RED before the
fix; afterwards all five Linux source gates pass (UI 22, targeting 4, storage 5,
parity labels 105/105, docs consistency), Markdown has zero errors. The temporary
ad-hoc verification script passed and was removed. Swift compilation/execution
of these **new** tests remains the Mac owner
next gate; prior 318/0 is not evidence for them. Existing nil-anchor rows are
not rewritten because their original availability cannot be recovered.

Both local names and call-log UserDefaults backup exposure are now explicit
in client docs, source comments and RFC-0022 question 4 for the owner. No
file-store migration, physical-device install, feed, merge or ADR acceptance.
