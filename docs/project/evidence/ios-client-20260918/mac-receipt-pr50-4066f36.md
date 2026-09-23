---
status: draft
owner: ios
last_reviewed: 2026-09-23
---

# Contributor Mac receipt for PR50 at 4066f36

## Provenance

Yaroslav ran the Mac gate for exact `4066f36f90eef71bbd78c0ac1813f6598c8e5292`,
the final head of PR #50 (iOS call tones and audio lifecycle), and reported it
in the ParanoID Telegram thread on 2026-09-18. The durable record of that report
is the coordinator's bot-authored merge-gate review
[PR50 review 5251691143](https://github.com/GOTD-GLOBAL/ParanoID/pull/50#pullrequestreview-5251691143):
`APPROVED`, 2026-09-18T19:18:15Z, by `goryanya-deploy[bot]` on commit `4066f36`,
quoting the report. This file transcribes that quotation. The raw Telegram
message, logs and xcresult bundles were not retrieved for this record, and no
Telegram permalink was supplied.

These are contributor-reported Mac results. They are not a coordinator Mac run,
not human architecture approval and not ADR acceptance. The commands requested
from the contributor are in the
[PR50 Mac handoff comment](https://github.com/GOTD-GLOBAL/ParanoID/pull/50#issuecomment-5733796530)
and in [call-tones-handoff.md](../../../clients/ios/call-tones-handoff.md).

Reported environment: clean worktree at the exact SHA; notices generated in that
tree; iPhone 17 Pro / iOS 26.5 simulator through `clients/ios/toolchain.sh`.

## Results reported for 4066f36

| Check | Reported result |
| --- | --- |
| Five requested focused app suites: `CallTonesTests`, `CallTonePlaybackTests`, `AudioPreparationReplyTests`, `CallAudioSessionTests`, `CallScreenPolicyRegressionTests` | 42 tests, 0 failures |
| Full `ParanoIDTests` app target, excluding Keychain | 90 tests, 0 failures |
| `KeychainStoreTests`, separate ad-hoc-signed run | 11 tests, 0 failures |
| ParanoidKit package | 362 tests, 0 failures |
| `test_app_bundle.py` on a freshly built device bundle | 23 checks, 1 skipped |
| All 16 ios-static Python gates | green |

The review also records that Yaroslav reviewed the rewrite and reported no
objections. The report does not name the skipped bundle check and gives no
per-suite breakdown of the 90 app tests.

## Checks against the tree (2026-09-23)

Read from git, not from the report:

- GitHub records `4066f36` as PR50's head. PR50 was squash-merged into main as
  `02baeb21e243fad16705ea4904ae687d466b58b3` at 2026-09-18T19:18:23Z.
  `git diff 4066f36 02baeb2 -- clients/ios clients/core key-protocol` is empty.
- `git diff 4066f36 c735f94 -- clients/ios clients/core key-protocol` is empty.
  Main at `c735f94920b0ff85383b22f959b86f35de078e61` has byte-identical iOS,
  core and key-protocol trees. This connects the receipt to that exact source
  checkpoint, not to later main heads or bit-identical compiled artifacts.
  The four main commits after `02baeb2` do not touch those paths.
- The counts agree with the tree. At `4066f36`, `ParanoIDTests` declares 101
  test methods, 11 of them in `KeychainStoreTests` (101 − 11 = 90). The five
  focused suites declare 28 + 3 + 3 + 5 + 3 = 42 test methods. These numbers
  come from counting `func test` declarations, not from a rerun.

## What else these runs covered

PR47's merge `5026236d0affd25f945999d796a33d3886d1794e` and PR46's head
`cc5b0c711090729cb53690a526722a5d86edd6f4` are both ancestors of `4066f36`
(`git merge-base --is-ancestor`). Between `5026236` and `4066f36`,
`LocalMetadataBootstrapTests.swift` and the metadata store sources are
unchanged. The only change to `AppModel.swift` is PR50's call-audio preparation
path. The reported full-target scope is consistent with inclusion of the
[PR47 bootstrap follow-up](../../../clients/pr47-bootstrap-followup.md) tests.
Only `KeychainStoreTests` was reportedly excluded; the three unchanged
`LocalMetadataBootstrapTests` cases therefore fit within the reported 90.
This is inferred inclusion from the source tree, counts and stated run scope,
not an independently retrieved per-suite execution log. Counting declarations
alone cannot prove runtime discovery, selection or execution.

These runs were not a dedicated PR47 test campaign. The focused
`LocalMetadataBootstrapTests`/`OpeningRetryTests` command in that handoff was not
reported separately. None of this is device, backup or restore evidence.

## NOT RUN

- Physical-device audibility, speaker/headset/silent-switch behavior, haptics
  and real call/alarm interruption: NOT RUN for this candidate, as the review
  states. The fake-port and held-player tests check application ordering, not
  acoustic output or hardware mute behavior.
- The report includes no physical-iPhone installation, signed archive/export,
  TestFlight or hosted-server test.

## Boundaries

The review records Sergey Maltsev's Telegram authorization to merge PR50
("Мержи"), with no permalink. That authorization covers the merge only. It is not
architecture or ADR acceptance, a release or a deployment.
[RFC-0025](../../../rfcs/0025-ios-call-tone-lifecycle.md) and
[ADR-0014](../../../decisions/0014-ios-client.md) remain proposed. The rollback
is a reviewed revert of PR50; the PR adds no server or persisted-state migration.
