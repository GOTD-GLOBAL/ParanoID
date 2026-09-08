---
status: draft
owner: development
decision_owner: martadvix-web
review_mode: closed-alpha-ai
required_reviewers: []
last_reviewed: 2026-09-08
---

# RFC-0008: Executable text development slice

This is an implementation-review proposal under the owner's direct request to
build send/receive, not an accepted architecture. ADR-0003 remains in force.
Do not deploy, merge as accepted architecture, or use real sensitive data before
scope/decision evidence and independent review are complete. RFC-0006 remains the
full alpha target, not a claim that this smaller implementation meets every gate.

## Deployment acceptance clarified by the founder

The founder proposes testing the actual deployed instance on the existing
production host, not stopping at loopback clients. Simple Linux deployment is
part of REQ-DEPLOY-001 and must be exercised with the same versioned package used
for the hosted test. Local transport tests below are developer checks only, not
the product acceptance endpoint or a reason to defer the first hosted test.

Recommend an isolated closed-alpha instance on that host: separate service
identity, database/data directory and explicit resource/port boundaries; HTTPS
and no direct public database port. Production-host placement does not mean
production readiness. Only synthetic/non-sensitive test data, with E2EE before
real phone messaging; never expose the loopback-only transport harness publicly.

Package startup, health checks, configuration, upgrade/rollback and backup/restore
as a reproducible Linux workflow rather than a sequence of undocumented SSH edits.
A container/Compose deployment is a candidate, not yet an accepted or exercised
installation contract. Keep a documented systemd alternative if host constraints
make installing a container engine inappropriate. Inspect the existing host and
services with separately authorized read-only access before selecting that path.
Explicit bounded deployment authorization is required before host changes; the
founder's proposal is not permission to replace or restart neighboring services.

## Bounded implementation scope

One loopback development server, private local PostgreSQL and two disposable
clients. Rust/Axum/SQLx as already compiled candidates. Retain ciphertext until
an explicit future deletion operation; no automatic purge. Stable message IDs,
transactional per-room sequence, identical retry returns original result and
changed retry fails. Receive by cursor; server commit is not recipient delivery.

The first runnable increment implements transport/storage tests using synthetic
opaque ciphertext. It is not a plaintext messaging mode, an E2EE client or a
phone-to-phone milestone by itself. The executable refuses non-loopback binding.
Authentication for this bounded transport test is two independently generated
256-bit bearer credentials supplied through local configuration; no registration,
root identity, recovery or production device authentication is adopted. Tokens
must never enter URLs, logs or committed files. Closed admission and real E2EE
peer authentication remain required before phones use the service.

## Data and protocol proposal

`POST /v0/messages`: authenticated sender, UUID message ID, base64 opaque
ciphertext, recipient device. One fixed room contains the two configured devices.
Server rejects unknown fields, invalid encoding, oversized/empty payload, unknown
recipient and self-send. The authenticated credential determines the sender.
Unique (sender, message ID); conflicts never overwrite ciphertext. Room row lock
serializes sequence allocation and commit. Success response only after commit.

`GET /v0/messages?after=N`: authenticated recipient fetches only its incoming
messages in sequence order, bounded page size. Cursor is last returned sequence;
empty pages preserve the submitted cursor. No delivery/read status is implied by
fetch. Authenticated peer receipts will be ciphertext messages from actual clients,
not server-invented second check marks.

## Threat and operational limits

Loopback HTTP is for same-host synthetic tests only; there is no remote TLS or
production installation in this increment. Local account/root compromise exposes
test configuration. PostgreSQL runs as this unprivileged user, with no TCP listener
and a private Unix-socket directory in the local test runner. The executable
validates private socket directories before connecting. CI explicitly opts into
a dedicated `paranoid_test` service on 127.0.0.1:5432; that narrow exception is
not permission to reuse existing databases. See `server/README.md` for bounds.
Server metadata includes sender, recipient, sequence, time/size and ciphertext.
Logs/errors exclude payloads, credentials and database connection strings.

REQ-MSG-002/004 and REQ-SEC-001 motivate retry, retention and no-plaintext logging
checks. Proposed checks: auth rejection, exact retries, conflicting retries,
concurrent sends, recipient isolation, restart persistence, offline cursor sync,
invalid version/payload and size limits. Tests must actually execute PostgreSQL.

## Next client increment proposed for review

A separate Rust client core and Android shell are the next increment, not a
production identity system. Each disposable client generates its own Olm account.
Two testers explicitly exchange and confirm public identity/prekey bundles out
of band; the server never supplies a trusted contact key. Pin one peer, reject
silent replacement, authenticate inner realm/device/message context, and use
library Olm ciphertext for text and delivery receipts. No plaintext fallback.

Commit local ratchet/history/cursor/outbox together before network effects. The
Android shell must encrypt the entire atomic snapshot with a platform-keystore
key and refuse to regenerate identity after a decryption/storage error. Retain
unsent encrypted bytes for retries. Limit the development client to 200 history
messages, fail visibly rather than evict. Losing client keys makes old history
unreadable; no recovery or production account migration is promised here.

Peer verification is explicit manual public-code exchange in this increment,
not an implemented root-signed device credential or QR scanner. Android requires
HTTPS for remote use. Server tokens are provisioned separately for each tester,
not included in public pairing bundles. iOS is not built here; the shared core
must remain independent of Android storage/network/UI. Review these boundaries
before any hosted phone test. This paragraph does not authorize a rollout.

## IP HTTPS with an explicitly pinned server key

The founder selected IP-based HTTPS with a self-signed certificate and a pinned
server public key, rather than requiring a domain. Proposed trust input is the
SHA-256 digest of the leaf SubjectPublicKeyInfo DER, provided out of band by the
operator, separate from the device bearer token and peer Olm pairing code.

No trust-all manager, hostname-verification bypass or system-wide TLS override.
Require the configured pin, certificate validity, server-auth use and an exact SAN
for the requested address. Keep platform hostname verification, disable redirects,
and permit only TLS 1.2/1.3. Persist the pin with the encrypted client snapshot;
never fetch/accept a replacement from an untrusted server or silently repin.
Certificate renewal under the same key can retain the pin; key rotation requires
a separately reviewed explicit re-enrollment path. This does not approve a public
deployment, relax the server development gate, or supply missing device evidence.

## Disposition

Draft, not production or full-alpha acceptance. Owner request authorizes work in
the implementation branch; durable scope/architecture acceptance remains pending.
Independent AI review and exact execution results are required before presenting
the increment for adoption. No phone exchange, E2EE integration, root recovery,
container deployment or iOS capability is claimed by the transport increment.
