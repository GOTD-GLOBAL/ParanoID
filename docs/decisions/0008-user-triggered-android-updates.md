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

## Proposed size-ceiling amendment (2026-09-13)

The owner's new direction and threat/resource/migration analysis are recorded in
[RFC-0013](../rfcs/0013-user-triggered-android-updates.md#owner-amendment-no-fixed-apk-size-ceiling-2026-09-13).
Remove the fixed APK ceiling on both components, retaining positive signed-long
size representation, exact length/hash/signature checks and bounded streaming
buffers. Server snapshots move payload storage from heap to anonymous private
disk, with two-response concurrency and space checks. Client checks available
cache space and retains failed-download cleanup. Metadata remains bounded.
Separate server/client PRs and a legacy-compatible bridge precede larger releases.
This ADR remains draft: Telegram implementation direction is not permanent
architecture approval, release/merge permission or phone acceptance.

## Scoped maintenance reconciliation proposal (2026-09-13)

The owner explicitly requested checking/fixing the observed server-package blocker
and completing deployment. [The one-off operational RFC](../rfcs/apk-cap-maintenance-reconciliation.md)
records exact evidence-bound reconciliation of already performed FCM enable and
same-key TLS renewal, original before-image preservation, annotations, crash
recovery and unchanged original preflight. It adds no generic drift bypass,
permanent architecture acceptance or permission to alter live trust/data.
This ADR remains draft; the operation requires fresh independent review.
The subsequent [optional push-schema backup correction](../rfcs/apk-cap-push-backup-recovery.md)
records the actual safe rollout failure and a bounded fix preserving complete
schema comparison, token backup verification and failed-transaction evidence.

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
