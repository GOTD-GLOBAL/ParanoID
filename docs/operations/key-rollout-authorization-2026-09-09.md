---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Bounded key-registration rollout authority

In the current Telegram conversation Sergey Maltsev answered "Разрешаю" to the
explicit request to prepare and independently verify a history/key-preserving
migration update, update only the isolated ParanoID deployment, approve exactly
the two labelled phone credentials he supplied, and return public approval QR.
This supersedes the earlier task's prohibition on live deployment only within
that exact boundary. It is not blanket production/security/architecture acceptance,
merge permission, or authority to modify neighboring services, firewall or secrets.
No Telegram permalink is available in this tool context; no GitHub approval link
is fabricated. ADR-0006 remains proposed pending its canonical evidence workflow.

Scope: existing dedicated ParanoID service/root on 157.180.49.125, unchanged
public IP HTTPS port 38443, TLS key/pin, existing application identity/history;
two known labelled public phone requests, one device per account. Inputs are held
outside Git in a private local evidence directory, not published in repository.

Before any live cutover: strict TDD for migration/support changes, real populated
local TLS/PG/JNI and restore/rollback checks, fresh independent security review,
verified artifact, scoped read-only current-host inventory and source-consistent
restricted backup/isolated restore. Preserve exact post-cutover history; never
restore a stale dump or reactivate bearer after key-only activation. If no safe
compatible rollback exists, stop with retained data rather than reset identity.

This file records authorization and gates, NOT deployment completion. No live
mutation has been performed at the time this record was created.
