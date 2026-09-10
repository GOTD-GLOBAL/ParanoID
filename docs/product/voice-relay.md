---
status: proposed
owner: product
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice relay completion for issue 19

[Issue 19](https://github.com/GOTD-GLOBAL/ParanoID/issues/19) requests actual 1:1
encrypted voice after PR18. The direct owner task authorizes local implementation,
real tests, signing and component PRs. It expressly requires a fully implemented,
tested package and exact deployment request if new public ports are needed.
No stable Telegram permalink is available; no permanent decision approval is
invented. The direct-ICE client checkpoint is real implemented/tested work, but
its passing local relay instrumentation alone does not complete this requirement.

**REQ-CALL-006:** provide a locally tested, authenticated short-lived TURN
credential issuer, matching Android client integration and self-hosted coturn
package. Preserve existing text, identity, TLS and storage contracts. Supply exact
binary/config/unit/network scope and rollback before any deployment request.

Acceptance requires real PostgreSQL/session authorization and negative tests,
actual coturn accepting issued HMAC credentials and refusing expired/wrong
credentials, actual application E2EE calls using selected relay candidates with
decoded bidirectional audio, cancellation without capture, retained text latency,
source/artifact correspondence and fresh independent final review. Physical audio,
Bluetooth, Doze and mobile handover remain separate unmeasured limits.

[The canonical API](../protocol/voice-turn-v1.md),
[RFC-0018](../rfcs/0018-voice-turn.md) and
[proposed ADR-0012](../decisions/0012-voice-turn.md) precede implementation.
Server/package and Android changes have separate PRs under
[component boundaries](../project/component-boundaries.md). The Android PR must
reference the exact server foundation revision. Nothing authorizes changing the
live server, opening ports, firewall/DNS changes, operating phones or merging PRs.
