---
status: draft
owner: operations
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Actual realtime private-alpha rollout — 2026-09-09

## Outcome and authority

**The reviewed same-data update and actual hosted messaging acceptance passed.**
Release `3ed25173ad978e6b417c` is running on the existing isolated endpoint
`https://157.180.49.125:38443`. Final postflight after hosted acceptance passed at
2026-09-09 20:59:04 UTC. This is private synthetic-data alpha evidence, not
physical-phone acceptance, public release, human security audit or permanent ADR
approval. RFC-0015 and ADR-0010 remain proposed.

The [current owner scope](../product/overnight-realtime.md) explicitly authorized
the signed APK and attended existing-service deployment after independent review,
real tests and safe rollback readiness. Exact supplied instructions remain in the
external evidence record; no permanent message permalink is invented. This update
preserved current data. It does not renew the earlier
[one-time old-data discard](self-service-v2-rollout-2026-09-09.md).

The target was only `paranoid@157.180.49.125`, root
`/home/paranoid/paranoid-alpha`, unit `paranoid-alpha.service`, PostgreSQL system
ID `7683525211206671315`. No phone action, feed publication, merge, firewall/DNS
change, credential change or neighboring-service mutation was performed.

## Exact source, artifacts and independent review

The authoritative build source is the immutable 254-file `final-source/` copy in
the evidence directory below. Manifest SHA256:
`0f6d0689cefd7eac1a61bddc296054fbddc09dc0d06795a832779f785c314f2e`.
The build includes preserved initial dirty work and the overnight delta; Git HEAD
alone does not describe its inputs. Postbuild documentation updates have a separate
snapshot/manifest and never replace the compiler-input manifest or imply a rebuild.

| Artifact | Exact identity |
| --- | --- |
| Server release | `3ed25173ad978e6b417c` |
| Server tar SHA256 | `2306c0a8c35e2d9e42e15a507d1825df7c2f3e6c115bf1823176817aaf4630f0` |
| Running server binary SHA256 | `bf74a9634f20163ac7254af9c0876bd6c9ff7e60cd77253503cc598deeb22fa2` |
| Controller SHA256 | `c706b5dc9bf03371bbc6b4d72fa84417d9e81618579c26a920d07369b2298f9e` |
| Release manifest SHA256 | `7fbc031b6f669e52c92c759963c6d23395b26f4718334a2249fbee29400326c7` |
| Android APK | `paranoid-0.0.8-realtime-arm64.apk`, 3,031,545 bytes |
| APK SHA256 | `1b9f44d88011f0a8e4aa454e4df890c0a6872190a8606d1b590e8d942e42eadb` |
| APK package/version | `org.paranoid.devtext`, versionCode 8, `0.0.8-realtime`, ARM64, min API 26 |
| Retained signer SHA256 | `82b29cc029b186cb7ac404a02408d0c99e214ab18062200d1f27365ee89c5926` |

Fresh `claude-fable-5` product review, separate execution-script review and bounded
DEPLOY-GATE-1/ORCH-1/ORCH-2 closure all succeeded before the private execution gate
was created. Raw results retain actual model usage. The first review's maximum-turn
failure and unsuccessful exact-session resume remain recorded and were not treated
as approvals. The completed final review and closure inspect these exact unchanged
products, actual tests and the corrected execution scripts. AI review does not
supply permanent human decision-owner acceptance.

## Executed update and preservation

The reviewed action sequence was gate check, stage, start, status until `complete`,
postflight, two-synthetic-peer acceptance, then final read-only postflight. The
worker started at 20:56:09.211981 UTC and completed at 20:56:11.645058 UTC, controller
exit 0. Its transaction elapsed **2.433077 seconds**; outage duration was not
continuously measured. SSH return alone was never counted as completion.

The controller stopped only the dedicated unit, generated an AES-GCM encrypted
backup, fully authenticated/decrypted it and restored to a new isolated verifier
database. Exact schema and ordered row digests/counts matched across all six
tables before the current pointer selected the new release on the same database.
The successful exact verifier also checked the retained old release's eight
allowlisted files for rollback; postflight stdout does not repeat that hash list.

The retained backup is `v2-20260909T205610Z-40b3610731f32523`, 22,140 encrypted
bytes, archive SHA256
`4f0df3bf58e042a9d80a9f0f0ddc350cb5a16f8a21b03dd794973479977c707d`.
Verification database: `verify_v2_344afced6a9041e9`. The verified pre-cutover table
counts were room_state 0, ss_meta 1, ss_accounts 4, ss_devices 4,
ss_conversations 2 and ss_messages 5. These are backup-time counts, not current
traffic counts. Only aggregate metadata was exported; backup keys, archives,
private TLS material and raw user rows were not copied into evidence.
Postflight checks the verified backup's aggregate metadata, not the latest row
contents. Hosted acceptance subsequently added its two synthetic identities and
messages; no post-acceptance whole-database row-count/digest equality is claimed.

Final postflight observed active/running and enabled `paranoid-alpha.service`,
supervisor PID 1966827 and server PID 1966908 with the exact binary hash above.
Health returned protocol `paranoid-self-service-v2`, status `ok` and realtime
`signed-long-poll-v1`. The PostgreSQL system ID remained `7683525211206671315`.
Configuration, unit and certificate hashes matched the reviewed preflight; unit
limits and TLS identity were retained. Origin and SPKI remained unchanged:
`sha256//iqWUqRSPYQ2p3mcdfHrnxpDmceU+sOijuTG+64iJcLo=`.
Scoped Nginx, Docker and shared PostgreSQL service states, MainPID fields and
activation timestamps matched preflight. This records those exact comparisons,
not a probe of every unrelated process.

