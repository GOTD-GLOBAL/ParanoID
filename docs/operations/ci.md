---
status: draft
owner: maintainers
last_reviewed: 2026-10-16
---

# Continuous integration

Reference for the GitHub Actions checks. The workflow sources in
`.github/workflows/` are authoritative; this page explains their contract.

## One entry point, one required check

`.github/workflows/ci.yml` runs on every pull request, every push to `main` and
manual dispatch. It has **no path filters**: every change runs every component
workflow, so a change to one platform always runs the other platform's gates.

| Job | Calls | What it checks |
| --- | --- | --- |
| `docs` | `docs.yml` | Markdown lint, links, Devnet receipt citations |
| `server` | `server.yml` | server, deploy, client core, JNI/TLS, Android host gates, Devnet client, legacy history |
| `ios` | `ios.yml` | iOS static checks on Ubuntu: bridge, pins, captions, notices, boundary |
| `gate` | — | passes only if `docs`, `server` and `ios` all finished with `success` |

`gate` is the single status check that [`main`'s ruleset](#main-branch-ruleset)
requires. A failed, cancelled or skipped component fails it. `docs.yml`, `server.yml` and `ios.yml`
have only a `workflow_call` trigger and never run on their own.
`scripts/test-ci-wiring.py` enforces this layout.

A newer push to a pull request cancels that pull request's older run. Pushes to
`main` and manual dispatches never cancel one another: each gets its own
concurrency group, so every commit on `main` keeps its own result.

### Cost of running everything

Every pull request, a one-line Markdown fix included, waits for the slowest
component. That is the server suite, `server`'s `postgres-http` job. This is the
price of never skipping a consumer's gate.

Five server tests wait on real time on purpose: the five-minute session expiry,
the two-minute TLS socket lifetime, the nonce ledger and two 61-second expiries.
Together they took about 11 of the suite's 16 minutes, so `postgres-http` runs
as three parallel shards, each on its own runner with its own private
PostgreSQL: `realtime-expiry`, `realtime-limits` and `rest`. Each shard needs
about five and a half minutes of tests plus a cold build. No test is shortened,
skipped or given a test-only timeout.

`scripts/check-server.py` owns the shard table (`SHARDS`). Before a shard runs
any test, it lists the suite through libtest and proves that its filters
select exactly the tests it owns. A renamed slow test, a test in two shards or
a missing test fails the shard before PostgreSQL starts. The catch-all `rest`
owns every test that is not named, so a new test always runs. To rebalance,
move names in `SHARDS`; the CI matrix must list the same shards, and
`scripts/test-ci-wiring.py` checks that. Run it locally without `--shard` to
run the whole suite, as before.

Links are checked in two places:

- **Internal links and anchors, on every change.** `docs.yml` runs lychee with
  `--offline --include-fragments`. Every relative link and every `#anchor` into a
  repository file must resolve. The check needs no network and fails the same
  way every time, so it is strict.
- **External links, weekly.** `links-weekly.yml` runs on a schedule (Mondays
  06:17 UTC) and on manual dispatch, never on a pull request or push. A dead
  external link opens or updates one issue, "Weekly external link check found
  dead links", instead of blocking unrelated changes. Fix the document, or add a
  justified line to `.lycheeignore`. That file is the one exclusion list for
  both checks.

One step still reaches a third-party service on every change.
`scripts/check-devnet-receipt.py` reads the public Devnet RPC to verify the
recorded deployment. If it fails on a change that did not touch the Devnet
records, re-run the failed job.

## Legacy history job

`clients/core/tests/self_service.rs` keeps 14 historical pre-v7 assertions that
fail by design ([archival record](archival-ci-correction.md); REQ-MSG-005's
historical scope). They are listed in `scripts/ci-legacy-client-tests.txt`.

`scripts/check-legacy-failures.py` runs the whole target without exclusions and
passes only when exactly those 14 fail and every other test passes. A new
failure, a listed test that starts passing, a missing, ignored or filtered-out
test, a build error or an inconsistent cargo exit fails the job. The raw cargo
exit and every historical failure name are printed and written to the step
summary.

Green means "the same 14 listed tests fail and every other test passes". It
never means "historical target fixed". The check compares failing names only,
not why each test fails. A listed test that starts failing for a new reason
stays green, so a change to code those tests exercise still needs its own
supported tests.

Since 2026-10-16 this job is green when the result is exactly the documented one.
Before that it was deliberately red, which kept every `main` run red. The
decision owner confirmed this change in the ParanoID Telegram group: see
[archival record](archival-ci-correction.md#aggregate-semantics-superseded--2026-10-16).

## Host Java compiles

CI compiles the Android text client on the host with hand-written file lists.
`server.yml`, `test_realtime_transport.py` and `test_updates.py` pass
`-sourcepath clients/android/src`. A production class of the same package that
a list forgot then compiles implicitly instead of failing CI; in 2026-09/10
that was the most common CI failure, and it was never a defect.
`clients/android-devnet/check_controller.py` puts both the devnet and the text
package on its sourcepath, because the devnet client legitimately depends on
the text client.

The text sourcepath holds the text package only. A new dependency of
`org.paranoid.text` on `org.paranoid.devnet` therefore still fails these
compiles, as it should. `clients/android/test_host_sourcepath.py` checks both
halves on every change.

## What CI does not prove

- No Android APK is built or signed in CI; APK builds and device runs are local.
- No macOS runner: iOS simulator, XCTest, the local stand and device runs are
  manual Mac receipts recorded in `docs/clients/ios/`.
- No ParanoID server, phone, TLS key, Devnet wallet or production host is
  contacted. On a change, the only outside traffic is the read-only Devnet RPC
  citation check and package downloads from apt, crates.io, Maven and rustup.
  External documentation links are checked weekly, outside `gate`.

## Adding a check

Add it as a step or job inside the component workflow it belongs to. A new job
inside `docs.yml`, `server.yml` or `ios.yml` is covered by `gate`
automatically. Give it a `timeout-minutes`; the wiring test requires one for
every job.

Do not add path filters to `ci.yml`. Do not add another workflow that runs on
`pull_request`, `push` or `workflow_call`: its checks would sit outside `gate`.
A separate workflow is allowed only for `schedule` or `workflow_dispatch`, for
example a weekly report. `scripts/test-ci-wiring.py` enforces both rules. It
reads the workflows as YAML, so reformatting a workflow does not break it.

The workflows `rust.yml` and `mobile-identity.yml` were left over from an
August 2026 branch. They were disabled in the repository settings on
2026-10-16 and never ran on `main`.

## Main branch ruleset

The repository owner configured it in the GitHub UI on 2026-10-16. It is
ruleset `main` (ID 25251613), with enforcement `active`, applied to the default
branch, and with an empty bypass list. The same day the rulesets API returned
exactly these rules:

- `deletion` and `non_fast_forward`: `main` cannot be deleted or force-pushed.
- `pull_request`: every change reaches `main` through a pull request; a direct
  push is refused. It requires zero approvals and allows merge, squash and
  rebase.
- `required_status_checks`: `gate`, pinned to the GitHub Actions app
  (`integration_id` 15368). A commit status named `gate` from any other source
  does not satisfy it. A pull request does not have to be up to date with
  `main` before merging (`strict_required_status_checks_policy: false`).

The repository setting "Automatically delete head branches" is on.

The ruleset enforces CI, not review. It requires zero approvals, so human
review and decision-owner approval remain process rules recorded in each pull
request under the [documentation policy](../governance/documentation-policy.md).
GitHub does not enforce them. A pull request also does not have to be up to
date, so two pull requests that each pass `gate` alone can still break `main`
when combined. The push run on `main` shows this, and a new pull request fixes
it.

To rename or remove the `gate` job, change the ruleset first. Otherwise no pull
request can merge, because each one waits for a check that never reports. That
includes the pull request that would fix it, and a revert of the CI entry point.

A required `gate` is only as trustworthy as the review of what computes it. For
a `pull_request` event GitHub runs the pull request's own version of
`.github/workflows/**` and `scripts/check-legacy-failures.py`, so a pull request
can change the logic that judges it. Review every change to those paths as a
change to the merge rule itself. A `CODEOWNERS` entry for them is a possible
later owner action; none exists now.
