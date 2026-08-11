---
status: draft
owner: protocol
last_reviewed: 2026-08-11
---

# Protocol documentation

No ParanoID protocol has been selected or specified.

Identity, registration, and authentication are under discussion in
[RFC-0002](../rfcs/0002-identity-registration-authentication.md). The RFC is not
a normative protocol and must not be implemented as an accepted contract until
its open questions are resolved and an ADR is accepted.

Future protocol documentation must be normative and versioned. It must define:

- identity, device, key, and recovery state machines;
- message envelopes, ordering, retries, deduplication, expiry, and synchronization;
- group membership and cryptographic epoch behavior;
- media, voice-message, call-signalling, and real-time transport contracts;
- federation discovery, authorization, routing, policy, and abuse handling;
- offline, partition, conflict, and clock-skew behavior;
- error codes, limits, canonical encoding, and extensibility rules;
- version negotiation, compatibility, deprecation, and test vectors.

Normative schemas and test vectors must live beside this documentation. Narrative
examples do not replace executable conformance tests.

The current
[key-hierarchy vector](../../specs/protocol/identity/key-derivation-experiment-v1.json)
is explicitly experimental and non-normative. Its scope, results, and limits are
recorded in [EXP-IDENTITY-0001](../experiments/identity-key-hierarchy-0001.md).
The provisional HKDF candidate is independently exercised at the Kotlin
Multiplatform boundary by
[EXP-IDENTITY-0002](../experiments/identity-mobile-conformance-0002.md). Neither
experiment declares a production identity protocol.
