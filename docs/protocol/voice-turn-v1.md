---
status: proposed
owner: protocol
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice TURN credentials v1

Canonical proposed extension for [REQ-CALL-006](../product/voice-relay.md).
[RFC-0018](../rfcs/0018-voice-turn.md) and proposed
[ADR-0012](../decisions/0012-voice-turn.md) scope this local work. This document
adds one fixed operation to [signed sessions](realtime-v1.md); it does not change
existing message operations, session transcripts, storage or E2EE call bodies.
The issuer and offline package are implemented on the server foundation branch;
Android integration is in its dependent client branch. Focused issuer and offline
package checks pass. Retained-allocation expiry and ACL packet tests remain NOT RUN;
final review and public deployment are separate uncompleted gates.

## Request and authority

`GET /v2/voice/turn`, no query, zero body bytes, exactly one existing
`Authorization: ParanoidSessionV2 ...` header. The native selector is exactly
`operation: "turn"` with no envelope ID. Native code generates this fixed path,
method, empty body and fresh nonce after validating the complete saved
realm/pin/account/device/credential context. It exposes no arbitrary signer.
No bearer, old challenge proof, registration, method override or other route is
accepted. The signature includes the unchanged complete session transcript and
exact path/body digest. Replay, expiry, 2048-nonce ledger and invalid-signature
nonconsumption remain unchanged.

Before every issuance or disabled response, acquire the existing `ss_meta`
transaction lock and recheck session lifetime and the complete active immutable
account/root/device/auth/fingerprint/credential binding, plus the current locked
ss_meta version/realm/pin against the retained service context. A changed/revoked binding
invalidates the session and returns generic401. An authorization point before a
concurrent revocation may finish; later points fail. No conversation/contact,
message, identity or persistent schema row is created by this endpoint.

The endpoint is ordinary total ingress with the retained ten-second handler
deadline. Minting is independently limited to four requests per account/device
binding per sliding60seconds and32 globally per sliding60seconds. The mapping is
bounded to1024 active binding buckets; discard only expired quota entries and
reject capacity, never evict live entries to bypass a limit. Quotas use monotonic
time, survive session replacement within a process, and reset on issuer restart;
this reset does not reset any retained session's nonce ledger. A new process
invalidates all old sessions as before. Cancellation/lost responses may consume
one issuance budget; no unbounded automatic remint/retry exists.

## Success and validation

Exactly these JSON fields, no duplicates or unknown fields, response <=2048UTF-8
bytes; numeric fields are integers:

```json
{
  "v": 1,
  "urls": [
    "turn:157.180.49.125:34781?transport=udp",
    "turn:157.180.49.125:34781?transport=tcp"
  ],
  "username": "<expiry-seconds>:<32-lowercase-random-hex>",
  "credential": "<canonical-padded-base64-20-byte-HMAC>",
  "expires": 0,
  "ttl": 1200
}
```

The placeholders and zero above describe types, not usable fixture credentials.
`expires` is issuance Unix seconds+1200; username begins with exactly its decimal
representation, followed by a colon and16 fresh random bytes as lowercase hex.
No account/device/call ID appears in username. The password is standard padded
Base64(HMAC-SHA1(secret, UTF8(username))), using the exact64 lowercase ASCII hex
bytes in the private secret file as the HMAC key, **not** their decoded bytes.
Use a maintained cryptographic implementation; SHA1 is only the coturn REST HMAC
interoperability mechanism, never identity/signature/media cryptography.

The only permitted URLs are the two exact `turn:` forms above, in that order,
with the literal IPv4 host equal to the retained HTTPS realm host. No user-info,
fragment, alternate host/port, DNS lookup policy, `stun:` or implicit public relay.
The isolated test realm uses127.0.0.1 and matching loopback TURN forwarding;
production configuration rejects loopback/private/nonpublic addresses. No
production binary substitutes a fixture host or TLS pin.

Client validates the strict shape, exact URLs and username/expiry relation,
canonical credential encoding, ttl1200 and version1. Remaining wall-clock lifetime
must be between1000 and1205seconds on receipt, covering the45-second setup and
15-minute maximum call under the existing five-second clock-skew assumption.
Record a monotonic receipt deadline and recheck adequate remaining lifetime before
opening the PeerConnection; waiting for older disposal cannot extend authority.
The same generation's callback must still be active and explicitly consented.
Credentials are volatile: no state snapshot, history, E2EE control, saved
configuration, URL query, error/log, screenshot or evidence export includes them.
Responses use `Cache-Control: no-store`; clients disable caching.

