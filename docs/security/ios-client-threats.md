---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-13
---

# iOS client trust delta (RFC-0021, proposed ADR-0014)

Delta for the candidate native iOS client of
[REQ-CLIENT-001](../product/requirements.md). Extends
[the threat model](threat-model.md), [the realtime delta](realtime-v1-threats.md),
[the voice delta](voice-v1-threats.md), [the video delta](video-v1-threats.md)
and [the voice TURN delta](voice-turn-threats.md); everything in those remains
required. The wire contracts are unchanged, so this document adds **platform**
boundaries only: Apple's storage, Apple's trust evaluation, Apple's
distribution, and one binary media dependency.

Human residual risk owner: `martadvix-web`. Private synthetic data only. No
human audit, no production assurance and no completed independent review is
claimed here; independent qualified human review of identity, cryptography,
persistence and application security remains required before this client
carries real communication
([policy item 6](../governance/documentation-policy.md#closed-alpha-review-exception)).

```text
Unchanged: core identity/Olm/frame2 -> self-service v2 over pinned TLS -> server
New device boundary: Keychain (AfterFirstUnlockThisDeviceOnly) + Data Protection
  file -> AES-256-GCM sealed core snapshot -> install marker (UserDefaults)
New trust boundary: Security.framework leaf-SPKI evaluation, no system trust
New dependency: WebRTC.xcframework 150.7871.01 (digest-pinned, no runtime fetch)
New observer: Apple as TestFlight distributor and installation observer
Not used: APNs / PushKit / background refresh / CallKit (foreground-only)
```

## Storage boundary (threat-model boundary 2)

| Threat | Control in this client | How it was checked |
| --- | --- | --- |
| Snapshot readable from a stolen, powered-on, locked device | AES-256-GCM key in the Keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable; file at `.completeUntilFirstUserAuthentication` | `KeychainStoreTests` reads the stored attributes back. The **class the file write asks for cannot be observed in a simulator** — the simulator has no Data Protection and reports no protection class, so this is `NOT RUN` until a device test |
| Snapshot or key leaves the device through backup or iCloud | Backup exclusion set on the candidate **before** the rename, because the flag lives on the inode; the Keychain item is this-device-only and not synchronizable | Storage unit tests on the commit order; device behaviour is `NOT RUN` |
| Torn write or silent truncation adopts a corrupt ratchet | Five durable steps in one order — temp write, `F_FULLFSYNC`, `rename(2)`, byte-exact read-back, directory `F_FULLFSYNC` — and any failure sets `isBroken` for the rest of the process | `SnapshotStoreTests` with injected file-system faults, one step at a time |
| A reinstall silently resurrects a stale identity, or freezes forever | Install marker (`paranoid.install.v1`): with no marker the stale Keychain key is **deleted** and a new identity is created; with the marker present, key-without-file and file-without-key both freeze | `KeychainStoreTests` marker matrix (signed simulator run) and the `reinstall` scenario of `test_sim_text.py`; both `CLAIMED` |
| A stale key is reused to "recover" state | Never: the absent-marker path deletes rather than reuses | same |

The install marker is the one place where this client's behaviour differs from
`docs/clients/core/self-service.md`. It is recorded as a platform note and a
doc-to-code finding, not as an owner-approved relaxation of the fail-closed
rule; the rule is unchanged whenever the marker is present.

## Transport trust boundary

| Threat | Control | How it was checked |
| --- | --- | --- |
| A system or user-installed CA issues a certificate for the realm | The client evaluates the leaf itself on `Security.framework` primitives and never delegates to system trust: one self-signed certificate, constant-time SPKI-digest equality with the saved pin, validity, no CA basic constraint, no unknown critical extension, signature verified with the leaf key, server-auth usage and EKU, EC ≥ 256 / RSA ≥ 2048, SAN-only host match, TLS 1.2 minimum, no client certificate | Eight leaf checks plus the session rules numbered 9. Six of the eight (1, 2, 3, 6, 7, 8) are broken over real loopback sockets by `check-pinned-tls.py`; checks 4 and 5 have no socket fixture and are proven on parsed certificates by `PinnedTrustTests`, with the corrupted leaf also driven through `PinnedSessionDelegate` on a real `SecTrust`. The TLS-1.1 fixture for check 9 runs only where the local OpenSSL still offers TLS 1.1 and prints `SKIPPED` otherwise. `X509LeafTests` covers the parser, `test_realtime_transport.py` the socket rules — `CLAIMED`, offline |
| A compiled default silently overrides what the user enrolled with | Saved trust always wins; a fixture disagreeing with a saved pair is refused; hosted defaults apply only in a Release build or under an explicit flag | `SelfServiceClientTests`, `ProofFlowTests` |
| The pin expires mid-alpha and a build cannot be updated | The leaf was renewed **with the same key** on 2026-09-13, so the pin is unchanged and the new validity ends 2026-12-12T07:38:09Z; verified from the build Mac by a TLS handshake with no HTTP request | `hosted-preflight.json` (local evidence, not committed) |
| A key rotation silently breaks more than the transport | Out of scope here, and deliberately: the pin feeds the first-contact channel transcript, so a key change invalidates enrolled contacts. It needs its own deploy-trust RFC | RFC-0021 question 7 |

## Foreground-only delivery (threat-model boundary 8)

This client registers no APNs or PushKit token, declares no `aps-environment`,
schedules no background task and implements no CallKit. Boundary 8 of the
threat model — *mobile client to platform push notification services* — is
therefore **not used by the iOS client**; the
[push wake delta](push-wake-threats.md) describes the Android gateway of
[RFC-0020](../rfcs/0020-push-wake.md) and no iOS half exists.

| Consequence | Nature |
| --- | --- |
| No push observer learns that a message arrived for this device | privacy gain, and the reason the limitation is acceptable for the alpha |
| A message sent while the application is closed is delivered **after** it is opened; a call to a closed or locked iPhone is not answered and the caller sees the expected 45-second `timeout` | user-visible functional limitation, stated on the connection screen and written into the stage-2 scenarios as the **expected** result |
| The `audio` background mode is the only background capability, and only for a call already running | checked by the bundle gate: `UIBackgroundModes` exactly `[audio]`, no `voip`, no `aps-environment` |

Accepting a push path later is a new proposal, not a configuration change: it
adds an observer of delivery timing and re-opens boundary 8 for this client.

## Media, camera and screen capture

| Threat | Control | Gap |
| --- | --- | --- |
| Camera or microphone opens without consent | Microphone only from an explicit Call or Answer; camera only from an explicit toggle or video-call intent; ring, knock, ready and a peer `media` control open nothing | none; source-contract tests, `CLAIMED` |
| A forged `media` control turns a camera on or claims one is off | `media` is informative, validated like a heartbeat and grants no authority; frames come only from the authenticated DTLS-SRTP transport | none |
| An oversized description escapes the frame budget | Refused at 9000 bytes before the core, never rewritten; the measured frame2 ceiling is 10040 bytes | none |
| A screen recording, mirror or AirPlay captures the peer's camera | The video stage is covered while `UIScreen.isCaptured` and says so | **partial**: the controls stay visible by design |
| A **screenshot** captures the call | none possible — iOS has no API that refuses a screenshot; a client only learns afterwards | **open gap**, not parity with Android's `FLAG_SECURE` |
| The **app-switcher snapshot** captures the call as the app leaves the screen | not covered | **open gap** |

Both gaps are stated in [the client documentation](../clients/ios/voice-calls.md)
and in [verification.md](../clients/ios/verification.md) rather than left to be
discovered by a user. They are a property of the platform, not a defect to be
fixed in this pull request.

## Supply chain and distribution

| Threat | Control | Residual |
| --- | --- | --- |
| A substituted WebRTC binary | Archive and per-slice SHA-256 verified **before** extraction; no runtime download; licence text bundled; the embedded framework in an unsigned bundle is weighed against the pinned slice | A signed bundle is re-signed by Xcode, so the bundle-level digest is `SKIPPED` and the pin is enforced at extraction only |
| A dependency drifting away from the Android build | `bridge/Cargo.lock` is seeded from `clients/core/Cargo.lock`; a divergence fails the build | none |
| Apple as an observer | TestFlight distribution makes Apple an observer of **who installs the application and when**, and of the metadata in an App Store Connect account. It never sees message content or keys | accepted for the alpha; recorded because it is a new actor that Android sideloading did not have |
| Export controls treated as a checkbox | `ITSAppUsesNonExemptEncryption = YES` is prepared, **not** satisfied: the classification, the regime, the filing entity and any Apple compliance code are unrecorded, and Apple applies the requirement to TestFlight too | **gate closed**: [export compliance](../clients/ios/export-compliance.md); the upload row stays `NOT RUN` |
| A signing credential entering the repository | Team ID and App Store Connect key come only from the environment; the bundle gate refuses `.p12`, `.p8`, `.env` and `.mobileprovision` inside the bundle | none |

## Residual risks carried into the pull request

1. **No physical-device evidence at all.** Data Protection classes, the real
   camera, a real network, a locked screen and a real recording cannot be
   observed in a simulator. Everything about them is `NOT RUN`.
2. **No independent human review** of the storage, trust and call code; the
   closed-alpha exception permits an independent AI review in a fresh context
   and does not replace item 6.
3. **No hosted account exists** (`hosted_registrations` is zero), so nothing in
   this client has been exercised against the live server beyond a TLS
   handshake.
4. **No iOS CI run yet.** `.github/workflows/ios.yml` lands with this pull
   request and has never executed on a runner; every check was run locally on
   the pinned build Mac. There is no macOS runner, so nothing in that workflow
   opens a simulator, builds an app or touches a stand — the security-relevant
   behaviour of this client is proven locally or not at all.
5. **The alpha break of call-v2**: this client cannot call an Android build
   older than v16, by design.

## App Transport Security is off, and why that removes nothing

`Info.plist` sets `NSAppTransportSecurity` to `NSAllowsArbitraryLoads = YES`.
This was not a shortcut: measured on a physical iPhone against the hosted
server, ATS refuses a self-signed leaf on a public IP address before any
`URLSession` delegate is consulted (`NSURLErrorDomain -1200`, stream error
`-9802`), while it lets the same profile through on a private address, which is
why the local stand never showed it. ATS's exception and pinning lists take
domain names only, and the server has none — `NSPinnedDomains` with the correct
SPKI was tried and does not match an IP literal.

What ATS would have contributed is a CA-chain check. This client never relies
on one: every session is built by `PinnedSessionDelegate`, which requires the
pinned SubjectPublicKeyInfo digest, a self-signed leaf whose signature verifies
with its own key, a TLS 1.2 floor, no proxies, no redirects and no cookies; the
string contract test refuses any `URLSession` created outside it. That is the
same posture as Android, whose pinned trust manager replaces the platform
store. The residual difference is procedural: Apple asks for a justification
of this key at submission, and this section is it.
