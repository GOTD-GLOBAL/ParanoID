---
status: draft
owner: ios
last_reviewed: 2026-10-13
---

# Native Mac receipts: Devnet facade and separate QR fixture

These are reports published by Yaroslav / `Cooldom66671`, retrieved from their
exact GitHub comments by the Linux coordinator. The coordinator did not execute
Xcode or inspect full local Mac logs/artifacts. Abbreviated artifact hashes in
those comments are not full independently verified checksums.

## Swift facade: c1e9b90

- Exact source: `c1e9b9045e16e6b39b3821dbf2a4c5e39f445c3c`, PR #78.
- [Original human receipt](https://github.com/GOTD-GLOBAL/ParanoID/pull/78#issuecomment-6153275696).
- Dedicated detached worktree, clean before and after; no source edits.
- Reported pins: Xcode 26.6 (17F113), iOS SDK 26.5, Swift 6.3.3,
  Rust 1.98.1, Python 3.14.4, macOS Darwin 27.0.0.
- Fresh Rust xcframework: three arm64 slices; verified pinned WebRTC: two slices.
- DevnetBridgeTests: **21 tests / 0 failures**.
- CoreBridgeTests: **10 tests / 0 failures**.
- Full ParanoidKit: **410 tests / 0 failures / 0 skipped**.
- First unsigned Release `xcodebuild`: **exit 65**, missing
  `clients/ios/out/THIRD_PARTY_NOTICES.txt`. The handoff omitted `notices.py`;
  the app's resource-copy phase failed. This failure remains part of the receipt.
- After normal `notices.py --offline` and `test_notices.py`: **146 crates plus
  WebRTC 150.7871.01**, rules **32 tests PASS**. The identical `xcodebuild`
  command then returned **exit 0 / BUILD SUCCEEDED**, without source edits.
- Additional reported bundle check: **23 checks PASS, one Team ID check skipped**
  because the build was unsigned. This is not signing or device execution.

The native component/package and unsigned compile requests are satisfied on
this source. A documentation-only correction does not require rerunning them.
No simulator/device execution, signed build, installation, RPC, registration,
server login, owner replacement or recovery/login/restart phone acceptance was
performed by this receipt. The facade is not a working identity-v3 application.
The full wrapper still has the separate gate 11 blocker.

## QR-only fixture: 7029d80

- Exact source: `7029d805315441ecfcd923cd38b268f3786a259b`, separate PR #79.
- [Original human receipt](https://github.com/GOTD-GLOBAL/ParanoID/pull/79#issuecomment-6153314021).
- Dedicated worktree, clean before and after; pinned build prerequisites passed.
- Six consecutive `test_qr_cross.py` runs: **six PASS, each four checks and
  exit 0**. The previous source `4aac29c` had one PASS and three FAIL in four
  runs; this historical failure is not erased by the new receipt.
- No simulator, device, server, stand or signing action is claimed.

The receipt's prose file inventory omits `clients/ios/README.md`; the coordinator
checked the exact commit and PR, which contain **three** files: that README,
`clients/ios/test_qr_cross.py`, and `docs/clients/ios/verification.md`. This is
an inventory correction, not evidence of a source change during the Mac run.

This QR source is separate from `c1e9b90`; neither the frozen #78 source nor this
documentation branch incorporates #79. Do not attribute the fixed QR result to
the old fixture in those trees, and do not request another unchanged QR run.

## Remaining authority and application gates

[Draft ADR-0017](../../../decisions/0017-ios-concurrent-identity-v3.md) records
Yaroslav's technical basis agreement and the still-pending product/alpha-scope
record in #73. Neither receipt supplies that approval, accepts an ADR or permits
merge, deployment or live phone actions. Owner/realm persistence, login/runtime
implementation, its new tests and first authorized VDSina phone acceptance remain
separate work. No ready-to-login iOS build is claimed.
