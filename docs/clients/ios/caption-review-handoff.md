---
status: draft
owner: client
last_reviewed: 2026-09-23
---

# PR #55 caption review handoff

## Scope and authority

Yaroslav requested removal of the numeric limit caption and preparation of the
remaining caption corrections for merge. Changing the resource budgets is deferred
to Yaroslav and Sergey; [RFC-0022](../../rfcs/0022-unlimited-conversation-history.md)
remains proposed. This change does not alter core, wire, crypto, state format,
permissions, server, Android, call-controller behavior or distribution machinery.
It is not merge, release, deployment or ADR-acceptance authorization.

Requirements: REQ-CLIENT-004 (honest presentation), REQ-MSG-003/004
(delivery semantics and persistent server history). Accepted ADR-0001 requires
matching documentation; ADR-0003 does not waive owner acceptance or native gates.

## Corrections

- Remove the numeric message-count sentence, not the core's resource bounds.
  Independent outgoing commitments and inbound text/receipt event counts are not
  one total-history cap. The PR review includes a real-core counterexample with
  1001 texts visible after reopen, without manually padded history.
- Keep manual installation wording, consistent with the current
  [distribution evidence](build-and-testflight.md).
- Ask the user to keep the app open for incoming calls; warn that a missed-call
  row may be absent after reopening. Do not promise unconditional absence either.
  The [voice-call document](voice-calls.md) distinguishes cold launch, expiry,
  and a retained readiness slot admitting fresh queued offer/end on resume.
- Keep the Russian plural correction and update rendered-caption assertions.

## Error presentation, unchanged

`AppModel.send()` restores the draft and shows `Strings.Status.sendUnfinished`
when sending throws. That is a generic error, not a specific capacity diagnosis.
Incoming rejections are a different path; this caption-only change does not add
new error mapping, retry, archival or recovery behavior. Do not claim those UX
improvements as implemented. Expansion of limits and detailed capacity UX remain
follow-up work, not a reason to advertise a fictitious total count here.

## Local evidence and remaining gates

On the prior PR head, the Linux source contracts, bridge ABI, Rust checks,
Markdown and real-core counterexample passed; the
[PR review evidence](https://github.com/GOTD-GLOBAL/ParanoID/pull/55#issuecomment-5800308865)
records exact scope and reproduction source.
For this closure, the strengthened `UNTRUE` test was first run RED independently
for the numeric promise and the unconditional no-row promise, then GREEN after
each caption correction. Neither check was weakened. Final Linux/CI receipts
are recorded on the exact new commit in the PR rather than inferred from the
prior head.

Three new `CallCaptionLifecycleTests` characterize the existing controller via
wire-body serialization and an injected clock: preserved readiness admits queued
offer/end after resume, a cold controller without readiness does not, and expired
controls do not create a terminal record. Production call logic is unchanged.
These tests were authored on Linux; Swift/XCTest execution is **NOT RUN** here.
They do not exercise actual iOS suspension, player audibility or a physical lock.

## Mac gate on the exact pushed head

Use `clients/ios/toolchain.sh` and record the full commit ID, clean tree, toolchain,
simulator destination and commands. Generate notices from that same tree.

```sh
bash clients/ios/toolchain.sh swift test \
  --package-path clients/ios/ParanoidKit --filter CallCaptionLifecycleTests
bash clients/ios/toolchain.sh swift test --package-path clients/ios/ParanoidKit
```

Also run the app target (including `ConnectionCaptionTests`), separately signed
Keychain tests as appropriate, and the stand-backed `TextFlowUITests` flow checking
both changed screens. Rebuild the device bundle and run its existing verification.
Record skipped cases explicitly. A source gate or a passing old-head receipt does
not substitute for this native gate. No signed export/TestFlight/device acceptance
is claimed or requested by this handoff.

## Integration and rollback

After the exact-head Mac receipt, independent review and CI: present source merge
for the owner's decision. No server deployment is needed by this iOS-only diff.
Installing/distributing an iOS build is separate from merging source into `main`.
Rollback is a reviewed revert; no data migration is involved.

The separate Android follow-up from main after #55/#56 removes the stale
numeric sentence and restores the shared line's `MainActivity.java` origin in
`clients/ios/test/captions.txt`. Both UI contracts guard the shared wording;
a dedicated Android assertion rejects either retired numeric promise. This is
a source change, not an APK release. Core budgets and RFC-0022 are unchanged.
The Android edit lives outside the original iOS PR; its component-boundary
allowlist is not expanded.
