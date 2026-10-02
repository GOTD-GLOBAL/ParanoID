---
status: draft
owner: identity
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-24
---

# RFC-0027: Solana identity login and single-device replacement

## Authority, scope and status

Protocol proposal, not accepted architecture or deployed capability. Human decision
and risk owner: Sergey Maltsev (`martadvix-web`). ADR-0001/0003 and documentation
policy apply. `closed-alpha-ai` identifies the requested review path, NOT proof
that durable scope/architecture approval is complete. Independent reviewer:
Claude Opus 5.5, fresh context; not a second human or security audit.

Scope: local implementation/testing of common-server Devnet authentication,
Android integrated client, one active device, two informed private alpha testers,
synthetic/non-sensitive chats/contacts and isolated local PostgreSQL/TLS fixtures.
No live server change, Mainnet, real funds, public registration service, iOS,
owner-server installer, federation, invitation implementation or data deletion.
Device replacement creates fresh transport/E2EE keys and requires new contact
exchange. This restriction and retained owner-key risks need owner disposition.

Telegram ParanoID thread 2, 2026-09-24, Sergey confirmed: finish server login first,
then implement Android-driven VPS server deployment. One app offers common server,
invited independent server or self-hosting with the same blockchain identity.
He instructed: «Готовь протокол. Если переписка и контакты потеряются ничего страшного.»
Then: «Разбирай замечания, исправляй, отправь новую ревизию OPus 5.5 согласуй все с ним
и приступай к реализации.» Original message permalinks are unavailable. This permits
local preparation and implementation work; not accepted ADR, merge or deployment.
Current TEST chat/contact migration is not a gate. This never waives future message
retention or authorizes wiping hosted DB, phones, TLS keys or operational backups.
Permanent human confirmation in GitHub remains required for protected disposition.

Requirements: REQ-ID-001/002/003/004/005/007/008, REQ-MSG-002/003/004/005,
REQ-SEC-001, REQ-CLIENT-001. REQ-SERVER-001/002, REQ-MULTI-001 and REQ-DEPLOY-001
are the next milestone, not this delivery. REQ-ID-006 is the historical proposed
legacy-enrollment constraint: it conflicts literally with fresh migration waiver.
We do not silently apply it or alter an accepted decision. Proposed scoped
supersession: legacy slot/history preservation stays historical; this new cohort
has no legacy slots, does not migrate test history, and still checks explicit
server admission policy separately from key possession. The default server policy
permits bounded self-admission; bans/capacity are not bypassed. This reconciliation
requires owner disposition alongside the draft ADR, before normative adoption.

## Protocol and alternatives

The exact candidate is [identity-login-v3](../protocol/identity-login-v3.md), not
the initial inline RFC exchange. It is paired with
[threat analysis](../security/identity-login-v3-threats.md) and
[draft ADR-0016](../decisions/0016-solana-server-authentication.md).
The existing [RFC0026](0026-solana-devnet-registration.md) registry is unchanged.
No on-chain transaction, fee or SOL balance is required for login.

A stable identity membership points to fresh immutable transport generations.
We deliberately do NOT swap keys under an existing ContactV2 account, derive Olm
from seed, provide automatic name->account discovery, restore chat ciphertext
from recovery words, or treat a nickname as admission. Those shortcuts conflict
with existing first-contact trust. Automatic cryptographic contact rotation and
strong recovery after seed/owner-device compromise are separate future designs.

The initial eight-generation per-member budget is a bounded alpha choice, not
production recovery. At cap, current device and status keep working; a new recovery
is blocked with explicit error. It and the retained owner-key/cooldown risks need
human risk acceptance before phone release. Repeated contact replacements can
exhaust existing peer caps; no silent deletion is permitted to conceal that limit.

## First Opus review and resolution map

Reviewed initial commit b7410d6; runtime modelUsage confirmed claude-opus-5-5;
verdict REQUEST_CHANGES. Review used a supplied source packet with tools disabled,
not repository inspection or executed attacks. Its claim of tool reads is not
supported by invocation. Packet's RFC was verified against that exact commit.

| Finding | Candidate correction, awaiting re-review |
| --- | --- |
| B1 retired rebind | Lifetime unique root/account/device/auth/fingerprint/Olm bindings across identities; tombstones and negative tests |
| B2 route/lock bypass | Separate realm+DB+router; legacy registration disabled; shared ss_meta lock; complete route classes; recipient and push revocation |
| B3 retry/status | Echo client original generation; immutable current intent/result; device-only historical status; no durable resume ledger |
| B4 owner compromise | Device-only status, explicit owner-sign UI; retained owner key risk and no strong compromised-device recovery disclosed |
| B5 resource attacks | No RPC/DB on challenge, post-proof bounded RPC, fixed global windows, reserved lifetime binding budget |
| B6 membership oracle | Membership-independent challenge; dual-proof inspect; status only reveals exact device's binding |
| B7 E2EE peers | Reject retired recipients; no directory; fresh contact exchange and finite alpha peer-cap disclosure |
| B8 schema/consume | Separate exact spec, string generations, explicit state machine; consume memory before SQL, fresh proof on failure |
| B9 governance | Scoped review mode/risk owner, requirement conflict disclosed, draft ADR; durable human acceptance still pending |

Review is requested on technical readiness for LOCAL candidate implementation.
No AI verdict satisfies permanent human approval or phone/deployment gates.

## Validation and implementation sequence

1. Independent public transcript/hash/signature vectors and parser negatives.
2. Fresh Opus 5.5 review of specification, vectors and threat delta; fix blockers.
3. TDD shared Rust transcript/parser/verification, then isolated server schema,
   RPC verifier and per-route authorization, then Android state and UI integration.
4. AUTH-01 through AUTH-08 real checks, independent exact-code review and owner
   disposition; separate phone handoff and explicit operational authority.

Local candidate work may begin after technical blockers close, but no accepted
ADR, production/privacy claim, deployment or phone success is inferred from it.
Implementation evidence must distinguish crypto fixtures, real DB/RPC, host/JNI,
Android runtime and physical phones. Draft remains open; decision deadline is
before candidate phone release, exact review date assigned when blockers close.
