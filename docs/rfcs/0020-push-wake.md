---
status: proposed
owner: architecture
decision_owner: martadvix-web
review_mode: closed-alpha-ai
decision_deadline: 2026-09-19
required_reviewers: []
last_reviewed: 2026-09-12
---

# RFC-0020: Content-free push wake through a single FCM gateway

## Problem

Background delivery on the alpha phones (OPPO/ColorOS) relies on the user-enabled
foreground connection plus an inexact watchdog. The owner reports (2026-09-12)
that notifications are unreliable: the OEM kills or throttles the foreground
service and the long-poll is not re-established until the app is opened. There
is no push provider in any shipped build.

## Owner decision (Telegram, 2026-09-10/11/12; recorded here, not yet approved as ADR)

- One Google account, one Firebase project (`para-no-id`, package
  `global.paranoid.messenger`), one push gateway; many ParanoID servers later.
- The FCM service-account key lives only on the gateway host as a systemd
  credential. Deployed servers never receive the key; in the single-host alpha
  the message server *is* the gateway.
- FCM is an additional transport: data-only, content-free wake. Devices without
  Google services keep the foreground channel and watchdog (UnifiedPush later).

## Proposal

### Wire (server, `docs/protocol/self-service-v2.md` delta)

- `POST /v2/push` over the existing signed session (`ParanoidSessionV2`), body
  `{"platform":"fcm","token":<opaque, ≤4096 graphic ASCII>}`; empty token
  unregisters. One token per account (its active device). `404 push_disabled`
  when the gateway is not configured; the base v2 schema is byte-identical and
  the `ss_push_tokens` table is created only on a configured gateway.
- After a committed `POST /v2/messages`, if the recipient has no live
  `/v2/events` waiter and a token, the server sends **one** FCM v1 message
  `{"data":{"t":"wake"},"android":{"priority":"high","ttl":"60s"}}` — no
  sender, recipient, ciphertext, call or size information. Per-account
  minimum interval 10 s; global cap 4096 tracked accounts. `UNREGISTERED`
  deletes the token. Failures never affect the sender's response.
- OAuth2: RS256 JWT from the service account, access token cached ≤ 1 h.
  Outbound HTTPS to `oauth2.googleapis.com` / `fcm.googleapis.com` only
  (webpki roots). Startup refuses the endpoint override in public mode.

### Client (call-v2 phones, next APK)

- Register the FCM token after the signed session is established and on token
  rotation; unregister on identity reset. Core signs the request
  (`sign_session_v2` operation `push`).
- On a `wake` data message: start the realtime loop (foreground service when the
  user enabled background; otherwise a bounded fetch) — the wake carries nothing
  to display. Incoming call signaling still needs the app's own authenticated
  receive path; the wake only shortens the time to reconnect.

## Threat delta (see `docs/security/push-wake-threats.md`)

Google learns: app install, FCM token, and the *timing* of wakes for a device
(≈ "someone messaged/called you now"). It never learns who, what, or the
ciphertext. The gateway key compromise lets an attacker wake devices (battery,
traffic) but not read or forge messages. Wake rate limiting bounds abuse by a
sender. Server compromise already implies metadata exposure; tokens add a
Google-side identifier that a compromised server could correlate — mitigated by
deleting tokens on unregister and by the single-gateway boundary.

## Alternatives

- Foreground-only (status quo): unreliable on OEM firmware (owner report).
- UnifiedPush: no Google dependency, but requires a distributor app and a
  self-hosted push server; kept as follow-up for Huawei/degoogled devices.
- Notification-carrying pushes: rejected — content and metadata would transit
  Google.

## Gates

Server tests (fake OAuth/FCM, real PostgreSQL): registration shape, content-free
payload, rate limit, dead-token removal, disabled-mode 404, credential parsing.
Deployment: credential via `LoadCredential`, environment path only. Phones: a
message to a backgrounded/killed app must arrive as a notification within
seconds on both OPPO phones.
