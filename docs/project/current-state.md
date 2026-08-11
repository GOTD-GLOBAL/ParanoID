---
status: accepted
owner: maintainers
last_reviewed: 2026-08-11
---

# Current project state

## Phase

**Inception and first vertical-slice design.** This repository is a clean reboot.
It contains documentation governance, product framing, an accepted initial
implementation stack, and a proposed identity design. It has no messenger
implementation or accepted production identity protocol.

The earlier proof of concept is preserved in the private
`GOTD-GLOBAL/ParanoID-legacy` repository. It may be mined for lessons, UX ideas,
and experiments, but it is not a dependency or source of current architecture.

## Present facts

- The new repository is private and intentionally starts from a clean history.
- The product vision is documented as a draft.
- Initial product requirements are traceable but do not yet have complete
  acceptance criteria.
- Documentation-as-code is the first accepted project decision.
- The initial implementation stack is accepted through `ADR-0002`: a Rust
  modular-monolith server, PostgreSQL, Kotlin Multiplatform mobile clients, a
  Rust identity reference crate, and a Rust/Anchor Solana registry prototype.
- Solana is selected for the identity-registry prototype, local-validator tests,
  and Devnet integration. No mainnet program, account layout, fee policy, or
  production RPC architecture is accepted.
- Identity, registration, and authentication are being specified in proposed
  `RFC-0002`. Key derivation, signed encodings, device revocation, offline cache,
  and the on-chain nickname data model remain unresolved.
- The first intended vertical slice is seed generation, nickname registration,
  device authorization, signed challenge authentication, and server session
  creation. It is not implemented yet.
- No messaging protocol, end-to-end encryption construction, federation
  protocol, hosting platform, or token model has been selected.
- No production security or privacy claims are valid yet.

## Next decision gates

1. Resolve the open key-hierarchy, encoding, recovery, nickname, cache, and
   revocation questions in `RFC-0002`.
2. Prototype and measure the candidate Solana registry account models and abuse
   economics on a local validator and Devnet.
3. Produce cross-platform identity and signed-challenge conformance vectors.
4. Accept the identity protocol through an ADR or reject and revise the proposal.
5. Create the minimal server, identity-core, registry, and mobile scaffolds using
   the accepted stack.
6. Implement and verify the first identity vertical slice without production
   security claims.

## Update trigger

Update this document whenever a gate is completed, a production capability is
added, a major risk changes, or an accepted decision changes what a newcomer
should believe about the project.
