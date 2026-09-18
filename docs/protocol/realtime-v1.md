---
status: proposed
owner: protocol
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Signed session and long-poll v1

Proposed overnight private test-data alpha extension of
[self-service v2](self-service-v2.md), [RFC-0015](../rfcs/0015-overnight-realtime.md)
and proposed [ADR-0010](../decisions/0010-overnight-realtime.md).
Written before implementation. Fresh independent Fable design review and bounded
closure are now complete; the local server candidate and full-test progress are
recorded in [server evidence](../server/realtime-local.md). Final exact-source
review and deployment remain pending.
REQ-MSG-002/003/004/005, REQ-ID-004/005/008, REQ-SEC-001 and REQ-MULTI-001 apply.

## Opening and immutable authority

Existing registration and proof authentication remain available unchanged.
The existing authenticated challenge route additionally recognizes exactly
`purpose: "session", method: "POST", path: "/v2/session", body: SHA256("{}")`.
Its existing 60-second challenge, device signature, one-use consumption,
active-account and full immutable credential checks authorize POST `/v2/session`
with exactly `{}`. No session exists before successful device proof and the
transactional active binding check. Session issuance does not register an account.

The successful response is exactly a strict `SessionV2` JSON object:
`id, epoch, expires, realm, pin, account, device, credential`.
All fields are strings except integer Unix-seconds `expires`. ID and epoch are
canonical random UUIDv4; epoch is the current server-process epoch. `expires` is
issuance wall time plus 300 seconds. Session lifetime also uses monotonic time.
The server retains the complete already verified Credential for this session.
At most 64 live sessions globally and two per account; reject with 429 at capacity,
never evict another live session. Expired entries may be reclaimed.

Session fields are public context, **not bearer authority**. An operation requires
the retained device-auth private key. The session is scoped to precisely its
realm, TLS SPKI, account, device and credential fingerprint. Client validates all
these against its saved identity/trust before use. Nothing is persisted or logged
as a reusable credential. Restart drops sessions and replay state together.

## Exact request authentication

An authenticated session operation signs the existing length-prefixed UTF-8
transcript with its Ed25519 device-auth key:

```text
LP("paranoid-session-request-v1", session.id, session.epoch,
   session.expires, session.realm, session.pin, session.account,
   session.device, session.credential, request_nonce, method, path, SHA256(body))
Authorization: ParanoidSessionV2 <session.id>.<request_nonce>.<signature>
```

`request_nonce` is a fresh canonical UUIDv4. Signature encoding is the existing
canonical unpadded Ed25519 base64. Exactly one Authorization header is accepted.
Method is uppercase; path includes exact query
bytes. Server constructs context from its stored session, never submitted claims.
Native client signing accepts only exact native-generated message-send JSON for
an immutable durable outbox envelope, or a canonical inbox/events cursor request.
It must not expose a general-purpose arbitrary-path/body signer.

Allowed session operations are only POST `/v2/messages` with unchanged strict
Submission, GET `/v2/messages` with the unchanged strict cursor query, and GET
`/v2/events` with that same query/body contract. Empty GET bodies are mandatory.
No registration, admin, update, arbitrary path, query on POST or method override
is authorized. Signed sessions cannot authenticate existing registration/status
routes. Existing ParanoidV2 proofs cannot authenticate `/v2/events`.

Verify signature and exact context before atomically inserting nonce into the
session replay ledger; invalid signatures do not consume legitimate nonces.
Each nonce has at most one winner, including concurrent duplicates. Retain all
consumed nonces until session expiry; at most 2048 operations per session, then
429 until a new session can be opened. No replay ledger eviction. A request that
fails after nonce consumption still consumes that nonce. Retry uses a fresh nonce
and the exact persisted ciphertext/ID; unchanged server idempotency handles lost
acceptance responses. No message is re-encrypted for a transport retry.

Before every ordinary operation, initial wait query and final wait completion, under the existing `ss_meta`
transaction lock, recheck active mode and exact account root, device, auth key,
fingerprint and complete Credential against the stored session. Recheck expiry
at the authorization linearization point. Any changed binding or inactive account
invalidates that session and returns generic 401. A transaction authorized before
a concurrent revocation may commit; later authorization points must fail.
Missing, malformed, replayed or already expired process-local session authority
fails immediately without querying the database; it cannot return data or success.
An unlocked database-binding/revocation hint still receives the locked final check.
Existing revoked accounts are terminal: supported APIs never reactivate/rekey
them. Future reactivation/rekey requires a durable authorization generation and
an independently reviewed migration before it can be supported. No PostgreSQL
internal tuple-version dependency or schema change is introduced tonight.

## Delivery wait and persistence

GET `/v2/events?after=0&limit=20` returns exactly the ordinary messages page and
cursor. Cursor is nonnegative; limit remains 1..100, client requests at most 20.
Return immediately when authorized inbox data exists. Otherwise wait at most
20 seconds, never beyond session expiry, then query/re-authorize before returning
data or an empty page. An expired/revoked session returns 401, not an empty success.

At most eight concurrent event waits globally and one per account, across all
sessions. Excess receives 429 without an unbounded permit queue. The waiter guard
is released on success, rejection, disconnect cancellation or handler timeout.
Waits hold neither a PostgreSQL transaction/connection nor a native state worker.