## Consent, transport and compatibility

Only the existing explicit outgoing intent plus matching fresh ready, or explicit
Answer plus microphone permission, may start a credential request. Incoming knock,
ringing or background notification cannot mint credentials or open media. Before
both Call and Answer, disclose that relay mode exposes address/timing/volume
metadata to the operator, while direct compatibility exposes IP to the peer;
audio remains encrypted between authenticated endpoints in either mode. A valid
response creates libwebrtc with the two returned URLs and relay-only ICE. It never
turns DTLS-SRTP termination over to coturn: authenticated peer SDP/fingerprint and
all existing E2EE/control checks still apply. Failure to allocate/connect ends the
call within its existing deadline; no silent direct fallback after credentials
were offered. Neither retransmission nor network change resets consent/deadlines.

One cancellable, bounded voice network lane is separate from text send/receive.
At most one current request and one latest replacement may exist; superseded
queued work is removed. Responses must pass transport-generation and call-generation
checks on their owners. Cancel/terminal/auth-loss closes only the voice connection,
drops credentials/pending work and never captures audio from a delayed callback.
The controller exposes an authorizing state while this request is pending and
advances to connecting only after this generation passes metadata validation.
No network work blocks the native state owner or Android UI. The existing two
text lanes retain their limits; this extension permits one additional bounded
voice HTTP connection during negotiation only. Successful voice transport is
closed after the response. Its bounded eight-second connect/read operations never
extend the call's45-second setup deadline.

The existing first ambiguous401 may retry once with a freshly signed nonce; a
second401 terminates local call authority. No other implicit retry/remint occurs.
A disabled new issuer returns authenticated404 `turn_disabled`. An old v2 server
may return generic404 on this absent route: a valid pinned-origin404 permits the
retained direct-ICE compatibility mode, disclosed before user consent. It is
capability absence, **not** proof of account authorization; the fresh authenticated
E2EE call handshake remains required. A pre-session legacy server also stays in
that disclosed compatibility mode. Redirects, TLS mismatch, malformed200, timeout,
429,5xx or authorization failure never trigger this fallback. A404 for this
optional route does not discard an otherwise valid text session or force legacy
text rediscovery.

## Configuration and relay resources

Server startup defaults to issuer disabled. Enabling requires both an explicit
secret-file path and relay IPv4 matching the configured saved HTTPS realm;
the exact environment names are `PARANOID_TURN_SECRET_FILE` and
`PARANOID_TURN_RELAY_IP`. Partial/invalid configuration fails startup. The offline
native command `paranoid-server voice-turn-capabilities` returns exactly
`{"api":1,"issuer":"signed-session-turn-v1"}`. A new controller package verifies
that actual binary capability before claiming issuer support; existing exact
self-service/deployment capability objects remain unchanged. The secret is exactly64 lowercase
ASCII hex bytes, no newline, file mode0400 or0600 without special bits, regular
non-symlink with one hard link, owner root or runtime effective UID. Its path is
absolute. Open read-only with no-follow and nonblocking flags before checking the
opened file metadata, so a FIFO cannot hang startup; read at most65bytes and
require exactly64. A maintained OS primitive supplies the effective UID, never an
environment variable or shell command. Verify metadata on the opened file. Paths can be environment configuration;
secret contents cannot be environment values or process arguments. Never log the
secret, credentials or configuration file contents. The package retains an isolated root-owned0600 master. Existing messaging runs
as a user unit whose manager cannot read that master: authorized installation
provides a separate issuer source owned by that runtime user at0400, and a
root-owned0400 source for the dedicated system TURN unit. Each unit uses
`LoadCredential` for its own runtime copy. The existing messaging controller
currently removes PARANOID environment variables; its explicit allowlisted
secret-path/relay-IP forwarding and exact user-unit template and closed controller config/release-file-set capability bump
are part of the server package and must be tested. Coturn cannot directly read a
LoadCredential file: a tiny versioned launcher validates the runtime credential,
creates a private0600 runtime configuration from the pinned template plus its
secret line, and execs the pinned binary with only that config path in argv. No existing live unit is changed by building.

