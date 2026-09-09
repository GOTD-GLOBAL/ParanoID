---
status: draft
owner: product
last_reviewed: 2026-09-09
---

# Self-service messenger: application and server target

Owner-facing issue: [#16](https://github.com/GOTD-GLOBAL/ParanoID/issues/16), in
Russian. This English brief mirrors its product scope; concrete technical choices
remain subject to the repository's scoped RFC/ADR and security-review process.
Requirements: REQ-ID-001/004/005/006/007/008, REQ-MSG-002/003/004/005,
REQ-DEPLOY-001, REQ-SERVER-001/002, REQ-CLIENT-001/002, REQ-MULTI-001, REQ-SEC-001.

**Current local scope: tested clean-install first-contact candidate.**
[Current-state](../project/current-state.md) and the [local candidate record](../operations/clean-first-contact-local.md)
separate observed core/JVM/JNI/real-server tests from final artifact verification
and still-unrun physical-phone acceptance. This does not close issue #16 by
substituting a local fixture for the eventual two-phone outcome.

Historically, the feature branch started from
[archival checkpoint f45519e](https://github.com/GOTD-GLOBAL/ParanoID/commit/f45519ebe1c44ab2f34b3707c57703fce4583fa6)
with operator-grant enrollment. Merely creating that branch/brief/issue did not
implement self-service or authorize merging the archive as a finished product.

## Current clean-install amendment (2026-09-09)

The owner selected [RFC-0014](../rfcs/0014-first-contact-incoming.md)'s mandatory
signed account-ID first-contact recommendation and explicitly prioritized a
working messenger on fresh installations. Exact Telegram text/provenance is in
[REQ-MSG-005](requirements.md#first-contact-incoming-correction-2026-09-09).
Historical test-message preservation/migration/recovery is NOT this candidate's
release gate. The historical migration acceptance bullet below remains a later
obligation, not an immediate build blocker or a claim of fixed historical REDs.

The local deliverable is tested core + actual pinned-TLS/PostgreSQL/JVM/JNI
zero-contact text/reply/receipts and a retained-signer APK candidate. Parent
independent review precedes any delivery/publication. Real two-phone acceptance
still requires later evidence and is not inferred from local tests. Fresh-state
persistence/reopen, E2EE, exact immutable retries and genuine receipts remain
required. No live action or application reset is performed by this task.

## User journey

Install -> create ID -> automatically register on the common default server ->
add a contact -> send and receive messages. No human operator, phone number,
email, wallet, temporary admission code, SSH, manual URL/pin/token or alice/bob role
selection in the ordinary flow. Threema is a UX reference, not an adopted protocol.

Keys are owned and securely retained by the client. Server proof-of-possession
checks remain automatic; removing human approval never means accepting an
unproven identity or disabling TLS. Contacts/dialogs/chat are normal user-facing
screens, not diagnostic JSON forms. A verified contact QR is permissible and
separate from admission. Any ID lookup/discovery and its privacy must be specified;
a globally public user directory is not implicit in this requirement.

Support text, retained history, offline outbox, reconnect and restart without
identity changes, lost acknowledged data or duplicate display. One check means
durable server acceptance; two mean authenticated peer delivery, not reading.
Errors must be understandable without developer-assisted configuration or reset.

## Server boundary

- Self-service registration under declared resource/abuse controls, not operator
  queues. Common-server defaults must not make ordinary users fetch approval codes.
- General user/device/conversation records replace fixed two-slot/test-pair limits.
  Unknown keys must never acquire legacy identities/history by taking a free slot.
- Preserve separated identity, device authentication and server admission policy;
  verify key possession, reject replay/substitution and unauthorized access.
- Bound registrations, requests and storage without silently reviving manual
  approval as the default user experience or allowing unlimited subsidized writes.
- E2EE/private content keys stay client-side; no plaintext or key leakage in server
  logs/storage. TLS remains verified, independent of E2EE. History is not evicted
  after delivery; deletion is a separate explicit contract.
- Reproducible isolated Linux deployment, autostart/restart, meaningful health,
  verified backup/restore and history-preserving updates remain requirements.
  Moving to other hardware should not require a bespoke deployment procedure.

## Blockchain and independent servers later

Do not require a wallet, transaction, chain/RPC choice or blockchain availability
for the first registration/message milestone. Later blockchain registration is a
separate identity operation, linking existing accounts without losing contacts,
keys or history. It must not replace the entire messaging system or require a
transaction for each message. No plaintext messages/private keys go on chain.

Users can later choose the common public server or an independently operated
private server. Server choice and identity are separate. Private-server policy
must not reintroduce compulsory operator approval on the common server. The chain,
linking protocol, naming/discovery/privacy and recovery are separate decisions;
this issue does not choose them or claim they are implemented.

## Acceptance gate for the next working version

- Two ordinary users on two physical Android phones independently complete the
  journey without an operator or service-code exchange.
- Create ID needs no phone/email/wallet/chain transaction; retry/relaunch preserves
  the same identity. Contacts and history survive closing/reopening the app.
- REQ-MSG-005: only the sender needs the recipient public contact. The recipient
  with zero contacts sees first incoming plaintext and can reply without scanning
  or approving the sender; optional identity verification is a separate action.
  [RFC-0014](../rfcs/0014-first-contact-incoming.md) is proposed; actual candidate
  evidence is recorded separately.
- Offline/reconnect and server restart retain acknowledged data without duplicates;
  receipt semantics and E2EE are actually exercised, not inferred from health.
- Server integration covers more than two accounts; a third physical phone is not
  a new prerequisite for the two-phone acceptance test.
- Invalid proofs, account/device substitution, replay, quota limits and ambiguous
  storage failure are rejected without resetting retained identity/history.
- Populated migration from preserved experimental state retains keys, contacts,
  history and APK signing identity. No uninstall/data clear as an upgrade method.
- Actual Linux installation/update/restart/restore tests preserve later data and
  leave neighboring services unchanged.
- Requirements/contracts/threats/tests evolve with the implementation; independent
  review and CI precede authorized PR merge and identified-commit deployment.
  Written, tested, PR-open, merged and deployed are distinct recorded states.
- The deliverable is an installable APK plus demonstrated two-user messaging.
  Documentation, compilation, a JVM run or `/health` alone cannot close #16.

Media/files/voice messages/audio-video calls remain later product tasks. iOS,
server creation/selection/invitations/stores and blockchain are not silently
implemented here and must not postpone the usable initial text journey again.

## Scoped fresh-server correction (2026-09-09)

Sergey subsequently requested replacing the old disposable server DB in place
without preserving/backing it up. The [operation record](../operations/fresh-self-service-v2.md#scope-correction-and-provenance)
records exact supplied provenance and deletion boundary, not invented permanent
approval. This supersedes the legacy server migration/pre-cutover-backup gate for
this one fresh replacement only. Preserve APK identity, TLS and every phone
snapshot/key/contact/history; fresh server storage never authorizes phone reset.
Future v2 history preservation/update/restore requirements remain unchanged.

## Preservation and workflow

Keep the archive as history. Reuse tested crypto, client storage, transport,
receipts/retry, TLS and lifecycle components after adaptation; replace the manual
onboarding/two-slot design instead of discarding everything or bypassing checks.
New protected changes need a small concrete contract, strict TDD and review, not
another broad research cycle. The original brief task prepared the workstream
only; subsequent implementation/evidence is tracked in
[current state](../project/current-state.md). Neither this product brief nor local
server tests grant deployment, merge or architecture acceptance.
