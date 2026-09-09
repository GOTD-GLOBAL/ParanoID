---
status: proposed
owner: client
decision_owner: martadvix-web
review_mode: closed-alpha-ai
last_reviewed: 2026-09-09
---

# ADR-0009: Clean-install signed first-contact account-ID channel

## Proposed disposition and authority

Adopt the deterministic mandatory signed channel in [RFC-0014](../rfcs/0014-first-contact-incoming.md)
and [first-contact v1](../protocol/first-contact-v1.md) for the bounded private
synthetic-data Android alpha, all new text and receipts, fresh app installations.
Human decision/risk owner is martadvix-web. The current 2026-09-09 Telegram
implementation task reports the selected first recommendation and clean-install
amendment; its exact excerpt is in RFC-0014 and REQ-MSG-005. The earlier approval
message/permalink has not been independently retrieved in this context. This ADR remains **proposed**; there is no
invented `approval_record`, accepted status or completed RFC.

The direct current instruction authorizes local implementation, actual TDD and
isolated tests, and an APK build before independent code review. It excludes
publication/delivery/deployment/SSH/live database/phone actions. Historical
message preservation, migration and recovery are not this candidate's release
gates; historical failed tests remain visible and are not claimed fixed.

## Context and selected option

A genuine recipient QR lets a sender encrypt, but the historical receiver with
zero contacts cannot authenticate/pin the sender from relay routing alone.
Reciprocal scanning was explicitly rejected as product UX (REQ-MSG-005).
An inspection-only signed-introduction prototype neither decrypted nor admitted
ordinary incoming events and could not fix differing legacy/account-ID profiles.

Use a deterministic channel bound to both sorted immutable account/device/
credential/contact endpoints, realm and TLS SPKI. Every new message carries
signed intro-v2 and strict encrypted PlainV1 v1/channel/account context. A
zero-contact receiver transactionally admits authenticated text with unverified
identity and a real encrypted receipt; one retained Olm Account and immutable
pins remain. Clean schema3/snapshot4 explicitly refuses unsupported old state.

Alternatives: negotiating legacy profiles requires extra handshake state and
ambiguous retained history; wrapping old v0 plaintext leaves downgrade ambiguity;
labels/trial contexts/silent repins/automatic verified-contact approval violate
authentication/trust. They are not selected. Historical additive lanes and exact
authenticated recovery are deferred after the owner's clean-install amendment.

## Consequences, security and validation

Relay-visible signed device/contact/fallback linkage increases metadata; device
signatures make ciphertext origin transferable; reusable fallback prekeys weaken
initial forward secrecy compared with consumed one-time prekeys. These scoped
tradeoffs do not establish production security. Local growth/DoS is bounded by
16 unverified/64 peers and existing finite storage/session/frame budgets; Sybil
fairness, recovery, key rotation, multiple devices and server suppression remain
unsolved. [Threat model](../security/threat-model.md#first-contact-incoming-trust-boundary-draft)
records the candidate boundary.

Acceptance is actual core and real generated pinned-TLS/PostgreSQL/JVM/JNI
text/reply/receipt, forgery/strip/context, full-state rollback, duplicate/reload,
capacity/block, self-registration and persistent reopen evidence, followed by a
retained-signer unique ARM64 APK with matching full source snapshot. Report
historical suite failures separately without suppression. REQ-ID-004/005/007/008,
REQ-MSG-002/003/004/005 and REQ-SEC-001 trace to RFC invariant tests.

## Pending permanent acceptance and next gate

Independent code review is assigned to the parent after this implementation
handoff; author self-review and historical design review do not pass it. Record
reviewer/model, source identity, findings/resolutions and actual results when it
occurs. Before accepting this ADR, obtain permanent owner provenance and required
review evidence under [the canonical policy](../governance/documentation-policy.md#closed-alpha-review-exception).
No second human is invented; no review pass or production/human audit is claimed.

The local candidate is not deployed. A future reviewed release must carry its
own explicit publication/deployment authority. Unsupported snapshot rollback
means preserving existing bytes and reporting incompatibility; never installing
an older decoder over schema3, restoring stale state, or silently resetting.
