---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Authorized key-registration rollout, 2026-09-09

Authority: [bounded owner approval](key-rollout-authorization-2026-09-09.md).
This is a private two-known-phone alpha, not production architecture acceptance.
ADR-0006 remains proposed. Real phone activation/messaging is not yet claimed.

## Executed and verified

- Strict SSH as the dedicated `paranoid` account used the retained encrypted-key
  pipe/temporary agent and existing host trust; no private key was exported.
- Initial retained service/root/TLS/DB health passed. Existing root is
  `/home/paranoid/paranoid-alpha`, PG system identifier `7683205479877615472`.
- Independent auth review found PG-lock lifetime and idle TLS occupancy defects;
  [final deployment review](../reviews/2026-09-09-final-deployment-review.md)
  independently verified both corrections and the migration/restore/rollback path.
- Exact reviewed release `618a684d9084e05cc2fc` was transferred and all seven
  regular members/component hashes/ABI dependencies verified on the host.
- Only `paranoid-alpha.service` was stopped. Reviewed `migrate-key` verified the
  actual schema, created a restricted backup, restored it into an isolated DB and
  compared original rows before sticky configuration/schema/pointer cutover.
- At 05:25:48 UTC migration/private health passed. Original token/IP values,
  TLS key/certificate/unit bytes, PG identity and message/room rows were preserved.
  Nginx, Docker and existing PostgreSQL service state/PID/start times were unchanged.
- Backup: `backups/20260909T052547Z-a2fe2666`, 4059-byte dump, restored database
  `verify_35d008ef01a34f4e`, exact rows verified. Identity copies stay private on host.

## External ALPN correction and final service

Default external curl exposed h2 advertisement against an HTTP/1-only handler;
explicit HTTP/1 worked. This was not hidden as successful generic connectivity.
A local failing TLS negotiation regression reproduced it. A key-mode-only ALPN
restriction preserved certificate/key/TLS policy; independent focused review and
repeated packaged JNI E2EE tests passed before the compatible update.

Final release: `007fd1812c0dbba9a489`.
Archive SHA256: `36bbd35237a34d314cefd130e562a84dd6803f2cf240d464dfccd1c4cd090df4`.
At 05:39:38 UTC the reviewed same-schema update/private health passed. All four
current tables, original config/TLS/unit bytes and PG identity were preserved.
Backup `backups/20260909T053936Z-6ccde09d` was independently restored into
`verify_3103bdf29c51df17`; all four tables matched. Dump size 8883 bytes.
The observed service MainPID was 586547, active. No firewall, neighbor, user-unit
configuration, app identity or phone data change occurred.

External default curl now passes exact CA/IP/SPKI validation: health 200,
unknown `/v1/auth/challenge` 401, unauthenticated `/v1/messages` 401; wrong SPKI
fails before HTTP. Public endpoint and SPKI remain unchanged from the phone inputs.

## Two phone approvals

The two user-labelled public requests were independently signature-checked and
explicitly mapped by the operator to slots 0/1, never a first-free-slot allocation.
Reviewed `key-admin-approve` issued only those exact credential/Olm bindings.
Both database records were read back as `approved`. Public approval JSON/QR were
created and ZXing-roundtrip-checked for delivery. Private device keys remain only
on the phones; the server cannot activate them without their signed proof.

These grants expire at 05:56:43 UTC unless redeemed; expiry affects unused grants,
not the retained local identity. Do not reset/reinstall phones if a grant expires.
No phone activation, contact verification, actual two-phone text exchange, Android
Keystore crash test or physical camera acceptance is claimed by this record.

## Evidence and restrictions

Full nonsecret local execution logs are in
`/home/codex/paranoid-key-rollout-evidence/`: `host-before.json`,
`host-stage.json`, `host-migration-result.json`, `host-alpn-update-result.json`,
`host-external-final.log`, independent review/runtime/restore logs and public
phone approval records kept outside Git. Backups include private config/TLS copies;
never transfer them without encryption. No stale restore or bearer-only downgrade.
No merge or release was performed. A later phone response must confirm activation
and end-to-end delivery; successful server health is not that evidence.
