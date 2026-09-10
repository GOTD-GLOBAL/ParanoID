---
status: proposed
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Voice relay threat delta

[REQ-CALL-006](../product/voice-relay.md),
[RFC-0018](../rfcs/0018-voice-turn.md), proposed
[ADR-0012](../decisions/0012-voice-turn.md) and the single
[canonical API/relay contract](../protocol/voice-turn-v1.md) define the design.
This threat analysis precedes implementation and does not assert passing tests.

| Boundary / threat | Proposed control and required evidence |
| --- | --- |
| Unauthenticated or changed/revoked device mints credentials | Existing complete signed session transcript/nonce, locked ss_meta current realm/pin/version and full active binding recheck; actual SQL/context/replay/race negatives |
| Native becomes arbitrary signing oracle | Only fixed turn selector, exact GET path, empty body, no caller ID/path/nonce; JNI negative context/selector tests |
| Malicious issuer redirects client or disables privacy silently | Exact saved realm IPv4 and fixed34781 URLs; strict response/expiry validation; relay-only after success, no failure downgrade; only pinned404/pre-session legacy compatibility direct path with explicit IP disclosure |
| TURN credential extraction or cache | Volatile per-generation response; no state/history/signaling/logging; no-store; separate private LoadCredential sources and runtime paths, no secret arguments |
| Delayed network result captures after cancellation | Bounded separate voice lane and generation checks, close/drop on termination; actual held-response/cancel/redial and no-microphone tests |
| Revoke prevents minting but cached relay key refreshes forever | Two mandatory narrowly reviewed coturn patches: revalidate upstream REST credentials on each authenticated control, cap lifetime after normalization; actual original RED/patched expiry and media-drain GREEN |
| Expiry and clock error | 1200second credential, client lifetime/monotonic clamp,15minute max call; relay clock is trusted and rollback can extend expiry. No immediate remote revocation claim |
| Authorized actor exhausts relay or minting | Four issuances per binding/minute,32global/minute,1024bounded buckets; four allocations/username,16total, per/all bandwidth caps and60second allocation lifetime; no live quota eviction |
| Relay used for internal scan or unauthenticated STUN | Exact public listener, nonpublic peer denial plus dedicated-UID own-host egress limited to its relay UDP range, no unauthenticated STUN/TCP peer/CLI; test actual deny and effective resource configuration |
| Relay/media MITM | Coturn forwards peer-authenticated DTLS-SRTP; existing native E2EE exact SDP/fingerprint/ICE/context validation remains mandatory; no plaintext/media keys at issuer/relay |
| Added dependency or patch supply chain | Pinned coturn/source/runtime closure, patches and exactbinaryhash, license notices, reproducible package manifest; actual package rebuild and smoke tests |
| Deployment crosses existing trust boundary | Separate componentPR, defaultdisabled issuer, exact systemd user-unit/controller forwarding and system relay files; no live mutation without separate reviewed owner authorization |

Server rollback disables issuer and returns to prior same-data binary; it does not
reset DB/schema, identities, TLS or messaging history. Relay rollback stops only
the named new unit, removes only recorded listener/relay rules and isolated secrets,
and preserves incident evidence and existing service. Android rollback requires
newer versionCode with retained signer. Physical audio/Bluetooth/Doze/mobile handover
are not proven by synthetic app/media or server tests.

Fresh Fable design gate opened on2026-09-09 with concrete corrections: include
auth-to-relay scheduling delay in the expiry residual, use `cli=0` and assert5766
closed, explicit query/body rejection and locked metadata comparison, dual-mode
pre-consent disclosure, and a versioned runtime credential launcher/controller
capability bump. The gate permits implementation, not release or deployment.

## Unified installer trust boundary — 2026-09-10

[REQ-DEPLOY-003](../operations/voice-single-host.md) introduces one privileged
coordinator across the existing messaging user manager and isolated relay system
unit. The review must verify package provenance before execution, trusted path
ancestors and no-follow single-link locks/secrets, exact unit ownership, exclusive
credential generation, a durable transaction journal and preserved current data.
Preflight must reject unknown/partial installs, port conflicts and network policy
drift. Own-host relay UDP is the only own-host egress exception; the dedicated UID
must not reach neighboring services. Installing rules must not flush or replace
existing firewall state. Syntax tests cannot establish packet enforcement.
Power loss and partial failure must leave recoverable recorded state and no
unreviewed relay exposure. No new sensitive-data or permanent architecture scope.

The candidate checks the loaded systemd fragment, empty `DropInPaths`,
`NeedDaemonReload=no`, exact command and dedicated system-unit identity alongside
base-file hashes. A global or per-unit override is an unsupported configuration;
the installer refuses it rather than deleting/adopting it. Production updates
journal and stop the verified previous relay before code/unit cutover. New and
restored ingress require the expected active packaged executable hash; this is
process identity evidence, not CLI/expiry/packet/media acceptance. These production
paths have offline regressions only and remain behind the unavailable full-relay
profile gate. Required final Fable review has not been obtained.

## Measured systemd credential boundary — 2026-09-10

[The runtime-copy contract](../protocol/voice-turn-v1.md#systemd-runtime-copy-compatibility-2026-09-10)
separates source0400/0600 from systemd's measured root-owned named-UID ACL copy.
Ordinary0440 group access remains rejected. Exact fd-based five-entry ACL checks
require GROUP_OBJ/OTHER0 and sole named service-UID access, with fixed-size typed
libc inspection and metadata rechecks. Both launcher operations pin the literal
production paths; no arbitrary-path compatibility or secret fixup is introduced.
The zero-mask service-owned0500/0400 fallback avoids an unnecessary ACL dependency.
Root/mount administration and installed Python/libc remain trusted. Systemd layout
changes fail closed; no unmeasured0750 alternative is accepted.

[Offline tests](../../deploy/turn/test_systemd_credentials.py) cover real synthetic
xattrs, bounded getter/ABI negatives, unsafe descriptors and paths, mixed layouts,
format and metadata changes. Root ownership is simulated in those unprivileged
fixtures; they are not actual root/systemd delivery or persistent-unit evidence.
The separate actual metadata-only observation used a transient codex unit and
read no credential content. Actual primitive matrix and exact production unit/UID
confirmation remain needed. No relay/packet/CLI/expiry/full-rehearsal/current-call
or deployment gate is closed by these results. Generic/source/installer/alpha/Rust
credential guards remain unchanged and are rechecked at final review.

## Disposable verification boundary — 2026-09-10

The [source-bound VM capability observation](../project/evidence/voice-ready-20260910/vm-isolation-result.json)
ran on the separate development host, with an unprivileged TCG QEMU process,
no NIC, disk, host filesystem share, vsock, guest agent or control listener.
QMP used inherited pipes. Official signed Ubuntu kernel/BusyBox inputs formed a
RAM-only initramfs; complete tooling and library hashes were retained. Before
cont, actual argv/fd/device inventory was checked; the guest then reported only
loopback, no external routes and no production markers, and powered off cleanly.
This proves the observed run only. QEMU, its resolved host libraries, signed input
trust anchor and the owner-controlled runner remain trusted. It does not prove
future test isolation or any relay/installer acceptance. Future fixture source
and guest-only network changes require their own bounded independent review and
fresh running isolation checks; no prior denied worker/resource may be rerouted.
