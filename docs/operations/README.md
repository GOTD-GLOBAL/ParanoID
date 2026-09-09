---
status: draft
owner: operations
last_reviewed: 2026-08-09
---

# Operations documentation

Operational design is part of the product because simple, safe self-hosting is a
core requirement.

## Infrastructure access

- [Production SSH access](production-access.md): owner-provided host inventory,
  temporary-agent procedure, read-only verification evidence, and authority limits.

## Deployment documentation

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
