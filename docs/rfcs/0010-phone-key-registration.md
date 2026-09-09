---
status: draft
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: pending scope confirmation under ADR-0003
decision_deadline: before architecture acceptance or deployment; local candidate separately authorized
last_reviewed: 2026-09-08
---

# RFC-0010: Phone-created identity with bounded alpha admission

## Outcome and provenance

The subsequent 2026-09-08 implementation-worker CLI instruction explicitly
authorizes the bounded local build/test candidate, not production adoption or a
live migration. The corrected preservation requirement retains the actual
`org.paranoid.devtext` application ID and `org.paranoid.text` Java/JNI namespace.
The [exact profile](../protocol/key-enrollment-v1.md) and
[local runbook](../operations/key-registration-local.md) now accompany actual
implementation, signed APK and isolated test evidence. Earlier inspected-source
statements below describe baseline `7bef87b`, not the current candidate. No
permanent owner approval link or independent review result is invented.

Record the founder's correction, not another broad identity research phase.
In the delegated 2026-09-08 user turn Sergey rejected manually obtaining a token
and asked for registration like the earlier Threema-inspired discussion. English
translation: “Wait, why this dance around obtaining a token? Make registration
like Threema, as we agreed.” The supplied earlier discussion says to take the
Threema authorization idea for version one. These are user-input provenance, not
independently verifiable architecture approval; no original message permalink or
sender-to-GitHub mapping is available here. Obtain exact GitHub confirmation from
martadvix-web before acceptance, not another general product interview.

Confirmed requested UX: create identity on the phone, no phone/email or manual
bearer retrieval, local private keys, automatic possession proof, and verified QR
contact addition. This does NOT select Threema's protocol/directory/recovery,
a blockchain, public anonymous signup, or ownership of the first free alpha slot.
Blockchain naming is later; REQ-ID-002 recovery direction is not redesigned here.

## Follow-up product input

In the supplied 2026-09-08 Telegram follow-up Sergey explicitly accepts Create ID
-> one-time operator approval -> messaging for the closed alpha: “Пока что пойдет”
(“This will do for now”). For production he wants the common project server by
default, alternatives to create/self-host or join a known existing server, and a
server invite via QR/link that leads to Google Play/App Store when the app is absent
and resumes in-app after installation. He adds: “Поэтому как сейчас реализовано не
важно, главное вот эту мою мысль учти” (“So how it is implemented now does not matter;
the main thing is to take this idea into account”).

This records bounded UX approval and durable future product direction, not a
request to implement all future features now. No Telegram permalink, message ID,
authenticated sender mapping or independent GitHub confirmation is supplied; do not
invent them. The product question about one operator step is answered, but this is
not ADR acceptance, technical-scope approval evidence, public signup authorization
or permission to migrate/deploy. Existing manual bearer UI remains a discrepancy.

## Baseline evidence and discrepancy

Inspected baseline: `7bef87b`, including rollout evidence atop remote main
`f8131cd`. Read-only `git ls-remote origin HEAD refs/heads/main` on 2026-09-08
returned `f8131cd92e9e5945667b0257944552676885455d` for both. Local main is
`1fc163a`; it was not checked out, reset or updated. This RFC worktree deliberately
includes the newer unmerged rollout record, not an assertion it is on main.
GitHub rulesets returned an empty list; main protection returned HTTP 404,
“Branch not protected.” Workflow existence alone is not required-check evidence.

- `server/src/lib.rs::authenticate` maps two bearer hashes to integers 0/1;
  `stored_app` exposes only message routes and health. `server/schema.sql` stores
  sender/recipient 0/1, one room, existing sequences and dedup IDs, no accounts.
- `MainActivity.java` asks URL, SPKI pin, alice/bob and token; it copies/pastes a
  public pairing code, not a camera-scanned QR. `TextEngine.configure/http`
  saves the bearer in encrypted state and sends it on every request.
- `clients/core/src/lib.rs::init` creates a local Olm account, but `Bundle.device`
  is alice/bob, not a root account identity or independently authorized device.
  `Client.account` means an Olm crypto object, not a server account record.
- Existing APK is reported as 0.0.3-dev in this task. No APK was read, rebuilt,
  installed or tested here. Source confirms the onboarding mismatch independently.
