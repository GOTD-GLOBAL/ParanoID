# Independent timeout review — 2026-09-18

Verdict: **APPROVE**, no blockers, local candidate only. Fresh read-only review
via Claude CLI; actual result reports `claude-opus-5` with auxiliary
`claude-haiku-4-5-20251001` usage. This is not a human audit or architecture
acceptance. Reviewer inspected the complete four-site diff, new TLS fixture,
CI/doc changes and supplied local execution evidence; it did not run tests.

The first exploratory review hit its turn limit without a verdict; its resume
failed with `No conversation found`. Neither counted as approval. A fresh
single-turn full-patch review completed successfully. Local raw result:
`/tmp/paranoid-timeout-review-fresh.json`.

## Disposition of non-blocking suggestions

- Clarified retry wording to preserve message IDs/ciphertext specifically for
  message retries, not every connection operation.
- Documented that the updater's nominal deadline is unchanged but a blocked read
  can extend beyond it by the longer per-read bound. No total deadline claim.
- The real ordinary 10-second handler bound is present in
  `server/src/self_service_http.rs` (inner request middleware); the pre-existing
  realtime reference already identifies both inner and outer middleware. The
  new test is deliberately a transport fixture, not Rust-handler validation.
- `RealtimeTransport.call` rejects v1 paths at ingress. KeyTransport retains v1
  reads at 8 seconds. No extra version guard is needed in the realtime adapter.
- Valid core-signed events requests carry a query. Broadening the prefix to
  `/v2/events` would also match different route names, so that suggestion was not
  applied. Events-route normalization is outside this fix.
- The tests demonstrate delayed delivery and reject old 8-second values; they
  do not assert an exact 15-second upper bound, legacy-v1 timing or connect timing.
  The unchanged source values are inspection evidence only. Further upper-bound
  timing coverage is a non-blocking follow-up, not claimed as tested.
- Update non-200 responses intentionally expose a generic IOException. The
  fixture verifies the production behavior without changing its error API.
- `--evidence-dir` was already supported by the runner and was used in actual
  RED/GREEN executions. The new test output is preserved in the CI job log.
- Owner direction is directly present in the current Telegram conversation;
  absence of a permalink is stated, not replaced with invented provenance.

No runtime changes followed this approval. The two documentation clarifications
above and this review record were the only subsequent additions.