The retained old release `346f059914a290be4851` and current data remain available
for [the reviewed same-data rollback](overnight-realtime.md#existing-service-rollout-and-rollback).
No live rollback was needed or exercised. Real local systemd failure/signal tests
verify code rollback while preserving newly accepted messages. Never restore a
stale dump over current history or repeat fresh/replace operations. The DB backup
uses a co-resident host key; it is not off-host disaster recovery. Existing backups
and verifier databases were retained; no retention cleanup was authorized.

Preflight imported the controller once and created a new bytecode cache in the
old release. The exact generated file and then-empty directory were removed with
recorded provenance, restoring the prior release before the update. This is
disclosed in `preflight-cache-restoration.md`; the entire preflight is not described
as mutation-free. Subsequent remote Python used bytecode suppression.

## Actual messaging, latency and retained tests

The hosted runner used exact product Java and optimized host JNI against the
actual endpoint, direct pinned TLS, no proxy or remapped trust, and exactly two
new synthetic identities. Automatic registration, one-way QR encode/decode and
contact pairing, zero-contact first incoming text, reply and genuine receipts
passed. Both peers had active signed sessions/event requests. Process stop/reopen
created new sessions and preserved messaging. Wrong-pin TLS failed; unauthenticated
session/event requests returned 401. Camera capture was not tested by the QR check.

Twelve alternating hosted sends measured **P50 76.50962 ms / P95 85.743713 ms**
(nearest rank). Timing starts at the product JVM/JNI send call before state-owner
submission and ends at receiver listener notification after encrypted durable
snapshot commit. The 500 ms cadence after the preceding receipt lies outside the
timed interval. This is actual hosted-network evidence, not Android display-frame
or physical-phone latency.

Separately, optimized local v7 measured P50 3043.98/P95 3057.50 ms for 20 messages;
the exact final local realtime fixture measured P50 102.94/P95 122.01 ms for 24.
Both use real pinned TLS/PostgreSQL/JNI, with the realtime local proxy adding a
second verified TLS hop. Early debug JNI around 600 ms P50 failed the target and
is retained. The hosted and local samples describe different network paths.

Actual populated-v7 core3/sealed4 producer-to-final-process continuity passed for
identity, contacts, verification/blocking, history, queued immutable ciphertext,
owed receipts and reopen. Server realtime tests passed 14/14, retained server
tests passed 55/55, and the conditional exact final APK byte test passed separately.
Ten actual Android 35 emulator checks passed, with 54 screenshot/XML pairs,
including keyboard/focus, message/receipt behavior, notification permission and
visible foreground connection. Emulator fixture APKs used isolated loopback trust
and version 7; they are not the final ARM64 phone artifact.

The first exact packaged sequence remains **13 PASS / 1 FAIL**: standalone
TLS/database readiness failed with cause **UNKNOWN**. Four focused reproductions,
one full 11-test capture and exactly one requested Gate1 full 11-test diagnostic
passed without weakening assertions or changing product/timeout values. Gate1
recorded PostgreSQL readiness at 73.674 ms for the candidate and 75.619 ms for the
retained old runtime, matching owned PID files and clean shutdown. Independent
closure accepts this observed condition only for attended deployment with reviewed
same-data recovery. It does not claim a fix or prove the failure cannot recur.

Unchanged historical core tests remain 27 PASS/14 FAIL and both old JVM smoke tests
fail with the same v7 outcomes. They are preserved separately, not relabeled as
passing. No physical-phone install, rendering, camera, accessibility-service,
Doze/force-stop or battery result is claimed. Voice, provider push, federation and
a second live server remain unimplemented or outside this acceptance scope.

## Durable evidence and documentation provenance

Evidence root:
`/home/codex/paranoid-self-service-evidence/overnight-realtime-20260909T191524Z`.
The following retained files are relative to that private external root; they are
not repository-relative links or publications of private test state:

- `live-deployment-result.json`: normalized actual outcome, original action paths
  and hashes; `live-update-actions/` retains unmodified stage/start/status and both
  postflight records, including the final observation at 20:59:04.102079 UTC.
- `live-deployment-audit.json`: independent local cross-check of retained action,
  preservation and artifact evidence; it performs no additional live operation.
- `hosted-final-acceptance/result.json`: actual samples and checks;
  `post-acceptance-artifact-source-check.json` rechecks all 254 frozen/integration
  inputs plus APK/tar before these postbuild documentation edits.
- `fable-final-review.md`, `fable-scripts-review.md` and
  `fable-deploy-closure-review.md`: successful final reviews and bounded closure;
  adjacent raw result/process records retain unsuccessful attempts and model usage.
- `final-apk-result.json`, `final-server-result.json` and
  `final-source-sha256.json`: exact build identities. Their build-time pending
  fields are historical; the later normalized deployment/review records establish
  completion without changing artifact bytes.
- `final-v7-continuity/continuity-result.json`,
  `final-realtime-fixture/realtime-fixture-result.json`, `server-final-validation.json`,
  `final-apk-server-bytes.log`, `ui/actual-ui-result.json` and
  `historical-comparison.json`: tests and their distinct acceptance boundaries.
- `final-packaged-deploy-tests/result.json` and `gate1-diagnostic/HANDOFF.md`:
  original failure retained alongside subsequent diagnostic evidence and closure.
- `postdeployment-docs/` and `postdeployment-docs-sha256.json`: separate original
  document copy, task-only diff, updated-document copy, hashes and documentation
  checks. They do not replace immutable `final-source/` or change what was built.

Initial dirty sources, accepted historical ADRs and earlier rollout history remain
preserved. The old asymmetric RFC-0013 proposal body remains intact under RFC-0016,
with the historical alias retained; updater RFC-0013 and proposed decision statuses
are unchanged. Further public/sensitive-data scope requires the canonical review
and authorization process. This record adds no new live action.
