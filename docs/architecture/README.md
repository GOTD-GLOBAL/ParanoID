---
status: draft
owner: architecture
last_reviewed: 2026-08-11
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

This diagram records scope only. The initial implementation stack is accepted in
[ADR-0002](../decisions/0002-initial-technology-stack.md), but identity,
messaging, federation, and cryptographic protocols remain undecided.

```mermaid
flowchart LR
    user["User"]
    admin["Server administrator"]
    enterprise["Enterprise operator"]
    client["ParanoID client"]
    server["ParanoID server"]
    peer["Federated ParanoID server"]
    chain["Solana identity registry<br/>(protocol proposed)"]
    plugin["Permissioned plugin or enterprise service"]

    user -->|messages and calls| client
    client -->|messaging and synchronization| server
    client -->|identity registration and proof| chain
    admin -->|deploys and operates| server
    enterprise -->|administers local environment| server
    server <-->|policy-controlled federation| peer
    server <-->|explicit capabilities| plugin
```

## Rules for diagrams

- State scope, audience, and abstraction level.
- Label every relationship with intent or data flow.
- Show trust boundaries and external dependencies.
- Do not mix context, container, component, and code levels.
- Prefer a small number of useful views over diagrams that mirror every class.
- Update a diagram in the same change that alters the architecture it represents.
