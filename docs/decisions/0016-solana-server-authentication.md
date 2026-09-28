---
status: proposed
owner: identity
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-28
---

# ADR-0016: Proposed Devnet server identity authentication

## Context and proposed choice

[RFC-0027](../rfcs/0027-solana-server-authentication.md) records exact local
private synthetic-data scope, human risk owner, Telegram provenance and requirement
conflict. [The v3 contract](../protocol/identity-login-v3.md) proposes separate
Devnet realm/database, dual owner/device proof for enrollment/replacement,
device-only status, stable membership and immutable transport generations.
No on-chain login transaction or automatic contact-key substitution.

Alternatives: retain disconnected nickname (does not deliver login); reuse owner
as messaging root/Olm key (breaks separation); silently rekey immutable contacts
(breaks peer verification); implement contact rotation now (separate larger scope).

## Consequences and retained risks

Fresh contact exchange after replacement; no history restoration from seed.
Existing wrapped owner key stays on phone: a compromised owner device can compete
for takeover. One successful replacement/day and eight lifetime generations are
explicit private-alpha limits, not secure recovery after seed theft or unlimited
production recovery. Current-generation traffic/status survives generation cap.
Existing peer capacity can be exhausted by repeated contact replacement. RPC is
trusted; public blockchain identity allows inter-server correlation. Existing
media and in-flight content-free push cannot be recalled. These need human risk
acceptance, not a fabricated AI/human approval.

## Disposition gates

The local self-admission profile is vulnerable to cheap Sybil exhaustion: free
Devnet identities can consume all 128 memberships permanently. Global mutation/RPC
start quotas and the separate 64-entry v3 challenge pool can be monopolized by
self-signed requests indefinitely, denying legitimate login/status/replacement.
Post-proof is not post-admission. Caps bound resource cost, not fair availability.
V2 traffic uses separate challenge/session pools but still shares total ingress;
no availability guarantee under attack. Non-local self-admission policy and these
risks require explicit owner disposition; no public rollout follows local tests.
Banned memberships retain reserved slots. Ban lifecycle is fixture-only here.

## Owner disposition record (2026-09-28)

Decision owner `martadvix-web` approved on GitHub, PR #60:
<https://github.com/GOTD-GLOBAL/ParanoID/pull/60#issuecomment-5874285958>
(2026-09-28T16:32:02Z). Exact text:

> Как decision owner принимаю ADR-0016 для закрытой альфы на Devnet в локальном
> режиме, только с тестовыми данными: вход на сервер тем же Solana ID; при
> восстановлении на новом телефоне старый отключается; история и контакты при
> этом не переносятся. Ограничения: 128 участников, до 8 смен телефона на
> человека, не чаще одной смены в сутки. Публичный режим, Mainnet и
> развёртывание этим решением не разрешаются.

Covered: login with the same Devnet identity, single-device replacement, no
history/contact transfer, the 128/8/one-per-day limits, local test data only; no
public mode, Mainnet or deployment. NOT yet covered by that text, so status is
`proposed`, not `accepted`: the REQ-ID-006 conflict (the local profile admits any
finalized Devnet registry owner, i.e. key possession grants admission), the Sybil
and availability risks above, RPC trust, inter-server correlation and takeover by
a compromised old device holding the seed. Acceptance also needs AUTH-06/07
evidence for delivered behavior. No accepted marker is fabricated. REQ-ID-006 scoped reconciliation
and all limits above must be included in that disposition. Fresh independent
Opus5.5 technical review must close blockers; AUTH-01..08 and code/artifact review
must precede relevant delivery claims. Policy ADR0003 is not application approval.
Local implementation preparation is authorized in the current Telegram task;
merge, migration, phone release and deployment remain separately gated.

## Migration and rollback

No current DB/phone migration or deletion. New mode refuses legacy/populated DB.
Rollback never restores lower membership generations or re-enables retired keys.
Do not route new-cohort clients to the old v2 service. Any operational cutover
requires exact source/artifact review, rollback design and explicit authorization.
