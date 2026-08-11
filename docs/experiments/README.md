---
status: accepted
owner: maintainers
last_reviewed: 2026-08-11
---

# Experiment log

Experiments produce reproducible evidence for unresolved RFC questions. They are
not production contracts and do not become architecture merely because code
exists.

Each experiment must state its question, linked requirements and RFC, inputs,
method, results, limitations, and the decision gate it informs. Generated
fixtures belong under `specs/` and must be checked by automated tests.

## Active experiments

- [Identity key hierarchy 0001](identity-key-hierarchy-0001.md): compares three
  deterministic BIP-39-to-Ed25519 derivation candidates for RFC-0002.
