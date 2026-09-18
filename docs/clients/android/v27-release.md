---
status: draft
owner: android-client
last_reviewed: 2026-09-18
---

# Android v27 publication — 2026-09-18

## Authority and source

Sergey explicitly requested merging PR48 and publishing a new Android APK so he
can update in-app. PR48 merged as `408911f32833b2e3e62411bafff0adcdcfe90daf`.
Release source `abc998fb379fe78a99dbe7ce8a96d7f3f9440369` on `release/android-v27`
adds only version metadata and matching assertions to that main. Runtime and
shared core retain all merged PR45/46/48 changes; this is not the old v26 core
with a new Java shell. Packaging/source provenance is retained in PR49.

REQ-CLIENT-003, REQ-ID-008, REQ-MSG-004 and REQ-SEC-001; RFC-0013 and draft
ADR-0008 keep the existing distribution boundary. No permanent ADR acceptance.

## Artifact and checks

- Package `global.paranoid.messenger`, version27 / `0.0.27-timeout`.
- ARM64, minSDK26, targetSDK35; one retained signer.
- APK SHA256:
  `a4d2de9539e7c66ce23ee2c852c725c9cb3473b61bea6cee0b59b8b3b8beaafa`.
- Size: 16,443,022 bytes, within the original updater size ceiling.
- Retained signer SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- Full canonical `clients/android/build.sh` passed: native tests/build, JNI,
  SDK35, UI/calls/time, real pinned TLS, update integrity/policy negatives,
  split-DEX checks, signing and alignment.
- Version assertions were updated for the owner-requested release, not weakened.
  The v27 APK test first rejected a v26 artifact. Old v26 UI/wiring assertions
  also failed on the new manifest before being updated to the intended version.
- The first background invocation lacked SDK environment and stopped before
  compilation. The wrapper then supplied the already installed SDK explicitly.
- Independent fresh read-only review: **APPROVE**, no blockers, actual
  `claude-opus-5` with auxiliary Haiku usage. Covers source increment, artifact
  integrity and the bounded publisher; not a human audit or phone acceptance.
- After committing the source, a clean-worktree canonical rebuild passed again.
  All 101 ZIP payload entries matched the reviewed APK exactly, including DEX,
  native core and manifest. Whole APK hashes differ across rebuilds; the reviewed
  snapshot above, not the later container, was published. No byte-for-byte
  whole-APK reproducibility claim is made.

## Actual publication and external verification

The old live feed was version26. Before replacement, its digest-named APK,
ownership/modes, hash, disk headroom and enabled Python assertions were checked.
The bounded publisher was adapted from the prior v26 publisher. Four local
fixtures passed: successful publication, changed feed, corrupt APK and symlinked
APK. Failures left the prior feed untouched.

APK bytes were copied/fsynced first; metadata was atomically switched last.
`updates/android-v26-before27.json` preserves the previous PUBLIC feed, and its
APK remains. No database/config/TLS/firewall or service action was performed.
The source and local evidence are retained under
`/home/codex/paranoid-update-publish/v27/` (build log, reviewed snapshot,
release-review JSON, manifest and downloaded bytes).

After publication:

1. The retained old v25 updater fetched version27 over the unchanged pinned
   origin and downloaded all 16,443,022 bytes with the exact expected SHA256.
2. The current updater separately downloaded the live version27 and retained it
   for inspection. Byte comparison against the published snapshot passed.
3. The artifact test on those **downloaded** bytes passed package, version,
   permissions, core/DEX presence, exact signer, APK signature and 16KiB alignment.

These are real host transport/artifact checks, not Android installer execution.
No phone installation, call/push runtime acceptance or on-device history audit
was performed. Users update in place through the ordinary native confirmation;
never uninstall, clear data or downgrade to recover. Feed rollback only stops
further distribution; already-updated clients require a forward-fix release.
Issue38 remains separate and is not claimed fixed by this publication.
