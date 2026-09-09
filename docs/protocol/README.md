---
status: draft
owner: protocol
last_reviewed: 2026-09-08
---

# Protocol documentation

The [voice-v1 proposal](voice-v1.md) defines the implemented retained-channel
E2EE call controls and media fingerprint/ICE binding. Its independent design
closure and native/JNI tests are recorded; actual media and final-source review
remain separate gates. It adds no server route or accepted production protocol.

No normative ParanoID protocol has been accepted. The draft
[single-server acceptance matrix](server-v0-acceptance.md) maps the proposed
text/history/reconnect behavior to future tests; it is not a wire specification.

The [key enrollment v1 draft](key-enrollment-v1.md) narrows RFC-0010 admission,
request-proof and migration semantics. The historical key-registration candidate
is implemented; the contract remains non-normative.

The [self-service v2 draft](self-service-v2.md) specifies the locally implemented
RFC-0012 server routes, exact proof fields, limits, cursor/retry behavior and offline
transition. See draft [ADR-0007](../decisions/0007-self-service-messenger.md) and
[threat/test mapping](../security/self-service-v2-threats.md). Local server tests
do not establish client interoperability, phone acceptance or hosted v2 rollout.

The [first-contact v1 proposal](first-contact-v1.md) specifies mandatory
intro-v2/PlainV1 account-ID channels for the owner's clean-install private alpha.
It leaves [server v2 opaque transport](self-service-v2.md) unchanged and keeps
historical client migration/recovery outside this candidate's acceptance scope.

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

## Overnight realtime candidate

[Signed-session realtime contract](realtime-v1.md) records the current private-alpha scope and its exact review/test gates.
No permanent architecture acceptance or physical-phone result is implied.

## Voice relay credentials

[Voice TURN v1](voice-turn-v1.md) is the canonical proposed fixed signed-session
operation, strict response and consent/expiry contract for REQ-CALL-006.
