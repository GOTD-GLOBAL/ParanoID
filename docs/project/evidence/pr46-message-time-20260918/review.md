---
status: draft
owner: clients
last_reviewed: 2026-09-18
---

# Independent PR46 integration review

Reviewer: Claude Opus 5, fresh read-only CLI context. Reviewed staged integration
of PR46 `7093845` with main `de43920`, including coordinator fixes. The first
review found false call-log timestamp documentation and stale no-message-time
statements; both were corrected. Its staging/test-status observations were made
during ongoing work and were not final verification claims.

The final independent report follows. Two non-blocking comment nits were then
corrected without changing runtime. Build/tests and exact artifact evidence are
recorded separately in [the integration record](../../../clients/pr46-integration.md).
This is advisory AI review, not human architecture approval or a device test.

## APPROVE

Read-only review, no edits/builds/network. Note the follow-up is **staged, not committed** — `HEAD` is still `7093845`, so everything below is `git diff --cached 7093845`.

### Previous findings — both fixed

- **RFC false call-log-timestamp claim:** `docs/rfcs/0023-message-time.md` Privacy now states the PR45 call log "stores outcomes, durations and message anchors, not wall-clock times… the call log is not evidence of an existing timestamp-storage boundary." Correct against `CallRecord.swift` / `CallLog.java` fields. The RFC also gained the call-preview clause (line 41) that matches the code.
- **Stale "core keeps no time for a message" comments:** corrected in `MessagePresentation.java:135`, `AppModel.swift:655`, `CallLog.swift:121`, `DialogPolicy.swift:4` (line-range ref replaced with `Entry`), `CallRecord.swift:50`. The three remaining hits ("the core keeps no **clock**", `SelfServiceClient.java:100`, `SelfServiceClient.swift:251`, `AppModel.swift:144`) are still true — the core takes `now_ms` and reads no clock. `CHANGELOG.md:65` sits inside the dated 2026-09-17 PR45 entry; leaving dated history intact is right.

### The two behaviours you flagged — no regressions found

- **Call-preview date suppression:** one predicate per platform drives both the subtitle and the stamp (`MainActivity.java:641-649` `callPreview`; `AppModel.swift:700` `preview(for:) != nil`, same function used at `Dialogs.swift:42-43`), so text and time cannot disagree. Contact rows pass `false` with `last=null`. When `dialog.last == nil` both platforms already returned "" earlier, so the extra branch is unreachable there. Behaviour matches RFC-0023 and REQ-CLIENT-004; the trade-off — a conversation whose newest event is a call shows no date at all — is the documented intent, not a defect.
- **Android pre-epoch clamp:** `now_ms` is `u64` in `self_service.rs:64,70` / `clean_service.rs:143,153`, so a negative JSON number would fail request deserialization and abort a send/receive. `Math.max(0,System.currentTimeMillis())` maps it to the documented "zero means unknown", identical to iOS's `UInt64(max(0,…))`. All three stamp sites are covered (send, sync, realtime) and `test_message_time.py` pins the count at 3.

### Staging / scope

Core runtime is byte-identical to `7093845`; `server/` and `deploy/` byte-identical to `de43920`; the `MainActivity` crash-report/`CrashLog.load` block is byte-identical to main (upstream preserved — only the row/time hunks are new). Smoke wiring is real in both paths (`clients/android/build.sh:50`, `.github/workflows/server.yml:118`, asserted by `scripts/test-ci-wiring.py:10-15`). The two new core regressions match what the RFC's Tests section claims. `docs/clients/pr46-integration.md` is honest about the un-run Swift case and the review-only APK.

### Non-blocking nits

1. `MessagePresentation.java:61-63` — two consecutive javadoc comments now sit on the 3-arg overload, and the 2-arg implementation (which holds the actual formatting rule) is left undocumented. Move the "What a conversation row says" doc back onto the 2-arg method.
2. `Dialogs.swift:93-94` and `AppModel.swift:694-696` still say the empty string means "a history that carries no time" / "written without a time". After this change, an empty stamp also means "the row previews a call". Same incompleteness the earlier sweep targeted, one level up.

### Gates I could not close (separate from the verdict)

- **Mac only:** `testCallPreviewDoesNotBorrowTheLastMessagesTime` in `MessageTimeTests.swift` is written but NOT RUN — no Swift/Xcode here; the PR's ParanoidKit 327/0 receipt predates it and does not cover the suppression fix. The changed `TextFlowUITests` simulator assertions are likewise unexecuted.
- **Device/runtime:** physical two-phone check, VoiceOver, signed iOS export/TestFlight, and any APK delivery — all untested. The versionCode26 artifact must not be published under that version.
- Historical `self_service` remains red at exactly the 14 known names; merge/deploy/publication and ADR acceptance stay out of scope.
