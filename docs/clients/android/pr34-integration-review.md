---
status: draft
owner: android-client
last_reviewed: 2026-09-17
---

# PR34 integration review and corrections

Sergey requested completion of PR34 and a merge recommendation in Telegram.
He then explicitly authorized completing and merging PR34 after checks. This
does not authorize another v26 publication, server deployment or phone
installation. No permalink is invented.

Reviewed PR head: `ce902258a564987adeebe922cdce474359396b91`.
Integration base: `8106ae712789af43176970167f3962d590aabea0`.
The candidate worktree is `fix/pr34-integration-review`.
REQ-CALL-003/004/005, REQ-CLIENT-003 and REQ-SEC-001 apply; RFC-0013,
RFC-0020 and proposed voice/Android ADR status remain unchanged.

## Findings and local corrections

- **Documentation corruption:** the PR contained a literal `OUTPUT TRUNCATED`
  placeholder replacing historical voice evidence in `current-state.md`.
  Restore the complete current-main document and add only the dated PR34 note.
  Resolve both doc conflicts without deleting later iOS/TLS evidence. No runtime
  conflict resolution is needed.
- **Cold push owner:** the same JVM harness constructs the controller on a foreign
  thread then ticks on the designated main thread. Main fails with
  `IllegalStateException: call owner thread`; PR34 passes. The existing expanded
  controller smoke also rejects a stranger thread and null owner. Preserve the
  explicit `Looper.getMainLooper().getThread()` assignment.
- **Native exit privacy/format:** Android API31+ native traces are protobuf
  tombstones, not UTF-8. See [Android API documentation](https://developer.android.com/reference/android/app/ApplicationExitInfo#getTraceInputStream()).
  Remove raw trace and free-form description access, retaining reason/status/
  importance/timestamp only. A synthetic JVM adapter reproduced a private marker
  entering the original report; after correction neither raw API is accessed.
  This is not a reproduction of a real user's secret exposure.
- **Startup and acknowledgement:** collect and acknowledge off main on a separate
  one-worker/eight-queued-operation executor. Deliver through the UI executor;
  the Activity rejects callbacks when finishing/destroyed. Reading does not
  acknowledge. Copy/Close acknowledges the exact report and deletes a Java file
  only if it still matches that report. Examine at most eight recent system
  records for the latest eligible exit. This is best-effort diagnostics, not a
  durable crash archive: Android can overwrite its own records. Queue saturation
  skips diagnostics/ack, not messaging; an unacknowledged report can reappear.
- **DEX gate:** descriptor strings did not prove class definitions. Parse actual
  `class_defs`, require the merged definitions to equal both inputs' union,
  reject a descriptor-only fake, and detect a removed definition. Check both
  input DEX directories for `classes2.dex` before merging, as well as the output.
  The single-DEX constraint is the current packager's, not an API26 limitation.
  Correct the claim that `--classpath` acts as a keep root: explicit keep and
  consumer rules retain Firebase members.
- **Clean dependency fetch:** Google Maven returns HTTP404 for pinned
  `error_prone_annotations-2.26.0.jar` and `listenablefuture-1.0.jar`.
  Maven Central supplies exactly the pinned lengths and SHA256s. Change only
  these two repository selectors; do not change artifact versions or hashes.

## Privacy and lifecycle limits

The old Java exception report remains app-private, unredacted baseline behavior;
this correction does not certify that Java exception text contains no secrets.
The UI previews it, warns before copying and performs no automatic upload.
The existing native seen marker contains timestamp/PID, not key material.
No crash payload is added to server requests, snapshots, call signaling or logs.
No permissions, media consent, timeout, TLS, identity, history, offline enqueue
or cryptographic behavior changes. Do not confuse these startup exit records
with the separate in-call diagnostic-journal candidate.

## Executed checks

- Foreign-thread construction differential: main RED, PR34 GREEN.
- Current controller consent/replay/heartbeat/lifecycle smoke: PASS.
- Synthetic crash adapter: raw marker RED before correction; structured-only,
  unacknowledged reread, explicit ack and executor delivery/API29 gate PASS after.
  This uses fake Android API objects, not a device or actual ANR.
- Fresh Android35 resource generation and all application Java compilation: PASS.
- Actual Firebase-only R8, untouched app/WebRTC/ZXing D8 and final DEX merge: PASS.
  Current output has 1203 app/R/WebRTC/ZXing and 855 Firebase definitions,
  2058 merged. These counts are evidence for this candidate, not fixed limits.
- DEX tests: descriptor-only/removed-definition and input guard regressions,
  manifest/app/registrar definition retention: PASS after corrections.
- Four Firebase tests including native-payload/tamper rejection: PASS.
  Empty-cache download and verification of all 61 artifacts: PASS.
- Android UI and update wiring checks: PASS. Eight installer worker host-adapter
  scenarios and three update-artifact checks: PASS.
- Canonical release-profile core gate: 17 clean-first-contact, 6 realtime
  signing and 14 voice tests PASS, including the real cryptographic stress test.
- Host JNI core built locally. Complete updater pinned-TLS fixture: PASS with
  an explicitly supplied historical APK from the v26 worktree. Earlier attempts
  correctly failed for absent JNI then absent default APK. The final fixture
  does not prove installation or correspondence of a newly signed candidate.
- Existing PR CI's legacy job genuinely failed: 10 passed, 14 failed, raw exit101.
  Its Rust source is unchanged by PR34; do not report that job green or disable it.

## Remaining gates

Independent final correction review and fresh CI must refer to the new candidate,
not the original PR head. The current environment lacks signing variables, so
no new full canonical signed-APK build is claimed. Historical v26 artifact review
remains historical evidence. Phone cold FCM, native crash presentation, Activity
recreation, WebRTC JNI execution and install acceptance are not newly run here.

Merging source does not republish v26. A subsequent release must use a new
monotonic versionCode and retain signer/data. PR45 must retain these owner/split
build fixes and reconcile the duplicated dependency-source correction.