- Public connection metadata supplied for the existing alpha is
  `https://157.180.49.125:38443`, SPKI SHA-256
  `8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba`.
  These are not secrets or peer identity. No live connection was made here;
  hosted observations belong to the [rollout record](../operations/linux-alpha-rollout-2026-09-08.md).

The current fixture is a development shortcut, not fulfillment of REQ-ID-005.
Moving its token into a QR, deep link, APK or server response would merely hide
bearer onboarding. It would not create a key-owned account or authenticate its
private-key possession. Never embed existing credentials or auto-select a role.

## Recommended bounded UX

1. A reviewed alpha APK carries only the approved public origin/pin, or imports a
   separately authenticated public server descriptor. No fetched trust pin,
   trust-all TLS, automatic repinning or secret is bundled. Existing saved origin
   and pin win; conflicts stop, never overwrite.
2. “Create identity” generates and durably saves independent account and device
   authentication keys on the phone; show a public account ID. A truly empty
   install also saves fresh Olm keys in an unassigned state; split crypto creation
   from legacy role assignment, never guess alice/bob. Existing state
   instead offers “Enable key login for this identity”, with no fresh Olm init.
3. “Join private test” displays a public enrollment-request QR with account key,
   device key and request fingerprint. Until approved, local identity exists but
   has no server messaging rights. No network registration queue is necessary.
4. A maintainer verifies the intended tester and phone QR directly (or over an
   already authenticated channel). A reviewed operator-only local enrollment
   tool approves those exact public keys, explicitly names legacy slot 0 or 1,
   and produces an expiring public grant descriptor. The tester scans that QR
   or opens it in the app. No SSH, copied bearer, email or phone number is needed
   by the tester. The maintainer still performs admission, not the user.
5. App redeems the grant using key proof, persists the mapping, then automatically
   proves device possession on reconnect/requests. A leaked grant alone is
   useless: it is bound to the already verified keys, not a secret bearer invite.
6. “Add contact” scans the other phone's public contact QR, shows ID/fingerprint,
   and requires explicit comparison/confirmation. Enrollment QR and contact QR
   have different types and authority. An unverified forwarded QR is not proof
   of who holds the phone. A changed existing peer key is refused, not auto-pinned.

Recommended admission boundary: **at most the existing two explicitly assigned
testers, one device each, synthetic data only**. No self-service public grant
issuance, public admin route, third account, wildcard invite or slot guessing.
A request QR is public key material; sending it does not consume a slot. Grants
expire after 15 minutes, can be revoked, are single-use and exact-key/slot bound.
Reissue requires maintainer confirmation; no automatic slot recycling. Expiry
of admission material is not deletion of history or an existing identity.
The follow-up accepts the one-time operator step as alpha UX. Exact-key/legacy-slot
mechanics remain proposed and require durable scoped disposition, not another
product interview about whether operator approval is tolerable.

## Future server onboarding boundary

REQ-SERVER-001/002 and REQ-CLIENT-002 are future product targets, not additions to
REG-01–REG-06 or the current two-OPPO implementation slice. Keep this capture inside
RFC-0010; no broad new RFC or detailed multi-server protocol is needed now.

- Default to the common project server only as a replaceable UX choice. Offer
  create/self-host and join-known-server alternatives; independent servers must
  not depend on permanent default-server authority. Server trust/admission remain
  per-server; selecting another server never resets identity/history or overwrites
  saved pins, peer verification or mappings.
- A server-selection/admission invite is a distinct typed QR/link, not the contact
  QR that verifies a person's public key binding. Opening it does not grant access,
  verify a peer or authorize silent trust replacement. Admission still needs the
  target server's policy and key proof; no secret grant in an app/store URL.
- If installed, open an invitation preview in-app and validate server trust and
  admission. Otherwise guide to the appropriate Google Play/App Store listing;
  installation needs user/platform action, never silent install. Automatic deferred
  deep-link resumption is platform-dependent and NOT VERIFIED. If unavailable,
  reopen the original invite after installation; revalidate it and visibly handle
  expiry/revocation rather than bypass auth to recover the flow.
- Platform link association, store availability and safe continuation need later
  device evidence, including absent-app, cancelled-install, lost-context and wrong
  server/QR-type cases. No such test or store publication is claimed. Simultaneous
  multi-server operation, iOS and store publishing do not gate this Android alpha.

## Identity and key boundaries

