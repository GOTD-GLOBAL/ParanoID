---
status: draft
owner: identity
decision_owner: martadvix-web
decision_deadline: 2026-10-07
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-10-06
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

## Implementation notes (2026-09-30, branch `feat/server-directory-links`)

Status stays `draft`: implemented as a local candidate, not reviewed, merged or deployed.

- **Routes.** Also `POST /v3/directory/card`: after login the phone publishes its own
  `paranoid-contact-v2` object (credential + Olm curve/one-time key + fallback key,
  signed by the credential auth key). The server stores it only if `credential` equals
  the caller's active credential and `olm = olm_digest(curve, one_time_key)`. A contact
  needs this bundle, not only the credential. Entries therefore return
  `{name, owner, identity, contact, proof}`; only members that published a card are
  listed, and the caller is not listed. Replacement clears the card; the new phone
  republishes. Wire details: [identity-login-v3](../protocol/identity-login-v3.md#rfc-0028-member-directory-routes-2026-09-30).
- **Proof.** `id_memberships.proof` is `NOT NULL` canonical JSON
  `{"challenge": IdentityChallengeV3, "owner_signature"}` written in the commit
  transaction for enroll and replace (`key-protocol` `DirectoryProof::verify`).
- **Rate limits.** Persisted fixed windows (`id_memberships.directory_*`,
  `id_meta.directory_*`) updated under the `ss_meta` lock, not in memory, so they
  survive restarts. Directory paths are excluded from the 8/s auth ingress bucket.
- **Phone.** Core ops `verify_directory_entry_v1` (read-only) and
  `pair_directory_entry_v1` (re-verifies, pins as `network_unverified`); session
  selectors `directory_search`, `directory_visibility`, `directory_card`. Android runs
  the registry check with `RegistrationFlow.verifyMember` (same finalized
  `getMultipleAccounts` + byte-exact `verify` as own-name readback, and requires the
  returned identity PDA to equal the derived one). Directory UI appears only when the
  server's health reports `paranoid-identity-v3`.
- **Links.** `server-id` = first 16 lowercase hex characters of the server's pinned
  TLS SPKI SHA-256 (`KeyClient` pin). The app compares it with its own server's pin
  only; it keeps no list of other servers, so any other id shows «Этот сервер не
  подключён». `assetlinks.json` uses the closed-alpha disposable test signing
  certificate fingerprint; see `deploy/web/paranoid.global/README.md`.
- **Tests run.** Server (real PostgreSQL): 5 directory tests. Core: 5 directory tests,
  plus a `DirectoryProof` test in `key-protocol`. JVM/JNI end-to-end
  (`clients/android/test_identity_login.py`): two phones publish cards, phone one lists
  and finds `bob`, rejects a substituted one-time key and a wrong registry binding, adds,
  sends; phone two receives. Registry in that test is the server's fixture file, not
  live Devnet.

## Own-link client correction (2026-10-06)

The connection indicator and a populated background `directory_name` cache are
not equivalent. A connected phone can have an empty cache while its contact-card
publication is pending or has failed. This must not be described as a disconnected
server or repaired by forcing identity restoration.

On the explicit share action, the Android follow-up uses the existing signed
`directory_card` operation, asynchronously outside the state owner. It requires
an acknowledged publication and a canonical nickname from that server; the URL's
server-id remains derived only from the already configured TLS pin. The active
account/card/trust context is checked across the request, and obsolete UI callbacks
must not open a chooser after leaving/replacing that Activity. A cached global
blockchain nickname alone is never substituted for server membership evidence.

No wire/API or database format changes. Visibility, contact proof verification,
recipient lookup and the no-unknown-server-auto-join rule are unchanged. Hidden
members remain hidden; sharing a string does not change discovery permissions.

## Tests required before phone release

Server: unauthenticated/retired/banned callers refused; hidden members absent;
prefix and paging; rate limits; proof stored on enroll and replace. Phone: accepts a
genuine entry; rejects substituted Olm key, substituted credential, wrong owner, name
not on chain, proof for another server. End-to-end: find → add → first message.
