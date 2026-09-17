---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# APK-cap server rollout completed — 2026-09-13

## Actual result and authority

After the initial blocked attempt, Sergey Maltsev explicitly instructed:
“По серверному пакету чекни, что нужно сделай. Надо развернуть”. This authorized
checking/fixing the bounded blocker and completing the existing private-alpha
server rollout. It did not waive identity/schema/backup guards, authorize data
reset, or accept a permanent architecture. Original Telegram permalink unavailable.

The unchanged coordinator CLI completed update transaction
`612e99b23221727b28300c70663d7271` with phase **active**, **verified=true**.
The live message release is **9f37215d844b21abae3c** in kit
**cf434591c2dace39a8b2**. The actual running process executable hash matches the
independently checked package:
`ce2ae4ce6ac7649471b7ce40e044c50f8c7e2c7b7a9f777704c0d0f72b5d7fec`.
[Readback evidence](../project/evidence/apk-cap-rollout-20260913/verification.json)
records the observed process, identity and verified backup.

## Two blockers resolved without suppressing checks

1. **Existing authorized maintenance drift.** The original transaction's exact
   config/unit before-images proved only the FCM key and LoadCredential line were
   added. The new public certificate exactly matched the prior authorized same-key
   renewal. Release, manifest, PG, key and SPKI were unchanged. A reviewed,
   exact-hash-bound metadata reconciliation archived original records0400 and
   explicitly annotated later maintenance. Original coordinator status then
   passed unchanged. [RFC and scope](../rfcs/apk-cap-maintenance-reconciliation.md).
2. **Optional FCM table omitted from backup expectations.** The first actual
   kit12 update safely rolled back: the exact schema guard found the legitimate
   `ss_push_tokens` table, absent from base-only reference schema. Live schema-only
   comparison and a red local PG regression identified the same mismatch. The
   revised controller creates exact optional DDL only in the empty reference DB,
   retains full schema comparison and verifies push-token row counts/digests after
   encrypted restore. It does not alter application schema or ignore extra objects.
   [Correction and recovery scope](../rfcs/apk-cap-push-backup-recovery.md).

Failed transaction **8bbb341ef62a6d5440048983ce5367fe** and its journal remain
preserved, not relabeled success. A separately reviewed exact-failure-bound helper
verified the completed rollback and actual prior identity/network/units, archived
its pointer and selected the byte-exact active predecessor. Neither transaction
journal nor runtime was changed by that acknowledgment. The second update opened
its own new transaction through the normal CLI, including signal/recovery guards.

## Actual preservation and verification

- PG system identifier remained **7683525211206671315**.
- TLS private-key hash, certificate hash, SPKI and message unit hash are unchanged
  across the successful update. Config objects are identical; the standard worker
  normalized JSON serialization, so raw config bytes/hash need not be identical.
- Push and voice configuration remain enabled. Owned TURN and policy services are
  active; their relay/coordinator components are byte-identical to the prior kit.
- Before switching code, the controller created an encrypted backup, restored it
  into its new verification DB and compared full schema plus ordered count/digests
  for **all seven tables**, including messages and push tokens. Recorded snapshot:
  1236 messages and5 push-token rows. This is a dated snapshot, not a live count.
- Backup: `/home/paranoid/paranoid-alpha/backups/v2-20260913T175557Z-5a1ade65f513ca2e`;
  encrypted archive SHA256:
  `abc8c4a5b14d02b08644eb0c087c85b6fce4b2a41544d136cb6c20bac59ccfa5`.
  No raw token/key or plaintext backup was exported. No old dump replaced current
  messages. Private restore/reference DBs follow existing retention policy.
- Exact final packaged binary served **16,820,224 bytes** through local trusted
  TLS/private fresh PG, above the previous cap; size/hash matched. This was an
  isolated synthetic transport artifact, never placed on the public feed.
- After deployment, historical v25 updater code fetched the unchanged public v26
  feed/APK through the live pinned TLS origin and verified all16,443,022 bytes and
  SHA256 `2a00e8dbf2f4cc7bc7d6b9d34a174a6530d20abee9ea81ea7342d5ab8cc4bc1e`.

## Build, tests and independent review

Source: **4bfbd3b14b93c32b0ae439dedac2f77b88c9f1b8**, clean at final build.
Locked Rust1.98.1 and existing dependencies; final controller bytes equal reviewed
source. Kit manifest SHA256:
`304edb4199143529360675f7704a7a51ce937b4a211dbe319dbe748aa1954dc1`;
archive SHA256 `5ef951dbf989f54fa8980ee055301129e875e2fea535c9a214c2f4abd6445d20`.

- Eleven reconciliation metadata/crash tests and two restored-identity tests pass.
- Fifteen source and final-packaged maintenance tests pass with real private PG,
  encrypted restore, wrong-schema/changed-token rejection and SIGINT/SIGTERM cases.
- Independent AI reviews closed the preparation-interruption issue, approved the
  optional-schema/controller and rollback acknowledgment, then approved the exact
  artifact and prepare/verify wrapper. Final audit checked75 manifest entries and
  all42 archive files. Actual reviewer: gpt-6-astra, not Opus or a human audit.
- Root-host read-only proof, original preflight and exact reviewed plan passed;
  runtime mutation used only the original single_host.py CLI update operation.

## Test-count clarification — 2026-09-17

The fifteen dated maintenance tests above comprise fourteen `test_v2_update.py`
tests and one `test_v2_maintenance_interrupts.py` test (four signal/phase cases).
This clarifies the original scope; it does not add a retrospective execution claim.
New PR35 integration checks and their review are recorded separately in
[the integration handoff](apk-cap-pr35-integration.md).

## Limits and next steps

No physical-phone call/FCM-wake acceptance or reboot test was performed. Existing
service/autostart configuration was preserved; active/loaded checks are not an
actual reboot rehearsal. Android v26 was already published and did not change.
The original failed kit and previous release remain available; current-data
rollback must use the verified current controller, never restore an old dump.

The maintenance adoption/recovery helpers are one-off and exact-state-bound, not
an automatic future drift accepter. Later independent TLS/config maintenance may
again require reviewed coordinator integration until that separate lifecycle
contract is implemented. No status guard was weakened to hide that limitation.
Source/evidence remain in the normal PR review workflow; this operation does not
itself authorize merging PRs or marking draft RFC/ADRs accepted.
