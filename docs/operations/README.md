---
status: draft
owner: operations
last_reviewed: 2026-09-09
---

# Operations documentation

The [voice local record](voice-calls-local.md) tracks the post-PR18 client
implementation, completed design/native/JNI and actual direct/isolated-relay media
checks, with final inset UI and signed APK checks passing; final review remains pending. The [bounded relay proposal](voice-turn-request.md)
records the local proof and missing production credential work. Neither document
authorizes live TURN/firewall/DNS or existing-server changes.

Operational design is part of the product because simple, safe self-hosting is a
core requirement.

## Infrastructure access

- [Production SSH access](production-access.md): owner-provided host inventory,
  temporary-agent procedure, read-only verification evidence, and authority limits.

## Deployment documentation

The [actual 2026-09-09 self-service v2 rollout](self-service-v2-rollout-2026-09-09.md)
records the later explicitly authorized successful installation, independently
closed FPD-D01, exact artifact, one-time old-data-only discard, retained TLS/unit/
neighbors, and real pinned HTTPS/SQL readiness. The existing unit is running v2;
phone acceptance and optional Android feed publication remain separate.

The [fresh self-service v2 candidate](fresh-self-service-v2.md) records the scoped
owner correction: replace only the old isolated server DB in place without backup
or legacy import, preserving TLS/phones/neighbors. Explicit mode, local tests and
preparation-time commands are historical; the dated rollout above records execution.

The [native private-alpha runbook](linux-alpha-deployment.md) accompanies the
locally exercised package (RFC-0009, draft ADR-0005), not a hosted deployment.

The [key-registration local runbook](key-registration-local.md) records the
explicitly authorized local APK/server candidate, operator-only admission and
isolated migration/restore tests under RFC-0010/proposed ADR-0006. It is not a
live migration procedure or permission to change the hosted alpha.

The [key deployment rollout runbook](key-deployment-rollout.md) records the
locally tested migration-capable package and recovery restrictions under
[RFC-0011](../rfcs/0011-key-deployment-migration.md). The
[2026-09-09 authority](key-rollout-authorization-2026-09-09.md) permits only the
reviewed isolated two-phone rollout; this index does not claim it has occurred.

Every supported deployment profile must eventually include:

- prerequisites and one-click or guided installation;
- architecture and trust boundaries;
- configuration reference with secure defaults;
- upgrade, downgrade, migration, and rollback procedures;
- backup, restore, disaster recovery, and restore-test evidence;
- capacity planning and performance limits;
- health checks, logs, metrics, alerts, and privacy-safe diagnostics;
- certificate, key, secret, and administrator lifecycle;
- federation troubleshooting and isolation procedures;
- incident runbooks and post-incident review template;
- supported versions and end-of-life policy.

Runbooks are verified through exercises. A runbook that has never been executed is
a hypothesis, not an operational guarantee.

## Clean-install first-contact local candidate

[Local testing and APK record](clean-first-contact-local.md) covers the authorized
clean core/JVM/JNI/TLS/PostgreSQL build, separate historical test accounting,
retained signer and independent review gate. It is not a live rollout or phone
reset/installation procedure.

## Overnight realtime implementation and rollout

[Overnight realtime operation](overnight-realtime.md) records the private-alpha
scope, review/test requirements and same-data recovery procedure. The
[actual realtime rollout](realtime-rollout-2026-09-09.md) records completed
independent review/closure, encrypted verified backup, preserved existing service
and hosted messaging acceptance, including the unresolved original readiness
failure and physical-device limits.
No permanent architecture acceptance or physical-phone result is implied.

## Local voice relay candidate

[Server evidence](../server/voice-turn-local.md) and the [offline relay runbook](../../deploy/turn/README.md)
describe local implementation, checks, exact proposed network scope and rollback.
No new public listener or existing-server change has been performed.
