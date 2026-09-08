---
status: accepted
owner: maintainers
last_reviewed: 2026-08-09
---

# Current project state

## Phase

**Inception and architecture discovery.** This repository is a clean reboot. It
contains documentation governance and project framing, but no messenger
implementation or accepted production architecture.

The earlier proof of concept is preserved in the private
`GOTD-GLOBAL/ParanoID-legacy` repository. It may be mined for lessons, UX ideas,
and experiments, but it is not a dependency or source of current architecture.

## Experimental device evidence

A disposable Android packaging diagnostic exists in
`spikes/002-android-bootstrap`. The owner supplied a screenshot of installation
and launch on OPPO CPH2671 (Android 16/API 36). It displays device information
locally, has no network permission and is not a messenger or stack acceptance.

## Present facts

- The new repository is private and intentionally starts from a clean history.
- The product vision is documented as a draft.
- Initial product requirements are traceable but do not yet have complete
  acceptance criteria.
- Documentation-as-code is the first accepted project decision.
- No application stack, blockchain, identity protocol, messaging protocol,
  cryptographic construction, database, hosting platform, or token model has
  been selected.
- No production security or privacy claims are valid yet.

## Experimental Android evidence (not a production capability)

The isolated [Android probe](../../spikes/002-android-bootstrap/README.md) builds
an ARM64 APK using vodozemac with a JNI boundary for a local synthetic self-test.
Host tests and cross-compilation pass. The session handoff records owner-reported
local diagnostic PASS on OPPO CPH2671 and CPH2659 (Android 16 ARM64); this is not
a new physical-device run or proof of phone-to-phone messaging. No server, real
conversation, account recovery or production stack is introduced. RFC-0004
(closed PR #6) is historical proposal context only.

## Closed-alpha review policy

The founder requested removal of the mandatory second-human reviewer after
reporting that none is available. [RFC-0007](../rfcs/0007-closed-alpha-review-policy.md)
records a bounded private test-data alpha exception with independent AI review
and retained human decision-owner approval, approved by martadvix-web in PR #12.
[ADR-0003](../decisions/0003-closed-alpha-review-policy.md) records acceptance;
the policy becomes normative on merge. It accepts no application architecture,
authorizes no deployment and makes no security claim.

## Next decision gates

1. Validate and prioritize the initial requirements with the founder.
2. Define assets, adversaries, metadata exposure, recovery, and trust boundaries.
3. Specify identity and nickname lifecycle, including cost and abuse resistance.
4. Compare protocol and implementation strategies, including open-source prior art.
5. Select the first vertical slice and its measurable acceptance criteria.
6. Accept the initial architecture and stack through RFCs and ADRs.

## Update trigger

Update this document whenever a gate is completed, a production capability is
added, a major risk changes, or an accepted decision changes what a newcomer
should believe about the project.
