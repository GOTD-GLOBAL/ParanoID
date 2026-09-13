---
status: draft
owner: operations
last_reviewed: 2026-09-13
---

# APK-cap server rollout: blocked preflight, no deployment

Historical initial observation. The subsequent owner-authorized correction,
safe failed-attempt rollback and successful deployment are recorded in
[the completed rollout](apk-cap-rollout-2026-09-13.md). Do not read the initial
blocker below as the latest runtime status.

## Authority and scope

Sergey Maltsev replied “Го” to updating the server and publishing a legacy-sized
Android bridge after PRs 32/33 merged. This authorizes that scoped rollout, not
ignoring identity drift, changing TLS trust, database reset or rewriting prior
acceptance evidence. Telegram permalink is unavailable in this tool context.
REQ-DEPLOY-002/003, REQ-MSG-004 and RFC-0013 safeguards remain required.

## Actual observations

- Canonical source: `2d91bd4dba79bd35f563e51850f2e18796a3c9ba`.
- Locked native release build succeeded. Prepared message release
  `ad6fa2d6e0c1864d2c81`, archive SHA256
  `ba170beab829aebbd73f6cf36a920798d4c346779dc500477c734e742a41ce98`.
- SSH used the existing pipe-to-agent credential and strict known_hosts. No key
  was printed, copied or persisted in plaintext.
- Host publication storage is disk-backed; observed available space 172G.
- Live message release remains `9e6549ecd92080e20fcc`; TURN and owned policy
  services were active. Public update feed was version25 at preflight.
- The original installed coordinator's `status --state
  /var/lib/paranoid-single-host` failed validation, before update/staging.
- Its read-only message worker found differences from recorded identity in
  **config_sha256, tls_cert_sha256 and unit_sha256**. Message release/manifest,
  PG system identifier, TLS key hash and SPKI were unchanged.
- The PG system identifier remains `7683525211206671315`. The current public
  SPKI remains `8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`.
- This is consistent with separately performed push configuration and same-key
  certificate renewal, but that hypothesis is not a complete drift audit.

## Boundary retained

No server code switch, service restart, journal rewrite, config/TLS mutation,
backup/restore or database write was performed for this attempted rollout.
The candidate archive was not uploaded or activated. Do not treat a successful
build or Android publication as successful server deployment.

## Required next action

Reconcile the current runtime with the original approved push/TLS operation
receipts and generated unit bytes, using a reviewed explicit adoption procedure.
Preserve the original transaction and acceptance evidence; do not overwrite
`current.json` merely to pass validation. A new or extended coordinator contract
requires scoped RFC/ADR and independent review. Re-run original identity,
network/unit and same-data preflight before attempting update, with the usual
verified encrypted backup/restore and current-data rollback gates. No
workaround through a different updater is authorized by this record.
