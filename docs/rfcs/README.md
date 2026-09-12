---
status: accepted
owner: maintainers
decision_owner: martadvix-web
approved_change: RFC/ADR lifecycle, decision authority, durable evidence, and protected-domain review governance
approval_date: 2026-08-17
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/4
approval_record: https://github.com/GOTD-GLOBAL/ParanoID/pull/4#issuecomment-5311797500
last_reviewed: 2026-08-15
---

# Request for comments process

RFCs make significant proposals reviewable before implementation. They are not
accepted architecture until an ADR records the decision.

## States

- `draft`: author is still developing the proposal;
- `proposed`: ready for review and experiments;
- `completed`: review concluded; link every resulting accepted ADR;
- `rejected`: not selected; preserve the reason;
- `withdrawn`: author stopped the proposal;
- `superseded`: replaced by a linked RFC.

RFCs never use `accepted`. `completed` closes the discussion but does not make the
RFC normative; accepted decisions exist only in linked ADRs.

## Review and closure

Before moving an RFC to `proposed`, name its human `decision_owner`, required
domain reviewers, decision deadline, and validation plan. The proposal owner is
responsible for collecting evidence but cannot substitute authorship for the
required approval.

Close an RFC and record its disposition in one coherent pull request:

- use `completed` and link the accepted ADR or ADRs when a choice is approved;
- use `rejected` and preserve the rationale when no option is selected;
- use `withdrawn` when the author stops the proposal without a decision;
- use `superseded` and link the replacement RFC when discussion moves elsewhere.

Follow the human authority and acceptance-evidence rules in the
[documentation policy](../governance/documentation-policy.md#decision-authority-and-acceptance-evidence).

## Active narrow proposal

- [RFC-0013: User-triggered Android updates](0013-user-triggered-android-updates.md)
  (draft): user-requested Update button, pinned APK distribution and mandatory
  platform confirmation; [draft ADR-0008](../decisions/0008-user-triggered-android-updates.md).

- [RFC-0012: Self-service messenger](0012-self-service-messenger.md) (draft):
  automatic registration/general direct messaging; draft
  [ADR-0007](../decisions/0007-self-service-messenger.md),
  [v2 contract](../protocol/self-service-v2.md) and
  [threat delta](../security/self-service-v2-threats.md). Server locally tested;
  application/phone/deployment acceptance and architecture disposition remain open.

- [RFC-0010: Phone-created identity](0010-phone-key-registration.md) (draft):
  user correction, exact-key alpha admission and history-preserving migration;
  proposed ADR-0006, locally built/tested registration candidate.
- [RFC-0011: Key deployment migration](0011-key-deployment-migration.md) (proposed):
  exact offline schema transition, sticky cutover and history-preserving recovery;
  local package tested, independent final deployment review pending.

- [RFC-0006: One-server text contract](0006-single-server-text-contract.md)
  (draft): founder delivery/retention requirements, concrete technical
  recommendations and remaining application-disposition gates. Earlier RFC-0004/0005 are
  retained in closed PRs #6/#10 and their branches, not accepted architecture.

## Active governance proposal

- [RFC-0007: Bounded closed-alpha review policy](0007-closed-alpha-review-policy.md)
  (completed): approved by owner; ADR-0003 and the policy take effect on merge.

## Executable development proposal

- [RFC-0008](0008-executable-text-development-slice.md) and draft ADR-0004 accompany
  the bounded transport implementation, not a production architecture adoption.

- [RFC-0009](0009-isolated-linux-alpha-package.md): native isolated alpha package,
  explicit TLS mode and history-preserving lifecycle; draft ADR-0005.

## First-contact incoming proposal

- [RFC-0014](0014-first-contact-incoming.md) (proposed): owner-selected mandatory
  signed account-ID intro-v2 channel, immediate unverified incoming plaintext/reply,
  clean-install local implementation/testing/build scope; proposed ADR-0009.
  Historical migration/recovery is outside this candidate's gate; old REDs remain
  reported separately. The former Android-local RFC-0013 is preserved as [RFC-0016](0016-asymmetric-retained-context.md), with a transparent numbering correction.

## Naming

Use `NNNN-short-title.md`. Allocate the next number and never reuse it. Add active
RFCs to this file when the first proposal is opened.

A number is only free when no other branch has taken it. Before allocating,
check every published branch, not just `main`:

```sh
git fetch --all --prune
for ref in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do
  git ls-tree -r --name-only "$ref" -- docs/rfcs docs/decisions
done | grep -oE '[0-9]{4}' | sort -u | tail -1
```

When two branches reach the same number anyway, the branch that is merged
later renumbers and records the correction here in one sentence, as done for
RFC-0016 and RFC-0021. Numbers are never silently reused or swapped.

## Required use

Create an RFC for every
[protected decision domain](../governance/documentation-policy.md#protected-decision-domains)
or any other change whose reversal would be expensive or compatibility-sensitive.

Use [the RFC template](rfc-template.md).

## Overnight realtime candidate

[RFC-0015: overnight realtime](0015-overnight-realtime.md) records the current private-alpha scope and its exact review/test gates.
No permanent architecture acceptance or physical-phone result is implied.

## Push wake

[RFC-0020](0020-push-wake.md) (proposed) covers the content-free FCM wake
gateway (owner decision recorded 2026-09-12); server implementation and tests
land first, the Android registration/wake follows in the next APK.

## Voice relay completion

[RFC-0018](0018-voice-turn.md) (proposed) covers REQ-CALL-006, the issuer,
Android contract and isolated relay package. Independent review and explicit
deployment authority remain separate gates.

## iOS client candidate

[RFC-0021: Native iOS client on the shared Rust core](0021-ios-client.md)
(draft) proposes a SwiftUI shell over the unchanged `clients/core` through a
thin C-ABI bridge, the same wire contracts and pin as Android v15, Keychain
plus Data Protection storage with an install marker, and the pinned WebRTC
iOS dependency; [draft ADR-0014](../decisions/0014-ios-client.md). Its
decision deadline is a placeholder until the client pull request is opened.
No build, phone result, hosted account or architecture acceptance is implied.
This candidate has been renumbered twice while still a draft, both times
transparently and before it was proposed: RFC-0019 was already allocated on
the unmerged `feat/video-calls-v16` branch, and RFC-0020 was then allocated
on the published `feat/push-fcm-gateway` branch. RFC-0019 stays with the
video-call work, RFC-0020 with the push wake gateway, and the iOS candidate
is RFC-0021. Both moves follow the naming rule below: an unpublished draft
yields.

## Video calls proposal

[RFC-0019](0019-video-calls.md) (proposed) covers 1:1 camera video on the
retained E2EE call channel as [call-v2](../protocol/call-v2.md), with
[ADR-0013](../decisions/0013-video-calls.md) proposed and the
[threat delta](../security/video-v1-threats.md) drafted. Groups, SFU and
screen sharing are explicitly excluded.
