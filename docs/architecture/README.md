---
status: draft
owner: architecture
last_reviewed: 2026-08-09
---

# Architecture map

ParanoID uses the C4 model for durable architecture views. Diagrams are maps,
not decisions; every important choice shown in a diagram must link to an accepted
ADR or be marked as proposed.

## Planned views

| View | Purpose | Current state |
| --- | --- | --- |
| System context | People, external systems, and trust boundaries | Conceptual draft below |
| Containers | Deployable applications and data stores | Not defined |
| Components | Internals of a container where the detail adds value | Not defined |
| Dynamic | Identity, message, federation, recovery, and call flows | Not defined |
| Deployment | Home, managed, enterprise LAN, and federated topologies | Not defined |

## Conceptual system context

This diagram records scope only. It deliberately avoids choosing a stack,
protocol, chain, or cryptographic construction.

```mermaid
flowchart LR
    user["User"]
    admin["Server administrator"]
    enterprise["Enterprise operator"]
    client["ParanoID client"]
    server["ParanoID server"]
    peer["Federated ParanoID server"]
    chain["Identity blockchain<br/>(technology undecided)"]
    plugin["Permissioned plugin or enterprise service"]

    user -->|messages and calls| client
    client -->|messaging and synchronization| server
    client -->|identity registration and proof| chain
    admin -->|deploys and operates| server
    enterprise -->|administers local environment| server
    server <-->|policy-controlled federation| peer
    server <-->|explicit capabilities| plugin
```

## Proposed private-alpha deployment view

```text
OPPO A/B (Olm keys + encrypted client state)
  -> direct pinned IP TLS :38443 -> Rust server (closed-alpha-v0)
  -> private Unix socket -> dedicated PG16 cluster / ciphertext + metadata
systemd user unit -> Python supervisor -> server + private PG16
operator -> verified release pointer / restricted dumps + isolated restore DB
neighboring Nginx :80/:443 and existing PG: no connection or modification
```

This local-package view accompanies draft RFC-0009/ADR-0005, not accepted
production architecture or evidence of a hosted rollout.

## Proposed registration boundary (RFC-0010; local candidate implemented)

```text
Phone: account root + device auth keys | independent existing Olm + storage keys
  -> public request QR -> trusted maintainer verification -> local grant tool
  <- exact-key public grant QR (not a bearer, no public grant-creation API)
  -> pinned TLS + one-use signed proof -> server grant/device/mode mapping
  -> explicitly assigned existing 0/1 transport principal -> unchanged history
Phone A <-> explicitly compared contact QR/root-device-Olm binding <-> Phone B
```

[The proposal](../rfcs/0010-phone-key-registration.md) separates local identity
creation from closed-alpha admission. Public signup, blockchain and recovery
are not introduced; existing pins, keys and message state are preserved.
The [local operator/test runbook](../operations/key-registration-local.md) documents
the executable candidate. This view is not accepted production architecture or
evidence that the hosted endpoint has been migrated.

## Proposed self-service v2 server boundary

The local candidate replaces operator-dependent signup and pair routing in a
separate v2 mode. The [data-flow/trust-boundary view](../security/self-service-v2-threats.md#data-flow-and-trust-boundaries)
shows client proof, bounded ingress/challenges, serialized private PostgreSQL
transactions and offline legacy migration. It is scoped to the locking loopback
TLS binary, not public deployment or completed client architecture.
[ADR-0007](../decisions/0007-self-service-messenger.md),
[RFC-0012](../rfcs/0012-self-service-messenger.md) and the
[wire contract](../protocol/self-service-v2.md) remain drafts. Historical views
above are not self-service authority or evidence of a v2 hosted rollout.

The later [fresh-only deployment candidate](../operations/fresh-self-service-v2.md)
reuses the isolated supervisor/private PG container boundary, with explicit
reviewed IPv4:38443 TLS and one-shot replacement of only the old server data
cluster. TLS/phone state/neighbors stay outside discard. This extends the original
local-only view, not an accepted architecture or hosted rollout.

## Proposed clean-install first-contact boundary (RFC-0014)

```text
Sender: genuine recipient QR -> immutable peer/channel -> Olm PlainV1 text
  -> device-signed intro-v2 -> sealed immutable outbox -> v2 pinned-TLS transport
Recipient: zero contacts -> signature/recipient/channel + transient Olm candidate
  -> exact PlainV1 + budgets -> atomic unverified dialog/plaintext/receipt snapshot
  -> immediate reply UI -> same signed channel and one shared retained Olm Account
Server: existing proof-authenticated opaque POST/GET; no content keys or directory
```

[The exact proposed contract](../protocol/first-contact-v1.md) uses clean core3/
sealed snapshot4 and rejects old client snapshots unchanged. The owner removed
historical migration/recovery from this local candidate's gate. The source/build
is not accepted architecture, current live rollout or physical-phone evidence.

## Rules for diagrams

- State scope, audience, and abstraction level.
- Label every relationship with intent or data flow.
- Show trust boundaries and external dependencies.
- Do not mix context, container, component, and code levels.
- Prefer a small number of useful views over diagrams that mirror every class.
- Update a diagram in the same change that alters the architecture it represents.

## Overnight realtime candidate

[Retained-stack realtime proposal](../rfcs/0015-overnight-realtime.md) records the current private-alpha scope and its exact review/test gates.
No permanent architecture acceptance or physical-phone result is implied.

## One-host coordinated voice installation

[REQ-DEPLOY-003](../operations/voice-single-host.md) records the owner-selected
single existing host and one installer across messaging/private PostgreSQL/relay.
The coordinator and its cross-user deployment boundary remain proposed under
[RFC-0018](../rfcs/0018-voice-turn.md); mandatory runtime tests and independent
review gate any exposure. Existing message TLS/data/identity and neighbors remain
protected; this is not permanent stack/architecture acceptance.
