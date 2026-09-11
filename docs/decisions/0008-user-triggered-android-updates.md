---
status: draft
owner: architecture
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# ADR-0008: User-triggered signed Android updates

## Context and proposal

Sergey requests downloading updates from inside ParanoID rather than receiving
every APK in Telegram. [RFC-0013](../rfcs/0013-user-triggered-android-updates.md)
records supplied user direction, the proposed wire contract and security gates.
This record is **draft**, not acceptance or live publication permission.

Recommend explicit user-triggered update checks and downloads from the already
pinned HTTPS origin. Verify bounded metadata, immutable digest-named APK hash/size,
actual package/version/compatibility and continuity with the installed signer;
then invoke the standard Android installer with a narrow read-only URI grant.
Retain `global.paranoid.messenger` package/signing identity from v14 onward,
all app state and mandatory Android confirmation. The owner-directed v14 rename
from `org.paranoid.devtext` creates a separate Android application; it is not a
cross-package in-place update or authorization to erase or transfer old state.
This 2026-09-11 naming clarification does not accept this draft decision.
Initial installation of the APK containing Update still needs an external handoff.

Alternatives: keep Telegram-only manual distribution (fails requested convenience);
open arbitrary browser downloads (weakens source/version binding); background or
silent installation (unrequested and bypasses platform consent); full update
framework/TUF (future hardening, not this bounded private-alpha implementation).

## Consequences, review and rollback

The updater adds supply-chain, untrusted metadata/APK and URI-provider boundaries.
TLS pin and signer continuity do not protect against a compromised signing key or
a server withholding updates. No production secure-update claim, key rotation,
mandatory upgrades, Play-store compliance or automatic rollback is implied.
Failed download/install leaves the current application and its data intact. Do
not downgrade APK versions, clear phone state or replace trusted pins to recover.

Independent review of the client, provider/permission, distribution server and
artifact provenance precedes use. Required owner disposition and permanent evidence
remain pending under accepted ADR-0001/0003 and governance policy. User's product
request is provenance, not a fabricated permanent GitHub architecture approval.
No accepted historical ADR is rewritten. No installation/deployment result is
claimed by this proposed decision.
