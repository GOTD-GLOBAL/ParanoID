---
status: draft
owner: operations
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-08
---

# ADR-0005: Native isolated closed-alpha deployment (not adopted)

## Proposed decision

Implement [RFC-0009](../rfcs/0009-isolated-linux-alpha-package.md): locked native
Rust server bundle, dedicated unprivileged systemd user service, PostgreSQL 16
private cluster/socket, direct Rustls IP TLS on 38443 and stable operator-provisioned
SPKI trust. Keep the original development gate; add explicit `closed-alpha-v0`
TLS-only mode, not a reverse-proxy bypass. Keep client E2EE and server history
unchanged. Same-schema updates and code rollbacks retain all live data.

## Scope evidence and disposition

Human risk/decision owner: martadvix-web. The
[owner's PR #14 authorization](https://github.com/GOTD-GLOBAL/ParanoID/pull/14#issuecomment-5587328763)
covers isolated test deployment after configuration, security and rollback checks
for two OPPO phones with non-sensitive data. This is not production architecture
acceptance. ADR-0003 is accepted; ADR-0004 remains draft historical development
proposal. No acceptance status is inferred for this new technical choice.
Independent fresh-context parent review is pending; no self-review is represented
as independent approval. This task made no production connection or change.

## Alternatives and consequences

Compose was considered; local Docker API is inaccessible. Native systemd avoids
invented container-test claims and reuses explicit PostgreSQL 16 prerequisites
without touching an existing database/service. Packaging PostgreSQL binaries or
installing packages implicitly would enlarge supply-chain/host scope. A reverse
proxy around the old loopback binary would violate its guard and was rejected.

The account/root can see admission credentials, TLS keys and metadata, not Olm
content keys. Retained dumps/restored verification DBs consume disk; no automatic
purge is permitted. Publisher signing, schema migration, PostgreSQL major upgrade,
remote boot/linger and real-phone acceptance remain separate gates. The alpha
request budget is global and can be exhausted by an attacker; TLS handshake and
network DoS are residual risks, not solved by E2EE.

## Validation and rollback

[Runbook](../operations/linux-alpha-deployment.md) and `deploy/test_integration.py`
map REQ-DEPLOY-001, REQ-MSG-004 and REQ-SEC-001 to native process/TLS tests,
authenticated readiness, durable retry, actual systemd restart and isolated
restore/data comparison. Roll back code through the same update command to a
retained schema-compatible release; never overwrite live history from a stale
dump. Failed update readiness attempts the previous release and reports failure.
