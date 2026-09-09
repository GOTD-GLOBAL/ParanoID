# Overnight realtime: durable preservation checkpoint

This is a **draft archival integration PR, not a merge-ready combined component
submission**. The current owner task explicitly requests a GitHub feature branch
and draft PR preserving the delivered implementation and evidence. The earlier
[component PR boundaries](../../component-boundaries.md) still govern eventual
merge proposals: split dependent server/shared-contract and client review PRs
before merge. Nothing here accepts an ADR, closes issue #16, publishes binaries,
or authorizes further live actions. PR #17 is unrelated and unchanged.

## Source and artifacts

The 254-file [build-source manifest](final-source-sha256.json) has SHA256
`0f6d0689cefd7eac1a61bddc296054fbddc09dc0d06795a832779f785c314f2e`.
All non-Markdown inputs are byte-identical to the reviewed v8 build. Ten canonical
Markdown files have the documented postdeployment updates, and one dated rollout
record was added. Their [separate manifest](postdeployment-docs-sha256.json) has
SHA256 `6522b7fa39c1507dfba300ad97e37b815d58be81fda7e01905858eb95835c415`.
The ten original Markdown files are retained byte-exact under `frozen-docs/`
with `.txt` suffixes; the complete frozen source can thus be reconstructed without
local chat/evidence access. Extra archival evidence is not a compiler input.

- APK: `org.paranoid.devtext`, versionCode 8, `0.0.8-realtime`, ARM64/API26+.
  SHA256 `1b9f44d88011f0a8e4aa454e4df890c0a6872190a8606d1b590e8d942e42eadb`.
- Retained signer SHA256:
  `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926`.
- Server release: `3ed25173ad978e6b417c`; bundle SHA256
  `2306c0a8c35e2d9e42e15a507d1825df7c2f3e6c115bf1823176817aaf4630f0`;
  binary SHA256 `bf74a9634f20163ac7254af9c0876bd6c9ff7e60cd77253503cc598deeb22fa2`.
- Original source archive SHA256:
  `b1e1b13c8b97af23bf2b4927ec91fa74c532dc5f19dcf795957f2cfbe55cda24`.

No APK, server binary, private key, credential, phone snapshot, encrypted backup,
or dependency/build output is published in this PR. Absolute paths in historical
reports describe the original execution environment, not portable dependencies.

## Rationale, invariants and outcome

[ADR-0010](../../../decisions/0010-overnight-realtime.md) and
[RFC-0015](../../../rfcs/0015-overnight-realtime.md) remain **proposed**. The bounded
choice retains the functioning E2EE core, v7 identities/history, pinned endpoint,
signer and server schema instead of replacing the stack overnight. Device-signed
non-bearer sessions remove repeated challenges; bounded long-poll removes polling
latency. A single native-state owner commits immutable outbox and incoming state;
separate network lanes prevent receipt I/O from blocking durable publication.

REQ-MSG-006 is covered by real TLS/PG/JNI measurements, retry/race/persistence tests;
REQ-CLIENT-004 by real Android35 emulator UI/background checks; REQ-SERVER-003 by
revocation and binding tests; REQ-DEPLOY-002 by packaged same-current-data rollback
and authenticated encrypted-backup verification. REQ-MULTI-002 records future
membership isolation, not an implemented second server. Mature OSS/XMPP selection,
federation, invitations, calls, blockchain and push adapters remain future work.

The [dated rollout](../../../operations/realtime-rollout-2026-09-09.md) records the
already completed attended existing-service update and final postflight at
2026-09-09 20:59:04 UTC. This GitHub-persistence task performs no deployment,
synthetic host writes, phone action, reset, merge, release or settings change.
Rollback is old compatible code on the **same current data**, never stale restore.
Co-resident backup keys do not provide host-loss or compromised-host protection.

## Full independent reviews and provenance

These reports are byte-exact text exports, not rewritten summaries. Their historical
statements such as “not deployed” describe their review time, before the dated
rollout. `.txt` preserves their original formatting without altering report bytes.

1. [Final product/APK/bundle review](fable-final-review.md.txt): PASS, deployment
   conditional on script disposition and DEPLOY-GATE-1 diagnostic.
