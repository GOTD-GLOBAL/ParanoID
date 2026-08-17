---
status: accepted
owner: architecture
decision_owner: martadvix-web
approved_change: RFC/ADR lifecycle, decision authority, durable evidence, and protected-domain review governance
approval_date: pending
approval_pull_request: https://github.com/GOTD-GLOBAL/ParanoID/pull/4
approval_record: pending
last_reviewed: 2026-08-15
---

# Architecture decision log

ADRs preserve why durable choices were made. Numbers are never reused.

## Decisions

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](0001-documentation-as-code.md) | Accepted | Use documentation as code with English as the canonical language |

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
