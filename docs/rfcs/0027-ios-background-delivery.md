---
status: draft
owner: ios
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-10-15
required_reviewers: []
last_reviewed: 2026-09-26
---

# RFC-0027: Content-free iOS background delivery through APNs

This is a draft. Nothing in it is accepted, implemented, deployed or measured.
It proposes a decision that only a future ADR-0016 could record, and only with
the human decision owner's exact approval. The author is the contributor
`Cooldom66671`. The numbers RFC-0027 and ADR-0016 were free on all 50 published
heads of the repository on 2026-09-26 (every head was present locally and
scanned with the procedure in [the RFC index](README.md#naming)); they are
re-checked before `proposed`.

## Summary

The proposal lets an iPhone whose ParanoID app is closed, suspended,
force-quit or locked show that a message arrived and, in a second stage, ring
for a call. Apple's push service (APNs) is the only mechanism that reaches a
closed third-party app off pre-configured Wi-Fi networks. Local Push
Connectivity works only on configured Wi-Fi and needs an Apple-granted
entitlement (see [the later complement](#later-complement-local-push-connectivity)).
So the proposal does not avoid Apple; it limits what Apple is told. After
every committed envelope for an opted-in iPhone that holds no live
connection, the server sends one constant, content-free APNs `alert` push.
The phone learns what arrived only over the existing authenticated E2EE
channel.

- **Stage 1: content-free alert.** No extension. iOS shows one constant text,
  meaning "You may have new messages" (in Russian, like every caption of this
  client), for every wake, including receipts and call controls. A call rings
  only if the user opens the app within the 45-second window.
- **Stage 2: silent classification and system ringing.** A read-only
  notification service extension fetches and classifies new envelopes, shows
  one constant "New message in ParanoID" notice (Android's caption, in
  Russian) for real messages, silences everything else and hands a fresh call
  to CallKit. It needs an entitlement that Apple grants at its discretion, a
  separate storage review and a separate owner approval.

What this costs, stated plainly: Apple learns the recipient device and,
through its own records, the Apple Account behind it, and the time and
delivery status of every wake; wake timing across devices can reveal call
attempts and who talks to whom. The lock screen, a paired Apple Watch and the
iOS notification store show that ParanoID is installed and when things
arrived. In stage 2 the ParanoID server also sees the phone's IP address at
every wake. RFC-0020's data-only push class does not carry over to iOS. Each
of these is a numbered [owner decision](#owner-decisions).

The APNs sender is a second provider of the existing
[RFC-0020](0020-push-wake.md) gateway, not a new service.

## Preconditions

Before this RFC moves to `proposed`:

1. **RFC-0020 disposition.** RFC-0020 is still `proposed`
   (`docs/rfcs/0020-push-wake.md:2`), its deadline 2026-09-19 (`:6`) has
   passed, and its owner decision is recorded as "not yet approved as ADR"
   (`:21`). This RFC extends that gateway and changes its Android behaviour
   (decisions 9 to 11), so it must not treat RFC-0020 as accepted. The owner
   either rules on RFC-0020 by its own ADR first, or decides that ADR-0016
   covers the push gateway for both platforms (decision 1).
2. **Apple team, App ID and key custody** are recorded
   ([ownership](#apple-team-app-id-and-key-ownership), decision 5).
3. **Base iOS client.** RFC-0021 is `proposed` with a decision deadline of
   2026-10-15 (`docs/rfcs/0021-ios-client.md:2`, `:5`), and ADR-0014 is
   `proposed` (`docs/decisions/0014-ios-client.md:2`; its front matter carries
   no deadline of its own). Push extends that client, so this RFC proposes
   the same `decision_deadline`: deciding push before the base client would
   decide an extension of an undecided architecture. The owner confirms or
   replaces the date (decision 20).

## Motivation

- The contributor asked on 2026-09-25 that the iPhone receive messages and
  calls while locked or closed, "like Signal: leak nothing extra, but
  everything works", and said "we introduce nothing external". The owner has
  not ruled on it.
- The iOS client is foreground-only by design. A message sent while the app is
  closed arrives after it is opened, and a call to a closed or locked iPhone
  ends in the caller's 45-second `timeout`
  (`docs/security/ios-client-threats.md:82-98`,
  `docs/decisions/0014-ios-client.md:162-166`,
  `docs/project/current-state.md:737-740`). RFC-0021 lists push, background
  delivery and CallKit as "track B, separate proposal"
  (`docs/rfcs/0021-ios-client.md:177-180`). This is that proposal.
- Android has an implemented, phone-unverified content-free FCM wake under
  RFC-0020, which is still proposed. Its client half ships in `0.0.20-push`
  (`docs/project/current-state.md:782-784`), and "Phone call/push/reboot
  acceptance remains unrun" (`:367`).
- No requirement covers background delivery
  (`docs/product/requirements.md:26-54`), and reliable background incoming
  calls "require actual separate evidence"
  (`docs/product/voice-calls.md:48-50`). This RFC proposes REQ-CLIENT-005 for
  the owner to confirm (decision 4). A pull request must not create a
  requirement implicitly (`CONTRIBUTING.md:24-25`).
- Two confirmed requirements constrain the design. REQ-NET-001 requires useful
  operation inside a local network without public internet
  (`docs/product/requirements.md:44`), where APNs cannot reach the phone.
  REQ-SERVER-001 says the default server must not become permanent central
  authority (`:46`), yet only the publisher's Apple team can push to the
  published app, so the iOS users of every self-hosted server would depend on
  the publisher's key and gateway. See
  [Local Push Connectivity](#later-complement-local-push-connectivity) and
  residual R8.
- "Nothing external" cannot be met literally for this feature. Off
  pre-configured Wi-Fi networks, only APNs can wake a suspended or force-quit
  third-party app. Background pushes are low priority and not guaranteed
  ("don't try to send more than two or three per hour"), and "If something
  force quits or kills the app, the system discards the held notification"
  ([Apple: pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)).
  Local Push Connectivity involves no Apple server: the system launches a
  provider extension that can alert the user or trigger CallKit through
  `reportIncomingCall(userInfo:)`, but only while the device is on configured
  Wi-Fi networks, and it needs an Apple-granted entitlement
  ([Apple: Local Push Connectivity](https://developer.apple.com/documentation/networkextension/local-push-connectivity)).
  This RFC states the dependency and minimises it instead of hiding it.

## Goals and non-goals

### Goals

- **Proposed REQ-CLIENT-005** (the owner confirms the ID and wording,
  decision 4), in three clauses:
  - (a) Messages: when the user has enabled it, an iOS device whose ParanoID
    app is closed, suspended, force-quit or locked shows that a message may
    have arrived, without the app being opened.
  - (b) Calls, **conditional on Apple granting the filtering entitlement**:
    under the same conditions, a call from a known contact rings through the
    system call interface and can be answered within the existing 45-second
    window. Without the entitlement this clause stays unmet, possibly for
    good, and the product says so.
  - (c) Disclosure: no single push carries the sender, content, size or
    message type; push type, topic, priority, collapse identifier and payload
    are constant. Apart from the publisher's own identifiers (gateway
    address, team and key), the push provider learns the recipient device and
    its Apple Account, that the app has push enabled, the time and delivery
    status of every wake, and the timing patterns of residual P13, as listed
    in [the threat delta](../security/ios-push-threats.md). In stage 2 the
    ParanoID server additionally learns the device IP address and the time of
    each wake-triggered fetch (P14), and a PushKit launch sends `ready` and
    ordinary delivery receipts (C9, C10).
- G1: a message sent to a force-quit, locked, opted-in iPhone produces a
  content-free notification within seconds (stage 1).
- G2: in stage 2, a receipt, call control or duplicate produces no visible
  notification, except a push that arrives less than 5 s after the previous
  fetch started, which shows the stage 1 text rather than risk hiding a
  message (extension step 3).
- G3: in stage 2, a call to a locked or closed iPhone rings through CallKit and
  can be answered within the 45-second window.
- G4: no single push shows Apple the sender, content, size or type. Push type,
  topic, priority, collapse identifier and payload are identical for text,
  receipts, call controls and first contact. Apple does learn the recipient
  device and Apple Account, the gateway address and the time of every wake,
  and timing across wakes can reveal call attempts and conversation pairs.
  That is residual P13, accepted only if the owner accepts it (decision 2).
- G5: the lock screen, Notification Center, a paired Apple Watch and the iOS
  notification store receive only the app name "ParanoID", a constant text
  and the arrival time: no names, previews, thread grouping, actions or Siri
  donations. Calls show the constant caller name "ParanoID" and stay out of
  Recents by default. The app name and the arrival timeline are disclosed and
  stated in the opt-in card (threat N3).
- G6: a user who declines or disables it gets exactly today's foreground-only
  behaviour, and no token is registered.
- G7: one gateway and one wake trigger for both platforms. These RFC-0020
  invariants carry over: constant content-free payload, signed registration,
  per-account rate limit, dead-token deletion, credential only on the gateway.
  RFC-0020's data-only, no-notification push class does **not**; see
  [Why iOS needs a visible alert push](#why-ios-needs-a-visible-alert-push).

### Non-goals

- Sender names, message previews, badges, notification actions,
  communication notifications (`INSendMessageIntent`) or grouping by
  conversation. Each moves plaintext or relationship metadata into iOS system
  stores and needs its own proposal.
- Anything sent by the notification service extension, including delivery
  receipts. (A stage 2 PushKit launch runs the app's ordinary receive path,
  which does send receipts; see decision 14.)
- Server-sent PushKit VoIP pushes, `content-available` background pushes, and
  any sender-set urgency or "no-wake" bit (see [Alternatives](#alternatives)).
- A relay through which self-hosted servers send wakes to the published app,
  RFC-0020's "many ParanoID servers later" (`docs/rfcs/0020-push-wake.md:23-24`).
  That is a separate deploy-trust proposal; its absence is residual R8.
- The extension as a writer of core state; any change to Olm, frame2 or the
  voice-v1 wire; any change to the Android client.
- `BGTaskScheduler` or background app refresh, which stay forbidden.
- LiveCommunicationKit, the default-calling-app entitlement, time-sensitive or
  critical alerts, and Focus breakthrough.

## Proposed design

### Principle and invariants

The push is a doorbell. It says "look now" and nothing else.

- **I1 Constant request.** Every APNs request carries the same body and
  headers apart from the device token, the JWT and `apns-expiration`.
- **I2 One push type.** Every committed envelope produces the same `alert`
  push: text, receipt, call control and first contact alike. The server cannot
  tell a call from text: call controls are Olm `PlainV1` with `kind: "call"`
  inside signed frame2 (`docs/protocol/voice-v1.md:19-25`). This is the
  condition Apple sets for its end-to-end-encrypted call path: "Only use this
  approach when your server can't determine whether an outgoing notification
  is a request for a VoIP call or some other data (such as a text message)
  due to metadata encryption"
  ([Apple: sending end-to-end encrypted VoIP calls](https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls)).
- **I3 The phone learns only over E2EE.** What arrived is learned only by
  fetching `/v2/messages` over the pinned, signed channel and decrypting in the
  core. The extension never commits core state; the app remains the single
  ratchet owner (`docs/protocol/realtime-v1.md:128`).

### Why iOS needs a visible alert push

RFC-0020 records the Android push as "an additional transport: data-only,
content-free wake" (`docs/rfcs/0020-push-wake.md:28`) and rejects
"Notification-carrying pushes" (`:75-76`). The FCM threat delta says "no
notification block" (`docs/security/push-wake-threats.md:7`), and a server test
asserts it (`server/tests/push_fcm.rs:394`). That class does not carry over to
iOS:

- The iOS counterpart of a data-only push is a background
  (`content-available`) push. Apple treats it as low priority, does not
  guarantee its delivery, may throttle it ("don't try to send more than two or
  three per hour") and discards it after a force-quit (Apple: pushing
  background updates, above). It cannot meet G1.
- The push that still reaches a force-quit app and can run an extension is a
  visible `alert` with `mutable-content`
  ([Apple: modifying content](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications);
  [Apple DTS on force-quit](https://developer.apple.com/forums/thread/769303),
  a forum statement by Apple staff, not reference documentation).

So the iOS push is a notification-carrying push. Its content is a constant key
resolved on the device, but iOS displays it by itself whenever no extension
runs, and it displays any alert push that lacks `mutable-content` directly.
That makes the signing key plus the token table a way to show arbitrary text
on every opted-in iPhone (threat P3). Accepting this push class for iOS is a
separate owner decision (decision 3), not a consequence of RFC-0020.

### Stages at a glance

| | Stage 1: content-free alert | Stage 2: silent classification and system ringing |
| --- | --- | --- |
| Server request | constant `alert` with `mutable-content` | identical: no server change between stages |
| Extension | none | read-only notification service extension (NSE) |
| A message shows | system-rendered "You may have new messages" (the meaning; the caption is Russian) | one local notification "New message in ParanoID" (Android's Russian caption) with a fixed identifier |
| Receipt or call control | the same banner (a false positive) | silenced |
| Incoming call | the banner; rings in the app only if it is opened within the knock window | CallKit ring through `reportNewIncomingVoIPPushPayload` |
| New disclosure to the ParanoID server | the token | plus the device IP and fetch time at every wake |
| Phone storage change | none | App Group mirror, extension cursor, shared Keychain group (read) |
| Prerequisites | paid Apple team; APNs key | plus Apple's filtering entitlement, storage review, owner approval |
| Core change | `push` gains `platform` | plus `classify_v2` and a read-only request signer |

Stage 1 is what stage 2 falls back to whenever the extension cannot classify.

### Stage 1: server

#### Wire delta

Against `docs/protocol/self-service-v2.md:66-73`:

- `POST /v2/push` (signed session only; unchanged route and binding):
  `{platform, token}` with platform `"fcm"` or `"apns"`. For `"apns"` the
  token is the device token as lowercase hexadecimal, even length, at most
  4096 characters.
- Today any platform other than `"fcm"` is refused with `400`
  (`server/src/self_service_http.rs:573-575`). Body validation runs before the
  disabled check (`:576-579`), so a server with no gateway also answers
  `{"platform":"apns"}` with `400`; the existing test sends it to a configured
  gateway (`server/tests/push_fcm.rs:319-331`). Proposed: `404 push_disabled`
  when no provider for the requested platform is configured. That test changes
  deliberately in the same pull request.
- Token model (decision 11, because it changes the RFC-0020 contract): one
  token per account across platforms. An account has "One immutable device"
  (`docs/protocol/self-service-v2.md:23`) and therefore one platform.
  Registering one platform removes the account's row for the other in the same
  transaction, and an empty token unregisters every platform. The alternative
  that leaves the RFC-0020 contract untouched is a per-platform empty token.
- The response is unchanged: `{registered: bool}`.
- The trigger is unchanged: a committed `POST /v2/messages` for a recipient
  with no live `/v2/events` waiter (`server/src/self_service_http.rs:609-614`,
  `:620-645`), with the two corrections below.

#### Trigger, suppression and coalescing

The trigger, the waiter suppression and `admit()` stay
(`server/src/self_service_http.rs:624`, `server/src/push_fcm.rs:174-189`). Two
gaps matter more on iOS than on Android, where a wake keeps the loop polling
for 25 seconds (`clients/android/src/org/paranoid/text/TextEngine.java:228-240`,
`:241`):

1. **Dropped second wake.** `admit()` drops, rather than defers, a wake within
   10 s of the previous one (`server/src/push_fcm.rs:17`, `:182-183`). A call
   `knock` 2 to 9 s after a text therefore produces no push, and on iOS the
   call is missed. **Proposal:** trailing-edge coalescing. A wake refused only
   by the interval schedules at most one deferred wake at the end of the
   interval, skipped if the recipient then holds a live waiter. The
   4096-account cap still fails closed. Decision 9: both providers, which
   changes RFC-0020 behaviour, or APNs only.
2. **Stale waiter.** A wake is suppressed while the recipient holds a waiter
   (`server/src/self_service_http.rs:624`), which lives up to 20 s
   (`:696-712`). The protocol already states that "The waiter guard is released
   on success, rejection, disconnect cancellation or handler timeout"
   (`docs/protocol/realtime-v1.md:103-104`), but no test proves the disconnect
   case for `WaitGuard` (`server/src/self_service_http.rs:671-676`) under
   hyper's HTTP/1 server: it is an untested protocol claim. **Proposal:**
   (a) the iOS client cancels its long-poll when its lanes stop on entering
   the background; (b) a wake suppressed because of a waiter is remembered,
   and if that waiter ends without returning a non-empty page, the gateway
   sends it, subject to `admit()`. A RED-first server test covers "the client
   aborts the long-poll, then a message commits, and a wake is sent".
   Decision 10: (b) changes Android behaviour too, so both providers or APNs
   only.

#### The request

Every APNs request is exactly this, and a server test asserts it byte for
byte:

```text
POST /3/device/<device-token-hex>          (HTTP/2, api.push.apple.com:443)
authorization: bearer <ES256 JWT {alg:ES256,kid:<key id>} {iss:<team id>,iat}>
apns-topic: global.paranoid.messenger
apns-push-type: alert
apns-priority: 10
apns-expiration: <send time + TTL>
apns-collapse-id: paranoid-wake
content-type: application/json

{"aps":{"alert":{"loc-key":"PARANOID_WAKE"},"sound":"default","mutable-content":1}}
```

Why each element is there:

- `alert` with `mutable-content: 1`: the push that reaches a force-quit app
  and can run an extension (above). Silencing by an extension works only for
  `apns-push-type: alert`
  ([Apple: filtering entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering)).
- `loc-key`: Apple carries a key, not text. The string lives in the app
  bundle, as Apple recommends for predetermined text
  ([Apple: generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)).
  Apple says the extension runs only when the alert has "title, subtitle, or
  body information" (modifying-content page, above), and this payload carries
  only a localized body key. Signal's production payload has the same shape,
  `setMutableContent(true)` plus `setLocalizedAlertMessage("APN_Message")`
  ([Signal-Server APNSender.java L42-L45](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/push/APNSender.java#L42-L45)),
  which is practical evidence that a `loc-key` body qualifies. A device test
  confirms it for this app. The string means "You may have new messages", as
  Signal's `APN_Message` does
  ([Signal-iOS Localizable.strings L215](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/Signal/translations/en.lproj/Localizable.strings#L215)).
  The iOS client ships in Russian and has no localization table
  (`clients/ios/App/ParanoID/Strings.swift:28-30`), so `PARANOID_WAKE` becomes
  the bundle's one localized-string entry. It holds a Russian caption that the
  owner approves with the opt-in card text (decision 6), and the captions gate
  learns it.
- `sound: "default"`: constant, so it adds nothing to what Apple learns.
  Without it a stage 1 banner is silent.
- `apns-collapse-id`: Apple documents it as "An identifier you use to merge
  multiple notifications into a single notification for the user". Storage is
  separate: "APNs stores only one notification per bundle ID", whatever the
  collapse identifier
  ([Apple: sending notification requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)).
  In stage 1 the header keeps repeated content-free banners as one. In stage 2
  the extension silences every push and posts its own local notification with
  a fixed identifier (Signal's pattern, see
  [the extension](#the-notification-service-extension)), so the collapse
  identifier does not govern what stage 2 shows. The one remaining interaction,
  a timeout fallback banner followed by a silenced push with the same collapse
  identifier, is a device test. If that push removes the banner, the server
  drops the header; it is constant, so dropping it changes nothing Apple learns.
- Nothing else: no badge, sender, account or device ID, ciphertext, size or
  counter. This matches the FCM invariant tested at
  `server/tests/push_fcm.rs:388-403`.
- `apns-expiration`, the TTL (decision 8): proposed 24 hours. The wake is only a
  hint; "the inbox and cursor are the durable truth"
  (`docs/protocol/realtime-v1.md:109-110`). While a device is offline, Apple
  keeps at most one notification for this app and delivers it on reconnect, for
  "30 days or less, depending on the date you specify" (sending-requests page).
  A longer TTL adds no content; it lengthens how long Apple stores one
  constant push.
  FCM uses 60 s (`server/src/push_fcm.rs:198-199`) and Signal 30 days
  ([APNSender.java L52-L54](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/push/APNSender.java#L52-L54)).

The server never sends `voip` or `background` pushes and never uses the `.voip`
topic. A test asserts that no other push type or topic can be built.

#### Authentication and transport

- Token-based authentication with a **topic-specific key restricted to
  production and to `global.paranoid.messenger`**, so the key cannot address
  any other app or environment
  ([Apple: token-based connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)).
- The JWT is signed with ES256 using the already pinned `ring` 0.17.14
  (`server/Cargo.toml:9`), so no new crypto crate is needed. Whether `ring`'s
  PKCS#8 parser accepts Apple's `.p8` file, which must embed the public key, is
  UNVERIFIED. The JWT is cached for 40 minutes, inside Apple's window of
  refreshing no more often than every 20 minutes and no less often than every
  60, regenerated on `403 ExpiredProviderToken`, and never regenerated sooner
  than 20 minutes (`429 TooManyProviderTokenUpdates`).
- APNs requires HTTP/2. The server's reqwest is built with only `json` and
  `rustls-tls-webpki-roots` (`server/Cargo.toml:25`), so its `http2` feature
  must be enabled. That is a foundational-dependency change for review. One
  long-lived connection is reused.
- TLS uses the existing webpki roots. APNs moved to the USERTrust RSA root in
  2025 ([Apple news](https://developer.apple.com/news/?id=09za8wzy)). Pinning
  Apple's CA, as Signal does
  ([APNSender.java L66-L71](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/push/APNSender.java#L66-L71)),
  is optional hardening (open item).
- The endpoint override for tests (loopback `h2c` only) is refused in public
  mode, exactly like the FCM override (`server/src/main.rs:141-155`).

#### Response handling

Responses map as follows
([Apple: handling responses](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)):

| APNs response | Gateway action |
| --- | --- |
| 200 | sent |
| 410 `Unregistered` or `ExpiredToken`; 400 `BadDeviceToken`; 400 `DeviceTokenNotForTopic` | compare-and-delete the row (`DELETE ... WHERE account=$1 AND token=$2`, as `server/src/self_service_http.rs:637-643`) |
| 403 `ExpiredProviderToken` | drop the cached JWT |
| 403 `InvalidProviderToken` | configuration error: counter, no retry |
| 429, 500, 503 | transient: skip; no retry loop, as with FCM |
| any other 400 | programming error: counter; tests make these unreachable |

Sending stays asynchronous after the commit, and a failure never affects the
sender's response (`server/src/self_service_http.rs:620-645`).

#### Token storage

**Recommended: an additive table without a time column,**
`ss_apns_tokens(account TEXT PRIMARY KEY REFERENCES ss_accounts(account), device TEXT NOT NULL REFERENCES ss_devices(device), token TEXT NOT NULL CHECK(token ~ '^[0-9a-f]+$' AND octet_length(token) BETWEEN 2 AND 4096))`.
It is created with `CREATE TABLE IF NOT EXISTS` only when the APNs provider is
configured, the same pattern as `ss_push_tokens`
(`server/src/self_service_http.rs:95-101`).

- **No last-launch record.** The FCM upsert rewrites `updated` on every
  registration (`server/src/self_service_http.rs:586`). The iOS client
  re-registers on every opted-in launch, so the same upsert would keep a
  last-launch time per account, and the v2 base schema otherwise has no
  per-account wall-clock column (`server/self-service-schema.sql:2-29`; its one
  time value is the global registration window at `:6`). Nothing in the server
  reads `updated` (`server/src/self_service_http.rs:98`, `:586`). The APNs table
  therefore has no time column, and an unchanged token writes nothing. If the
  server pull request finds a use for a time, it stores only the time of the
  last token change and the threat delta lists it.
- **Rejected: widening `CHECK(platform='fcm')`**
  (`server/src/self_service_http.rs:98`). It needs an `ALTER` of a live table,
  which `CREATE TABLE IF NOT EXISTS` cannot do. Worse, a rollback to an older
  binary would send APNs tokens to FCM, because the old wake path selects the
  token without looking at the platform (`:629-635`). With the additive table
  an older binary ignores it, and iOS falls back to foreground-only.
- **Deploy gate.** `deploy/alpha.py` must learn the new optional table in the
  same deploy pull request. Its schema gate compares full schemas
  (`deploy/alpha.py:996`, `:1006-1021`), and exactly this kind of mismatch
  blocked the 2026-09-13 update
  (`docs/rfcs/apk-cap-push-backup-recovery.md:18-24`).
- **Backups (decision 12).** Excluding APNs tokens from backups shrinks what a
  seized backup links, but it does not remove the link. A live server holds the
  tokens anyway, because clients re-register on launch. Even with no stored
  token, anyone with a record of commit times (access to a live server, or
  network captures at the host) can match them against Apple's records for a
  push token, which Apple provides under legal process: "The Apple ID
  associated with a registered APNs token and associated records may be
  obtained with an order"
  ([Apple Legal Process Guidelines, US, section III.AA](https://www.apple.com/legal/privacy/law-enforcement-guidelines-us.pdf)).

#### Configuration and credential custody

- The `.p8` key reaches the process only as a systemd `LoadCredential`; the
  environment carries its path and nothing else, as for the FCM credential
  (`deploy/alpha.py:828`, `server/src/main.rs:141-155`).
- The file check is strict: regular file, one link, mode 0400 or 0600, the
  expected owner, at most 4 KiB, a PEM PKCS#8 P-256 key. The config type is
  neither `Debug` nor `Serialize` (`server/src/push_fcm.rs:20-28`).
- The key ID, team ID, topic and environment are non-secret identifiers in the
  reviewed config key. They are enabled only through an explicit, journaled
  config flip with restore on failure, like the FCM switch
  `{'v': 1, 'provider': 'fcm'}` (`deploy/alpha.py:163`, `:1265`).
- One environment per gateway. Development builds from Xcode get sandbox tokens
  and are tested against a local stand with a sandbox key. TestFlight and
  hosted builds use production. A production gateway answers a sandbox token
  with `BadDeviceToken` and deletes it.
- Only the team that owns the App ID can sign pushes for it, and "APNs doesn't
  support authentication tokens from multiple developer accounts over a single
  connection" (token-based connection page, above). The key therefore lives
  only on the one gateway host, which in the single-host alpha is the message
  server (`docs/rfcs/0020-push-wake.md:25-27`).

#### Apple team, App ID and key ownership

- The bundle identifier is `global.paranoid.messenger`
  (`clients/ios/App/Config/Bundle.xcconfig:7`). The build takes the signing
  team only from the environment (`:12-16`), and the repository does not record
  which Apple team owns this App ID.
- Push notifications need a paid Apple Developer Program or Enterprise
  membership
  ([Apple: supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios)).
  App Groups do not (the same page also marks them for the free Apple
  Developer membership), but stage 2 needs push anyway.
- Only the team that owns the App ID can create a topic-specific key for it
  and request the filtering entitlement for its extension. If a contributor's
  team registered the identifier, the owner's team is expected to be unable to
  register the same identifier for its own key until it is released
  (UNVERIFIED; checked in the developer account).
- Whoever holds the key **and** the token table can show arbitrary banners to
  every opted-in iPhone (P3). The key alone cannot address a device, because
  it needs the tokens. Key custody is therefore deployment trust, not a build
  detail.
- To be recorded before `proposed` (decision 5): which paid team owns the App
  ID; who creates, holds and can revoke the production key; where the sandbox
  key for the local stand comes from; who requests the filtering entitlement;
  and the plan if Apple refuses it.

### Stage 1: core

`sign_session_v2` operation `push` takes an optional `platform`: `"fcm"`, the
default that keeps Android's JNI call unchanged, or `"apns"`. The token is
validated per platform. Today `"fcm"` is hardcoded
(`clients/core/src/clean_service.rs:736-748`). This is a red zone: test first,
explicit approval.

### Stage 1: iOS

- **Capabilities.** `aps-environment`, exactly `development` for Debug and
  `production` for Release. No extension, no PushKit, no CallKit, and
  `UIBackgroundModes` stays exactly `[audio]`
  (`clients/ios/App/ParanoID/Info.plist:41-44`). Alert notifications are drawn
  by the system without launching the app, so no background mode is expected
  to be needed; a signed-build device test confirms it.
- **Opt-in** (decision 6). After onboarding and the first signed session, one
  card says what Apple learns (this device, its Apple Account and the time of
  every wake) and that the lock screen, a paired Apple Watch and the iOS
  notification store will show "ParanoID" and arrival times. Only an explicit
  "Enable" calls `requestAuthorization([.alert, .sound])` (no badge,
  provisional, critical or time-sensitive), then
  `registerForRemoteNotifications`, then the core-signed
  `POST /v2/push {platform:"apns"}`. "Not now" registers nothing. Settings can
  turn it off.
- **Every launch** while opted in and authorized: register again, because the
  token can change on a restore, a new device or an OS reinstall
  ([Apple: registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns));
  the server writes nothing when it is unchanged. If authorization was
  revoked, send the empty token. On an identity reset, send the empty token
  before wiping (best effort).
- **On opening,** the app calls `removeAllDeliveredNotifications()`, which
  "Removes all of your app's delivered notifications from Notification Center"
  ([Apple](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removealldeliverednotifications())).
  Whether that also removes them from the on-device notification store is not
  documented (UNVERIFIED). The opt-in card says what the user can and cannot
  hide.
- **In the foreground,** `willPresent` shows nothing and asks for a receive
  cycle through `PushHook.wake()`, the named seam whose only implementation
  today is the no-op `NoPushHook`
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Realtime/PushHook.swift:1-33`,
  `:24-33`); stage 1 adds its first real implementation. Tapping a banner
  opens the app and nothing more, because the payload has nothing to act on.
- **Entering the background,** the lanes stop (unless a call is live) and the
  open long-poll is cancelled explicitly (stale-waiter item 2a above).
- **Calls in stage 1.** The knock's wake shows the same banner. If the user
  opens the app while the knock is still valid, the existing path runs (knock,
  automatic `ready`, offer, in-app ring per RFC-0025). Otherwise the caller sees
  today's `timeout`. This partial result is stated in the UI.
- `UNUserNotificationCenter` is used in exactly one app file, and
  `registerForRemoteNotifications` is called at exactly one site.

### Stage 2: silent classification and system ringing

Stage 2 starts only after three things: Apple has granted the filtering
entitlement, the storage and signing sections below have had their own
review, and the owner has approved stage 2 separately. Without the entitlement
a notification cannot be silenced, and `reportNewIncomingVoIPPushPayload` is
unavailable (filtering entitlement page, above;
[`reportNewIncomingVoIPPushPayload`](https://developer.apple.com/documentation/callkit/cxprovider/reportnewincomingvoippushpayload(_:completion:))).

Stage 2 aims at Signal's user-visible behaviour (content-free notifications
for messages, system ringing for calls), not at Signal's architecture, and it
discloses less. It is slower to ring; see
[How this compares with Signal](#how-this-compares-with-signal).

#### Storage: a read-only mirror, not a second owner

The extension is a separate process. It cannot share the app's state as a
writer:

- The app keeps the only in-memory state and commits whole snapshots, last
  writer wins
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Service/SelfServiceClient.swift:461-488`,
  `clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/SnapshotStore.swift:13-26`).
- Ratchets have one owner (`docs/protocol/realtime-v1.md:128`), and the iOS
  owner is process-local
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Realtime/StateOwner.swift:66-91`).
- A suspended process that holds a file lock is killed with `0xdead10cc`.
- Most dangerously, `StorageGuard.start` run inside an extension would read the
  install marker from the extension's own `UserDefaults`
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/InstallMarker.swift:7-11`),
  a separate domain in which the marker is absent. The app's snapshot is not
  visible there either, so the guard would take the deletion branch
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/StorageGuard.swift:31-34`).
  `KeychainKey.deleteRetained` matches by account with no access group
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/KeychainKey.swift:73-79`,
  `:161-168`), so in a process that shares the app's Keychain group it would
  delete the app's key, and the next launch would freeze permanently.

Proposal:

- **Mirror.** After each successful commit the app writes a copy of the already
  sealed `text-state.enc` into the App Group container
  `group.global.paranoid.messenger`: temporary file, then rename;
  backup-excluded; `completeUntilFirstUserAuthentication`. The authoritative
  file, `StorageGuard` and the key/file continuity rule are untouched. The
  mirror is a hint only: the app never reads it, never uses it for recovery,
  and deletes it on identity reset. A stale mirror only makes the extension
  classify from an older cursor. Moving the authoritative file into the App
  Group instead needs a two-path continuity migration in `StorageGuard` and is
  not recommended for the first iteration (decision 17).
- **Key.** The extension's `keychain-access-groups` names the app's group
  literally, `$(AppIdentifierPrefix)global.paranoid.messenger`. The app's item
  already lives in its default group
  (`clients/ios/App/ParanoID/ParanoID.entitlements:11-14`, whose comment says
  "in no shared one" at `:5-6` and changes with this proposal), so no Keychain
  migration is needed. The extension only calls `SecItemCopyMatching` with an
  explicit access group.
- **Extension-owned file.** `nse-cursor.v1` in the App Group holds the highest
  server sequence already notified and the wall-clock time at which the last
  fetch started.
  It is message-count and wake-time metadata, so it has the mirror's protection
  class (`completeUntilFirstUserAuthentication`), is excluded from backup, is
  written by temporary file and rename, and is deleted on identity reset. It is
  the only file the extension writes.
- **Forbidden in the extension target**, enforced by a source gate:
  `StorageGuard`, `InstallMarker`, `KeychainKey.create` and `deleteRetained`,
  `SnapshotStore` with its commit and load paths (load prepares directories:
  `SnapshotStore.swift:75-77`, `:84-88`), `SecItemAdd`, `SecItemUpdate`,
  `SecItemDelete`, `UserDefaults.standard`, `sign_request_v2`,
  `sign_session_v2`, every committing core operation, any `POST`, any session
  or `/v2/events` request, and WebRTC.
- **Memory gate.** The sealed state may reach 9 MiB (`SnapshotStore.swift:29`),
  and the bridge copies it several times
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Core/CoreBridge.swift:58-77`).
  The extension memory limit of about 24 MB is reported only by developers on
  Apple's forums (UNVERIFIED). Above a threshold, proposed at 2 MiB and set
  from a device measurement, the extension does not decrypt and falls back to
  the stage 1 text.

#### Signing authority in a second process

Stage 2 brings the device-auth signing key and the snapshot wrapping key into
a second process. That is the protected domain of identity and key
derivation. The existing `sign_request_v2` signs a challenge for
`GET /v2/messages?` with any query, but also for `POST /v2/messages` with any
body (`clients/core/src/self_service.rs:257-268`), so an extension holding it
could technically send. **Proposal:** a new core operation, working name
`sign_read_v2`, that signs only `GET /v2/messages?after=<n>&limit=<m>`. The
extension's Swift code may call only `sign_read_v2` and `classify_v2`. This
narrows the programmatic surface. It does not change what a compromised
extension could extract, because the key material is still decrypted inside
the extension process. Identity and cryptography review is required.

#### Core: `classify_v2`

- **One envelope per call.** The core refuses a request over 65536 bytes and a
  state over 8 MiB (`clients/core/src/lib.rs:438-441`;
  `clients/ios/bridge/include/paranoid_core.h:15`). A page on the session path
  holds up to 20 envelopes (`clients/core/src/clean_service.rs:730-734`), and
  each carries up to 16384 ciphertext bytes
  (`docs/protocol/self-service-v2.md:56-57`), about 21.8 KB in base64, so a
  whole page cannot fit one request. One envelope with its JSON framing does.
- **Output:** `{sequence, class}`, where class is `text`, `receipt`,
  `call_knock`, `call_other` or `unreadable`, plus the remaining knock lifetime
  for `call_knock`. It never returns plaintext or a state candidate, so nothing
  exists to persist. The core already exposes one pure JSON function,
  `command(state, request)` (`docs/decisions/0014-ios-client.md:82-85`), and
  the host decides what to persist: the app saves a new state through its sink
  only after checking the reply
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Service/SelfServiceClient.swift:461-488`).
  `dryRunUpgrade` already runs an operation and keeps nothing
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Service/SelfServiceClient.swift:424-440`).
- **Parse budget.** Every call parses the whole state again. The extension
  fetches with a small page, proposed `limit=4` in the signed path (the server
  accepts 1 to 100: `docs/protocol/self-service-v2.md:59-60`), and classifies
  at most 4 envelopes per push. The response has no "more pending" flag
  (`docs/protocol/self-service-v2.md:58`), so a full page, as many envelopes as
  the limit, counts as "classification budget exceeded" and falls back to the
  stage 1 text. Both numbers are set from a device measurement.
- **Crypto review (UNVERIFIED).** Every call starts from the same mirror state,
  without earlier envelopes applied. The extension also skips envelopes that
  lie between the mirror's committed cursor and `nse-cursor.v1` (extension
  step 4), so it classifies out of order relative to what the app will apply.
  Whether a later envelope decrypts correctly without the earlier ones, and
  whether decrypting a prekey message in a discarded candidate is safe given
  the rule that "an already retained Olm session must never be recreated from
  a replayed prekey after failed decrypt" (`docs/protocol/voice-v1.md:99-100`),
  needs cryptographic review. An envelope that cannot be read this way is
  `unreadable` and falls back to the stage 1 text.

#### The notification service extension

The extension always silences the push itself and shows at most one local
notification, with the fixed identifier `paranoid.new-message`, so a later
notification replaces an earlier one instead of stacking. Signal's extension
likewise never shows the push itself: it returns empty or badge-only content
([NotificationService.swift L182-L193](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NotificationService.swift#L182-L193),
[L208-L272](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NotificationService.swift#L208-L272))
and posts its own notices with fixed identifiers
([L296-L314](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NotificationService.swift#L296-L314)).

For each push:

1. If protected data is unavailable, which is the case before the first unlock
   after a reboot and makes the Keychain read fail: post the local
   notification with the stage 1 text once, and silence the push. Signal does
   the same: it returns empty content and posts a one-time "phone locked"
   notice
   ([NotificationService.swift L121-L136](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NotificationService.swift#L121-L136)).
2. If the mirror is missing or over the memory gate: the stage 1 text, and
   silence.
3. If a fetch started less than 5 s ago (proposed), according to
   `nse-cursor.v1`: do not fetch again; post the stage 1 text with the fixed
   identifier `paranoid.new-message`, and silence the push. The guard never
   silences without a notice, because the push may belong to an envelope
   committed after that fetch: the server spaces wakes per account by 10 s,
   but a late APNs delivery of the earlier push and the extension's own run
   time can bring the next push within 5 s of the fetch. The notice replaces
   an earlier one instead of stacking, so the cost is at most a false banner.
   A fresh knock in that push does not ring through CallKit; it behaves as in
   stage 1. The defence against spam-driven load is on the server (threat
   P15).
4. Record the start time of this fetch in `nse-cursor.v1`. Unseal the mirror in
   memory. Fetch a challenge (`POST /v2/auth/challenge`), sign it with
   `sign_read_v2`, then `GET /v2/messages?after=<cursor>&limit=4` over
   `PinnedSessionDelegate`, where `<cursor>` is the larger of the app's
   committed cursor in the mirror and the highest sequence already notified in
   `nse-cursor.v1`. Fetching after the mirror cursor alone would return the
   same oldest, already-notified page on every push while a closed app has a
   backlog of more than 4 envelopes, so new texts would be silenced as
   "nothing new" and a fresh knock beyond that page would never ring. This
   request uses neither of the two session slots per account
   (`docs/protocol/realtime-v1.md:35`) nor the single waiter slot (`:102`), so
   the extension can never lock the app out with `429`. It does spend auth
   ingress (P15), and it shows the server the device's IP address and the
   fetch time (P14).
5. Call `classify_v2` for each new envelope within the budget, and discard the
   state copy.
6. Decide. The rows apply independently: a page with a text and a fresh knock
   posts the notification and reports the call, and a full page that holds a
   fresh knock posts the stage 1 text and reports the call.

| Newest unseen classes (sequence above `<cursor>`) | Result |
| --- | --- |
| at least one `text` | post Android's captions verbatim, in Russian like every caption of this client (`clients/ios/App/ParanoID/Strings.swift:28-30`): «Новое сообщение в ParanoID» / «Откройте приложение, чтобы прочитать» ("New message in ParanoID" / "Open the app to read"; `clients/android/src/org/paranoid/text/BackgroundConnectionService.java:60`), with the fixed identifier; no `threadIdentifier`, no name, no actions; silence the push |
| `call_knock` from a known contact with at least 15 s left (proposed, to be measured) | `reportNewIncomingVoIPPushPayload(["c": <random UUID>])`; silence the push |
| only `receipt`, `call_other`, a stale knock, or nothing new | silence the push; post nothing |
| `unreadable`, a fetch failure, or the classification budget exceeded (including a full page, which may leave more pending) | post the stage 1 text with the fixed identifier; silence the push |
| `serviceExtensionTimeWillExpire` | return the original content, which iOS shows as the stage 1 text |

Then set the notified sequence in `nse-cursor.v1` to the highest sequence in
the page. A fresh knock beyond a full page is not seen by this push, so a phone
with more than 4 unclassified envelopes above `<cursor>` rings through CallKit
only once later pushes have paged through them; until then a call shows only
the stage 1 text.

On a timeout this design fails visible: an unclassified wake may be a message.
Signal completes silently instead (NotificationService.swift L182-L193, above).

#### Incoming calls: extension to PushKit to CallKit

This is Apple's documented path for a server that cannot tell calls from other
data (sending end-to-end encrypted VoIP calls, above):

1. The extension recognises a fresh knock and calls
   `reportNewIncomingVoIPPushPayload` with only a random UUID. No call metadata
   passes through system daemons. Signal likewise passes only a UUID
   ([NSECallMessageHandler.swift L169-L205](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NSECallMessageHandler.swift#L169-L205)),
   but Signal's extension first writes the decrypted call message into the
   shared database for the app
   ([CallMessageRelay.swift L81-L99](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/CallMessageRelay.swift#L81-L99)).
   This extension writes nothing, so the app must fetch and decrypt the knock
   again.
2. iOS launches the app into
   `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)`. "If you fail
   to report a call to CallKit, the system will terminate your app", and
   "Repeatedly failing to report calls may cause the system to stop delivering
   any more VoIP push notifications to your app"
   ([Apple: PushKit delegate](https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/pushregistry(_:didreceiveincomingpushwith:for:completion:))).
   The handler therefore calls `reportNewIncomingCall` first, before any
   storage or network work. `PKPushRegistry` and `CXProvider` are created in
   the application delegate at launch, not in a SwiftUI view: bootstrap today
   runs from a view `.task` (`clients/ios/App/ParanoID/ParanoIDApp.swift:61-63`),
   and whether the scene connects on a background launch is UNVERIFIED. The
   PushKit token is never sent anywhere. Signal ignores it the same way
   ([PushRegistrationManager.swift L175-L177](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/Signal/Notifications/PushRegistrationManager.swift#L175-L177)).
   iOS 26.4 adds a `mustReport` flag
   ([Apple](https://developer.apple.com/documentation/pushkit/pkvoippushmetadata/mustreport)),
   but the deployment target is 17.0
   (`clients/ios/App/Config/Bundle.xcconfig:10`), so the design does not rely
   on it.
3. **`ready` only after the system accepted the call** (decision 14). The report
   can fail: "the system reports an error if the user enabled Do Not Disturb"
   (PushKit delegate page). If the report fails or the call is filtered, the
   app ends it and sends nothing, in particular no `ready`. Otherwise it
   bootstraps (only if protected data is available), fetches from its own
   committed cursor, processes the knock, sends the automatic `ready` from an
   in-memory readiness slot (`docs/protocol/voice-v1.md:84-92`), and the
   caller's offer arrives. The first valid knock binds to the pending CallKit
   UUID. Without this gate any known contact could knock up to 6 times a minute
   (`docs/protocol/voice-v1.md:96`) and learn from the automatic `ready`
   whether a locked iPhone is powered on and online, even in Do Not Disturb
   (threat C9). Today a closed iPhone never answers. Android answers every
   authenticated knock with `ready` through its durable outbox, not gated on
   being online (`clients/android/src/org/paranoid/text/CallController.java:207-219`),
   so an Android phone that is connected, or is reconnected by an FCM wake,
   already reveals this; the proposed iOS gate is stricter than Android.
4. **Background receipts.** The app's ordinary receive path commits every
   pending envelope, not only the knock, and queues the ordinary delivery
   receipts. The second check can therefore appear while the phone stays
   locked (threat C10, decision 14). REQ-MSG-003 defines two checks as
   "recipient delivery, not reading" (`docs/product/requirements.md:38`), so
   this does not contradict the requirement, but it is new: today the second
   check means that the user opened the app.
5. If no valid knock is found within 10 s, the knock is stale, blocked or busy,
   or the bootstrap ends frozen or waiting for protected data, the app ends the
   CallKit call at once with `reportCall(with:endedAt:reason:)`. The 45-second
   window is clamped from the sender's expiry
   (`clients/ios/ParanoidKit/Sources/ParanoidKit/Voice/CallController.swift:1198-1204`),
   so the whole chain (APNs, extension, launch, bootstrap, `ready`, offer) must
   fit inside it. That latency is UNVERIFIED and is measured on the device.
   Signal hands off on the offer itself, with no knock and `ready` round trip:
   its extension validates an offer and relays it, and drops answer, ICE,
   hangup and busy messages
   ([NSECallMessageHandler.swift L51-L96](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NSECallMessageHandler.swift#L51-L96),
   [L154-L166](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/NSECallMessageHandler.swift#L154-L166)).
   This chain is therefore at least one network round trip longer than
   Signal's.
6. Answer maps to the existing explicit Answer path; End or Decline maps to
   reject or end; `CXSetHeldCallAction` and a second call map to end or busy,
   because voice-v1 has no paused call.

Android does not need this path: it is a single process that rings through a
full-screen-intent notification
(`clients/android/src/org/paranoid/text/VoiceCallService.java:55-58`).

#### CallKit privacy configuration

- `includesCallsInRecents = false`. Apple's default is `true`
  ([Apple](https://developer.apple.com/documentation/callkit/cxproviderconfiguration/includescallsinrecents)),
  and Signal's user setting also defaults to on
  ([Preferences.swift L180-L190](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/Preferences.swift#L180-L190)).
  Whether third-party CallKit entries in Recents sync to iCloud is not
  documented by Apple (UNVERIFIED); off by default removes the question.
- Incoming caller name: the constant "ParanoID". The handle is
  `CXHandle(type: .generic)` with a fresh random UUID per call, never a contact
  name or account ID.
- No `INStartCallIntent` or `INSendMessageIntent` donation and no
  communication-notifications entitlement. `SRResearchDataGeneration = NO` in
  Info.plist, which Apple names as the way to stop SensorKit research apps
  collecting Speech Metrics during a CallKit call
  ([Apple CallKit: Manage user privacy](https://developer.apple.com/documentation/callkit)).
- `CXCallUpdate`: `supportsHolding`, `supportsGrouping`, `supportsUngrouping`
  and `supportsDTMF` are false; `hasVideo` is false until an offer says
  otherwise.
- **Outgoing calls through CallKit are an owner decision** (decision 15). Apple
  says: "When a person makes a call in your app that uses CallKit, your app
  provides the contact information of the recipient to the system. The system
  may use that information to indicate communication with that person as a
  suggestion in the Journal app" (CallKit page, above). If chosen, every
  outgoing call uses a fresh random handle and the constant name, never an
  account ID or contact name. The author recommends it, for one audio regime.
- A paired Apple Watch mirrors notifications: "If your iPhone is locked or
  asleep, you get notifications on your Apple Watch, unless your Apple Watch is
  locked" ([Apple Support 108369](https://support.apple.com/en-us/108369)).
  Whether the CallKit call screen also appears there is UNVERIFIED.
- Showing names on the call screen, and Recents, are later opt-ins, each a
  separate owner decision.

#### Audio session under CallKit

Today the app activates and deactivates the session itself
(`clients/ios/App/ParanoID/Voice/AudioSessionController.swift:245`, `:267`).
Under CallKit the system activates it and reports `provider(_:didActivate:)`,
and an app must not call `setActive(true)` itself
([Apple DTS forum](https://developer.apple.com/forums/thread/783870)). A CallKit
branch starts WebRTC audio from `didActivate` and stops it from
`didDeactivate`. The incoming ring becomes the system ringtone. The RFC-0025
lease accounting gains that branch, and its tests are extended.

#### Background and before-first-unlock launches

A PushKit launch is the first way this app can start without the user. The
hazard is narrower than a key deletion:

- `StorageGuard.start` deletes the wrapping key only when the install marker
  reads absent **and** no snapshot file is seen. Whenever the file is seen it
  returns `.frozen` before touching the key
  (`clients/ios/ParanoidKit/Sources/ParanoidKit/Storage/StorageGuard.swift:31-33`),
  and `KeychainKey.exists()` throws on an unreadable Keychain instead of
  reporting the key absent (`KeychainKey.swift:86-94`). A deletion before the
  first unlock would need `FileManager` to report the existing file as absent,
  which is not expected but is UNVERIFIED.
- The realistic risk is a spurious in-memory freeze. Before the first unlock,
  `UserDefaults` may be unreadable, so the marker reads absent while the file
  exists, or the Keychain throws. The bootstrap then freezes
  (`clients/ios/App/ParanoID/AppModel.swift:275-277`; the freeze is in memory
  only, `:325-331`), and a call already reported to CallKit would be left
  unhandled.
- **Proposal.** Before `StorageGuard.start` the bootstrap checks that protected
  data is available and otherwise waits for
  `protectedDataDidBecomeAvailable`. A PushKit launch that ends frozen, or is
  still waiting, ends the CallKit call at once (a C4 test). The extension never
  relays a call before the first unlock (step 1 of the extension), but the
  guard is required regardless.

#### Microphone consent

Ringing never requests the microphone (`docs/protocol/voice-v1.md:105-108`;
REQ-CALL-004, `docs/product/voice-calls.md:27`). Whether the system permission
prompt can appear when a call is answered from the lock screen is UNVERIFIED.
If it cannot, answering with an undetermined permission turns into a reject.
The owner chooses between keeping that behaviour and asking for the microphone
when the user enables background calls (decision 16). The second is an
explicit user action, but it changes the documented consent wording.

### Later complement: Local Push Connectivity

REQ-NET-001 requires useful operation inside a local network without public
internet (`docs/product/requirements.md:44`), where APNs cannot reach the
phone. Apple describes Local Push Connectivity as "appropriate for use cases
where an iOS device operates on a local, restricted network that doesn't have
access to APNs": an app extension keeps its own connection while the device is
on configured Wi-Fi networks, the app needs the Network Extensions entitlement
with the `app-push-provider` value requested from Apple, and "An app can use
both Local Push Connectivity and Apple Push Notification Service"
(Local Push Connectivity page, above). On a configured network it adds no
Apple server as an observer. It is a later complement, not part of this RFC:
it needs its own entitlement, provider extension, server-side connection
design and proposal.

### Token lifecycle

| Event | Client | Server |
| --- | --- | --- |
| Opt-in and authorization granted | register the APNs token over the signed session | insert into `ss_apns_tokens`; delete the account's FCM row, if any (decision 11) |
| Every launch while opted in | re-register, because the token may have changed | write nothing if the token is unchanged; otherwise replace it |
| Authorization revoked, opt-out, identity reset | empty token | delete the account's rows |
| Reinstall, restore, new device | new token registered on the first opted-in launch | the old token dies: `410` or `BadDeviceToken` causes compare-and-delete |
| APNs `410`, `BadDeviceToken`, `DeviceTokenNotForTopic` | none | compare-and-delete |
| Gateway without APNs | `404 push_disabled`: stay foreground-only, retry on a later launch | nothing stored |

An account cannot move between platforms: v2 has one immutable device per
account (`docs/protocol/self-service-v2.md:23`). Proactive rotation of
long-silent tokens is deferred. Signal, behind a remote flag, rotates a token
whose last received push is more than 60 days old
([APNSRotationStore.swift L6-L8](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/APNSRotationStore.swift#L6-L8),
[L139-L141](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/APNSRotationStore.swift#L139-L141),
[L165-L173](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/APNSRotationStore.swift#L165-L173),
[L259](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Util/APNSRotationStore.swift#L259)).

### Failure modes

| Failure | Behaviour |
| --- | --- |
| APNs unreachable or throttled | no banner; messages stay on the server and arrive when the app opens, as today |
| Push delivered after a long offline period | stage 1: one content-free banner; stage 2: classified against the current cursor, stale knocks silenced |
| Extension timeout | iOS shows the original payload: the stage 1 text |
| Extension crash or memory kill | the original payload is expected to show (UNVERIFIED on the device) |
| Stage 2 push less than 5 s after the previous fetch started | the stage 1 text with the fixed identifier; no fetch; no call hand-off |
| Stage 2 backlog larger than one page | the stage 1 text; a fresh knock beyond the page does not ring until later pushes reach it |
| Before the first unlock | stage 2: the stage 1 text once; no decrypt; no call hand-off |
| Notifications disabled by the user | the extension "isn't employed" (modifying-content page); the client unregisters on the next launch; calls do not ring either, as stated in the UI |
| CallKit report fails (for example Do Not Disturb) | the call is ended; no `ready` is sent |
| PushKit launch finds no valid knock, or bootstrap ends frozen | the CallKit call is ended at once |
| Filtering entitlement not granted | stay at stage 1 |
| Server rollback to an older binary | APNs table ignored; iOS foreground-only; FCM unaffected |

## What each party learns

The full table is in [the iOS push threat delta](../security/ios-push-threats.md).

### Apple (APNs)

- **From every push:** the recipient device (the token) and, through Apple's
  own records, the Apple Account behind it. Apple's Transparency Report says a
  push token "is generated and registered to that developer and device", and
  push-token requests "generally seek identifying details of the Apple Account
  associated with the device's push token, such as name, physical address and
  email address" ([Apple Transparency Report: push tokens](https://www.apple.com/legal/transparency/push-token.html)).
  Also that this device has ParanoID with push enabled; the gateway's IP
  address, the Team ID, Key ID, topic, priority, expiry and collapse
  identifier; the time of the wake; and the delivery status (delivered, stored
  while offline, discarded)
  ([Apple: push metrics](https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns)).
- **Across pushes:** timing patterns. A missed call to a closed iPhone is a
  knock wake followed, up to 45 s later, by an `end` wake (reasons `cancel` or
  `timeout`, `docs/protocol/voice-v1.md:53`, `:114`). Replies between two
  opted-in iPhones on one small gateway produce alternating wakes, and a
  message is often followed by a receipt wake to the sender once the recipient
  opens the app, which exposes contact pairs. With a mixed pair, Google sees
  the Android half of the same pattern. This is residual P13; the owner accepts
  it or not (decision 2).
- **Not from any single push:** the sender, content, ciphertext, size, or
  whether the envelope was a text, receipt, call control or first contact.
  Type, topic, priority, collapse identifier and payload are constant.
- **Already known without this RFC:** once the app is distributed through
  TestFlight, the install (`docs/security/ios-client-threats.md:122`; no
  TestFlight build exists yet, `docs/clients/ios/README.md:69-70`).
- **Probably already known (inferred, not documented):** Apple states that
  devices "need a persistent connection to Apple's servers" to use APNs
  ([Apple Support 102266](https://support.apple.com/en-us/102266)). That this
  connection already exposes the device's IP address and online status to
  Apple, independent of this app, is an inference; Apple does not document
  it.
- **On the device (stage 2):** the operating system knows that ParanoID
  reported a call, with the name "ParanoID" and a random handle. Whether this
  leaves the device is UNVERIFIED.

### The ParanoID server and gateway

- **Already held:** sender, recipient, ciphertext length and commit order of
  every message, and the contact graph
  (`docs/protocol/self-service-v2.md:56-60`;
  `server/self-service-schema.sql:17-29`), plus the IP address of every
  connection it serves.
- **New in stage 1:** that the account uses an Apple device with push enabled,
  and its APNs token. No time column (see [Token storage](#token-storage)).
- **New in stage 2:** the device's IP address and the time of every
  wake-triggered fetch while the app is closed. From that the server can infer
  "delivered to the device at T" although no receipt is sent. Today a closed
  iPhone contacts the server only when the user opens the app (threat P14).
  After a PushKit launch the app's ordinary path also sends `ready` and
  delivery receipts (C9, C10).
- **Trade-off recorded.** Apple's own design carries the encrypted data inside
  the push ("Your server sends the encrypted data to the receiver's device
  using a regular remote notification", sending end-to-end encrypted VoIP
  calls page), so no fetch is needed. That would make Apple store ciphertext
  and learn its size for up to the TTL, and a ParanoID envelope of up to 16384
  bytes does not fit APNs' 4 KB payload (sending-requests page). This RFC keeps
  the fetch and accepts P14. Fetch jitter, a random delay before the fetch,
  would blur timing but costs call latency; it is not proposed by default
  (decision 13).

### Network observers

- **On the phone's network (stage 2):** a TLS connection to the ParanoID server
  at every wake while the app is closed. Matched with the sender's upload at
  the server's network, it can reveal communication. Today such connections
  happen only while the app is open.
- **On the gateway's network:** HTTP/2 connections to `api.push.apple.com` and
  their timing, inside TLS.

### Contacts and other senders

- Any account that can message the phone, including a first contact
  (REQ-MSG-005, `docs/product/requirements.md:40`), can cause wakes: one banner
  per 10 s in stage 1 (P6), and in stage 2 extension fetches that spend the
  server's auth budget (P15).
- Stage 2 only: a known contact's knock leads to an automatic `ready` only
  after the system accepted the call (C9), and a PushKit launch sends ordinary
  delivery receipts (C10).

### Someone holding the phone or a paired Apple Watch

- The lock screen, Notification Center and a paired Apple Watch show that
  ParanoID is installed, and when things arrived. The call screen shows
  "ParanoID".
- iOS keeps delivered notifications in an on-device store. In the 404 Media
  case of 2026-04-09, incoming message text was recovered from it after the app
  had been deleted
  ([404 Media](https://www.404media.co/fbi-extracts-suspects-deleted-signal-messages-saved-in-iphone-notification-database-2/)).
  What it keeps for a content-free banner is not documented by Apple, so this
  RFC assumes a per-banner timeline of app and time (threat N3). Today's
  foreground-only client leaves nothing there.

### Combined: server data plus legal process to Apple

Seizure of the server or a backup, together with a legal request to Apple,
links a ParanoID account to an Apple Account (name, physical address, email).
Excluding tokens from backups reduces this; it does not remove it, because
commit times can be matched against Apple's per-token records (P11).

## How this compares with Signal

| | Signal (Signal-Server at `bdf3e1a`, Signal-iOS at `06fb42b`) | This proposal |
| --- | --- | --- |
| Push class | `alert` with `mutable-content` only for a message the sender marks `urgent`; a `content-available` background push otherwise ([APNSender.java L84-L132](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/push/APNSender.java#L84-L132); [IncomingMessageList.java L44-L48](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/entities/IncomingMessageList.java#L44-L48)) | one `alert` for every envelope; the server learns no urgency bit |
| Server VoIP pushes | none at the pinned head: `APNSender.java` builds only alert and background pushes ([L116-L120](https://github.com/signalapp/Signal-Server/blob/bdf3e1aea1b83e6ce14530ba515501c15bade3ad/service/src/main/java/org/whispersystems/textsecuregcm/push/APNSender.java#L116-L120)). The iOS client stopped registering VoIP tokens when using the notification service extension on 2021-06-02 ([5227fd6](https://github.com/signalapp/Signal-iOS/commit/5227fd64dcc46dab1197a98679a69fdb47dfa57c)), and the leftover token code was removed on 2024-08-29 ([929d9ee](https://github.com/signalapp/Signal-iOS/commit/929d9eeaefa82e921b6fab4601c9f454fe00b597)). | none |
| Extension role | a writer: fetches, decrypts, stores, posts local notifications, stores decrypted call messages for the app | read-only: fetches, classifies, posts one constant notification, writes only its cursor |
| Background receipts | the extension waits for pending receipt sends ([BackgroundMessageFetcher.swift L118-L134](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Messages/BackgroundMessageFetcher.swift#L118-L134)) | the extension sends nothing; a PushKit launch of the app does (decision 14) |
| Before the first unlock | empty content plus a one-time local notice | the same pattern |
| Extension timeout | completes silently | fails visible with the stage 1 text |
| Call hand-off | on the offer, with the decrypted message stored for the app | on the knock; the app re-fetches and sends `ready`, one extra round trip |
| Notification content default | "Name, Content, and Actions" ([NotificationPreferencesManager.swift L44-L46](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Notifications/NotificationPreferencesManager.swift#L44-L46), [L13-L14](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalServiceKit/Notifications/NotificationPreferencesManager.swift#L13-L14); [Localizable.strings L6458](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/Signal/translations/en.lproj/Localizable.strings#L6458)) | constant text only |
| Calls in Recents | on by default | off |

"Stage 2" therefore means comparable delivery and ringing for the user with
less disclosure, not Signal's architecture. It costs call latency.

## Alternatives

Every option is judged against the same drivers: nothing beyond what is listed
in [What each party learns](#what-each-party-learns), it works when closed,
force-quit or locked, it is honest in the UI, and it adds no second push
service or state owner.

| Option | Verdict | Reason |
| --- | --- | --- |
| A0 Stay foreground-only | kept as the opt-out mode | Leaks nothing new, but fails the request: messages wait, calls time out (`docs/security/ios-client-threats.md:94`). |
| A1 Background (`content-available`) pushes only, the iOS form of RFC-0020's data-only class | rejected | Low priority, not guaranteed, may be throttled ("don't try to send more than two or three per hour"), discarded after a force-quit (pushing background updates page). It cannot deliver "everything works". |
| A2 Alert pushes with constant text, no extension | **stage 1** | Works after a force-quit with the current storage. Costs false banners, a visible push class and no CallKit. |
| A3 Extension that decrypts | **stage 2, read-only variant** | The writer variant is rejected: two ratchet owners, last writer wins, `0xdead10cc`, and the `StorageGuard` key-deletion hazard. Showing names or content is deferred, because text in a notification lives in the iOS notification store beyond the app's control (404 Media, above). |
| A4 Server-sent PushKit VoIP pushes for calls | rejected | The server would have to learn call from text, and Apple would see the `.voip` topic and type, so "someone is calling now" leaks. Every VoIP push must be reported to CallKit or the app is terminated (PushKit delegate page). Signal's server builds no VoIP push at the pinned head, and its iOS client stopped registering VoIP tokens with the extension in 2021-06 (table above). |
| A5 Sender-set urgency or "no-wake" bit (Signal's `urgent`) | not proposed; owner fallback if filtering is refused | It silences receipt banners in stage 1 but tells the server which envelopes are receipts, and with background pushes also tells Apple. |
| A6 Our own persistent connection or relay over the internet | not possible on iOS for a suspended or force-quit app | iOS does not keep a third-party socket alive for a suspended or terminated app, and background refresh stays forbidden here (non-goals). Any internet relay must still end at APNs with the publisher's team key, so it removes nothing from Apple's view and adds a hop. |
| A7 Local Push Connectivity as the only path | rejected as the only path; a later complement | It adds no Apple observer on configured Wi-Fi and serves REQ-NET-001, but it covers nothing off those networks, needs an entitlement, and "An app can use both" (Local Push Connectivity page). See [the later complement](#later-complement-local-push-connectivity). |
| A8 Ciphertext inside the push (Apple's documented shape) | rejected | No fetch, so no P14; but Apple stores ciphertext and learns its size until the TTL, and envelopes of up to 16384 bytes exceed the 4 KB payload. |
| A9 LiveCommunicationKit instead of CallKit | rejected | No privacy gain for this use, and it raises the minimum iOS from 17.0 (`clients/ios/App/Config/Bundle.xcconfig:10`) to 17.4. |
| A10 Extension holds a `/v2/events` session | rejected | Two live sessions per account and no logout (`docs/protocol/realtime-v1.md:35`) mean a few pushes would lock the app out with `429`. Challenge-signed reads avoid this. |

## Security risks and threat-model changes

The threat rows and checks are in
[the iOS push threat delta](../security/ios-push-threats.md). The main risks:

- **P3 Forged banners.** The signing key together with the token table (a
  compromised gateway) can show arbitrary text on every opted-in iPhone,
  because iOS displays an alert push without `mutable-content` directly and
  shows the original content whenever the extension does not run. The key
  alone cannot address a device. The same class exists for the FCM key, because
  for notification messages "the FCM SDK displays the message to end-user
  devices on behalf of the client app when it's running in the background"
  ([Firebase: message types](https://firebase.google.com/docs/cloud-messaging/customize-messages/set-message-type)),
  and `docs/security/push-wake-threats.md` does not list it yet (row P3a).
- **P13 Timing correlation by Apple:** call-attempt signatures and
  conversation pairs, as described above.
- **P14 Stage 2 fetch disclosure** of the device IP and wake time to the server
  and on-path observers.
- **P15 Auth-budget amplification.** Each stage 2 wake costs one
  `POST /v2/auth/challenge`, which counts against the global budget of 8 auth
  requests per second (`server/src/self_service_http.rs:170-176`;
  `docs/protocol/realtime-v1.md:135-137`), plus one `GET`, out of 20 requests
  per second in total. There are at most 16 outstanding challenges globally
  and 4 per account (`docs/protocol/self-service-v2.md:84-86`), and the TLS
  acceptor holds 16 sockets (`docs/protocol/realtime-v1.md:143`). REQ-MSG-005
  lets anyone who knows a public contact send, so spam aimed at a few dozen
  opted-in iPhones, each woken at the 10-second limit plus the trailing wake,
  can saturate the auth budget and block `POST /v2/session` for every client,
  Android included. Proposed mitigations: extension reads count against a
  separate, smaller challenge budget instead of the session budget; a global
  cap on APNs wakes per second, sized so that extension fetches cannot exceed
  a fixed share of the auth budget; the extension's 5-second duplicate guard,
  which on a hit posts the stage 1 text instead of fetching and never
  silences; and a server capacity test. An Android wake that finds no live
  session also opens one (challenge plus `POST /v2/session`), so the same
  class probably applies to FCM; the capacity test checks both.
- **C9 Power-on probing** through the automatic `ready`, closed by sending
  `ready` only after CallKit accepted the call.
- **N3 Lock screen, Apple Watch and notification store** reveal the install
  and the arrival timeline.
- **S10 Signing authority in the extension** (read-only signer proposed).

Residual risks the owner is asked to accept or refuse:

1. R1: Apple learns the recipient device and Apple Account and the timing of
   every wake, including call-attempt and conversation-pair patterns.
2. R2: Token-to-Apple-Account linkage under legal process, by stored token or
   by timing, if server data is also obtained.
3. R3: Forged banners with the key plus the token table, for iOS and, in the
   same class, for Android FCM.
4. R4: Stage 1 false banners, and calls that ring only if the app is opened in
   time.
5. R5: The lock screen, Apple Watch and notification store show that ParanoID
   is installed and when things arrived.
6. R6: Stage 2: the server and on-path observers see the device IP and a
   delivery signal at every wake.
7. R7: Dependence on Apple's discretion: the filtering entitlement may be
   refused or delayed, and stage 2 cannot ship without it.
8. R8: Centralisation. The iOS users of every self-hosted server depend on the
   publisher's Apple team key and gateway (REQ-SERVER-001); a relay for other
   servers is a future deploy-trust proposal.
9. R9: Before the first unlock there is no classification and no CallKit ring.
10. R10: Spam-driven load on the auth budget until the server mitigations of
    P15 exist.

When ADR-0016 is accepted, `docs/security/ios-client-threats.md` boundary 8
(`:82-98`) and its diagram line (`:33`) are replaced by a link to the delta;
`docs/security/threat-model.md:290-297` and `:353-364` record boundary 8 as
used by both clients; `docs/security/push-wake-threats.md` gains P3a and the
YAML front matter the policy requires.

## Owner decisions

The decision owner is `martadvix-web`. Items marked "precondition" block
`proposed`.

| # | Decision | Owner | Needed by |
| --- | --- | --- | --- |
| 1 | Rule on RFC-0020 first by its own ADR, or have ADR-0016 cover the push gateway for FCM and APNs together. This RFC does not treat RFC-0020 as accepted. | martadvix-web | precondition |
| 2 | Accept Apple (APNs) as a new observer for iOS: the recipient device and Apple Account, the gateway address, the time of every wake, and the timing patterns of residual P13. This reverses the recorded foreground-only property (`docs/security/ios-client-threats.md:82-98`). | martadvix-web | 2026-10-15 |
| 3 | Accept a visible, system-rendered alert push class for iOS, although RFC-0020 chose data-only for Android, including the forged-banner surface P3. | martadvix-web | 2026-10-15 |
| 4 | Confirm REQ-CLIENT-005: its ID and its three clauses, with the call clause conditional on the filtering entitlement. | martadvix-web | 2026-10-15 |
| 5 | Apple team, App ID and key custody: which paid team owns `global.paranoid.messenger`; who creates, holds and revokes the production and sandbox keys; who requests the filtering entitlement; the plan if Apple refuses it (stay at stage 1, a sender-set no-wake bit, or nothing). | martadvix-web | precondition |
| 6 | Opt-in model (an offer after onboarding, proposed; off by default; or on by default), the opt-in card text and the Russian `PARANOID_WAKE` caption. | martadvix-web | 2026-10-15 |
| 7 | Accept stage 1 false banners rather than a sender-set no-wake bit that tells the server which envelopes are receipts. | martadvix-web | 2026-10-15 |
| 8 | TTL: 24 h (proposed), 60 s or 30 days. | martadvix-web | 2026-10-15 |
| 9 | Trailing-edge coalescing for both providers (changes RFC-0020 behaviour) or for APNs only. | martadvix-web | before the server pull request |
| 10 | Re-sending a wake suppressed by a waiter that ended empty: for both providers (changes Android behaviour) or for APNs only. | martadvix-web | before the server pull request |
| 11 | Token model: one token per account across platforms and an empty token that unregisters every platform (changes the RFC-0020 contract), or per-platform unregistering. | martadvix-web | before the server pull request |
| 12 | APNs tokens in backups: exclude (reduces, does not remove, linkage) or keep. | martadvix-web | before the deploy pull request |
| 13 | Stage 2: accept that the server and on-path observers learn the device IP and a delivery signal at every wake (P14); fetch jitter or none. | martadvix-web | before stage 2 |
| 14 | Stage 2: send `ready` only after CallKit accepted the call (proposed); accept that a PushKit launch sends ordinary delivery receipts while the phone stays locked. | martadvix-web | before stage 2 |
| 15 | CallKit defaults (Recents off, constant name, random handle) and whether outgoing calls also go through CallKit, which gives the system the recipient's contact information for Journal suggestions. | martadvix-web | before stage 2 |
| 16 | Microphone permission for answering from the lock screen: keep the explicit-Answer rule or ask when background calls are enabled. | martadvix-web | before stage 2 |
| 17 | Stage 2 storage and signing: the App Group mirror (proposed) or moving the authoritative snapshot; a second process holding the device-auth and wrapping keys, with the read-only signer. Needs storage and identity review. | martadvix-web with the storage reviewer | before stage 2 |
| 18 | Acknowledge residual R8 (centralisation for self-hosted servers) and record Local Push Connectivity as the later complement for REQ-NET-001. | martadvix-web | 2026-10-15 |
| 19 | A permanent approval of the exact closed-alpha scope below, and a separate approval for each hosted server action (key placement, schema change, config flip). | martadvix-web | precondition |
| 20 | Confirm `decision_deadline` 2026-10-15, aligned with RFC-0021 (ADR-0014 carries no deadline of its own), or set another. | martadvix-web | precondition |
| 21 | Add the forged-notification row P3a and the auth-budget check to the FCM threat delta. | martadvix-web | with decision 1 |

Technical items the author owns: pinning Apple's APNs CA in the gateway, and
the format of the gateway counters (both before the server pull request).

## Required review rationale

This proposal touches these
[protected decision domains](../governance/documentation-policy.md#protected-decision-domains):

| Domain | What changes |
| --- | --- |
| Security boundaries and trust assumptions | Threat-model boundary 8 is re-opened for iOS; Apple becomes an observer of the recipient device and wake timing; the push class changes from data-only to a visible alert (`docs/security/ios-client-threats.md:82-98`, `docs/security/threat-model.md:290-297`). |
| Identity and key derivation | Stage 2 brings the device-auth signing key (used by `sign_request_v2`, `clients/core/src/self_service.rs:249-268`) and the snapshot wrapping key into a second process. |
| Cryptographic and E2EE semantics | Stage 2 decrypts inbound envelopes in a second process through a new non-committing operation, including prekey messages in discarded candidates. |
| Protocol compatibility and public APIs | `POST /v2/push` accepts `platform:"apns"`, `404` replaces `400` on a server without that provider, and the token model changes the RFC-0020 contract (`docs/protocol/self-service-v2.md:66-73`). |
| Persistence formats and storage | A new server table; the App Group mirror and `nse-cursor.v1` on the phone. |
| Storage and data retention | Apple stores one pending push per app for up to the TTL; the iOS notification store retains banners; the server retains tokens. |
| Foundational dependencies | reqwest `http2`; UserNotifications, PushKit and CallKit; the Apple-granted filtering entitlement. |
| Deployment topology and backward compatibility | A second third-party credential (the `.p8` key) on the gateway host; self-hosted servers depend on the publisher's gateway; trailing-edge and stale-waiter changes alter FCM behaviour. |

`review_mode: closed-alpha-ai` is proposed, so `required_reviewers` is empty.
That is valid only with the complete
[closed-alpha evidence](../governance/documentation-policy.md#closed-alpha-review-exception),
none of which exists yet:

1. A permanent owner approval of the exact scope below, not a blanket "go".
2. An independent AI review in a fresh context, recorded in the pull request
   with model, reviewed revision, findings and resolutions. The author holds
   delegated technical decision authority
   ([issue #27 comment](https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919))
   but cannot review his own proposal, and the delegation does not cover
   product scope or server actions.
3. No unresolved blocking finding.
4. This RFC, ADR-0016, the versioned contract delta, the
   [threat delta](../security/ios-push-threats.md), a requirement-to-test
   mapping and real device evidence, with every unmeasured item marked
   `NOT RUN`.
5. Synthetic data only; E2EE unchanged.
6. Exit gate: independent qualified human review of identity, cryptography,
   persistence and application security before real communication.

Scope proposed for the owner's approval:

- Features: stage 1 and, separately, stage 2 as defined above.
- Devices: the contributor's iPhone (iPhone 16 Pro Max, iOS 26.6.1,
  `docs/security/ios-client-threats.md:128-135`) as the only iOS device; the
  owner's Android as a peer only with the owner's explicit per-session consent.
- Environment: a local stand with an APNs sandbox key for development builds.
  The hosted alpha only after a separate, explicit owner approval of each
  server action.
- Data: synthetic accounts and messages only.
- Human risk owner: `martadvix-web`.

## Compatibility, migration and rollout

### Compatibility

- **Wire.** Additive. Android keeps `platform:"fcm"`. An older server answers
  `400` to `"apns"`, and a server without APNs answers `404`; in both cases iOS
  stays foreground-only.
- **Core.** `platform` is optional with default `"fcm"`, so Android's JNI call
  does not change. `classify_v2` and `sign_read_v2` are new operations.
- **Server database.** `ss_apns_tokens` is additive and exists only with APNs
  configured. The deploy schema gate learns it in the same deploy change. A
  rollback to an older binary ignores the table.
- **iOS.** Stage 1 and stage 2 builds use the same server contract. Stage 2
  creates the mirror on the first commit after the upgrade. A downgrade to a
  stage 1 build leaves a stale mirror, so the stage 1 build that ships first
  already deletes any mirror and `nse-cursor.v1` it finds.
- **Gates.** The foreground-only gates become exact allowlists in the same
  pull request as the code; they are not deleted, and each new gate is shown
  RED against a mutation. Affected: `clients/ios/test_app_bundle.py:162-179`
  and `:317-323`; `clients/ios/test_ui_contract.py:842-869`;
  `clients/ios/ParanoidKit/Tests/ParanoidKitTests/LifecycleTests.swift:264-276`;
  `clients/ios/App/ParanoIDTests/ConnectivityRestartTests.swift:384-395`.
  `check_secrets` in `clients/ios/test_app_bundle.py` must tolerate the
  extension's embedded provisioning profile, and the pinned-session inventory
  must cover the extension.
- **Documents that change with the code** (code and docs never diverge):
  `docs/security/ios-client-threats.md:33`, `:82-98`;
  `docs/security/threat-model.md:290-297`, `:353-364`;
  `docs/decisions/0014-ios-client.md:162-166`, which gets a transparent link to
  ADR-0016 (ADR-0014 is still `proposed`);
  `docs/rfcs/0021-ios-client.md:177-180`, `:358-359`;
  `docs/project/current-state.md:737-740`; `docs/clients/ios/README.md:71-73`;
  the comments in `clients/ios/App/ParanoID/AppLifecycle.swift:33-37`,
  `clients/ios/ParanoidKit/Sources/ParanoidKit/Realtime/LifecyclePolicy.swift:131`,
  `:193`, `PushHook.swift` and `ParanoID.entitlements:5-10`; the UI strings in
  `clients/ios/App/ParanoID/Strings.swift`;
  `docs/protocol/self-service-v2.md:66-73`; `docs/product/requirements.md`
  (only if decision 4 confirms REQ-CLIENT-005); and `CHANGELOG.md`.
- **Pull request split.** The iOS component-boundary gate forbids `server/`,
  `clients/core/src/` and `deploy/` (`clients/ios/test_component_boundary.py:22-23`),
  and CI runs it on `feat/ios-*` branches (`.github/workflows/ios.yml:97`), so
  the server, core and deploy parts land in separate pull requests, as
  RFC-0020 did.

### Rollout

1. **Phase 0, documents and decisions.** This draft RFC, the threat delta and
   the index row, on a documentation branch that is not `feat/ios-*`. Then:
   re-check the numbers, an independent AI review, the owner's answers, the
   move to `proposed`, ADR-0016 as `proposed`, and a transparent link from
   ADR-0014.
2. **Apple steps, by the owner of the Apple team.** The production
   topic-specific key, a sandbox key for the local stand, and the filtering
   entitlement request, filed early because Apple's turnaround is unknown.
3. **Phase 1, server** (its own pull request). `push_apns.rs` as the second
   provider; reqwest `http2`; ES256 JWT on `ring`; `ss_apns_tokens`;
   `platform:"apns"`; the trailing-edge and stale-waiter changes as decided;
   the P15 budget changes; identifier-free counters. Tests first, against a
   fake HTTP/2 APNs and real PostgreSQL. `self-service-v2.md` changes in the
   same pull request.
4. **Phase 1b, deploy** (its own pull request; `deploy/alpha.py` is a red
   zone). Credential delivery, the config flip, the schema gate and backup
   handling as decided. Enabling it on the hosted alpha needs a separate,
   explicit owner approval.
5. **Phase 2, core** (its own pull request; red zone, test first). `push`
   gains `platform`.
6. **Phase 3, iOS stage 1** (`feat/ios-*`). Entitlement, opt-in card,
   registration, `PARANOID_WAKE`, long-poll cancellation, gates as allowlists,
   documents. Verified on the contributor's iPhone against the local stand
   with the sandbox key; everything unmeasured is `NOT RUN`.
7. **Phase 4, iOS stage 2**, only after the entitlement, the storage and
   identity review and the owner's separate approval: the core
   `classify_v2` and `sign_read_v2` (their own pull request), the mirror, the
   extension, PushKit, CallKit, the audio branch and the protected-data guard.
8. **Phase 5, closure.** Evidence gathered; ADR-0016 `accepted` with the
   owner's exact approval, RFC-0027 `completed`, and the decision-log entry,
   in one pull request.

**Rollback.** The server flip back to FCM-only restores today's behaviour; the
APNs table is ignored. An iOS user turns the feature off in Settings, which
unregisters the token. A stage 2 regression is handled by shipping a stage 1
build, which deletes the mirror.

## Operations and observability

- **Apple account.** The Account Holder of the paid team that owns
  `global.paranoid.messenger` creates the topic-specific production key and
  requests the filtering entitlement. The request form is behind an Apple
  login; its criteria and turnaround are unknown (UNVERIFIED).
- **Deployment.** The key goes in as `LoadCredential=push-apns-key:...` next to
  the FCM credential. The explicit config flip is journaled with restore.
  Egress is allowed to `api.push.apple.com:443` only. Every hosted step is a
  server action that needs the owner's explicit approval each time.
- **Capacity.** Wakes are bounded by `admit()`: one per account per 10 s plus
  one trailing wake, 4096 tracked accounts, one HTTP/2 connection. Stage 2
  adds the fetch load of P15, bounded by the proposed global APNs wake cap and
  the separate challenge budget.
- **Observability.** Today the gateway has no logs or metrics
  (`server/src/self_service_http.rs:620-645`), which would make a wrong key or
  environment invisible. Proposed: aggregate counters (sent, dead token,
  provider-auth error, transient, wakes refused by the global cap) with no
  identifiers, emitted at most once per 10 minutes. Tokens, accounts and JWTs
  are never logged.
- **Incident.** If the key leaks: revoke it in the developer account, deploy a
  new key, record the event. If the token table leaks: tokens alone cannot
  push, but they link to Apple Accounts, so treat it as a metadata incident; if
  both leak, forged banners are possible until the key is revoked.
- **Backup and restore.** Covered by the deploy gate, with decision 12.

## Validation plan

Everything is `NOT RUN` until evidence is recorded. Each item is marked
**[CI]** (Linux CI or local server tests), **[Mac]** (host, unit or simulator
on the contributor's Mac) or **[device]** (a physical iPhone; a simulator does
not count, per policy item 4).

### Server and deploy

- [CI] The exact request: path, every header and the body bytes; no account,
  device or ciphertext string; no other push type or topic can be built.
- [CI] The JWT verifies with the key's public half; `kid`, `iss` and `iat` are
  correct; reused within 20 minutes, regenerated on `ExpiredProviderToken`,
  never sooner than 20 minutes.
- [CI] The response mapping table, including a compare-and-delete that does not
  remove a newer token.
- [CI] Trailing-edge coalescing: a knock 3 s after a text gives exactly two
  wakes, the second at about 10 s. RED on the current code.
- [CI] Stale waiter: the client aborts `/v2/events`, a message commits, and a
  wake is sent. RED if the guard is not released on disconnect.
- [CI] Registration: `apns` accepted when configured, `404` when not, one row
  per account across platforms, the empty token deletes both; the old
  `apns → 400` assertion is rewritten deliberately.
- [CI] An unchanged token re-registration writes nothing.
- [CI] Capacity (P15): opted-in accounts spammed at the maximum admitted wake
  rate, with extension-style challenge fetches, do not push `POST /v2/session`
  for other accounts into `429`; the same check for FCM-driven reconnects.
- [CI] The endpoint override is refused in public mode; the key file checks are
  enforced; the config type is not `Debug`.
- [CI] Deploy: credential delivery, the schema gate with the optional table, a
  backup and restore round trip, and a rollback to the previous binary.

### Core

- [CI] `push` with `fcm` and `apns`; any other platform is rejected; the Android
  call is byte-identical.
- [CI] `classify_v2`: the output never contains plaintext; the state bytes are
  identical before and after; the class is correct for text, receipt, fresh
  knock, stale knock, blocked peer and first contact; one envelope of the
  maximum ciphertext size (16384 bytes) fits under the 65536-byte request
  limit; an oversize request is refused.
- [CI] `sign_read_v2` signs only `GET /v2/messages?after=<n>&limit=<m>` and
  refuses `POST` and every other path.

### iOS static gates

- [CI] Exact `UIBackgroundModes`: `[audio]` in stage 1; in stage 2 `[audio]` or
  `[audio, voip]`, as decided by the signed-build experiment (whether `voip` is
  required for this path is not stated by Apple; UNVERIFIED).
- [CI] Exact `aps-environment` per configuration.
- [CI] The app's entitlements are exactly the reviewed set; the extension's are
  exactly `usernotifications.filtering`, the literal Keychain group and the App
  Group; no communication-notifications entitlement.
- [CI] `SRResearchDataGeneration = NO`; `includesCallsInRecents = false` as a
  literal.
- [CI] The extension target contains none of the forbidden symbols; exactly one
  `PKPushRegistry` site; `UNUserNotificationCenter` in one app file and one
  extension file; no intent donation; `BGTaskScheduler` still forbidden.
- [CI] The `PARANOID_WAKE` string exists in the bundle.

### iOS unit tests and simulator

- [Mac] The extension decision table with a fake core and transport, including
  the fixed local-notification identifier.
- [Mac] The 5-second guard: a fetch completes, a new envelope commits, and a
  push arrives within 5 s of the fetch start. The expected result is the
  stage 1 text with the fixed identifier, never silence; `nse-cursor.v1`
  records the fetch start time.
- [Mac] The fetch cursor: with a backlog of more than 4 envelopes above the
  mirror cursor followed by a fresh knock, successive pushes fetch after
  `max(mirror cursor, nse-cursor.v1)` and never refetch an already-notified
  page; a full page posts the stage 1 text; a fresh knock inside the page is
  reported to CallKit. Its classification from the mirror state is covered by
  the crypto-review item in [`classify_v2`](#core-classify_v2).
- [Mac] `nse-cursor.v1` and the mirror: protection class, backup exclusion,
  deletion on identity reset.
- [Mac] The PushKit handler reports to CallKit before returning, on every path.
- [Mac] C4: a PushKit launch that ends frozen, or waits for protected data,
  ends the CallKit call at once.
- [Mac] `ready` is sent only after a successful report; a failed report (as
  with Do Not Disturb) ends the call and sends nothing.
- [Mac] The bootstrap refuses `StorageGuard` while protected data is
  unavailable.
- [Mac] The CallKit audio branch activates only from `didActivate`; hold maps
  to end.
- [Mac] An alert push through the real APNs sandbox to a simulator (Apple
  silicon, iOS 16 or later, per the
  [Xcode 14 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)).
  `simctl push` does not run extensions and does not count.

### Physical device

The owner's authorization is needed for any owner phone.

- [device] A force-quit, locked iPhone receives a message banner; the
  `loc-key`-only payload runs the extension in stage 2.
- [device] Stage 1: the false banner for a receipt is recorded. Stage 2: a
  receipt-only wake shows nothing, and a text followed by a receipt-only wake
  leaves exactly one message notification.
- [device] A timeout fallback banner followed by a silenced push with the same
  collapse identifier: the banner remains (otherwise the header is dropped).
- [device] A call to a locked iPhone rings through CallKit and connects on
  Answer; a stale knock does not ring; with Do Not Disturb on, the caller
  receives no `ready`.
- [device] After a reboot, before unlock: the stage 1 text once, no call
  hand-off, and no freeze after unlock.
- [device] With notifications denied, no token is registered.
- [device] Recents stays empty; no name appears on the lock screen; what a
  paired Apple Watch shows is recorded.
- [device] `removeAllDeliveredNotifications()` on opening clears Notification
  Center.
- [device] Extension peak memory with the largest alpha-sized state, which sets
  the memory gate and the classification budget.
- [device] End-to-end call latency against the 45-second window.
- [device] Sandbox versus production tokens; token change after reinstall.
- [device] Airplane mode for longer than a minute, then back (TTL).
- [device] The microphone prompt when answering from the lock screen.

### Acceptance criteria (proposed; the owner confirms)

- Stage 1: 20 of 20 messages to a force-quit, locked, opted-in iPhone on a
  healthy network produce a banner, with P95 under 10 s.
- Stage 2: 0 visible notifications across 20 receipt-only wakes, each arriving
  at least 5 s after the previous fetch started; 10 of 10 calls
  to a locked, force-quit iPhone ring through CallKit and connect on Answer;
  0 CallKit rings for 5 stale knocks; 0 `ready` sent for 5 knocks under Do Not
  Disturb.
- Both stages: the server test proves the constant request; the gates prove the
  allowlists; Recents stays empty.

### Requirement-to-test mapping (proposal)

| Requirement | Evidence |
| --- | --- |
| REQ-CLIENT-005 (a), proposed: messages | server payload test; stage 1 device run |
| REQ-CLIENT-005 (b): calls, conditional on the entitlement | extension decision tests; PushKit handler tests; stage 2 device run |
| REQ-CLIENT-005 (c): disclosure | payload and header test; unchanged-token test; gates; threat delta review; stage 2: device capture of one fetch per wake (P14), the Do Not Disturb `ready` test (C9) and the check of when the second check appears after a PushKit launch (C10) |
| REQ-MSG-003 (two checks mean delivery, not reading) | extension forbidden-symbol gate (no sends); device check of when the second check appears, including after a PushKit launch |
| REQ-MSG-005 (first contact can message) | capacity test for P15; wake spam bound P6 |
| REQ-CALL-004 (explicit answer consent) | microphone tests; device lock-screen answer |

## Open and unverified items

These are carried as assumptions until measured or sourced:

- Whether `voip` in `UIBackgroundModes` is required for the
  `reportNewIncomingVoIPPushPayload` path. Apple's end-to-end-encrypted call
  article does not mention it; Signal declares it
  ([Signal-Info.plist L129-L136](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/Signal/Signal-Info.plist#L129-L136)).
- The extension memory limit (about 24 MB, developer reports only).
- Whether the extension runs after a force-quit (stated by Apple staff on the
  forums, not in reference documentation).
- Whether a `loc-key`-only alert runs the extension (Signal's production
  payload suggests yes; a device test decides).
- Whether a silenced push with the same collapse identifier removes a displayed
  fallback banner.
- What the iOS notification store keeps for a content-free banner, and whether
  `removeAllDeliveredNotifications()` removes it from that store.
- Whether a CallKit call is shown on a paired Apple Watch, and whether
  third-party CallKit Recents entries sync to iCloud.
- Whether the fact of a CallKit report leaves the device.
- The filtering entitlement's criteria and turnaround.
- The meaning of `com.apple.developer.pushkit.unrestricted-voip`, which Signal
  holds for both its app and its notification service extension
  ([Signal-AppStore.entitlements L31-L32](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/Signal/Signal-AppStore.entitlements#L31-L32);
  [SignalNSE-AppStore.entitlements L13-L14](https://github.com/signalapp/Signal-iOS/blob/06fb42bbf4402c738fc6d37dcb2828ba6ec0ce9f/SignalNSE/SignalNSE-AppStore.entitlements#L13-L14));
  it is not used here.
- Whether `ring` parses Apple's `.p8`.
- Whether hyper releases `WaitGuard` on client disconnect, as
  `docs/protocol/realtime-v1.md:103-104` claims (untested).
- How `FileManager` and `UserDefaults` behave on a background launch before the
  first unlock.
- Whether the SwiftUI scene connects on a PushKit launch.
- PushKit and CallKit on the simulator.
- Whether a classification from the mirror state is correct for later
  envelopes, and whether a dry-run decrypt of a prekey message is safe.
- Real end-to-end call latency.
- The microphone prompt from a CallKit lock-screen answer.
- Whether the owner's team can register the bundle identifier if another team
  holds it.
- Time-sensitive notifications and Focus behaviour beyond Do Not Disturb were
  not researched.
- **Documentation discrepancy, reported and not resolved here.**
  `docs/project/current-state.md:784-785` says "Until the gateway is deployed
  with the Firebase credential no wake is sent", while the 2026-09-13 rollout
  record says "Push and voice configuration remain enabled" and counted 5
  push-token rows (`docs/operations/apk-cap-rollout-2026-09-13.md:57`,
  `:61-62`). Whether the hosted alpha sends FCM wakes today is therefore not
  established by the documents. This RFC does not depend on it. The
  documentation policy treats such a contradiction as a defect to resolve in
  the same change (`docs/governance/documentation-policy.md:48-49`), but this
  branch changes only the RFC, the threat delta and the index. The pull
  request that carries this draft lists it as an explicit item for the owner,
  and a separate small documentation change reconciles
  `docs/project/current-state.md` with the 2026-09-13 rollout record.

## Decision and follow-up

- Disposition: open (draft).
- Decision-owner approval permalink: none yet.
- Delegation evidence permalink:
  <https://github.com/GOTD-GLOBAL/ParanoID/issues/27#issuecomment-5651949919>
  (technical decisions within the bounded alpha; it does not cover product
  scope or server actions).
- Required-review evidence permalinks: none yet; an independent AI review is
  to be recorded in the pull request.
- Resulting ADR: ADR-0016, to be drafted as `proposed` (number re-checked
  before use).
- Closure rationale: not applicable.
- Replacement RFC: not applicable.
- Implementation issues: none yet.
