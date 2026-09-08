---
status: proposed
owner: maintainers
decision_owner: martadvix-web
approved_change: proposed bounded second-human review exception for private test-data alpha
approval_date: pending
approval_pull_request: pending
approval_record: pending
last_reviewed: 2026-09-08
---

# Documentation policy

## Objective

At any project stage, a new developer, reviewer, operator, auditor, or AI agent
must be able to determine:

- what the system is intended to do;
- what it actually does now;
- why important decisions were made;
- which contracts must remain compatible;
- where trust boundaries and known risks exist;
- how to build, test, deploy, observe, recover, and change it safely.

## Documentation as code

Canonical documentation is versioned with the code it describes. It is reviewed
in the same pull request, rendered from text where practical, and checked by
automation. Chat messages, meetings, issue comments, and external presentations
are inputs, not durable sources of truth.

## Sources of truth

Different artifacts answer different questions:

| Question | Canonical artifact |
| --- | --- |
| Why was a durable choice made? | Accepted ADR |
| What is being proposed? | RFC |
| What must the product do? | Versioned requirement |
| What contract must implementations follow? | Protocol/API/schema specification |
| What is implemented and verified now? | Code and automated tests |
| What is usable or deployed now? | Current-state document and release record |
| How is the system operated safely? | Runbook |
| What can go wrong and where is trust placed? | Threat model |

Contradictions between these artifacts are defects. Report and resolve them in
the same change; do not hide them behind precedence rules.

## Required metadata

Durable documents use YAML front matter with `status`, `owner`, and
`last_reviewed`. Draft templates may use placeholders. Generated references must
identify their generator and source revision.

`owner` identifies who maintains the artifact; it does not grant decision
authority. RFCs and ADRs moving beyond `draft` also name a human
`decision_owner`. Status describes the authority of the artifact, not whether its
branch exists or its pull request was merged.

A material change to an accepted normative document also records
`decision_owner`, `approved_change`, `approval_date`, `approval_pull_request`, and
`approval_record` in front matter. `approval_record` is the permanent human
approval evidence URL described below. None of these approval fields may remain
`pending` when the change is merged.

## Decision hygiene

- An ADR captures one decision, its context, options, trade-offs, consequences,
  and verification method.
- Accepted ADRs are append-only historical records. Supersede rather than rewrite.
- An RFC is non-normative design discussion and may change until closed.
- A completed RFC links the accepted ADR or ADRs that record its disposition.
- Rejected options remain documented when they explain important trade-offs.

## Protected decision domains

The following domains require an RFC or ADR, threat-model review where relevant,
and the review process defined below. Independent qualified human review is the
default; only the explicit closed-alpha exception can replace the second reviewer:

- identity, key derivation, recovery, and blockchain integration;
- cryptographic algorithms and end-to-end encryption semantics;
- federation, protocol compatibility, persistence formats, event models, and
  public APIs;
- storage, data retention, and payment boundaries;
- plugin permissions and isolation;
- the primary stack and foundational dependencies;
- security boundaries and trust assumptions;
- deployment topology and backward compatibility.

This section is the canonical protected-domain list. Other governance documents
must link here rather than maintain narrower parallel lists.

## Decision authority and acceptance evidence

ParanoID is in its inception phase, so decision authority remains human and
explicit:

- the founder and current project decision owner is the human GitHub user
  `martadvix-web`;
- the founder is the decision owner for product scope, requirements, and product
  priorities;
- the founder or a human maintainer explicitly delegated by the founder is the
  decision owner for technical and governance decisions;
