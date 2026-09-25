---
status: draft
owner: security
decision_owner: martadvix-web
last_reviewed: 2026-09-26
---

# iOS push delivery threat delta (RFC-0027, draft)

Delta for threat-model boundary 8 (*mobile client to platform push
notification services*) on the iOS client, proposed by
[RFC-0027](../rfcs/0027-ios-background-delivery.md). It extends
[the threat model](threat-model.md), [the iOS client delta](ios-client-threats.md)
and [the push wake delta](push-wake-threats.md); everything in those remains
required.

**Status: draft.** Nothing here is implemented or accepted. Until ADR-0016 is
accepted, the recorded state stays: the iOS client does not use boundary 8
(`docs/security/ios-client-threats.md:82-98`,
`docs/security/threat-model.md:290-297`). Every check below is `NOT RUN`.
RFC-0020, on which the gateway rests, is itself still `proposed`
(`docs/rfcs/0020-push-wake.md:2`).

Human residual risk owner: `martadvix-web`. Private synthetic data only. No
human audit or production assurance is claimed. The exit gate of
[policy item 6](../governance/documentation-policy.md#closed-alpha-review-exception)
applies.

```text
Unchanged: core identity/Olm/frame2 -> self-service v2 over pinned TLS -> server
Changed boundary 8 (iOS): server/gateway --(constant alert push, HTTP/2, ES256 JWT)--> Apple APNs --> iPhone
Push class: visible, system-rendered alert (RFC-0020's data-only class does not carry over)
New credential: APNs topic-specific production key (.p8), gateway host only (systemd credential)
New server state: ss_apns_tokens (account -> APNs device token), no time column, only with APNs configured
Stage 2 only: notification service extension (second process, read-only) that fetches
  over pinned TLS; App Group mirror of the sealed snapshot; nse-cursor.v1; shared
  Keychain group (read); read-only request signer; PushKit relay -> CallKit
Not used: server VoIP pushes, background (content-available) pushes, BGTaskScheduler,
  communication notifications, intent donation, CallKit Recents
```

## Observers

| Observer | Learns (new) | Does not learn |
| --- | --- | --- |
| Apple (APNs), per push | The recipient device (token) and, through Apple's records, the Apple Account behind it: push-token requests "generally seek identifying details of the Apple Account associated with the device's push token, such as name, physical address and email address" ([Transparency Report](https://www.apple.com/legal/transparency/push-token.html)). That the device has ParanoID with push enabled. The gateway IP address, Team ID, Key ID, topic, priority, expiry and collapse identifier. The time of every wake. The delivery status. | From any single push: the sender, content, ciphertext, size, or whether it was a text, receipt, call control or first contact. Type, topic, priority, collapse identifier and payload are identical for all of them. |
| Apple (APNs), across pushes | Timing patterns (P13): a missed call is a knock wake followed by an `end` wake up to 45 s later (`docs/protocol/voice-v1.md:53`, `:114`); alternating wakes between two opted-in iPhones on a small gateway, and message-then-receipt wakes, expose conversation pairs. | Anything the timing does not carry. |
| Apple (device OS, stage 2) | That ParanoID reported an incoming call to CallKit, with the name "ParanoID" and a random handle. Whether this leaves the device is UNVERIFIED. | The caller's identity; no Recents entry; no Siri or intent donation; no SensorKit speech metrics (`SRResearchDataGeneration = NO`). |
| ParanoID server or gateway | That the account uses an Apple device with push enabled, and its APNs token. **Stage 2:** the device's IP address and the time of every wake-triggered fetch while the app is closed, from which it can infer delivery (P14); after a PushKit launch, the app's ordinary `ready` and delivery receipts (C9, C10). | Nothing about content. It already holds sender, recipient, ciphertext length, commit order and the contact graph (`docs/protocol/self-service-v2.md:56-60`, `server/self-service-schema.sql:17-29`). |
| Network observer near the phone | **Stage 2:** a TLS connection to the ParanoID server at every wake while the app is closed; today only while it is open. | Content, which stays inside TLS and E2EE. |
| Network observer near the gateway | HTTP/2 connections to `api.push.apple.com` and their timing. | Payload, which is inside TLS and constant anyway. |
| Contacts and other senders | **Stage 2:** whether a locked iPhone is on, if `ready` were sent before CallKit accepted the call (closed by C9); a second check while the phone stays locked after a PushKit launch (C10). | Anything in stage 1: the phone sends nothing while closed. |
| Someone holding the phone or a paired Apple Watch | That ParanoID is installed and when things arrived: lock screen, Notification Center and a paired Apple Watch ("If your iPhone is locked or asleep, you get notifications on your Apple Watch", [Apple Support 108369](https://support.apple.com/en-us/108369)); the notification store's timeline (N3). | Names, previews or thread grouping: none are ever posted. |
| Someone who seizes the server or a backup and also has legal process against Apple | The link from a ParanoID account to an Apple Account (name, address, email), from a stored token, or by matching commit times with Apple's per-token records even without one ([Apple Legal Process Guidelines, US, III.AA](https://www.apple.com/legal/privacy/law-enforcement-guidelines-us.pdf)). | Content, which stays E2EE. |

Apple states that devices "need a persistent connection to Apple's servers"
to use APNs ([Apple Support 102266](https://support.apple.com/en-us/102266)).
That this connection already exposes the device's IP address and online
status to Apple, independent of this app, is inferred, not documented. If the
inference holds, they are not a new channel.

## Threats

| ID | Threat | Mitigation | Check |
| --- | --- | --- | --- |
| P1 | Content or metadata leaves through Apple | Constant body `{"aps":{"alert":{"loc-key":"PARANOID_WAKE"},"sound":"default","mutable-content":1}}` and constant headers. No badge, sender, recipient, size, count or identifier. | [CI] server test asserts path, every header and the body bytes, and that account, device and ciphertext strings are absent |
| P2 | A single push reveals "a call is coming" | One push type (`alert`), one topic (the bundle ID), priority 10, for every envelope. No `voip` or `background` push and no `.voip` topic. The server cannot tell a call from text: calls are Olm `PlainV1` inside frame2 (`docs/protocol/voice-v1.md:19-25`). The timing signature of a missed call is not hidden; it is P13. | [CI] no other push type or topic can be built; review of invariant I2 |
| P3 | Forged banners with **arbitrary text**. The signing key plus the token table (a compromised gateway) can address every opted-in iPhone; iOS displays an alert push without `mutable-content` directly, and shows the original content whenever the extension does not run. The key alone cannot address a device. | Topic-specific key limited to production and `global.paranoid.messenger`, only on the gateway as a systemd `LoadCredential`; the environment carries only the path; strict file checks; the config type is not `Debug`; immediate revocation in the developer account. The app never acts on payload content: no deep links, no actions. | [CI] deploy test for credential delivery and permissions; a documented revocation runbook. **Residual:** forged banners until revocation. |
| P3a | The same class for the FCM key: for notification messages "the FCM SDK displays the message to end-user devices on behalf of the client app when it's running in the background" ([Firebase](https://firebase.google.com/docs/cloud-messaging/customize-messages/set-message-type)) | Not in `push-wake-threats.md` today. Proposed as an added row there. | Owner review |
| P4 | Forged registration binds a victim account to an attacker's token | Registration only over the signed session of the active device; one row per authenticated account (unchanged from RFC-0020) | [CI] unsigned request gets 401; `apns` registration with a valid session |
| P5 | An attacker registers a victim's token under the attacker's account | The attacker gains only the ability to wake the victim's device on the attacker's own traffic, bounded by the rate limit. The server never returns tokens. | Review: no API returns tokens |
| P6 | Wake spam: banner or battery abuse by any sender, including a first contact (REQ-MSG-005) | At most one wake per account per 10 s, plus at most one trailing wake; the 4096-account cap fails closed. Stage 2 silences blocked peers and non-text envelopes. | [CI] rate-limit and trailing-edge tests. **Residual:** one content-free banner per 10 s in stage 1. |
| P7 | A missed call because a knock falls inside the 10-second window | Trailing-edge coalescing (owner decides: both providers or APNs only) | [CI] a knock 3 s after a text gives exactly two wakes |
| P8 | A missed wake while a suspended iPhone still holds a `/v2/events` waiter | The client cancels the long-poll on entering the background. A wake suppressed by a waiter that ends without a non-empty page is re-sent (owner decides the provider scope). The protocol claims the guard is released on disconnect (`docs/protocol/realtime-v1.md:103-104`), untested. | [CI] aborted long-poll, then a commit, gives a wake (RED-first); [device] check |
| P9 | A stale token keeps a device reachable after reinstall or restore | Re-register on every opted-in launch. Empty token on opt-out, revoked authorization or identity reset. Compare-and-delete on `410` (Unregistered, ExpiredToken), `BadDeviceToken`, `DeviceTokenNotForTopic`. | [CI] response-mapping tests; [Mac] client unit test |
| P10 | A sandbox token or key is mixed with production | One environment per gateway. `aps-environment` is exact per build configuration. `BadDeviceToken` deletes the token. | [CI] bundle gate; server test |
| P11 | The token links a ParanoID account to an Apple Account | Opt-in only; deletion on opt-out and reset; tokens never logged; optional exclusion from backups (owner decision). Exclusion reduces the linkage but does not remove it: a live server holds the tokens, and commit times can be matched against Apple's per-token records even without a stored token. | Log review; deploy test if exclusion is chosen. **Residual:** accepted only if approved. |
| P12 | The gateway's test endpoint override is used in production | Loopback `h2c` only; refused in public mode (as `server/src/main.rs:141-155`) | [CI] startup test |
| P13 | Apple-side correlation of wake timing: call-attempt signatures (knock, then `end` within 45 s), conversation pairs (alternating or message-then-receipt wakes), and with Google for mixed Android and iOS pairs | None technical. Coalescing blurs bursts only. | **Accepted residual only if the owner accepts it**, the same class as Google in `push-wake-threats.md` |
| P14 | Stage 2: every wake makes the locked phone fetch, so the server and on-path observers learn the device IP and the fetch time, and the server can infer delivery although no receipt is sent | Stated in the opt-in card. The alternative, ciphertext inside the push, would make Apple store ciphertext and its size, and envelopes of up to 16384 bytes exceed the 4 KB payload. Fetch jitter is possible but costs call latency; not proposed by default. | Owner decision; [device] capture shows one fetch per wake and nothing else |
| P15 | Stage 2 auth-budget amplification: each wake costs a `POST /v2/auth/challenge` against the global budget of 8 auth requests/s (`server/src/self_service_http.rs:170-176`) and a `GET` against 20 requests/s, with 16 outstanding challenges globally (`docs/protocol/self-service-v2.md:84-86`) and 16 TLS sockets (`docs/protocol/realtime-v1.md:143`). Spam at a few dozen opted-in iPhones can block `POST /v2/session` for every client, Android included. | A separate, smaller challenge budget for extension reads; a global cap on APNs wakes per second sized against the auth budget; the extension's 5-second duplicate guard, counted from the start of the previous fetch, which on a hit skips the fetch and posts the stage 1 text with the fixed identifier instead of silencing, so a message committed after that fetch is never hidden (the cost is at most a false banner). An Android wake that finds no session also opens one, so the class probably applies to FCM too. | [CI] capacity test: spammed opted-in accounts do not push other accounts' `POST /v2/session` into 429; the same for FCM reconnects; [Mac] a push within 5 s of a completed fetch, after a new commit, shows the stage 1 text, never silence |
| P16 | The token table keeps a per-account last-launch time, because the FCM-style upsert rewrites `updated` on every registration (`server/src/self_service_http.rs:586`) and iOS re-registers on every launch | `ss_apns_tokens` has no time column, and an unchanged token writes nothing. The existing `ss_push_tokens.updated` (FCM) remains retained metadata: the time of the last FCM registration. | [CI] an unchanged re-registration writes nothing |
| P17 | Centralisation: the iOS users of every self-hosted server depend on the publisher's Apple team key and gateway (REQ-SERVER-001), and a local network without internet gets no wake at all (REQ-NET-001) | None in this RFC. A relay for other servers is a future deploy-trust proposal; Local Push Connectivity is a later complement that adds no Apple observer on configured networks ([Apple](https://developer.apple.com/documentation/networkextension/local-push-connectivity)). | **Residual** the owner acknowledges |
| S1 | The extension becomes a second ratchet owner and rolls back or forks state | The extension never commits core state; `classify_v2` returns no state candidate. The app stays the single owner (`docs/protocol/realtime-v1.md:128`). | [CI] state bytes identical before and after; forbidden-symbol source gate on the extension target |
| S2 | The extension runs `StorageGuard` or `InstallMarker`, reads the marker as absent in its own `UserDefaults`, sees no snapshot, and deletes the app's wrapping key (`StorageGuard.swift:31-34`, `KeychainKey.swift:161-168`), freezing the account permanently | The extension target must not reference `StorageGuard`, `InstallMarker`, `KeychainKey.create`, `deleteRetained`, `SnapshotStore`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete` or `UserDefaults.standard`. The key is read only with `SecItemCopyMatching` and an explicit access group. | [CI] source gate (RED against a mutation); [Mac] signed-simulator test |
| S3 | A PushKit launch before the first unlock freezes the app in memory (the marker reads absent while the file exists, or the Keychain throws: `StorageGuard.swift:31-33`, `KeychainKey.swift:86-94`, `AppModel.swift:275-277`) and leaves a reported CallKit call unhandled. Key deletion is not the expected outcome, because a seen file returns `.frozen` first. | The bootstrap checks that protected data is available before `StorageGuard` and otherwise waits; a launch that ends frozen or waiting ends the CallKit call at once. The extension never relays a call before the first unlock. | [Mac] unit test (C4); [device] reboot test; `FileManager` and `UserDefaults` behaviour before the first unlock is UNVERIFIED |
| S4 | The App Group mirror widens exposure of the sealed state | Same sealed bytes, same key, same protection class (`completeUntilFirstUserAuthentication`); excluded from backup; never used for recovery; deleted on reset. Readable only by the app and its extension (same team). | [Mac] unit tests; [device] backup check |
| S5 | The extension exhausts memory on a large state | Size gate: above the threshold there is no decrypt and the stage 1 text is shown. WebRTC is not linked into the extension. | [device] measurement sets the threshold (the ~24 MB limit is UNVERIFIED) |
| S6 | The extension's network path bypasses pinning | The extension uses `PinnedSessionDelegate` and joins the pinned-session inventory. Its plist has the same ATS key. | [CI] source inventory gate; [device] run |
| S7 | Extension reads lock the app out through session or waiter slots | The extension uses only challenge-signed `GET /v2/messages` and never opens a session or `/v2/events` | [CI] source gate; server session-capacity test |
| S8 | The extension tells a peer that the locked phone woke | The extension sends nothing to any peer. (The server still sees its fetch: P14. A PushKit launch of the app does send: C9, C10.) | [CI] source gate |
| S9 | `nse-cursor.v1` holds message-count and fetch-time metadata | Same protection class as the mirror, excluded from backup, written by temporary file and rename, deleted on identity reset | [Mac] unit tests; [device] backup check |
| S10 | The extension holds the device-auth signing key and the wrapping key; `sign_request_v2` would also sign `POST /v2/messages` (`clients/core/src/self_service.rs:257-268`) | A read-only signer (`sign_read_v2`) for `GET /v2/messages` only; the extension may call only it and `classify_v2`. The key material is still decrypted in the extension process. | [CI] core test: `POST` refused; source gate; identity review |
| S11 | `classify_v2` input exceeds the core's limits (65536-byte request, 8 MiB state: `clients/core/src/lib.rs:438-441`) | One envelope per call; a small fetch page (proposed 4), fetched after `max(mirror cursor, nse-cursor.v1)` so no already-notified page is fetched again, and at most 4 classifications per push; a full page may leave more pending and shows the stage 1 text | [CI] core test at the maximum envelope size; [device] timing and memory |
| N1 | Plaintext or names persist in the iOS notification store ([404 Media, 2026-04-09](https://www.404media.co/fbi-extracts-suspects-deleted-signal-messages-saved-in-iphone-notification-database-2/)) | Only constant text, with no name, preview or `threadIdentifier` | [Mac] unit test for the extension content; [device] inspection |
| N2 | Lock-screen actions or Siri learn contacts | No notification categories or actions; no `INSendMessageIntent` or `INStartCallIntent`; no communication-notifications entitlement | [CI] source and entitlement gates |
| N3 | The lock screen, Notification Center, a paired Apple Watch and the notification store reveal that ParanoID is installed and when things arrived; the store keeps that timeline, and in the 404 Media case its data outlived the app | Stated in the opt-in card. `removeAllDeliveredNotifications()` when the app opens clears Notification Center ([Apple](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removealldeliverednotifications())); whether it also clears the store is UNVERIFIED. One fixed-identifier notification in stage 2 instead of one per wake. | [device] inspection of lock screen, Watch and Notification Center. **Residual:** accepted only if approved. |
| C1 | Call history in system Recents, possibly synced to iCloud (third-party sync is UNVERIFIED) | `includesCallsInRecents = false` (Apple's default is true) | [CI] literal source gate; [device] check |
| C2 | Caller identity on the lock screen or call UI | Constant name "ParanoID"; `CXHandle(type: .generic)` with a fresh random UUID per call | [CI] source gate; [device] check |
| C2a | Outgoing CallKit calls give the recipient's contact information to the system, which "may use that information ... as a suggestion in the Journal app" ([Apple CallKit](https://developer.apple.com/documentation/callkit)) | Owner decision whether outgoing calls use CallKit at all; if so, a fresh random handle and the constant name per call | [CI] source gate; owner review |
| C3 | The VoIP relay payload carries call metadata through system daemons | The payload holds only a random UUID; the app fetches the knock over E2EE | [Mac] unit test |
| C4 | The app is killed or loses VoIP delivery for not reporting a call | The PushKit handler reports to CallKit first, on every path, and ends the call at once if no valid knock follows or the bootstrap ends frozen | [Mac] unit test; [device] test |
| C5 | A stale or replayed knock rings | The extension relays only a fresh knock from a known contact with at least 15 s left; the app ends a CallKit call without a valid knock; readiness slots are unchanged (`docs/protocol/voice-v1.md:84-92`) | [Mac] decision tests; [device] stale-knock test |
| C6 | Answering from the lock screen bypasses microphone consent or fails | Answer maps to the existing explicit Answer path; the prompt behaviour is UNVERIFIED; owner decision on asking at opt-in | [device] test |
| C7 | CallKit hold or call waiting implies a paused call that voice-v1 lacks | Holding and grouping are disabled; hold maps to end | [Mac] unit test |
| C8 | Audio session misuse under CallKit (the app activates it itself) | A CallKit branch starts audio only from `provider(_:didActivate:)` | [Mac] unit test; [device] test |
| C9 | Power-on probing: a known contact knocks (up to 6 per minute, `docs/protocol/voice-v1.md:96`) and learns from the automatic `ready` that a locked iPhone is on and online, even under Do Not Disturb, where "the system reports an error" ([Apple PushKit](https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/pushregistry(_:didreceiveincomingpushwith:for:completion:))) | Send `ready` only after `reportNewIncomingCall` succeeded and the call was not filtered; otherwise end the call and send nothing. Android already answers every authenticated knock with `ready` (`clients/android/src/org/paranoid/text/CallController.java:207-219`), so a connected or FCM-woken Android phone reveals this today. | [Mac] unit test; [device] Do Not Disturb test; owner decision |
| C10 | After a PushKit launch the app's ordinary receive path sends delivery receipts, so the second check appears while the phone stays locked | Consistent with REQ-MSG-003 (delivery, not reading) but new; stated to the user; owner decision | [device] check of when the second check appears |

## Residual risks

1. **Apple learns the recipient device and Apple Account, and the timing of
   every wake**, for opted-in iPhones, including receipts and call controls,
   which are indistinguishable from text, and the timing patterns of P13. This
   is an explicit owner trade-off. Off pre-configured Wi-Fi networks, APNs is
   the only mechanism that reaches a closed app; Local Push Connectivity works
   only on configured Wi-Fi and needs an Apple-granted entitlement (P17).
2. **Token-to-Apple-Account linkage** under legal process, by stored token or
   by timing, if server data is also obtained.
3. **Forged banners** with the key plus the token table, for iOS and, in the
   same class, for Android FCM.
4. **Stage 1 false banners** (receipts, call controls) and calls that ring only
   if the app is opened in time.
5. **Lock screen, Apple Watch and notification store** show the install and the
   arrival timeline.
6. **Stage 2 fetch disclosure**: the server and on-path observers see the
   device IP and a delivery signal at every wake.
7. **Dependence on Apple's discretion.** The filtering entitlement may be
   refused or delayed, and stage 2 cannot ship without it.
8. **Centralisation** for self-hosted servers, and no wake on a local network
   without internet until a later Local Push Connectivity proposal.
9. **Before the first unlock** there is no classification and no CallKit ring;
   only the generic text is shown.
10. **Spam-driven load** on the auth budget until the P15 server mitigations
    exist.

## Retained metadata summary

| Where | What | Lifetime |
| --- | --- | --- |
| Apple | one pending push per app while the device is offline; per-token records | up to the TTL (proposed 24 h); Apple's own retention for records |
| ParanoID server | `ss_apns_tokens` (account, device, token), no time column | until opt-out, reset or a dead-token response |
| ParanoID server (existing, FCM) | `ss_push_tokens.updated`, the time of the last FCM registration | until the row changes |
| iPhone | App Group mirror; `nse-cursor.v1` (highest notified sequence, start time of the last fetch) | until identity reset |
| iPhone | notification store entries for delivered banners | not controlled by the app; not documented by Apple |

## Documents to change on acceptance

- `docs/security/ios-client-threats.md:33` and `:82-98`: boundary 8 now used,
  with a link here.
- `docs/security/threat-model.md:290-297` and `:353-364`: boundary 8 is used by
  both clients.
- `docs/security/push-wake-threats.md`: add the forged-notification row (P3a),
  the auth-budget amplification check (P15) and the YAML front matter the
  policy requires.

Not changed: E2EE, frame2, the voice-v1 wire, session signing, message storage
on the server, TURN.
