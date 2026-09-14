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

| Threat | Control in this client | How it was checked |
| --- | --- | --- |
| Snapshot readable from a stolen, powered-on, locked device | AES-256-GCM key in the Keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable; file at `.completeUntilFirstUserAuthentication` | `KeychainStoreTests` reads the stored attributes back. The **class the file write asks for cannot be observed in a simulator** — the simulator has no Data Protection and reports no protection class, and the 2026-09-13 device smoke did not measure it either, so this stays `NOT RUN` |
| Snapshot or key leaves the device through backup or iCloud | Backup exclusion set on the candidate **before** the rename, because the flag lives on the inode; the Keychain item is this-device-only and not synchronizable | Storage unit tests on the commit order; device behaviour is `NOT RUN` (not measured in the 2026-09-13 device smoke) |
| Torn write or silent truncation adopts a corrupt ratchet | Five durable steps in one order — temp write, `F_FULLFSYNC`, `rename(2)`, byte-exact read-back, directory `F_FULLFSYNC` — and any failure sets `isBroken` for the rest of the process | `SnapshotStoreTests` with injected file-system faults, one step at a time |
| A reinstall silently resurrects a stale identity, or freezes forever | Install marker (`paranoid.install.v1`): with no marker **and no state file** the stale Keychain key is deleted and a new identity is created; with the marker present, a file without a key freezes, and so does a key without a file unless the container's own positive fact, `paranoid.firstrun.pending.v1`, says its first run has committed nothing | `KeychainStoreTests` marker matrix, 12 tests on the signed simulator, 2026-09-14, and the `reinstall` scenario of `test_sim_text.py` (run before the pending fact replaced the commit record; the reinstall row it drives is unchanged); both `CLAIMED` |
| A stale key is reused to "recover" state | Never: the absent-marker path deletes rather than reuses | same |
| A lost install marker destroys the wrapping key of a state file that is still there | Never: the marker is a `UserDefaults` entry and the file is not, so a file that survived disproves the reinstall the missing marker suggests. That launch freezes with both halves intact and records nothing, because a freeze is recoverable by a person and a deleted key is recoverable by nobody | `KeychainStoreTests.testAMissingMarkerBesideAStateFileKeepsTheKeyAndTheFile` reopens the retained file after the refusal — run on the signed simulator on 2026-09-14, in the 12-test run above; `SnapshotStoreTests` covers the same rule on the host — `CLAIMED` |
| A first run that creates no identity freezes the client for good | Never: this client creates the Keychain item while opening, so a Welcome screen closed without «Создать ID» leaves a key and no file. The container's own fact `paranoid.firstrun.pending.v1` — recorded by the launch that found it holding neither half, before the key was created, and withdrawn by the first commit after the candidate is synced and before the rename — is what separates that from a file that has gone missing; only its presence opens the client | `KeychainStoreTests.testAKeyFromAnInterruptedFirstRunIsNotAFreeze`, same 2026-09-14 signed simulator run, and the host `SnapshotStoreTests` startup cases; both `CLAIMED` |
| The upgrade to this build reads an existing installation as a container that committed nothing, and starts a second identity over it | Never: no build before 2026-09-14 wrote the pending fact, so on every container that exists today — the contributor's iPhone is one — a key without a file freezes, until a launch finds the container holding neither a key nor a file and records the fact there. `paranoid.install.v1` is not reinterpreted, so the first launch of this build deletes no key and re-freezes no retained file. The first correction's `paranoid.snapshot.v1` and `paranoid.install.v2` are gone from the code; a container that still holds them is read on the pending fact alone | `KeychainStoreTests.testAnInstallationFromAnEarlierBuildKeepsFreezingOverItsMissingFile` on the real Keychain, same 2026-09-14 signed simulator run, plus the two host cases in `SnapshotStoreTests` (the frozen upgrade, with the first correction's facts seeded and ignored, and the launch that records the fact); `CLAIMED` |
| A commit's bookkeeping is lost or never persisted while the install markers survive, the state file is lost after it, and the launch reads the surviving key as an interrupted first run (the owner reviewer's P1 on `67af672`) | Never by a lost record: no fact whose *absence* opens the client exists any more — after a commit the container holds `paranoid.install.v1` and nothing else — so a key without a file opens only on the container's positive word, and a word never written, not persisted or rolled back freezes with the key kept and nothing recorded | `SnapshotStoreTests.testALostCommitRecordAndALostFileDoNotAddUpToAFreshInstall` (red on a scratch copy of `67af672`, green here), `testAPendingFactWhoseWriteNeverPersistedFreezesTheKeyItExplained` on a defaults backend whose same-process read-back succeeds and whose write vanishes on reopening, and `KeychainStoreTests.testALostCommitRecordAndALostFileFreezeWithTheKeyKept` on the real Keychain; `CLAIMED` |
| The first commit's withdrawal of the pending fact is acknowledged but never persisted, and the state file is lost before any launch has seen it | **Open.** The stale claim beside the key of a lost file opens the client. Bounded, not closed: the withdrawal happens after the candidate is synced and before the rename, so a process killed mid-commit cannot leave a committed file beside the claim; the launch that opens the file withdraws it again; a container that refuses the withdrawal breaks the store with nothing renamed. The window is the one between the first commit and the next launch, where the earlier record was exposed on every later day. Closing it needs a fact that lives with the key (an attribute of the Keychain item) or a key created at the first commit as Android's is — a storage-boundary decision for the owner | `SnapshotStoreTests.testTheRemainderAWithdrawalThatNeverPersistedAndAFileLostBeforeAnyLaunchSawIt`, a strict `XCTExpectFailure`: it passes only while the gap is open and fails by passing the day the gap is closed. A disclosure, not a control; no device run |
| A backup taken during an interrupted first run — which lasts until the user returns to «Создать ID», and can be days — is restored onto the same device after an identity was committed | **Not told apart, and not closable on the device.** The restore takes the defaults and, from an encrypted backup, the `ThisDeviceOnly` key back to the same moment, and the excluded file does not come back, so the launch after it finds the pending fact beside the key and starts a first run over that key: the interrupted-first-run row, reached by the user's own hand on any later day. Neither closing design in the row above separates it — a fact on the Keychain item is restored with the item, and a key created at the first commit is absent from the copy, which is the row that holds neither half. What the restore costs is the identity it had already discarded with the file, the cost the accepted restore onto a new iPhone carries too, with the key reused instead of new; what the launch lacks is the visible refusal | The same two observations as the interrupted first run, so `SnapshotStoreTests.testAKeyFromAFirstRunThatCommittedNothingIsNotAFreeze` is its executable form; a real restore onto a device is `NOT RUN`. A disclosure, not a control |

The install marker is the one place where this client's behaviour differs from
`docs/clients/core/self-service.md`. It is recorded as a platform note and a
doc-to-code finding, not as an owner-approved relaxation of the fail-closed
rule: nothing here replaces a state file, starts an identity while a usable
state exists, or deletes a key any file could still need. Five of the rows
are the two owner-side reviews of 2026-09-14: before the first, a missing
marker deleted the key of a retained file, and a key left by an interrupted
first run froze every later launch; the fix for the second recorded "a state
file has been committed here" and read its absence as evidence, and the
second review showed that a lost record and a lost file then added up to a
fresh identity over the old key. The fact is now the pending first run, read
only by its presence; the loss that inversion does not close is the open row
above, and the restore nothing on the device can refuse is the row after it.
The storage boundary of RFC-0021 and the candidate ADR-0014 carry the same
matrix and the same remainder. None of the three documents is an owner
approval, which is still outstanding.

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