| Object | Proposed authority and storage |
| --- | --- |
| Account identity | Independent on-device Ed25519 root signing key; domain-separated full public-key digest is account ID, not phone/email, nickname or slot. Authorizes device credential, not traffic encryption. Algorithm/library/encoding require reviewed vectors before implementation. |
| Device | Random persistent device ID plus independent Ed25519 authentication key. Root-signed credential binds account ID, device ID, auth key, server realm and current E2EE public bundle digest. One device only in this increment. |
| E2EE | Existing Olm Curve25519 identity/prekey and ratchet state remain content/session keys. Do not reuse these as root or login keys, derive them from a bearer, rotate them or expose them to server admission. Contact QR carries the public binding; server needs auth credential, not ratchet secrets. |
| Storage/TLS | Existing Android Keystore AES-GCM wrapping key is neither identity nor auth. TLS server key/SPKI authenticates the server, not contacts. Root/auth secrets stay in platform-protected encrypted local state; no hardware-backed Ed25519 claim without OPPO evidence. |
| Admission | Operator grants the exact account/device permission to a named existing transport slot. Root self-signature proves key control, not eligibility, identity of a human or entitlement to an old account. |

No seed UI, seed derivation, recovery escrow, device transfer/rotation, account
merge or lost-key recovery is added. Loss warnings remain honest; preserving an
old Olm state does not magically recover it from a new root. Future recovery
must be separately reconciled with REQ-ID-002 before claiming that requirement.

## Proposed contract and minimal implementation boundary

[Key enrollment v1 draft](../protocol/key-enrollment-v1.md) specifies route intent,
one-use challenges, signed request binding, failure/retry and migration gates.
It is a design target, NOT an implemented or accepted wire contract.

| Exact existing surface | Smallest proposed change after disposition |
| --- | --- |
| `server/src/lib.rs::Store`, `authenticate`, `stored_app` | Add key credential/grant lookup and one-use challenge verification; add `/v1/enrollment/*`, `/v1/auth/*` and authenticated `/v1/messages` wrapper. Map authorized principal to existing 0/1 before reusing send/sync logic. Reject bearer for migrated slot even at `/v0/messages`; never take sender/slot from request body. |
| `server/schema.sql`, server migration tests | Add accounts/devices, bound grants and per-slot migration/auth mode. Preserve envelopes/room tables and all historical keys/indices unchanged. Require unique slot/account/device bindings and atomic grant activation; review versioned migration separately from startup CREATE IF NOT EXISTS. |
| `server/src/main.rs`, `deploy/alpha.py`, `deploy/build.py` | Add explicit schema/config-version gate, operator-local grant/revoke tool and key-auth readiness path; retain DB/TLS isolation and packaging allowlist. Existing schema-hash-only update gate must refuse this upgrade until a separately tested migration path exists. No ad hoc live SQL or public administration UI. |
| `clients/android/.../MainActivity.java` | Replace new-user role/token form with create/join/wait/ready and QR scan/display/confirmation. Keep diagnostics separate, never show credentials. Camera permission and reviewed QR dependency, invalid/oversized QR and cancellation tests required. |
| `clients/android/.../TextEngine.java`, `SnapshotCodec.java`, `PinnedTls.java` | Version encrypted outer snapshot, persist key identity before request, add registration/auth state machine and challenge-signing transport. Preserve old token/state during staged migration; do not show or export token. Retain per-connection TLS rules unchanged. |
| `clients/core/src/lib.rs::Client`, `Bundle`, `init`, `Request::Pair`, JNI adapter | Add separately versioned identity/credential/contact wrapper, not renamed Olm account. Preserve v0 crypto state and legacy alice/bob identifiers inside historical payloads; initialize new Olm only for truly empty state, split key creation from later explicit slot assignment without regenerating keys. Verify root/device/E2EE binding and explicit QR trust before existing pairing operation. |
| `server/tests`, `clients/core/tests`, Android JVM/APK tests, `deploy/test_*` | Implement contract matrix below with disposable identities/PG, then real OPPO storage/QR/messaging acceptance on reviewed build. Update API schemas, migration/runbook/build notices alongside code. |

Do not generalize the database to arbitrary accounts, replace Olm, add a directory,
change history retention, or build a web admin service to solve this correction.

## Invariants, validation and review

No standalone invariant registry exists in this baseline. Canonical stable IDs
are requirements plus the server acceptance matrix. All remain preserved; the
new identity decision remains proposed. The local candidate exercises the bounded
controls listed below; physical OPPO acceptance remains NOT RUN.

