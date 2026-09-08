---
status: draft
owner: security
last_reviewed: 2026-09-08
---

# Threat model

This is an initial discovery scaffold, not evidence that ParanoID is secure.
Update it whenever assets, actors, data flows, dependencies, or trust boundaries
change.

## Active scoped analysis

The [single-server text delta](server-v0-threats.md) identifies proposed controls
and test mappings for RFC-0006. It is unimplemented and not a completed review.

## Security objectives

- Prevent unauthorized control of accounts, devices, servers, names, and plugins.
- Protect message content according to a precisely defined encryption scope.
- Minimize and document metadata visible to servers, peers, chains, push services,
  hosting providers, plugins, and observers.
- Preserve authenticity and integrity across synchronization and federation.
- Remain recoverable from operational failure without inventing hidden account
  recovery that contradicts paranoid mode.
- Make security-relevant state and failures understandable to users and operators.

## Assets

- recovery seed and derived key material;
- device authorization and revocation state;
- blockchain identity and nickname control;
- message content, attachments, call media, and local caches;
- contact, group, timing, presence, and federation metadata;
- server credentials, backups, configuration, logs, and update channel;
- plugin permissions, tokens, data, and outputs;
- enterprise CRM and organizational data.

## Candidate threat actors

- opportunistic remote attacker;
- malicious or compromised server operator;
- malicious federation peer;
- malicious plugin or AI service;
- compromised client device;
- hosting, DNS, network, push-notification, or blockchain observer;
- spammer, bot operator, name squatter, or economic-abuse actor;
- insider with administrative access;
- software supply-chain attacker;
- coercive or censoring network authority.

## Trust boundaries to define

1. Recovery seed to device key derivation.
2. Device to local secure storage and operating system services.
3. Client to home server.
4. Server to federation peer.
5. Client or service to blockchain RPC and naming contracts.
6. Core system to plugin, bot, CRM, and AI services.
7. Server to database, object storage, backup, update, and observability systems.
8. Mobile client to platform push notification services.

## Priority discovery questions

- Which keys exist, where are they generated, and what can each key authorize?
- How are devices added, verified, rotated, revoked, and recovered?
- What happens when the blockchain or RPC provider is unavailable, reorganized,
  censored, expensive, or inconsistent?
- Which identity and relationship metadata becomes permanently public on-chain?
- Who can correlate a nickname, wallet, server, IP address, and social graph?
- Which messaging modes are end-to-end encrypted, and who are the endpoints?
- How are group membership changes authenticated and reflected in key state?
- How do federation peers limit spam, replay, enumeration, and resource exhaustion?
- Can plugins or enterprise controls access plaintext, keys, metadata, or recovery
  paths, and how is that consent represented?
- How are binaries, containers, mobile releases, and automatic updates signed and
  verified?

## Isolated Android probe boundary

The [experimental probe](../../spikes/002-android-bootstrap/README.md) creates
both participants in one Android process, with synthetic data and no network
permission. Java invokes a native Rust self-test; JNI returns only a result code.
No production identity, contact authentication, server trust, durable key storage,
or recovery protocol is implemented. Its public test pickle key is unsuitable for
real storage. Dependency supply-chain, native load and platform compatibility risks
remain; local tamper/replay checks are not a production security review or E2EE
claim. Independent qualified human review remains required for adoption.

## Required analysis artifacts

Before the first architecture is accepted, add data-flow diagrams, STRIDE-style
threat enumeration, abuse cases, risk ratings, mitigations, residual risk owners,
and verification tests. Before release, perform independent cryptographic and
application security review appropriate to the claims being made.
