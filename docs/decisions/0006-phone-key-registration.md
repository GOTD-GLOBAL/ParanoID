---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: pending exact-scope confirmation under ADR-0003
last_reviewed: 2026-09-08
---

# ADR-0006: Phone-created identity, key proof and bounded alpha admission

## Context and decision drivers

Sergey explicitly rejected manual token acquisition and requested the earlier
Threema-inspired registration UX. The current two-bearer alice/bob fixture does
not satisfy that request. [RFC-0010](../rfcs/0010-phone-key-registration.md)
records user-input provenance and exact inspected implementation, not durable
architecture approval. This proposed decision is ready for owner disposition;
its cryptographic wire detail and implementation still need review and tests.
The supplied Telegram follow-up accepts the one-time operator step for alpha UX
(“Пока что пойдет”), not this ADR or rollout. Future default/own/existing-server and
QR/link/store onboarding is captured in RFC-0010 and REQ-SERVER-001/002,
REQ-CLIENT-002; it does not expand this proposed implementation slice.

Drivers: REQ-ID-001/004/005/006/007, preserved REQ-MSG-002/003/004 and REQ-SEC-001.
No phone/email/SSH/manual bearer input; phone-owned keys and verified QR contacts;
no anonymous public signup, history loss or taking the first unused legacy slot.

## Proposed decision — not accepted

Local implementation/build was explicitly authorized in the 2026-09-08 worker
CLI task, including preservation of the actual `org.paranoid.devtext` package.
The [exact draft profile](../protocol/key-enrollment-v1.md) now has canonical
vectors and a built/tested bounded candidate. This is implementation permission,
not acceptance of this ADR or permission to deploy/migrate the hosted endpoint.

Adopt in-app account/device key creation and automatic proof-of-possession auth
for the existing private two-tester, one-device-per-tester alpha. Separate root
account signing authority, device authentication, Olm E2EE, storage wrapping and
server TLS keys. Use exact-key, expiring, one-use maintainer-approved public grants
for explicitly assigned legacy slots. Grant QR is not a reusable bearer and
contact QR is not admission. Keep message storage/Olm semantics and all existing
identities/history; migrate via explicit unique mapping and staged activation,
never implicit role assignment. Defer blockchain and recovery design.

Recommend per-request signed one-use challenges (no new bearer session protocol)
and a separate versioned auth wrapper around the existing transport, detailed in
the [draft contract](../protocol/key-enrollment-v1.md). The Ed25519 root/device
recommendation, exact byte encoding and libraries require vectors and review;
this ADR does not claim protocol interoperability or completed implementation.

## Considered alternatives

1. Keep token form or hide old bearer in QR/deep link: fails actual key registration.
2. Automatically give public applicants a free alice/bob slot: unauthorized
   admission expansion and account takeover risk, even with proof of a new key.
3. Transferable secret invites plus proof: workable later but exposes a pre-binding
   theft/race risk and requires secret handling unnecessarily for two known testers.
4. Exact-key maintainer grant plus phone proof: recommended bounded admission;
   one operator confirmation is deliberate, not tester SSH/token onboarding.

## Consequences, security and validation

Better requested UX and no reusable server admission secret entered by testers;
new server auth state, device key storage, QR verification and migration complexity.
Possession proves control of a key, not human identity, admission or old-slot
ownership. Public endpoint DoS, metadata correlation, hostile operator and device
compromise remain risks. No sensitive communication or production claims.

[Threat delta](../security/server-v0-threats.md#proposed-phone-key-registration-delta)
and RFC REG-01–REG-06 cover replay/race/expiry, resource bounds, key substitution,
TLS, redaction and populated migration/rollback. The
[local runbook](../operations/key-registration-local.md) records actual isolated
contract/vector, TLS/PostgreSQL/JVM JNI, migration/restore and APK checks. Physical
Android Keystore/camera and two-OPPO tests remain NOT RUN; the local build is not
presented as successful phone registration or accepted production architecture.

## Compatibility and migration

Preserve rootless legacy Olm identity, sessions, pinned peers, ciphertext, room
sequence, dedup, outbox, receipts and client Keystore/signing identity. New root
binding is a verified migration assertion, not retroactive proof or recovery.
Operator explicitly maps tester/new public credential/existing Olm fingerprint
to old slot. Pending migration leaves old auth unchanged; explicit activation
makes the slot key-only across all routes. Lost replies use fresh key proof.
No downgrade to bearer-only binaries after activation; no stale DB restore or
silent fallback. Current schema-hash update gate refuses this schema change until
reviewed migration-capable deployment/rollback exists. No live change here.

## Required review rationale and evidence

Protected domains: identity/authentication, API, persistence migration and trust
boundaries. Human decision and risk owner: martadvix-web; no delegation asserted.
Requested `closed-alpha-ai` mode is conditional on exact-scope approval under
[ADR-0003](0003-closed-alpha-review-policy.md), not a waiver automatically granted
by this proposal. `required_reviewers` remains pending rather than a false empty
approved list. If this scope is approved, record the bounded exception and fresh
independent AI review; otherwise the default qualified-human policy applies.

- Decision-owner approval permalink: pending; current user correction has no
  independently verifiable approval link or sender mapping in this context.
- Proposed scope: two existing OPPO testers, one device each, synthetic messages,
  isolated existing alpha; no public signup or change to neighboring services.
- Exact owner decision: confirm this admission/mapping boundary and approve the
  key-registration direction, then separately authorize reviewed migration rollout.
- Independent reviewer/model, reviewed revision, findings/resolutions: pending.
- PR and permanent disposition record: none created by this local task.
- Disposition: proposed only. No acceptance date or completed RFC is asserted.
- Follow-up: canonical encoding/vectors and isolated failing tests first; then
  scoped implementation, review, migration rehearsal and device acceptance.

## Links

- [Requirements](../product/requirements.md)
- [RFC-0010](../rfcs/0010-phone-key-registration.md)
- [Contract draft](../protocol/key-enrollment-v1.md)
- [Current state](../project/current-state.md)
- Experiment: bounded local candidate and evidence are mapped in RFC-0010 and the
  local runbook; independent review and physical device acceptance are pending.
- Supersedes: none. Accepted ADRs are unchanged.
