---
status: draft
owner: identity
decision_owner: martadvix-web
decision_deadline: 2026-10-07
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-30
---

# RFC-0028: Server member directory and contact links

## Required review rationale

Not applicable for a second human under the closed-alpha exception; an independent
AI review of the exact code is still required before the phone release. Protected
domains touched: identity, metadata, E2EE contact establishment.

## Summary

A member of an identity-v3 server can list and search the other members of **that
server** by nickname and add one as a contact, and can share a link carrying
server + nickname that opens ParanoID. A phone accepts a found contact only after
verifying, against the Solana registry, that the nickname owner signed the exact
transport credential (including the Olm key) the server returned. This reverses the
"no name->account directory" rule of RFC-0027 and `identity-login-v3` for members
of the same server.

## Owner decisions (Сергей Мальцев, ParanoID Telegram thread, 2026-09-30)

1. «Я должен в рамках сервера находить контакт по нику.»
2. Search only on the server the phone is logged in to; a phone may belong to
   several servers and searches each separately. Nobody unauthenticated can query.
3. Not necessarily exact: a member may see who else is on the server.
4. Rate limit: yes.
5. Visibility default: **visible** (option «а»); a member can hide in settings.
6. Share link = server + nickname, opens the app; domain `paranoid.global`.
7. Scheme confirmed: «Схему подтверждаю».

This supersedes, for server membership, the earlier owner preference that nickname
search be opt-in; hiding remains available.

## Design

### Server

- `POST /v3/directory/search` — signed v2 session of an **active** member only.
  Body `{ "query": "<0..24 chars [a-z0-9_]>", "after": "<name>|null" }`. Returns up to
  50 visible active members whose name starts with `query`, ordered by name, plus
  `next`. Empty query lists the server. Retired, banned and hidden members are absent.
- `POST /v3/directory/visibility` — member sets `visible` true/false for itself.
- Limit: 60 directory requests per member per hour, 600 per server per hour, fixed
  windows under the existing `ss_meta` lock.
- Each entry: `name`, `owner`, `identity`, the member's current transport
  `credential`, and `proof` = the stored enroll/replace challenge fields plus the
  `owner_signature` that the server already verified at login.
- New columns: `id_memberships.visible BOOLEAN NOT NULL DEFAULT true`,
  `id_memberships.proof TEXT` (canonical JSON, written in the same commit that
  activates a generation). Schema is applied to empty databases only; the test VPS
  database is re-initialized (it holds only test members).

### Phone verification (the security core)

For each entry the phone, before showing «Добавить»:

1. Reconstructs `transcript(Owner)` from `proof` and checks it names this server's
   realm+pin, purpose `enroll|replace`, and `credential_fingerprint` equal to the
   fingerprint of the returned `credential` (which covers its Olm key).
2. Verifies `owner_signature` with the returned `owner` key.
3. Reads the finalized Solana registry: `name` → `owner` and `identity` match
   (same RPC/pin checks as login).
4. Rejects the entry on any mismatch. The server cannot substitute keys without the
   owner's 12 words. Challenge expiry is NOT checked here (historical proof).

The added contact is an ordinary unverified contact; its fingerprint can still be
compared in person. After replacement of the peer's phone the old credential is
retired as today; the directory then returns the new one with a new owner proof.

### Links

`https://paranoid.global/c/<server-id>/<nickname>` and the same path under
`paranoid://c/...`. `server-id` identifies a server the app already knows (built-in
common server or one the user joined); unknown servers are shown, never joined
silently. The app opens «Добавить @nickname?» and runs the same verified search.
`https://paranoid.global/.well-known/assetlinks.json` binds the domain to the
package and signing key; without the app the page offers the APK download.

## Metadata and privacy

- The server learns who searched whom and how often; members of a server learn its
  member list (default visible). Nicknames and owner keys are already public on
  Solana; server membership was not, and now is to other members.
- Hidden members are not listed but are still reachable by existing QR/contact
  exchange.
- The link reveals server + nickname to whoever receives it.

## Alternatives

- Exact match only: rejected by the owner (wants to see who is on the server).
- Trust the server's key answer (no owner proof): rejected, a compromised server
  could read new conversations.
- Global cross-server directory: out of scope; each server has its own.

## Compatibility and rollback

v2 servers and older apps are unaffected (new routes return 404 on them). Rollback:
redeploy the previous binary; the extra columns are ignored.

## Tests required before phone release

Server: unauthenticated/retired/banned callers refused; hidden members absent;
prefix and paging; rate limits; proof stored on enroll and replace. Phone: accepts a
genuine entry; rejects substituted Olm key, substituted credential, wrong owner, name
not on chain, proof for another server. End-to-end: find → add → first message.
