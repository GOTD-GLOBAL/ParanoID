---
status: draft
owner: product
last_reviewed: 2026-08-09
---

# Glossary

## Canonical terms

**Account**
: A user's durable identity and associated authorization state. Its exact
  relationship to seed material, devices, servers, and blockchain records is not
  yet specified.

**Device**
: A client installation authorized to act for an account. Device keys must not
  be assumed to be identical to recovery or blockchain keys.

**Federation**
: Controlled communication between independently operated ParanoID servers.
  Federation does not imply shared administration or universal trust.

**Home server**
: A server selected by a user or organization for messaging services. Whether an
  account has one authoritative home server is undecided.

**Identity registry**
: The blockchain-backed mechanism intended to associate human-readable names
  with cryptographic control. Chain and data model are undecided.

**Nickname**
: A human-readable identifier intended to be anchored in the identity registry.
  Display names that are not unique must be documented separately.

**Paranoid mode**
: The initial seed-only account ownership and recovery mode: loss of recovery
  words means loss of the account.

**Plugin**
: An optional extension that receives explicitly declared capabilities. A plugin
  is not automatically trusted merely because it runs inside a ParanoID product.

**Server**
: A self-hosted or managed ParanoID service instance. Its precise responsibilities
  will be defined by the architecture.
