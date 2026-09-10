---
status: draft
owner: server
last_reviewed: 2026-09-10
---

# Local signed-session TURN issuer

[REQ-CALL-006](../product/voice-relay.md),
[RFC-0018](../rfcs/0018-voice-turn.md) and proposed
[ADR-0012](../decisions/0012-voice-turn.md) govern this implementation. The
[canonical voice TURN contract](../protocol/voice-turn-v1.md) owns the exact
request, response, quota, consent and relay-expiry rules. This component issues
temporary credentials; it does not listen for TURN traffic or terminate media.

## Runtime integration

`server/src/voice_turn.rs` contains private-file configuration, a bounded sliding
issuance budget and coturn REST HMAC generation. `self_service_http.rs` adds one
fixed GET route using the existing signed session transcript, nonce ledger and
active account/device authorization. The TURN branch reads the current
`ss_meta` version/realm/pin under the same transaction lock before accepting the
full retained credential binding. It performs that check before disabled 404 too.
The ordinary message operations and persistent schema remain unchanged.

`self_service::app(pool)` is the retained default-disabled wrapper.
`app_with_turn(pool, config)` receives an explicit optional `TurnConfig`;
environment access stays in `main.rs`. The runtime accepts only both
`PARANOID_TURN_SECRET_FILE` and `PARANOID_TURN_RELAY_IP`, or neither. Local mode
permits IPv4 loopback; public mode rejects nonpublic addresses. The saved HTTPS
realm must name that exact literal IPv4. Public deployment remains separately
authorized; the local constructor is not a way to widen public listener scope.

The opaque config is neither Debug nor Serialize. Opening the private file uses
`O_NOFOLLOW|O_NONBLOCK`; descriptor metadata must prove regular type, one hard
link, root/effective-user ownership and exact 0400/0600 mode. A bounded read accepts
exactly 64 lowercase ASCII hex bytes without a newline. The already locked
`libc` 0.2.189 supplies the effective UID; `ring` 0.17.14 supplies HMAC-SHA1 for
coturn interoperability. No new cipher, signature scheme or media key derivation
is implemented here. The ASCII secret is not hex-decoded.

The existing offline capability responses stay byte-compatible in JSON shape.
The separate `voice-turn-capabilities` command identifies the actual issuer
binary to the versioned controller; a controller cannot infer support from its
own code or manifest alone. Configured startup failure retains the existing
generic stderr message, without paths, secrets, credential bodies or DB errors.

## Verification

Run the focused tests with an unprivileged user, Rust 1.98.1, PostgreSQL 16,
Python 3 with `cryptography`, curl and OpenSSL available:

```sh
python3 server/check-voice-turn.py
```

The runner creates an owned temporary PostgreSQL cluster with TCP disabled.
Every HTTP operation uses the actual server and SQL state. Test identities sign
registration and session transcripts independently of the server helper.
Capacity fixtures seed valid synthetic registered identities to avoid the
unrelated registration cap; they still obtain and use genuine signed sessions.
No mocked SQL or bearer authorization replaces the device proof.

The 14 integration tests cover the fixed route/body/query and complete session
context; duplicate authorization headers and a concurrent replay winner; locked
revocation and mutated/missing meta; strict random HMAC responses; account/global
quotas and restart; unsafe secret files and partial configuration; native
capability; and actual generated CA+SPKI-verified TLS with ordinary signed
messages afterward. Two additional unit tests check sliding time boundaries and
capacity rejection without live-bucket eviction. The test probes print no keys
or issued credential bodies.

The complete retained server gate includes this target automatically:

```sh
python3 scripts/check-server.py
cargo fmt --manifest-path server/Cargo.toml -- --check
cargo clippy --locked --manifest-path server/Cargo.toml --all-targets -- -D warnings
```

The full gate retains actual five-minute session expiry and TLS socket lifetime
tests. Focused success does not replace it. Same-data default-disabled reopening
is tested; it is not a claim that an older binary, deployed host or live rollback
was exercised by that test. Final component evidence records those outcomes
separately from the later package and application integration gates.

## Remaining boundaries

Issuance authorization is not call consent or media authentication. Android owns
the fresh authenticated call handshake, permission, generation and cleanup checks.
The relay package owns actual allocation authentication, resource/peer policy and
expiry-drain tests, including its separately reviewed coturn derivative. Correct
issuer HMAC alone does not prove relay behavior or decoded media. Live listeners,
firewall changes, existing-service restart, DNS and phone operations require the
separate reviewed deployment scope.
