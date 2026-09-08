---
status: draft
owner: protocol
last_reviewed: 2026-09-08
---

# Protocol documentation

No normative ParanoID protocol has been accepted. The draft
[single-server acceptance matrix](server-v0-acceptance.md) maps the proposed
text/history/reconnect behavior to future tests; it is not a wire specification.

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
