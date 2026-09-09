---
status: proposed
owner: product
decision_owner: martadvix-web
last_reviewed: 2026-09-09
---

# Overnight messenger scope and acceptance

The current direct task says: “execute complete overnight implementation, real
 tests, independent Fable security review, signed APK and narrowly authorized safe
 existing-service deployment.” Its exact detailed instructions and owner
clarifications are preserved in the external `overnight-realtime-20260909T191524Z`
evidence directory. Deadline: 2026-09-10 09:00 Europe/Istanbul (06:00 UTC).
No Telegram permalink was supplied. This records current scoped implementation
and deployment authority, not permanent architecture acceptance.

| ID | Required outcome | Acceptance boundary |
| --- | --- | --- |
| REQ-MSG-006 | Fast foreground E2EE text using a persistent authenticated transport, independent state/network work and durable publication before receipt I/O | Real pinned TLS/PostgreSQL/JVM/JNI P50 <=500 ms, P95 <=1500 ms under stated healthy conditions; physical render separately NOT RUN without phones |
| REQ-CLIENT-004 | Native messenger UI adapted from the supplied mobile prototype with real chat list, bubbles, stable composer, clear identity trust and delivery | Real Android rendering and interactions; light/dark and keyboard inspection; no fabricated contacts, timestamps, call controls or read receipts |
| REQ-MULTI-002 | One portable root identity with isolated server memberships, sessions, credentials, cursors, outboxes and connection failure domains | Architecture explicitly separates root from membership; second server implementation/deployment is not an overnight gate |
| REQ-SERVER-003 | Per-server membership revocation stops future authorized reads/writes and pending access; invitations may be granted by role | Tonight preserves self-registration; role-based invitations are future work. Revocation cannot erase cached plaintext; future group rekey and active peer-to-peer voice limits remain explicit |
| REQ-DEPLOY-002 | Update only the existing isolated service after independent review, real tests, encrypted verified backup and same-data rollback readiness | Preserve TLS/SPKI/origin, identities, all existing data, config, neighbors, firewall/DNS and retained releases. No destructive replacement or stale-dump rollback |

REQ-MSG-002/003/004/005 and REQ-ID-005/007/008 remain in force. In-place update
must preserve delivered v7 core3/sealed4 identity, contacts and history. Prior
clean-install permission is not a current phone reset action. Unsupported older
historical state remains preserved and honestly reported separately; historical
failures are not waived or relabeled passing.

Native state has one owner. Immutable ciphertext must commit before network;
decrypt/history/receipt candidate must commit before visible publication. Receipt
network delay cannot block publication or unrelated UI actions. Failed/ambiguous
local persistence freezes future mutation and network dispatch. Reconnect must
retain exact outbox bytes and handle crossing sends, lost replies and server
restart without duplicate messages or fabricated delivery. Actual bounds, auth,
replay and race tests follow [the protocol](../protocol/realtime-v1.md).

Owner-selected GPL-compatible open-client direction permits evaluating mature
OSS as the long-term base. This overnight work keeps the already working E2EE
core; it does not accept XMPP/Conversations or another foundational stack.
Blockchain is a later public anchor only. Federation is disabled by default in
the proposed multi-server direction and requires later explicit policy.

Background delivery should be attempted through a user-visible Android-supported
foreground connection with bounded retries and an eventual provider abstraction
for FCM/UnifiedPush/Huawei. No mandatory Google service or fabricated provider
credentials. Report screen-off/Doze/force-stop limitations. Voice remains stretch;
if absent, omit call controls. No physical phone action is authorized here.

[The proposed RFC](../rfcs/0015-overnight-realtime.md) and
[ADR-0010](../decisions/0010-overnight-realtime.md) remain proposed. Independent
fresh Fable design and final exact-source code/deployment reviews are required,
with blockers fixed and reviewed again. This is bounded private test data, not a
human security audit or a production assurance claim.