- every change in a
  [protected decision domain](#protected-decision-domains) requires a second
  qualified human domain reviewer who is not the decision owner or author, unless
  the bounded [closed-alpha exception](#closed-alpha-review-exception) applies.

Until a domain owner is delegated, the founder owns triage and reviewer
selection for that domain. This fallback does not itself waive review. Outside
the closed-alpha exception, if no qualified second human is available, the
proposal remains `proposed`.

Delegation and required reviewers must be recorded in the RFC, ADR, or pull
request. A delegation is valid only when its evidence meets the same identity,
permalink, and source requirements as decision approval. A statement by the
delegate, author, automation account, or AI agent is not delegation evidence. A
person with merge permission does not gain decision authority merely by creating
or merging a change. AI reviews are advisory and cannot satisfy a required human
approval.

An ADR may change from `proposed` to `accepted` only when the same pull request
records all of the following:

1. the human decision owner and the exact decision being approved;
2. links to applicable requirements, RFCs, threat analysis, experiments, and
   alternatives, or an explicit explanation for each item that is not applicable;
3. validation evidence, known limitations, unresolved risks, and follow-up work;
4. approval from the decision owner and every required human domain reviewer, or
   complete closed-alpha exception evidence in place of the second-human review;
5. the accepted ADR, its decision-log entry, and the completed or otherwise closed
   RFC state as one coherent change, or an explicit `not applicable` explanation
   when no RFC was required.

An ADR may change from `proposed` to `rejected` only when the decision owner,
rejection rationale, and permanent disposition evidence are recorded. Its author
may change a `draft` or `proposed` ADR to `withdrawn` by recording the reason and a
permanent author statement. An accepted ADR may change only to `superseded`, by a
linked newer accepted ADR. Other direct status transitions are invalid.

The same human decision-owner approval is required for a material change to an
already accepted policy, requirement, specification, or other normative document.
A material change alters obligations, authority, status semantics, compatibility,
or system behavior; editorial corrections do not require a new decision.

## Closed-alpha review exception

This exception applies only after this policy revision is approved and merged.
It removes the mandatory SECOND human reviewer for bounded private test-data
alpha development; the human decision owner is never removed or replaced by AI.

Every use must record all of the following in its RFC/ADR and implementation PR:

1. `review_mode: closed-alpha-ai`, the exact features, devices, data and environment,
   the human risk owner, and a permanent owner approval for that scope. A blanket
   instruction to proceed, this policy approval or an AI statement is not approval
   of a particular architecture or permission to merge/deploy it.
2. An independent AI review in a fresh context, separate from the implementing
   context. Record reviewer/model, reviewed revision, findings, resolutions and
   final report in the PR. Self-review alone does not qualify. Prefer a different
   model where available; shared-model blind spots remain a disclosed risk.
3. No unresolved blocking security/correctness findings. If the reviewer fails,
   cannot finish, or disagrees materially, fix and re-review or escalate to the
   owner; do not silently mark the gate passed. The owner cannot make a failed
   test into passing evidence by approving it.
4. Applicable RFC/ADR, versioned contract, threat analysis, requirement-to-test
   mapping, actual verification evidence and honest NOT RUN items. Acceptance
   criteria for delivered behavior must pass; missing phone evidence cannot be
   replaced by a simulator or dependency build. ADR acceptance still requires
   the human decision owner's exact decision approval and all lifecycle records.
5. Only private, informed alpha testers using synthetic/non-sensitive test data.
   E2EE remains required; no plaintext fallback, server content-key escrow or
   invented recovery guarantees. A closed test endpoint is not production-ready
   just because it runs on the owner's existing production machine. Deployment
   still needs explicit bounded authorization, isolation and rollback.
6. A review exit gate: before real sensitive communication, public release,
   production/security/privacy claims, or expansion beyond the approved private
   test scope, obtain independent qualified human review appropriate to identity,
   cryptography, persistence and application security. Record the actual scope
   and evidence; do not describe earlier AI review as a human audit.

Requests using real sensitive data, an unreviewed scope expansion or a
production-readiness claim do not qualify. Such requests remain blocked under
the default human-review rule. Server restart, backups, retained metadata and
local key loss still require explicit contracts and tests; the exception does
not weaken those boundaries or any secret-handling rule.

Application RFCs/ADRs may have `required_reviewers: []` only when accompanied by
`review_mode: closed-alpha-ai` and complete exception evidence (or an explanation
that no protected domain applies). Record the independent AI reviewer separately;
never insert an AI identity into a list of human reviewers. Existing proposals
must be updated explicitly after this revision becomes normative; they are not
automatically approved, completed or reclassified. Existing accepted decisions
and their historical human approval evidence remain unchanged.

## Durable approval and delegation records

The accepted ADR or materially changed normative document is the durable record.
It must identify the approver, approval date, exact decision or change boundary,
pull request, and permanent evidence URL. The evidence may be:

- a GitHub review or comment made by the human approver; or
- the original approval message in the recognized private Telegram group
  `ParanoID`, when the message has a stable link visible to project members and
  an authenticated sender identity that maps unambiguously to the decision owner.

When Telegram evidence is used, the pull request and durable record must contain
the message permalink, platform message ID, sender identity mapping, timestamp,
and exact approval text. A relay comment only points to this source evidence; the
relayer does not create or validate the approval. If the original message cannot
be linked and independently checked by authorized project members, the decision
owner must confirm the approval directly on GitHub. Apply the same rules to
delegation evidence. Do not copy secrets or unrelated private conversation into
the repository.

Chat and pull-request discussion remain inputs rather than canonical design
documents. Their permanent links are provenance for the approval fields committed
in the ADR or normative document. Silence, a green CI result, an AI verdict, an
unverifiable relay, or merge execution alone is never approval.

After the evidence is present, merge to the canonical branch publishes the
decision. A bot may execute that merge, but the recorded human approval remains
the acceptance event. These rules apply to acceptance transitions made after this
policy change; they do not retroactively invalidate ADR-0001.

An ADR may show `status: accepted` in a review branch only after all acceptance
evidence is complete. It becomes normative only when that exact revision is merged
to the canonical branch.

## Traceability

Requirements receive stable identifiers. Pull requests and tests reference the
identifiers they satisfy. Public contracts declare versions. Breaking changes
include migration and rollback documentation before merge.

## Freshness

- Review changed documents in every relevant pull request.
- Review security and architecture documents at each release milestone.
- Review `current-state.md` at least monthly during active development.
- Review runbooks through exercises, not editorial inspection alone.
- A reviewer may block a change because documentation is misleading, even if the
  code works.

## Automation

CI checks Markdown structure and links. As the stack is selected, add checks that
compare generated API/protocol references, schemas, database migrations, CLI help,
configuration examples, and architecture rules against their sources.

Automation can detect drift but cannot decide whether an explanation is useful.
Human decision-owner acceptance remains required. Independent domain review
follows the default rule or the bounded closed-alpha exception above.

## Security and privacy

Never place secrets, private keys, seed phrases, production personal data,
vulnerability details under embargo, or customer-confidential material in the
repository. Use synthetic examples. Mark security assumptions and unsupported
claims explicitly.

## Canonical language and translations

English is the canonical language for technical and governance documentation.
Translations link to the canonical file and record the source revision. If a
translation conflicts with the canonical document, the conflict must be fixed;
the translation does not create a new requirement.
