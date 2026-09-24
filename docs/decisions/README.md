---
status: accepted
owner: architecture
decision_owner: martadvix-web
approved_change: RFC/ADR lifecycle, decision authority, durable evidence, and protected-domain review governance
approval_date: 2026-08-17
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/4
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/4#issuecomment-5311797500
last_reviewed: 2026-08-15
---

# Architecture decision log

ADRs preserve why durable choices were made. Numbers are never reused.
Allocate a number only after checking every published branch, not just `main`
(the command is in [the RFC index](../rfcs/README.md#naming)). Re-check before a draft is proposed: an unpublished draft yields to a
published one. ADR-0014 was
moved from ADR-0013 for that reason, before it was proposed; ADR-0013 stays
with the video-call work.

## Decisions

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](0001-documentation-as-code.md) | Accepted | Use documentation as code with English as the canonical language |
| [ADR-0003](0003-closed-alpha-review-policy.md) | Accepted | Bounded independent-AI review exception for private test-data alpha; human owner acceptance retained |

## Draft implementation records

- [ADR-0011](0011-voice-calls.md): proposed retained-channel WebRTC voice;
  local implementation task authorized, independent design/final reviews required.

- [ADR-0008](0008-user-triggered-android-updates.md): user-triggered pinned HTTPS
  Android APK updates with signer continuity and native installer confirmation;
  RFC-0013 implementation/review pending, not accepted distribution architecture.

- [ADR-0007](0007-self-service-messenger.md): self-service v2 registration and
  general direct messaging; local server tested, decision/owner disposition and
  SR-01 documentation re-review pending. RFC-0012 remains draft.
- [ADR-0004](0004-development-transport.md): initial development transport.
- [ADR-0005](0005-isolated-linux-alpha-package.md): isolated native alpha package;
  scope authorization exists, technical disposition and independent review pending.

## Proposed identity change

- [ADR-0006](0006-phone-key-registration.md): phone-created identity and bounded
  exact-key admission; proposed, owner scope/disposition and review pending.

## Proposed clean-install first contact

- [ADR-0009](0009-clean-first-contact.md): mandatory signed account-ID text/receipt
  channel for fresh private-alpha installs. Local implementation/build is directly
  authorized; permanent provenance and independent code review remain outstanding.
  Proposed, not accepted. Historical ADR-0007/0008 allocations in the server
  worktree remain unchanged.

## Lifecycle

ADRs use these states:

- `draft`: incomplete and not ready for disposition;
- `proposed`: ready for human disposition but non-normative;
- `accepted`: approved and normative after merge to the canonical branch;
- `rejected`: reviewed but not selected;
- `withdrawn`: closed before a decision by its author;
- `superseded`: replaced by a linked accepted ADR.

Allowed transitions are fail-closed:

- `draft` to `proposed` when the record is complete, or to `withdrawn` with the
  author's reason and permanent statement;
- `proposed` to `accepted` with all human acceptance evidence required by policy;
- `proposed` to `rejected` with the decision owner, rejection rationale, and
  permanent disposition evidence;
- `proposed` to `withdrawn` with the author's reason and permanent statement;
- `accepted` to `superseded` only through a linked newer accepted ADR.

No other direct status transition is valid. `status: accepted` may appear in a
review branch after its evidence is complete, but it becomes normative only when
that exact revision reaches the canonical branch.

1. Discuss significant designs in `docs/rfcs/`.
2. Create a `draft` ADR while the decision record is incomplete. Move it to
   `proposed` when it is ready for disposition and names the human
   `decision_owner` and required domain reviewers.
3. Link requirements, threat analysis, experiments, alternatives, and the RFC.
4. Record permanent links for decision-owner approval, any delegation, required
   reviews, validation evidence, remaining risks, and follow-up work in both the
   ADR and pull request.
5. Change the ADR to `accepted`, close the RFC as `completed`, and add the ADR to
   this index in the same pull request.
6. Merge only after the required human acceptance evidence is present. Merge
   execution by a bot is not itself approval.
7. Supersede an accepted ADR with a new ADR rather than rewriting history.

For a rejected or withdrawn ADR, preserve the disposition rationale and evidence
in the ADR and decision index even though the artifact is non-normative.

The authoritative acceptance rules are in the
[documentation policy](../governance/documentation-policy.md#decision-authority-and-acceptance-evidence).

Use [the ADR template](adr-template.md) for new decisions.

## Overnight realtime candidate

[Proposed ADR-0010: retained-stack realtime](0010-overnight-realtime.md) records the current private-alpha scope and its exact review/test gates.
No permanent architecture acceptance or physical-phone result is implied.

## Voice relay proposal

[Proposed ADR-0012](0012-voice-turn.md) specifies ephemeral relay issuance and
isolated packaging. Local task authorization does not constitute ADR acceptance.

## Integrated Devnet registration candidate

[Proposed ADR-0015](0015-integrated-devnet-client.md) records the integrated main
Android APK registration boundary under [RFC-0026](../rfcs/0026-solana-devnet-registration.md).
Source merge does not accept the ADR or implement server login, messenger recovery
or production readiness. The build/review evidence and owner-reported registration
are in [the v28 record](../project/evidence/android-v28-devnet-20260922/README.md).

## iOS client candidate

[Proposed ADR-0014](0014-ios-client.md): native SwiftUI iOS client over the
unchanged shared Rust core through a thin C-ABI bridge, Keychain/Data
Protection storage with an install marker, `Security.framework` leaf-SPKI
pinning to the retained pin and the pinned WebRTC iOS dependency, for the
bounded private alpha ([RFC-0021](../rfcs/0021-ios-client.md)). Proposed, not
accepted: the RFC's numbered questions are answered, but closed-alpha scope
approval, the independent AI review and the physical-phone evidence are not,
and none of them is a question this client can answer for the owner.