| Requirement / proposed test | Enforcement needed before delivery |
| --- | --- |
| REQ-ID-001/005; REG-01 | Phone create/join/reopen needs no phone/email/SSH/role/bearer input; persisted keys survive crash; unavailable keys never silently regenerate. |
| REQ-ID-004/006; REG-02 | No grant or wrong key/slot/realm => no account; revoked/expired grant and concurrent double redemption denied; third tester denied; no pending-row allocation for unknown keys. |
| REQ-ID-005/006; REG-03 | Wrong signature, replay/race, expiry, cross-purpose/realm/path/query/body/device and stale-boot challenge fail; a captured grant/request never becomes reusable login. |
| REQ-ID-007, REQ-SEC-001; REG-04 | QR type confusion, malformed credential, substituted E2EE key and changed verified contact fail. TLS wrong pin/IP/expiry and redirects still fail before HTTP; inspect release and logs for secrets. |
| REQ-MSG-002/003/004; REG-05 | Populated legacy fixture retains exact Olm keys, sessions, ciphertext, cursor, outbox, dedup and receipt state through staged migration, lost replies, restart and explicit abort. Both sender slots remain isolated. |
| REQ-MSG-004, REQ-DEPLOY-001; REG-06 | Verified restore on isolated DB, version-mismatch update/downgrade refusal and migration-capable rollback preserve writes after cutover; legacy bearer cannot regain migrated slot. |
| REQ-ID-002/003; review | No recovery/blockchain claim, no seed-derived ratchet reset; later scope explicitly deferred. |

The initial documentation-only proposal was followed by explicitly authorized
local tracer TDD, not a mock presented as a messenger. The runbook records real
isolated TLS/PG/JVM JNI, QR, populated migration and restore checks. Independent
review and physical two-phone acceptance remain separate unfulfilled gates.

## Alternatives, operations and remaining owner decisions

- Keep/manual or QR-hide bearer: simpler but fails the explicit product correction.
- Public key signup with only CAPTCHA/rate limits: possession is not admission;
  expands the approved public attack surface and permits slot theft. Rejected.
- Secret invite QR plus PoP: possible later, but a stolen invite permits a race
  before key binding; exact-key maintainer approval avoids that alpha risk.
- Recommended exact-key grants: bounded, no raw token handling by testers, costs
  one maintainer approval per device; no claim of unrestricted Threema UX.

Auth work introduces correlation through stable public IDs, challenge/approval
traffic and server-observed metadata. See the [threat delta](../security/server-v0-threats.md#proposed-phone-key-registration-delta).
Metrics must be aggregate/static; never log signatures, grants, QR payloads,
keys, request bodies, authorization headers or legacy tokens. Rate/connection
bounds and quotas remain; expiration cleanup covers auth state only, not messages.

Only owner decisions blocking acceptance/rollout: confirm this precise two-tester,
one-device, exact-key admission and legacy mapping authority; approve the proposed
identity/auth boundary under ADR-0003 with durable evidence. Actual tester-key
mapping is private operator evidence, never credentials in Git. Deployment of a
reviewed migration still needs bounded authorization; existing firewall or bearer
alpha permission is not permission for the new registration service. No extra
blockchain/recovery/stack selection or mandatory second human is invented here.

Human risk owner: martadvix-web. Requested review mode is `closed-alpha-ai`, not
an assertion that this specific scope is already approved. Scope approval and
independent fresh-context reviewer/model/revision/findings are pending. Before
acceptance record those and close any blocking findings under the canonical
policy; outside approved test scope use the default qualified-human review.

Historical documentation-only validation on 2026-09-08: `npx --yes markdownlint-cli2@0.18.1`
checked 49 Markdown files with zero errors; a read-only local Markdown link/heading
check passed 138 local links/anchors across those files. It skipped 21 external
references; full online Lychee/remote CI was not run. `git diff --check` passed.
These are documentation checks only, not REG-01–REG-06 execution or independent
security review. That initial proposal was confined to Markdown; subsequent local
implementation evidence is recorded separately in the local runbook.

Disposition: draft; [ADR-0006](../decisions/0006-phone-key-registration.md) is
proposed, not accepted. The local implementation/build does not create an approval
permalink, PR, merge, deployment, live migration or live-secret access.
