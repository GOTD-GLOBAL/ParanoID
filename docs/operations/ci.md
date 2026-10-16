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
component. That is `server`'s `postgres-http` job, which takes about 18–20
minutes of wall time. This is the price of never skipping a consumer's gate.

Two steps reach third-party services, so an outage there can fail `gate` on an
unrelated change. Lychee checks every external documentation link, with four
retries five seconds apart. `scripts/check-devnet-receipt.py` reads the public
Devnet RPC. If either step fails on a link or service that the change did not
touch, re-run the failed jobs. If a link is permanently gone, fix the document
in a separate pull request. Do not add an exclusion only to turn the check green.

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

## What CI does not prove

- No Android APK is built or signed in CI; APK builds and device runs are local.
- No macOS runner: iOS simulator, XCTest, the local stand and device runs are
  manual Mac receipts recorded in `docs/clients/ios/`.
- No ParanoID server, phone, TLS key, Devnet wallet or production host is
  contacted. The only outside traffic is the read-only Devnet RPC citation
  check, lychee's external link checks, and package downloads from apt,
  crates.io, Maven and rustup.

## Adding a check

Add it as a step or job inside the component workflow it belongs to. Do not
create a new top-level workflow or add path filters to `ci.yml`. A new job
inside `docs.yml`, `server.yml` or `ios.yml` is covered by `gate` automatically.

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
