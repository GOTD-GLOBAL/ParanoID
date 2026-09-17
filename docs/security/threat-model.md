---
status: draft
owner: security
last_reviewed: 2026-09-09
---

# Threat model

The candidate [full voice VM rehearsal boundary](voice-turn-threats.md#candidate-full-vm-profile-and-evidence-integrity--2026-09-10)
adds explicit current-boot isolation and root-controlled execution-evidence binding.
The full runner, packet/current-call acceptance and deployment remain pending;
root-authored reports are not remote attestation and do not replace independent
actual source/artifact/runtime review.

This is an initial discovery scaffold, not evidence that ParanoID is secure.
Update it whenever assets, actors, data flows, dependencies, or trust boundaries
change.

## Active scoped analysis

The [PR34 native-exit correction](../clients/android/pr34-integration-review.md)
removes raw system trace/description from UI exports, moves diagnostic reads and
acknowledgement off main, and acknowledges only an explicitly dismissed report.
Existing Java exception reports remain unredacted and explicitly disclosed; no
automatic upload or general secret-free crash-report guarantee is claimed.

The [same-key renewal proposal](../rfcs/tls-same-key-automation.md#threats-and-alternatives)
adds unattended dedicated-user lifecycle authority, durable public-certificate
journals and fail-closed drift recovery. No key export/generation, DB restore/reset,
client repin or neighboring-service change is permitted. Same-owner/root compromise,
clock correctness, power-loss durability and failure monitoring remain explicit
risks; file guards are not a security boundary against a compromised service account.
The [runbook](../operations/tls-auto-renewal.md) requires fresh review and runtime
verification before installation; no public-readiness or phone acceptance claim.

The [voice trust delta](voice-v1-threats.md) adds proposed authenticated call
controls, fresh consent/nonces, WebRTC dependency and microphone/media/network
boundaries for RFC-0017/ADR-0011. It is analysis before runtime implementation;
actual evidence and independent reviews are separate gates. No live relay or
public-network expansion is authorized by this design.

The [realtime trust delta](realtime-v1-threats.md) records signed-session,
independent state/network, Android foreground connection and encrypted same-data
maintenance boundaries for RFC-0015/proposed ADR-0010. Final Fable product/script
reviews and bounded closure preceded the [actual attended rollout](../operations/realtime-rollout-2026-09-09.md).
Hosted synthetic messaging passed; the original intermittent readiness-failure
cause remains UNKNOWN, with attended recovery and physical-device limits retained.
This dated outcome does not convert earlier scoped evidence below into a human
audit or permanent architecture approval.

The [single-server text delta](server-v0-threats.md) identifies proposed controls
and test mappings for RFC-0006, distinguishing implemented development/client
controls and the native alpha deployment delta from outstanding gates. This is
not a completed independent security review.

The [proposed registration delta](server-v0-threats.md#proposed-phone-key-registration-delta)
adds RFC-0010 key/admission/QR/migration risks and now distinguishes the locally
tested candidate from the unchanged hosted endpoint and unperformed phone tests.

The [key deployment delta](key-deployment-delta.md) covers the separately authorized
migration candidate: durable cutover, verified restore, same-host process ownership
and bounded TLS connection lifetimes. Live cutover remains gated on final review.

The [self-service v2 delta](self-service-v2-threats.md) covers RFC-0012 and draft
ADR-0007: automatic bounded registration, general routing, request proof, offline
migration and downgrade authority. It includes data flows, residual risk owners
and exact tests, distinguishing independent local server evidence from unrun
client/phone/deployment gates. SR-01 documentation re-review remains pending.

The [fresh-only v2 deployment amendment](self-service-v2-threats.md#fresh-only-deployment-amendment)
adds explicit exact-IP exposure and scoped destructive replacement risks. The owner
requested no old-server-DB backup for this one operation; TLS/phone state/neighbors
remain protected. Local implementation is not host deployment or review approval.

The [asymmetric retained-context draft](../rfcs/0016-asymmetric-retained-context.md#security-delta-and-replay-boundary)
records a confirmed client profile-selection defect, the ambiguity of signed
original labels, and why classified context failures cannot authorize blanket
replay. No relaxed context verification or new negotiation protocol is implemented.

## First-contact incoming trust-boundary draft

The owner-selected [RFC-0014](../rfcs/0014-first-contact-incoming.md) and
[exact protocol](../protocol/first-contact-v1.md) authorize local clean-install
implementation/build for REQ-MSG-005. The **2026-09-09 Telegram** clarification
is recorded verbatim there; no permalink/message ID or ADR acceptance is invented.
Historic migration/recovery is outside this candidate's gate, not claimed fixed.
Independent implementation review remains required before publication/delivery.

The new boundary is admission of an unknown signed sender directly to a visible,
replyable `network_unverified` dialog. Cryptographic device possession is not
real-world identity verification; only explicit exact same-key QR comparison
upgrades trust. No recipient approval, server directory or label inference is used.

| Threat | Required candidate control and verification |
| --- | --- |
| Relay or peer substitutes sender/recipient/channel | Strict root/device ContactV2 plus intro-v2 signature; account-sorted endpoint/realm/SPKI commitment; exact local recipient and immutable existing pins; negative signature/recipient tests |
| Wrapper stripping or signed wrong inner context | Mandatory frame2 for all new text/receipts; exact PlainV1 v1/channel/realm/from/to/id; no v0/alternate-context retry; independently re-signed wrong-inner test |
| Invalid ciphertext consumes Account/prekey or allocates peer | Whole-state transient transaction with explicit accepted/duplicate/rejected outcome; reject all pin/Account/ratchet/history/outbox/replay changes, including failures after decrypt/receipt construction |
| Forged/unknown receipt produces false delivery | Strict same-channel target sender/id/inner digest matched to retained outgoing commitment after server acceptance; unknown target no allocation, no synthetic receipt/receipt loop |
| Replay, changed immutable ciphertext or conflicting sequence | Non-evicting sender/id + sequence/channel/outer/inner ledger; exact duplicates no-op across reload; conflict before decrypt; monotonic cursor |
| Network peer launders verification or replaces keys | Unverified enum distinct from explicit QR trust, immutable credential/device/auth/original bundle/fallback, trust-only same-key upgrade |
| Unknown-sender growth or blocked spam | 16 network-unverified/64 peers; existing 8 MiB snapshot, 200 history, 400 outbox, 8 sessions, 1000 accepted IDs per peer; 16 KiB frame/20-event pages; bounded block suppressing display/receipts |
| Crash or ambiguous persistence publishes non-durable state | Core candidate sealed atomically before UI/network; failure freezes; exact wrapped outbox retry and persistent reopen exercised over real JVM/JNI |
| Old incompatible client data silently reset | New explicit core3/outer4 validation; unsupported older snapshots preserved and visibly refused; no migration/reset path in this clean candidate |

A single retained Olm Account owns private prekeys across per-peer sessions.
The reusable fallback's weaker initial forward secrecy remains a scoped tradeoff.
Signed device/contact/fallback linkage is exposed to the relay and device envelope
signatures make origin claims transferable; deniability differs from Olm alone.
Stable IDs, routing, timing, length and IP metadata remain visible. Server
suppression/reordering, Sybil fairness, endpoint compromise, recovery, key rotation
and multiple devices remain unresolved. No production/privacy guarantee follows.

Human residual risk/decision owner: martadvix-web; ADR-0009 stays proposed.
Current local implementation/test status is in [current-state](../project/current-state.md)
and the candidate evidence record. Existing historical asymmetric RED is separately
reported; no historical hosted message recovery or live data change is performed.

## Android APK ceiling removal candidate (2026-09-13)

[RFC-0013's amendment](../rfcs/0013-user-triggered-android-updates.md#owner-amendment-no-fixed-apk-size-ceiling-2026-09-13)
replaces the fixed APK cap, not transport/signer/integrity checks. Server heap is
fixed-buffer, with anonymous disk snapshots to preserve verified-byte identity.
Two response-lifetime permits bound snapshot concurrency; malformed metadata,
wrong size/hash, unsafe file paths and I/O failures fail closed. Disk exhaustion
is a remaining availability risk: snapshot storage scales with artifact size,
space checks race unrelated writers, and tmpfs is unsuitable for large APKs.
Metadata remains 8192-byte bounded. Copy deadline cannot preempt stalled kernel
I/O. Operator-controlled disk-backed publication storage and disk headroom are
required. A compromised publisher can deny service but cannot grant installer
trust. Client free-space checks are advisory, exact-size accounting is overflow
safe, failures clean only dedicated update files. All signer/package/version,
pinned TLS and native consent gates remain; app identity/history are untouched.
Independent review precedes release; no production DoS guarantee is made.

## Security objectives

RFC-0013 adds the [bounded Android publication boundary](../server/android-updates.md#filesystem-and-resource-boundary):
untrusted metadata/APK bytes, safe descriptor-relative reads and bounded hash work.
The local controller selects `ROOT/updates` only for v2, outside DB storage, without
directory creation or inherited feed authority in legacy modes. Missing feed
does not authorize a fallback path. Publisher/client signer verification,
independent combined-artifact review and phone installer consent remain required;
server transport integrity is not a production secure-update claim.

- Prevent unauthorized control of accounts, devices, servers, names, and plugins.
- Protect message content according to a precisely defined encryption scope.
- Minimize and document metadata visible to servers, peers, chains, push services,
  hosting providers, plugins, and observers.
- Preserve authenticity and integrity across synchronization and federation.
- Remain recoverable from operational failure without inventing hidden account
  recovery that contradicts paranoid mode.
- Make security-relevant state and failures understandable to users and operators.

## Assets

- recovery seed and derived key material;
- device authorization and revocation state;
- blockchain identity and nickname control;
- message content, attachments, call media, and local caches;
- contact, group, timing, presence, and federation metadata;
- server credentials, backups, configuration, logs, and update channel;
- plugin permissions, tokens, data, and outputs;
- enterprise CRM and organizational data.

## Candidate threat actors

- opportunistic remote attacker;
- malicious or compromised server operator;
- malicious federation peer;
- malicious plugin or AI service;
- compromised client device;
- hosting, DNS, network, push-notification, or blockchain observer;
- spammer, bot operator, name squatter, or economic-abuse actor;
- insider with administrative access;
- software supply-chain attacker;
- coercive or censoring network authority.

## Trust boundaries to define

1. Recovery seed to device key derivation.
2. Device to local secure storage and operating system services. The candidate
   iOS shape of this boundary — Keychain
   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), a Data Protection file,
   the AES-256-GCM sealed snapshot and the install marker that replaces
   Android's key-and-file exclusive-or — is in
   [the iOS client delta](ios-client-threats.md#storage-boundary-threat-model-boundary-2).
3. Client to home server.
4. Server to federation peer.
5. Client or service to blockchain RPC and naming contracts.
6. Core system to plugin, bot, CRM, and AI services.
7. Server to database, object storage, backup, update, and observability systems.
8. Mobile client to platform push notification services. Used by the Android
   client through the [push wake gateway](push-wake-threats.md)
   ([RFC-0020](../rfcs/0020-push-wake.md)); **not used by the candidate iOS
   client (track A)**, which registers no APNs or PushKit token and declares no
   `aps-environment`, so it introduces no new observer of delivery timing and
   delivers only while the application is open. The consequences of that choice
   are in
   [the iOS client delta](ios-client-threats.md#foreground-only-delivery-threat-model-boundary-8).

## Priority discovery questions

- Which keys exist, where are they generated, and what can each key authorize?
- How are devices added, verified, rotated, revoked, and recovered?
- What happens when the blockchain or RPC provider is unavailable, reorganized,
  censored, expensive, or inconsistent?
- Which identity and relationship metadata becomes permanently public on-chain?
- Who can correlate a nickname, wallet, server, IP address, and social graph?
- Which messaging modes are end-to-end encrypted, and who are the endpoints?
- How are group membership changes authenticated and reflected in key state?
- How do federation peers limit spam, replay, enumeration, and resource exhaustion?
- Can plugins or enterprise controls access plaintext, keys, metadata, or recovery
  paths, and how is that consent represented?
- How are binaries, containers, mobile releases, and automatic updates signed and
  verified?

## Isolated Android probe boundary

The [experimental probe](../../spikes/002-android-bootstrap/README.md) creates
both participants in one Android process, with synthetic data and no network
permission. Java invokes a native Rust self-test; JNI returns only a result code.
No production identity, contact authentication, server trust, durable key storage,
or recovery protocol is implemented. Its public test pickle key is unsuitable for
real storage. Dependency supply-chain, native load and platform compatibility risks
remain; local tamper/replay checks are not a production security review or E2EE
claim. Independent qualified human review remains required for production
adoption or use outside an explicitly approved private test-data alpha scope;
that bounded exception follows the
[canonical review policy](../governance/documentation-policy.md#closed-alpha-review-exception).

## Required analysis artifacts

Before the first architecture is accepted, add data-flow diagrams, STRIDE-style
threat enumeration, abuse cases, risk ratings, mitigations, residual risk owners,
and verification tests. Before release, perform independent cryptographic and
application security review appropriate to the claims being made.

## Overnight realtime delta

[The signed-session trust delta](realtime-v1-threats.md) covers replay, terminal
revocation, wait races, native outbox signing, state/network separation, opt-in
Android foreground notifications and encrypted same-data update/rollback.
Actual final review and deployment evidence remain separate gates.

## Voice relay delta

[Voice TURN threats](voice-turn-threats.md) cover the issuer authorization lock,
volatile credentials, metadata, relay resource and peer limits, credential
residual authority and secret/package boundaries. Offline builds pass; required
retained-allocation expiry and ACL packet tests remain NOT RUN after a platform
interruption. Public deployment is not authorized by local task scope.

## iOS client delta — 2026-09-13

[The iOS client delta](ios-client-threats.md) records the platform boundaries a
second client adds without changing a wire contract: Keychain and Data
Protection with the install-marker reinstall rule, leaf-SPKI evaluation on
`Security.framework` instead of system trust with
[App Transport Security off](ios-client-threats.md#app-transport-security-is-off-and-why-that-removes-nothing)
(it refused the self-signed leaf on a public IP before the pinning delegate
ran; found on the phone against the hosted server), the digest-pinned WebRTC
binary, foreground-only delivery that leaves boundary 8 unused, Apple as a
TestFlight installation observer, and the closed export-compliance gate. It
also names what was not observed on the device (Data Protection classes, a
real recording, a locked screen) as `NOT RUN`; a real camera read a QR on the
phone on 2026-09-13. Proposed under
[RFC-0021](../rfcs/0021-ios-client.md) and
[ADR-0014](../decisions/0014-ios-client.md); physical-device evidence exists
from 2026-09-13 (a signed build on an iPhone 16 Pro Max against the local
stand, one hosted registration from the phone), and no independent human
review exists.

## One-host coordinator work — 2026-09-10

The [voice installer threat delta](voice-turn-threats.md#unified-installer-trust-boundary--2026-09-10)
tracks the proposed privileged coordinator, preserved messaging identity/data,
exclusive credentials, scoped network ownership and interrupted-update recovery.
The [owner amendment](../operations/voice-single-host.md) supplies conditional
existing-host authority, not passing runtime acceptance or permanent ADR approval.