2. [Orchestration review](fable-scripts-review.md.txt): two low findings ORCH-1/2,
   plus informational ORCH-3 manual-disposition requirement.
3. [Bounded closure](fable-deploy-closure-review.md.txt): PASS; diagnostic condition
   and ORCH-1/2 closed. ORCH-3 remains deliberate manual control.

[Model provenance](review-model-provenance.json) preserves actual success fields,
independent session IDs and complete modelUsage, including `claude-fable-5` and
small CLI `claude-haiku-4-5-20251001` helper usage. It records original raw JSON
hashes, not a claim those omitted raw JSONs are in Git. Incomplete max-turn and
failed-resume attempts are not approvals. AI review is not qualified human audit
or permanent decision-owner acceptance. [Copy provenance](copy-provenance.json)
binds exported originals byte-for-byte.

## Actual test evidence, separate from GitHub CI

| Check | Historical execution outcome |
| --- | --- |
| Clean native/signing | 17 retained + 4 new PASS |
| Server realtime | 14 PASS |
| Retained server | 55 PASS; conditional prior APK separately PASS |
| Final APK routing | Exact 3,031,545 bytes PASS |
| Populated v7 continuity | PASS; exact pending ciphertext, identity/history and reopen |
| Android35 emulator | 10 checks PASS; physical phones NOT RUN |
| Original packaged sequence | **13 PASS / 1 FAIL**, readiness cause **UNKNOWN** |
| Follow-up diagnostic | Four focused passes, full order PASS, requested diagnostic 11 PASS |
| Orchestration correction | Actual two-test RED, then 22-test GREEN |
| Historical pre-v7 | **27 PASS / 14 FAIL Rust + 2 FAIL JVM**, unchanged from v7 |

The original readiness failure is **not fixed by subsequent passes**. Closure
satisfies a bounded attended-deployment diagnostic condition, not an unattended
availability guarantee. See [selected packaged records](packaged-tests-selected.json),
[original-order diagnostic log](gate1-diagnostic/full11.log),
[RED](remote-runner-orch12-red.log), [GREEN](remote-runner-orch12-green.log),
[native log](core-clean-final-candidate.log),
[server result](server-final-validation.json),
[exact APK log](final-apk-server-bytes.log) and
[unchanged historical outcomes](historical-comparison.json).

| Measured boundary | Samples | P50 ms | P95 ms |
| --- | ---: | ---: | ---: |
| Optimized v7 local serial-sync baseline | 20 | 3043.98 | 3057.50 |
| Exact final local TLS/PG/JNI | 24 | 102.94 | 122.01 |
| Exact final external endpoint Java/JNI | 12 | 76.51 | 85.74 |

[Baseline samples](baseline-release-final/latency-baseline.json),
[final local samples](final-realtime-fixture/latency-samples.json),
[local context](final-realtime-fixture/realtime-fixture-result.json),
[external result and samples](hosted-final-acceptance/result.json).
Nearest-rank percentiles end at durable receiver commit/listener, **not phone
rendering**. The final local fixture adds a pinned TLS proxy hop; v7 excludes its
production polling wait. No physical OPPO benchmark, installation/upgrade, camera,
accessibility-service, OEM background, Doze/force-stop or battery result is claimed.

## Reproduce and resume safely

From repository root, run the offline provenance check:

```sh
python3 docs/project/evidence/overnight-realtime-20260909/verify.py
```

Product test/build commands and prerequisites are in the
[runbook](../../../operations/overnight-realtime.md),
[Android README](../../../../clients/android/README.md),
[server README](../../../../server/README.md) and
[deployment README](../../../../deploy/README.md). Examples:

```sh
cargo test --locked --manifest-path clients/core/Cargo.toml --test clean_first_contact
cargo test --locked --manifest-path clients/core/Cargo.toml --test realtime_signing
python3 clients/android/test_realtime.py --help
python3 server/check-realtime.py
```

Use fresh isolated local test directories, not retained host/phone state. Packaged
checks need `PARANOID_TEST_PACKAGED=1` plus exact candidate/old release paths as
specified by the runbook. Do not rerun the completed remote transaction or reuse
its private synthetic keys to reproduce results. Local historical test evidence
is not GitHub CI success: consult the draft PR's actual check runs. No test
expectations or runtime code were changed during persistence to appease CI.
