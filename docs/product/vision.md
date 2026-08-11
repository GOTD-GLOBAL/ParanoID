---
status: draft
owner: founder
last_reviewed: 2026-08-11
---

# Product vision

## One-sentence vision

ParanoID aims to be an open-source, crypto-native messenger that people and
organizations can run on infrastructure they control, federate when desired,
and extend into a commercial enterprise platform.

## Intended audiences

- Privacy-conscious users who want their own server and understandable control.
- Communities operating under unreliable, filtered, or restricted connectivity.
- Homes and small teams that need one-click self-hosting.
- Organizations that need local-network operation without public internet.
- Enterprises that need messaging plus configurable workflow and CRM capabilities.
- Developers building isolated extensions and future AI-assisted services.

## Product layers

1. **Open-source messenger**: text, media, audio, voice messages, calls, groups,
   and modern mobile experiences.
2. **Self-hosting ecosystem**: simple deployment, hosting partnerships, managed
   offers, upgrades, backups, and operational tooling.
3. **Crypto-native identity**: no mandatory phone number or email; seed-based
   control and an on-chain human-readable identity are core founder directions.
4. **Federation and multi-server use**: local autonomy with explicit inter-server
   connectivity and the ability for a user to interact through multiple servers.
5. **Enterprise platform**: paid plugins, administration, compliance controls,
   configurable workflows, and embedded CRM.
6. **AI platform**: optional project assistance, organizational agents, and later
   self-hosted model infrastructure.

## Product principles

- User and organization control must be real, not a branding claim.
- Self-hosting must be operable by non-specialists.
- Local-network messaging must not require public internet connectivity.
- Security and privacy claims must be specific, testable, and threat-modelled.
- Federation, blockchain, and plugins must have explicit trust and failure models.
- Open source is a product and community strategy, not permission to outsource
  engineering quality to contributors.
- Commercial features must not silently weaken the open messenger's security.

## Founder directions requiring specification

- Initial registration and authentication use no phone number or email.
- Initial account recovery is seed-only: losing the recovery words means losing
  the account.
- A human-readable username or nickname is anchored in a blockchain registry.
- Registration cost and mass-registration abuse must not be subsidized without a
  sustainable control mechanism.

These are product constraints, not yet a complete identity architecture. Solana
has been selected for the initial identity-registry prototype through
`ADR-0002`; the transaction and account model, custody, recovery flow, naming
rules, renewals, transferability, privacy, offline behavior, and mainnet design
remain undecided.

## Relationship to architecture decisions

This vision does not itself select implementation technologies. `ADR-0002` now
selects the initial Rust, PostgreSQL, Kotlin Multiplatform, and Solana/Anchor
prototype stack. No token, federation protocol, cryptographic construction,
identity protocol, or production blockchain deployment is accepted by this
vision or that stack decision.
