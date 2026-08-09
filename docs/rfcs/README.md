---
status: accepted
owner: maintainers
last_reviewed: 2026-08-09
---

# Request for comments process

RFCs make significant proposals reviewable before implementation. They are not
accepted architecture until an ADR records the decision.

## States

- `draft`: author is still developing the proposal;
- `proposed`: ready for review and experiments;
- `accepted`: decision approved; link the resulting ADR;
- `rejected`: not selected; preserve the reason;
- `withdrawn`: author stopped the proposal;
- `superseded`: replaced by a linked RFC.

## Naming

Use `NNNN-short-title.md`. Allocate the next number and never reuse it. Add active
RFCs to this file when the first proposal is opened.

## Required use

Create an RFC for identity, cryptography, blockchain, federation, storage,
protocols, plugins, foundational dependencies, deployment topology, or any change
whose reversal would be expensive or compatibility-sensitive.

Use [the RFC template](rfc-template.md).
