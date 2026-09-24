---
status: draft
owner: ios
last_reviewed: 2026-09-23
---

# Contributor Mac receipt for PR46 at cc5b0c7

## Provenance

Yaroslav reported the final-head Mac gate for exact
`cc5b0c711090729cb53690a526722a5d86edd6f4` in the ParanoID Telegram thread on
2026-09-18. The coordinator requested that gate in
[PR46 comment 5727481543](https://github.com/GOTD-GLOBAL/ParanoID/pull/46#issuecomment-5727481543)
and relayed the report in
[PR46 comment 5727872437](https://github.com/GOTD-GLOBAL/ParanoID/pull/46#issuecomment-5727872437)
at 2026-09-18T09:13:51Z. The latter comment was read back during this documentation
review. PR46 merged as `c9ca067bf747b7b3046fcfdf1986a46c0418ff21` at
2026-09-18T09:18:19Z.

This is an English summary of that durable relay, not a verbatim transcript or
an independent coordinator Mac execution. The Telegram message retained in the
coordinator's session history agrees with its results and limitations. It does
not supply the expanded command lines, all test method names or full server
binary digest previously presented by this draft as an original quotation.
Those expansions and their text checksum have been removed rather than used as
execution evidence. No Telegram permalink was supplied; raw logs, screenshots
and xcresult bundles were not retrieved for this record.

## Reported environment and results

The contributor reported a clean worktree at the exact SHA, macOS 26, Xcode 26,
Swift 6.3.3, Rust 1.98.1, and an iPhone 17 Pro simulator on iOS 26.5.

| Check | Contributor-reported result |
| --- | --- |
| `bash clients/ios/build-core.sh` | OK: device, simulator and macOS slices |
| `swift test --filter MessageTimeTests` | 7 passed, 0 failed, including `testCallPreviewDoesNotBorrowTheLastMessagesTime` |
| Full `swift test` | 328 passed, 0 failed |
| Unsigned simulator application build, `CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| `test_sim_text.py --server-binary … --scenario text` | PASS: 15 screenshots, 6 retained envelopes, 0 plaintext rows, one bubble per tap, 3 messages in peer history |
| Five original iOS source gates and call parity | OK; parity 105/105 |
| Android host controller, call-log, message-time, message-presentation and UI tests | OK |

Reported core-slice SHA-256:
`119cd7dde4b6fb761865565af8c710822d1e08a2219106b58be1e5421a9adbdb`.
The report does not identify which slice that digest names; this documentation
review did not retrieve or hash the artifact.

The running simulator application's accessibility labels contained HH:mm, the
chat showed the Today separator, and delivery marks read as stored by server and
then delivered. Call-preview date suppression was checked **only by the new unit
test**: the text scenario contains no call, so it did not observe that preview.

The stand used a prebuilt server identified only as `a4a65d12…` in the verified
report; the server could not be rebuilt on macOS because of Linux-only
`O_TMPFILE`. A full digest in an earlier evidence catalogue is not proof that
this run used that exact artifact. No fresh server build from this checkout is
claimed; PR46 does not change server/deploy.

## Checks against Git, not new execution

- `git diff cc5b0c7 c9ca067 -- clients/ios clients/core key-protocol` is empty:
  PR46's merge carries these tested source trees unchanged. This does not prove
  bit-identical compiled artifacts or repeat the Mac run.
- `test_sim_text.py --scenario text` selects the stand-backed text UI scenario,
  not a physical-phone run or a call scenario.
- `cc5b0c7` is an ancestor of the later [4066f36 receipt](mac-receipt-pr50-4066f36.md).
  That report's full package run is consistent with inclusion of MessageTimeTests,
  but is not a newly retrieved per-suite log or live-UI call-preview observation.

## NOT RUN and boundaries

Physical phones, spoken VoiceOver, a signed iOS application build/export,
TestFlight, APK/Android SDK checks, the production server and two-phone acceptance
were not run by the contributor in this receipt. The coordinator's Linux Android
checks remain separate. Live simulator call-preview observation remains a follow-up.

These results closed the requested package/build/text-flow gate by contributor
report; they do not constitute architecture approval or ADR acceptance. The later
source merge is recorded above, not recast as deployment, publication or device
acceptance. No new execution, installation or live operation follows from this
records-only PR.
