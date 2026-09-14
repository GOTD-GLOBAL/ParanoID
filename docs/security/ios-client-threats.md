---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-14
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

The lazy wrapping-key correction replaces the defaults-based first-run exception;
old candidate evidence does not certify this implementation. RFC-0021 and ADR-0014
remain proposed. [Mac verification handoff](../clients/ios/lazy-storage-handoff.md).

| Threat | Current control / limitation | Verification |
| --- | --- | --- |
| Key or plaintext exposure | Unchanged AES-256-GCM, Keychain accessibility/account and non-synchronizing item; backup exclusion on candidate inode before rename | Existing codec tests; current real-Keychain/device execution NOT RUN |
| Torn file commit adopts invalid state | Unchanged write, F_FULLFSYNC, rename, byte-exact readback, directory F_FULLFSYNC; errors terminal before candidate adoption/network | Existing injected file-fault tests retained; current Mac run NOT RUN |
| Welcome exit creates orphan key | Persistent-key SnapshotStore construction/load never create a key; first commit does | LazySnapshotKeyTests and isolated-account KeychainStoreTests; runtime NOT RUN |
| Lost pending/commit bookkeeping authorizes fresh identity over lost history | No such defaults are read. Marker-present key/file XOR always freezes, including stale positive pending flags | Former expected failure is a strict SnapshotStoreTests regression; runtime NOT RUN |
| Missing install marker destroys usable snapshot key | A surviving file forces freeze before deletion or marker recording | Host and real-Keychain regression sources retained; current runtime NOT RUN |
| First commit creates key, then file commit fails | Key retained, store terminal, next launch freezes. This is an availability cost, not atomic cross-store commit | LazySnapshotKeyTests fault cases; real interruption/power-loss NOT RUN |
| Key changes/disappears while a store is running | Persistent adapter rechecks key/file continuity and remembers its acquired key; no substitution or regeneration | New runtime regression sources; Mac run NOT RUN |
| Upgrade from an earlier candidate | Valid key/file pair unchanged; orphan eager key remains frozen even if old pending defaults survive | Upgrade matrix in both suites; physical-device upgrade NOT RUN |
| Whole-container loss/reinstall or rollback of both key and file | Existing install.v1 reinstall distinction remains; no independent recovery/rollback witness exists | Explicit residual limitation; physical backup/restore NOT RUN |

Only missing marker plus missing file retains the proposed stale reinstall-key
cleanup. An existing file always protects its key from that cleanup. Keychain and
file durability are separate: failure after creating a first key may require human
recovery and is never repaired by deleting that key. No change to E2EE, realm/pin,
snapshot schema, server persistence or automatic recovery is authorized here.

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

1. **Physical-device evidence is thin.** A signed Debug build ran on one
   iPhone (iPhone 16 Pro Max, iOS 26.6.1) on 2026-09-13 against the local
   stand: an identity was created on the device, a QR was read with the real
   camera, texts crossed with receipts and one call to a simulator connected
   with video from the device. Data Protection classes, backup exclusion, a
   locked screen during dialling, a relayed call and a real screen recording
   cannot be observed in a simulator and were not measured on the device
   either; everything about them is `NOT RUN`.
2. **No independent human review** of the storage, trust and call code; the
   closed-alpha exception permits an independent AI review in a fresh context
   and does not replace item 6.
3. **Three hosted accounts exist** (`hosted_registrations` is 3): one from the
   build Mac through `service-bridge` on 2026-09-13 while diagnosing the
   phone's TLS failure, one from the physical iPhone (Release build,
   2026-09-13, after the ATS fix below, the contributor's own and still in
   use), and one diagnostic account registered from the build Mac on
   2026-09-14 to measure the hosted server from a second identity while
   diagnosing issue #38. The third exists because the first is permanently
   unreachable: that fixture kept its wrapping key in process memory only, so
   its state file no longer opens and the account is registered but dead. The
   diagnostic account keeps its key beside its state, carries no messages and
   no contacts, and has no relationship to either of the other two. All three
   fall under the owner's answer to RFC-0021 question 4 (no fixed budget), and
   the server has no delete path, so all three are permanent. On 2026-09-14 an
   unscheduled joint session on that server exchanged text both ways with the
   owner's Android — both checks appeared — and carried one call, dialled by
   the owner, with video in both directions. Those results are the
   contributor's report, marked `SHOWN (joint, reported)` in
   [stage1-text.md](../project/evidence/ios-client-20260913/stage1-text.md) and
   [stage2-voice.md](../project/evidence/ios-client-20260913/stage2-voice.md),
   and no owner "go" permalink exists for the session. What remains untested is
   named there: the owner never scanned this client's QR, no fingerprint was
   compared aloud, and this client has never dialled an Android from a phone.
   The line-by-line protocol comparison is still a Mac-only `CLAIMED` check.
   **After that session the phone stopped connecting and has not recovered**:
   its signed read of `/v2/messages` times out while `/health` answers in
   0.2 s with the pin unchanged, and no client restart clears it. Measured in
   pull request #36 and tracked as issue #38, which records it as a
   server-side condition; the pinned handshake did not fail, so it is not a
   trust finding.
4. **iOS CI has run once.** `.github/workflows/ios.yml` ran on pull request
   #36 (draft, 2026-09-14): `ios-static` passed, as did the docs workflow and
   the server workflow's `client-core-and-tls` and `native-package` jobs.
   There is no macOS runner, so nothing in that workflow opens a simulator,
   builds an app or touches a stand — the security-relevant behaviour of this
   client is proven locally or not at all.
5. **The alpha break of call-v2**: this client cannot call an Android build
   older than v16, by design.
6. **Open on the device (2026-09-13/14).** After a network drop the phone
   stayed at «Нет подключения» while the server answered from the Mac and the
   pinned key was unchanged; the cause is under investigation on the branch
   and no device logs were collected.

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
