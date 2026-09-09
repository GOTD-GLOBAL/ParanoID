# GitHub persistence verification

This record describes checks performed while persisting the frozen implementation,
not a new product qualification or deployment.

- Offline `verify.py`: PASS, 254 source entries, all non-Markdown inputs unchanged,
  ten documented Markdown replacements reconstructable, 91 postbuild doc hashes
  and byte-exact copied evidence verified. Index blobs also matched every source
  and postbuild-document allowlist entry.
- APK, source archive and server bundle rehashed locally: all three match the
  published hashes in the evidence README. No binary uploaded to GitHub.
- Raw latency samples independently recomputed with nearest-rank percentiles:
  baseline 20 / 3043.977463 / 3057.497984 ms; local 24 / 102.942236 / 122.013062 ms;
  external 12 / 76.50962 / 85.743713 ms.
- `npx --yes markdownlint-cli2`: 93 Markdown files checked, zero issues at the first
  persistence pass. Evidence README's 27 relative targets all exist.
- Gitleaks 8.21.2 scanned 286 explicit source/evidence files, no symlink traversal:
  exit 1, 23 generic-api-key heuristic findings, all manually classified as public
  source/schema hashes or public deterministic credential fingerprints. See
  `secret-scan-dispositions.json`; zero unresolved secret findings. This is not
  falsely described as a raw zero-findings scanner run or universal security proof.
- `git diff --cached --check` reports preserved whitespace at
  `clients/android/test_realtime.py:173`, `server/self-service-schema.sql:31` and
  final blank lines in two copied evidence logs. These bytes are intentionally
  retained to match the reviewed source/original logs, not silently rewritten.
- `clients/android/test_realtime.py --help` returned documented fixture options.
  Attempting `server/check-realtime.py --help` revealed that script has no argument
  parser: it actually started a fresh local PG test run, compiled the debug server
  and was interrupted by the 30-second tool timeout during the first test. This
  attempted rerun is **INCOMPLETE, not PASS**; the earlier 14-PASS qualification
  remains historical evidence. Subsequent process inspection found no matching
  realtime-test/check-runner process. No remote command was involved. Product
  source and deliverable hashes were reverified unchanged afterward. The README
  now gives the real server command without a misleading `--help` example.

GitHub checks are separate and will be reported on the draft PR, including pending
or failed checks; no runtime/test expectation is changed for CI. The current
GitHub rulesets API returned an empty list; that alone is not proof of every
possible legacy protection setting. Persistence changes no repository settings.
