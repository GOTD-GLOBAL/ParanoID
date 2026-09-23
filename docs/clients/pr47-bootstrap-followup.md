---
status: draft
owner: ios
last_reviewed: 2026-09-18
---

# PR47 bootstrap and documentation follow-up

Base: `57a45debf2c7884c5340db7b375ee6a88e464c29`.
Yaroslav requested coordinator implementation of C1/C2 from the follow-up
review. This change does not merge, install, deploy or accept RFC-0024/any ADR.

## Changes

- `AppModel` initializes `ContactNames(store: nil)` and `CallLog(store: nil)`.
  These values have no persistent-store side effects, including when screens
  read them before startup.
- A stored factory creates/loads the real metadata stores only after successful
  client and Runtime construction, before setting `.running` and starting lanes.
  A once flag prevents reloading over live values on repeated start calls.
  No lazy getter can accidentally authorize a migration. No-stand, malformed
  fixture and initial-open failure paths exit without invoking the factory.
- The existing test-only bootstrap seam remains; a separate metadata factory
  allows isolated UserDefaults suites and temporary directories in app tests.
  Production defaults still use the application container after the gate.
- RFC0024, client docs, threat model and current-state/changelog consistently
  separate proven byte/flag failures from inconclusive I/O, and completed
  migration from retained legacy preferences or historical backups. In-process
  preference removal is not represented as crash-durable OS backup erasure.
- No LocalMetadataStore storage algorithm, key policy, core, Android, protocol,
  server or persisted format was changed. Its one source edit is a lifecycle
  comment reflecting deferred initialization.

## Verification

Actually executed on Linux: the new UI source-wiring test failed on the old
initialization; all 23 UI source tests pass after correction. The old name-table
source assertion was updated to require the new non-persistent initialization
plus explicit assignment, not simply removed. Storage bootstrap (5), call
control targeting (4), docs consistency and 105/105 parity labels pass.

Three **app-target** tests were added in `LocalMetadataBootstrapTests.swift`:

1. Construction, early view reads, start and repeated start with injected
   `trustUnavailable` produce `.noStand` and preserve both legacy preferences
   without creating the metadata directory or calling the loader.
2. A malformed-stand bootstrap outcome also leaves both stores untouched.
3. An initial failed open followed by an authorized retry migrates both tables
   once, proves exclusion/legacy retirement, preserves old values and can append
   and reopen a new call row. The real client has no identity and a no-commit
   sink, so no server or user Keychain is used by these fixtures.

The tests exercise actual AppModel construction/start/retry but inject the
bootstrap outcome through its existing `openClient` seam. They do not claim to
execute every platform environment/preflight branch. The source guard separately
checks ordering after the real no-stand early return and Runtime construction.

Swift compilation, these new XCTest cases, fresh app/bundle and device behavior
are **NOT RUN on Linux**. A bounded independent Opus 5 source re-review found
no confirmed blockers after checking the actual type/ownership and bootstrap
context; this is not Swift execution or architectural acceptance. The contributor's earlier 362/0 package receipt and
23/1 bundle receipt belong to `57a45de`, not this patch.

Update recorded 2026-09-23: this patch merged in PR47 as `5026236`, which is an
ancestor of PR50's `4066f36`. Between those commits, `LocalMetadataBootstrapTests.swift`
and the metadata store sources are unchanged, and `AppModel.swift` changes only
in PR50's call-audio path. The contributor's
[4066f36 Mac receipt](../project/evidence/ios-client-20260918/mac-receipt-pr50-4066f36.md)
reports the full app target without Keychain at 90/0 and ParanoidKit at 362/0.
Those runs therefore compiled and executed this patch as merged. By the tree's
test count, the 90 include the three cases above. They were not the focused
command below, which was not reported separately, and they are not device,
backup or restore evidence.

## Mac handoff

Use an isolated worktree and the project's normal core/framework preparation.
Generate notices in that tree before building a fresh bundle:

```sh
python3 clients/ios/notices.py --offline
swift test --package-path clients/ios/ParanoidKit
xcodebuild test -project clients/ios/App/ParanoID.xcodeproj -scheme ParanoID \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ParanoIDTests/LocalMetadataBootstrapTests \
  -only-testing:ParanoIDTests/OpeningRetryTests
```

Use the existing authorized simulator signing configuration; this is not
permission to install on a physical phone or upload to TestFlight. Then run the
full app tests and fresh simulator build as appropriate. If running
`test_app_bundle.py`, pass the actual newly built `.app` path explicitly: the
checker does not build and its default `out/ParanoID.app` can be stale.
Record source SHA, app-test counts, package result and exact bundle provenance.