The proposed coturn package pins4.18.0 and its source/dependency hashes, licenses
and exact binary/runtime closure. Deployment host157.180.49.125 only. Listeners
TCP+UDP34781; relayUDP40000-40015; no DNS/TLS changes. Dedicated
`paranoid-turn.service`/unprivileged user and separate versioned files, secret and
bounded logs. Disable unauthenticated STUN and TCP peer relay. Set `cli=0` and assert port5766
is closed: upstream4.18.0 `no-cli` is a deprecated no-op. Keep mobility disabled;
deny loopback, private, link-local, multicast and reserved peers. Two relay-only
clients using this same server must reach each other at its own public relay
address: permit that own IPv4 only on UDP40000-40015 through the dedicated
TURN UID egress policy, deny its other own-host destinations. A blanket own-IP
peer ban would break same-relay calls. Exact prepared firewall rules and isolated
packet tests must demonstrate this port exception; no live rules change.
Public configuration never reuses a loopback test allowlist.

Initial limits: four allocations per temporary username,16 total,128000bytes/s
per allocation,512000bytes/s aggregate, maximum allocation lifetime60seconds.
Use actual coturn option semantics and test the effective limits. Both UDP and
TCP URL gathering are tested rather than assuming one allocation per endpoint.
The relay holds no media keys, but sees addresses, timing and volume. API account
revocation blocks **new issuance**; previously issued bearer credentials can
allocate/refresh until expiry, Unmodified coturn4.18.0 checks REST expiry on credential lookup, but caches the
key for later controls, so repeated authenticated refresh can bypass that check.
Its lifetime normalization also raises zero/small requests to600seconds before an
`else if` maximum clamp, bypassing a configured maximum below600seconds.
The proposed package therefore requires two narrow, hash-pinned source patches:

1. The password-stage condition performs upstream credential lookup on every
   first pass (`can_resume`), even when a cached HMAC/password exists. The async
   callback clears cached HMAC/password presence before processing its own result;
   only success reinstates the key. This prevents another queued success from
   supplying a key to a failed/expired lookup resume. The existing lookup checks
   REST timestamp and integrity; the resume pass must not recurse. No new crypto
   or timestamp parser is introduced. Exact proposed patch and upstream hashes
   are inputs to the fresh design review before the packaged source is modified.
2. Apply the configured maximum allocation lifetime unconditionally after upstream
   default/minimum normalization. Zero/omitted and1..599second requests must not
   bypass the60second deployment maximum; explicit Refresh deletion remains zero
   according to the enclosing method's existing handling.

Expired credentials then cannot authenticate new allocation/refresh/permission/
channel-bind controls. Existing ChannelData and unauthenticated Send indications may continue until
the last allocation expires. The residual is credential expiry +60seconds + one
second of timestamp granularity + scheduling delay between the auth worker
expiry check and the relay-thread lifetime grant, assuming no relay wall-clock
rollback. The actual expiry test must measure and report that scheduling margin;
no architectural zero-delay or strict61second wall-clock guarantee is claimed. A relay wall-clock rollback
can extend REST expiry and is an explicit trusted-host/time risk, not an E2EE
or immediate remote-revocation guarantee. Actual tests must show the unmodified
failures and patched refusal/drain, including the unchanged async resume and
normal refresh paths. These patches require the fresh design/final review; an
upstream version label alone cannot identify this modified package. Honest
call endpoints still stop under the separate authenticated heartbeat bound.

## Tests, deployment and rollback

Required RED/GREEN: fixed native selector/context; real HTTP/PostgreSQL/session
route/body/context/nonce/replay/changed-binding/revocation; disabled and invalid
configuration; account/global/capacity limits; strict client parsing, old404
compatibility, no fallback for other failures, no disclosure or stale capture;
real coturn HMAC acceptance/wrong and expired credential rejection; actual full
app E2EE+relay+decoded bidirectional media with text beside it and cleanup/redial.
Test injected clock boundaries honestly; do not label simulated expiry as an
elapsed1200-second test. Test source hashing and signed APK correspondence.

All builds/listeners/tests remain isolated and locally owned. Separate server and
Android PRs declare their exact dependency. Server rollback is a same-data prior
binary with issuance disabled, no schema downgrade/reset; client rollback needs a
higher versionCode and the retained signer. The prepared deployment request must
include exact package/config/unit/server-diff hashes, host/ports, secret isolation,
readiness/denial tests and exact rollback actions. Running it needs separate reviewed
owner authorization; no current live unit, firewall, DNS, DB or phone is changed.

## Later bounded deployment authority — 2026-09-10