Before its initial inbox query, a wait creates/enables its notification observer.
After every successful POST transaction commit (including the old v2 route), the
server notifies current observers. Notifications carry no message/body and need
not be durable: the inbox and cursor are the durable truth. Subscribe-before-query,
re-register-before-requery and final query close commit/subscribe and timeout races.
A bounded one-second tick rechecks authorization and inbox while idle, covering
revocation without an administrative notification API. It is a recovery safety
check, not the primary delivery mechanism. **Idle ticks and notifications first
use plain unlocked SQL reads**, never `ss_meta FOR UPDATE`; they hold no open
transaction while sleeping. Only an initial query or final data/empty/binding-error
completion acquires the authorization transaction lock. Unlocked observations
are hints, never permission to return ciphertext. Eight idle waiters must not
create eight global-lock transactions per second or starve the three pool
connections remaining beside the process advisory-lock connection.
The lockless inbox tick stays at most one second, including when a sender handler
is cancelled after its DB commit but before notification. This bounds missed-wake
recovery without a detached unbounded task. Failed/rolled-back inserts never signal
successful delivery. No ACK-triggered deletion or queue of message copies exists.

The server does not interpret E2EE or fabricate receipts. Renderer publication
follows successful full native candidate persistence and precedes receipt network
completion. Ratchets retain one owner; networking has separate send/wait lanes and
bounded handoff, with immutable requests and generation/cursor revalidation when
network results return. Multi-server future state isolates each realm's session,
cursor, outbox and key namespace beneath a separate portable root identity.

## Preserved and extended resource limits

All existing registration/challenge ingress, 20 total requests/second, 8 auth
requests/second, message body/ciphertext/page/storage limits and no-eviction rules
remain. Session opening counts as auth ingress. Events are ordinary total ingress.
Both nested deadlines must be changed: the inner middleware in
`server/src/self_service_http.rs` and outer TLS middleware in `server/src/main.rs`
give **GET `/v2/events` in self-service v2 only** a 25-second handler deadline;
every other method, route and mode retains 10 seconds. Changing the inner layer
alone would terminate every idle long-poll prematurely.
The TLS acceptor retains 16 simultaneous sockets, no pending permit queue and
8-second handshake timeout. Only self-service v2 uses a 120-second absolute TLS
socket lifetime to permit bounded pooled requests; older modes retain 15 seconds.
HTTP/1 keep-alive is enabled only for self-service v2; legacy key mode retains
its current disabled keep-alive behavior. Client TLS factories are reused and
normal request completion does not send `Connection: close` or disconnect a
healthy pooled transport. Explicit cancellation may close a waiting connection.
Client pools contain at most two concurrent sockets per realm; idle sockets are
closed promptly. V2 HTTP/1 header-read timeout is eight seconds, bounded separately
from an authenticated long-poll response; no endless idle-header permit retention.
No infinite socket or session lifetime. For self-service v2, clients configure
response read timeouts above the applicable handler deadline: 15 seconds for
ordinary routes (10-second handler), 30 seconds for GET `/v2/events` (25-second
handler). Connection establishment keeps its separate 8-second timeout. These
are socket read bounds, not total operation or download deadlines. Connection
expiry/cancellation uses a new signed request. A message retry preserves its
immutable message ID and ciphertext; no timeout permits weaker TLS or
authentication.
Connection limits remain shared availability risks, not guaranteed fairness.

## Discovery, rollback and required evidence

`GET /health` retains existing status/protocol and advertises optional
`realtime: "signed-long-poll-v1"` only when this extension exists. This flag is
capability discovery, not authority or DB readiness. A pinned client on an older
v2 server (missing flag) uses retained challenge-message transport. 401 is an auth
failure, never permission to loosen trust. The server update is schema-free and
old v2 messages are unchanged; same-data rollback to the retained v2 binary is
compatible. No reinitialization, deletion, old dump restoration or pin rotation.

Errors distinguish 429 `ingress_limit`/existing challenge-rate errors from
`session_exhausted` (2048 consumed nonces), `session_capacity` (live-session cap)
and `waiter_busy` (account/global waiter cap). A busy waiter, including a dead
connection whose server handler remains until its deadline, triggers bounded
plain GET `/v2/messages` while receipt/send progress continues; it must not block
receiving for the entire old wait. A 404/unknown-route on a cached session/events
capability triggers pinned `/health` rediscovery and retained challenge transport
fallback without changing identity/trust. A 401 never weakens authorization.
Failed session renewal also triggers pinned capability rediscovery: an older v2
server rejects the new session-purpose challenge with 401 before the client can
reach `/v2/session`. Only an absent realtime capability selects retained v2 proof
transport; a 401 while capability remains present stays an authentication failure.
The client clamps received session lifetime by monotonic receipt time to at most
300 seconds and renews around 240 seconds using the second account session slot;
local wall-clock skew is not a reason to extend server authority.

Required real tests: signed context/route/body/nonce tampering; concurrent replay
winner; expiry/restart; changed device binding and revocation during wait; session
and waiter limits/release; subscribe/commit/no-lost-wake and page continuation;
legacy sender waking a session waiter; exact retries/quota preservation; delayed
receipt network independent of durable renderer publication; actual pinned TLS,
PostgreSQL, JVM/JNI crossing/restart and measured latency. Phone render/Doze and
background provider guarantees require separate device evidence.

Additional review regressions: both TLS deadline layers; two signed requests on
one TLS connection; the 120-second absolute socket close with fresh-proof recovery;
eight idle waiters plus continuous sends with no pool timeout and reported P95
versus no-waiter baseline; lost post-commit notification recovered by the one-second
tick; nine rapid `/v2/session` requests reaching auth ingress rejection; events
not spending auth ingress; live old-binary rollback capability rediscovery; bounded
client socket pool. These remain tests to run, not measured claims.
