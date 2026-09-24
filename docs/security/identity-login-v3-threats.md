---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-24
---

# Identity-login v3 threat delta

Scope and residual risk owner: Sergey Maltsev, bounded local synthetic-data alpha
in [RFC0027](../rfcs/0027-solana-server-authentication.md). No approval implied.
[Protocol](../protocol/identity-login-v3.md) is a candidate, not implemented defense.

## Flows and boundaries

Android Keystore-wrapped owner -> typed Rust signer -> pinned TLS -> server proof
verifier -> configured trusted Devnet RPC -> serialized membership transaction.
Independent device auth -> device status / existing v2 proof/session transport.
Opaque E2EE messages remain client-owned; server sees public identity, membership,
transport metadata, and routing but never seed/content keys. Public registry does
not contain membership, device list, server address or social graph.

| Threat | Proposed mitigation / test |
| --- | --- |
| Spoofing registry or owner | Strict dual signatures, pins, paired finalized PDAs; AUTH-01/02 |
| Tamper/replay across routes/servers | LP roles/purpose/path, consumed random challenge; AUTH-01/03 |
| Lost response or competing replacements | Immutable intent, original generation, single ss_meta lock; AUTH-04 |
| Retired key rebind under another identity | Global lifetime unique bindings/tombstones; AUTH-05 |
| Membership enumeration | No DB/RPC/state-sensitive response before proof; AUTH-03 |
| RPC/DB resource exhaustion | Fixed global caps, no untrusted-key limiter map, post-proof RPC; AUTH-02/08 |
| Legacy or long-lived-session bypass | Isolated router/realm, per-operation generation gate; AUTH-05 |
| Contact substitution | No old-account rekey, immutable pins, new exchange; AUTH-06 |
| False delivery to retired inbox | Locked recipient check before insert/ACK; AUTH-06 |
| Push metadata after retirement | Delete token atomically, revalidate dispatch; in-flight request residual; AUTH-05 |
| Misleading device/media recovery | Device revocation is not owner-key revocation or remote erasure; AUTH-07/08 |

## Residual risks and review exit

Seed/owner-phone compromise allows competing replacement; current registry cannot
rotate owner. One/day cooldown can block a legitimate recovery too. Eight-generation
cap can exhaust future recovery, while existing traffic/status remains available.
Peer caps can exhaust after repeated re-adds. These must be visible in owner
acceptance and app UI; no silent wipe or evict-to-pass workaround. Strong recovery,
peer archival and production-scale lifecycle need subsequent reviewed protocols.

RPC can lie; program may change after inspection; pinned finalized HTTPS is not
chain verification. Devnet reset prevents new mutations while existing committed
bindings may keep operating; do not silently trust a new genesis. Servers can
correlate public owners. Already downloaded data, authorized response bytes,
dispatched FCM wake and ongoing direct media cannot be revoked retroactively.

AUTH-01..08 are defined by the contract; no execution evidence is claimed here.
Public vectors check encoding/crypto only, never RPC, SQL races or phone lifecycle.
Independent review and permanent human disposition are still required; qualified
human review before sensitive/public production use remains mandatory.
