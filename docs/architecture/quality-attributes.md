---
status: draft
owner: architecture
last_reviewed: 2026-08-09
---

# Quality attributes

Architecture proposals must compare designs using measurable scenarios, not only
feature lists. Targets below remain to be negotiated.

| Attribute | Scenario to specify | Target |
| --- | --- | --- |
| Security | A device is stolen while the account seed remains safe. | TBD |
| Privacy | A server or federation peer attempts to infer conversation content and graph. | TBD |
| Availability | A home server loses public internet but the local network remains available. | TBD |
| Recoverability | An administrator restores a failed server from a verified backup. | TBD |
| Deployability | A non-specialist provisions a secure server on a supported host. | TBD |
| Compatibility | Two supported adjacent protocol versions federate during a rolling upgrade. | TBD |
| Performance | A mobile client synchronizes a defined message history over constrained bandwidth. | TBD |
| Scalability | A server handles defined concurrent users, rooms, calls, and media traffic. | TBD |
| Portability | An operator migrates between supported hosting providers without changing user identity. | TBD |
| Auditability | A reviewer traces a security-critical behavior to a requirement, decision, code, and test. | TBD |
| Accessibility | A user completes critical messaging and recovery flows with assistive technology. | TBD |

Every accepted target must define environment, workload, measurement method, and
failure threshold.
