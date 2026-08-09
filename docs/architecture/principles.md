---
status: proposed
owner: architecture
last_reviewed: 2026-08-09
---

# Architecture principles

These principles guide proposals but are not a substitute for ADRs.

1. **Self-hosting is a primary deployment model.** Managed hosting must use the
   same core artifacts and protocols where practical.
2. **Local operation is a first-class scenario.** Internet-dependent services
   must have documented behavior when unreachable.
3. **Trust is explicit.** Every server, device, plugin, administrator, federation
   peer, chain, and recovery path has named capabilities and failure modes.
4. **Cryptography is composed from reviewed protocols.** Custom cryptographic
   primitives are prohibited; protocol choices require specialist review.
5. **Contracts are versioned before scale.** Wire formats, events, APIs, storage
   migrations, and plugin capabilities declare compatibility behavior.
6. **Secure defaults beat configuration advice.** A simple deployment should not
   require an expert to discover critical hardening steps.
7. **Metadata is part of the privacy model.** Threat analysis includes timing,
   graph, federation, notification, media, and blockchain metadata.
8. **Extensions are least-privileged.** Plugins receive narrow, inspectable,
   revocable capabilities and cannot silently bypass encryption boundaries.
9. **Operational recovery is designed, tested, and documented.** Backup, restore,
   key rotation, device revocation, upgrades, and rollback are product features.
10. **Replaceability is valuable.** Foundational components sit behind explicit
    contracts so evidence can justify changing them without rewriting the product.
