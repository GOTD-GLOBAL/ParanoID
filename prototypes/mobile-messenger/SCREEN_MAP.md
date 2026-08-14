---
status: draft
owner: product-design
last_reviewed: 2026-08-14
---

# Mobile messenger prototype screen map

This is an exploratory information architecture for a high-fidelity prototype.
It is not an accepted protocol, API, privacy model, or production capability.

## Global navigation

Compact iOS and Android clients use four stable destinations:

1. **Chats** — conversations, requests, archive, and global message search.
2. **Calls** — call history and start-call entry point.
3. **Contacts** — people, invitations, nickname/QR lookup, and server context.
4. **Settings** — profile, devices, servers, privacy, notifications, data, help.

Conversation, setup, call, and creation flows sit above these destinations and
always provide a visible escape or predictable back path.

## Route inventory

| Flow | Route | Purpose / transition |
| --- | --- | --- |
| Launch | `splash` | Brand launch → `welcome` |
| Account | `welcome` | Create account or sign in |
| Account | `server-choice` | Use known server, nearby server, address, or deployment |
| Server | `server-connect` | Review address, operator, reachability, and limitations |
| Server | `server-deploy` | Select a supported deployment path (concept only) |
| Server | `server-preflight` | Check domain, machine, ports, backup destination |
| Server | `server-progress` | Staged deployment feedback with safe exit |
| Server | `server-ready` | Admin recovery reminder and client connection QR |
| Registration | `nickname` | Choose a unique nickname; no phone or email |
| Registration | `public-metadata` | Disclose candidate public/correlatable registry metadata |
| Registration | `recovery-warning` | Explain irreversible seed-only recovery |
| Registration | `recovery-words` | Display synthetic recovery-word UI; never a real seed |
| Registration | `recovery-confirm` | Confirm offline backup without clipboard dependence |
| Profile | `profile-create` | Display name and optional local avatar |
| Onboarding | `permissions` | Explain notifications, contacts, camera, and microphone |
| Onboarding | `ready` | First-success moment → chats |
| Sign in | `sign-in` | Unlock this device, pair device, or recover with words |
| Sign in | `recover` | Seed-only recovery warning and synthetic entry UI |
| Main | `chats` | Conversation list, requests, unread, compose |
| Main | `chat-personal` | Direct conversation with mixed message types |
| Main | `chat-group` | Group conversation, threads/replies, member context |
| Messaging | `message-actions` | React, reply, forward, copy, details, delete |
| Messaging | `attachments` | Photo, video, file, camera, contact attachment sheet |
| Messaging | `media-preview` | Preview and caption before sending |
| Messaging | `voice-recording` | Accessible hold/lock/cancel/send recording state |
| Messaging | `forward` | Search and select recipients; confirm once |
| Search | `search` | People, chats, and messages with filters/recent queries |
| Contacts | `contacts` | Contacts, requests, nearby/QR, server-aware identity |
| Contacts | `contact-add` | Find by nickname/address or scan a QR code |
| Groups | `group-create` | Select people → name/avatar → permissions → create |
| Profile | `profile-user` | Person, shared groups, media, notifications, block/report |
| Profile | `profile-group` | Members, media, invite link, roles, leave group |
| Calls | `calls` | History, missed state, start audio/video/group call |
| Calls | `call-incoming` | Incoming audio call with platform-adaptive system surface |
| Calls | `call-outgoing` | Connecting/ringing with cancel and route detail |
| Calls | `call-audio` | Active one-to-one audio call controls |
| Calls | `call-video` | Active one-to-one video call and local preview |
| Calls | `call-group` | Adaptive group video grid, speakers, participants, chat |
| Settings | `settings` | Account and app settings hierarchy |
| Settings | `settings-privacy` | Read receipts, presence, calls, blocked users, metadata help |
| Settings | `settings-notifications` | Per-scope alerts, previews, sounds, calls |
| Settings | `settings-data` | Auto-download, storage, upload quality, local cache |
| Trust | `devices` | Authorized devices and revocable server sessions |
| Trust | `servers` | Multiple servers, local/degraded status, add/switch/remove |
| State | `state-loading` | Skeleton with preserved layout |
| State | `state-empty` | First-use chats state with one action |
| State | `state-error` | Specific failure and retry path |
| State | `state-offline` | Local/degraded operation, queued messages, stale warning |
| State | `state-permission` | Denied permission with Settings recovery path |

## Critical paths

```text
Create identity
Splash → Welcome → Server choice → Connect/deploy → Nickname
→ Public metadata → Recovery warning → Recovery words → Confirm
→ Profile → Permissions → Ready → Chats

Daily messaging
Chats → Personal/group chat → Message action / attachment / voice
→ Send state → Conversation

Server ownership
Server choice → Deploy → Preflight → Progress → Ready
→ Connect this device → Registration

Calling
Calls or chat header → Outgoing → Audio/video → Active call → Chat
Incoming system surface → Answer → Active call → Chat
```

## Explicit research gaps

- Messaging ordering, sync, retention, E2EE, group epochs, call signaling, and
  federation contracts do not exist yet.
- Server deployment providers, exact secure defaults, backup/restore flow, and
  supported topology are not accepted.
- Contacts, notification metadata, call privacy, block/report semantics, and
  user-facing error taxonomy have no stable requirements.
- The prototype therefore tests navigation, comprehension, and visual direction;
  every behavior above remains proposed until the relevant requirement, RFC,
  threat model, specification, and decision are accepted.