The [one-host owner record and REQ-DEPLOY-003](../operations/voice-single-host.md)
supply the separately required location/port authorization after actual tests and
fresh review, with one coordinated installer and preserved TLS/data/identity.
No API, credential lifetime, allocation cap, E2EE, consent or peer policy is
relaxed by that amendment. Missing retained-allocation/ACL/runtime tests remain
NOT RUN; ADR-0012 stays proposed.

The single-host candidate's production unit contract excludes merged systemd
drop-ins and stale loaded configuration. Updates stop the previous owned relay
before selecting new code, and rollback verifies the prior active executable
before restoring owned ingress. Process identity alone is not transport readiness
or relay acceptance. Full rehearsal availability remains empty while the new
VM runner is implemented; the mandatory production gate stays structurally
unsatisfiable. Message-only fixture results cannot authorize exposure.

The candidate [VM rehearsal contract](../operations/voice-vm-rehearsal.md) adds
required `evidence_path` and `fixture_kit_path` to the production rehearsal gate.
Both referenced files and contained case logs are read and verified; exact kit,
production intent/plan, both fixture modes, shared implementation and component
identity must correspond. Matching issuer/relay gates reference those verified
case hashes. The current-boot fixture boundary independently computes its topology
digest. This changes installer evidence validation only; wire/credential/media
contracts and production acceptance requirements are unchanged. Real execution
and independent exact artifact/runtime review are still pending.

## Systemd runtime-copy compatibility 2026-09-10

The source/master/installer and both issuer loaders retain the0400/0600 contract
above. The dedicated relay runtime reader is now implemented separately, following
[actual synthetic metadata measurement and Opus design review](../project/evidence/voice-ready-20260910/README.md).
Offline descriptor tests pass; actual system/user primitive delivery and persistent
production-unit acceptance remain separate pending gates at this checkpoint.

Both launcher operations require literal `CREDENTIALS_DIRECTORY` equal to
`/run/credentials/paranoid-turn.service`, literal `RUNTIME_DIRECTORY=/run/paranoid-turn`
and nonzero effective UID. There is no runtime pathname or policy override for
fixtures. Traverse `/`, `run`, `credentials`, and the fixed unit component using
held directory descriptors, single components, `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`.
Ancestors must be root-owned real directories without special bits or group/other
write. The final directory/file pair must be exactly one of:

- Root-owned0550 directory and root-owned0440 regular file with exactly five
  version2 Linux access-ACL entries: USER_OBJ, USER=current service UID, GROUP_OBJ,
  MASK, OTHER, in that order. Non-USER IDs equal0xffffffff. Directory permissions
  are5/5/0/5/0; file permissions4/4/0/4/0. The owning numeric GID is unrestricted
  because its ACL permission is zero. No other named grant or permission is allowed.
- Service-euid-owned0500 directory and service-euid-owned0400 regular file. Group
  mask and other bits are zero, so no effective non-owner access is possible;
  this branch makes no ACL call. It is a retained safe fallback, not a newly
  observed system-manager result.

Mixed pairs, runtime0600, speculative0750 directories and mode-only0440 acceptance
are refused. Select the pair by fd metadata before invoking any ACL syscall.
For the ACL pair only, use already-loaded libc via `ctypes.CDLL(None,use_errno=True)`
and one fixed44byte `fgetxattr` per descriptor with explicit integer/pointer/ssize_t
ABI. Reject missing symbol, every error or other length; decode explicit
little-endian version/entries and compare the complete ordered tuple. No library
search, size-discovery loop, alternative parser or permission fixup.

The file must have one link and size64. Open it relative to the held credential
directory with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`, then inspect ACL, read at
most65bytes and require the unchanged64 lowercase ASCII hex format on that same
fd. Recheck dev/inode/mode/uid/gid/nlink/size/ctime_ns of file and final directory
after reading. Directory nlink/size are compared only against their own initial
snapshot, never pinned to fixture constants. Unrelated global `/run` directory
ctime changes are not a rejection condition. Root remains trusted, including
mount replacement; nofollow does not prevent a malicious root mount substitution.

The temporary-directory `runtime.py check` recipe is withdrawn. Offline tests
use private descriptor primitives; production check/run have identical path and
credential restrictions. No plan/preflight or builder caller used that recipe.
A systemd layout change fails relay startup and requires a newly reviewed owned
synthetic measurement plus TDD/code/artifact review, never chmod/chown/ACL removal
or a second secret-copy path. Runtime changes require a new manifest and package;
old artifacts do not acquire these semantics retroactively.
